package game

import "core:fmt"
import "core:reflect"
import hm "handle_map_static"
import rl "vendor:raylib"

SpawnOptions :: struct {
	name:                            string,
	tex:                             TextureName,
	render_layer:                    RenderLayer,
	using texture_import:            TextureImportMode,
	hitbox_units:                    HitboxUnits,
	text:                            string,
	pos:                             vec2,
	rot:                             f64,
	scale:                           vec2,
	color:                           rl.Color,
	coll_shape:                      CollisionShape,
	tags:                            bit_set[ObjectTag],
	parent_handle:                   Maybe(GameObjectHandle),
	supplying_local_coordinates:     bool,
	fit_screen_size_to_tex_dims:     bool,
	fit_scale_to_tex_dims:           bool,
	manual_size, manual_hitbox_size: bool,
}
HitboxUnits :: enum {
	WorldUnits,
	TexturePixels,
	ScreenPixels,
}

//return the spawned object
//if you want the handle, you can just use the handle field of the result
//which is required to be part of the struct by handle map
spawn_object_from_def_untyped :: proc(object: GameObject) -> ^GameObject {
	render_layer := object.render_layer
	if render_layer >= NUM_RENDER_LAYERS {
		print("bad render layer, putting in default layer")
		render_layer = 0
	}
	h := hm.add(&game.objects, object)
	obj := hm.get(&game.objects, h) //TODO: should return the ^obj from hm.add?
	obj._variant_type = reflect.union_variant_typeid(obj.variant)
	append(&game.render_layers[render_layer], h)
	return obj
}

spawn_object_from_def_typed :: proc(object: GameObject, $T: typeid) -> GameObjectInst(T) {
	obj := spawn_object_from_def_untyped(object)
	return object_inst(obj, T)
}
apply_spawn_opts :: proc(obj: ^GameObject, spawn_opts: Maybe(SpawnOptions) = nil) {
	spawn_opts, spawn_opts_provided := spawn_opts.?
	if spawn_opts_provided {
		obj.spawn_opts = spawn_opts
	}
	si := obj.spawn_opts
	obj.name = si.name
	obj.position = si.pos
	obj.rotation = si.rot
	obj.texture = atlas_textures[si.tex]
	obj.import_mode = si.texture_import
	obj.render_layer = uint(RenderLayer.Floor)
	if si.render_layer != {} {
		obj.render_layer = uint(si.render_layer)
	}
	set_render_layer(obj.handle, obj.render_layer)
	obj.color = si.color
	if obj.color == {} {
		obj.color = rl.WHITE
	}
	obj.tags += si.tags
	if si.scale == {} {
		obj.scale = {1, 1}
	} else {
		obj.scale = si.scale
	}
	tex_dims := vec2{1, 1} * TEXTURE_PIXELS_PER_WORLD_UNIT
	if si.keep_original_dimensions {
		tex_dims = vec2{obj.texture.rect.width, obj.texture.rect.height}
	}
	obj.pivot = tex_dims / 2
	obj.hitbox.shape = AABB{-tex_dims / 2, tex_dims / 2}
	#partial switch s in si.coll_shape {
	case Circle:
		obj.hitbox.shape = Circle{{0, 0}, tex_dims.x / 2}
	}
}
spawn_object_from_def_with_spawn_opts :: proc(
	object: GameObject,
	spawn_opts: SpawnOptions,
) -> ^GameObject {
	obj := spawn_object_from_def_untyped(object)
	apply_spawn_opts(obj, spawn_opts)
	return obj
}

spawn_object_from_def_with_spawn_opts_typed :: proc(
	object: GameObject,
	spawn_opts: SpawnOptions,
	$T: typeid,
) -> GameObjectInst(T) {
	obj := spawn_object_from_def_with_spawn_opts(object)
	return object_inst(obj, T)
}

spawn_object_from_def :: proc {
	spawn_object_from_def_typed,
	spawn_object_from_def_untyped,
	spawn_object_from_def_with_spawn_opts,
	spawn_object_from_def_with_spawn_opts_typed,
}


spawn_object :: proc(spawn_opts: SpawnOptions) -> ^GameObject {
	obj := spawn_object_from_def({})
	apply_spawn_opts(obj, spawn_opts)
	return obj
}

spawn_dynamic_object :: proc(spawn_opts: SpawnOptions) -> ^GameObject {
	opts := spawn_opts
	opts.tags += {.Sprite, .Collide}
	return spawn_object(opts)
}
spawn_decorative_object :: proc(spawn_opts: SpawnOptions) -> ^GameObject {
	opts := spawn_opts
	opts.tags += {.Sprite}
	opts.tags -= {.Collide}
	return spawn_object(opts)
}

//some convenience spawning procs for common loose categories of objects
// - static walls
// - static area of affect (trigger zone)
// - decorative object (just a sprite or animated sprite with no collision)
// - dynamic object with hitbox matching size of texture
// - UI components

