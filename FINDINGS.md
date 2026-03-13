# Code Review Findings

Codebase: Odin/Raylib top-down shooter engine ("atomic chair")
Reviewed: main.odin, atomic_chair.odin, physics.odin, geometry.odin, render.odin,
tilemap.odin, animation.odin, transform.odin, object_types.odin, timer.odin,
handle_map_static/handle_map.odin, atlas_builder/atlas_builder.odin,
palette_tool/palette_tool.odin, and supporting files.

---

## Critical (MUST fix)

### C1 — `spawn_ui_slider` double-spawns the slider object
**File:** [source/atomic_chair.odin](source/atomic_chair.odin#L901-L903)

The function correctly creates the slider with `spawn_and_return_object(slider_def)` on line
901, wires up associated objects, then immediately calls `spawn_object(slider_def)` *again*
on the return line. The function returns a handle to the second (orphaned) object — the first
one, with properly set `handle_handle` and associated objects, is leaked and unreachable.
The volume slider in both the main menu and pause menu is affected.

```odin
// line 901: correct spawn
slider_handle, slider_object = spawn_and_return_object(slider_def)
handle_object.associated_objects["slider"] = slider_handle
// line 903: BUG — spawns a second copy; should be `return slider_handle, ...`
return spawn_object(slider_def), slider_info.handle_handle
```

**Fix:** Replace `spawn_object(slider_def)` with `slider_handle` on the return line.

---

### C2 — `object_inst_from_handle` panics on invalid handle
**File:** [source/object_types.odin](source/object_types.odin#L14-L17)

`hm.get` returns `nil` for an invalid or stale handle. The result is passed directly to
`object_inst_from_obj_ptr` without a nil check, which then accesses `o.variant.(T)` —
an immediate nil dereference panic.

```odin
object_inst_from_handle :: proc(h: GameObjectHandle, $T: typeid) -> GameObjectInst(T) {
    o := hm.get(&game.objects, h)   // can be nil
    return object_inst_from_obj_ptr(o, T)  // panics if o == nil
}
```

This is called in live gameplay code (e.g. `handle_ui_sliders` accesses
`slider.handle_handle` this way). If a slider handle becomes stale the game will crash.

---

## High (Should address before further development)

### H1 — A* path reconstruction omits the start node
**File:** [source/geometry.odin](source/geometry.odin#L365-L378)

`reconstruct_path` walks `came_from` backwards from `end`. The loop condition is
`for (current in came_from)`. Because the start node is never added to `came_from`,
the loop exits before appending it. The returned path begins at the *second* tile,
not the first. Enemies navigating toward a target will skip directly to the second
waypoint.

---

### H2 — `has_line_of_sight` skips the last tile
**File:** [source/geometry.odin](source/geometry.odin#L292-L298)

```odin
for i in 0 ..< len(tiles) - 1 {  // last tile never checked
```

A wall at the destination tile (the `b` endpoint) is never checked. A bullet or
line-of-sight query terminating inside a wall cell will incorrectly return `true`.

---

### H3 — A* candidate deduplication is O(n) linear scan → O(n²) overall
**File:** [source/geometry.odin](source/geometry.odin#L399-L408)

```odin
for c in candidates.queue {
    if c.tile == neighbor { ... }
}
```

Every neighbor update scans the entire priority queue to check membership. This
degrades A* from O(n log n) to O(n²) as the open set grows. On larger maps with
many enemies pathfinding simultaneously, this will be a significant CPU bottleneck.

**Fix:** Track membership in a separate `map[TilemapTileId]bool` (already using
`context.temp_allocator` for everything else in that proc).

---

### H4 — Render layers never cleared on `reset_game`
**File:** [source/atomic_chair.odin](source/atomic_chair.odin#L485-L492)

`reset_game` calls `hm.clear(&game.objects)` but leaves all `game.render_layers`
arrays intact. After reset the render layer arrays are full of stale handles from
the old session. The next render loop tries to draw those invalid handles, produces
spurious `hm.get` misses, and also has an extra log line:

```odin
print("RECREATING FINAL TRANSFORMS BUT SHOULD NOT NEED TO HERE")
```

**Fix:** Clear all `game.render_layers[i]` slices in `reset_game`.

---

### H5 — Enemy `TilePath` is never freed before being replaced
**File:** [source/atomic_chair.odin](source/atomic_chair.odin#L80-L84), [source/geometry.odin](source/geometry.odin#L370)

`reconstruct_path` allocates its path with the default (heap) allocator. Enemy's
`path: TilePath` stores this. When the path is recalculated (expected every
`PATHFINDING_UPDATE_INTERVAL` frames), the old allocation is simply overwritten
with no `delete`. With many enemies this is a steady memory leak.

---

### H6 — `random_point_in_visible_range` can loop forever
**File:** [source/geometry.odin](source/geometry.odin#L191-L197)

```odin
random_point_in_visible_range :: proc(center: vec2, radius: f64) -> vec2 {
    p := random_point_in_circle(center, radius)
    for !has_line_of_sight(center, p) {
        p = random_point_in_circle(center, radius)
    }
    return p
}
```

If no point within the circle has line-of-sight (e.g. center is in a walled-off
pocket), this loops forever, hanging the game.

---

### H7 — Window resize breaks world↔screen coordinate math
**Files:** [source/transform.odin](source/transform.odin#L13-L17), [source/render.odin](source/render.odin#L532)

`screen_conversion` is a compile-time constant using `WINDOW_WIDTH` / `WINDOW_HEIGHT`.
`get_chunks_near_cam` also uses these compile-time constants. The window is created
with `{.WINDOW_RESIZABLE}`, so after a resize all world-to-screen and
screen-to-world conversions use stale values. Mouse picking, camera frustum culling,
and viewport-edge chunking will silently compute incorrect results.

**Fix:** Replace the constant with a proc that reads `rl.GetScreenWidth/Height()` at
call time, or update `screen_conversion` each frame.

---

## Medium (Nice to haves / don't need to fix urgently)

### M1 — Map literals recreated per tile in `color_to_tile`
**File:** [source/atomic_chair.odin](source/atomic_chair.odin#L205-L224)

`COLOR_TO_TILETYPE` and `COLOR_TO_SPAWN` maps are local to the `color_to_tile`
closure and are constructed (and destroyed) for *every tile* in the map. Even with
`#+feature dynamic-literals`, this adds allocation overhead for every tile read.
These should be declared as `@(rodata)` or `#partial` arrays keyed on color, or
hoisted outside the closure.

---

### M2 — `dir_path_to_file_infos` leaks sub-directory entry slices
**File:** [source/atlas_builder/atlas_builder.odin](source/atlas_builder/atlas_builder.odin#L720-L728)

Recursive calls return a `[]os.File_Info` that is iterated and appended but never
freed. The atlas builder is a short-lived tool so this won't crash, but it's
technically a leak.

---

### M3 — `load_font` does not free the `letters` rune slice
**File:** [source/atlas_builder/atlas_builder.odin](source/atlas_builder/atlas_builder.odin#L300)

```odin
letters := utf8.string_to_runes(LETTERS_IN_FONT)
```
The returned slice is heap-allocated but never deleted.

---

### M4 — `ticks_until_change` uint underflow in animation
**File:** [source/animation.odin](source/animation.odin#L36)

```odin
anim_state.ticks_until_change -= 1
if anim_state.ticks_until_change > 0 { return }
```

`ticks_until_change` is `uint`. If `ticks_per_frame` is `0`, it's initialized to
`0` and the first decrement wraps to `max(uint)`. The animation then effectively
freezes for ~584 million years. There is no guard against `ticks_per_frame = 0`.

---

### M5 — `hm.add` return value (ok bool) discarded in `spawn_and_return_object`
**File:** [source/main.odin](source/main.odin#L261)

```odin
h := hm.add(&game.objects, object)
```

If the handle map is full (`MAX_OBJECTS = 1 << 17` slots), `hm.add` returns
`({}, false)`. The zero handle `{}` is silently appended to the render layer array
and used throughout. Every subsequent render/physics lookup on it will silently
fail. The overflow goes completely undetected.

---

### M6 — `pixel_filter_ex` has `EndDrawing` outside the game loop
**File:** [source/main.odin](source/main.odin#L72-L73)

`rl.BeginDrawing()` is inside the loop but `rl.EndDrawing()` is after it. If this
dev/test proc were ever called it would crash raylib (mismatched begin/end).

---

### M7 — Duplicated volume slider construction in menus
**Files:** [source/atomic_chair.odin](source/atomic_chair.odin#L271-L286), [source/atomic_chair.odin](source/atomic_chair.odin#L435-L450)

The volume slider block in `main_menu_start` and `pause_menu_start` is verbatim
copy-paste. Divergence is likely over time.

---

### M8 — Transform hierarchy cycle → stack overflow
**File:** [source/render.odin](source/render.odin#L92-L134)

`get_final_transform_cached` is recursive. If the parent/child chain contains a
cycle (a → b → a), it will recurse until a stack overflow. No depth limit or
cycle-detection guard exists.

---

### M9 — `get_world_center` / `local_to_world` can panic with invalid handle
**File:** [source/transform.odin](source/transform.odin#L26-L36)

```odin
get_world_center :: proc(h: GameObjectHandle) -> vec2 {
    o := hm.get(&game.objects, h)  // nil if invalid
    return local_to_world(h, o.pivot)  // panics
}
```

---

### M10 — `spawn_enemy` `switch enemy_type` block is a no-op
**File:** [source/atomic_chair.odin](source/atomic_chair.odin#L795-L800)

The switch only sets `obj_name` (a string used for `enemy.name` which is then
set to `fmt.aprint(obj_name)` anyway). No stats, textures, or behaviors differ
between enemy types. The `EnemyType` enum exists but is effectively unused.

---

### M11 — `has_line_of_sight` has dead variables `d` and `coord`
**File:** [source/geometry.odin](source/geometry.odin#L291-L292)

```odin
d := b - a
coord := math.abs(d.x) > math.abs(d.y) ? 0 : 1
```

Both are computed and never read. (Same issue in `print_line_of_sight`.)

---

## Low (Nits)

### L1 — `print` aliased to `fmt.println`
**File:** [source/main.odin](source/main.odin#L87)

```odin
print :: fmt.println
```

Makes it easy to leave debug logging in production code with no grep-able
distinction from intentional output.

---

### L2 — Debug panic message in hot render path
**File:** [source/render.odin](source/render.odin#L409)

```odin
print("RECREATING FINAL TRANSFORMS BUT SHOULD NOT NEED TO HERE")
recreate_final_transforms()
```

This fires every frame if the condition is hit. Should be `assert(false, ...)` or
removed once the underlying cause (H4 above) is fixed.

---

### L3 — `box_cast_tiles` is an unimplemented stub
**File:** [source/geometry.odin](source/geometry.odin#L526-L546)

Always returns `false`. If anything in the codebase later calls this expecting
actual sweep collision, it will silently produce wrong results.

---

### L4 — `num_anim_frames_left` can produce a large positive uint
**File:** [source/atomic_chair.odin](source/atomic_chair.odin#L698-L700)

```odin
num_anim_frames_left := int(bullet.animation.anim.last_frame - bullet.animation.frame)
```

`TextureName` is likely an enum backed by an integer. If `frame > last_frame` (can
happen after ping-pong or when swapping animations mid-flight), `last_frame - frame`
wraps to a large positive value when cast to `int`. Dead bullets would never be
cleaned up.

---

### L5 — `BASE_WINDOW_WIDTH` is a misleading name
**File:** [source/main.odin](source/main.odin#L14)

It is a scale factor (`1.2`), not a base width. `WINDOW_SCALE` would be clearer.

---

### L6 — `objects_to_draw` and `tile_render_layers_used` as package-level globals
**File:** [source/render.odin](source/render.odin#L349-L350)

These are single-use scratch variables for the `render()` proc. As globals they
require manual clearing and make `render()` non-reentrant. Declaring them inside
`render()` would be cleaner (or pass as parameters).

---

### L7 — "Visiable" typo
**File:** [source/atlas_builder/atlas_builder.odin](source/atlas_builder/atlas_builder.odin#L442)

```odin
if ase.Layer_Chunk_Flag.Visiable in c.flags {
```

Likely mirrors a typo in the underlying ase library, but worth noting.

---

### L8 — `Timer` struct stores proc fields
**File:** [source/timer.odin](source/timer.odin)

`timer->time(...)` style requires resolving a proc pointer on every call. Since
`timing_logs` is a compile-time `#config` flag that gates all timer bodies anyway,
ordinary top-level procs with a `^Timer` parameter would be simpler and equally
zero-cost when disabled.

---

## Highlights (Things done well — replicate these patterns)

### ✓ Handle-based entity management
`handle_map_static` uses index + generation pairs for safe, stable entity
references. Handles can be stored anywhere without worrying about pointer
invalidation. The fixed-size backing array means no allocator calls during gameplay
and cache-friendly iteration. Checking handle validity (`hm.get` returning nil) is
encouraged by the API design.

### ✓ Hot-reload architecture
All mutable game state lives in a single heap-allocated `Game` struct. The
`game_hot_reloaded` callback re-seats the global pointer. Combined with the
separate `main_hot_reload` entry point, this enables live code changes without
losing game state — an enormous dev-loop advantage.

### ✓ Compile-time gating for debug/timing code
`timer.odin` uses `when timing_logs` (a `#config` boolean) so all timing
instrumentation compiles to zero code in release. Same pattern used for
`draw_debug_shapes` and `show_fps`. This is the right way to do optional dev
features in Odin.

### ✓ Declarative type assertion system
`TYPE_ASSERTS` / `validate_object_types` catches tag/variant/collision-layer
inconsistencies at runtime during development (gated by `#config(validate, true)`).
This turns a class of bugs that would otherwise be mysterious gameplay glitches into
clear error messages. More assertions should be added as the type space grows.

### ✓ Atlas builder completeness
The atlas builder handles .ase/.aseprite (with indexed color, multiple layers,
frame animations, Aseprite tags), plain PNGs, JSON-described spritesheets, TTF
fonts, and tilesets with padding. It auto-crops, auto-scales the atlas if rects
don't fit, and emits stable `TileId` enum values so saved tile data doesn't break
when the atlas is regenerated.

### ✓ Palette tool
`palette_tool` is a small but genuinely useful dev utility: a pannable/zoomable
atlas viewer that maps pixel hover to `TextureName` enum variants and copies them
to the clipboard. Reduces the friction of looking up sprite coordinates to zero.

### ✓ Sweep-and-prune broad phase
Sorting boxes by `bounds.min.x` and early-exiting when `b.bounds.min.x > a.bounds.max.x`
is textbook and correct. Combined with chunk-based spatial hashing, this avoids
O(n²) all-pairs checks in the common case.

### ✓ Collision layer matrix as `@(rodata)` bitset array
`COLLISION_MATRIX: [CollisionLayer]bit_set[CollisionLayer]` is a clean,
data-driven way to express the collision graph. `layers_can_collide` is a
two-instruction bitset operation. Extending or querying the matrix requires no
procedural changes.

### ✓ Two-pass A* with line-of-sight shortcutting
Running raw A* then removing intermediate waypoints that are mutually visible
produces smoother, more natural-looking enemy paths with no extra steering logic
required.

### ✓ DDA tile intersection with diagonal handling
`tiles_intersecting_line` correctly identifies tiles on both sides of diagonal
crossings — not just the "primary" tile — which prevents bullets from passing
through tile corners.

### ✓ `#unroll` in tight inner loops
Using `#unroll for i in 0 ..< 4` for AABB side iteration, bounding-box corner
computation, and winding-order reversal in the renderer is appropriate and
communicates intent clearly.
