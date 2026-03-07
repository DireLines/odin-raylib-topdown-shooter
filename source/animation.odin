package game
import hm "handle_map_static"

//animation system

Animation :: struct {
	name:            AnimationName,
	using anim:      AtlasAnimation,
	ticks_per_frame: uint, //TODO: optionally, base on time not frames
	loop:            bool, //should I keep playing after reaching end of playback?
}
PlaybackDirection :: enum {
	backward = -1,
	forward  = 1,
}
AnimationState :: struct {
	anim:               Animation,
	frame:              TextureName, //what frame should be displayed?
	ticks_until_change: uint, //how many ticks of the game should elapse before switching to the next frame?
	direction:          PlaybackDirection, //are we currently playing forward or backward?
	paused:             bool,
}

//swapping out sprites
increment_animations :: proc(dt: f64) {
	obj_iter := hm.make_iter(&game.objects)
	for obj, _ in hm.iter(&obj_iter) {
		increment_animation(&obj.render_info, &obj.animation)
	}
}

increment_animation :: proc(render_info: ^RenderInfo, anim_state: ^AnimationState) {
	if anim_state.paused {
		return
	}
	anim_state.ticks_until_change -= 1
	if anim_state.ticks_until_change > 0 {
		//normal frame - continue as is
		return
	}
	//need to increment animation frame
	anim := anim_state.anim
	new_frame: TextureName
	switch anim.loop_direction {
	case .Forward:
		new_frame = anim_state.frame + TextureName(1)
		if new_frame > anim.last_frame {
			if !anim.loop {
				anim_state.paused = true
			}
			new_frame = anim.first_frame
		}
	case .Ping_Pong, .Ping_Pong_Reverse:
		at_start := anim_state.frame == anim.first_frame && anim_state.direction == .backward
		at_end := (anim_state.frame == anim.last_frame && anim_state.direction == .forward)
		if at_start || at_end {
			anim_state.direction = -anim_state.direction
		}
		new_frame = anim_state.frame + TextureName(anim_state.direction)
	case .Reverse:
		new_frame = anim_state.frame - TextureName(1)
		if new_frame < anim.first_frame {
			if !anim.loop {
				anim_state.paused = true
			}
			new_frame = anim.last_frame
		}
	}
	anim_state.frame = new_frame
	anim_state.ticks_until_change = anim.ticks_per_frame
	render_info.texture = atlas_textures[new_frame]
	return
}

//TODO: tweening (maybe use easing functions from odin raylib?)
//TODO for better looking animations, separate display transform from actual transform and apply tween stuff to display transform only

initial_animation_state :: proc(anim: Animation, paused: bool = false) -> AnimationState {
	init_frame: TextureName
	init_direction: PlaybackDirection
	switch anim.loop_direction {
	case .Forward, .Ping_Pong:
		init_frame = anim.first_frame
		init_direction = .forward
	case .Ping_Pong_Reverse, .Reverse:
		init_frame = anim.last_frame
		init_direction = .backward
	}
	return {
		anim = anim,
		frame = init_frame,
		direction = init_direction,
		ticks_until_change = anim.ticks_per_frame,
		paused = paused,
	}
}

make_animation :: proc(
	anim_name: AnimationName,
	ticks_per_frame: uint = 1,
	loop: bool = true,
) -> Animation {
	return {anim_name, atlas_animations[anim_name], ticks_per_frame, loop}
}

make_animation_state :: proc(
	anim_name: AnimationName,
	ticks_per_frame: uint = 1,
	paused: bool = false,
) -> AnimationState {
	return initial_animation_state(make_animation(anim_name, ticks_per_frame), paused)
}

pause_animation :: proc(anim: ^AnimationState) {
	anim.paused = true
}
resume_animation :: proc(anim: ^AnimationState) {
	anim.paused = false
}
toggle_pause :: proc(anim: ^AnimationState) {
	anim.paused = !anim.paused
}
