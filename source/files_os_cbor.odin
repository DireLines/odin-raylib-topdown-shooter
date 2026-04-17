#+build !wasm32
#+build !wasm64p32
package game

import "core:encoding/cbor"
import "core:os"
import hm "handle_map_static"

// Serializes and writes the game state to a file at path.
_save_game :: proc(g: ^Game, path: string = "") -> bool {
	print("saving", path)
	data, merr := game_to_cbor(g)
	if merr != nil {
		print("save_game: marshal error:", merr)
		return false
	}
	werr := os.write_entire_file(path, data)
	defer free(raw_data(data))
	if werr != nil {
		print("save_game: failed to write file:", path, werr)
		return false
	}
	print("saved", len(data), "bytes")
	return true
}

// Reads a file at path and restores game state from it.
// See apply_save_to_game for caveats about object cleanup before calling.
_load_game :: proc(g: ^Game, path: string) -> bool {
	print("loading", path)
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil {
		print("load_game: failed to read file:", path, rerr)
		return false
	}
	result := game_from_cbor(g, data)
	print("loaded", len(data), "bytes")
	defer free(raw_data(data))
	return result
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
			if .DoNotSerialize in obj.tags {continue}
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
		objects                    = objects,
		frame_buffer               = g.frame_buffer,
	}
	print_field_info :: proc(name: string, value: $T) {
		d, e := cbor.marshal(value, allocator = context.temp_allocator)
		if e == nil {
			print(len(d), "\t\tbytes:", name)
		} else {
			print(name, "-> marshal error:", e)
		}
	}
	when #config(save_size_breakdown, false) {
		print("--- GameSave CBOR size breakdown ---")
		print_field_info("tilemap_chunks", save.tilemap_chunks)
		print_field_info("loaded_chunks", save.loaded_chunks)
		print_field_info("room_chunks", save.room_chunks)
		print_field_info("frame_counter", save.frame_counter)
		print_field_info("render_counter", save.render_counter)
		print_field_info("screen_space_parent_handle", save.screen_space_parent_handle)
		print_field_info("paused", save.paused)
		print_field_info("quit", save.quit)
		print_field_info("main_camera", save.main_camera)
		print_field_info("game_specific_state", save.game_specific_state)
		print_field_info("frame_buffer", save.frame_buffer)
		print_field_info("objects", save.objects)
		print("------------------------------------")
	}

	return cbor.marshal(save, allocator = allocator)
}

// Deserializes CBOR bytes and applies the result to g.
// See apply_save_to_game for caveats about object cleanup before calling.
game_from_cbor :: proc(g: ^Game, data: []byte) -> bool {
	save := new(GameSave)
	defer free(save)
	err := cbor.unmarshal(data, save, {.Trusted_Input})
	if err != nil {
		print("game_from_cbor: unmarshal error:", err)
		return false
	}
	apply_save_to_game(g, save)
	return true
}
