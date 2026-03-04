#+build !wasm32
#+build !wasm64p32

package game

import fmt "core:fmt"
import testing "core:testing"
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
			_, side, _, will_be_colliding := get_time_to_collide(test.a, test.b)
			testing.expect(t, will_be_colliding == test.expected_collide, "result doesn't match")
			testing.expect(t, side == test.expected_side, "side doesn't matches")
		}
	}
}
