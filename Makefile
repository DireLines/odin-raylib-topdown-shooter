MAIN_DIR = source/main_release
ifeq ($(OS),Windows_NT)
	EXE = game.exe
else
	EXE = game
endif

run: #just quickly build and run
	odin build $(MAIN_DIR) -out:$(EXE) && ./$(EXE)
speed: #build and run with optimizations on
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed && ./$(EXE)
release: atlas #make desktop release build
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:validate=false -define:show_fps=false
debug: #build with debug symbols enabled for use with a debugger
	odin build $(MAIN_DIR) -out:$(EXE) -debug -o:none -define:draw_debug_shapes=true
mem: #build using a tracking allocator to find memory leaks
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:track_allocations=true
perf: #build with optimizations on and verbose timing logs enabled, for tracking performance stats
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:timing_logs=true
compile-perf: #build with verbose compiler output to troubleshoot slow compiles (probably not much you can do about it lol)
	odin build $(MAIN_DIR) -out:$(EXE) -show-timings -show-more-timings -o:speed
atlas: #run build script to generate atlas.png and atlas.odin from the textures folder
	odin run source/atlas_builder