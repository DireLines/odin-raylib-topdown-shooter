package game
import pq "core:container/priority_queue"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"

AABB :: struct {
	min, max: vec2,
}

// a line segment which is parallel to either x or y axis
AABBSide :: struct {
	start:     vec2,
	length:    f64,
	direction: enum {
		vertical,
		horizontal,
	},
}

Ray :: struct {
	pos, vel: vec2,
}

Circle :: struct {
	pos:    vec2,
	radius: f64,
}

CollisionShape :: union {
	AABB,
	Circle,
}

MovingShape :: struct {
	shape: CollisionShape,
	vel:   vec2,
}

MovingAABB :: struct {
	using aabb: AABB,
	vel:        vec2,
}

MovingCircle :: struct {
	using circle: Circle,
	vel:          vec2,
}

//point-line intersection for continuous detection
get_time_to_collide_ray_line :: proc(ray: Ray, line: AABBSide) -> (t: f64, will_collide: bool) {
	start, speed, wall: f64
	switch line.direction {
	case .vertical:
		start = ray.pos.x
		speed = ray.vel.x
		wall = line.start.x
	case .horizontal:
		start = ray.pos.y
		speed = ray.vel.y
		wall = line.start.y
	}
	//if not moving toward wall at all, need to stop divide by zero
	if speed == 0 {
		return math.inf_f64(1), false
	}
	t = (wall - start) / speed
	p_hit := ray.pos + ray.vel * t
	will_collide = t > 0 // ignore if we need to move backwards to hit wall
	//handle that we are hitting a line segment, not infinite line
	in_range :: #force_inline proc(x, low, high: f64) -> bool {
		return x > min(low, high) && x < max(low, high)
	}
	switch line.direction {
	case .vertical:
		will_collide &= in_range(p_hit.y, line.start.y, line.start.y + line.length)
	case .horizontal:
		will_collide &= in_range(p_hit.x, line.start.x, line.start.x + line.length)
	}
	return t, will_collide
}

//point-aabb intersection for continuous detection
get_time_to_collide_ray_aabb :: proc(
	ray: Ray,
	aabb: AABB,
) -> (
	t: f64,
	side: SideName,
	is_colliding, will_be_colliding: bool,
) {
	size := aabb.max - aabb.min
	sides := [SideName]AABBSide {
		.left = {start = aabb.min, direction = .vertical, length = size.y},
		.right = {start = aabb.max, direction = .vertical, length = -size.y},
		.top = {start = aabb.min, direction = .horizontal, length = size.x},
		.bottom = {start = aabb.max, direction = .horizontal, length = -size.x},
	}

	t_min := math.inf_f64(1)
	t_max := math.inf_f64(-1)
	side_min, side_max: SideName
	any_collisions := false
	#unroll for i in 0 ..< 4 {
		t_side, will_collide := get_time_to_collide_ray_line(ray, sides[SideName(i)])
		if will_collide {
			any_collisions = true
			if t_side < t_min {
				side_min = SideName(i)
				t_min = t_side
			}
			if t_side > t_max {
				side_max = SideName(i)
				t_max = t_side
			}
		}
	}
	if !any_collisions {
		return math.inf_f64(1), side, false, false
	}
	// if t_max < 0, ray (line) is intersecting AABB, but whole AABB is behind us
	if t_max < 0 {
		return -1, side, false, false
	}
	// if t_min > t_max, ray doesn't intersect AABB
	if t_min > t_max {
		return -1, side, false, false
	}
	//if t_min negative and t_max positive, ray is going from inside to outside aabb
	if t_min < 0 {
		return t_max, side_max, true, false
	}
	return t_min, side_min, false, true
}


