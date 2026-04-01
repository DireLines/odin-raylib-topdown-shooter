package game
import "core:encoding/cbor"
import "core:os"
import "core:slice"
import "core:strings"
import hm "handle_map_static"
import rl "vendor:raylib"
//loading/saving assets

SOUNDS_DIR := #load_directory("sounds")
get_sound :: proc(name: string, file_extension: string = ".wav") -> rl.Sound {
	if name in game.sounds {
		return game.sounds[name]
	}
	return load_sound(name, file_extension)
}
@(private = "file") //don't go through these uncached helpers, use the cache
load_sound :: proc(name: string, file_extension: string = ".wav") -> rl.Sound {
	for sound_file in SOUNDS_DIR {
		if sound_file.name == name {
			wave := rl.LoadWaveFromMemory(
				".wav",
				raw_data(sound_file.data),
				i32(len(sound_file.data)),
			)
			sound := rl.LoadSoundFromWave(wave)
			game.sounds[name] = sound
			return sound
		}
	}
	print("tried to load unrecognized sound", name)
	return {}
}
unload_sound :: proc(name: string) {
	sound, ok := game.sounds[name]
	if ok {
		rl.UnloadSound(sound)
		delete_key(&game.sounds, name)
	}
}
get_texture :: proc(filename: string) -> rl.Texture2D {
	texture, ok := game.textures[filename]
	if ok {
		return texture
	}
	return load_texture(filename)
}
@(private = "file") //don't go through these uncached helpers, use the cache
load_texture :: proc(filename: string) -> rl.Texture2D {
	texture := rl.LoadTexture(strings.clone_to_cstring(filename))
	rl.SetTextureFilter(texture, .BILINEAR)
	game.textures[filename] = texture
	return texture
}
unload_texture :: proc(filename: string) {
	texture, ok := game.textures[filename]
	if ok {
		rl.UnloadTexture(texture)
		delete_key(&game.textures, filename)
	}
}

get_font :: proc(font_name: FontName) -> rl.Font {
	font, ok := game.fonts[font_name]
	if ok {
		return font
	}
	return load_font(font_name)
}
@(private = "file") //don't go through these uncached helpers, use the cache
load_font :: proc(font_name: FontName) -> rl.Font {
	font := load_atlased_font(font_name)
	game.fonts[font_name] = font
	return font
}
unload_font :: proc(font_name: FontName) {
	font, ok := game.fonts[font_name]
	if ok {
		delete_atlased_font(font)
		delete_key(&game.fonts, font_name)
	}
}


// This uses the letters in the atlas to create a raylib font. Since this font is in the atlas
// it can be drawn in the same draw call as the other graphics in the atlas. Don't use
// rl.UnloadFont() to destroy this font, instead use `delete_atlased_font`, since we've set up the
// memory ourselves.
//
// The set of available glyphs is governed by `LETTERS_IN_FONT` in `atlas_builder.odin`
// The set of available fonts depends on the contents of FONTS_DIR in `atlas_builder.odin`
@(private = "file") //don't go through these uncached helpers, use the cache
load_atlased_font :: proc(font_name: FontName) -> rl.Font {
	num_glyphs := len(LETTERS_IN_FONT)
	font_rects := make([]rl.Rectangle, num_glyphs)
	glyphs := make([]rl.GlyphInfo, num_glyphs)

	for ag, idx in atlas_fonts[font_name] {
		font_rects[idx] = rect_to_rl_rect(ag.rect)
		glyphs[idx] = {
			value    = ag.value,
			offsetX  = i32(ag.offset_x),
			offsetY  = i32(ag.offset_y),
			advanceX = i32(ag.advance_x),
		}
	}

	return {
		baseSize = ATLAS_FONT_SIZE,
		glyphCount = i32(num_glyphs),
		glyphPadding = 0,
		texture = atlas,
		recs = raw_data(font_rects),
		glyphs = raw_data(glyphs),
	}
}
delete_atlased_font :: proc(font: rl.Font) {
	delete(slice.from_ptr(font.glyphs, int(font.glyphCount)))
	delete(slice.from_ptr(font.recs, int(font.glyphCount)))
}

// ===== Game Save / Load =====
//
// Serializes/deserializes game state to/from CBOR.
//
// FUNCTION POINTER OPTIONS:
//   The four proc fields above cannot be serialized. They will be nil after load. Options:
//     1. Re-assign after load: iterate objects and re-attach the correct proc by variant/name.
//     2. Store a string key alongside each proc and use a lookup table at runtime.
//     3. Don't save UI objects — rebuild menus from scratch on load.

