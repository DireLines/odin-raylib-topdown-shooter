#+feature dynamic-literals
package game_main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:strings"
import hm "handle_map_static"
import maps "mapgen"
import rl "vendor:raylib"
import "words"

//controls
GAME_NAME :: "earshot"
BULLET_FONT: FontName : .Atkinson_Hyperlegible_Bold
MENU_SCREEN_DIMS :: vec2{WINDOW_WIDTH, WINDOW_HEIGHT}
MENU_BUTTON_SPACING :: 0.15
//speeds in world units per second
PLAYER_MAX_SPEED :: 100
PLAYER_LINEAR_DRAG :: 5.0
PLAYER_BULLET_SPEED :: 1200
REFLECTED_BULLET_SPEED :: 500
BULLET_KNOCKBACK_STRENGTH :: 10
ENEMY_LINEAR_DRAG :: 5.0
ENEMY_CONTACT_KNOCKBACK_STRENGTH :: 20
//which collision layers can hit which others?
@(rodata)
COLLISION_MATRIX: [CollisionLayer]bit_set[CollisionLayer] = #partial {
	.Default      = ~{}, //all layers
	.Wall         = {.Player, .PlayerBullet, .Bullet, .Enemy, .EnemyBullet},
	.Player       = {.Wall, .Enemy, .EnemyBullet},
	.PlayerBullet = {.Enemy, .Wall},
	.Bullet       = {.Wall, .Player, .Enemy},
	.Enemy        = {.Wall, .Player, .PlayerBullet},
	.EnemyBullet  = {.Player, .Wall},
}
//type constraints to check
TYPE_ASSERTS := []GameObjectTypeAssert {
	TagVariantAssert{.Player, Player, true, true},
	TagVariantAssert{.Enemy, Enemy, true, true},
	TagVariantAssert{.Bullet, Bullet, true, true},
	TagCollisionLayerAssert{.Bullet, .Bullet, false, true},
	TagCollisionLayerAssert{.Bullet, .PlayerBullet, false, true},
	TagCollisionLayerAssert{.Bullet, .EnemyBullet, false, true},
}
//map legend
BEE_YELLOW :: rl.Color{246, 208, 58, 255}
BASIC_ENEMY_COLOR :: rl.Color{20, 205, 168, 255}
FLOOR_MAP_COLOR :: rl.Color{128, 128, 128, 255}
EarshotProps :: struct {
	target_word, current_string: string,
	selection:                   int2, //first and last selected index of current_string
	word_properties:             words.WordProperties,
	mouth, word_display:         Maybe(GameObjectHandle),
}
//game-specific stuff that applies to all objects
GameSpecificProps :: EarshotProps


//named render layers
RenderLayer :: enum uint {
	Bottom  = 0,
	Floor   = NUM_RENDER_LAYERS * 50.0 / 256,
	Wall    = NUM_RENDER_LAYERS * 52.0 / 256,
	Enemy   = NUM_RENDER_LAYERS * 100.0 / 256,
	Bullet  = NUM_RENDER_LAYERS * 120.0 / 256,
	Player  = NUM_RENDER_LAYERS * 128.0 / 256,
	Ceiling = NUM_RENDER_LAYERS * 200.0 / 256,
	UI      = NUM_RENDER_LAYERS * 240.0 / 256,
	Top     = NUM_RENDER_LAYERS - 1,
}

CollisionLayer :: enum {
	Default = 0,
	Wall, //wall or other scenery
	Player,
	PlayerBullet, //bullet which can't hit the player
	Bullet, //bullet which can hit either player or enemies (gameplay code can ignore certain collisions)
	Enemy,
	EnemyBullet, //bullet which can't hit enemies
}

//object tags
ObjectTag :: enum {
	Bullet,
	Player,
	Enemy,
	Collide,
	Sprite,
	Text,
}

AliveDeadState :: enum {
	Alive,
	Dead,
}

MenuState :: enum {
	InGame,
	MainMenu,
}

EnemyState :: enum {
	Alive_Inactive,
	Alive_Active,
	Dead,
}

//types of objects in the game
Player :: struct {
	health: int,
	state:  AliveDeadState,
}
Enemy :: struct {
	spawn_point:    vec2,
	state:          EnemyState,
	type:           EnemyType,
	pathfind_index: uint,
	path:           TilePath,
}
Bullet :: struct {
	last_hit_object: Maybe(GameObjectHandle),
	state:           AliveDeadState,
}
UIButton :: struct {
	min_scale, max_scale: vec2,
	on_click:             proc(info: ButtonCallbackInfo),
}
DefaultVariant :: distinct struct{}
GameObjectVariant :: union {
	DefaultVariant,
	Player,
	Enemy,
	Bullet,
	UIButton,
}

