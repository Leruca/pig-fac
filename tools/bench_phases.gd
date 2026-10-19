extends SceneTree
## 单块分相耗时（只用于定标，不做断言）。
## 运行：godot --headless --path . -s res://tools/bench_phases.gd

func _initialize() -> void:
	var config := WorldGenConfig.load_default()
	var seed_value := 20250101
	var generator := WorldGenerator.new(config, seed_value)
	generator.generate_chunk(Vector2i(0, 0))
	var terrain_layer := TerrainLayer.new()
	var chunk := Vector2i(3, 3)
	var field := terrain_layer.make_field(seed_value, config, chunk)
	var terrain := PackedByteArray()
	terrain.resize(config.chunk_size * config.chunk_size)
	var started := Time.get_ticks_usec()
	field.fill_rows(terrain, 0, config.chunk_size)
	var terrain_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var obstacles: Array[Dictionary] = []
	started = Time.get_ticks_usec()
	var sampler := TerrainSampler.new(terrain, GridMath.chunk_origin(chunk, config.chunk_size), config.chunk_size, field)
	ObstacleLayer.generate(seed_value, config, sampler, chunk, obstacles)
	var obstacle_ms := float(Time.get_ticks_usec() - started) / 1000.0
	var origin: Vector2i = GridMath.chunk_origin(chunk, config.chunk_size)
	started = Time.get_ticks_usec()
	var bounds := ObstacleLayer.candidate_bounds(config, chunk)
	for index_y in bounds.size.y:
		var grid_y := bounds.position.y + index_y
		for index_x in bounds.size.x:
			var cell := ObstacleLayer.candidate_cell(seed_value, config, bounds.position.x + index_x, grid_y)
			if cell.x >= origin.x and cell.x < origin.x + config.chunk_size and cell.y >= origin.y and cell.y < origin.y + config.chunk_size:
				EcoLayer.try_place_bush(seed_value, config, sampler, cell, {}, obstacles)
	var eco_ms := float(Time.get_ticks_usec() - started) / 1000.0
	started = Time.get_ticks_usec()
	var ores := OreLayer.collect_chunk(seed_value, config, chunk, func(cell: Vector2i) -> int: return generator.terrain_type_at(cell))
	var ore_ms := float(Time.get_ticks_usec() - started) / 1000.0
	print("PHASES chunk=%s terrain=%.2f obstacle=%.2f eco=%.2f ore(warm)=%.2f ores=%d" % [
		str(chunk), terrain_ms, obstacle_ms, eco_ms, ore_ms, ores.size()
	])
	var candidates := bounds.size.x * bounds.size.y
	print("PHASES candidates=%d step=%d" % [candidates, config.obstacle_cell_chunk_cells])
	quit(0)