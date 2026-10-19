extends WorldGenTestBase
## 复审发现 #3/#5 的回归：
##   #3 step() 的**行预算**必须真的生效（曾经只有毫秒闸门有效）；
##   #5 chunk_radius 只能由 chunk_size 推导（曾经是第二个事实来源）。
## 运行：godot --headless --path . -s res://tests/worldgen/test_slice_and_config_guards.gd


func _run() -> void:
	_test_row_budget_is_a_real_gate()
	_test_slicing_equals_one_shot()
	_test_chunk_radius_is_derived()
	_finish("SLICE & CONFIG GUARD TESTS")


## 行预算：step(32 行, 1000ms) 只应推进 32 行，而不是一口气跑完。
func _test_row_budget_is_a_real_gate() -> void:
	var generator := WorldGenerator.new(config, 12345)
	var job := generator.make_job(Vector2i(0, 0))
	var rows_before := job._rows_done
	var done := job.step(32, 1000)
	var advanced := job._rows_done - rows_before
	_check(not done, "32 行预算下，一块 255 行的区块不应一次跑完")
	_check_equal(advanced, 32, "行预算必须精确生效（每次推进 32 行）")
	# 再推进一次仍然是 32 行。
	rows_before = job._rows_done
	job.step(32, 1000)
	_check_equal(job._rows_done - rows_before, 32, "连续两次 step 都应只推进 32 行")
	# 毫秒闸门在**批次之间**检查：一个 batch 一旦开始就做完，之后立刻停。
	# 因此 (行预算=1, 毫秒=0) 的契约是"只推进 1 行"，而不是跑满。
	var fast_job := generator.make_job(Vector2i(1, 0))
	fast_job.step(1, 0)
	_check_equal(fast_job._rows_done, 1, "行预算 1 + 毫秒 0：只应推进 1 行")
	# 行预算是上界：无论毫秒预算多大，单次推进都不得超过它。
	var bounded_job := generator.make_job(Vector2i(2, 0))
	bounded_job.step(10, 1000000)
	_check(bounded_job._rows_done <= 10, "单次推进不得超过行预算（实际 %d）" % bounded_job._rows_done)


## 任意切片粒度下，最终哈希都必须与一次性生成一致。
func _test_slicing_equals_one_shot() -> void:
	var generator := WorldGenerator.new(config, 20240607)
	for pair in [[0, 0], [-2, 1], [3, -3]]:
		var chunk := Vector2i(int(pair[0]), int(pair[1]))
		var one_shot: ChunkData = generator.generate_chunk(chunk)
		var reference := ChunkHasher.chunk_hash(
			20240607, config.worldgen_version, chunk, one_shot.terrain, one_shot.obstacles, one_shot.ores
		)
		for budget in [1, 7, 32, 64, 255, 1000]:
			var fresh := WorldGenerator.new(config, 20240607)
			var job := fresh.make_job(chunk)
			while not job.step(budget, 1000000):
				pass
			var sliced: ChunkData = job.finish()
			var hash := ChunkHasher.chunk_hash(
				20240607, config.worldgen_version, chunk, sliced.terrain, sliced.obstacles, sliced.ores
			)
			_check_equal(hash, reference, "行预算 %d 的切片结果必须与一次性生成一致" % budget)


## chunk_radius 必须是 (chunk_size-1)/2，即使 JSON 里写了一个不一致的值。
## 注意：这里会打印一条 push_warning（"chunk_radius 不匹配，已强制取 …"），那是预期行为。
func _test_chunk_radius_is_derived() -> void:
	var custom := WorldGenConfig.load_default()
	custom.apply_dict({"chunk_size": 100, "chunk_radius": 127})
	_check_equal(custom.chunk_radius, (100 - 1) / 2, "chunk_radius 必须由 chunk_size 推导，而不是照抄 JSON")
	# 推导之后，地形窗口与 GridMath 的原点必须重合。
	var layer := TerrainLayer.new()
	var field := layer.make_field(12345, custom, Vector2i(2, 2))
	var expected := GridMath.chunk_origin(Vector2i(2, 2), custom.chunk_size)
	_check_equal(Vector2i(field.origin_x, field.origin_y), expected, "地形窗口原点必须与 GridMath 一致")
	_check_equal(Vector2i(field.size_x, field.size_y), Vector2i(custom.chunk_size, custom.chunk_size), "窗口尺寸必须等于 chunk_size")