//game-specific initialization logic
game_start :: proc() {
	load_map :: proc() -> (tilemap: Tilemap, player_spawn: TilemapTileId) {
		MAP_DATA :: #load("map.png")
		tiles_img := rl.LoadImageFromMemory(".png", raw_data(MAP_DATA), i32(len(MAP_DATA)))
		tiles_buf := maps.img_to_buf(tiles_img)
		color_to_tile :: proc(c: rl.Color) -> Tile {
			t := Tile{}
			COLOR_TO_TILETYPE := map[rl.Color]TileType {
				rl.BLACK        = .Wall,
				FLOOR_MAP_COLOR = .None,
			}
			COLOR_TO_SPAWN := map[rl.Color]SpawnType {
				BEE_YELLOW        = .Player,
				BASIC_ENEMY_COLOR = .Enemy,
			}
			tiletype, ok := COLOR_TO_TILETYPE[c]
			if ok {
				t.type = tiletype
			}
			spawntype, spawn_ok := COLOR_TO_SPAWN[c]
			if spawn_ok {
				t.spawn = spawntype
			}
			return t
		}
		return img_to_tilemap(tiles_buf, color_to_tile)
	}
	player_spawn_tile: TilemapTileId
	game.global_tilemap, player_spawn_tile = load_map()
	game.player_spawn_point = get_tile_center(player_spawn_tile)
	cam.position = game.player_spawn_point

	game.menu_state = .MainMenu
	main_menu_start()
	words.populate_words_by_difficulty()
}
earshot_start :: proc() {
	game.paused = false
	//spawn player
	player_def := GameObject {
		name = "player",
		transform = {
			position = game.player_spawn_point,
			rotation = 0,
			scale = {1, 1},
			pivot = {64, 64},
		},
		linear_drag = PLAYER_LINEAR_DRAG,
		hitbox = {layer = .Player, box = {{-29, -45}, {29, 44}}}, //relative to object's pivot
		render_info = {
			color = rl.WHITE,
			texture = atlas_textures[.Bflap0],
			render_layer = uint(RenderLayer.Player),
		},
		animation = initial_animation_state(make_animation(.Bflap, 3)),
		target_word = "bee",
		tags = {.Player, .Collide, .Sprite},
		variant = Player{5, .Alive},
	}
	player_handle := spawn_object(player_def)
	player_mouth_handle := spawn_object(
		GameObject {
			name = "player mouth",
			transform = {position = {13, -21}, rotation = 0, scale = {0.3, 0.3}, pivot = {64, 64}},
			render_info = {
				color = rl.WHITE,
				texture = atlas_textures[.Mouth_Talk0],
				render_layer = uint(RenderLayer.Player) + 1,
			},
			animation = initial_animation_state(
				make_animation(.Mouth_Talk, 5, loop = false),
				paused = true,
			),
			parent_handle = player_handle,
			tags = {.Sprite},
		},
	)
	player_word_handle := spawn_object(
		GameObject {
			name = "word display",
			transform = {scale = {1, 1}, pivot = {0, 0}, position = {0, -player_def.pivot.y}},
			render_layer = uint(RenderLayer.Player) + 1,
			current_string = "bee",
			parent_handle = player_handle,
			tags = {.Text},
		},
	)

	game.player_handle = player_handle
	player := hm.get(&game.objects, player_handle)
	player.mouth = player_mouth_handle
	player.word_display = player_word_handle
}
earshot_stop :: proc() {
	//TODO save progress
	reset_game()
}
reset_game :: proc() {
	hm.clear(&game.objects)
	recreate_final_transforms()
	game.frame_counter = 0
	game.screen_space_parent_handle = spawn_object(GameObject{name = "screen space parent"})
}
main_menu_start :: proc() {
	game.paused = true
	//spawn buttons
	titlebar_tex := atlas_textures[.Earshot_Title]
	sc := vec2{titlebar_tex.rect.width, titlebar_tex.rect.height} / 400
	titlebar := spawn_object(
	GameObject {
		transform = {
			position = MENU_SCREEN_DIMS * {0.5, 0.1},
			pivot    = {125 / sc.x * 2, 0}, //TODO it *SHOULD* be half the texture width, why is it this?
			scale    = sc,
		},
		parent_handle = game.screen_space_parent_handle,
		texture = atlas_textures[.Earshot_Title],
		render_layer = uint(RenderLayer.UI),
		color = rl.WHITE,
		tags = {.Sprite},
	},
	)
	play_button := spawn_button(
		MENU_SCREEN_DIMS * {0.5, 0.1 + MENU_BUTTON_SPACING * 2},
		.White,
		"PLAY",
		proc(info: ButtonCallbackInfo) {
			game := info.game
			if ODIN_OS == .JS {
				rl.InitAudioDevice()
			}
			main_menu_stop()
			recreate_final_transforms()
			game.menu_state = .InGame
			earshot_start()
		},
	)
	//TODO volume sliders
	//TODO credits
	quit_button := spawn_button(
		MENU_SCREEN_DIMS * {0.5, 0.1 + MENU_BUTTON_SPACING * 4},
		.White,
		"QUIT",
		proc(info: ButtonCallbackInfo) {
			game := info.game
			main_menu_stop()
			game.quit = true
		},
	)
	main_menu_objects := [dynamic]GameObjectHandle{play_button, quit_button, titlebar}
	game.menu_container = spawn_object(
		GameObject{associated_objects = {"main_menu" = main_menu_objects}},
	)
}
main_menu_stop :: proc() {
	menu_container_obj, ok := hm.get(&game.objects, game.menu_container)
	if !ok {
		print("menu container handle is invalid")
		return
	}
	main_menu_buttons := menu_container_obj.associated_objects["main_menu"].([dynamic]GameObjectHandle)
	for button in main_menu_buttons {
		hm.remove(&game.objects, button)
	}
}
pause_menu_start :: proc() {
	resume_button := spawn_button(
		MENU_SCREEN_DIMS * {0.5, 0.1 + MENU_BUTTON_SPACING * 2},
		.White,
		"RESUME",
		proc(info: ButtonCallbackInfo) {
			game := info.game
			pause_menu_stop()
			game.paused = false
		},
	)
	//TODO volume sliders
	main_menu_button := spawn_button(
		MENU_SCREEN_DIMS * {0.5, 0.1 + MENU_BUTTON_SPACING * 4},
		.White,
		"QUIT",
		proc(info: ButtonCallbackInfo) {
			game := info.game
			pause_menu_stop()
			earshot_stop()
			game.menu_state = .MainMenu
			main_menu_start()
		},
	)
	pause_menu_objects := [dynamic]GameObjectHandle{resume_button, main_menu_button}
	menu_container := hm.get(&game.objects, game.menu_container)
	menu_container.associated_objects["pause_menu"] = pause_menu_objects
}
pause_menu_stop :: proc() {
	menu_container_obj, ok := hm.get(&game.objects, game.menu_container)
	if !ok {
		print("menu container handle is invalid")
		return
	}
	pause_menu_buttons := menu_container_obj.associated_objects["pause_menu"].([dynamic]GameObjectHandle)
	for button in pause_menu_buttons {
		hm.remove(&game.objects, button)
	}
}

