extends WorldGenTestBase
## 出生保护区（§4.5）：
##   - 半径 R 内全 GRASS、无 obstacle、无 ore；
##   - "根格在 R+1、footprint 伸进 R" 的树必须被移除（逐格 footprint 判定）；
##   - 初始猪位 (0,0)/(4,0)/(8,0) 与教学树 9 格不被占。
## 运行：godot --headless --path . -s res://tests/worldgen/test_spawn_guard.gd

const SEED := 20240607


func _run() -> void:
	var generator := WorldGenerator.new(config, SEED)
	var data := generator.generate_chunk(Vector2i(0, 0))
	_test_terrain_clear(data)
	_test_no_obstacles(data)
	_test_no_ores(data)
	_test_reserved_cells(data)
	_test_footprint_granular_removal()
	_test_reserved_cells_are_config_driven()
	_finish("SPAWN GUARD TESTS")


func _inside(cell: Vector2i, radius: int) -> bool:
	return maxi(absi(cell.x), absi(cell.y)) <= radius


func _local_of(data: ChunkData, cell: Vector2i) -> Vector2i:
	return GridMath.local_of_cell(cell, data.chunk, config.chunk_size)


func _test_terrain_clear(data: ChunkData) -> void:
	var radius := config.spawn_safe_radius_cells
	var origin := GridMath.chunk_origin(data.chunk, config.chunk_size)
	var bad := 0
	for y in range(-radius, radius + 1):
		for x in range(-radius, radius + 1):
			var local := _local_of(data, Vector2i(x, y))
			var terrain_type := data.terrain[local.y * config.chunk_size + local.x]
			if terrain_type != TerrainTypes.GRASS:
				bad += 1
	_check_equal(bad, 0, "出生半径 %d 内必须全是 GRASS（实际 %d 格不是）" % [radius, bad])
	_check_equal(origin, Vector2i(-127, -127), "区块 (0,0) 的原点应是 (-127,-127)")


func _test_no_obstacles(data: ChunkData) -> void:
	var radius := config.spawn_safe_radius_cells
	var footprint := config.tree_footprint
	var offenders: Array[String] = []
	for obstacle in data.obstacles:
		var root: Vector2i = obstacle["cell"]
		var size := footprint if int(obstacle["kind"]) == ChunkData.KIND_TREE else 1
		var touches := false
		for offset_y in size:
			for offset_x in size:
				if _inside(root + Vector2i(offset_x, offset_y), radius):
					touches = true
		if touches:
			offenders.append(str(root))
	_check_equal(offenders.size(), 0, "出生区内不得有 footprint 覆盖它的障碍：%s" % str(offenders))


func _test_no_ores(data: ChunkData) -> void:
	var radius := config.spawn_safe_radius_cells
	var offenders: Array[String] = []
	for ore in data.ores:
		var cell: Vector2i = ore["cell"]
		if _inside(cell, radius):
			offenders.append(str(cell))
	_check_equal(offenders.size(), 0, "出生区内不得有矿：%s" % str(offenders))


## 初始猪位与教学树 9 格：既不被障碍占，也不被水挡。
func _test_reserved_cells(data: ChunkData) -> void:
	for cell in config.spawn_reserved_cells:
		var local := _local_of(data, cell)
		_check_equal(data.terrain[local.y * config.chunk_size + local.x], TerrainTypes.GRASS, "猪位 %s 应是 GRASS" % str(cell))
		var blocked := false
		for obstacle in data.obstacles:
			var root: Vector2i = obstacle["cell"]
			var size := config.tree_footprint if int(obstacle["kind"]) == ChunkData.KIND_TREE else 1
			if cell.x >= root.x and cell.x < root.x + size and cell.y >= root.y and cell.y < root.y + size:
				blocked = true
		_check(not blocked, "猪位 %s 不得被障碍覆盖" % str(cell))
	for entry in config.spawn_reserved_footprints:
		var root: Vector2i = entry["root"]
		var size := int(entry["size"])
		for offset_y in size:
			for offset_x in size:
				var cell := root + Vector2i(offset_x, offset_y)
				var local := _local_of(data, cell)
				_check_equal(
					data.terrain[local.y * config.chunk_size + local.x],
					TerrainTypes.GRASS,
					"教学树格 %s 应是 GRASS" % str(cell)
				)
	_check_equal(config.spawn_reserved_cells.size(), 3, "配置里应保留 3 个猪位")
	_check_equal(config.spawn_reserved_cells[0], Vector2i(0, 0), "猪 1 在 (0,0)")
	_check_equal(config.spawn_reserved_cells[1], Vector2i(4, 0), "猪 2 在 (4,0)")
	_check_equal(config.spawn_reserved_cells[2], Vector2i(8, 0), "猪 3 在 (8,0)")


