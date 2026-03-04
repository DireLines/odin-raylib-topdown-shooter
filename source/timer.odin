package game
import "base:runtime"
import "core:fmt"
import "core:time"


Timer :: struct {
	loc:          runtime.Source_Code_Location,
	start:        time.Tick,
	totals:       map[string]time.Duration,
	time:         proc(state: ^Timer, msg: string),
	count_toward: proc(state: ^Timer, msg: string),
	dump_totals:  proc(state: ^Timer),
	reset:        proc(state: ^Timer),
}
timer :: proc(loc := #caller_location) -> Timer {
	timing_logs :: #config(timing_logs, false)
	timer_time :: proc(state: ^Timer, msg: string) {
		when timing_logs {
			prefix := state.loc.procedure
			if msg in state.totals {
				fmt.printfln(
					"%v: %v took %.5f millis",
					prefix,
					msg,
					time.duration_milliseconds(state.totals[msg]),
				)
				delete_key(&state.totals, msg)
				return
			}
			elapsed := time.tick_since(state.start)
			fmt.printfln(
				"%v: %v took %.5f millis",
				prefix,
				msg,
				time.duration_milliseconds(elapsed),
			)
			state.start = time.tick_now()
		}
	}
	return Timer {
		loc = loc,
		start = time.tick_now(),
		time = timer_time,
		count_toward = proc(state: ^Timer, msg: string) {
			when timing_logs {
				elapsed := time.tick_since(state.start)
				state.totals[msg] += elapsed
				state.start = time.tick_now()
			}
		},
		dump_totals = proc(state: ^Timer) {
			when timing_logs {
				for k in state.totals {
					state->time(k)
				}
			}
		},
		reset = proc(state: ^Timer) {
			state.start = time.tick_now()
		},
	}
}