//game-specific update logic
game_update :: proc(dt: f64) {
	switch game.menu_state {
	case .InGame:
		earshot_update(dt)
	case .MainMenu:
		main_menu_update(dt)
	}
}

LidarPoint :: struct {
	p:       vec2,
	visible: bool,
}
NUM_LIDAR_POINTS :: 5000
lidar_points: [NUM_LIDAR_POINTS]LidarPoint
next_lidar_point: int = 0
earshot_update :: proc(dt: f64) {
	if rl.IsKeyPressed(rl.KeyboardKey.ESCAPE) {
		game.paused = !game.paused
		if game.paused {
			pause_menu_start()
			recreate_final_transforms()
		} else {
			pause_menu_stop()
		}
	}
	// main game logic
	timer := timer()
	handle_ui_buttons()
	if game.paused {
		//TODO additional pause menu stuff?
		return
	}
	timer->time("handle buttons")
	{
		chunks_near_cam := get_chunks_near_cam(1)
		for chunk in chunks_near_cam {
			if chunk not_in game.loaded_chunks {
				tilemap := get_tilemap_chunk(chunk)
				min_corner, _ := get_tilemap_corners(chunk)
				for i in 0 ..< CHUNK_WIDTH_TILES {
					for j in 0 ..< CHUNK_HEIGHT_TILES {
						if tilemap[i][j].spawn == .Enemy {
							spawn_tile := min_corner + TilemapTileId{i, j}
							for _ in 0 ..< 3 {
								pos := random_point_in_tile(spawn_tile)
								word, _ := words.get_word(
									min_difficulty = 0,
									max_difficulty = 1,
									min_length = 0,
									max_length = 7,
								)
								spawn_enemy(pos, .Basic, word)
							}
						}
					}
				}
				game.loaded_chunks[chunk] = {}
			}
		}
		//TODO load/unload chunks if cam chunks changed
		//mostly need to decide what to actually do on chunk unload
		//1. unload tilemap
		//2. unload (inactive?) enemies currently in chunk?
		//3. remember which enemies to respawn when chunk is loaded again?
	}
	timer->time("load chunks")
	//player movement
	player, player_present := hm.get(&game.objects, game.player_handle)
	// player.shader = .SolidColor
	switch player.variant.(Player).state {
	case .Alive:
		mouse_pos := screen_to_world(linalg.to_f64(rl.GetMousePosition()), cv)
		pos_diff := (mouse_pos - player.position) * 60
		//flip if needed
		if math.sign(pos_diff.x) != math.sign(player.scale.x) {
			player.scale.x *= -1
		}
		//move toward mouse
		move_speed := PLAYER_MAX_SPEED / dt
		multiplier: f64 = 0
		if rl.IsMouseButtonDown(.LEFT) {
			multiplier = 0.1
		} else if rl.IsMouseButtonDown(.RIGHT) {
			move_speed *= 0.5 // backward max accel slower
			multiplier = -0.1
		}
		movement_vec := pos_diff
		if linalg.length(movement_vec) > move_speed {
			movement_vec = linalg.normalize(movement_vec) * move_speed
		}
		player.inst_velocity = movement_vec * multiplier
		// player.acceleration = movement_vec * multiplier
		CAM_LERP_AMOUNT :: 0.15
		// TODO why is this so nauseating when the player starts/stops moving?
		// //lerp cam to position ahead of player
		// CAM_LEAD :: 0.3
		// cam_target := player.position + player.velocity * CAM_LEAD
		// cam.position += (cam_target - cam.position) * CAM_LERP_AMOUNT
		cam.position += (player.position - cam.position) * CAM_LERP_AMOUNT
		timer->time("move player")
		keys := [dynamic]rl.KeyboardKey{}; defer delete(keys)
		key := rl.GetKeyPressed()
		for key != .KEY_NULL {
			append(&keys, key)
			key = rl.GetKeyPressed()
		}
		mouth_pos := get_world_center(player.mouth.(GameObjectHandle))
		bullet_diff := mouse_pos - mouth_pos
		bullet_velocity :=
			linalg.normalize(bullet_diff) * PLAYER_BULLET_SPEED + player.velocity * 0.5
		bullet_fired := false
		for key in keys {
			bullet_handle := spawn_bullet(key, mouth_pos, bullet_velocity, layer = .PlayerBullet)
			if bullet_handle != nil {
				bullet_fired = true
				rl.PlaySound(get_sound("light-fire.wav"))
			}
		}
		if bullet_fired {
			mouth := hm.get(&game.objects, player.mouth.(GameObjectHandle))
			mouth.animation.frame = .Mouth_Talk0
			mouth.animation.ticks_until_change = 1
			mouth.animation.paused = false
		}
		timer->time("spawn bullets")
	case .Dead:
		player.velocity = 0
		//TODO play player death sfx, switch sprite to dead bee
		print("game over :)") //TODO: game over screen, menuing, score
	}
	{it := hm.make_iter(&game.objects)
		for bullet, bullet_handle in all_objects_with_variant(&it, Bullet) {
			has_line_of_sight(bullet.position, local_to_world(player.mouth.(GameObjectHandle), {}))
		}
	}
	timer->time("line of sight checks")
	{it := hm.make_iter(&game.objects)
		for bullet, bullet_handle in all_objects_with_variant(&it, Bullet) {
			switch bullet.state {
			case .Alive:
				bullet_has_string := bullet.current_string != ""
				collisions, has_collisions := game.collisions[bullet_handle]
				if !has_collisions {continue}
				//generally bullet gets destroyed on impact with stuff
				//but cannot default to destroying it and set false for non-fatal collisions
				//because we want fatal collisions to take precedence
				//otherwise bullet appears to clip through things
				should_kill_bullet := false
				for collision in collisions {
					if collision.type != .start {continue}
					switch other_handle in collision.b {
					case GameObjectHandle:
						if other_handle == bullet.last_hit_object {continue}
						other, ok := hm.get(&game.objects, other_handle)
						if !ok {continue}
						knockback_vec :=
							(other.position - bullet.position) * BULLET_KNOCKBACK_STRENGTH
						//TODO operate on tags
						#partial switch other.hitbox.layer {
						case .Bullet, .PlayerBullet, .EnemyBullet:
						//bullets should phase through each other - don't do anything
						case .Enemy:
							enemy := other
							word_props := other.word_properties
							if bullet_has_string {
								letter_is_correct :=
									len(other.target_word) > len(other.current_string) &&
									other.target_word[len(other.current_string)] ==
										bullet.current_string[0]
								if letter_is_correct && .accept_correct_letter in word_props ||
								   !letter_is_correct && .accept_incorrect_letter in word_props {
									//add to current string
									old_string := enemy.current_string
									defer delete(old_string)
									enemy.current_string = fmt.aprint(
										enemy.current_string,
										rune(bullet.current_string[0]),
										sep = "",
									)
									should_kill_bullet = true
									// apply_knockback(knockback_vec, enemy)
									rl.PlaySound(get_sound("hit.wav"))
								}
								if word_h, ok := enemy.word_display.(GameObjectHandle); ok {
									word := hm.get(&game.objects, word_h)
									word.current_string = enemy.current_string
								}

								if letter_is_correct && .reflect_correct_letter in word_props ||
								   !letter_is_correct && .reflect_incorrect_letter in word_props {
									if bullet.last_hit_object == nil {
										//reflect bullet
										should_kill_bullet = false
										bullet.velocity =
											-linalg.normalize(bullet.velocity) *
											REFLECTED_BULLET_SPEED
										bullet.last_hit_object = other_handle
										bullet.hitbox.layer = .Bullet // can now collide with player and other enemies
										apply_knockback(knockback_vec, enemy)
										rl.PlaySound(get_sound("ricochet.wav"))
									} else {
										//bullet should only reflect once
										should_kill_bullet = true
										apply_knockback(knockback_vec, enemy)
										rl.PlaySound(get_sound("hit.wav"))
									}
								}
								//did we just kill?
								if .clear_on_current_matches_target in word_props &&
								   enemy.target_word == enemy.current_string {
									e := &enemy.variant.(Enemy)
									e.state = .Dead
								}
							}
						case .Player:
							should_kill_bullet = true
							player := other
							//take damage
							p := &player.variant.(Player)
							p.health -= 1
							rl.PlaySound(get_sound("hit.wav"))
							apply_knockback(knockback_vec, player)
							//did we just die?
							if p.health <= 0 {
								p.state = .Dead
							}
						case:
							should_kill_bullet = true
						}
					case TilemapTileId:
						should_kill_bullet = true
						tile := get_tile(other_handle)
						#partial switch TILE_PROPERTIES[tile.type].layer {
						}
						rl.PlaySound(get_sound("hit-dud.wav"))
					}
				}
				if should_kill_bullet {
					bullet.tags -= {.Collide}
					bullet.state = .Dead
					bullet.animation = make_animation_state(.Explosion, 2)
					//TODO move bullet to point of impact - for this need to remember fatal collision
					bullet.velocity = {}
					bullet.scale *= 1.4
					bullet.rotation += f64(rand.int_max(3)) * 90
				}
			case .Dead:
				num_anim_frames_left := int(
					bullet.animation.anim.last_frame - bullet.animation.frame,
				)
				if num_anim_frames_left <= 0 {
					hm.remove(&game.objects, bullet_handle)
				}
			}
		}
	}
	timer->time("handle bullet hits")
	{it := hm.make_iter(&game.objects)
		printed_details := false
		for enemy, h in all_objects_with_variant(&it, Enemy) {
			activate_distance :: TILE_SIZE * 50
			switch enemy.state {
			case .Alive_Inactive:
				player_diff := player.position - enemy.position
				if linalg.length(player_diff) <= activate_distance {
					enemy.state = .Alive_Active
				}
			case .Alive_Active:
				if uint(game.frame_counter) %% PATHFINDING_UPDATE_INTERVAL ==
				   enemy.pathfind_index {
					delete(enemy.path)
					enemy.path = TilePath(
						slice.clone(get_a_star_path(enemy.position, player.position)),
					)
				}
				sees_player := has_line_of_sight(enemy.position, player.position)
				line_color := sees_player ? set_alpha(rl.GREEN, 100) : set_alpha(rl.RED, 100)
				// for i in 0 ..< len(enemy.path) - 1 {
				// 	draw_debug_line(
				// 		get_tile_center(enemy.path[i]),
				// 		get_tile_center(enemy.path[i + 1]),
				// 		5,
				// 		line_color,
				// 	)
				// }
				player_sense_distance :: TILE_SIZE * 50
				target: vec2 = player.position
				// print_line_of_sight( enemy.position, player.position)
				if !sees_player && len(enemy.path) > 0 {
					epsilon :: 0.00001
					target = get_farthest_visible_point_in_path(
						enemy.position + epsilon,
						enemy.path,
					)
					// draw_debug_circle(target, color = set_alpha(rl.BLUE, 100), filled = false)
				}
				player_diff := player.position - enemy.position
				target_diff := target - enemy.position
				enemy_speed :: 200
				dist_to_player := linalg.length(player_diff)
				if dist_to_player > activate_distance {
					enemy.state = .Alive_Inactive
				} else if dist_to_player < player_sense_distance {
					if linalg.length(target_diff) < TILE_SIZE * 0.1 {
						enemy.inst_velocity = 0
					} else {
						enemy.inst_velocity = linalg.normalize(target_diff) * enemy_speed
					}
				} else {
					spawn_diff := enemy.spawn_point - enemy.position
					if linalg.length(spawn_diff) < TILE_SIZE * 0.1 {
						enemy.inst_velocity = 0
					} else {
						enemy.inst_velocity = linalg.normalize(spawn_diff) * enemy_speed
					}
				}
			case .Dead:
				hm.remove(&game.objects, h)
				if mouth, ok := enemy.mouth.?; ok {
					hm.remove(&game.objects, mouth)
				}
				if word_display, ok := enemy.word_display.?; ok {
					hm.remove(&game.objects, word_display)
				}
				rl.PlaySound(get_sound("augh.wav"))

			}
		}
	}
	timer->time("move enemies")
	{it := hm.make_iter(&game.objects)
		for enemy, h in all_objects_with_variant(&it, Enemy) {
			collisions, has_collisions := game.collisions[h]
			if !has_collisions {continue}
			for collision in collisions {
				if collision.type == .stop {continue}
				if other_handle, ok := collision.b.(GameObjectHandle); ok {
					other, ok := hm.get(&game.objects, other_handle)
					if !ok {continue} 	//e.g. deleted bullet
					#partial switch other.hitbox.layer {
					case .Enemy:
						circle_jostle_resolve(h, other_handle)
					case .Player:
						knockback_vec :=
							(other.position - enemy.position) * ENEMY_CONTACT_KNOCKBACK_STRENGTH
						player := other
						//take damage
						//TODO have player enter temp invincible state
						p := &player.variant.(Player)
						p.health -= 1
						rl.PlaySound(get_sound("hit.wav"))
						apply_knockback(knockback_vec, player)
						//did we just die?
						if p.health <= 0 {
							p.state = .Dead
						}
					}
				}
			}
		}
	}
	timer->time("resolve enemy collisions")
	{it := hm.make_iter(&game.objects)
		for e1, h1 in all_objects_with_variant(&it, Enemy) {
			it_inner := it
			for e2, h2 in all_objects_with_variant(&it_inner, Enemy) {
				if h1 == h2 {continue}
				if e1.state != .Alive_Active || e2.state != .Alive_Active {continue}
				ENEMY_REPULSION_STRENGTH :: 150000 // why does it need to be so high? maybe cause length squared is enormous?
				EPSILON_DIFF :: 0.01
				diff := e1.position - e2.position
				if diff == {0, 0} {
					//prevent div by 0
					diff = {EPSILON_DIFF, EPSILON_DIFF}
				}
				len2 := linalg.length2(diff)
				MIN_LENGTH :: EPSILON_DIFF
				MAX_LENGTH_FOR_REPULSION :: TILE_SIZE * 10
				if len2 > MAX_LENGTH_FOR_REPULSION * MAX_LENGTH_FOR_REPULSION {continue}
				if len2 < MIN_LENGTH * MIN_LENGTH {len2 = MIN_LENGTH} 	//prevent divide by almost zero yielding huge numbers
				e1.inst_velocity += dt * diff * ENEMY_REPULSION_STRENGTH / len2
				e2.inst_velocity -= dt * diff * ENEMY_REPULSION_STRENGTH / len2
			}
		}
	}
	timer->time("resolve enemy-enemy repulsion")
	// for _ in 0 ..< 500 {
	// 	p := random_point_in_circle(player.position, 10 * TILE_SIZE)
	// 	visible := has_line_of_sight( player.position, p)
	// 	lidar_points[next_lidar_point] = LidarPoint{p, visible}
	// 	next_lidar_point = (next_lidar_point + 1) %% NUM_LIDAR_POINTS
	// }
	// for p in lidar_points {
	// 	draw_debug_circle(p.p, 3, p.visible ? rl.WHITE : rl.RED)
	// }
	// TODO
	//timer->time("fire enemy bullets")
	//timer->time("enemy state machine updates")
	//timer->time("add consumables to inventory")
	//timer->time("room enter / clear / exit events")
	//timer->time("update player progress / save state (probably most of this happened in previous steps)")
	//timer->time("update player UI displays")
}

