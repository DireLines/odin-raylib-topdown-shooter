package game

import "core:math"
import "core:math/linalg"
import "core:slice"
import hm "handle_map_static"

//physics and collision math & update logic

PhysicsInfo :: struct {
	//instantaneous velocity - this is added to velocity in physics calculation but does not accumulate
	//this is because some motions are easier to express in terms of setting velocity than setting acceleration
	inst_velocity:          vec2, //world units per second
	velocity, acceleration: vec2, //world units per second
	linear_drag:            f64,
	//instantaneous angular velocity -  this is added to angular velocity in physics calculation but does not accumulate
	//this is because some motions are easier to express in terms of setting velocity than setting acceleration
	inst_angular_velocity:  f64, //degrees per second
	angular_velocity:       f64, //degrees per second
	angular_acceleration:   f64, //degrees per second
	angular_drag:           f64,
}

CollisionProperties :: struct {
	layer:          CollisionLayer,
	trigger_events: bool, //if true, trigger collision events for gameplay scripts
	resolve:        bool, //if true, do collision resolution physics
}

Hitbox :: struct {
	shape:           CollisionShape,
	using collision: CollisionProperties,
}

MovingHitbox :: struct {
	moving_shape:    MovingShape,
	using collision: CollisionProperties,
}

CollisionEventType :: enum {
	start,
	stay,
	stop,
}
DiscreteCollision :: struct {
	normal:            vec2,
	penetration_depth: f64,
}
ContinuousCollision :: struct {
	time_to_collide: f64,
	normal:          vec2,
}
CollisionInfo :: union {
	DiscreteCollision,
	ContinuousCollision,
}

Collision :: struct {
	a, b: union {
		GameObjectHandle,
		TilemapTileId,
	},
	info: CollisionInfo,
	type: CollisionEventType,
}

layers_can_collide :: proc(a, b: CollisionLayer) -> bool {
	return b in COLLISION_MATRIX[a] || a in COLLISION_MATRIX[b]
}

SideName :: enum {
	left,
	right,
	top,
	bottom,
}
@(rodata)
WALL_NORMALS := [SideName]vec2 {
	.left   = {-1, 0},
	.right  = {1, 0},
	.top    = {0, -1},
	.bottom = {0, 1},
}

get_chunk_aabb :: proc(id: ChunkId) -> AABB {
	top_left := vec2{f64(id.x) * CHUNK_WIDTH, f64(id.y) * CHUNK_HEIGHT}
	return {top_left, top_left + {CHUNK_WIDTH, CHUNK_HEIGHT}}
}

get_containing_chunk :: proc(p: vec2) -> ChunkId {
	return {int(math.floor(p.x / CHUNK_WIDTH)), int(math.floor(p.y / CHUNK_HEIGHT))}
}

get_containing_chunk_for_tile :: proc(id: TilemapTileId) -> ChunkId {
	return {int(id.x / CHUNK_WIDTH_TILES), int(id.y / CHUNK_HEIGHT_TILES)}
}
get_chunks_between :: proc(a, b: ChunkId) -> []ChunkId {
	ids := make([dynamic]ChunkId, allocator = context.temp_allocator)
	min: ChunkId = linalg.min(a, b)
	max: ChunkId = linalg.max(a, b)
	for x in min.x ..= max.x {
		for y in min.y ..= max.y {
			append(&ids, ChunkId{x, y})
		}
	}
	return ids[:]
}

get_pos_delta :: proc(obj: ^GameObject, dt: f64) -> vec2 {
	new_accel := obj.acceleration - obj.linear_drag * obj.velocity
	return 0.5 * new_accel * dt * dt + obj.velocity * dt
}
get_moving_hitbox_for_object :: proc(
	obj: ^GameObject,
	transform: mat3,
	dt: f64,
	precalculated_delta: Maybe(vec2) = nil,
) -> MovingHitbox {
	m := transform * pivot(obj.transform)
	vel := precalculated_delta.? or_else get_pos_delta(obj, dt)
	switch s in obj.hitbox.shape {
	case AABB:
		c1, c2 := mat_vec_mul(m, s.min), mat_vec_mul(m, s.max)
		return {
			moving_shape = MovingShape {
				shape = AABB{linalg.min(c1, c2), linalg.max(c1, c2)},
				vel = vel,
			},
			collision = obj.hitbox.collision,
		}
	case Circle:
		scale := linalg.length(vec2{m[0][0], m[1][0]})
		return {
			moving_shape = MovingShape {
				shape = Circle{pos = mat_vec_mul(m, s.pos), radius = s.radius * scale},
				vel = vel,
			},
			collision = obj.hitbox.collision,
		}
	}
	panic("unhandled shape in get_moving_hitbox_for_object")
}

