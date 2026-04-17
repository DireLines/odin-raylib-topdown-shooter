package mapgen
import rb "../ring_buffer"
import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import rl "vendor:raylib"
vec2 :: rl.Vector2
int2 :: [2]int
Color :: rl.Color
print :: fmt.println
mid_grey :: Color{180, 180, 180, 255}
MapType :: enum {
	Caves,
	ArtificialCaves,
	Wreckage,
	Spirals,
	Starfield,
}
generate_map :: proc(
	map_type: MapType,
	top_left: int2,
	$width: int,
	seed: u64 = 0,
) -> (
	img: [][]Color,
) {
	caves :: CellularAutomatonRule{{5, 6, 7, 8}, {4, 5, 6, 7, 8}} // smooths things out, removes jagged detail, population stays about the same
	wreckage :: CellularAutomatonRule{{5, 6, 7, 8}, {3, 5, 6, 7, 8}} // shrinks things, adds some jagged detail and growth biased toward 45 degree angles
	switch map_type {
	case .ArtificialCaves:
		grid := random_noise(seed, 0.55, width)
		grid = run_automaton(&grid, wreckage, 20)^
		grid = run_automaton(&grid, caves, 10)^
		img = bool_grid_to_img_buf(&grid, proc(b: bool) -> Color {
			return b ? mid_grey : rl.BLANK
		})
		img = replace_small_chunks(img, mid_grey, rl.BLANK)
		img = replace_small_chunks(img, rl.BLANK, mid_grey)
		img = recolor_chunks(img, mid_grey)
	case .Caves:
		grid := random_noise(seed, 0.49, width)
		grid = run_automaton(&grid, caves, 30)^
		img = bool_grid_to_img_buf(&grid, proc(b: bool) -> Color {
			return b ? mid_grey : rl.BLANK
		})
		img = replace_small_chunks(img, mid_grey, rl.BLANK)
		img = replace_small_chunks(img, rl.BLANK, mid_grey)
		img = recolor_chunks(img, mid_grey)
		return img
	case .Wreckage:
		grid := random_noise(seed, 0.55, width)
		grid = run_automaton(&grid, wreckage, 30)^
		img = bool_grid_to_img_buf(&grid, proc(b: bool) -> Color {
			return b ? mid_grey : rl.BLANK
		})
		img = replace_small_chunks(img, mid_grey, rl.BLANK)
		img = replace_small_chunks(img, rl.BLANK, mid_grey)
		img = recolor_chunks(img, mid_grey)
	case .Starfield:
		colliding_blobs :: CellularAutomatonRule{{3, 5}, {2, 5, 6, 7, 8}}
		grid := random_noise(seed, 0.48, width)
		grid = run_automaton(&grid, colliding_blobs, 700)^ //takes a while to fully resolve
		invert_grid(&grid) //empty spaces should be stars
		img = bool_grid_to_img_buf(&grid, proc(b: bool) -> Color {
			return b ? mid_grey : rl.BLANK
		})
	case .Spirals:
		rand_state := rand.create(seed)
		context.random_generator = rand.default_random_generator(&rand_state)
		width_ratio :: 2
		pix_width :: width * width_ratio
		//less winding, fuller hallways, room boundaries less discernibly along circle lines
		// spiral_spacing :: width_ratio * 4 / math.PI
		// spiral_turns :: 6 * math.PI

		// spiral_spacing :: width_ratio * 3.25 / math.PI
		// spiral_turns :: 7.5 * math.PI

		//more winding, thinner hallways, room boundaries more discernibly along circle lines
		//generally prefer how this one looks
		spiral_spacing :: width_ratio * 3 / math.PI
		spiral_turns :: 8 * math.PI

		spiral_path := generate_spiral_path(spiral_spacing, spiral_turns)
		spiral_width := spiral_spacing * 2 * math.PI
		spiral_path_radius :: 2 * width_ratio


		min_segment_length :: 3 * width_ratio
		max_segment_length :: 16 * width_ratio
		min_gap_length :: 2 * width_ratio
		max_gap_length :: 7.3 * width_ratio
		light_grey :: Color{177, 177, 177, 255}
		dark_grey :: Color{134, 134, 134, 255}
		tex := rl.LoadRenderTexture(i32(pix_width), i32(pix_width))
		rl.BeginDrawing(); defer rl.EndDrawing()

		rl.BeginTextureMode(tex)
		rl.ClearBackground(mid_grey)
		Circle :: struct {
			pos:    vec2,
			radius: f32,
		}
		circles := [dynamic]Circle{}
		fails := 0
		total_area := f32(pix_width * pix_width)
		claimed_area: f32 = 0
		num_spiral_points: int
		new_circle: Circle
		for claimed_area < total_area {
			invalid_pos := true
			//find unoccupied circle position
			for invalid_pos {
				invalid_pos = false
				num_spiral_points = len(spiral_path) - max(fails / 10000, 1)
				radius := linalg.length(spiral_path[num_spiral_points])
				new_circle = Circle {
					pos    = {
						rand.float32_range(0, f32(pix_width) + radius * 4) - radius * 2,
						rand.float32_range(0, f32(pix_width) + radius * 4) - radius * 2,
					},
					radius = radius - f32(spiral_width * 1.25), //allow slight overlap with other circles
				}
				for circle in circles {
					dist := linalg.distance(circle.pos, new_circle.pos)
					if dist < circle.radius + new_circle.radius {
						invalid_pos = true
						fails += 1
						break
					}
				}
			}
			//add circle
			append(&circles, new_circle)
			//draw spiral at that position
			this_path := make([]vec2, num_spiral_points)
			angle_degrees := rand.float32_range(0, 360)
			clockwise := rand.int_max(2) == 0
			for i in 0 ..< num_spiral_points {
				p := spiral_path[i]
				if clockwise {p.y = -p.y}
				this_path[i] = rotate_around_origin(p, angle_degrees) + new_circle.pos
			}
			for i in 1 ..< len(this_path) - 1 {
				if clockwise {
					rl.DrawTriangle(this_path[0], this_path[i], this_path[i + 1], mid_grey)
				} else {
					rl.DrawTriangle(this_path[0], this_path[i + 1], this_path[i], mid_grey)
				}
			}
			making_segment := true
			steps_until_switch := rand.float32_range(min_segment_length, max_segment_length)
			for i in 1 ..< len(this_path) - 1 {
				steps_until_switch -= 1
				if making_segment {
					rl.DrawCircleV(this_path[i], spiral_path_radius, rl.BLACK)
				}
				if steps_until_switch <= 0 {
					making_segment = !making_segment
					if making_segment {
						steps_until_switch = rand.float32_range(
							min_segment_length,
							max_segment_length,
						)
					} else {
						steps_until_switch = rand.float32_range(min_gap_length, max_gap_length)
					}
				}
			}
			//claim circle's area
			claimed_area += new_circle.radius * new_circle.radius * math.PI
		}


		rl.EndTextureMode()
		img = render_texture_to_img_buf(tex)
		// print_grid(slice_rect_from_slice(&img, {0, 0, 100, 100}), proc(c: Color) -> rune {
		// 	return c == mid_grey ? '0' : ' '
		// })
		grid := new([pix_width][pix_width]bool)
		for &r, i in img {
			for &c, j in r {
				grid[i][j] = c == mid_grey ? false : true
			}
		}
		grid = run_automaton(grid, caves, 2)
		img = bool_grid_to_img_buf(grid, proc(on: bool) -> Color {
			return !on ? mid_grey : rl.BLACK
		})
		img = replace_value(img, rl.BLACK, rl.BLANK)
		img = replace_small_chunks(
			img,
			rl.BLANK,
			mid_grey,
			int(10 * width_ratio * width_ratio),
			wrap = false,
		)
		img = replace_small_chunks(
			img,
			mid_grey,
			rl.BLANK,
			int(10 * width_ratio * width_ratio),
			wrap = false,
		)
		img = recolor_chunks(img, mid_grey, wrap = false)
	}
	return img
}

