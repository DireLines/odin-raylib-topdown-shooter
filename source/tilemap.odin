package game
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import maps "mapgen"
import rl "vendor:raylib"

TilemapTileId :: distinct [2]int //TODO: TileId name is in use by atlas.odin, investigate the intended way to generate tilemaps there
CardinalDirection :: enum {
	North,
	East,
	South,
	West,
}
Tile :: struct {
	type:     TileType, //what type of tile is here?
	spawn:    SpawnType, //what kind of stuff spawns here on chunk load?
	rotation: CardinalDirection, //only used for display
}

TilemapChunk :: [CHUNK_WIDTH_TILES][CHUNK_HEIGHT_TILES]Tile
Tilemap :: [][]Tile

//allows texture to render conditional on what textures are near it
TileNeighborType :: enum {
	None,
	One,
	Two_Adjacent,
	Two_Opposing,
	Three,
	All,
}
//allows texture to render with one of several choices, weighted by chance
TextureDistribution :: []struct {
	texture: TextureName,
	chance:  f32,
}
TileTypeInfo :: struct {
	using collision:   CollisionProperties,
	using render_info: RenderInfo,
	wall_render_info:  Maybe(RenderInfo),
	random_rotation:   bool,
}

get_tilemap_chunk :: proc(id: ChunkId) -> ^TilemapChunk {
	if id in game.tilemap_chunks {
		return &game.tilemap_chunks[id]
	}
	game.tilemap_chunks[id] = load_tilemap_chunk(id)
	return &game.tilemap_chunks[id]
}
@(private = "file")
load_tilemap_chunk :: proc(id: ChunkId) -> (tilemap: TilemapChunk) {
	min_corner, _ := get_tilemap_corners(id)
	map_slice := maps.slice_rect_from_slice(
		&game.global_tilemap,
		{
			uint(min_corner.x %% len(game.global_tilemap)),
			uint(min_corner.y %% len(game.global_tilemap[0])),
			CHUNK_WIDTH_TILES,
			CHUNK_HEIGHT_TILES,
		},
	)
	for i in 0 ..< CHUNK_WIDTH_TILES {
		for j in 0 ..< CHUNK_HEIGHT_TILES {
			tilemap[i][j] = map_slice[i][j]
		}
	}
	return tilemap
}
unload_tilemap_chunk :: proc(id: ChunkId) {
	delete_key(&game.tilemap_chunks, id)
}
// Flood-fills the tilemap starting from the tile at player_pos, stopping at
// Wall tiles, and returns the set of every chunk that contains a reached tile.
// Uses the temp allocator internally; the returned map uses the default allocator.
get_chunks_in_room :: proc(start_tile: TilemapTileId) -> map[ChunkId]struct{} {
	visited := make(map[TilemapTileId]struct{}, allocator = context.temp_allocator)
	queue := make([dynamic]TilemapTileId, allocator = context.temp_allocator)
	chunks := make(map[ChunkId]struct{})

	if get_tile(start_tile).type == .Wall {
		return chunks
	}

	append(&queue, start_tile)
	visited[start_tile] = {}

	MAX_TILES :: 1000000
	head := 0
	for head < len(queue) {
		if head >= MAX_TILES {
			print("hit tile limit")
			break
		}
		tile := queue[head]
		head += 1

		chunks[get_containing_chunk_for_tile(tile)] = {}

		for neighbor in get_neighbors(tile) {
			if neighbor in visited {
				continue
			}
			visited[neighbor] = {}
			if get_tile(neighbor).type != .Wall {
				append(&queue, neighbor)
			}
		}
	}

	return chunks
}

get_tile :: proc(id: TilemapTileId) -> Tile {
	//TODO cannot assume the tilemap generates quickly enough to hang on loading in any particular frame
	// this should already be loaded by a chunk loader/unloader process
	// when that's done, put back this warning
	// print("tried to read tile", id, "from chunk", chunk_id, "but chunk not loaded in tilemap")
	tilemap := get_tilemap_chunk(get_containing_chunk_for_tile(id))
	return tilemap[id.x %% CHUNK_WIDTH_TILES][id.y %% CHUNK_HEIGHT_TILES]
}

