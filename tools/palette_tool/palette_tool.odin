#+build !wasm32
#+build !wasm64p32
/*
Atlas Palette Tool
------------------
Opens atlas.png in a zoomable/pannable view.
Hover over a pixel to see the TextureName at that location.
Left-click to copy the enum variant name to the clipboard.

Usage (from project root):
    odin run source/palette_tool
*/

package palette_tool

import game "../../source"
import "core:fmt"
import "core:os"
import rl "vendor:raylib"

ATLAS_PNG :: "source/atlas.png"

TextureEntry :: struct {
	name: string,
	rect: rl.Rectangle,
}

main :: proc() {
	// Build entry list from the game package's atlas_textures at startup.
	entries := make([dynamic]TextureEntry)
	defer {
		for e in entries {delete(e.name)}
		delete(entries)
	}
	for tex, name in game.atlas_textures {
		r := tex.rect
		if r.width <= 0 || r.height <= 0 {continue}
		append(
			&entries,
			TextureEntry {
				name = fmt.aprintf("%v", name),
				rect = rl.Rectangle{f32(r.x), f32(r.y), f32(r.width), f32(r.height)},
			},
		)
	}

	rl.SetTraceLogLevel(.NONE) //shup up
	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(1280, 800, "Atlas Palette")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	atlas := rl.LoadTexture(ATLAS_PNG)
	if atlas.id == 0 {
		fmt.eprintfln("Failed to load %v", ATLAS_PNG)
		os.exit(1)
	}
	defer rl.UnloadTexture(atlas)

	zoom: f32 = 0.2
	pan := rl.Vector2{}
	hovered_idx := -1

	for !rl.WindowShouldClose() {
		free_all(context.temp_allocator)

		mouse := rl.GetMousePosition()

		// Zoom with scroll wheel, centered on mouse cursor
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			prev_zoom := zoom
			zoom *= 1.0 + wheel * 0.05
			zoom = clamp(zoom, 0.05, 40.0)
			scale := zoom / prev_zoom
			pan = mouse + (pan - mouse) * scale
		}

		// Pan with right mouse or middle mouse drag
		if rl.IsMouseButtonDown(.MIDDLE) || rl.IsMouseButtonDown(.RIGHT) {
			pan += rl.GetMouseDelta()
		}

		// Convert mouse to atlas image coordinates
		atlas_pos := (mouse - pan) / zoom

		// Find the smallest rect that contains the cursor (prefer tightest fit)
		hovered_idx = -1
		best_area := max(f32)
		for e, i in entries {
			r := e.rect
			if atlas_pos.x >= r.x &&
			   atlas_pos.x < r.x + r.width &&
			   atlas_pos.y >= r.y &&
			   atlas_pos.y < r.y + r.height {
				area := r.width * r.height
				if area < best_area {
					best_area = area
					hovered_idx = i
				}
			}
		}

		// Left-click copies the hovered name to clipboard
		if rl.IsMouseButtonPressed(.LEFT) && hovered_idx >= 0 {
			cname := fmt.ctprintf("%v", entries[hovered_idx].name)
			rl.SetClipboardText(cname)
		}

		// Drawing
		rl.BeginDrawing()
		rl.ClearBackground({20, 20, 20, 255})

		// Draw atlas image
		src := rl.Rectangle{0, 0, f32(atlas.width), f32(atlas.height)}
		dst := rl.Rectangle{pan.x, pan.y, f32(atlas.width) * zoom, f32(atlas.height) * zoom}
		rl.DrawTexturePro(atlas, src, dst, {0, 0}, 0, rl.WHITE)

		// Highlight hovered texture rect
		if hovered_idx >= 0 {
			r := entries[hovered_idx].rect
			sr := rl.Rectangle {
				r.x * zoom + pan.x,
				r.y * zoom + pan.y,
				r.width * zoom,
				r.height * zoom,
			}
			thickness := clamp(2.0 / zoom, 1.0, 3.0) * zoom // ~2px at any zoom
			rl.DrawRectangleLinesEx(sr, thickness, {255, 220, 0, 255})
		}

		// Tooltip near cursor
		if hovered_idx >= 0 {
			text := fmt.ctprintf(".%v", entries[hovered_idx].name)
			font_size: i32 = 16
			pad: i32 = 6
			tw := rl.MeasureText(text, font_size)
			bw := tw + pad * 2
			bh := font_size + pad * 2
			tx := i32(mouse.x) + 16
			ty := i32(mouse.y) + 16
			// Keep tooltip on screen
			sw := rl.GetScreenWidth()
			sh := rl.GetScreenHeight()
			status_h: i32 = 26
			if tx + bw > sw {tx = sw - bw - 4}
			if ty + bh > sh - status_h {ty = i32(mouse.y) - bh - 4}
			rl.DrawRectangle(tx, ty, bw, bh, {0, 0, 0, 210})
			rl.DrawRectangleLinesEx({f32(tx), f32(ty), f32(bw), f32(bh)}, 1, {90, 90, 90, 255})
			rl.DrawText(text, tx + pad, ty + pad, font_size, rl.WHITE)
		}

		// Status bar
		{
			sw := rl.GetScreenWidth()
			sh := rl.GetScreenHeight()
			bar_h: i32 = 26
			rl.DrawRectangle(0, sh - bar_h, sw, bar_h, {35, 35, 35, 255})
			rl.DrawLine(0, sh - bar_h, sw, sh - bar_h, {60, 60, 60, 255})
			status: cstring
			if hovered_idx >= 0 {
				status = fmt.ctprintf(".%v  —  click to copy", entries[hovered_idx].name)
			} else {
				status = fmt.ctprintf(
					"scroll: zoom  |  right/middle drag: pan  |  hover: inspect  |  click: copy name  |  zoom: %.2f×",
					zoom,
				)
			}
			rl.DrawText(status, 8, sh - bar_h + 5, 15, {180, 180, 180, 255})
		}

		rl.EndDrawing()
	}
}