invert_grid :: proc(grid: ^[$width][width]bool) {
	for &row in grid {
		for &cell in row {
			cell = !cell
		}
	}
}

get_neighbors :: proc(x, y, width: int, wrap: bool = true, include_diag: bool = true) -> [8]int2 {
	likely_results := [8]int2 {
		{x, y + 1},
		{x + 1, y},
		{x, y - 1},
		{x - 1, y},
		{x + 1, y + 1},
		{x + 1, y - 1},
		{x - 1, y - 1},
		{x - 1, y + 1},
	}
	results := [8]int2{}
	//check for in bounds
	for likely_result, i in likely_results {
		if i == 4 && !include_diag {
			break
		}
		if wrap {
			results[i] = {likely_result.x %% width, likely_result.y %% width}
		} else if likely_result.x >= 0 &&
		   likely_result.x < width &&
		   likely_result.y >= 0 &&
		   likely_result.y < width {
			results[i] = likely_result
		} else {
			results[i] = {-1, -1}
		}
	}
	return results
}

random_noise :: proc(seed: u64, percentage: f32, $width: int) -> (grid: [width][width]bool) {
	rand_state := rand.create(seed)
	context.random_generator = rand.default_random_generator(&rand_state)
	grid = [width][width]bool{}
	for i in 0 ..< width {
		for j in 0 ..< width {
			grid[i][j] = rand.float32() <= percentage
		}
	}
	return grid
}
print_grid :: proc(grid: [][]$T, display_proc: proc(t: T) -> rune) {
	for row in grid {
		for cell in row {
			fmt.print(display_proc(cell), " ", sep = "")
		}
		fmt.println()
	}
}

