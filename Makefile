MAIN_DIR = source/main_release
ODIN_ROOT := $(shell odin root)

ifeq ($(OS),Windows_NT)
	EXE = game.exe
	HOT_EXE = game_hot_reload.exe
	DLL_EXT = .dll
	EXTRA_LINKER_FLAGS =
else ifeq ($(shell uname),Darwin)
	EXE = game
	HOT_EXE = game_hot_reload.bin
	DLL_EXT = .dylib
	EXTRA_LINKER_FLAGS = -Wl,-rpath $(ODIN_ROOT)/vendor/raylib/macos
else
	EXE = game
	HOT_EXE = game_hot_reload.bin
	DLL_EXT = .so
	EXTRA_LINKER_FLAGS = '-Wl,-rpath=$$ORIGIN/linux'
endif

HOT_RELOAD_DIR = build/hot_reload
WEB_DIR = build/web
EMSCRIPTEN_SDK_DIR ?= $(HOME)/repos/emsdk

help: #show this help
	@grep -E '^[a-zA-Z_-]+:.*#' $(MAKEFILE_LIST) | \
		sed 's/:.*# */\t/' | \
		column -t -s '	'

#build targets
run: #just quickly build and run
	odin build $(MAIN_DIR) -out:$(EXE) && ./$(EXE)
speed: #build and run with optimizations on
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed && ./$(EXE)
release: atlas #make desktop release build
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:validate=false -define:show_fps=false
debug: #build with debug symbols enabled for use with a debugger
	odin build $(MAIN_DIR) -out:$(EXE) -debug -o:none -define:draw_debug_shapes=true -define:show_object_list=true
mem: #build using a tracking allocator to find memory leaks
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:track_allocations=true
perf: #build with optimizations on and verbose timing logs enabled, for tracking performance stats
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:timing_logs=true
compile-perf: #build with verbose compiler output to troubleshoot slow compiles (probably not much you can do about it lol)
	odin build $(MAIN_DIR) -out:$(EXE) -show-timings -show-more-timings -o:speed


hot-reload: hot-reload-libs hot-reload-dll hot-reload-exe #build hot reload game and runner

hot-reload-libs: #copy platform shared libraries needed at runtime
	@mkdir -p $(HOT_RELOAD_DIR)
ifeq ($(OS),Windows_NT)
	@[ -f raylib.dll ] || cp "$(ODIN_ROOT)/vendor/raylib/windows/raylib.dll" .
else ifneq ($(shell uname),Darwin)
	@if [ ! -d "$(HOT_RELOAD_DIR)/linux" ]; then \
		mkdir -p $(HOT_RELOAD_DIR)/linux; \
		cp -r $(ODIN_ROOT)/vendor/raylib/linux/libraylib*.so* $(HOT_RELOAD_DIR)/linux; \
	fi
endif

hot-reload-dll: hot-reload-libs #build the game shared library
	@echo "Building game$(DLL_EXT)"
	odin build source \
		$(if $(EXTRA_LINKER_FLAGS),-extra-linker-flags:"$(EXTRA_LINKER_FLAGS)") \
		-define:RAYLIB_SHARED=true -build-mode:dll \
		-out:$(HOT_RELOAD_DIR)/game_tmp$(DLL_EXT) -strict-style -debug
	mv $(HOT_RELOAD_DIR)/game_tmp$(DLL_EXT) $(HOT_RELOAD_DIR)/game$(DLL_EXT)

hot-reload-exe: #build the hot reload runner executable (skipped if already running)
	@if command -v pgrep > /dev/null 2>&1 && pgrep -f $(HOT_EXE) > /dev/null 2>&1; then \
		echo "Hot reloading..."; \
	elif command -v tasklist > /dev/null 2>&1 && tasklist | grep -q $(HOT_EXE); then \
		echo "Hot reloading..."; \
	else \
		echo "Building $(HOT_EXE)"; \
		odin build source/main_hot_reload -out:$(HOT_EXE) -strict-style -debug; \
	fi

hot-reload-run: hot-reload #build and run the hot reload game
	./$(HOT_EXE)

web: #build for web using emscripten
	@mkdir -p $(WEB_DIR)
	@export EMSDK_QUIET=1; \
	[ -f "$(EMSCRIPTEN_SDK_DIR)/emsdk_env.sh" ] && . "$(EMSCRIPTEN_SDK_DIR)/emsdk_env.sh"; \
	odin build source/main_web -o:speed -target:js_wasm32 -build-mode:obj \
		-define:glsl_version="300 es" \
		-define:RAYLIB_WASM_LIB=env.o -define:RAYGUI_WASM_LIB=env.o \
		-strict-style -out:$(WEB_DIR)/game.wasm.o; \
	cp $(ODIN_ROOT)/core/sys/wasm/js/odin.js $(WEB_DIR); \
	emcc -g -o $(WEB_DIR)/index.html \
		$(WEB_DIR)/game.wasm.o \
		$(ODIN_ROOT)/vendor/raylib/wasm/libraylib.a \
		$(ODIN_ROOT)/vendor/raylib/wasm/libraygui.a \
		-sUSE_GLFW=3 -sWASM_BIGINT -sWARN_ON_UNDEFINED_SYMBOLS=0 -sASSERTIONS \
		-sINITIAL_HEAP=2147483648 '-sEXPORTED_RUNTIME_METHODS=["HEAPF32"]' \
		-sMAX_WEBGL_VERSION=2 \
		--shell-file source/main_web/index_template.html; \
	rm $(WEB_DIR)/game.wasm.o; \
	echo "Web build created in $(WEB_DIR)"

deploy: #deploy build/web to GitHub Pages (gh-pages branch)
	@if [ ! -f "$(WEB_DIR)/index.html" ]; then echo "Error: $(WEB_DIR)/index.html not found. Run 'make web' first."; exit 1; fi
	@echo "Deploying $(WEB_DIR) to gh-pages branch..."
	@cd $(WEB_DIR) && \
		git init -q && \
		git checkout -q -B gh-pages && \
		git add . && \
		git commit -q -m "deploy" && \
		git push -f git@github.com:DireLines/odin-raylib-topdown-shooter.git gh-pages
	@echo "Deployed! Visit: https://direlines.github.io/odin-raylib-topdown-shooter/"

web-deploy: web deploy #build for web then deploy to GitHub Pages

# build tools
atlas: #run build script to generate atlas.png and atlas.odin from the textures folder
	odin run tools/atlas_builder
palette: #open the atlas palette viewer (zoomable/pannable, hover to inspect, click to copy name)
	odin run tools/palette_tool

.PHONY: help run speed release debug mem perf compile-perf atlas palette \
       hot-reload hot-reload-libs hot-reload-dll hot-reload-exe hot-reload-run web \
       deploy web-deploy

.DEFAULT_GOAL := run
