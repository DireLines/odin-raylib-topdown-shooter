#+feature dynamic-literals
package game_main

import "core:fmt"
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
PLAYER_LINEAR_DRAG :: 5.0

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

//object variants
//in contrast to tags, each object has exactly one variant
//GameObject has a field called `variant` which is this GameObjectVariant union type
//this is intended for mutually exclusive types of objects which need their own state fields
//for example, an enemy might need a max speed, state machine behavior, and an equipped weapon
//but those things will never apply to a collectible item
//so Enemy and Collectible can be two variants in the union
DefaultVariant :: distinct struct{}
AliveDeadState :: enum {
	Alive,
	Dead,
}
Player :: struct {
	health: int,
	state:  AliveDeadState,
}
UIButton :: struct {
	min_scale, max_scale: vec2,
	on_click:             proc(info: ButtonCallbackInfo),
}
GameObjectVariant :: union {
	DefaultVariant,
	Player,
	UIButton,
}
GameSpecificProps :: struct {
	current_string:         string,
	display_current_string: bool,
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
		texture = atlas_textures[.None],
		render_layer = uint(RenderLayer.Floor),
		random_rotation = true,
	},
	.Wall = {
		collision = {layer = .Wall, resolve = true, trigger_events = true},
		texture = atlas_textures[.Rock],
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
	cam.position = game.player_spawn_point

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

atomic_chair_start :: proc() {
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
		tags = {.Player, .Collide, .Sprite},
		variant = Player{5, .Alive},
	}
	player_handle := spawn_object(player_def)
	game.player_handle = player_handle
	player := hm.get(&game.objects, player_handle)
}

//game-specific teardown / reset logic
reset_game :: proc() {}

//game-specific update logic (run once per frame)
game_update :: proc(dt: f64) {}


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
		display_current_string = true,
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