GameSave :: struct {
	g:            Game,
	objects:      []GameObject,
	frame_buffer: []GameFrameData,
}

// Applies a GameSave to a live Game.
//
// NOTE: Call this on a freshly reset game (e.g. right after reset_game()) to avoid
// leaking the dynamic allocations inside existing GameObjects (associated_objects maps, etc.).
// NOTE: global_tilemap ownership is transferred from save to g — do not free save after calling this.
apply_save_to_game :: proc(g: ^Game, save: ^Game) {
	// --- Objects ---
	// Zero out the handle map and write objects directly at their saved indices
	// so that all stored GameObjectHandles remain valid.
	hm.clear(&g.objects)
	max_idx: u32 = 0
	for obj in save.objects.items {
		idx := obj.handle.idx
		if idx > 0 && int(idx) < len(g.objects.items) {
			g.objects.items[idx] = obj
			if idx > max_idx do max_idx = idx
		}
	}
	g.objects.num_items = max_idx + 1

	// Rebuild unused-slot linked list for any gaps in the index range.
	g.objects.next_unused = 0
	g.objects.num_unused = 0
	for i := u32(1); i < g.objects.num_items; i += 1 {
		if g.objects.items[i].handle.idx == 0 {
			g.objects.unused_items[i] = g.objects.next_unused
			g.objects.next_unused = i
			g.objects.num_unused += 1
		}
	}

	// Rebuild render layers from the restored objects.
	for &layer in g.render_layers {
		clear(&layer)
	}
	{
		it := hm.make_iter(&g.objects)
		for obj in hm.iter(&it) {
			layer := obj.render_layer
			if layer >= NUM_RENDER_LAYERS do layer = 0
			append(&g.render_layers[layer], obj.handle)
		}
	}

	// --- Tilemap / chunk sets ---
	delete(g.tilemap_chunks)
	g.tilemap_chunks = save.tilemap_chunks

	delete(g.loaded_chunks)
	g.loaded_chunks = make(map[ChunkId]struct{})
	for id in save.loaded_chunks {
		g.loaded_chunks[id] = {}
	}

	delete(g.room_chunks)
	g.room_chunks = make(map[ChunkId]struct{})
	for id in save.room_chunks {
		g.room_chunks[id] = {}
	}

	// --- Scalar / simple fields ---
	g.frame_counter = save.frame_counter
	g.screen_space_parent_handle = save.screen_space_parent_handle
	g.paused = save.paused
	g.main_camera = save.main_camera
	g.menu_state = save.menu_state
	g.menu_container = save.menu_container
	g.global_tilemap = save.global_tilemap
	g.chunk_loading_mode = save.chunk_loading_mode
	g.player_spawn_point = save.player_spawn_point
	g.player_handle = save.player_handle
}

// Serializes the game to CBOR bytes. Caller owns the returned slice.
game_to_cbor :: proc(
	g: ^Game,
	allocator := context.allocator,
) -> (
	data: []byte,
	err: cbor.Marshal_Error,
) {
	//TODO g.objects is a giant statically allocated block, so need to gather that into its own list of just the objects that actually exist
	return cbor.marshal(g^, allocator = allocator)
}

// Deserializes CBOR bytes and applies the result to g.
// See apply_save_to_game for caveats about object cleanup before calling.
game_from_cbor :: proc(g: ^Game, data: []byte) -> bool {
	//TODO objects is serialized as a list, so need to populate g.objects based on that
	save := new(Game)
	err := cbor.unmarshal(data, save)
	if err != nil {
		print("game_from_cbor: unmarshal error:", err)
		return false
	}
	apply_save_to_game(g, save)
	return true
}

// Serializes and writes the game state to a file at path.
save_game :: proc(g: ^Game, path: string) -> bool {
	data, merr := game_to_cbor(g)
	if merr != nil {
		print("save_game: marshal error:", merr)
		return false
	}
	werr := os.write_entire_file(path, data)
	free(raw_data(data))
	if werr != nil {
		print("save_game: failed to write file:", path, werr)
		return false
	}
	return true
}

// Reads a file at path and restores game state from it.
// See apply_save_to_game for caveats about object cleanup before calling.
load_game :: proc(g: ^Game, path: string) -> bool {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		print("load_game: failed to read file:", path, rerr)
		return false
	}
	result := game_from_cbor(g, data)
	free(raw_data(data))
	return result
}
