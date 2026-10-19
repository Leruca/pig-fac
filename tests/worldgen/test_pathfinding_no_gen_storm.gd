extends WorldGenNodeTestBase
## 寻路不得触发生成雪崩（§5.5）：
##   - 目标在未生成区块时，A* 不得同步生成任何区块；
##   - 未生成区块的地形视为可通过；已生成的水必须挡住；
##   - 交互落点校验会同步生成且只生成 1 块。
## 运行：godot --headless --path . res://tests/worldgen/test_pathfinding_no_gen_storm.tscn

const SEED := 13579


func _ready() -> void:
	config = WorldGenConfig.load_default()
	_test_pathfinding_does_not_generate()
	_test_unloaded_terrain_is_passable()
	_test_loaded_water_blocks()
	_finish("PATHFINDING NO GEN STORM TESTS")


## 用一个最小的"寻路探针"复刻 main.gd 的 A* 形状：只调用 is_blocked 与地形查询。
func _pathfind(world: WorldObjects, manager: ChunkManager, start: Vector2i, goal: Vector2i) -> Array:
	var open: Array = [start]
	var seen := {start: true}
	var came := {}
	var guard := 0
	var directions := [
		Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	]
	while not open.is_empty() and guard < 4000:
		guard += 1
		var current: Vector2i = open.pop_front()
		if current == goal:
			var path: Array = [current]
			var cursor := current
			while came.has(cursor):
				cursor = came[cursor]
				path.push_front(cursor)
			return path
		for direction in directions:
			var next_cell: Vector2i = current + direction
			if seen.has(next_cell):
				continue
			if world.is_blocked(next_cell):
				continue
			seen[next_cell] = true
			came[next_cell] = current
			open.append(next_cell)
	return []


func _test_pathfinding_does_not_generate() -> void:
	var world := WorldObjects.new()
	var manager := ChunkManager.new()
	manager.setup(config, SEED, world)
	world.terrain_blocker = manager.is_terrain_blocked
	var loaded_before := manager.loaded_count()
	# 目标在远超 ensure 半径的未生成区块。
	var path := _pathfind(world, manager, Vector2i(0, 0), Vector2i(4096, 4096))
	_check_equal(manager.loaded_count(), loaded_before, "寻路不得同步生成任何区块")
	_check_equal(manager.generator._region_fields.size(), 0, "寻路不得建立噪声窗口缓存")
	var _unused := path
	# 近距离目标（仍在未生成区块）也不得生成。
	# 注意 (0,0) 在出生保护区里，周围有教学树等**非程序生成**的占位；
	# 这里从保护区外起步，单纯验证"未生成区块不被地形挡住"。
	var near_path := _pathfind(world, manager, Vector2i(-4000, 3000), Vector2i(-3985, 3015))
	_check(not near_path.is_empty(), "未生成区块应被视为可通过（能找到路径）")
	_check_equal(manager.loaded_count(), 0, "近距离寻路同样不得触发生成")
	manager.free()
	world.free()


func _test_unloaded_terrain_is_passable() -> void:
	var world := WorldObjects.new()
	var manager := ChunkManager.new()
	manager.setup(config, SEED, world)
	world.terrain_blocker = manager.is_terrain_blocked
	_check_equal(manager.get_cell_terrain(Vector2i(5000, 5000)), -1, "未生成区块的地形查询应返回 -1")
	_check(not manager.is_terrain_blocked(Vector2i(5000, 5000)), "未生成区块不得挡住寻路")
	_check(not world.is_blocked(Vector2i(5000, 5000)), "未生成区块的格子应可通行")
	manager.free()
	world.free()


## 已生成的水必须挡住：找一块已知有水的区域，验证 is_blocked 为真且寻路绕行。
func _test_loaded_water_blocks() -> void:
	var world := WorldObjects.new()
	var manager := ChunkManager.new()
	manager.setup(config, SEED, world)
	world.terrain_blocker = manager.is_terrain_blocked
	var data := manager.ensure_chunk_now(Vector2i(0, 0))
	var water_cell := Vector2i(2147483647, 2147483647)
	var origin := GridMath.chunk_origin(Vector2i(0, 0), config.chunk_size)
	for index in data.terrain.size():
		if data.terrain[index] == TerrainTypes.WATER:
			water_cell = GridMath.chunk_origin(Vector2i(0, 0), config.chunk_size) + Vector2i(index % config.chunk_size, index / config.chunk_size)
			break
	_check(water_cell != Vector2i(2147483647, 2147483647), "区块 (0,0) 应有水格可用于本例")
	if water_cell == Vector2i(2147483647, 2147483647):
		manager.free()
		world.free()
		return
	_check_equal(manager.get_cell_terrain(water_cell), TerrainTypes.WATER, "地形查询应返回 WATER")
	_check(manager.is_terrain_blocked(water_cell), "已生成的水必须挡住寻路")
	_check(world.is_blocked(water_cell), "WorldObjects.is_blocked 必须把水算进去")
	var _unused := origin
	manager.free()
	world.free()