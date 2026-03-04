MAIN_DIR = source/main_release
ifeq ($(OS),Windows_NT)
	EXE = game.exe
else
	EXE = game
endif

run:
	odin build $(MAIN_DIR) -out:$(EXE) && ./$(EXE)
speed:
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed && ./$(EXE)
release: atlas
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:validate=false -define:show_fps=false
debug:
	odin build $(MAIN_DIR) -out:$(EXE) -debug -o:none -define:draw_debug_shapes=true
mem:
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:track_allocations=true
perf:
	odin build $(MAIN_DIR) -out:$(EXE) -o:speed -define:timing_logs=true
compile-perf:
	odin build $(MAIN_DIR) -out:$(EXE) -show-timings -show-more-timings -o:speed
atlas:
	odin run source/atlas_builder