main_menu_update :: proc(dt: f64) {
	timer := timer()
	handle_ui_buttons()
	timer->time("handle buttons")
	cam.position += {30, 40} * dt
	if game.render_counter % 300 == 0 {
		cam.position = random_point_in_circle(game.player_spawn_point, TILE_SIZE * 10)
	}
}

EnemyType :: enum {
	Basic,
	Nerd,
	Indecisive,
	Killer,
	Raging,
	Wacky,
	Rhyming,
}
spawn_enemy :: proc(
	pos: vec2,
	enemy_type: EnemyType,
	target_word: string = "enemy",
) -> GameObjectHandle {
	body := GameObject {
		name = "enemy",
		transform = {position = pos, scale = {1, 1}, pivot = {64, 64}},
		tags = {.Enemy, .Collide, .Sprite},
		hitbox = {layer = .Enemy, box = {{-45, -45}, {45, 45}}}, //relative to object's pivot
		linear_drag = ENEMY_LINEAR_DRAG,
		render_layer = uint(RenderLayer.Enemy),
		target_word = target_word,
		current_string = "",
		word_properties = words.default_word_properties_enemy(),
		variant = Enemy {
			pos,
			.Alive_Inactive,
			enemy_type,
			rand.uint_range(0, PATHFINDING_UPDATE_INTERVAL),
			{},
		},
	}
	body.texture = atlas_textures[.Enemy_Face]
	body.color = rl.WHITE
	obj_name := "enemy"
	//TODO other stuff that varies per enemy type like different textures / animation states
	switch enemy_type {
	case .Basic:
		obj_name = "basic enemy"
	case .Nerd:
		obj_name = "nerd enemy"
	case .Indecisive:
		obj_name = "indecisive enemy"
	case .Killer:
		obj_name = "killer enemy"
	case .Raging:
		obj_name = "raging enemy"
	case .Wacky:
		obj_name = "wacky enemy"
	case .Rhyming:
		obj_name = "rhyming enemy"
	}
	body.name = fmt.aprint(obj_name, target_word)
	body_handle := spawn_object(body)
	mouth := GameObject {
		name = fmt.aprint(body.name, "mouth"),
		transform = {position = {-32, -9}, rotation = 0, scale = {0.5, 0.5}},
		color = rl.WHITE,
		texture = atlas_textures[.Mouth_Talk0],
		render_layer = uint(RenderLayer.Enemy) + 1,
		animation = initial_animation_state(make_animation(.Mouth_Talk, 8), paused = true),
		parent_handle = body_handle,
		tags = {.Sprite},
	}
	word := GameObject {
		name = "word display",
		transform = {scale = {1, 1}, pivot = {25, 0}, position = {0, -body.pivot.y}},
		current_string = "",
		render_layer = uint(RenderLayer.Ceiling) + 1,
		font = get_font(.Cmunit),
		target_word = target_word,
		parent_handle = body_handle,
		tags = {.Text},
		word_properties = words.default_word_properties_enemy(),
	}
	mouth_h := spawn_object(mouth)
	word_h := spawn_object(word)
	enemy := hm.get(&game.objects, body_handle)
	enemy.mouth = mouth_h
	enemy.word_display = word_h
	word_obj := hm.get(&game.objects, word_h)
	AVG_LETTER_WIDTH :: 20 * (1.25 / BASE_WINDOW_WIDTH)
	AVG_LETTER_HEIGHT :: 30 * (1.25 / BASE_WINDOW_WIDTH)
	word_obj.pivot.x = f64(len(enemy.target_word)) / 2 * AVG_LETTER_WIDTH
	word_obj.pivot.y = 5 + AVG_LETTER_HEIGHT / 2
	return body_handle
}

