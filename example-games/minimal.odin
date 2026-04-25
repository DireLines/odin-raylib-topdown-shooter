package game

//boilerplate / starter code for your game-specific logic in this engine
//note: this is a TEMPLATE file, made to give a starting point and modified from here
//for some example games, see the examples folder at the root of the repo

import hm "handle_map_static"
import rl "vendor:raylib"

GAME_NAME :: "my game"

//game-specific initialization logic (run once when game is started)
//typically this will be "set up the main menu"
game_start :: proc() {}

//game-specific update logic (run once per frame)
game_update :: proc(dt: f64) {}

//game-specific teardown / reset logic
game_reset :: proc(game: ^Game, total: bool = false) {}

//game-specific logic when loading from a save state
game_specific_load :: proc(game: ^Game = game, save: ^GameSave) {
	game.game_specific_state = save.game_specific_state

	//unfortunately save/load destroys function pointers, we need to replace the ones we care about
	//if you use function pointers, you must do that here
}

//these are embedded in the basic structs
//you can think of them as extending the types with what your game needs
//extending Game
GameSpecificGlobalState :: struct {}
//extending GameObject
GameSpecificObjectData :: struct {}
//extending Tile
GameSpecificTileData :: struct {}

//object variants
//in contrast to tags, each object has exactly one variant
//GameObject has a field called `variant` which is this GameObjectVariant union type
//this is intended for mutually exclusive types of objects which need their own state fields
//for example, an enemy might need a max speed, state machine behavior, and an equipped weapon
//but those things will never apply to a collectible item
//so Enemy and Collectible can be two variants in the union
DefaultVariant :: distinct struct{}
GameObjectVariant :: union {
	//engine provided variants
	DefaultVariant,
	UIButton,
	UISlider,
	UIStatBar,
	//game-specific variants
}

//object tags
//these are mostly game-specific boolean tags on objects
//GameObjects can have any set of these tags, encoded using a bit_set[ObjectTag] called `tags`
//bit_set is encoded in a 128-bit value, so the max number of tags is 128
ObjectTag :: enum {
	//engine-required tags
	Disabled, // if set, systems will skip object as if it has been deleted
	Collide, // if set, the collision system will consider this object in collisions
	Sprite, // if set, the renderer will draw the sprite / texture data of this object
	Text, // if set, the renderer will draw the text data of this object
	CustomDraw, // if set, the renderer will call the custom draw function on this object
	DoNotSerialize, // if set, saving will not save this object
	DontDestroyOnLoad, // if set, loading will not reset or overwrite this object
	//game-specific tags
}

//type constraints to check at runtime (outside of Odin's type system)
//these will be checked once per frame and print nice errors if violated
//checks are not very expensive but can be turned off with a flag for release builds
//for example, you might want to assert that no object ever has both of a pair of tags
//or that no objects with the DecorativeSprite variant are missing the Sprite tag
TYPE_ASSERTS := []GameObjectTypeAssert{}

//collision layers
//you may want some categories of objects to only collide with certain other categories
//instead of you providing logic inside each collision event to specifically ignore the ones you want,
//it's simpler and faster to have the collision detection logic not even generate the collision event
//to that end, you can define categories of objects which the collision system knows about
CollisionLayer :: enum {
	Default = 0,
}
//which collision layers can hit which others?
@(rodata)
COLLISION_MATRIX: [CollisionLayer]bit_set[CollisionLayer] = #partial {
	.Default = ~{}, //by default, collide with all layers
}

//named render layers
//a render layer is really just an index into an array of lists of object handles
//determining the order in which the game draws things
//lower indices are drawn first and so end up at the bottom
//to keep things consistent, I find it helpful to name some of these layers with what they represent in the game world
RenderLayer :: enum uint {
	Bottom  = 0,
	Floor   = NUM_RENDER_LAYERS * 50.0 / 256,
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
}
//properties of each type of tile
TILE_PROPERTIES := [TileType]TileTypeInfo {
	.None = {
		texture = atlas_textures[.None],
		render_layer = uint(RenderLayer.Floor),
		random_rotation = true,
	},
}

//this is the initial value loaded into the chunk
//for the current value of the tile, use get_tile
//called in load_tilemap_chunk
get_starting_tile :: proc(id: TilemapTileId) -> Tile {
	return Tile{}
}