get_neighbors :: proc(id: TilemapTileId) -> [4]TilemapTileId {
	return {{id.x, id.y + 1}, {id.x, id.y - 1}, {id.x + 1, id.y}, {id.x - 1, id.y}}
}
is_surrounded_by_same_tile :: proc(id: TilemapTileId) -> bool {
	t := get_tile(id)
	neighbors := get_neighbors(id)
	#unroll for i in 0 ..< 4 {
		neighbor := get_tile(neighbors[i])
		if neighbor.type != t.type {
			return false
		}
	}
	return true
}

get_tile_aabb :: proc(id: TilemapTileId) -> AABB {
	top_left := vec2{f64(id.x) * TILE_SIZE, f64(id.y) * TILE_SIZE}
	return {top_left, top_left + TILE_SIZE}
}

get_containing_tile :: proc(p: vec2) -> TilemapTileId {
	return {int(math.floor(p.x / TILE_SIZE)), int(math.floor(p.y / TILE_SIZE))}
}


TilemapIterator :: struct {
	min, max: TilemapTileId,
	curr:     TilemapTileId,
}
make_tilemap_iterator :: proc(a, b: TilemapTileId) -> TilemapIterator {
	min: TilemapTileId = linalg.min(a, b)
	max: TilemapTileId = linalg.max(a, b)
	return {min = min, max = max, curr = min}
}
tilemap_iter :: proc(it: ^TilemapIterator) -> (val: TilemapTileId, has_next: bool) {
	if it.curr.y > it.max.y {
		return
	}
	val = it.curr
	has_next = true
	it.curr.x += 1
	if it.curr.x > it.max.x {
		it.curr.x = it.min.x
		it.curr.y += 1
	}
	return
}

get_tiles_between :: proc(a, b: TilemapTileId) -> []TilemapTileId {
	result := [dynamic]TilemapTileId{}
	it := make_tilemap_iterator(a, b)
	for tile in tilemap_iter(&it) {
		append(&result, tile)
	}
	return result[:]
}

get_tilemap_corners_chunk :: proc(id: ChunkId) -> (min, max: TilemapTileId) {
	return get_tilemap_corners_aabb(get_chunk_aabb(id))
}
get_tilemap_corners_aabb :: proc(aabb: AABB) -> (min, max: TilemapTileId) {
	return get_containing_tile(aabb.min), get_containing_tile(aabb.max)
}

get_tilemap_corners_tile_list :: proc(
	tiles: []TilemapTileId,
) -> (
	min_corner, max_corner: TilemapTileId,
) {
	if len(tiles) == 0 {
		return
	}
	min_corner = tiles[0]
	max_corner = tiles[0]
	for tile in tiles {
		min_corner = linalg.min(tile, min_corner)
		max_corner = linalg.max(tile, max_corner)
	}
	return min_corner, max_corner
}
get_tile_center :: proc(id: TilemapTileId) -> vec2 {
	aabb := get_tile_aabb(id)
	return (aabb.min + aabb.max) / 2
}
get_tilemap_corners :: proc {
	get_tilemap_corners_chunk,
	get_tilemap_corners_aabb,
	get_tilemap_corners_tile_list,
}

img_to_tilemap :: proc(
	img: [][]rl.Color,
	color_to_tile: proc(c: rl.Color) -> Tile,
) -> (
	tilemap: Tilemap,
	player_spawn: TilemapTileId,
) {
	w, h := len(img[0]), len(img)
	tiles := maps.make_grid_slice(Tile, w, h)
	for r in 0 ..< h {
		for c in 0 ..< w {
			tile := color_to_tile(img[r][c])
			props := TILE_PROPERTIES[tile.type]
			tile.rotation = .North
			if props.random_rotation {
				tile.rotation = rand.choice_enum(CardinalDirection)
			}
			if tile.spawn == .Player {
				player_spawn = TilemapTileId{r, c}
			}
			tiles[r][c] = tile
		}
	}
	return tiles, player_spawn
}