//aabb-aabb intersection for continuous detection
get_time_to_collide_aabb_aabb :: proc(
	a, b: MovingAABB,
) -> (
	t: f64,
	side: SideName,
	normal: vec2,
	is_colliding, will_be_colliding: bool,
) {
	//account for motion by subtracting b's vel from both sides
	//reduce to ray-aabb collision by detecting collision of (center of a) with (minkowski sum of a and b))
	a_half_dims := linalg.abs((a.max - a.min) / 2)
	ray := Ray {
		pos = a.min + a_half_dims,
		vel = a.vel - b.vel,
	}
	aabb := AABB {
		min = b.min - a_half_dims,
		max = b.max + a_half_dims,
	}
	t, side, is_colliding, will_be_colliding = get_time_to_collide_ray_aabb(ray, aabb)
	normal = WALL_NORMALS[side]
	return
}

get_time_to_collide_circle_aabb :: proc(
	circle: Circle,
	circle_vel: vec2,
	aabb: AABB,
) -> (
	t: f64,
	side: SideName,
	normal: vec2,
	is_colliding, will_be_colliding: bool,
) {
	r := circle.radius

	// Check if already overlapping
	if aabb_circle_intersect(aabb, circle) {
		is_colliding = true
		return
	}

	CollisionRunningInfo :: struct {
		t:      f64,
		side:   SideName,
		normal: vec2,
	}
	best := CollisionRunningInfo {
		t = math.INF_F64,
	}
	found := false
	update_best_if_needed :: #force_inline proc(
		best: ^CollisionRunningInfo,
		new: CollisionRunningInfo,
		found: ^bool,
	) {
		if new.t > 0 && new.t < best.t {
			best^ = new
			found^ = true
		}
	}


	ray := Ray{circle.pos, circle_vel}
	// 4 flat sides of the Minkowski sum (only valid in the non-corner region)
	// mirrors get_time_to_collide_ray_aabb but with each side offset outward by r
	sides := [SideName]AABBSide {
		.left = {
			start = {aabb.min.x - r, aabb.min.y},
			length = aabb.max.y - aabb.min.y,
			direction = .vertical,
		},
		.right = {
			start = {aabb.max.x + r, aabb.min.y},
			length = aabb.max.y - aabb.min.y,
			direction = .vertical,
		},
		.top = {
			start = {aabb.min.x, aabb.min.y - r},
			length = aabb.max.x - aabb.min.x,
			direction = .horizontal,
		},
		.bottom = {
			start = {aabb.min.x, aabb.max.y + r},
			length = aabb.max.x - aabb.min.x,
			direction = .horizontal,
		},
	}
	#unroll for s in SideName {
		t_s, will_s := get_time_to_collide_ray_line(ray, sides[s])
		if will_s {update_best_if_needed(&best, CollisionRunningInfo{t_s, s, WALL_NORMALS[s]}, &found)}
	}

	// Corner tests: solve |p + vel*t - corner|^2 = r^2 for each of the 4 corners
	corners := [4]vec2{aabb.min, {aabb.max.x, aabb.min.y}, {aabb.min.x, aabb.max.y}, aabb.max}
	a_coef := linalg.dot(circle_vel, circle_vel)
	if a_coef > 0 {
		for corner in corners {
			d := circle.pos - corner
			b_coef := 2 * linalg.dot(d, circle_vel)
			c_coef := linalg.dot(d, d) - r * r
			disc := b_coef * b_coef - 4 * a_coef * c_coef
			if disc < 0 {continue}
			t_hit := (-b_coef - math.sqrt(disc)) / (2 * a_coef) // entry time (smaller root)
			if t_hit < 0 || t_hit > 1 {continue}
			if t_hit < best.t {
				best.t = t_hit
				// Pick axis-aligned side from collision normal
				normal := linalg.normalize(circle.pos + circle_vel * t_hit - corner)
				best.normal = normal
				if abs(normal.x) >= abs(normal.y) {
					best.side = .left if normal.x < 0 else .right
				} else {
					best.side = .top if normal.y < 0 else .bottom
				}
				found = true
			}
		}
	}

	if found {
		t = best.t
		side = best.side
		normal = best.normal
		will_be_colliding = true
	}
	return
}