IndexRect :: struct {
	x, y, width, height: uint,
}
slice_rect_from_grid :: proc(grid: ^[$width][width]$T, rect: IndexRect) -> [][]T {
	rows: [][width]T = grid[rect.x:rect.x + rect.width]
	res := make([][]T, len(rows))
	for &r, i in rows {
		res[i] = r[rect.y:rect.y + rect.height]
	}
	return res
}
grid_to_slice :: proc(grid: ^[$width][width]$T) -> [][]T {
	rows: [][width]T = grid[:]
	res := make([][]T, len(rows))
	for &r, i in rows {
		res[i] = r[:]
	}
	return res
}

slice_rect_from_slice :: proc(grid: ^[][]$T, rect: IndexRect) -> [][]T {
	rows: [][]T = grid[rect.x:rect.x + rect.width]
	res := make([][]T, len(rows))
	for &r, i in rows {
		res[i] = r[rect.y:rect.y + rect.height]
	}
	return res
}
CellularAutomatonRule :: struct {
	birth:    []int,
	survival: []int,
}
run_automaton :: proc(
	grid: ^[$width][width]bool,
	rule: CellularAutomatonRule,
	iterations: int,
	wrap: bool = true,
) -> ^[width][width]bool {
	grids := rb.RingBuffer([width][width]bool, 2){}
	rb.init(&grids)
	rb.set_current(&grids, grid)
	rb.increment(&grids) //set empty grid as current initially
	for _ in 0 ..< iterations {
		prev_grid := rb.get_prev(&grids)
		curr_grid := rb.get_current(&grids)
		// print_grid(
		// 	slice_rect_from_grid(prev_grid, {0, 0, 100, 100}),
		// 	proc(on: bool) -> rune {return on ? '0' : ' '},
		// )
		for &row, i in curr_grid {
			for &cell, j in row {
				cell = false
				cell_on_before := prev_grid[i][j]
				my_neighbors := get_neighbors(i, j, width, wrap = wrap)
				num_neighbors_on := 0
				for neighbor in my_neighbors {
					if neighbor[0] < 0 {
						continue
					}
					num_neighbors_on += int(prev_grid[neighbor[0]][neighbor[1]])
				}
				if cell_on_before && slice.contains(rule.survival, num_neighbors_on) {
					cell = true
				}
				if !cell_on_before && slice.contains(rule.birth, num_neighbors_on) {
					cell = true
				}
			}
		}
		rb.increment(&grids)
	}
	return rb.get_current(&grids)
}
FloodFillChunk :: struct($T: typeid) {
	value: T,
	cells: [dynamic]int2,
}

