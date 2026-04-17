package game
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
// proc fields cannot be serialized. They will be nil after load. Options:oo
//    1. Re-assign after load: iterate objects and re-attach the correct proc by variant/name.
//    2. Store a string key alongside each proc and use a lookup table at runtime.
//    3. Don't save UI objects — rebuild menus from scratch on load.

// GameSave holds only the serializable fields of Game
GameSave :: struct {
	// compact object list (valid entries only)
	objects:                    [dynamic]GameObject,
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
	g.frame_buffer.idx = save.frame_buffer.idx
	for frame, i in save.frame_buffer.items {
		//collisions are the only thing we need to persist from prev frames
		//the rest of the frame_buffer info is rebuilt each frame
		g.frame_buffer.items[i].collisions = frame.collisions
	}
	g.frame = rb.get_current(&g.frame_buffer)
	g.prev_frame = rb.get_prev(&g.frame_buffer)

	// Objects
	// Zero out the handle map and write objects directly at their saved indices
	// so that all stored GameObjectHandles remain valid.
	// Objects tagged DontDestroyOnLoad are preserved across loads; any save entry
	// whose index collides with one is ignored (with a warning).
	filtered_objects := make([dynamic]GameObject, context.temp_allocator)
	protected_indices := make(map[u32]struct{}, allocator = context.temp_allocator)
	{
		it := hm.make_iter(&g.objects)
		for obj in hm.iter(&it) {
			if .DontDestroyOnLoad in obj.tags {
				append(&filtered_objects, obj^)
				protected_indices[obj.handle.idx] = {}
			}
		}
	}
	for obj in save.objects {
		if obj.handle.idx in protected_indices {
			print(
				"apply_save_to_game: warning: save has object at index",
				obj.handle.idx,
				"which is held by a DontDestroyOnLoad object; skipping",
			)
			continue
		}
		append(&filtered_objects, obj)
	}
	hm.clear(&g.objects)
	hm.refill_from_list(&g.objects, filtered_objects[:])
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
	g.tilemap_chunks = make(map[ChunkId]TilemapChunk)
	for id, chunk in save.tilemap_chunks {
		g.tilemap_chunks[id] = chunk
	}

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
	game_specific_load(g, save)
}

save_game :: proc(g: ^Game, path: string = "") {
	when ODIN_OS == .JS {
		print("saving & loading not supported on WASM yet")
	} else {
		_save_game(g, path)
	}
}

load_game :: proc(g: ^Game, path: string = "") {
	when ODIN_OS == .JS {
		print("saving & loading not supported on WASM yet")
	} else {
		_load_game(g, path)
	}
}