get_texture_aabb_for_object :: proc(obj: ^GameObject, transform: mat3) -> AABB {
	r := obj.texture.rect
	c1, c2 := mat_vec_mul(transform, {}), mat_vec_mul(transform, {r.width, r.height})
	return {linalg.min(c1, c2), linalg.max(c1, c2)}
}


remake_chunks :: proc(dt: f64) {
	clear_map(&game.objects_in_multiple_chunks)
	clear_map(&game.chunks)
	it := hm.make_iter(&game.objects)
	for obj, h in hm.iter(&it) {
		new_chunks: []ChunkId
		if .Collide in obj.tags {
			//make sure obj is in the right chunks and only those chunks
			//since object hitbox is a contiguous shape,
			//it's sufficient to get the rectangle of chunk ids between those which contain the top left and bottom right corners of the box

			//typically:
			//many objects per chunk, but only 1 or 2 chunks per object
			//objects stay in same chunks as last frame
			//optimize for this case
			box := get_bounding_box_for_moving_shape(
				get_moving_hitbox_for_object(obj, game.final_transforms[h.idx].transform, dt).moving_shape,
			)
			new_chunks = get_chunks_between(
				get_containing_chunk(box.min),
				get_containing_chunk(box.max),
			)
		} else {
			//non-colliding objects still need to be added to chunks for rendering
			//since only chunks close to the camera need to be drawn
			new_chunks = {
				get_containing_chunk(mat_vec_mul(game.final_transforms[h.idx].transform, {0, 0})),
			}
		}
		if len(new_chunks) > 1 {
			game.objects_in_multiple_chunks[h] = {}
		}
		//update chunks
		for chunk_id in new_chunks {
			if chunk_id not_in game.chunks {
				game.chunks[chunk_id] = make(
					[dynamic]GameObjectHandle,
					allocator = context.temp_allocator,
				)
			}
			append(&game.chunks[chunk_id], h)
		}
	}
}


ObjectPair :: [2]GameObjectHandle
Handle_Hitbox :: struct {
	handle:     GameObjectHandle,
	bounds:     AABB,
	moving_box: MovingHitbox,
}

