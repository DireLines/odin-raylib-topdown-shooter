run: 
	odin build source -out:game && ./game
speed: 
	odin build source -out:game -o:speed && ./game
release: atlas wordgen
	odin build source -out:earshot -o:speed -define:validate=false -define:show_fps=false
debug:
	odin build source -out:game -debug -o:none -define:draw_debug_shapes=true
mem:
	odin build source -out:game -o:speed -define:track_allocations=true
perf:
	odin build source -out:game -o:speed -define:timing_logs=true
compile-perf:
	odin build source -out:game -show-timings -show-more-timings -o:speed
atlas:
	odin run source/atlas_builder
wordgen:
	odin run source/words/word_generator