get_time_to_collide_moving_shape_aabb :: proc(
	moving_shape: MovingShape,
	aabb: AABB,
) -> (
	t: f64,
	side: SideName,
	normal: vec2,
	is_colliding, will_be_colliding: bool,
) {
	switch s in moving_shape.shape {
	case AABB:
		moving_aabb := MovingAABB {
			aabb = s,
			vel  = moving_shape.vel,
		}
		return get_time_to_collide_aabb_aabb(moving_aabb, MovingAABB{aabb = aabb, vel = {0, 0}})
	case Circle:
		return get_time_to_collide_circle_aabb(s, moving_shape.vel, aabb)
	}
	panic("unhandled shape type in get_time_to_collide_moving_shape_aabb")
}

get_time_to_collide_circle_circle :: proc(
	a: Circle,
	a_vel: vec2,
	b: Circle,
) -> (
	t: f64,
	side: SideName,
	normal: vec2,
	is_colliding, will_be_colliding: bool,
) {
	d := a.pos - b.pos
	sum_r := a.radius + b.radius

	if linalg.dot(d, d) <= sum_r * sum_r {
		is_colliding = true
		return
	}

	a_coef := linalg.dot(a_vel, a_vel)
	if a_coef == 0 {return}
	b_coef := 2 * linalg.dot(d, a_vel)
	c_coef := linalg.dot(d, d) - sum_r * sum_r
	disc := b_coef * b_coef - 4 * a_coef * c_coef
	if disc < 0 {return}

	t_hit := (-b_coef - math.sqrt(disc)) / (2 * a_coef)
	if t_hit < 0 || t_hit > 1 {return}

	// normal points from wall circle center toward player circle center
	normal = d + a_vel * t_hit
	if abs(normal.x) >= abs(normal.y) {
		side = .left if normal.x < 0 else .right
	} else {
		side = .top if normal.y < 0 else .bottom
	}
	t = t_hit
	will_be_colliding = true
	return
}

get_time_to_collide_moving_shape_circle :: proc(
	moving_shape: MovingShape,
	circle: Circle,
) -> (
	t: f64,
	side: SideName,
	normal: vec2,
	is_colliding, will_be_colliding: bool,
) {
	switch s in moving_shape.shape {
	case Circle:
		return get_time_to_collide_circle_circle(s, moving_shape.vel, circle)
	case AABB:
		// approximate: treat the AABB as a circle for wall testing
		half := (moving_shape.shape.(AABB).max - moving_shape.shape.(AABB).min) * 0.5
		approx := Circle {
			pos    = moving_shape.shape.(AABB).min + half,
			radius = linalg.length(half),
		}
		return get_time_to_collide_circle_circle(approx, moving_shape.vel, circle)
	}
	panic("unhandled shape type in get_time_to_collide_moving_shape_circle")
}

get_time_to_collide :: proc {
	get_time_to_collide_aabb_aabb,
	get_time_to_collide_moving_shape_aabb,
	get_time_to_collide_moving_shape_circle,
	get_time_to_collide_ray_aabb,
	get_time_to_collide_ray_line,
}

shapes_contact :: proc(a, b: CollisionShape) -> (normal: vec2, depth: f64) {
	switch s_a in a {
	case AABB:
		switch s_b in b {
		case AABB:
			return aabb_aabb_contact(s_a, s_b)
		case Circle:
			n, d := circle_aabb_contact(s_b, s_a)
			return -n, d
		}
	case Circle:
		switch s_b in b {
		case AABB:
			return circle_aabb_contact(s_a, s_b)
		case Circle:
			return circle_circle_contact(s_a, s_b)
		}
	}
	panic("unhandled shape type in shapes_contact")
}

