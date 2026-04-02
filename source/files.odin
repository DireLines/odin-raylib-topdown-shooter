package game
import "core:encoding/cbor"
import "core:os"
import "core:reflect"
import "core:slice"
import "core:strings"
import hm "handle_map_static"
import rb "ring_buffer"
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
// TODO RESTORE FUNCTION POINTERS
// proc fields cannot be serialized. They will be nil after load. Options:
//    1. Re-assign after load: iterate objects and re-attach the correct proc by variant/name.
//    2. Store a string key alongside each proc and use a lookup table at runtime.
//    3. Don't save UI objects — rebuild menus from scratch on load.

// GameSave holds only the serializable fields of Game (no giant fixed arrays or GPU handles),
// plus the compact object list and frame buffer needed to fully restore game state.
GameSave :: struct {
	// compact object list (valid entries only) and frame buffer
	objects:                    []GameObject,
	// Game scalar / map fields (everything in Game not tagged cbor:"-")
	tilemap_chunks:             map[ChunkId]TilemapChunk,
	loaded_chunks:              map[ChunkId]struct{},
	room_chunks:                map[ChunkId]struct{},
	frame_buffer:               rb.RingBuffer(GameFrameData, 2),
	frame_counter:              u64,
	render_counter:             u64,
	screen_space_parent_handle: GameObjectHandle,
	paused:                     bool,
	quit:                       bool,
	main_camera:                Transform,
	using game_specific_state:  GameSpecificGlobalState,
}

// Applies a GameSave to a live Game.
apply_save_to_game :: proc(g: ^Game, save: ^GameSave) {
	// Frame buffer
	g.frame_buffer = save.frame_buffer
	g.frame = rb.get_current(&g.frame_buffer)
	g.prev_frame = rb.get_prev(&g.frame_buffer)
	// Objects
	// Zero out the handle map and write objects directly at their saved indices
	// so that all stored GameObjectHandles remain valid.
	hm.clear(&g.objects)
	hm.refill_from_list(&g.objects, save.objects)
	it := hm.make_iter(&g.objects)
	for obj, h in hm.iter(&it) {
		obj._variant_type = reflect.union_variant_typeid(obj.variant)
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


	// Tilemap / chunk sets
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

	// Scalar / simple fields
	g.frame_counter = save.frame_counter
	g.render_counter = save.render_counter
	g.screen_space_parent_handle = save.screen_space_parent_handle
	g.paused = save.paused
	g.main_camera = save.main_camera
	g.game_specific_state = save.game_specific_state
}

// Serializes the game to CBOR bytes. Caller owns the returned slice.
game_to_cbor :: proc(
	g: ^Game,
	allocator := context.allocator,
) -> (
	data: []byte,
	err: cbor.Marshal_Error,
) {
	// Collect only the live objects (skip empty slots in the fixed handle map array).
	objects := make([dynamic]GameObject, context.temp_allocator)
	{
		it := hm.make_iter(&g.objects)
		for obj in hm.iter(&it) {
			append(&objects, obj^)
		}
	}

	save := GameSave {
		tilemap_chunks             = g.tilemap_chunks,
		loaded_chunks              = g.loaded_chunks,
		room_chunks                = g.room_chunks,
		frame_counter              = g.frame_counter,
		render_counter             = g.render_counter,
		screen_space_parent_handle = g.screen_space_parent_handle,
		paused                     = g.paused,
		quit                       = g.quit,
		main_camera                = g.main_camera,
		game_specific_state        = g.game_specific_state,
		objects                    = objects[:],
		frame_buffer               = g.frame_buffer,
	}
	// Per-field size breakdown (uses temp allocator, freed at end of frame).
	print_field_size :: proc(name: string, value: $T) {
		d, e := cbor.marshal(value, allocator = context.temp_allocator)
		if e == nil {
			print(name, "->", len(d), "bytes")
		} else {
			print(name, "-> marshal error:", e)
		}
	}
	print("--- GameSave CBOR size breakdown ---")
	print_field_size("tilemap_chunks", save.tilemap_chunks)
	print_field_size("loaded_chunks", save.loaded_chunks)
	print_field_size("room_chunks", save.room_chunks)
	print_field_size("frame_counter", save.frame_counter)
	print_field_size("render_counter", save.render_counter)
	print_field_size("screen_space_parent_handle", save.screen_space_parent_handle)
	print_field_size("paused", save.paused)
	print_field_size("quit", save.quit)
	print_field_size("main_camera", save.main_camera)
	print_field_size("game_specific_state", save.game_specific_state)
	print_field_size("objects", save.objects)
	print_field_size("frame_buffer", save.frame_buffer)
	print("------------------------------------")

	return cbor.marshal(save, allocator = allocator)

}

// Deserializes CBOR bytes and applies the result to g.
// See apply_save_to_game for caveats about object cleanup before calling.
game_from_cbor :: proc(g: ^Game, data: []byte) -> bool {
	save := new(GameSave)
	defer free(save)
	err := cbor.unmarshal(data, save)
	if err != nil {
		print("game_from_cbor: unmarshal error:", err)
		return false
	}
	apply_save_to_game(g, save)
	return true
}

// Serializes and writes the game state to a file at path.
save_game :: proc(g: ^Game, path: string = "") -> bool {
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
