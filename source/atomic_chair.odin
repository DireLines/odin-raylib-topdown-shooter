#+feature dynamic-literals
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import hm "handle_map_static"
import maps "mapgen"
import rl "vendor:raylib"

//boilerplate / starter code for your game-specific logic in this engine
GAME_NAME :: "atomic chair"
MENU_BUTTON_SPACING :: 0.15
MENU_SCREEN_DIMS :: vec2{WINDOW_WIDTH, WINDOW_HEIGHT}
BEE_YELLOW :: rl.Color{246, 208, 58, 255}
BASIC_ENEMY_COLOR :: rl.Color{20, 205, 168, 255}
FLOOR_MAP_COLOR :: rl.Color{128, 128, 128, 255}
//speeds in world units per second
PLAYER_MAX_SPEED :: 40000
PLAYER_LINEAR_DRAG :: 5.0
PLAYER_BULLET_SPEED :: 1400
ENEMY_BULLET_SPEED :: 500
BULLET_KNOCKBACK_STRENGTH :: 10
ENEMY_LINEAR_DRAG :: 5.0
ENEMY_CONTACT_KNOCKBACK_STRENGTH :: 20

UI_MAIN_FONT_SIZE :: 72
UI_SECONDARY_FONT_SIZE :: 42

GameSpecificGlobalState :: struct {
	clicked_ui_object:  Maybe(GameObjectHandle),
	menu_state:         MenuState,
	menu_container:     GameObjectHandle,
	global_tilemap:     Tilemap,
	//we load the map immediately, but need to remember
	//where to spawn the player when the player object is spawned later
	player_spawn_point: vec2,
	player_handle:      GameObjectHandle,
	score_label_handle: GameObjectHandle,
}

//object tags
//these are mostly game-specific boolean tags on objects
//GameObjects can have any set of these tags, encoded using a bit_set[ObjectTag] called `tags`
//bit_set is encoded in a 128-bit value, so the max number of tags is 128
ObjectTag :: enum {
	//engine-required tags
	Collide, // if present, the collision system will consider this object in collisions
	Sprite, // if present, the renderer will draw the sprite / texture data of this object
	Text, // if present, the renderer will draw the text data of this object
	//user-defined tags
	Bullet,
	Player,
	Enemy,
}


//types needed in variants
AliveDeadState :: enum {
	Alive,
	Dead,
}
EnemyState :: enum {
	Alive_Inactive,
	Alive_Active,
	Dead,
}

//object variants
//in contrast to tags, each object has exactly one variant
//GameObject has a field called `variant` which is this GameObjectVariant union type
//this is intended for mutually exclusive types of objects which need their own state fields
//for example, an enemy might need a max speed, state machine behavior, and an equipped weapon
//but those things will never apply to a collectible item
//so Enemy and Collectible can be two variants in the union
Player :: struct {
	health: int,
	state:  AliveDeadState,
	score:  int,
}
Enemy :: struct {
	health:         int,
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
	on_click_start:       proc(info: ButtonCallbackInfo), //triggered when mouse button down and hovering button
	on_click:             proc(info: ButtonCallbackInfo), //triggered when mouse button up and hovering button - most of the time this is what you want
}
DefaultVariant :: distinct struct{}
GameObjectVariant :: union {
	DefaultVariant,
	Player,
	Enemy,
	Bullet,
	UIButton,
	UISlider,
}
GameSpecificProps :: struct {
	text: string,
}

//type constraints to check at runtime (outside of Odin's type system)
//these will be checked once per frame and print nice errors if violated
//checks are not very expensive but can be turned off with a flag for release builds
//for example, you might want to assert that no object ever has both of a pair of tags
//or that no objects with the DecorativeSprite variant are missing the Sprite tag
TYPE_ASSERTS := []GameObjectTypeAssert{TagCollisionLayerAssert{.Bullet, .Bullet, false, true}}