aabb_aabb_contact :: proc(a, b: AABB) -> (normal: vec2, depth: f64) {
	center_a := (a.min + a.max) * 0.5
	center_b := (b.min + b.max) * 0.5
	overlap_x := math.min(a.max.x, b.max.x) - math.max(a.min.x, b.min.x)
	overlap_y := math.min(a.max.y, b.max.y) - math.max(a.min.y, b.min.y)
	if overlap_x <= overlap_y {
		depth = overlap_x
		normal = {math.sign(center_a.x - center_b.x), 0}
	} else {
		depth = overlap_y
		normal = {0, math.sign(center_a.y - center_b.y)}
	}
	return
}

circle_circle_contact :: proc(a, b: Circle) -> (normal: vec2, depth: f64) {
	diff := a.pos - b.pos
	dist := linalg.length(diff)
	depth = a.radius + b.radius - dist
	if dist > 0 {
		normal = diff / dist
	} else {
		normal = {1, 0}
	}
	return
}

// normal points from aabb toward circle (i.e. the direction the circle should move to resolve)
circle_aabb_contact :: proc(circle: Circle, box: AABB) -> (normal: vec2, depth: f64) {
	closest := linalg.clamp(circle.pos, box.min, box.max)
	diff := circle.pos - closest
	dist := linalg.length(diff)
	depth = circle.radius - dist
	if dist > 0 {
		normal = diff / dist
		return
	}
	// circle center is inside the AABB — find minimum penetration axis to exit
	to_min := circle.pos - box.min
	to_max := box.max - circle.pos
	min_dist := math.min(to_min.x, math.min(to_min.y, math.min(to_max.x, to_max.y)))
	switch min_dist {
	case to_min.x:
		normal = {-1, 0}
		depth = circle.radius + to_min.x
	case to_max.x:
		normal = {1, 0}
		depth = circle.radius + to_max.x
	case to_min.y:
		normal = {0, -1}
		depth = circle.radius + to_min.y
	case:
		normal = {0, 1}
		depth = circle.radius + to_max.y
	}
	return
}

shapes_intersect :: proc(a, b: CollisionShape) -> bool {
	//TODO: obviously this doesnt scale.
	// Need a better solution when we have more shapes. With only 2 its fine for now.
	switch s_a in a {
	case AABB:
		switch s_b in b {
		case AABB:
			return aabb_intersect(s_a, s_b)
		case Circle:
			return aabb_circle_intersect(s_a, s_b)
		}
	case Circle:
		switch s_b in b {
		case AABB:
			return aabb_circle_intersect(s_b, s_a)
		case Circle:
			return circle_intersect(s_a, s_b)
		}
	}
	panic("unhandled shape type in shapes_intersect")
}

aabb_circle_intersect :: proc(a: AABB, b: Circle) -> bool {
	closest_point := linalg.clamp(b.pos, a.min, a.max)
	return linalg.distance(closest_point, b.pos) <= b.radius
}
circle_intersect :: proc(a, b: Circle) -> bool {
	return linalg.distance(a.pos, b.pos) <= a.radius + b.radius
}
aabb_intersect :: proc(a, b: AABB) -> bool {
	return (a.min.x <= b.max.x && a.max.x >= b.min.x) && (a.min.y <= b.max.y && a.max.y >= b.min.y)
}
aabb_overlap :: proc(a, b: AABB) -> AABB {
	return {min = linalg.max(a.min, b.min), max = linalg.min(a.max, b.max)}
}
aabb_to_rect :: proc(aabb: AABB) -> Rect {
	top_left := aabb.min
	dims := aabb.max - aabb.min
	return {x = top_left.x, y = top_left.y, width = dims.x, height = dims.y}
}
rect_to_aabb :: proc(r: Rect) -> AABB {
	return {{r.x, r.y}, {r.x + r.width, r.y + r.height}}
}