spawn_bullet :: proc(
	key: rl.KeyboardKey,
	pos, vel: vec2,
	layer: CollisionLayer,
) -> Maybe(GameObjectHandle) {
	idx, ok := key_to_texture_index(key).?
	if !ok {
		return nil
	}
	current_string := strings.to_lower(fmt.tprint(key))
	return spawn_bullet_from_string(current_string, pos, vel, layer)
}

spawn_bullet_from_string :: proc(
	str: string,
	pos, vel: vec2,
	layer: CollisionLayer,
) -> Maybe(GameObjectHandle) {
	idx, ok := string_to_texture_index(str).?
	if !ok {
		return nil
	}
	//shoot bullet
	tex := atlas_glyph_to_texture(atlas_fonts[BULLET_FONT][idx])
	tex_dims := (vec2{tex.rect.width, tex.rect.height} * (DEFAULT_FONT_SIZE)) / (ATLAS_FONT_SIZE)
	scale := vec2{0.12, 0.12}
	bullet := GameObject {
		name = fmt.aprint("bullet", str),
		transform = {
			position = pos,
			rotation = 0,
			scale = {0.2, 0.2},
			pivot = (tex_dims / 2) / scale,
		},
		render_info = {texture = tex, color = rl.WHITE, render_layer = uint(RenderLayer.Bullet)},
		velocity = vel,
		hitbox = {
			layer = layer,
			box = {min = (-tex_dims / 2) / scale, max = (tex_dims / 2) / scale},
		},
		tags = {.Bullet, .Collide, .Sprite},
		variant = Bullet{nil, .Alive},
		current_string = str,
	}
	h := spawn_object(bullet)
	return h
}