//collision layers
//you may want some categories of objects to only collide with certain other categories
//instead of you providing logic inside each collision event to specifically ignore the ones you want,
//it's simpler and faster to have the collision detection logic not even generate the collision event
//to that end, you can define categories of objects which the collision system knows about
CollisionLayer :: enum {
	Default = 0,
	Player,
	Enemy,
	Wall,
	Bullet,
	PlayerBullet,
	EnemyBullet,
}
//which collision layers can hit which others?
@(rodata)
COLLISION_MATRIX: [CollisionLayer]bit_set[CollisionLayer] = #partial {
	.Default      = ~{}, //by default, collide with all layers
	.Wall         = {.Player, .PlayerBullet, .Bullet, .Enemy, .EnemyBullet},
	.Player       = {.Wall, .Enemy, .EnemyBullet},
	.PlayerBullet = {.Enemy, .Wall},
	.Bullet       = {.Wall, .Player, .Enemy},
	.Enemy        = {.Wall, .Player, .PlayerBullet},
	.EnemyBullet  = {.Player, .Wall},
}

//named render layers
//a render layer is really just an index into an array of object handles
//determining the order in which the game draws things
//lower indices are drawn first and so end up at the bottom
//to keep things consistent, I find it helpful to name some of these layers with what they represent in the game world
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

//tilemap tiles are distinct from regular GameObjects in this engine
//this is because they are by far the most common type of object in practice
//so benefit more from some optimizations and simplifying assumptions
//unlike GameObjects, tiles in the tilemap
//1) are always static - they do not move, and collisions with them have
//2) are always located at a particular grid cell in the tilemap
//3) are identical to all other tiles of the same type
//   there is no tile-specific data at a particular spot in the grid
//   all that is stored is the tile type id
//types of tiles
TileType :: enum {
	None,
	Wall,
}
//properties of each type of tile
TILE_PROPERTIES := [TileType]TileTypeInfo {
	.None = {
		texture      = atlas_textures[.Block_Strong_Empty_Kenney_New_Platformer_Pack_1_1_Large],
		render_layer = uint(RenderLayer.Floor),
		color        = {128, 128, 128, 255},
		// random_rotation = true,
	},
	.Wall = {
		collision = {layer = .Wall, resolve = true, trigger_events = true},
		texture = atlas_textures[.Block_Green_Kenney_New_Platformer_Pack_1_1_Large],
		render_layer = uint(RenderLayer.Ceiling),
		wall_render_info = RenderInfo {
			texture = atlas_textures[.Darkrock],
			render_layer = uint(RenderLayer.Floor),
		},
	},
}

//I assume you want your game to have a main menu
//this keeps track of whether you are in the menu or in the game
MenuState :: enum {
	InGame,
	MainMenu,
}

//game-specific initialization logic (run once when game is started)
//typically this will be "set up the main menu"
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
	game.main_camera.position = game.player_spawn_point

	game.menu_state = .MainMenu
	main_menu_start()
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
			atomic_chair_start()
		},
	)
	//volume sliders
	slider_handles := spawn_vol_sliders()
	//TODO credits button
	main_menu_objects := [dynamic]GameObjectHandle{play_button, titlebar}
	for h in slider_handles {
		append(&main_menu_objects, h)
	}
	when ODIN_OS != .JS {
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
		append(&main_menu_objects, quit_button)
	}
	game.menu_container = spawn_object(
		GameObject{associated_objects = {"main_menu" = main_menu_objects}},
	)
}

main_menu_update :: proc(dt: f64) {
	timer := timer()
	handle_ui_buttons()
	handle_ui_sliders()
	timer->time("handle ui")
	game.main_camera.position += {30, 40} * dt
	if game.render_counter % 300 == 0 {
		game.main_camera.position = random_point_in_circle(game.player_spawn_point, TILE_SIZE * 10)
	}
}

