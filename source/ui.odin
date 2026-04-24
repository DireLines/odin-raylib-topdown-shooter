package game

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

//a bar displaying the current value of a stat
UIStatBar :: struct {
	min_value, current_value, max_value: f64,
	disp_length, disp_height:            f64,
	filled_color, unfilled_color:        rl.Color,
	num_ticks:                           int,

	// the display behavior for the partially filled tick at the end
	incomplete_tick_display_mode:        enum {
		Exact, //fill exact fraction of the tick
		Round, //round to closest tick
		Ceil, //round to nearest tick above
		Floor, // round to nearest tick below
	},

	//if true, lerp the color of incomplete tick between filled_color and unfilled_color
	//if false, it will be filled_color
	interp_tick_color:                   bool,
}
default_ui_stat_bar :: proc() -> UIStatBar {
	return UIStatBar {
		disp_length = 100,
		disp_height = 20,
		filled_color = rl.GREEN,
		unfilled_color = rl.GRAY,
		num_ticks = 10,
		incomplete_tick_display_mode = .Exact,
		interp_tick_color = false,
	}
}

UIButton :: struct {
	min_scale, max_scale: vec2,
	on_click_start:       proc(info: ButtonCallbackInfo) `cbor:"-"`, //triggered when mouse button down and hovering button
	on_click:             proc(info: ButtonCallbackInfo) `cbor:"-"`, //triggered when mouse button up and hovering button - most of the time this is what you want
}
UISlider :: struct {
	min_value, current_value, max_value, default_value: f64,
	left_pos, right_pos:                                f64, //screen coords, for display
	snap_increment:                                     f64, //0 = no snapping
	show_percentage:                                    bool,
	on_set_value:                                       proc(info: SliderCallbackInfo) `cbor:"-"`,
	handle_handle:                                      GameObjectHandle,
}
SliderCallbackInfo :: struct {
	game:          ^Game,
	slider:        GameObjectInst(UISlider),
	slider_handle: GameObjectHandle,
	new_value:     f64,
}

ButtonCallbackInfo :: struct {
	game:          ^Game,
	button:        GameObjectInst(UIButton),
	button_handle: GameObjectHandle,
}
get_slider_handle_text :: proc(frac, val: f64, show_percentage: bool = false) -> string {
	return(
		show_percentage ? fmt.aprintf("%d", int(math.round(frac * 100))) : fmt.aprintf("%.2f", val) \
	)
}

draw_ui_stat_bar :: proc(bar: ^GameObject) {
	stat_bar := get_object(bar, UIStatBar)
	//for each tick, draw a rectangle
	frac_bar_filled :=
		(stat_bar.current_value - stat_bar.min_value) / (stat_bar.max_value - stat_bar.min_value)
	num_ticks_filled := int(math.floor(frac_bar_filled * f64(stat_bar.num_ticks)))
	tick_width := stat_bar.disp_length / f64(stat_bar.num_ticks)
	tick_height := stat_bar.disp_height
	transform := game.final_transforms[bar.handle.idx]
	top_left := mat_vec_mul(transform.transform, {0, 0})
	bottom_right := mat_vec_mul(transform.transform, {1, 1})
	if !transform.screen_space {
		top_left = world_to_screen(top_left, screen_conversion)
		bottom_right = world_to_screen(bottom_right, screen_conversion)
	}
	filled_color, unfilled_color := stat_bar.filled_color, stat_bar.unfilled_color
	for i in 0 ..< stat_bar.num_ticks {
		pos := vec2{top_left.x + f64(i) * tick_width, top_left.y}
		color := filled_color
		if i >= num_ticks_filled {
			color = unfilled_color
		}
		tick_disp_width := tick_width
		if i == num_ticks_filled {
			//handle partially filled tick
			single_tick_value :=
				(stat_bar.max_value - stat_bar.min_value) / f64(stat_bar.num_ticks)
			filled_ticks_total := f64(num_ticks_filled) * single_tick_value
			frac_incomplete_tick_filled :=
				(stat_bar.current_value - filled_ticks_total) / single_tick_value
			switch stat_bar.incomplete_tick_display_mode {
			case .Exact:
				tick_disp_width = tick_width * frac_incomplete_tick_filled
				color = filled_color
				//also display the unfilled remainder of the tick
				rl.DrawRectangle(
					i32(pos.x + tick_disp_width),
					i32(pos.y),
					i32(tick_width - tick_disp_width) + 1,
					i32(tick_height * (bottom_right - top_left).y),
					unfilled_color,
				)

			case .Round:
				color = frac_incomplete_tick_filled < 0.5 ? unfilled_color : filled_color
			case .Ceil:
				color = filled_color
			case .Floor:
				color = unfilled_color
			}
			if stat_bar.interp_tick_color {
				color = lerp_colors(unfilled_color, filled_color, frac_incomplete_tick_filled)
			}
		}
		rl.DrawRectangle(
			i32(pos.x),
			i32(pos.y),
			i32(tick_disp_width),
			i32(tick_height * (bottom_right - top_left).y),
			color,
		)
		//black lines between ticks to cover seams
		rl.DrawRectangle(
			i32(pos.x) - 1,
			i32(pos.y),
			3,
			i32(tick_height * (bottom_right - top_left).y),
			rl.BLACK,
		)
		if i == stat_bar.num_ticks - 1 {
			rl.DrawRectangle(
				i32(pos.x + tick_disp_width) - 1,
				i32(pos.y),
				3,
				i32(tick_height * (bottom_right - top_left).y),
				rl.BLACK,
			)
		}
	}
	lerp_colors :: proc(a, b: rl.Color, t: f64) -> rl.Color {
		result: rl.Color
		#unroll for i in 0 ..< 4 {
			result[i] = u8(math.lerp(f64(a[i]), f64(b[i]), t))
		}
		return result
	}
}