//helpers for finding points to spawn stuff
random_point_in_tile :: proc(id: TilemapTileId) -> vec2 {
	aabb := get_tile_aabb(id)
	return {rand.float64_range(aabb.min.x, aabb.max.x), rand.float64_range(aabb.min.y, aabb.max.y)}
}
is_point_in_tile :: proc(p: vec2, id: TilemapTileId) -> bool {
	return is_point_in_aabb(p, get_tile_aabb(id))
}
random_point_in_circle :: proc(center: vec2, radius: f64) -> vec2 {
	disp := mat_vec_mul(
		rotate_degrees(rand.float64_range(0, 360)),
		{math.sqrt(rand.float64()) * radius, 0},
	)
	return center + disp
}
is_point_in_circle :: proc(p, center: vec2, radius: f64) -> bool {
	return linalg.distance(p, center) <= radius
}
random_point_in_radius_range :: proc(center: vec2, min_radius, max_radius: f64) -> vec2 {
	r := math.sqrt(rand.float64_range(min_radius * min_radius, max_radius * max_radius))
	disp := mat_vec_mul(rotate_degrees(rand.float64_range(0, 360)), {r, 0})
	return center + disp
}
is_point_in_radius_range :: proc(p, center: vec2, min_radius, max_radius: f64) -> bool {
	return is_point_in_circle(p, center, max_radius) && !is_point_in_circle(p, center, min_radius)
}

random_point_in_visible_range :: proc(center: vec2, radius: f64) -> vec2 {
	p := random_point_in_circle(center, radius)
	for !has_line_of_sight(center, p) {
		p = random_point_in_circle(center, radius)
	}
	return p
}
dda :: proc(a, b: vec2, STEP: f64 = 1) -> []vec2 {
	points := make([dynamic]vec2, context.temp_allocator)
	d := b - a
	coord := math.abs(d.x) > math.abs(d.y) ? 0 : 1 //stepping horizontally or vertically?
	if d[coord] == 0 {
		return points[:]
	}
	if d[coord] < 0 {
		//if moving in negative direction, pretend the points came in the other order (handles integer endpoint cases)
		return dda(b, a, STEP)
	}
	u := (d / d[coord]) * STEP
	nearest_multiple_below :: proc(a, b: f64) -> f64 {
		return math.floor(a / b) * b
	}
	offset_factor := (a[coord] - nearest_multiple_below(a[coord], STEP)) / STEP
	if offset_factor > 0 {
		offset_factor = 1 - offset_factor
	}
	o := u * (offset_factor / STEP) //initial offset vector
	p := a //point we're filling in the closest pixel to
	p = p + o
	dist_traveled := offset_factor * STEP
	for dist_traveled < d[coord] {
		append(&points, p)
		p = p + u
		dist_traveled += STEP
	}
	return points[:]
}


//all tiles intersecting the line segment from A to B
tiles_intersecting_line :: proc(a, b: vec2) -> []TilemapTileId {
	STEP: f64 = TILE_SIZE
	tiles := make([dynamic]TilemapTileId, context.temp_allocator)
	diff := b - a
	coord := math.abs(diff.x) > math.abs(diff.y) ? 0 : 1 //stepping horizontally or vertically?
	if diff[coord] == 0 {
		return tiles[:]
	}
	if diff[coord] < 0 {
		//if moving in negative direction, pretend the tiles came in the other order (handles integer endpoint cases)
		return tiles_intersecting_line(b, a)
	}
	other_coord := 1 - coord
	step_vector := (diff / diff[coord]) * STEP
	nearest_multiple_below :: proc(a, b: f64) -> f64 {
		//nearest multiple of b below a
		return math.floor(a / b) * b
	}
	dist_to_grid_line := a[coord] - nearest_multiple_below(a[coord], STEP)
	if dist_to_grid_line > 0 {
		dist_to_grid_line = STEP - dist_to_grid_line
	}
	step_to_grid_line := step_vector * (dist_to_grid_line / STEP)
	p := a //point we're filling in the closest pixel to
	dist_traveled: f64 = 0
	t_prev: TilemapTileId
	for dist_traveled < diff[coord] {
		t_prev = get_containing_tile(p)
		p_grid := p + step_to_grid_line
		p = p + step_vector
		t_p := get_containing_tile(p)
		t_grid := get_containing_tile(p_grid)
		append(&tiles, t_prev)
		if t_prev[other_coord] == t_p[other_coord] {
			//still on same tile horizontally - not responsible for any diagonals
		} else if t_prev[other_coord] == t_grid[other_coord] {
			diag := t_p
			diag[other_coord] = t_prev[other_coord]
			append(&tiles, diag)
		} else {
			diag := t_p
			diag[coord] = t_prev[coord]
			append(&tiles, diag)
		}
		dist_traveled += STEP
	}
	//finally, handle endpoint which might be skipped over in the loop exit condition
	t_b := get_containing_tile(b)
	if t_b != t_prev {
		append(&tiles, get_containing_tile(b))
	}
	return tiles[:]
}