physics_update :: proc(dt: f64) {
	timer := timer()
	//set up initial state of collisions
	{
		for _, v in game.collisions {
			delete(v)
		}
		clear_map(&game.collisions)
	}
	timer->time("clear collisions")
	//for all object pairs which are in prev_frame collisions: produce collision stop events
	//collision detection logic finds all collisions which are happening, so any events not overwritten are valid stop events
	{
		for h, prev_colls in game.prev_frame.collisions {
			clear(&game.collisions[h])
			for collision in game.prev_frame.collisions[h] {
				if collision.type != .stop {
					if h not_in game.collisions {
						game.collisions[h] = make([dynamic]Collision)
					}
					new_coll := collision
					new_coll.type = .stop
					append(&game.collisions[h], new_coll)
				}
			}
		}
	}
	timer->time("initialize collisions")
	objects_tested := make(map[GameObjectHandle]struct{}, allocator = context.temp_allocator)
	collisions_found_in_multiple_chunks := make(
		map[ObjectPair]struct{},
		allocator = context.temp_allocator,
	)
	//physics/tilemap phase
	//for each chunk:
	//    for each object in chunk:
	//        record starting physics info
	//		  move the object (resolving collisions with walls) and record collisions with tilemap
	for _, objects_in_chunk in game.chunks {
		for h in objects_in_chunk {
			if _, tested := objects_tested[h]; tested {
				continue // this avoids double-moving objects in multiple chunks
			}

			//move the object
			tilemap_collisions := move_object(h, dt)

			//merge these collisions with the existing ones
			for coll in tilemap_collisions {
				was_colliding_before := false
				if h in game.prev_frame.collisions {
					for prev_collision, i in game.prev_frame.collisions[h] {
						#partial switch prev_coll_handle in prev_collision.b {
						case TilemapTileId:
							if prev_collision.type != .stop && prev_coll_handle == coll.b {
								was_colliding_before = true
							}
						}
					}
				}
				if h not_in game.collisions {
					game.collisions[h] = make([dynamic]Collision)
				}
				new_coll := coll
				new_coll.type = .start
				if was_colliding_before {
					new_coll.type = .stay
				}
				current_coll_idx := -1
				for current_coll, i in game.collisions[h] {
					#partial switch coll_handle in current_coll.b {
					case TilemapTileId:
						if coll_handle == coll.b {
							current_coll_idx = i
						}
					}
				}
				if current_coll_idx == -1 {
					append(&game.collisions[h], new_coll)
				} else {
					game.collisions[h][current_coll_idx] = new_coll
				}
			}

			objects_tested[h] = {}
		}
	}
	timer->time("move objects")
	//collision phase
	//for each chunk:
	//    gather, sort and sweep boxes in chunk
	//    sort and sweep boxes in chunk
	//    for each object in chunk:
	//	      detect collisions with other objects and record them
	for chunk_id, objects_in_chunk in game.chunks {
		//collect and sort hitboxes in the scene
		boxes := make([dynamic]Handle_Hitbox, allocator = context.temp_allocator)
		for h in objects_in_chunk {
			obj := hm.get(&game.objects, h)
			if .Collide in obj.tags {
				moving_box := get_moving_hitbox_for_object(
					obj,
					game.final_transforms[h.idx].transform,
					dt,
				)
				bounds := get_bounding_box_for_moving_shape(moving_box.moving_shape)
				append(&boxes, Handle_Hitbox{handle = h, bounds = bounds, moving_box = moving_box})
			}
		}
		slice.sort_by_key(boxes[:], proc(it: Handle_Hitbox) -> f64 {return it.bounds.min.x})

		//keep mapping of obj -> box index
		handle_to_hitbox_index := make(
			map[GameObjectHandle]int,
			allocator = context.temp_allocator,
		)
		reserve_map(&handle_to_hitbox_index, len(objects_in_chunk))
		for b, i in boxes {
			handle_to_hitbox_index[b.handle] = i
		}
		OBJECTS_IN_CHUNK: for h in objects_in_chunk {
			//TODO: this needs to change when objects can have multiple hitboxes
			//since detection/resolution happens per object
			//for each hitbox in the object, look up its index in boxes and start iterating from there
			//keep running min over all hitboxes, and keep track of which hitbox on each obj was involved in the collision
			obj := hm.get(&game.objects, h)
			if .Collide not_in obj.tags {continue}

			//find object's hitbox within boxes
			a_idx, ok := handle_to_hitbox_index[h]
			a := boxes[a_idx]
			//check other objects in chunk (discrete)
			BOXES: for j := a_idx + 1; j < len(boxes); j += 1 {
				b := boxes[j]
				b_obj := hm.get(&game.objects, b.handle)
				if b.bounds.min.x > a.bounds.max.x {continue OBJECTS_IN_CHUNK}
				if a.handle == b.handle {continue} 	//will only be useful when objects have multiple hitboxes
				if .Collide not_in b_obj.tags {continue}
				if !layers_can_collide(a.moving_box.layer, b.moving_box.layer) {continue}
				if !shapes_intersect(
					a.moving_box.moving_shape.shape,
					b.moving_box.moving_shape.shape,
				) {continue}
				//annoying and costly edge case - collision can be detected multiple times in multiple chunks, need to dedup by object id pair
				if a.handle in game.objects_in_multiple_chunks &&
				   b.handle in game.objects_in_multiple_chunks {
					pair := ObjectPair{a.handle, b.handle}
					if pair in collisions_found_in_multiple_chunks {
						continue
					} else {
						collisions_found_in_multiple_chunks[pair] = {}
					}
				}
				//ok, collision is officially happening for this pair of objects. add to game.collisions, symmetrically
				normal, depth := shapes_contact(
					a.moving_box.moving_shape.shape,
					b.moving_box.moving_shape.shape,
				)
				if a.moving_box.resolve && b.moving_box.resolve {
					obj_a := hm.get(&game.objects, a.handle)
					obj_b := hm.get(&game.objects, b.handle)
					if obj_a != nil && obj_b != nil {
						obj_a.position += normal * depth * 0.5
						obj_b.position -= normal * depth * 0.5
					}
				}
				new_coll_a := Collision {
					a = h,
					b = b.handle,
					info = DiscreteCollision{normal = normal, penetration_depth = depth},
				}
				new_coll_b := Collision {
					a = b.handle,
					b = h,
					info = DiscreteCollision{normal = -normal, penetration_depth = depth},
				}
				add_collision(h, new_coll_a)
				add_collision(b.handle, new_coll_b)
				add_collision :: proc(h: GameObjectHandle, collision: Collision) {
					collision := collision
					if h not_in game.collisions {
						game.collisions[h] = make([dynamic]Collision)
					}
					was_colliding_before := false
					if h in game.prev_frame.collisions {
						for prev_collision, i in game.prev_frame.collisions[h] {
							#partial switch prev_coll_handle in prev_collision.b {
							case GameObjectHandle:
								if prev_collision.type != .stop &&
								   prev_coll_handle == collision.b {
									was_colliding_before = true
								}
							}
						}
					}
					collision.type = .start
					if was_colliding_before {
						collision.type = .stay
					}
					current_coll_idx := -1
					for current_coll, i in game.collisions[h] {
						#partial switch coll_handle in current_coll.b {
						case GameObjectHandle:
							if coll_handle == collision.b {
								current_coll_idx = i
							}
						}
					}
					if current_coll_idx == -1 {
						append(&game.collisions[h], collision)
					} else {
						game.collisions[h][current_coll_idx] = collision
					}
				}
			}
		}
	}
	timer->time("detect collisions")
}

