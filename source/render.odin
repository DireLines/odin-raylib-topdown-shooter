package game

import "core:c"
import "core:fmt"
import "core:math/linalg"
import "core:strings"
import "core:time"
import hm "handle_map_static"
import rb "ring_buffer"
import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

RenderInfo :: struct {
	texture:                AtlasTexture,
	shader:                 ShaderName,
	color:                  rl.Color,
	using text_render_info: TextRenderInfo,
	render_layer:           uint,
	using import_mode:      TextureImportMode,
	draw:                   proc(obj: ^GameObject) `cbor:"-"`, //custom draw proc, not used unless .CustomDraw is on in object's tags
}

TextureImportMode :: struct {
	//whether to offset sprite to account for transparent border inside original document,
	//which otherwise gets trimmed off when packing into atlas.
	//usually desired for animations
	include_transparent_border: bool,
	//whether to map sprite to a 1x1 square in world coordinates or to the texture's actual dimensions.
	//usually desired for animated sprites, but then since the texture determines the object's size
	//the rest of the code needs to account for it, for hitboxes and such
	keep_original_dimensions:   bool,
}
TextAlignment :: enum {
	Center,
	Left,
	Right,
}

//these are Maybes because the zero value is undesirable for all of them, need to know when to use a default
TextRenderInfo :: struct {
	font:           Maybe(rl.Font) `cbor:"-"`,
	text_color:     Maybe(rl.Color),
	font_size:      Maybe(f32),
	text_alignment: TextAlignment,
}

ShaderName :: enum {
	None,
	PixelFilter,
	SolidColor,
}

DEBUG_RED :: rl.RED
DEBUG_GREEN :: rl.GREEN
DEBUG_BLUE :: rl.BLUE
//drawing things on the screen
@(rodata)
SQUARE_CORNERS := [4]vec2 {
	{0, 0}, //top left
	{0, 1}, //bottom left
	{1, 1}, //bottom right
	{1, 0}, //top right
}
draw_texture_quad :: proc(
	texture: rl.Texture2D,
	source: Rect,
	transform: mat3,
	color: rl.Color = rl.WHITE,
	screen_space: bool = false,
	keep_original_dimensions: bool = false,
) {
	rlgl.Begin(rlgl.QUADS); defer rlgl.End()
	rlgl.SetTexture(texture.id); defer rlgl.SetTexture(0)
	rlgl.Color4ub(color.r, color.g, color.b, color.a)
	corners := SQUARE_CORNERS
	if keep_original_dimensions {
		corners = [4]vec2 {
			{0, 0}, //top left
			{0, f64(source.height) / TEXTURE_PIXELS_PER_WORLD_UNIT}, //bottom left
			{
				f64(source.width) / TEXTURE_PIXELS_PER_WORLD_UNIT,
				f64(source.height) / TEXTURE_PIXELS_PER_WORLD_UNIT,
			}, //bottom right
			{f64(source.width) / TEXTURE_PIXELS_PER_WORLD_UNIT, 0}, //top right
		}
	}
	screen_corners: [4]vec2
	if screen_space {
		#unroll for i in 0 ..< 4 {
			screen_corners[i] = mat_vec_mul(transform, corners[i] * TEXTURE_PIXELS_PER_WORLD_UNIT)
		}
	} else {
		#unroll for i in 0 ..< 4 {
			screen_corners[i] = world_to_screen(
				mat_vec_mul(transform, corners[i] * TEXTURE_PIXELS_PER_WORLD_UNIT),
				screen_conversion,
			)
		}
	}
	tex_width := f64(texture.width)
	tex_height := f64(texture.height)
	tex_corners := [4]vec2 {
		{source.x / tex_width, source.y / tex_height}, //top left
		{source.x / tex_width, (source.y + source.height) / tex_height}, //bottom left
		{(source.x + source.width) / tex_width, (source.y + source.height) / tex_height}, //bottom right
		{(source.x + source.width) / tex_width, source.y / tex_height}, //top right
	}
	is_flipped_x := screen_corners[3].x < screen_corners[0].x
	is_flipped_y := screen_corners[1].y < screen_corners[0].y
	is_flipped := is_flipped_x ~ is_flipped_y //xor
	#unroll for i in 0 ..< 4 {
		index := i
		if is_flipped {
			index = 3 - i //reverse winding
		}
		rlgl.TexCoord2f(f32(tex_corners[index].x), f32(tex_corners[index].y))
		rlgl.Vertex2f(f32(screen_corners[index].x), f32(screen_corners[index].y))
	}
}

