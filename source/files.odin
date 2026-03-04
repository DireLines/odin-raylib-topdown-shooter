package game
import "core:slice"
import "core:strings"
import rl "vendor:raylib"
//loading/saving assets

SOUNDS_DIR := #load_directory("sounds")
get_sound :: proc(name: string, file_extension: string = ".wav") -> rl.Sound {
	if name in game.sounds {
		return game.sounds[name]
	}
	return load_sound(name, file_extension)
}
@(private = "file") //don't go through these uncached helpers, use the cache
load_sound :: proc(name: string, file_extension: string = ".wav") -> rl.Sound {
	for sound_file in SOUNDS_DIR {
		if sound_file.name == name {
			wave := rl.LoadWaveFromMemory(
				".wav",
				raw_data(sound_file.data),
				i32(len(sound_file.data)),
			)
			sound := rl.LoadSoundFromWave(wave)
			game.sounds[name] = sound
			return sound
		}
	}
	print("tried to load unrecognized sound", name)
	return {}
}
unload_sound :: proc(name: string) {
	sound, ok := game.sounds[name]
	if ok {
		rl.UnloadSound(sound)
		delete_key(&game.sounds, name)
	}
}
get_texture :: proc(filename: string) -> rl.Texture2D {
	texture, ok := game.textures[filename]
	if ok {
		return texture
	}
	return load_texture(filename)
}
@(private = "file") //don't go through these uncached helpers, use the cache
load_texture :: proc(filename: string) -> rl.Texture2D {
	texture := rl.LoadTexture(strings.clone_to_cstring(filename))
	rl.SetTextureFilter(texture, .BILINEAR)
	game.textures[filename] = texture
	return texture
}
unload_texture :: proc(filename: string) {
	texture, ok := game.textures[filename]
	if ok {
		rl.UnloadTexture(texture)
		delete_key(&game.textures, filename)
	}
}

get_font :: proc(font_name: FontName) -> rl.Font {
	font, ok := game.fonts[font_name]
	if ok {
		return font
	}
	return load_font(font_name)
}
@(private = "file") //don't go through these uncached helpers, use the cache
load_font :: proc(font_name: FontName) -> rl.Font {
	font := load_atlased_font(font_name)
	game.fonts[font_name] = font
	return font
}
unload_font :: proc(font_name: FontName) {
	font, ok := game.fonts[font_name]
	if ok {
		delete_atlased_font(font)
		delete_key(&game.fonts, font_name)
	}
}


// This uses the letters in the atlas to create a raylib font. Since this font is in the atlas
// it can be drawn in the same draw call as the other graphics in the atlas. Don't use
// rl.UnloadFont() to destroy this font, instead use `delete_atlased_font`, since we've set up the
// memory ourselves.
//
// The set of available glyphs is governed by `LETTERS_IN_FONT` in `atlas_builder.odin`
// The set of available fonts depends on the contents of FONTS_DIR in `atlas_builder.odin`
@(private = "file") //don't go through these uncached helpers, use the cache
load_atlased_font :: proc(font_name: FontName) -> rl.Font {
	num_glyphs := len(LETTERS_IN_FONT)
	font_rects := make([]rl.Rectangle, num_glyphs)
	glyphs := make([]rl.GlyphInfo, num_glyphs)

	for ag, idx in atlas_fonts[font_name] {
		font_rects[idx] = rect_to_rl_rect(ag.rect)
		glyphs[idx] = {
			value    = ag.value,
			offsetX  = i32(ag.offset_x),
			offsetY  = i32(ag.offset_y),
			advanceX = i32(ag.advance_x),
		}
	}

	return {
		baseSize = ATLAS_FONT_SIZE,
		glyphCount = i32(num_glyphs),
		glyphPadding = 0,
		texture = atlas,
		recs = raw_data(font_rects),
		glyphs = raw_data(glyphs),
	}
}
delete_atlased_font :: proc(font: rl.Font) {
	delete(slice.from_ptr(font.glyphs, int(font.glyphCount)))
	delete(slice.from_ptr(font.recs, int(font.glyphCount)))
}