find_flood_fill_chunks :: proc(
	grid: [][]$T,
	include_diag_neighbors: bool = false,
	wrap: bool = true,
	allocator := context.allocator,
) -> (
	chunks: map[int]FloodFillChunk(T),
) where intrinsics.type_is_comparable(T) {
	context.allocator = allocator
	next_id := 0
	already_filled := make([][]bool, len(grid))
	for r, i in grid {
		already_filled[i] = make([]bool, len(r))
	}
	for row, i in grid {
		for cell, j in row {
			if already_filled[i][j] {
				continue
			}
			//new chunk - BFS thru neighbors with same value
			cells := [dynamic]int2{}
			append(&cells, int2{i, j})
			already_filled[i][j] = true
			for num_searched := 0; num_searched < len(cells); num_searched += 1 {
				next_cell := cells[num_searched]
				neighbors := get_neighbors(
					next_cell.x,
					next_cell.y,
					len(grid),
					include_diag = include_diag_neighbors,
					wrap = wrap,
				)
				for neighbor in neighbors {
					if neighbor[0] < 0 { 	//out of bounds
						continue
					}
					if already_filled[neighbor.x][neighbor.y] { 	//already part of this or other chunks
						continue
					}
					if grid[neighbor.x][neighbor.y] == cell {
						append(&cells, neighbor)
						already_filled[neighbor.x][neighbor.y] = true
					}
				}
			}
			chunk := FloodFillChunk(T) {
				value = cell,
				cells = cells,
			}
			chunks[next_id] = chunk
			next_id += 1
		}
	}
	return chunks
}

replace_small_chunks :: proc(
	grid: [][]$T,
	target, replacement: T,
	min_chunk_size: int = 180,
	wrap: bool = true,
) -> [][]T where intrinsics.type_is_comparable(T) {
	result := make([][]T, len(grid))
	for r, i in grid {
		result[i] = make([]T, len(r))
	}
	arena := runtime.Arena{}
	alloc_e := runtime.arena_init(&arena, 0, context.allocator)
	alloc := runtime.arena_allocator(&arena); defer free_all(alloc)
	chunks := find_flood_fill_chunks(grid, allocator = alloc, wrap = wrap)
	for _, chunk in chunks {
		val_to_write := chunk.value
		if chunk.value == target && len(chunk.cells) < min_chunk_size {
			val_to_write = replacement
		}
		for cell in chunk.cells {
			result[cell.x][cell.y] = val_to_write
		}
	}
	return result
}

replace_value :: proc(
	grid: [][]$T,
	target, replacement: T,
) -> [][]T where intrinsics.type_is_comparable(T) {
	result := make([][]T, len(grid))
	for r, i in grid {
		result[i] = make([]T, len(r))
		for c, j in grid {
			value_to_write := grid[i][j]
			if value_to_write == target {
				value_to_write = replacement
			}
			result[i][j] = value_to_write
		}
	}
	return result
}

recolor_chunks :: proc(
	grid: [][]$T,
	target: T,
	wrap: bool = true,
) -> [][]T where intrinsics.type_is_comparable(T) {
	rand_u8_range :: proc(min: u8 = 0, max: u8 = 255) -> u8 {
		return u8(rand.int_max(int(max) - int(min))) + min
	}
	rand_color :: proc() -> Color {
		return Color{rand_u8_range(50, 250), rand_u8_range(100, 250), rand_u8_range(100, 250), 255}
	}
	result := make([][]T, len(grid))
	for r, i in grid {
		result[i] = make([]T, len(r))
	}
	arena := runtime.Arena{}
	alloc_e := runtime.arena_init(&arena, 0, context.allocator)
	alloc := runtime.arena_allocator(&arena); defer free_all(alloc)
	chunks := find_flood_fill_chunks(grid, allocator = alloc, wrap = wrap)
	for id, chunk in chunks {
		if chunk.value == target {
			output_color := rand_color()
			for cell in chunk.cells {
				result[cell.x][cell.y] = output_color
			}
		}
	}
	return result
}