get_final_transform_cached :: proc(
	handle, screen_space_handle: GameObjectHandle,
	objects: ^GameObjects,
	final_transforms: []TransformScreenSpace,
) -> TransformScreenSpace {
	cached := final_transforms[handle.idx].transform[2, 2] > 0
	if cached {
		return final_transforms[handle.idx]
	}
	obj, ok := hm.get(objects, handle)
	if !ok {
		print("get_final_transform_cached called on deleted object:", obj.name)
		return {}
	}
	parent_handle, has_parent := obj.parent_handle.?
	m: mat3
	screen_space: bool
	if !has_parent {
		m = apply(obj.transform)
	} else {
		if parent_handle == screen_space_handle {
			m = apply(obj.transform)
			screen_space = true
			final_transforms[handle.idx] = {m, screen_space}
			return {m, screen_space}
		}
		_, ok := hm.get(objects, parent_handle)
		if !ok {
			print("child object left with deleted parent:", obj.name)
			return {}
		}
		parent_transform_info := get_final_transform_cached(
			parent_handle,
			screen_space_handle,
			objects,
			final_transforms,
		)
		m = parent_transform_info.transform * apply(obj.transform)
		screen_space = parent_transform_info.screen_space
	}
	final_transforms[handle.idx] = {m, screen_space}
	return {m, screen_space}
}

draw_debug_shapes :: #config(draw_debug_shapes, false)
vec2_to_vec2f32 :: proc(v: vec2) -> rl.Vector2 {
	return {f32(v.x), f32(v.y)}
}
vec2f32_to_vec2 :: proc(v: rl.Vector2) -> vec2 {
	return {f64(v.x), f64(v.y)}
}
draw_object :: proc(obj: ^GameObject, final_transform: TransformScreenSpace) {
	when draw_debug_shapes {
		if .Collide in obj.tags {
			switch s in obj.hitbox.shape {
			case Circle:
				m := final_transform.transform * pivot(obj.transform)
				obj_scale := linalg.length(vec2{m[0][0], m[1][0]})
				draw_debug_circle(
					world_coords = mat_vec_mul(m, s.pos),
					radius = f32(s.radius * obj_scale * screen_conversion.scale),
				)
			case AABB:
				m := final_transform.transform * pivot(obj.transform)
				c1 := mat_vec_mul(m, s.min)
				c2 := mat_vec_mul(m, s.max)
				draw_debug_box(AABB{linalg.min(c1, c2), linalg.max(c1, c2)})
			}
		}
	}
	transform := final_transform.transform
	disp_transform := obj.display_transform
	if disp_transform != {} {
		if disp_transform.scale == {0, 0} {
			disp_transform.scale = {1, 1}
		}
		transform *= pivot(obj.transform) * apply(disp_transform) * unpivot(obj.transform)
	}
	parent_handle, has_parent := obj.parent_handle.?
	if .Sprite in obj.tags {
		texture := atlas
		source := obj.texture.rect
		if obj.include_transparent_border {
			offset := vec2{f64(obj.texture.offset_left), f64(obj.texture.offset_top)}
			transform = transform * translate_vec2(offset)
		}
		draw_texture_quad(
			texture,
			source,
			transform,
			obj.color,
			final_transform.screen_space,
			obj.keep_original_dimensions,
		)
	}
	if .Text in obj.tags {
		font := obj.font.? or_else global_default_font
		font_size := obj.font_size.? or_else DEFAULT_FONT_SIZE
		cur_string_cstr := strings.clone_to_cstring(obj.text, context.temp_allocator)
		current_string_dims := rl.MeasureTextEx(font, cur_string_cstr, font_size, 0)
		total_dims := current_string_dims
		word_start_pos := mat_vec_mul(transform, obj.pivot)
		if !final_transform.screen_space {
			word_start_pos = world_to_screen(word_start_pos, screen_conversion)
		}
		switch obj.text_alignment {
		case .Center:
			word_start_pos -= vec2f32_to_vec2(total_dims) / 2
		case .Left:
			word_start_pos.y -= f64(total_dims.y) / 2
		case .Right:
			word_start_pos -= vec2f32_to_vec2(total_dims)
			word_start_pos.y += f64(total_dims.y) / 2
		}
		rl.DrawTextEx(
			font,
			cur_string_cstr,
			vec2_to_vec2f32(word_start_pos),
			font_size,
			0,
			obj.text_color.? or_else rl.GREEN,
		)
	}
	if .CustomDraw in obj.tags {
		if obj.draw != nil {
			obj->draw()
		} else {
			print("custom draw mode was on for", obj.name, "but custom draw proc was nil")
		}
	}
}