handle_ui_buttons :: proc() {
	mouse_screen_pos := linalg.to_f64(rl.GetMousePosition())
	it := hm.make_iter(&game.objects)
	for button, button_handle in all_objects_with_variant(&it, UIButton) {
		if game.clicked_ui_object != nil && game.clicked_ui_object != button_handle {continue}
		screen_aabb := get_texture_aabb_for_object(
			button.obj,
			game.final_transforms[button_handle.idx].transform,
		)
		hovering := is_point_in_aabb(mouse_screen_pos, screen_aabb)
		//TODO skip this stuff if there is another active UI interaction such as being in the middle of a slider drag
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
		click_started := hovering && rl.IsMouseButtonPressed(.LEFT)
		if click_started && button.on_click_start != nil {
			button.on_click_start({game, button, button_handle})
		}
		click_released := hovering && rl.IsMouseButtonReleased(.LEFT)
		if click_released && button.on_click != nil {
			button.on_click({game, button, button_handle})
		}
	}
}

handle_ui_sliders :: proc() {
	mouse_screen_pos := linalg.to_f64(rl.GetMousePosition())
	it := hm.make_iter(&game.objects)
	for slider, slider_handle in all_objects_with_variant(&it, UISlider) {
		if game.clicked_ui_object != slider_handle {continue}
		handle := object_inst(slider.handle_handle, UIButton)
		frac := (mouse_screen_pos.x - slider.left_pos) / (slider.right_pos - slider.left_pos)
		frac = clamp(frac, 0, 1)
		val_target := slider.min_value + frac * (slider.max_value - slider.min_value)
		if slider.snap_increment > 0 {
			val_target = math.round(val_target / slider.snap_increment) * slider.snap_increment
			frac = (val_target - slider.min_value) / (slider.max_value - slider.min_value)
		}
		handle.position.x = slider.left_pos + frac * (slider.right_pos - slider.left_pos)
		handle.text = get_slider_handle_text(frac, val_target, slider.show_percentage)
		if rl.IsMouseButtonReleased(.LEFT) {
			game.clicked_ui_object = nil
			new_value_frac :=
				(handle.position.x - slider.left_pos) / (slider.right_pos - slider.left_pos)
			new_value := slider.min_value + new_value_frac * (slider.max_value - slider.min_value)
			slider.on_set_value(
				SliderCallbackInfo {
					game = game,
					slider = slider,
					slider_handle = slider_handle,
					new_value = new_value,
				},
			)
		}
	}
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


atomic_chair_start :: proc() {
	game.paused = false
	//spawn player
	player_def := GameObject {
		name = "player",
		transform = {
			position = game.player_spawn_point,
			rotation = 0,
			scale = {1.4, 1.4},
			pivot = {64, 64},
		},
		linear_drag = PLAYER_LINEAR_DRAG,
		hitbox = {layer = .Player, box = {{-29, -45}, {29, 44}}}, //relative to object's pivot
		render_info = {
			color = rl.WHITE,
			texture = atlas_textures[.Squatman0],
			render_layer = uint(RenderLayer.Player),
			include_transparent_border = true,
			keep_original_dimensions = true,
		},
		animation = initial_animation_state(make_animation(.Squatman_Idle, 3)),
		tags = {.Player, .Collide, .Sprite},
		variant = Player{5, .Alive, 0},
	}
	player_handle := spawn_object(player_def)
	game.player_handle = player_handle
	player := hm.get(&game.objects, player_handle)

	SCORE_PADDING :: 20.0
	score_label := GameObject {
		name = "score label",
		transform = {position = {SCORE_PADDING, SCORE_PADDING}, scale = {1, 1}, pivot = {0, 0}},
		render_info = {
			color = rl.WHITE,
			render_layer = uint(RenderLayer.UI),
			text_render_info = {
				font_size = UI_SECONDARY_FONT_SIZE,
				text_color = BEE_YELLOW,
				text_alignment = .Left,
			},
		},
		tags = {.Text},
		parent_handle = game.screen_space_parent_handle,
	}
	game.score_label_handle = spawn_object(score_label)
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
	//volume sliders
	slider_handles := spawn_vol_sliders()
	main_menu_button := spawn_button(
		MENU_SCREEN_DIMS * {0.5, 0.1 + MENU_BUTTON_SPACING * 4},
		.White,
		"QUIT",
		proc(info: ButtonCallbackInfo) {
			game := info.game
			pause_menu_stop()
			atomic_chair_stop()
			game.menu_state = .MainMenu
			main_menu_start()
		},
	)
	pause_menu_objects := [dynamic]GameObjectHandle{resume_button, main_menu_button}
	for h in slider_handles {
		append(&pause_menu_objects, h)
	}
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

//game-specific teardown / reset logic
reset_game :: proc() {
	hm.clear(&game.objects)
	clear(&game.chunks)
	clear(&game.loaded_chunks)
	recreate_final_transforms()
	game.frame_counter = 0
	game.screen_space_parent_handle = spawn_object(GameObject{name = "screen space parent"})
}

//game-specific update logic (run once per frame)
game_update :: proc(dt: f64) {
	switch game.menu_state {
	case .InGame:
		atomic_chair_update(dt)
	case .MainMenu:
		main_menu_update(dt)
	}
}

atomic_chair_update :: proc(dt: f64) {
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
	handle_ui_sliders()
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
								spawn_enemy(pos, .Basic)
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
	player_take_damage :: proc(player: GameObjectInst(Player)) {
		p := &player.variant.(Player)
		p.health -= 1
		//did we just die?
		if p.health <= 0 {
			p.state = .Dead
			play_sound(get_sound("death.wav"))
			play_sound(get_sound("death2.wav"))
		} else {
			play_sound(get_sound("hit.wav"))
		}
	}
	//player movement
	player := object_inst(game.player_handle, Player)
	// player.shader = .SolidColor
	switch player.variant.(Player).state {
	case .Alive:
		pos_diff := vec2{get_axis(.A, .D), get_axis(.W, .S)} * PLAYER_MAX_SPEED
		//flip if needed
		if pos_diff.x != 0 && math.sign(pos_diff.x) != math.sign(player.scale.x) {
			player.scale.x *= -1
		}
		//move in that direction
		player.inst_velocity = pos_diff * PLAYER_MAX_SPEED * dt
		if linalg.length(player.inst_velocity) > PLAYER_MAX_SPEED * dt {
			player.inst_velocity = linalg.normalize(player.inst_velocity) * PLAYER_MAX_SPEED * dt
		}
		// player.acceleration = movement_vec * multiplier
		CAM_LERP_AMOUNT :: 0.15
		// TODO why is this so nauseating when the player starts/stops moving?
		// //lerp cam to position ahead of player
		// CAM_LEAD :: 0.3
		// cam_target := player.position + player.velocity * CAM_LEAD
		// cam.position += (cam_target - cam.position) * CAM_LERP_AMOUNT
		desired_anim_name: AnimationName
		desired_anim_speed: uint = 4
		{
			if abs(pos_diff.x) > 0 {
				desired_anim_name = .Squatman_Run_Right
			} else {
				if pos_diff.y < 0 {
					desired_anim_name = .Squatman_Run_Up
					desired_anim_speed = 6
				} else if pos_diff.y > 0 {
					desired_anim_name = .Squatman_Run_Down
					desired_anim_speed = 6
				} else {
					desired_anim_name = .Squatman_Idle
				}
			}
		}
		if desired_anim_name != player.animation.anim.name {
			player.animation = initial_animation_state(
				make_animation(desired_anim_name, desired_anim_speed),
			)
		}
		if rl.IsKeyPressed(.R) {
			player_take_damage(object_inst(player, Player))
		}
		game.main_camera.position +=
			(player.position - game.main_camera.position) * CAM_LERP_AMOUNT
		timer->time("move player")
		mouse_pos := screen_to_world(linalg.to_f64(rl.GetMousePosition()), screen_conversion)
		if rl.IsMouseButtonPressed(.LEFT) {
			firing_pos := get_world_center(game.player_handle)
			bullet_diff := mouse_pos - firing_pos
			bullet_velocity :=
				linalg.normalize(bullet_diff) * PLAYER_BULLET_SPEED + player.velocity * 0.5
			bullet_fired := false
			bullet_handle := spawn_bullet(firing_pos, bullet_velocity, layer = .PlayerBullet)
			if bullet_handle != nil {
				bullet_fired = true
				play_sound(get_sound("light-fire.wav"))
			}
		}
		timer->time("spawn bullets")
	case .Dead:
		player.velocity = 0
		if player.animation.anim.name != .Squatman_Dead {
			player.animation = initial_animation_state(
				make_animation(.Squatman_Dead, loop = false),
			)
		}
		if (player.color.a - 2) < player.color.a {
			player.color.a -= 2
		}
	}
	//update score label
	{
		score_label := hm.get(&game.objects, game.score_label_handle)
		if player.score > 0 {
			score_label.text = fmt.tprintf("Score: %d", player.score)
		} else {
			score_label.text = ""
		}
	}
	{it := hm.make_iter(&game.objects)
		for bullet, bullet_handle in all_objects_with_variant(&it, Bullet) {
			switch bullet.state {
			case .Alive:
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
							should_kill_bullet = true
							enemy := other
							e := &enemy.variant.(Enemy)
							e.health -= 1
							apply_knockback(knockback_vec, enemy)
							play_sound(get_sound("death.wav"), 0.3)
							//did we just kill?
							if e.health <= 0 {
								e.state = .Dead
								player.score += 1
							}
						case .Player:
							should_kill_bullet = true
							player := other
							//take damage
							apply_knockback(knockback_vec, player)
							play_sound(get_sound("hit.wav"))
							player_take_damage(object_inst(player, Player))
						case:
							should_kill_bullet = true
						}
					case TilemapTileId:
						should_kill_bullet = true
						tile := get_tile(other_handle)
						#partial switch TILE_PROPERTIES[tile.type].layer {
						}
						play_sound(get_sound("hit-dud.wav"))
					}
					if should_kill_bullet {break}
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
			case .Dead:
				hm.remove(&game.objects, h)
				play_sound(get_sound("augh.wav"))
			}
		}
	}
	timer->time("move enemies")
}