// save_png :: proc(grid: [][]Color, filename: string = "grid.png") {
// 	width := len(grid)
// 	pixels := make([^]Color, len(grid) * len(grid[0]))
// 	for row, i in grid {
// 		for cell, j in row {
// 			pixels[i * width + j] = cell
// 		}
// 	}
// 	stbim.write_png(
// 		strings.clone_to_cstring(filename),
// 		w = c.int(len(grid)),
// 		h = c.int(len(grid[0])),
// 		comp = 4, //number of components (bytes) per pixel
// 		data = raw_data(pixels),
// 		stride_in_bytes = i32(width) * size_of(Color),
// 	)
// 	print("saved grid to", filename)
// }

rotate_around_origin :: proc(p: vec2, angle_degrees: f32) -> vec2 {
	angle := math.to_radians(angle_degrees)
	return {
		p.x * math.cos(angle) - p.y * math.sin(angle),
		p.x * math.sin(angle) + p.y * math.cos(angle),
	}
}

spiral_length :: proc(b, t: f32) -> f32 {
	return (b / 2) * (t * math.sqrt(1 + t * t) + math.ln(t + math.sqrt(1 + t * t)))
}

generate_spiral_path :: proc(
	spiral_spacing, spiral_turns: f32,
	wind_clockwise: bool = false,
) -> []vec2 {
	path := [dynamic]vec2{}
	spacing :: 1.0
	max_length := spiral_length(spiral_spacing, spiral_turns)
	increment := math.round(max_length / spacing)
	append(&path, vec2{})
	for i in 1 ..< increment {
		min_theta: f32 = 0
		max_theta: f32 = spiral_turns
		mid_theta := (min_theta + max_theta) / 2
		MAX_ITER :: 100
		iter := 0
		EPSILON :: 0.00001
		for math.abs(spiral_length(spiral_spacing, mid_theta) - i * spacing) > EPSILON &&
		    iter < MAX_ITER {
			if spiral_length(spiral_spacing, mid_theta) > i * spacing {
				max_theta = mid_theta
			} else {
				min_theta = mid_theta
			}
			mid_theta = (min_theta + max_theta) / 2
			iter += 1
		}
		append(&path, vec2{math.cos(mid_theta), math.sin(mid_theta)} * spiral_spacing * mid_theta)
	}
	append(
		&path,
		vec2{math.cos(spiral_turns), math.sin(spiral_turns)} * spiral_spacing * spiral_turns,
	)
	return path[:]
}
img_to_buf :: proc(img: rl.Image, transpose: bool = false) -> [][]Color {
	img_multiptr := cast([^]Color)img.data
	buf_width, buf_height := img.width, img.height
	if transpose {
		buf_width, buf_height = buf_height, buf_width
	}
	buf := make([][]Color, buf_height)
	for r in 0 ..< buf_height {
		buf[r] = make([]Color, buf_width)
		for c in 0 ..< buf_width {
			idx := r * img.width + c
			if transpose {idx = c * img.width + r}
			buf[r][c] = img_multiptr[idx]
		}
	}
	return buf
}
render_texture_to_img_buf :: proc(tex: rl.RenderTexture2D) -> [][]Color {
	return img_to_buf(rl.LoadImageFromTexture(tex.texture))
}

bool_grid_to_img_buf :: proc(
	grid: ^[$width][width]bool,
	bool_to_color: proc(on: bool) -> Color,
) -> [][]Color {
	res := make([][]Color, width)
	for r in 0 ..< width {
		res[r] = make([]Color, width)
		for c in 0 ..< width {
			res[r][c] = bool_to_color(grid[r][c])
		}
	}
	return res
}


make_grid_slice :: proc($T: typeid, w, h: int) -> [][]T {
	res := make([][]T, h)
	for i in 0 ..< h {
		res[i] = make([]T, w)
	}
	return res
}