CEILING_SHIFT_PROPORTION :: 0.55
CEILING_OFFSET: vec2 = {0, -TILE_SIZE * CEILING_SHIFT_PROPORTION}
TILE_ROTATION_MATRICES: [CardinalDirection]mat3
draw_tile :: proc(
	id: TilemapTileId,
	render_layer: uint,
	timer: ^Timer,
	color: rl.Color,
	tile: Maybe(Tile) = {}, //allow prefetching
	props: Maybe(TileTypeInfo) = {}, //allow prefetching
) {
	tile, tile_provided := tile.?
	if !tile_provided {
		tile = get_tile(id)
	}
	info, info_provided := props.?
	if !info_provided {
		info = TILE_PROPERTIES[tile.type]
	}
	wall, is_wall := info.wall_render_info.?
	if !((render_layer == info.render_layer) || (is_wall && render_layer == wall.render_layer)) {
		return
	}
	source := info.texture.rect
	ceiling := is_wall && render_layer == info.render_layer
	if (!is_wall) && ceiling {
		return
	}
	if is_wall {
		if !ceiling {
			source = wall.texture.rect
		}
	}
	timer->count_toward("tile checks")
	aabb := get_tile_aabb(id)
	offset := aabb.min
	epsilon :: 0.0001 // handle seams btwn tiles
	scale_amt := vec2{TILE_SIZE / source.width, TILE_SIZE / source.height} + epsilon
	if is_wall && ceiling {
		offset += CEILING_OFFSET
	}
	m := translate(offset) * scale(scale_amt) * TILE_ROTATION_MATRICES[tile.rotation]
	timer->count_toward("compute tile transforms")
	if info.texture != atlas_textures[.None] {
		draw_texture_quad(atlas, source, m, color)
		timer->count_toward("draw tile quads")
	}
	when draw_debug_shapes {
		if info.resolve {
			draw_debug_box(aabb)
		}
	}
}