atomic_chair_stop :: proc() {
	//TODO save progress
	reset_game()
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
		text = text,
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
			text_render_info = {font_size = UI_MAIN_FONT_SIZE},
		},
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


EnemyType :: enum {
	Basic,
}
spawn_enemy :: proc(pos: vec2, enemy_type: EnemyType) -> GameObjectHandle {
	enemy := GameObject {
		name = "enemy",
		transform = {position = pos, scale = {1, 1}, pivot = {64, 64}},
		tags = {.Enemy, .Collide, .Sprite},
		hitbox = {layer = .Enemy, box = {{-45, -45}, {45, 45}}}, //relative to object's pivot
		linear_drag = ENEMY_LINEAR_DRAG,
		render_layer = uint(RenderLayer.Enemy),
		variant = Enemy {
			3,
			pos,
			.Alive_Inactive,
			enemy_type,
			rand.uint_range(0, PATHFINDING_UPDATE_INTERVAL),
			{},
		},
	}
	enemy.texture = atlas_textures[.Enemy_Face]
	enemy.color = rl.WHITE
	obj_name := "enemy"
	//TODO other stuff that varies per enemy type like different textures / animation states
	switch enemy_type {
	case .Basic:
		obj_name = "basic enemy"
	}
	enemy.name = fmt.aprint(obj_name)
	enemy_handle := spawn_object(enemy)
	AVG_LETTER_WIDTH :: 20 * (1.25 / BASE_WINDOW_WIDTH)
	AVG_LETTER_HEIGHT :: 30 * (1.25 / BASE_WINDOW_WIDTH)
	return enemy_handle
}

