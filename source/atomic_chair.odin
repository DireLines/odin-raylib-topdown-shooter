#+feature dynamic-literals
package game

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import hm "handle_map_static"
import maps "mapgen"
import rl "vendor:raylib"

//boilerplate / starter code for your game-specific logic in this engine
GAME_NAME :: "atomic chair"
MENU_BUTTON_SPACING :: 0.15
MENU_SCREEN_DIMS :: vec2{WINDOW_WIDTH, WINDOW_HEIGHT}
PLAYER_MAIN_COLOR :: rl.Color{99, 155, 255, 255}
BASIC_ENEMY_COLOR :: rl.Color{20, 205, 168, 255}
FLOOR_MAP_COLOR :: rl.Color{128, 128, 128, 255}
CHECKPOINT_COLOR :: rl.Color{100, 200, 100, 255}
STAT_BAR_UNFILLED_TICK_COLOR :: rl.Color{50, 50, 50, 255}
//speeds in world units per second
PLAYER_MAX_SPEED :: 40000
PLAYER_LINEAR_DRAG :: 5.0
PLAYER_BULLET_SPEED :: 1400
PLAYER_BULLET_FIRING_POSITION_OFFSET :: 15
ENEMY_BULLET_SPEED :: 500
BULLET_KNOCKBACK_STRENGTH :: 10
ENEMY_LINEAR_DRAG :: 5.0
ENEMY_CONTACT_KNOCKBACK_STRENGTH :: 20
PLAYER_BULLET_TEXTURE :: TextureName.Arrow_Right_Kenney_Board_Game_Icons_128px
INGAME_UI_PADDING :: 20.0

UI_MAIN_FONT_SIZE :: 72
UI_SECONDARY_FONT_SIZE :: 42

ChunkLoadingMode :: enum {
	Room,
	Proximity,
}
GameSpecificGlobalState :: struct {
	clicked_ui_object:  Maybe(GameObjectHandle),
	menu_state:         MenuState,
	menu_container:     GameObjectHandle,
	global_tilemap:     Tilemap `cbor:"-"`, //not serialized - too big
	chunk_loading_mode: ChunkLoadingMode,
	//we load the map immediately, but need to remember
	//where to spawn the player when the player object is spawned later
	player_spawn_point: vec2,
	player_handle:      GameObjectHandle,
	color_to_tiletype:  map[rl.Color]TileType,
	color_to_spawn:     map[rl.Color]SpawnType,
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
	CustomDraw, // if present, the renderer will call the custom draw function on this object
	DoNotSerialize, // if present, saving will not save this object
	DontDestroyOnLoad, // if present, loading will not reset or overwrite this object
	//user-defined tags
	Bullet,
	Player,
	Enemy,
	Checkpoint,
}