// thick_line_tiles :: proc(a, b: vec2, thickness: f64 = 0) -> []TilemapTileId {}

//DDA from a to b over tiles, stop if any of them are walls
has_line_of_sight :: proc(a, b: vec2) -> bool {
	tiles := tiles_intersecting_line(a, b)
	d := b - a
	coord := math.abs(d.x) > math.abs(d.y) ? 0 : 1 //stepping horizontally or vertically?
	for i in 0 ..< len(tiles) - 1 {
		t := tiles[i]
		if get_tile(t).type == .Wall {
			return false
		}
	}
	return true
}


//DDA from a to b over tiles, stop if any of them are walls
print_line_of_sight :: proc(a, b: vec2) {
	tiles := tiles_intersecting_line(a, b)
	d := b - a
	coord := math.abs(d.x) > math.abs(d.y) ? 0 : 1 //stepping horizontally or vertically?
	blocked := false
	for i in 0 ..< len(tiles) - 1 {
		t := tiles[i]
		if get_tile(t).type == .Wall {
			blocked = true
		}
	}
	for i in 0 ..< len(tiles) - 1 {
		t := tiles[i]
		draw_debug_box(get_tile_aabb(t), color = blocked ? DEBUG_RED : DEBUG_GREEN)
	}

}

TilePath :: []TilemapTileId
distance_between_tile_centers :: proc(a, b: TilemapTileId) -> f64 {
	return f64(linalg.distance(get_tile_center(a), get_tile_center(b))) / TILE_SIZE
}
//normal A* algorithm on the tilemap
get_unoptimized_a_star_path :: proc(
	a, b: vec2,
	heuristic: proc(a, b: TilemapTileId) -> f64 = distance_between_tile_centers,
	max_depth: f64 = 200,
) -> TilePath {
	start := get_containing_tile(a)
	end := get_containing_tile(b)
	num_tiles_considered := 0
	// The set of discovered nodes that may need to be (re-)expanded.
	// Initially, only the start node is known.
	// This is usually implemented as a min-heap or priority queue rather than a hash-set.
	Candidate :: struct {
		tile:  TilemapTileId,
		score: f64,
	}
	candidates: pq.Priority_Queue(Candidate)
	pq.init(&candidates, less = proc(a, b: Candidate) -> bool {
			return a.score < b.score
		}, swap = pq.default_swap_proc(Candidate), allocator = context.temp_allocator)
	pq.push(&candidates, Candidate{start, heuristic(start, end)})

	// For node n, cameFrom[n] is the node immediately preceding it on the cheapest path from the start
	// to n currently known.
	came_from := make(map[TilemapTileId]TilemapTileId, context.temp_allocator)

	// For node n, cheapest_path_cost[n] is the currently known cost of the cheapest path from start to n.
	cheapest_path_cost := make(map[TilemapTileId]f64, context.temp_allocator)
	cheapest_path_cost[start] = 0

	// For node n, estimated_path_cost[n] := cheapest_path_cost[n] + heuristic(n). estimated_path_cost[n] represents our current best guess as to
	// how cheap a path could be from start to finish if it goes through n.
	estimated_path_cost := make(map[TilemapTileId]f64, context.temp_allocator)
	estimated_path_cost[start] = heuristic(start, end)
	max_tiles_considered := int(max_depth) * 5 //assume failure if not reached by this point - unless the map is incredibly maze-y this won't be a false negative
	for pq.len(candidates) > 0 && num_tiles_considered < max_tiles_considered {
		num_tiles_considered += 1
		candidate := pq.pop(&candidates)
		current := candidate.tile
		if current == end {
			reconstruct_path :: proc(
				came_from: map[TilemapTileId]TilemapTileId,
				end: TilemapTileId,
			) -> TilePath {
				current := end
				path := make([dynamic]TilemapTileId)
				for (current in came_from) {
					append(&path, current)
					current = came_from[current]
				}
				slice.reverse(path[:])
				return TilePath(path[:])
			}
			return reconstruct_path(came_from, current)
		}
		neighbors := get_neighbors(current)
		for neighbor in neighbors {
			//stop after max depth reached
			if cheapest_path_cost[current] > max_depth {
				continue
			}
			//skip walls
			if get_tile(neighbor).type == .Wall {
				continue
			}
			maybe_cheapest_path_cost := cheapest_path_cost[current] + 1
			neighbor_prev_cost := math.INF_F64
			if neighbor in cheapest_path_cost {
				neighbor_prev_cost = cheapest_path_cost[neighbor]
			}
			if maybe_cheapest_path_cost < neighbor_prev_cost {
				came_from[neighbor] = current
				cheapest_path_cost[neighbor] = maybe_cheapest_path_cost
				estimated_path_cost[neighbor] = maybe_cheapest_path_cost + heuristic(neighbor, end)
				neighbor_is_already_candidate := false
				for c in candidates.queue {
					if c.tile == neighbor {
						neighbor_is_already_candidate = true
						break
					}
				}
				if !neighbor_is_already_candidate {
					pq.push(&candidates, Candidate{neighbor, estimated_path_cost[neighbor]})
				}
			}
		}
	}

	// Open set is empty but goal was never reached - failed to find path
	return {}
}