spawn_bullet :: proc(pos, vel: vec2, layer: CollisionLayer) -> Maybe(GameObjectHandle) {
	//shoot bullet
	tex := atlas_textures[.White]
	tex_dims := vec2{tex.rect.width, tex.rect.height}
	scale := vec2{0.24, 0.24}
	bullet := GameObject {
		name = fmt.aprint("bullet"),
		transform = {position = pos, rotation = 0, scale = scale, pivot = (tex_dims / 2)},
		render_info = {texture = tex, color = rl.WHITE, render_layer = uint(RenderLayer.Bullet)},
		velocity = vel,
		hitbox = {layer = layer, box = {min = -(tex_dims / 2), max = tex_dims / 2}},
		tags = {.Bullet, .Collide, .Sprite},
		variant = Bullet{nil, .Alive},
	}
	h := spawn_object(bullet)
	return h
}

get_axis :: proc(key_neg, key_pos: rl.KeyboardKey) -> f64 {
	return f64(int(rl.IsKeyDown(key_pos))) - f64(int(rl.IsKeyDown(key_neg)))
}

apply_knockback :: proc(knockback: vec2, obj: ^GameObject) {
	obj.velocity += knockback
}

play_sound :: proc(sound: rl.Sound, volume: f32 = 1) {
	rl.SetSoundVolume(sound, volume)
	rl.PlaySound(sound)
}