DebugBox :: struct {
	world_box: AABB,
	color:     rl.Color,
	filled:    bool,
}
debug_boxes := [dynamic]DebugBox{}
draw_debug_box :: proc(world_box: AABB, color: rl.Color = rl.GREEN, filled: bool = false) {
	append(&debug_boxes, DebugBox{world_box, set_alpha(color, min(color.a, 256 * 0.75)), filled})
}
draw_debug_box_now :: proc(world_box: AABB, color: rl.Color = rl.GREEN, filled: bool = false) {
	screen_hitbox := aabb_to_rect(
		AABB {
			min = world_to_screen(world_box.min, screen_conversion),
			max = world_to_screen(world_box.max, screen_conversion),
		},
	)
	if filled {
		rl.DrawRectangle(
			i32(screen_hitbox.x),
			i32(screen_hitbox.y),
			i32(screen_hitbox.width),
			i32(screen_hitbox.height),
			color,
		)
	} else {
		rl.DrawRectangleLines(
			i32(screen_hitbox.x),
			i32(screen_hitbox.y),
			i32(screen_hitbox.width),
			i32(screen_hitbox.height),
			color,
		)
	}
}

DebugCircle :: struct {
	world_coords: vec2,
	radius:       f32,
	color:        rl.Color,
	filled:       bool,
}
debug_circles := [dynamic]DebugCircle{}
set_alpha :: proc(c: rl.Color, alpha: u8) -> rl.Color {
	return {c.r, c.g, c.b, alpha}
}
//by default, want to defer drawing debug shapes until after sprites
draw_debug_circle :: proc(
	world_coords: vec2,
	radius: f32 = 10,
	color: rl.Color = rl.GREEN,
	filled: bool = false,
) {
	append(
		&debug_circles,
		DebugCircle{world_coords, radius, set_alpha(color, min(color.a, 256 * 0.75)), filled},
	)
}
draw_debug_circle_now :: proc(
	world_coords: vec2,
	radius: f32 = 10,
	color: rl.Color = rl.GREEN,
	filled: bool = false,
) {
	center := world_to_screen(world_coords, screen_conversion)
	if filled {
		rl.DrawCircle(i32(center.x), i32(center.y), radius, color)
	} else {
		rl.DrawCircleLines(i32(center.x), i32(center.y), radius, color)
	}
}


DebugLine :: struct {
	world_start, world_end: vec2,
	thickness:              f32,
	color:                  rl.Color,
}
debug_lines := [dynamic]DebugLine{}
draw_debug_line :: proc(world_start, world_end: vec2, thickness: f32, color: rl.Color = rl.RED) {
	append(&debug_lines, DebugLine{world_start, world_end, thickness, color})
}
draw_debug_line_now :: proc(world_start, world_end: vec2, thickness: f32, color: rl.Color) {
	rl.DrawLineEx(
		vec2_to_vec2f32(world_to_screen(world_start, screen_conversion)),
		vec2_to_vec2f32(world_to_screen(world_end, screen_conversion)),
		thickness,
		color,
	)
}