//types needed for tilemap
SpawnType :: enum {
	None,
	Player,
	Enemy,
	Checkpoint,
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
Health :: struct {
	health, max_health: int,
	health_bar:         GameObjectHandle,
}
Invuln :: struct {
	invulnerable:                           bool,
	invuln_cooldown, invuln_time_remaining: f64,
}

//object variants
//in contrast to tags, each object has exactly one variant
//GameObject has a field called `variant` which is this GameObjectVariant union type
//this is intended for mutually exclusive types of objects which need their own state fields
//for example, an enemy might need a max speed, state machine behavior, and an equipped weapon
//but those things will never apply to a collectible item
//so Enemy and Collectible can be two variants in the union
Player :: struct {
	using health_info:  Health,
	using invuln:       Invuln,
	state:              AliveDeadState,
	score:              int,
	score_label_handle: GameObjectHandle,
	current_chunk:      ChunkId,
}
Enemy :: struct {
	using health_info: Health,
	spawn_point:       vec2,
	state:             EnemyState,
	type:              EnemyType,
	pathfind_index:    uint,
	path:              TilePath,
}
Bullet :: struct {
	last_hit_object: Maybe(GameObjectHandle),
	state:           AliveDeadState,
}
UIButton :: struct {
	min_scale, max_scale: vec2,
	on_click_start:       proc(info: ButtonCallbackInfo) `cbor:"-"`, //triggered when mouse button down and hovering button
	on_click:             proc(info: ButtonCallbackInfo) `cbor:"-"`, //triggered when mouse button up and hovering button - most of the time this is what you want
}
UISlider :: struct {
	min_value, current_value, max_value, default_value: f64,
	left_pos, right_pos:                                f64, //screen coords, for display
	snap_increment:                                     f64, //0 = no snapping
	show_percentage:                                    bool,
	on_set_value:                                       proc(info: SliderCallbackInfo) `cbor:"-"`,
	handle_handle:                                      GameObjectHandle,
}
SliderCallbackInfo :: struct {
	game:          ^Game,
	slider:        GameObjectInst(UISlider),
	slider_handle: GameObjectHandle,
	new_value:     f64,
}

//a bar displaying the current value of a stat
UIStatBar :: struct {
	min_value, current_value, max_value: f64,
	disp_length, disp_height:            f64,
	filled_color, unfilled_color:        rl.Color,
	num_ticks:                           int,

	// the display behavior for the partially filled tick at the end
	incomplete_tick_display_mode:        enum {
		Exact, //fill exact fraction of the tick
		Round, //round to closest tick
		Ceil, //round to nearest tick above
		Floor, // round to nearest tick below
	},

	//if true, lerp the color of incomplete tick between filled_color and unfilled_color
	//if false, it will be filled_color
	interp_tick_color:                   bool,
}
default_ui_stat_bar :: proc() -> UIStatBar {
	return UIStatBar {
		disp_length = 100,
		disp_height = 20,
		filled_color = rl.GREEN,
		unfilled_color = rl.GRAY,
		num_ticks = 10,
		incomplete_tick_display_mode = .Exact,
		interp_tick_color = false,
	}
}
get_health_bar_def :: proc(h: Health) -> UIStatBar {
	bar := default_ui_stat_bar()
	bar.max_value = f64(h.max_health)
	bar.num_ticks = h.max_health
	bar.current_value = f64(h.health)
	bar.incomplete_tick_display_mode = .Ceil
	bar.interp_tick_color = true
	bar.unfilled_color = set_alpha(rl.RED, 120)
	return bar
}
DefaultVariant :: distinct struct{}
GameObjectVariant :: union {
	DefaultVariant,
	Player,
	Enemy,
	Bullet,
	UIButton,
	UISlider,
	UIStatBar,
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
	Player  = NUM_RENDER_LAYERS * 120.0 / 256,
	Bullet  = NUM_RENDER_LAYERS * 128.0 / 256,
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
	game.color_to_tiletype[rl.BLACK] = .Wall
	game.color_to_tiletype[FLOOR_MAP_COLOR] = .None
	game.color_to_spawn[PLAYER_MAIN_COLOR] = .Player
	game.color_to_spawn[BASIC_ENEMY_COLOR] = .Enemy
	game.color_to_spawn[CHECKPOINT_COLOR] = .Checkpoint
	load_map :: proc() -> (tilemap: Tilemap, player_spawn: TilemapTileId) {
		MAP_DATA :: #load("map.png")
		tiles_img := rl.LoadImageFromMemory(".png", raw_data(MAP_DATA), i32(len(MAP_DATA)))
		tiles_buf := maps.img_to_buf(tiles_img, transpose = true)
		color_to_tile :: proc(c: rl.Color) -> Tile {
			t := Tile{}
			tiletype, ok := game.color_to_tiletype[c]
			if ok {
				t.type = tiletype
			}
			spawntype, spawn_ok := game.color_to_spawn[c]
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
	titlebar_tex := atlas_textures[.Atomic_Chair_Title]
	sc := vec2{titlebar_tex.rect.width, titlebar_tex.rect.height} / 50
	titlebar_handle := spawn_object(
	GameObject {
		transform = {
			position = MENU_SCREEN_DIMS * {0.5, 0.1},
			pivot    = {60, 28.25}, //TODO it *SHOULD* be half the texture width, why is it this?
			scale    = sc,
		},
		parent_handle = game.screen_space_parent_handle,
		texture = titlebar_tex,
		render_layer = uint(RenderLayer.UI),
		color = rl.WHITE,
		tags = {.Sprite, .DoNotSerialize, .DontDestroyOnLoad},
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
	main_menu_objects := [dynamic]GameObjectHandle{play_button, titlebar_handle}
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
		GameObject {
			associated_objects = {"main_menu" = main_menu_objects},
			tags = {.DoNotSerialize, .DontDestroyOnLoad},
		},
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
			button.color = PLAYER_MAIN_COLOR
			button.text_color = rl.BLACK
		} else {
			button.color = rl.BLACK
			button.text_color = PLAYER_MAIN_COLOR
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
		handle := get_object(slider.handle_handle, UIButton)
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

spawn_player :: proc() -> GameObjectHandle {
	player_def := GameObject {
		name = "player",
		transform = {
			position = game.player_spawn_point,
			rotation = 0,
			scale = {1.4, 1.4},
			pivot = {64, 128},
		},
		linear_drag = PLAYER_LINEAR_DRAG,
		hitbox = {layer = .Player, shape = AABB{{-40, -60}, {40, 74}}}, //relative to object's pivot
		render_info = {
			color = rl.WHITE,
			texture = atlas_textures[.Squatman0],
			render_layer = uint(RenderLayer.Player),
			include_transparent_border = true,
			keep_original_dimensions = true,
		},
		animation = initial_animation_state(make_animation(.Squatman_Idle, 4)),
		tags = {.Player, .Collide, .Sprite},
		variant = Player{health = 6, max_health = 6, state = .Alive, invuln_cooldown = 1.0},
	}
	player_handle := spawn_object(player_def)
	player := get_object(player_handle, Player)
	{
		score_label := GameObject {
			name = "score label",
			transform = {
				position = {INGAME_UI_PADDING, INGAME_UI_PADDING},
				scale = {1, 1},
				pivot = {0, 0},
			},
			render_info = {
				color = rl.WHITE,
				render_layer = uint(RenderLayer.UI),
				text_render_info = {
					font_size = UI_SECONDARY_FONT_SIZE,
					text_color = PLAYER_MAIN_COLOR,
					text_alignment = .Left,
				},
			},
			tags = {.Text},
			parent_handle = game.screen_space_parent_handle,
		}
		player.score_label_handle = spawn_object(score_label)
	}
	{
		health_bar_def := get_health_bar_def(player.health_info)
		PLAYER_HEALTH_BAR_LENGTH :: 500
		health_bar_def.disp_length = PLAYER_HEALTH_BAR_LENGTH
		health_bar_def.disp_height = 30
		player.health_bar = spawn_ui_stat_bar(
			"player health",
			{WINDOW_WIDTH / 2 - PLAYER_HEALTH_BAR_LENGTH / 2, 10},
			game.screen_space_parent_handle,
			health_bar_def,
		)
	}
	return player_handle
}

atomic_chair_start :: proc() {
	game.paused = false
	game.chunk_loading_mode = .Proximity
	if game.player_handle.idx == 0 {
		//not loading from a file with a player in it
		game.player_handle = spawn_player()
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
	free(&menu_container_obj.associated_objects["pause_menu"])
}

//game-specific teardown / reset logic
reset_game :: proc(g: ^Game = game) {
	hm.clear(&g.objects)
	clear(&g.chunks)
	clear(&g.loaded_chunks)
	recreate_final_transforms(g)
	g.frame_counter = 0
	g.screen_space_parent_handle = spawn_object(GameObject{name = "screen space parent"})
	g.player_handle = {}
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
	player := get_object(game.player_handle, Player)
	{
		load_chunk :: proc(chunk: ChunkId) {
			tilemap := get_tilemap_chunk(chunk)
			min_corner, _ := get_tilemap_corners(chunk)
			for i in 0 ..< CHUNK_WIDTH_TILES {
				for j in 0 ..< CHUNK_HEIGHT_TILES {
					spawn_tile := min_corner + TilemapTileId{i, j}
					#partial switch tilemap[i][j].spawn {
					case .Enemy:
						for _ in 0 ..< 5 {
							pos := random_point_in_tile(spawn_tile)
							spawn_enemy(pos, .Basic)
						}
					case .Checkpoint:
						spawn_checkpoint(get_tile_center(spawn_tile))
					}
				}
			}
			print("loaded chunk", chunk, "on frame", game.frame_counter)
			game.loaded_chunks[chunk] = {}
		}
		switch game.chunk_loading_mode {
		case .Room:
			player_chunk := get_containing_chunk(player.position)
			if player_chunk not_in game.room_chunks {
				player.current_chunk = player_chunk
				delete(game.room_chunks)
				game.room_chunks = get_chunks_in_room(get_containing_tile(player.position))
				for chunk in game.room_chunks {
					if chunk not_in game.loaded_chunks {
						load_chunk(chunk)
					}
				}
			}
		case .Proximity:
			chunks_near_cam := get_chunks_near_cam(1)
			for chunk in chunks_near_cam {
				if chunk not_in game.loaded_chunks {
					load_chunk(chunk)
				}
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
		if player.invulnerable {return}
		player.health -= 1
		//did we just die?
		if player.health <= 0 {
			player.state = .Dead
			play_sound(get_sound("death.wav"))
			play_sound(get_sound("death2.wav"))
		} else {
			play_sound(get_sound("hit.wav"))
			player.invulnerable = true
			player.invuln_time_remaining = player.invuln_cooldown
		}
	}
	//player movement
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
		desired_anim_speed: uint = 5
		{
			if abs(pos_diff.x) > 0 {
				desired_anim_name = .Squatman_Run_Right
			} else {
				if pos_diff.y < 0 {
					desired_anim_name = .Squatman_Run_Up
					desired_anim_speed = 8
				} else if pos_diff.y > 0 {
					desired_anim_name = .Squatman_Run_Down
					desired_anim_speed = 8
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
		if player.invulnerable {
			player.invuln_time_remaining -= dt
			if int(f64(game.frame_counter) / 4) % 2 == 0 {
				player.shader = .SolidColor
			} else {
				player.shader = .None
			}
			if player.invuln_time_remaining <= 0 {
				player.invulnerable = false
				player.shader = .None
			}
		}
		if desired_anim_name != .Squatman_Idle {
			player.display_transform = Transform {
				position = 5 * {
						math.sin(f64(game.frame_counter) / 4),
						math.cos(f64(game.frame_counter) / 4),
					},
				rotation = 5 * math.sin(f64(game.frame_counter) / 4),
			}
		} else {
			player.display_transform = {}
			squish := f64(game.frame_counter) / 8
			player.display_transform.scale = {1, 1} + 0.02 * {math.sin(squish), -math.sin(squish)}
		}
		game.main_camera.position +=
			(player.position - game.main_camera.position) * CAM_LERP_AMOUNT
		timer->time("move player")
		mouse_pos := screen_to_world(linalg.to_f64(rl.GetMousePosition()), screen_conversion)
		if rl.IsMouseButtonPressed(.LEFT) {
			player_center := get_world_center(game.player_handle)
			bullet_diff := mouse_pos - player_center
			bullet_velocity :=
				linalg.normalize(bullet_diff) * PLAYER_BULLET_SPEED + player.velocity * 0.5
			firing_pos :=
				player_center -
				{0, 50} +
				linalg.normalize(bullet_velocity) * PLAYER_BULLET_FIRING_POSITION_OFFSET
			bullet_handle := spawn_bullet(firing_pos, bullet_velocity, layer = .PlayerBullet)
			play_sound(get_sound("light-fire.wav"))
		}
		timer->time("spawn bullets")
	case .Dead:
		player.velocity = 0
		if player.animation.anim.name != .Squatman_Dead {
			player.animation = initial_animation_state(
				make_animation(.Squatman_Dead, loop = false),
			)
		}
		if player.color.a < 20 {
			print("loading game")
			load_game(game, "save.cbor")
		}
		if (player.color.a - 2) < player.color.a {
			player.color.a -= 2
		}
	}
	should_save_game := false
	{
		player_collisions, has_collisions := game.collisions[game.player_handle]
		for collision in player_collisions {
			if collision.type != .start {continue}
			#partial switch other_handle in collision.b {
			case GameObjectHandle:
				other, ok := get_object(other_handle)
				if .Checkpoint in other.tags {
					should_save_game = true
				}
			}
		}
	}
	timer->time("check player collisions")
	//update score label
	{
		score_label := hm.get(&game.objects, player.score_label_handle)
		if player.score > 0 {
			delete(score_label.text)
			score_label.text = fmt.aprintf("Score: %d", player.score)
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
						case .Default:
							if .Checkpoint not_in other.tags {
								should_kill_bullet = true
							}
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
							player_take_damage(get_object(player, Player))
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
				enemy_speed :: 300
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
				squish := f64(game.frame_counter + u64(enemy.pathfind_index)) / 4
				enemy.display_transform.scale =
					vec2{1, 1} + 0.07 * vec2{math.sin(squish), -math.sin(squish)}
			case .Dead:
				hm.remove(&game.objects, h)
				hm.remove(&game.objects, enemy.health_bar)
				play_sound(get_sound("augh.wav"))
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
						player := get_object(other, Player)
						if player.state == .Alive {
							//take damage
							//TODO have player enter temp invincible state
							rl.PlaySound(get_sound("hit.wav"))
							apply_knockback(knockback_vec, player)
							player_take_damage(player)
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
	{it := hm.make_iter(&game.objects)
		update_health_bar :: proc(h: Health) {
			bar := get_object(h.health_bar, UIStatBar)
			bar.current_value = f64(h.health)
			bar.max_value = f64(h.max_health)
			bar.num_ticks = h.max_health
			if bar.current_value == bar.max_value {
				bar.tags -= {.CustomDraw}
			} else {
				bar.tags += {.CustomDraw}
			}
		}
		for enemy, h in all_objects_with_variant(&it, Enemy) {
			update_health_bar(enemy.health_info)
		}
		update_health_bar(player.health_info)
	}
	timer->time("update health bar displays")
	if should_save_game {
		save_game(game, "save.cbor")
		timer->time("save game")
	}
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
		tags = {.Sprite, .Text, .DoNotSerialize, .DontDestroyOnLoad},
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
	enemy_obj := GameObject {
		name = "enemy",
		transform = {position = pos, scale = {1, 1}, pivot = {64, 64}},
		tags = {.Enemy, .Collide, .Sprite},
		hitbox = {layer = .Enemy, shape = Circle{{0, 0}, 45}}, //relative to object's pivot
		linear_drag = ENEMY_LINEAR_DRAG,
		render_layer = uint(RenderLayer.Enemy),
		variant = Enemy {
			health_info = {health = 3, max_health = 3},
			spawn_point = pos,
			state = .Alive_Inactive,
			type = enemy_type,
			pathfind_index = rand.uint_range(0, PATHFINDING_UPDATE_INTERVAL),
		},
	}
	enemy_handle := spawn_object(enemy_obj)
	enemy := get_object(enemy_handle, Enemy)
	enemy.texture = atlas_textures[.Enemy_Face]
	enemy.color = rl.WHITE
	obj_name := "enemy"
	//TODO other stuff that varies per enemy type like different textures / animation states
	switch enemy_type {
	case .Basic:
		obj_name = "basic enemy"
	}
	enemy.name = fmt.aprint(obj_name)
	{
		health_bar_def := get_health_bar_def(enemy.health_info)
		enemy.health_bar = spawn_ui_stat_bar(
			fmt.aprint(obj_name, "health"),
			{-64, -70},
			enemy_handle,
			health_bar_def,
		)
	}
	return enemy_handle
}

spawn_bullet :: proc(pos, vel: vec2, layer: CollisionLayer) -> GameObjectHandle {
	//shoot bullet
	tex := atlas_textures[PLAYER_BULLET_TEXTURE]
	tex_dims := vec2{tex.rect.width, tex.rect.height}
	scale := vec2{0.24, 0.24}
	bullet := GameObject {
		name = fmt.aprint("bullet"),
		transform = {
			position = pos,
			rotation = math.to_degrees_f64(math.atan2(vel.y, vel.x)),
			scale = scale,
			pivot = (tex_dims / 2),
		},
		render_info = {texture = tex, color = rl.WHITE, render_layer = uint(RenderLayer.Bullet)},
		velocity = vel,
		hitbox = {layer = layer, shape = Circle{pos = {}, radius = tex_dims.x / 2}},
		tags = {.Bullet, .Collide, .Sprite},
		variant = Bullet{nil, .Alive},
	}
	return spawn_object(bullet)
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
		tags = {.Sprite, .Text, .DoNotSerialize, .DontDestroyOnLoad},
		variant = UIButton {
			min_scale = handle_scale,
			max_scale = {handle_scale.x, handle_scale.y},
			on_click_start = proc(info: ButtonCallbackInfo) {
				slider_handle := info.button.associated_objects["slider"].(GameObjectHandle)
				slider := get_object(slider_handle, UISlider)
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
		tags = {.Sprite, .DoNotSerialize, .DontDestroyOnLoad},
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
				text_color = PLAYER_MAIN_COLOR,
				text_alignment = .Right,
				font_size = UI_MAIN_FONT_SIZE,
			},
		},
		tags = {.Text, .DoNotSerialize, .DontDestroyOnLoad},
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

spawn_ui_stat_bar :: proc(
	name: string,
	pos: vec2,
	parent: Maybe(GameObjectHandle),
	stat_bar_info: UIStatBar,
) -> GameObjectHandle {
	return spawn_object(
		GameObject {
			name = fmt.aprint(name, "bar"),
			transform = {position = pos, scale = {1, 1}},
			render_info = {
				color = rl.WHITE,
				render_layer = uint(RenderLayer.UI),
				draw = draw_ui_stat_bar,
			},
			tags = {.CustomDraw},
			variant = stat_bar_info,
			parent_handle = parent,
		},
	)
}
draw_ui_stat_bar :: proc(bar: ^GameObject) {
	stat_bar := get_object(bar, UIStatBar)
	//for each tick, draw a rectangle
	frac_bar_filled :=
		(stat_bar.current_value - stat_bar.min_value) / (stat_bar.max_value - stat_bar.min_value)
	num_ticks_filled := int(math.floor(frac_bar_filled * f64(stat_bar.num_ticks)))
	tick_width := stat_bar.disp_length / f64(stat_bar.num_ticks)
	tick_height := stat_bar.disp_height
	transform := game.final_transforms[bar.handle.idx]
	top_left := mat_vec_mul(transform.transform, {0, 0})
	bottom_right := mat_vec_mul(transform.transform, {1, 1})
	if !transform.screen_space {
		top_left = world_to_screen(top_left, screen_conversion)
		bottom_right = world_to_screen(bottom_right, screen_conversion)
	}
	filled_color, unfilled_color := stat_bar.filled_color, stat_bar.unfilled_color
	for i in 0 ..< stat_bar.num_ticks {
		pos := vec2{top_left.x + f64(i) * tick_width, top_left.y}
		color := filled_color
		if i >= num_ticks_filled {
			color = unfilled_color
		}
		tick_disp_width := tick_width
		if i == num_ticks_filled {
			//handle partially filled tick
			single_tick_value :=
				(stat_bar.max_value - stat_bar.min_value) / f64(stat_bar.num_ticks)
			filled_ticks_total := f64(num_ticks_filled) * single_tick_value
			frac_incomplete_tick_filled :=
				(stat_bar.current_value - filled_ticks_total) / single_tick_value
			switch stat_bar.incomplete_tick_display_mode {
			case .Exact:
				tick_disp_width = tick_width * frac_incomplete_tick_filled
				color = filled_color
				//also display the unfilled remainder of the tick
				rl.DrawRectangle(
					i32(pos.x + tick_disp_width),
					i32(pos.y),
					i32(tick_width - tick_disp_width) + 1,
					i32(tick_height * (bottom_right - top_left).y),
					unfilled_color,
				)

			case .Round:
				color = frac_incomplete_tick_filled < 0.5 ? unfilled_color : filled_color
			case .Ceil:
				color = filled_color
			case .Floor:
				color = unfilled_color
			}
			if stat_bar.interp_tick_color {
				color = lerp_colors(unfilled_color, filled_color, frac_incomplete_tick_filled)
			}
		}
		rl.DrawRectangle(
			i32(pos.x),
			i32(pos.y),
			i32(tick_disp_width),
			i32(tick_height * (bottom_right - top_left).y),
			color,
		)
		//black lines between ticks to cover seams
		rl.DrawRectangle(
			i32(pos.x) - 1,
			i32(pos.y),
			3,
			i32(tick_height * (bottom_right - top_left).y),
			rl.BLACK,
		)
		if i == stat_bar.num_ticks - 1 {
			rl.DrawRectangle(
				i32(pos.x + tick_disp_width) - 1,
				i32(pos.y),
				3,
				i32(tick_height * (bottom_right - top_left).y),
				rl.BLACK,
			)
		}
	}
}


lerp_colors :: proc(a, b: rl.Color, t: f64) -> rl.Color {
	result: rl.Color
	#unroll for i in 0 ..< 4 {
		result[i] = u8(math.lerp(f64(a[i]), f64(b[i]), t))
	}
	return result
}

game_specific_load :: proc(game: ^Game = game, save: ^GameSave) {
	curr_global_tilemap := game.global_tilemap
	game.game_specific_state = save.game_specific_state
	game.global_tilemap = curr_global_tilemap

	//unfortunately save/load destroys function pointers, we need to replace the ones we care about
	//which is game-specific logic, so it must go here
	it := hm.make_iter(&game.objects)
	for obj, h in all_objects_with_variant(&it, UIStatBar) {
		obj.draw = draw_ui_stat_bar
	}
}


obj_to_circle :: proc(h: GameObjectHandle) -> Circle {
	obj := hm.get(&game.objects, h)
	circle: Circle
	switch shape in obj.hitbox.shape {
	case AABB:
		circle = {
			pos    = local_to_world(h, obj.pivot),
			radius = aabb_to_rect(shape).width / 2,
		}
	case Circle:
		circle = shape
	}
	return circle
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

spawn_checkpoint :: proc(pos: vec2) -> GameObjectHandle {
	CHECKPOINT_SIZE :: vec2{TILE_SIZE, TILE_SIZE}
	tex := atlas_textures[.White]
	checkpoint := GameObject {
		name = fmt.aprint("checkpoint"),
		transform = {position = pos, scale = {1, 1}, pivot = CHECKPOINT_SIZE / 2},
		render_info = {
			texture = tex,
			color = set_alpha(PLAYER_MAIN_COLOR, 100),
			render_layer = uint(RenderLayer.Ceiling),
		},
		hitbox = {shape = AABB{min = -CHECKPOINT_SIZE / 2, max = CHECKPOINT_SIZE / 2}},
		tags = {.Collide, .Sprite, .Checkpoint},
	}
	return spawn_object(checkpoint)
}
