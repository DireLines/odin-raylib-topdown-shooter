#+build !wasm32
#+build !wasm64p32
package game

import "core:os"

// Serializes and writes the game state to a file at path.
save_game :: proc(g: ^Game, path: string = "") -> bool {
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
load_game :: proc(g: ^Game, path: string) -> bool {
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