recreate_final_transforms :: proc(game: ^Game = game) {
	//iterate over game objects to determine final pos/rot/scales to render for each one (resolve transform hierarchy stuff)
	clear(&game.final_transforms)
	resize(&game.final_transforms, len(game.objects.items)) //uses index-matching, so needs to be the same size as the actual items array, not number of objects

	it := hm.make_iter(&game.objects)
	for obj, h in hm.iter(&it) {
		get_final_transform_cached(
			h,
			game.screen_space_parent_handle,
			&game.objects,
			game.final_transforms[:],
		)
	}

	it = hm.make_iter(&game.objects)
	for obj, h in hm.iter(&it) {
		game.final_transforms[h.idx].transform *= unpivot(obj.transform)
	}
}
objects_to_draw: map[GameObjectHandle]struct{}
tile_render_layers_used: map[uint]struct{}
object_list_display_start_index: int
render :: proc() {
	timer := timer()
	//figure out which objects are on screen
	chunks_near_cam := get_chunks_near_cam(1)
	clear_map(&objects_to_draw)
	for chunk, i in chunks_near_cam {
		aabb := get_chunk_aabb(chunk)
		when draw_debug_shapes {
			draw_debug_box(aabb, rl.BLUE)
		}
		chunk_min, chunk_max := get_tilemap_corners(chunk)
		if chunk not_in game.chunks {
			continue
		}
		for obj_handle in game.chunks[chunk] {
			objects_to_draw[obj_handle] = {}
		}
	}
	chunks_near_cam = get_chunks_near_cam(0)
	tile_min, tile_max: TilemapTileId
	for chunk, i in chunks_near_cam {
		chunk_min, chunk_max := get_tilemap_corners(chunk)
		if i == 0 {
			tile_min = chunk_min
			tile_max = chunk_max
		} else {
			tile_min = linalg.min(tile_min, chunk_min)
			tile_max = linalg.max(tile_max, chunk_max)
		}
	}
	timer->time("get to-draw list")
	//insert tilemap tiles into the render layers
	//draw using raylib
	rl.BeginDrawing(); defer rl.EndDrawing()

	// darkgray := rl.Color{32, 32, 30, 255}
	rl.ClearBackground(rl.BLACK)
	curr_shader_name: ShaderName //tracking this to know when to switch shader modes, which is expensive
	change_shader :: proc(s: ShaderName, curr: ^ShaderName) {
		if curr^ == s {return}
		if curr^ != .None {
			rl.EndShaderMode()
		}
		if s != .None {
			rl.BeginShaderMode(game.shaders[s])
		}
		curr^ = s
	}
	for layer, layer_idx in game.render_layers {
		for handle in layer {
			if int(handle.idx) >= len(game.final_transforms) {
				print("RECREATING FINAL TRANSFORMS BUT SHOULD NOT NEED TO HERE")
				recreate_final_transforms()
			}
			obj, ok := hm.get(&game.objects, handle)
			if !ok {
				continue
			}
			change_shader(obj.shader, &curr_shader_name)
			transform_info := game.final_transforms[handle.idx]
			if handle in objects_to_draw || game.paused || transform_info.screen_space {
				draw_object(obj, transform_info)
			}
		}
		i := uint(layer_idx)
		if i in tile_render_layers_used {
			tiles := make_tilemap_iterator(tile_min, tile_max)
			for tile_id in tilemap_iter(&tiles) {
				timer->reset()
				tile := get_tile(tile_id)
				timer->count_toward("get_tile calls")
				props := TILE_PROPERTIES[tile.type]
				wall, is_wall := props.wall_render_info.?
				on_main_layer := i == props.render_layer
				on_wall_layer := is_wall && i == wall.render_layer
				if !(on_main_layer || on_wall_layer) {
					continue
				}
				if on_main_layer {
					change_shader(props.shader, &curr_shader_name)
				}
				if on_wall_layer {
					change_shader(wall.shader, &curr_shader_name)
				}
				color := rl.WHITE
				if props.color.a != 0 {
					color = props.color
				}
				draw_tile(tile_id, i, &timer, color, tile = tile, props = props)
			}
		}
	}
	if curr_shader_name != .None {
		rl.EndShaderMode()
	}
	timer->dump_totals()
	when draw_debug_shapes {
		for k, v in game.collisions {
			for c in v {
				#partial switch info in c.info {
				case DiscreteCollision:
				// draw contact normal as a line from origin (no world pos available here, just visualize it exists)
				}
			}
		}
	}
	for circle in debug_circles {
		draw_debug_circle_now(circle.world_coords, circle.radius, circle.color, circle.filled)
	}
	clear(&debug_circles)
	for box in debug_boxes {
		draw_debug_box_now(box.world_box, box.color, box.filled)
	}
	clear(&debug_boxes)
	for line in debug_lines {
		draw_debug_line_now(line.world_start, line.world_end, line.thickness, line.color)
	}
	clear(&debug_lines)
	timer->time("draw debug stuff")
	when #config(show_fps, true) {
		x := rb.get_current(&measured_frame_times)
		x^ = time.duration_milliseconds(time.tick_since(frame_start))
		sum: f64 = 0
		num: int = 0
		for &n in measured_frame_times.items {
			if (n == 0) {
				continue
			}
			sum += n
			num += 1
		}
		smoothed_frame_time := sum / f64(num)
		millis_budget :: f64(1000) / f64(TARGET_FPS)
		rb.increment(&measured_frame_times)
		rl.DrawRectangle(0, 0, 10, 200, rl.Color{100, 158, 100, 128})
		rl.DrawRectangle(
			0,
			0,
			10,
			c.int(200 * smoothed_frame_time / millis_budget),
			rl.Color{255, 129, 61, 255},
		)
		for i in 0 ..< 10 {
			rl.DrawRectangle(1, c.int(i) * 20, 9, 2, rl.Color{200, 20, 20, 128})
		}
		frame_buckets_in_the_past :: proc(curr_frame, frame_idx: int) -> int {
			idx := frame_idx
			FRAME_BUCKET_SIZE :: 15
			if frame_idx > curr_frame {
				idx -= SMOOTHING_FRAMES
			}
			return (curr_frame / FRAME_BUCKET_SIZE) - (idx / FRAME_BUCKET_SIZE)
		}
		for &n, i in measured_frame_times.items {
			if (n == 0) {
				continue
			}
			curr_frame := measured_frame_times.idx
			x := frame_buckets_in_the_past(int(curr_frame), i)
			rl.DrawRectangle(
				10 + 5 * c.int(x),
				c.int(200 * n / millis_budget) - 1,
				5,
				3,
				rl.Color{255, 129, 61, 100},
			)
		}

	}
	timer->time("draw fps display")

	when #config(show_object_list, false) {{
			FONT_SIZE :: 12
			ROW_HEIGHT :: 16
			if rl.IsKeyDown(.LEFT_BRACKET) {
				object_list_display_start_index = max(0, object_list_display_start_index - 1)
			}
			if rl.IsKeyDown(.RIGHT_BRACKET) {
				object_list_display_start_index = min(
					int(game.objects.num_items),
					object_list_display_start_index + 1,
				)
			}
			label_pos_x: i32 = 16
			for i in object_list_display_start_index ..< object_list_display_start_index + 200 {
				if i >= len(game.objects.items) {
					break
				}
				label_pos_y := i32(i - object_list_display_start_index) * ROW_HEIGHT
				if label_pos_y + ROW_HEIGHT > rl.GetScreenHeight() {
					break
				}
				item := game.objects.items[i]
				text: string
				if i == 0 || item.handle.idx == 0 {
					text = fmt.tprintf("%d", i)
				} else {
					text = fmt.tprintf("%d (gen %d) %s", i, item.handle.gen, item.name)
				}
				rl.DrawText(
					strings.clone_to_cstring(text, context.temp_allocator),
					label_pos_x,
					label_pos_y,
					FONT_SIZE,
					rl.WHITE,
				)
			}
		}
	}
}

get_chunks_near_cam :: proc(border_screen_multiples: f64 = 0) -> []ChunkId {
	disp: vec2 = {WINDOW_WIDTH, WINDOW_HEIGHT} * border_screen_multiples
	top_left := screen_to_world({0, 0} - disp, screen_conversion)
	bottom_right := screen_to_world({WINDOW_WIDTH, WINDOW_HEIGHT} + disp, screen_conversion)
	chunks := get_chunks_between(
		get_containing_chunk(top_left),
		get_containing_chunk(bottom_right),
	)
	return chunks
}

//set render layer, and also do appropriate bookkeeping
set_render_layer :: proc(obj_h: GameObjectHandle, render_layer: uint) {
	obj, ok := hm.get(&game.objects, obj_h)
	if !ok {
		return
	}
	old_render_layer := obj.render_layer
	obj.render_layer = render_layer
	for h, i in game.render_layers[old_render_layer] {
		if h == obj_h {
			unordered_remove(&game.render_layers[old_render_layer], i)
			break
		}
	}
	append(&game.render_layers[render_layer], obj_h)
}