move_object :: proc(obj_handle: GameObjectHandle, dt: f64) -> []Collision {
	PhysicsUpdate :: struct {
		accel, vel, pos_delta:                 vec2,
		angular_accel, angular_vel, rot_delta: f64,
	}
	kinematic_update :: proc(obj: ^GameObject, dt: f64) -> (phys: PhysicsUpdate) {
		//linear
		phys.accel = obj.acceleration - obj.linear_drag * obj.velocity
		phys.vel = obj.velocity + phys.accel * dt
		phys.pos_delta = 0.5 * phys.accel * dt * dt + obj.velocity * dt + obj.inst_velocity * dt
		//angular
		phys.angular_accel = obj.angular_acceleration - obj.angular_drag * obj.angular_velocity
		phys.angular_vel = obj.angular_velocity + phys.angular_accel * dt
		phys.rot_delta =
			0.5 * phys.angular_accel * dt * dt +
			obj.angular_velocity * dt +
			obj.inst_angular_velocity * dt
		return phys
	}
	apply_phys_update :: proc(obj: ^GameObject, phys: PhysicsUpdate) {
		obj.acceleration = phys.accel
		obj.velocity = phys.vel
		obj.angular_acceleration = phys.angular_accel
		obj.angular_velocity = phys.angular_vel
	}
	//reset instantaneous data for next frame
	reset_instantaneous_state :: proc(obj: ^GameObject) {
		obj.acceleration = {0, 0}
		obj.inst_velocity = {0, 0}
		obj.angular_acceleration = 0
		obj.inst_angular_velocity = 0
	}
	collisions := make([dynamic]Collision, allocator = context.temp_allocator)
	obj := hm.get(&game.objects, obj_handle)
	phys_update := kinematic_update(obj, dt)
	pos_delta := phys_update.pos_delta
	rot_delta := phys_update.rot_delta
	if pos_delta == {0, 0} && rot_delta == 0 {
		return {}
	}
	apply_phys_update(obj, phys_update)
	//objects which cannot collide apply the motion normally
	if .Collide not_in obj.tags {
		obj.position += pos_delta
		obj.rotation += rot_delta
		reset_instantaneous_state(obj)
		return {}
	}
	//objects which can collide do this up to 4 times:
	//	check to see if they will collide with a wall
	//  if so:
	//		record the collision
	//		apply movement up to the collision
	//		cancel out component of velocity heading into wall
	//		subtract time taken to collide from remaining time
	//	else:
	//		move normally for the remaining time, exit loop
	t_remaining := dt
	for i := 0; i < 4 && t_remaining > 0; i += 1 {
		delta_frac_remaining := t_remaining / dt
		//TODO this will need to change when objects have multiple hitboxes, iterate over each hitbox and find overall t_min
		obj_box := get_moving_hitbox_for_object(
			obj,
			game.final_transforms[obj_handle.idx].transform,
			dt,
			pos_delta,
		)
		obj_bounds := get_bounding_box_for_moving_shape(obj_box.moving_shape)
		//find next collision in tilemap, setting t_min
		t_min: f64 = 1
		will_collide := false
		side_min: SideName
		normal_min: vec2
		tile_min: TilemapTileId
		tiles_min := make([dynamic]TilemapTileId, allocator = context.temp_allocator) //in case of ties
		offsets_needed := [SideName]bool{}
		offset_threshold :: 1
		tiles: TilemapIterator
		tilemap_min, tilemap_max := get_tilemap_corners(obj_bounds)
		tiles = make_tilemap_iterator(tilemap_min, tilemap_max)
		for tile_id in tilemap_iter(&tiles) {
			tile_props := TILE_PROPERTIES[get_tile(tile_id).type]
			if !layers_can_collide(tile_props.layer, obj.hitbox.layer) {
				continue
			}
			if tile_props.resolve {
				tile_aabb := MovingAABB {
					aabb = get_tile_aabb(tile_id),
					vel  = {0, 0},
				}
				t, side, normal, _, will_be_colliding := get_time_to_collide(
					obj_box.moving_shape,
					tile_aabb,
				)
				if will_be_colliding {
					if t < offset_threshold {
						offsets_needed[side] = true
					}
					if t < t_min {
						will_collide = true
						t_min = t
						clear(&tiles_min)
						side_min = side
						normal_min = normal
						tile_min = tile_id
					}
					if t <= t_min {
						append(&tiles_min, tile_id)
					}
				}
			}
		}
		obj.position += t_min * delta_frac_remaining * pos_delta //hit wall
		obj.rotation += t_min * delta_frac_remaining * rot_delta
		if will_collide {
			#unroll for j in 0 ..< 4 {
				s := SideName(j)
				if offsets_needed[s] {
					//push back from wall a bit
					epsilon :: 0.001
					obj.position += WALL_NORMALS[s] * epsilon
				}
			}
			wall_normal := normal_min
			//glide against wall - cancel component of velocity perpendicular to wall
			obj.velocity -= linalg.dot(obj.velocity, wall_normal) * wall_normal
			pos_delta -= linalg.dot(pos_delta, wall_normal) * wall_normal
			t_remaining -= t_min * t_remaining //we now try to keep moving for the rest of the time in this new direction
			for tile_id in tiles_min {
				collision := Collision {
					a = obj_handle,
					b = tile_id,
					info = ContinuousCollision {
						time_to_collide = t_min * t_remaining,
						normal = wall_normal,
					},
					type = .stay,
				}
				append(&collisions, collision)
			}
		} else {
			t_remaining = 0 //we have fully moved in this direction for the rest of the time step
			reset_instantaneous_state(obj)
		}
		// update transform matrix for obj because it will be used next iteration
		game.final_transforms[obj_handle.idx].transform =
			apply(obj.transform) * unpivot(obj.transform)
	}
	return collisions[:]
}