//a more optimized path taking shortcuts between points when able
//start from the unoptimized a* path
//if a->b->c is in the path, but a and c have line of sight, remove b from the path
//repeat until cannot eliminate anything in this way
get_a_star_path :: proc(a, b: vec2) -> TilePath {
	unoptimized_path := get_unoptimized_a_star_path(a, b)
	if len(unoptimized_path) <= 2 {
		//shortcuts don't make sense in short enough path
		return unoptimized_path
	}
	path := make([dynamic]TilemapTileId, context.temp_allocator)
	curr_tile := unoptimized_path[0]
	append(&path, curr_tile)
	i := 0
	for i != len(unoptimized_path) - 1 {
		next := curr_tile
		curr_center := get_tile_center(curr_tile)
		for has_line_of_sight(curr_center, get_tile_center(next)) {
			if i == len(unoptimized_path) - 1 {
				break
			}
			i += 1
			next = unoptimized_path[i]
		}
		farthest_visible := unoptimized_path[i - 1]
		if i == len(unoptimized_path) - 1 {
			farthest_visible = unoptimized_path[i]
		}
		append(&path, farthest_visible)
		curr_tile = farthest_visible
	}
	return TilePath(path[:])
}
//look up the path for the last waypoint you currently have line of sight to
get_farthest_visible_point_in_path :: proc(p: vec2, path: TilePath) -> vec2 {
	result := p
	for tile in path {
		center := get_tile_center(tile)
		if !has_line_of_sight(p, center) {
			return result
		}
		result = center
	}
	return result
}
is_point_in_aabb :: proc(p: vec2, aabb: AABB) -> bool {
	return p.x >= aabb.min.x && p.x < aabb.max.x && p.y >= aabb.min.y && p.y < aabb.max.y
}