## 直接构造一个"根格在 R+1、footprint 伸进 R"的树，验证 SpawnGuard 会删掉它。
func _test_footprint_granular_removal() -> void:
	var radius := config.spawn_safe_radius_cells
	var data := ChunkData.new()
	data.chunk = Vector2i(0, 0)
	data.terrain = PackedByteArray()
	data.terrain.resize(config.chunk_size * config.chunk_size)
	data.terrain.fill(TerrainTypes.GRASS)
	# footprint 只往 +x/+y 方向铺开，所以"根格在保护区外、树冠伸进来"只能发生在负方向：
	# 根格 (-(radius+2), 0) 的 3×3 覆盖到 -24，恰好压进 |x| ≤ radius 的保护区。
	var root := Vector2i(-(radius + 2), 0)
	data.obstacles = [
		{"cell": root, "kind": ChunkData.KIND_TREE, "hp": 3},
		# 对照：根格在 (radius+2, radius+2) 的石头完全不碰保护区，必须留下。
		{"cell": Vector2i(radius + 2, radius + 2), "kind": ChunkData.KIND_ROCK, "hp": 1},
	]
	data.ores = [
		{"cell": Vector2i(radius, radius), "ore_id": 1, "amount": 2},
		{"cell": Vector2i(radius + 1, radius + 1), "ore_id": 1, "amount": 2},
	]
	SpawnGuard.apply(SEED, config, data.chunk, data)
	var tree_roots: Array[String] = []
	for obstacle in data.obstacles:
		tree_roots.append(str(obstacle["cell"]))
	_check(not tree_roots.has(str(root)), "footprint 伸进保护区的树必须被移除")
	_check(tree_roots.has(str(Vector2i(radius + 2, radius + 2))), "不碰保护区的石头必须保留")
	var ore_cells: Array[String] = []
	for ore in data.ores:
		ore_cells.append(str(ore["cell"]))
	_check(not ore_cells.has(str(Vector2i(radius, radius))), "保护区内的矿必须被移除")
	_check(ore_cells.has(str(Vector2i(radius + 1, radius + 1))), "保护区外的矿必须保留")

	# 负方向再远 1 格：根格 (-(radius+3), 0) 的 footprint 停在 -(radius+1)，不碰保护区 → 保留。
	var data2 := ChunkData.new()
	data2.chunk = Vector2i(0, 0)
	data2.terrain = PackedByteArray()
	data2.terrain.resize(config.chunk_size * config.chunk_size)
	data2.terrain.fill(TerrainTypes.GRASS)
	var outside_root := Vector2i(-(radius + 3), 0)
	data2.obstacles = [{"cell": outside_root, "kind": ChunkData.KIND_TREE, "hp": 3}]
	SpawnGuard.apply(SEED, config, data2.chunk, data2)
	_check_equal(data2.obstacles.size(), 1, "恰好贴着保护区的树（footprint 不相交）应保留")


## 配置驱动：改半径后保护范围跟着变（代码里没有硬编码 R）。
func _test_reserved_cells_are_config_driven() -> void:
	var custom := WorldGenConfig.load_default()
	custom.spawn_safe_radius_cells = 4
	var generator := WorldGenerator.new(custom, SEED)
	var data := generator.generate_chunk(Vector2i(0, 0))
	var offenders := 0
	for obstacle in data.obstacles:
		var root: Vector2i = obstacle["cell"]
		if _inside(root, 4):
			offenders += 1
	_check_equal(offenders, 0, "半径改成 4 后 5×5 内仍应无障碍")
	_check_equal(custom.spawn_reserved_cells.size(), 3, "配置合并后猪位仍为 3 个")
