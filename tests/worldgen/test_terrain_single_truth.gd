extends WorldGenTestBase
## 复审发现 #2 的回归：地形必须有**唯一事实来源**。
##   fill_rows 写进 ChunkData.terrain 的字节，与 value_at / terrain_at 的点查询，
##   对同一格必须给出同一个类型（历史上是 (raw*21846)>>16 vs floor(raw/3) 的舍入差异）。
## 运行：godot --headless --path . -s res://tests/worldgen/test_terrain_single_truth.gd

const SEEDS := [12345, 20240607, -12345, 0, -1, 9223372036854775807]
const CHUNKS := [Vector2i(0, 0), Vector2i(-1, 0), Vector2i(-2, -2), Vector2i(3, -5)]


func _run() -> void:
	var mismatches := 0
	var compared := 0
	var boundary_hits := 0
	for seed_value in SEEDS:
		var layer := TerrainLayer.new()
		for chunk in CHUNKS:
			var terrain: PackedByteArray = layer.generate(seed_value, config, chunk)
			var field := layer.make_field(seed_value, config, chunk)
			var origin := GridMath.chunk_origin(chunk, config.chunk_size)
			# **全量**比对：曾经抽样 300 格/块时漏掉了 734/3901500 个不一致格。
			# 一块 255×255 = 65025 格，4 块 × 6 种子 = 1.56M 次查询，可接受。
			for local_y in config.chunk_size:
				var row_base := local_y * config.chunk_size
				for local_x in config.chunk_size:
					var stored := terrain[row_base + local_x]
					var queried := field.terrain_at(origin.x + local_x, origin.y + local_y)
					compared += 1
					if stored != queried:
						mismatches += 1
						if mismatches <= 5:
							print("  MISMATCH cell=(%d,%d) stored=%d queried=%d" % [
								origin.x + local_x, origin.y + local_y, stored, queried])
					# 统计非草地格（= 踩在某个阈值附近的格子），用于确认样本覆盖了危险区。
					if stored != TerrainTypes.GRASS:
						boundary_hits += 1
	_check_equal(mismatches, 0, "同一格的「存储地形」与「点查询地形」必须一致（%d/%d 不一致）" % [mismatches, compared])
	_check(compared > 1000000, "全量比对规模应足够（实际 %d 格）" % compared)
	_check(boundary_hits > 1000, "样本必须覆盖阈值附近（实际 %d 格）" % boundary_hits)

	# value_at 与 exact_value 也必须一致（exact_value 是窗口外的兜底路径）。
	var exact_mismatches := 0
	var layer := TerrainLayer.new()
	var field := layer.make_field(12345, config, Vector2i(0, 0))
	var origin := GridMath.chunk_origin(Vector2i(0, 0), config.chunk_size)
	# 窗口内 raw_value_at 与窗口外 raw_exact_value 必须是同一个量（判类才能一致）。
	for index in 400:
		var local_x := (index * 29 + 3) % config.chunk_size
		var local_y := (index * 41 + 5) % config.chunk_size
		var inside := field.raw_value_at(origin.x + local_x, origin.y + local_y)
		var outside := field.raw_exact_value(origin.x + local_x, origin.y + local_y)
		if inside != outside:
			exact_mismatches += 1
	_check_equal(exact_mismatches, 0, "raw_value_at 与 raw_exact_value 必须逐位一致（%d/400 不一致）" % exact_mismatches)
	_finish("TERRAIN SINGLE TRUTH TESTS")