UISlider :: struct {
	min_value, current_value, max_value, default_value: f64,
	left_pos, right_pos:                                f64, //screen coords, for display
	snap_increment:                                     f64, //0 = no snapping
	show_percentage:                                    bool,
	on_set_value:                                       proc(info: SliderCallbackInfo),
	handle_handle:                                      GameObjectHandle,
}
SliderCallbackInfo :: struct {
	game:          ^Game,
	slider:        GameObjectInst(UISlider),
	slider_handle: GameObjectHandle,
	new_value:     f64,
}

get_slider_handle_text :: proc(frac, val: f64, show_percentage: bool = false) -> string {
	return(
		show_percentage ? fmt.aprintf("%d", int(math.round(frac * 100))) : fmt.aprintf("%.2f", val) \
	)
}
spawn_ui_slider :: proc(
	pos: vec2,
	handle_texture: TextureName,
	text: string,
	slider_info: UISlider,
) -> (
	slider_handle, handle_handle, label_handle: GameObjectHandle,
) {

	handle_tex := atlas_textures[handle_texture]
	handle_scale := vec2{0.7, 0.4}
	default_frac :=
		(slider_info.default_value - slider_info.min_value) /
		(slider_info.max_value - slider_info.min_value)
	handle_x :=
		slider_info.left_pos + default_frac * (slider_info.right_pos - slider_info.left_pos)
	handle_def := GameObject {
		name = fmt.aprint(text, "slider handle"),
		text = get_slider_handle_text(
			default_frac,
			slider_info.default_value,
			slider_info.show_percentage,
		),
		transform = {
			position = {handle_x, pos.y},
			rotation = 0,
			scale = handle_scale,
			pivot = vec2{handle_tex.rect.width, handle_tex.rect.height} / 2,
		},
		render_info = {
			texture = handle_tex,
			color = rl.WHITE,
			render_layer = uint(RenderLayer.UI),
			text_render_info = {font_size = UI_SECONDARY_FONT_SIZE, text_color = rl.BLACK},
		},
		tags = {.Sprite, .Text},
		variant = UIButton {
			min_scale = handle_scale,
			max_scale = {handle_scale.x, handle_scale.y},
			on_click_start = proc(info: ButtonCallbackInfo) {
				slider_handle := info.button.associated_objects["slider"].(GameObjectHandle)
				slider := object_inst(slider_handle, UISlider)
				game.clicked_ui_object = slider_handle
			},
		},
		parent_handle = game.screen_space_parent_handle,
	}
	slider_info := slider_info
	handle_object: ^GameObject
	slider_info.handle_handle, handle_object = spawn_and_return_object(handle_def)
	track_tex := atlas_textures[.White]
	track_width := slider_info.right_pos - slider_info.left_pos
	track_scale := vec2{track_width / f64(track_tex.rect.width), 10.0 / f64(track_tex.rect.height)}
	slider_def := GameObject {
		name = fmt.aprint(text, "slider"),
		transform = {
			position = pos,
			rotation = 0,
			scale = track_scale,
			pivot = vec2{f64(track_tex.rect.width), f64(track_tex.rect.height)} / 2,
		},
		render_info = {
			texture = track_tex,
			color = {255, 255, 255, 100},
			render_layer = uint(RenderLayer.UI) - 1,
		},
		tags = {.Sprite},
		parent_handle = game.screen_space_parent_handle,
		variant = slider_info,
	}
	slider_object: ^GameObject
	slider_handle, slider_object = spawn_and_return_object(slider_def)
	handle_object.associated_objects["slider"] = slider_handle
	LABEL_PIXEL_PADDING :: 50
	label_def := GameObject {
		name = fmt.aprint(text, "slider label"),
		text = text,
		transform = {
			position = {slider_info.left_pos - LABEL_PIXEL_PADDING, pos.y},
			scale = {1, 1},
			pivot = {0, 0},
		},
		render_info = {
			color = rl.WHITE,
			render_layer = uint(RenderLayer.UI),
			text_render_info = {
				text_color = BEE_YELLOW,
				text_alignment = .Right,
				font_size = UI_MAIN_FONT_SIZE,
			},
		},
		tags = {.Text},
		parent_handle = game.screen_space_parent_handle,
	}
	label_handle = spawn_object(label_def)
	return slider_handle, slider_info.handle_handle, label_handle
}

