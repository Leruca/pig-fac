extends WorldGenTestBase
## 生成顺序无关性：同批区块以随机置换顺序生成，最终哈希必须一致。
## 同时验证：REGION 矿脉缓存不会因为"先生成哪块"而改变结果。
## 运行：godot --headless --path . -s res://tests/worldgen/test_generation_order_invariance.gd

const SEED := 424242


func _run() -> void:
	_test_permutations()
	_test_interleaved_generators()
	_test_ore_cache_order_independence()
	_finish("GENERATION ORDER INVARIANCE TESTS")


func _collect(chunks: Array[Vector2i]) -> Dictionary:
	var generator := WorldGenerator.new(config, SEED)
	var out := {}
	for chunk in chunks:
		out[chunk] = _hash_of(generator, SEED, generator.generate_chunk(chunk))
	return out


func _test_permutations() -> void:
	var chunks := _chunks_in_rect(Vector2i(-1, -1), Vector2i(2, 2))
	var baseline := _collect(chunks)
	# 三种反向/交错顺序，都应与基准逐块一致。
	var orderings: Array = [chunks.duplicate(), [], []]
	var reversed: Array[Vector2i] = []
	for index in range(chunks.size() - 1, -1, -1):
		reversed.append(chunks[index])
	orderings[1] = reversed
	var shuffled: Array[Vector2i] = []
	var step := 7
	var cursor := 0
	for index in chunks.size():
		cursor = (cursor + step) % chunks.size()
		shuffled.append(chunks[cursor])
	orderings[2] = shuffled
	for order_index in orderings.size():
		var order: Array = orderings[order_index]
		var generator := WorldGenerator.new(config, SEED)
		for chunk in order:
			var data := generator.generate_chunk(chunk)
			_check_equal(
				_hash_of(generator, SEED, data),
				baseline[chunk],
				"顺序 %d 下区块 %s 的哈希必须与基准一致" % [order_index, str(chunk)]
			)


## 两个生成器交错推进同一批块（共享的 REGION 静态缓存被两边交替命中）。
func _test_interleaved_generators() -> void:
	var chunks := _chunks_in_rect(Vector2i(3, 3), Vector2i(6, 5))
	var baseline := _collect(chunks)
	var left := WorldGenerator.new(config, SEED)
	var right := WorldGenerator.new(config, SEED)
	for chunk in chunks:
		var left_data := left.generate_chunk(chunk)
		var right_data := right.generate_chunk(chunk)
		_check_equal(_hash_of(left, SEED, left_data), baseline[chunk], "交错生成 A %s" % str(chunk))
		_check_equal(_hash_of(right, SEED, right_data), baseline[chunk], "交错生成 B %s" % str(chunk))


## 矿脉缓存命中/未命中两种路径的结果必须一样。
func _test_ore_cache_order_independence() -> void:
	var chunk := Vector2i(1, 1)
	OreLayer.reset_cache()
	var cold_generator := WorldGenerator.new(config, SEED)
	var cold := _hash_of(cold_generator, SEED, cold_generator.generate_chunk(chunk))
	# 先预热整整一圈邻域 REGION，再生成同一块（全命中路径）。
	var warm_generator := WorldGenerator.new(config, SEED)
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			var region := GridMath.region_of_chunk(chunk, config.ore_region_chunks)
			var neighbor := region + Vector2i(offset_x, offset_y)
			var region_origin := GridMath.region_origin_cell(neighbor, config.ore_region_chunks, config.chunk_size)
			var probe := region_origin + Vector2i(config.chunk_size / 2, config.chunk_size / 2)
			warm_generator.generate_chunk(GridMath.chunk_of_cell(probe, config.chunk_size))
	var warm := _hash_of(warm_generator, SEED, warm_generator.generate_chunk(chunk))
	_check_equal(warm, cold, "冷/热矿脉缓存下同一区块哈希必须一致")
