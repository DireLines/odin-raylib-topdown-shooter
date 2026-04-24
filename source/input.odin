package game

import rl "vendor:raylib"

get_axis :: proc(key_neg, key_pos: rl.KeyboardKey) -> f64 {
	return f64(int(rl.IsKeyDown(key_pos))) - f64(int(rl.IsKeyDown(key_neg)))
}