spawn_vol_sliders :: proc() -> [6]GameObjectHandle {
	master_vol_slider, master_vol_handle, master_vol_label := spawn_ui_slider(
		MENU_SCREEN_DIMS * {0.5, 0.1 + MENU_BUTTON_SPACING * 2.75},
		.White,
		"VOL",
		UISlider {
			min_value = 0,
			max_value = 2,
			snap_increment = 0.2,
			show_percentage = true,
			default_value = f64(rl.GetMasterVolume()),
			current_value = f64(rl.GetMasterVolume()),
			left_pos = MENU_SCREEN_DIMS.x * 0.5 - 250,
			right_pos = MENU_SCREEN_DIMS.x * 0.5 + 250,
			on_set_value = proc(info: SliderCallbackInfo) {
				rl.SetMasterVolume(f32(info.new_value))
				rl.PlaySound(get_sound("hit.wav"))
			},
		},
	)
	music_vol_slider, music_vol_handle, music_vol_label := spawn_ui_slider(
	MENU_SCREEN_DIMS * {0.5, 0.1 + MENU_BUTTON_SPACING * 3.25},
	.White,
	"MUSIC",
	UISlider {
		min_value = 0,
		max_value = 2,
		snap_increment = 0.2,
		show_percentage = true,
		//TODO use rl.SetMusicVolume() on global music object
		left_pos = MENU_SCREEN_DIMS.x * 0.5 - 250,
		right_pos = MENU_SCREEN_DIMS.x * 0.5 + 250,
		on_set_value = proc(info: SliderCallbackInfo) {},
	},
	)
	return [6]GameObjectHandle {
		master_vol_slider,
		master_vol_handle,
		master_vol_label,
		music_vol_slider,
		music_vol_handle,
		music_vol_label,
	}
}