// // basic way using half spaces
// is_point_in_triangle :: proc(p, a, b, c: vec2) -> bool {
// 	tri_sign :: proc(a, b, c: vec2) -> f64 {
// 		return (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
// 	}
// 	d1 := tri_sign(p, a, b)
// 	d2 := tri_sign(p, b, c)
// 	d3 := tri_sign(p, c, a)
// 	has_neg := (d1 < 0) || (d2 < 0) || (d3 < 0)
// 	has_pos := (d1 > 0) || (d2 > 0) || (d3 > 0)
// 	return !(has_neg && has_pos)
// }

// a hopefully math-ops-optimized version of the above i ported to odin
// Source - https://stackoverflow.com/questions/2049582/how-to-determine-if-a-point-is-in-a-2d-triangle
// Posted by John Bananas
// Retrieved 2026-01-20, License - CC BY-SA 4.0
is_point_in_triangle :: proc(p, a, b, c: vec2) -> bool {
	ap := p - a
	ab := b - a
	ac := c - a
	//since we're in 2d, all triangles have the same normal plane, so all that matters is the sign of one component of the cross product
	a_cross_b_has_positive_z :: proc(a, b: vec2) -> bool {
		return a.x * b.y - a.y * b.x > 0
	}
	ab_x_ap_has_positive_z := a_cross_b_has_positive_z(ab, ap)
	if a_cross_b_has_positive_z(ac, ap) == ab_x_ap_has_positive_z {
		return false
	}
	bc := c - b
	bp := p - b
	return a_cross_b_has_positive_z(bc, bp) == ab_x_ap_has_positive_z
}

get_bounding_box_for_moving_shape :: proc(moving_shape: MovingShape) -> AABB {
	switch s in moving_shape.shape {
	case AABB:
		corners := [4]vec2{s.max, s.min, s.min + moving_shape.vel, s.max + moving_shape.vel}
		overall_min := corners[0]
		overall_max := corners[0]
		#unroll for i in 1 ..< 4 {
			overall_min = linalg.min(overall_min, corners[i])
			overall_max = linalg.max(overall_max, corners[i])
		}
		return {min = overall_min, max = overall_max}
	case Circle:
		r := s.radius
		start_center := s.pos
		end_center := s.pos + moving_shape.vel
		overall_min := linalg.min(start_center, end_center) - vec2{r, r}
		overall_max := linalg.max(start_center, end_center) + vec2{r, r}
		return {min = overall_min, max = overall_max}
	}
	panic("unhandled shape type in get_bounding_box_for_moving_shape")
}

//TODO iterator over sliding rectangle

// ok so you have an object with a hitbox of size h
// you want to know
//     can that object slide from a to b without hitting any walls?
// for convenience, you can pass in where the hitbox is relative to the ray to account for off-center placements of hitboxes
// if you don't pass it in the aabb will be assumed to be centered on the ray
box_cast_tiles :: proc(box: AABB, a, b: vec2, box_pivot: vec2) -> bool {
	// basically, you want the minkowski sum of the ray a->b and the aabb in ray's coordinates
	// minkowski sum is convex hull of the 8 corners between the initial and shifted versions of the aabb - in general a hexagon
	// get minkowski sum vertices / tris
	box_center_start := a + box_pivot
	box_center_end := b + box_pivot
	box_ray_sum_corners: [8]vec2 = {}
	#unroll for i in 0 ..< 4 {
		box_ray_sum_corners[i] = box_center_start
	}
	#unroll for i in 4 ..< 8 {
	}
	// get_tilemap_corners()

	// iterate over all the tiles in the aabb of this minkowski sum
	//     (n^2 even though when n is small it's a linear number of tiles - figure this out later, probably iterator over tiles in a slightly larger sliding rectangle)
	// make_tilemap_iterator()
	// and for each one check if it's a wall and the tile aabb overlaps the minkowski sum at any point (standard polygon-aabb intersect query with the 4 tris of the sum shape)
	// if so, reject the boxcast
	return false
}
