This repo is a starter kit for a Nuclear Throne-esque 2D topdown shooter, written in Odin and Raylib. The intended use is for hobbyist game programmers who value control over their engine code to have a springboard for game jams and projects, with some creative commons assets and some core systems common to 2D top-down games figured out already.

# Building

See `Makefile` for build targets. Run `make help` for a summary.

Initially based on [Karl Zylinski's template](https://github.com/karl-zylinski/odin-raylib-hot-reload-game-template) supporting building to web using WebAssembly + emscripten, and building the game to a dynamic library for hot reloading gameplay code.

# Dependencies

- The [Odin compiler](https://odin-lang.org/docs/install/) is needed to build the game.
- [Raylib](https://www.raylib.com/index.html) is used for graphics, sound and input, but since raylib is included as a vendor library in Odin there is **no separate install needed**.
- The [Emscripten compiler](https://emscripten.org/docs/getting_started/downloads.html) (`emcc`) is needed for compiling to wasm specifically **when building for web**.
