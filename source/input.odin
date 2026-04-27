package game

import rl "vendor:raylib"

get_axis :: proc(key_neg, key_pos: rl.KeyboardKey) -> f64 {
	return f64(int(rl.IsKeyDown(key_pos))) - f64(int(rl.IsKeyDown(key_neg)))
}

// Returns scale + top-left offset used when blitting the viewport to the window.
get_viewport_render_rect :: proc() -> (scale, offset_x, offset_y: f32) {
	win_w := f32(rl.GetScreenWidth())
	win_h := f32(rl.GetScreenHeight())
	vp_w := f32(VIEWPORT_WIDTH)
	vp_h := f32(VIEWPORT_HEIGHT)
	scale = min(win_w / vp_w, win_h / vp_h)
	offset_x = (win_w - vp_w * scale) * 0.5
	offset_y = (win_h - vp_h * scale) * 0.5
	return
}

// Mouse position remapped from window coords into viewport (virtual screen) coords.
get_mouse_viewport_pos :: proc() -> rl.Vector2 {
	m := rl.GetMousePosition()
	scale, ox, oy := get_viewport_render_rect()
	return {(m.x - ox) / scale, (m.y - oy) / scale}
}