spawn_ui_button :: proc(
	pos: vec2,
	texture: TextureName, //TODO probably need to eventually supply hover / click animations
	text: string,
	on_click: proc(info: ButtonCallbackInfo),
) -> GameObjectInst(UIButton) {
	tex := atlas_textures[texture]
	min_scale :: vec2{3, 0.9}
	button_obj := GameObject {
		name = fmt.aprint(text, "button"),
		transform = {
			position = pos,
			rotation = 0,
			scale = min_scale,
			pivot = vec2{tex.rect.width, tex.rect.height} / 2,
		},
		render_info = {
			texture = tex,
			color = rl.WHITE,
			render_layer = uint(RenderLayer.UI),
			text_render_info = {text = text, font_size = UI_MAIN_FONT_SIZE},
		},
		tags = {.Sprite, .Text, .DoNotSerialize, .DontDestroyOnLoad},
		variant = UIButton {
			min_scale = min_scale,
			max_scale = {min_scale.x * 1.3, min_scale.y},
			on_click = on_click,
		},
		parent_handle = game.screen_space_parent_handle,
	}
	return spawn_object_from_def(button_obj, UIButton)
}


spawn_ui_slider :: proc(
	pos: vec2,
	handle_texture: TextureName,
	text: string,
	slider_info: UISlider,
) -> (
	GameObjectHandle,
	GameObjectHandle,
	GameObjectHandle,
) {

	handle_tex := atlas_textures[handle_texture]
	handle_scale := vec2{0.7, 0.4}
	default_frac :=
		(slider_info.default_value - slider_info.min_value) /
		(slider_info.max_value - slider_info.min_value)
	handle_x :=
		slider_info.left_pos + default_frac * (slider_info.right_pos - slider_info.left_pos)
	handle_def := GameObject {
		name = fmt.aprint(text, "slider handle"),
		transform = {
			position = {handle_x, pos.y},
			rotation = 0,
			scale = handle_scale,
			pivot = vec2{handle_tex.rect.width, handle_tex.rect.height} / 2,
		},
		render_info = {
			texture = handle_tex,
			color = rl.WHITE,
			render_layer = uint(RenderLayer.UI),
			text_render_info = {
				text = get_slider_handle_text(
					default_frac,
					slider_info.default_value,
					slider_info.show_percentage,
				),
				font_size = UI_SECONDARY_FONT_SIZE,
				text_color = rl.BLACK,
			},
		},
		tags = {.Sprite, .Text, .DoNotSerialize, .DontDestroyOnLoad},
		variant = UIButton {
			min_scale = handle_scale,
			max_scale = {handle_scale.x, handle_scale.y},
			on_click_start = proc(info: ButtonCallbackInfo) {
				slider_handle := info.button.associated_objects["slider"].(GameObjectHandle)
				slider := get_object(slider_handle, UISlider)
				game.clicked_ui_object = slider_handle
			},
		},
		parent_handle = game.screen_space_parent_handle,
	}
	slider_info := slider_info
	handle_object := spawn_object_from_def(handle_def)
	slider_info.handle_handle = handle_object.handle
	track_tex := atlas_textures[.White]
	track_width := slider_info.right_pos - slider_info.left_pos
	track_scale := vec2{track_width / f64(track_tex.rect.width), 10.0 / f64(track_tex.rect.height)}
	slider_def := GameObject {
		name = fmt.aprint(text, "slider"),
		transform = {
			position = pos,
			rotation = 0,
			scale = track_scale,
			pivot = vec2{f64(track_tex.rect.width), f64(track_tex.rect.height)} / 2,
		},
		render_info = {
			texture = track_tex,
			color = {255, 255, 255, 100},
			render_layer = uint(RenderLayer.UI) - 1,
		},
		tags = {.Sprite, .DoNotSerialize, .DontDestroyOnLoad},
		parent_handle = game.screen_space_parent_handle,
		variant = slider_info,
	}
	slider := spawn_object_from_def(slider_def)
	handle_object.associated_objects["slider"] = slider.handle
	LABEL_PIXEL_PADDING :: 50
	label_def := GameObject {
		name = fmt.aprint(text, "slider label"),
		transform = {
			position = {slider_info.left_pos - LABEL_PIXEL_PADDING, pos.y},
			scale = {1, 1},
			pivot = {0, 0},
		},
		render_info = {
			color = rl.WHITE,
			render_layer = uint(RenderLayer.UI),
			text_render_info = {
				text = text,
				text_color = UI_MAIN_COLOR,
				text_alignment = .Right,
				font_size = UI_MAIN_FONT_SIZE,
			},
		},
		tags = {.Text, .DoNotSerialize, .DontDestroyOnLoad},
		parent_handle = game.screen_space_parent_handle,
	}
	label := spawn_object_from_def(label_def)
	return slider.handle, handle_object.handle, label.handle
}


spawn_ui_stat_bar :: proc(
	name: string,
	pos: vec2,
	parent: Maybe(GameObjectHandle),
	stat_bar_info: UIStatBar,
) -> GameObjectInst(UIStatBar) {
	return spawn_object_from_def(
		GameObject {
			name = fmt.aprint(name, "bar"),
			transform = {position = pos, scale = {1, 1}},
			render_info = {
				color = rl.WHITE,
				render_layer = uint(RenderLayer.UI),
				draw = draw_ui_stat_bar,
			},
			tags = {.CustomDraw},
			variant = stat_bar_info,
			parent_handle = parent,
		},
		UIStatBar,
	)
}