ButtonCallbackInfo :: struct {
	game:          ^Game,
	button:        GameObjectInst(UIButton),
	button_handle: GameObjectHandle,
}
spawn_button :: proc(
	pos: vec2,
	texture: TextureName, //TODO probably need to eventually supply hover / click animations
	text: string,
	on_click: proc(info: ButtonCallbackInfo),
) -> GameObjectHandle {
	tex := atlas_textures[texture]
	min_scale :: vec2{3, 0.9}
	button_obj := GameObject {
		name = fmt.aprint(text, "button"),
		current_string = text,
		transform = {
			position = pos,
			rotation = 0,
			scale = min_scale,
			pivot = vec2{tex.rect.width, tex.rect.height} / 2,
		},
		render_info = {
			texture = tex,
			color = rl.WHITE,
			render_layer = uint(RenderLayer.UI),
			text_render_info = {font_size = 72},
		},
		word_properties = {.display_current_string},
		tags = {.Sprite, .Text},
		variant = UIButton {
			min_scale = min_scale,
			max_scale = {min_scale.x * 1.3, min_scale.y},
			on_click = on_click,
		},
		parent_handle = game.screen_space_parent_handle,
	}
	return spawn_object(button_obj)
}

//TODO this is a crude way of doing it, should be more explicit based on font contents / game mechanics
key_to_texture_index :: proc(key: rl.KeyboardKey) -> Maybe(uint) {
	idx := int(key) - int('A')
	if idx >= 0 && idx < len(atlas_fonts[BULLET_FONT]) {
		return uint(idx)
	}
	return nil
}

