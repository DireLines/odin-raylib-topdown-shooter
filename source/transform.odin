package game
import "core:math"
import "core:math/linalg"
import hm "handle_map_static"
//transform struct & math

//screen transformation
ScreenConversion :: struct {
	scale:         f64,
	screen_width:  f64,
	screen_height: f64,
}
screen_conversion :: ScreenConversion {
	SCREEN_PIXELS_PER_WORLD_UNIT,
	f64(WINDOW_WIDTH),
	f64(WINDOW_HEIGHT),
}
world_to_screen :: proc(w: vec2, cv: ScreenConversion) -> vec2 {
	return cv.scale * (w - game.main_camera.position) + 0.5 * {cv.screen_width, cv.screen_height}
}
screen_to_world :: proc(s: vec2, cv: ScreenConversion) -> vec2 {
	return (s - 0.5 * {cv.screen_width, cv.screen_height}) / cv.scale + game.main_camera.position
}

//assumes game.final_transforms is up to date
local_to_world :: proc(h: GameObjectHandle, p: vec2) -> vec2 {
	return mat_vec_mul(game.final_transforms[h.idx].transform, p)
}
world_to_local :: proc(h: GameObjectHandle, p: vec2) -> vec2 {
	return mat_vec_mul(linalg.inverse(game.final_transforms[h.idx].transform), p)
}

get_world_center :: proc(h: GameObjectHandle) -> vec2 {
	o := hm.get(&game.objects, h)
	return local_to_world(h, o.pivot)
}

Transform :: struct {
	position: vec2,
	rotation: f64,
	scale:    vec2,
	pivot:    vec2,
}
default_transform :: proc() -> Transform {
	return Transform{scale = {1, 1}}
}

pivot :: proc(t: Transform) -> (result: mat3) {
	return translate_vec2(t.pivot)
}
unpivot :: proc(t: Transform) -> (result: mat3) {
	return translate_vec2(-t.pivot)
}
identity :: proc() -> (result: mat3) {
	result[0, 0] = 1
	result[1, 1] = 1
	result[2, 2] = 1
	return
}
translate_vec2 :: proc(v: vec2) -> (result: mat3) {
	return translate_xy(v.x, v.y)
}
translate_xy :: proc(x, y: f64) -> (result: mat3) {
	result = identity()
	result[0, 2] = x
	result[1, 2] = y
	return
}
translate :: proc {
	translate_xy,
	translate_vec2,
}

rotate :: proc(r: f64) -> (result: mat3) {
	result = identity()
	result[0, 0] = math.cos(r)
	result[0, 1] = -math.sin(r)
	result[1, 0] = math.sin(r)
	result[1, 1] = math.cos(r)
	return
}

rotate_degrees :: proc(d: f64) -> mat3 {
	return rotate(radians_f64(d))
}

scale_vec2 :: proc(v: vec2) -> (result: mat3) {
	return scale_xy(v.x, v.y)
}
scale_xy :: proc(x, y: f64) -> (result: mat3) {
	result = identity()
	result[0, 0] = x
	result[1, 1] = y
	return
}
scale :: proc {
	scale_xy,
	scale_vec2,
}

radians_f64 :: math.to_radians_f64
apply :: proc(t: Transform) -> mat3 {
	return translate(t.position) * rotate(radians_f64(t.rotation)) * scale_vec2(t.scale)
}
reverse :: proc(t: ^Transform) -> (result: mat3) {
	return scale_vec2(1 / t.scale) * rotate(radians_f64(-t.rotation)) * translate(-t.position)
}

mat_vec_mul :: proc(m: mat3, v: vec2) -> vec2 {
	return {v.x * m[0, 0] + v.y * m[0, 1] + m[0, 2], v.x * m[1, 0] + v.y * m[1, 1] + m[1, 2]}
}
