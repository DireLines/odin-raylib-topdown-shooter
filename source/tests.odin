#+build !wasm32
#+build !wasm64p32

package game

import fmt "core:fmt"
import "core:reflect"
import testing "core:testing"
import hm "handle_map_static"
num_in_range :: proc(n, target: f64, epsilon: f64 = 0.001) -> bool {
	return abs(target - n) < epsilon
}

@(test)
test_collision_procs :: proc(t: ^testing.T) {
	{
		tests := []struct {
			name:          string,
			ray:           Ray,
			side:          AABBSide,
			expected:      bool,
			expected_time: f64,
		} {
			{
				name = "basic",
				ray = {pos = {-100, 0}, vel = {200, 0}},
				side = {start = {-50, -50}, direction = .vertical, length = 100},
				expected = true,
				expected_time = 0.25,
			},
			{
				name = "transpose x/y",
				ray = {pos = {0, -100}, vel = {0, 200}},
				side = {start = {-50, -50}, direction = .horizontal, length = 100},
				expected = true,
				expected_time = 0.25,
			},
			{
				name = "only direction of ray matters, not length",
				ray = {pos = {-300, 0}, vel = {200, 0}},
				side = {start = {-50, -50}, direction = .vertical, length = 100},
				expected = true,
				expected_time = 1.25,
			},
			{
				name = "negative length",
				ray = {pos = {-100, 0}, vel = {200, 0}},
				side = {start = {-50, -50}, direction = .vertical, length = -100},
				expected = false,
			},
			{
				name = "side not long enough to hit ray",
				ray = {pos = {-100, 0}, vel = {200, 0}},
				side = {start = {-50, -50}, direction = .vertical, length = 10},
				expected = false,
			},
			{
				name = "ray starts past side (x)",
				ray = {pos = {100, 0}, vel = {200, 0}},
				side = {start = {-50, -50}, direction = .vertical, length = 100},
				expected = false,
			},
			{
				name = "side is facing other direction",
				ray = {pos = {100, 0}, vel = {200, 0}},
				side = {start = {-50, -50}, direction = .horizontal, length = 100},
				expected = false,
			},
			{
				name = "works ok with any angle of ray?",
				ray = {pos = {-100, 0}, vel = {200, 50}},
				side = {start = {-50, -50}, direction = .vertical, length = 100},
				expected = true,
				expected_time = 0.25,
			},
			{
				name = "if ray has too much y vel, does it miss correctly?",
				ray = {pos = {-100, 0}, vel = {200, 1000}},
				side = {start = {-50, -50}, direction = .vertical, length = 100},
				expected = false,
			},
		}
		for test in tests {
			time, will_collide := get_time_to_collide(test.ray, test.side)
			testing.expect(
				t,
				test.expected == will_collide,
				fmt.tprintf("%v: result doesn't match", test.name),
			)
			if test.expected {
				testing.expect(
					t,
					num_in_range(time, test.expected_time),
					fmt.tprintf(
						"%v: time doesn't match: %v != %v",
						test.name,
						test.expected_time,
						time,
					),
				)
			}
		}
	}
	{
		tests := []struct {
			ray:              Ray,
			aabb:             AABB,
			expected_collide: bool,
			expected_side:    SideName,
		} {
			{
				ray = {pos = {-100, 0}, vel = {200, 0}},
				aabb = {min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .left,
			},
			{
				ray = {pos = {100, 0}, vel = {-200, 0}},
				aabb = {min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .right,
			},
			{
				ray = {pos = {0, -100}, vel = {0, 200}},
				aabb = {min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .top,
			},
			{
				ray = {pos = {0, 100}, vel = {0, -200}},
				aabb = {min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .bottom,
			},
			{ 	//cross one horiz and one vert side
				ray = {pos = {0, 75}, vel = {-200, -200}},
				aabb = {min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .bottom,
			},
		}
		for test in tests {
			_, side, _, will_be_colliding := get_time_to_collide(test.ray, test.aabb)
			testing.expect(t, will_be_colliding == test.expected_collide, "result doesn't match")
			testing.expect(t, side == test.expected_side, "side doesn't matches")
		}
	}
	{
		tests := []struct {
			a, b:             MovingAABB,
			expected_collide: bool,
			expected_side:    SideName,
		} {
			{
				a = {vel = {120, 0}, min = {-150, 0}, max = {-125, 25}},
				b = {vel = {0, 0}, min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .left,
			},
			{
				a = {vel = {-120, 0}, min = {150, 0}, max = {125, 25}},
				b = {vel = {0, 0}, min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .right,
			},
			{
				a = {vel = {0, -120}, min = {0, 150}, max = {25, 125}},
				b = {vel = {0, 0}, min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .bottom,
			},
			{
				a = {vel = {0, 120}, min = {0, -150}, max = {-25, -125}},
				b = {vel = {0, 0}, min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .top,
			},
			{
				a = {vel = {150, 0}, min = {-125, -75}, max = {-100, -30}},
				b = {vel = {0, 0}, min = {-50, -50}, max = {50, 50}},
				expected_collide = true,
				expected_side = .left,
			},
			{
				a = {vel = {150, 0}, min = {-125, -75}, max = {-100, -70}},
				b = {vel = {0, 0}, min = {-50, -50}, max = {50, 50}},
				expected_collide = false,
			},
		}
		for test in tests {
			_, side, _, _, will_be_colliding := get_time_to_collide(test.a, test.b)
			testing.expect(t, will_be_colliding == test.expected_collide, "result doesn't match")
			testing.expect(t, side == test.expected_side, "side doesn't matches")
		}
	}
}


@(test)
test_save_load :: proc(t: ^testing.T) {
	// Each sub-test allocates two Games on the heap: a source (g1) that is populated
	// with known state, and a destination (g2) that receives the round-tripped data.
	// game_from_cbor internally allocates a third Game for the intermediate unmarshal
	// target; that one is currently not freed (noted in files.odin).

	round_trip :: proc(t: ^testing.T, g1: ^Game, label: string) -> (g2: ^Game, ok: bool) {
		data, merr := game_to_cbor(g1)
		if !testing.expect(t, merr == nil, fmt.tprintf("%v: marshal failed: %v", label, merr)) {
			return nil, false
		}
		g2 = new(Game)
		if !testing.expect(
			t,
			game_from_cbor(g2, data),
			fmt.tprintf("%v: unmarshal failed", label),
		) {
			free(raw_data(data))
			return g2, false
		}
		free(raw_data(data))
		return g2, true
	}

	// Scalar game-state fields
	{
		g1 := new(Game); defer free(g1)
		g1.frame_counter = 1234
		g1.paused = true
		g1.main_camera = {
			position = {10, 20},
			rotation = 45,
			scale    = {2, 2},
		}
		g1.player_spawn_point = {300, 400}
		g1.menu_state = .MainMenu
		g1.chunk_loading_mode = .Proximity
		g1.screen_space_parent_handle = {
			idx = 7,
			gen = 3,
		}

		g2, ok := round_trip(t, g1, "scalars"); defer free(g2)
		if !ok do return

		testing.expect(t, g2.frame_counter == 1234, "scalars: frame_counter")
		testing.expect(t, g2.paused == true, "scalars: paused")
		testing.expect(t, g2.main_camera == g1.main_camera, "scalars: main_camera")
		testing.expect(t, g2.player_spawn_point == {300, 400}, "scalars: player_spawn_point")
		testing.expect(t, g2.menu_state == .MainMenu, "scalars: menu_state")
		testing.expect(t, g2.chunk_loading_mode == .Proximity, "scalars: chunk_loading_mode")
		testing.expect(
			t,
			g2.screen_space_parent_handle == {idx = 7, gen = 3},
			"scalars: screen_space_parent_handle",
		)
	}

	// Player variant, AABB hitbox, bit_set tags, parent handle
	{
		g1 := new(Game); defer free(g1)
		child_obj := GameObject {
			name = "player",
			transform = {position = {50, 75}, rotation = 90, scale = {1, 1}},
			hitbox = {
				shape = AABB{min = {-8, -8}, max = {8, 8}},
				collision = {layer = .Player, resolve = true, trigger_events = true},
			},
			tags = {.Player, .Collide, .Sprite},
			variant = Player{health_info = {health = 80, max_health = 100}, score = 999},
		}
		h, add_ok := hm.add(&g1.objects, child_obj)
		testing.expect(t, add_ok, "player: hm.add failed")

		g2, ok := round_trip(t, g1, "player"); defer free(g2)
		if !ok do return

		obj, get_ok := hm.get(&g2.objects, h)
		testing.expect(t, get_ok, "player: handle valid")
		testing.expect(t, obj.name == "player", "player: name")
		testing.expect(t, obj.transform.position == {50, 75}, "player: position")
		testing.expect(t, obj.transform.rotation == 90, "player: rotation")
		testing.expect(t, obj.tags == {.Player, .Collide, .Sprite}, "player: tags")
		testing.expect(t, obj.hitbox.layer == .Player, "player: hitbox layer")
		testing.expect(t, obj.hitbox.resolve, "player: hitbox resolve")
		aabb, is_aabb := obj.hitbox.shape.(AABB)
		testing.expect(t, is_aabb, "player: hitbox is AABB")
		testing.expect(t, aabb.min == {-8, -8}, "player: aabb min")
		testing.expect(t, aabb.max == {8, 8}, "player: aabb max")
		p, is_player := obj.variant.(Player)
		testing.expect(t, is_player, "player: is Player variant")
		testing.expect(t, p.health == 80, "player: health")
		testing.expect(t, p.max_health == 100, "player: max_health")
		testing.expect(t, p.score == 999, "player: score")
	}

	// Enemy variant, Circle hitbox
	{
		g1 := new(Game); defer free(g1)
		h, _ := hm.add(
			&g1.objects,
			GameObject {
				name = "enemy",
				hitbox = {shape = Circle{pos = {2, 3}, radius = 12}},
				variant = Enemy {
					health_info = {health = 30, max_health = 60},
					spawn_point = {100, 200},
					state = .Alive_Active,
					type = .Basic,
				},
			},
		)

		g2, ok := round_trip(t, g1, "enemy"); defer free(g2)
		if !ok do return

		obj, get_ok := hm.get(&g2.objects, h)
		testing.expect(t, get_ok, "enemy: handle valid")
		circle, is_circle := obj.hitbox.shape.(Circle)
		testing.expect(t, is_circle, "enemy: hitbox is Circle")
		testing.expect(t, circle.radius == 12, "enemy: radius")
		testing.expect(t, circle.pos == {2, 3}, "enemy: circle pos")
		e, is_enemy := obj.variant.(Enemy)
		testing.expect(t, is_enemy, "enemy: is Enemy variant")
		testing.expect(t, e.health == 30, "enemy: health")
		testing.expect(t, e.spawn_point == {100, 200}, "enemy: spawn_point")
		testing.expect(t, e.state == .Alive_Active, "enemy: state")
		testing.expect(t, e.type == .Basic, "enemy: type")
	}

	// Multiple objects: gaps in handle map are preserved
	{
		g1 := new(Game); defer free(g1)
		h1, _ := hm.add(&g1.objects, GameObject{variant = DefaultVariant{}})
		h2, _ := hm.add(&g1.objects, GameObject{variant = Bullet{state = .Alive}})
		hm.remove(&g1.objects, h1) // creates a gap; h1 should be invalid after round-trip
		h3, _ := hm.add(
			&g1.objects,
			GameObject{variant = UIStatBar{min_value = 0, max_value = 10, current_value = 7}},
		)

		g2, ok := round_trip(t, g1, "gaps"); defer free(g2)
		if !ok do return

		_, h1_ok := hm.get(&g2.objects, h1)
		testing.expect(t, !h1_ok, "gaps: h1 should be invalid (was removed)")

		b_obj, h2_ok := hm.get(&g2.objects, h2)
		testing.expect(t, h2_ok, "gaps: h2 valid")
		bullet, is_bullet := b_obj.variant.(Bullet)
		testing.expect(t, is_bullet, "gaps: h2 is Bullet")
		testing.expect(t, bullet.state == .Alive, "gaps: bullet state")

		c_obj, h3_ok := hm.get(&g2.objects, h3)
		testing.expect(t, h3_ok, "gaps: h3 valid")
		bar, is_bar := c_obj.variant.(UIStatBar)
		testing.expect(t, is_bar, "gaps: h3 is UIStatBar")
		testing.expect(t, bar.current_value == 7, "gaps: bar current_value")
		testing.expect(t, bar.max_value == 10, "gaps: bar max_value")
	}

	// Tilemap chunks and loaded/room chunk sets
	{
		g1 := new(Game); defer free(g1)
		g1.tilemap_chunks = make(map[ChunkId]TilemapChunk)
		g1.loaded_chunks = make(map[ChunkId]struct{})
		g1.room_chunks = make(map[ChunkId]struct{})

		chunk: TilemapChunk
		chunk[3][1] = Tile {
			type     = .Wall,
			rotation = .East,
			spawn    = .Enemy,
		}
		chunk[0][0] = Tile {
			type  = .None,
			spawn = .Player,
		}
		g1.tilemap_chunks[{2, -1}] = chunk
		g1.loaded_chunks[{2, -1}] = {}
		g1.room_chunks[{2, -1}] = {}
		g1.room_chunks[{0, 0}] = {}

		g2, ok := round_trip(t, g1, "tilemap"); defer free(g2)
		if !ok do return

		c, has_chunk := g2.tilemap_chunks[{2, -1}]
		testing.expect(t, has_chunk, "tilemap: chunk present")
		testing.expect(t, c[3][1].type == .Wall, "tilemap: tile type")
		testing.expect(t, c[3][1].rotation == .East, "tilemap: tile rotation")
		testing.expect(t, c[3][1].spawn == .Enemy, "tilemap: tile spawn")
		testing.expect(t, c[0][0].spawn == .Player, "tilemap: second tile spawn")
		_, in_loaded := g2.loaded_chunks[{2, -1}]
		testing.expect(t, in_loaded, "tilemap: in loaded_chunks")
		_, in_room_a := g2.room_chunks[{2, -1}]
		testing.expect(t, in_room_a, "tilemap: {2,-1} in room_chunks")
		_, in_room_b := g2.room_chunks[{0, 0}]
		testing.expect(t, in_room_b, "tilemap: {0,0} in room_chunks")
	}
}