string_to_texture_index :: proc(str: string) -> Maybe(uint) {
	idx := int(str[0]) - int('a')
	if idx >= 0 && idx < len(atlas_fonts[BULLET_FONT]) {
		return uint(idx)
	}
	return nil
}
atlas_glyph_to_texture :: proc(g: AtlasGlyph) -> AtlasTexture {
	return {rect = g.rect}
}

obj_to_circle :: proc(h: GameObjectHandle) -> Circle {
	obj := hm.get(&game.objects, h)
	return {pos = local_to_world(h, obj.pivot), radius = aabb_to_rect(obj.hitbox).width / 2}
}


//enforce circles do not penetrate by adding to velocity
circle_jostle_resolve :: proc(a, b: GameObjectHandle) {
	a_h, b_h := a, b
	a_c, b_c := obj_to_circle(a), obj_to_circle(b)
	if a_c.radius < b_c.radius {
		a_h, b_h = b, a
		a_c, b_c = b_c, a_c
	}
	assert(a_c.radius >= b_c.radius)
	diff := b_c.pos - a_c.pos
	if diff == {0, 0} {
		epsilon :: 0.0001
		diff.x += epsilon
	}
	dist := linalg.length(diff)
	sum_radii := abs(a_c.radius) + abs(b_c.radius)
	if sum_radii == 0 { 	//degenerate case - avoid div by zero
		return
	}
	overlap := sum_radii - dist
	if overlap <= 0 { 	//circles do not overlap
		return
	}
	diff_unit := linalg.normalize(diff)
	overlap_start := a_c.pos + diff_unit * b_c.radius
	overlap_end := overlap_start + diff_unit * overlap
	//assuming objects are equal density rigidbodies, correct resolution is to put them at a distance proportional to their radii along the overlap
	point_of_touch := math.lerp(overlap_start, overlap_end, (a_c.radius / sum_radii))
	//TODO(dry): helper function
	{
		c_new_pos := point_of_touch - diff_unit * a_c.radius
		pos_diff := c_new_pos - a_c.pos
		obj, ok := hm.get(&game.objects, a_h)
		obj.inst_velocity += -pos_diff
	}
	{
		c_new_pos := point_of_touch - diff_unit * b_c.radius
		pos_diff := c_new_pos - b_c.pos
		obj, ok := hm.get(&game.objects, b_h)
		obj.inst_velocity += -pos_diff
	}
}

handle_ui_buttons :: proc() {
	mouse_screen_pos := linalg.to_f64(rl.GetMousePosition())
	it := hm.make_iter(&game.objects)
	for button, button_handle in all_objects_with_variant(&it, UIButton) {
		screen_aabb := get_texture_aabb_for_object(
			button.obj,
			game.final_transforms[button_handle.idx].transform,
		)
		hovering := is_point_in_aabb(mouse_screen_pos, screen_aabb)
		scale_target := button.min_scale
		if hovering {
			scale_target = button.max_scale
		}
		button.scale *= 1 + (scale_target - button.scale) * 0.1
		// clicking := hovering && rl.IsMouseButtonDown(.LEFT)
		if hovering {
			button.color = BEE_YELLOW
			button.text_color = rl.BLACK
		} else {
			button.color = rl.BLACK
			button.text_color = BEE_YELLOW
		}
		click_confirmed := hovering && rl.IsMouseButtonReleased(.LEFT)
		if click_confirmed {
			button.on_click({game, button, button_handle})
		}
	}
}

apply_knockback :: proc(knockback: vec2, obj: ^GameObject) {
	obj.velocity += knockback
}
