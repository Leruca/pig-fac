extends WorldGenNodeTestBase
## 卸载一致性（§5.2）：
##   - 加载 A、B 相邻 → 卸载 A → B 边界 2 格内的跨区树 footprint 仍然 is_blocked；
##   - 树的引用计数无泄漏；
##   - 猪所在块永不卸载；战争迷雾/全局计数器不被卸载影响。
## 运行：godot --headless --path . res://tests/worldgen/test_unload_consistency.tscn

const SEED := 606060
var _world: WorldObjects
var _manager: ChunkManager


func _ready() -> void:
	config = WorldGenConfig.load_default()
	_world = WorldObjects.new()
	_world.cell_size = 36
	_world.worldgen_seed = SEED
	_world.worldgen_config = config
	add_child(_world)
	_manager = ChunkManager.new()
	add_child(_manager)
	_manager.setup(config, SEED, _world)
	_test_adjacent_unload_keeps_cross_border_trees()
	_test_reference_counting_no_leak()
	_test_pig_chunk_never_unloaded()
	_test_unload_keeps_global_state()
	_test_unload_reload_keeps_damage()
	_test_materialize_idempotent()
	_finish("UNLOAD CONSISTENCY TESTS")


## 找出"根格在 A、footprint 伸进 B"的树，卸载 A 后这些格在 B 里仍必须被挡。
func _test_adjacent_unload_keeps_cross_border_trees() -> void:
	var chunk_a := Vector2i(0, 0)
	var chunk_b := Vector2i(1, 0)
	_manager.ensure_chunk_now(chunk_a)
	_manager.ensure_chunk_now(chunk_b)
	# 区块 A 的右边界是 x=127，区块 B 的第一格是 x=128；A 的树最多伸出 2 格（3x3），
	# 所以 B 的 x ∈ [128, 129] 才可能被 A 的树覆盖。
	var boundary_x := config.chunk_size * 1 - config.chunk_radius
	var cross_cells: Array[Vector2i] = []
	var cross_roots := {}
	for offset in range(0, 2):
		for y in range(-127, 128):
			var cell := Vector2i(boundary_x + offset, y)
			var root := _world.find_tree_root(cell)
			if root == WorldObjects.INVALID_CELL:
				continue
			if GridMath.chunk_of_cell(root, config.chunk_size) == chunk_a:
				cross_cells.append(cell)
				cross_roots[root] = true
	_check(cross_cells.size() > 0, "接缝处应存在跨区树（否则本用例无效）")
	_check(cross_roots.size() > 0, "接缝处应存在根格在 A 的树")
	# 卸载 A。
	_manager.unload_chunk(chunk_a)
	for cell in cross_cells:
		_check(_world.is_blocked(cell), "卸载 A 后，B 里被 A 的树覆盖的格 %s 仍必须阻塞（不穿树）" % str(cell))
	# 路径也不得穿过这些格。
	for cell in cross_cells:
		_check(_world.is_blocked(cell), "路径判定同样依赖 is_blocked，不得穿透")
	# 重新加载 A 后仍一致（引用计数回到原位）。
	_manager.ensure_chunk_now(chunk_a)
	for cell in cross_cells:
		_check(_world.is_blocked(cell), "重新加载 A 后跨区树仍应阻塞")


## 引用计数：每个 root 的引用数 == 收录它的已物化区块数；全部卸载后清零。
func _test_reference_counting_no_leak() -> void:
	var chunks: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
	for chunk in chunks:
		if not _manager.is_loaded(chunk):
			_manager.ensure_chunk_now(chunk)
	var expected := {}
	for chunk in chunks:
		var data := _manager.get_chunk(chunk)
		if data == null:
			continue
		for obstacle in data.obstacles:
			if int(obstacle["kind"]) != ChunkData.KIND_TREE:
				continue
			var root: Vector2i = obstacle["cell"]
			expected[root] = int(expected.get(root, 0)) + 1
	var mismatched := 0
	for root_value in expected.keys():
		var actual := int(_world._tree_refs.get(root_value, 0))
		if actual != int(expected[root_value]):
			mismatched += 1
	_check_equal(mismatched, 0, "树引用计数必须等于收录它的区块数（无泄漏/无短缺）")
	# 全部卸载：世界里的树应清空（因为没有区块再引用它们）。
	var pig_chunks: Array = []
	for chunk in chunks:
		_manager.unload_chunk(chunk)
	_check_equal(_manager.loaded_count(), 0, "全部卸载后不应还有加载块")
	_check_equal(_world.tree_roots.size(), 0, "没有区块引用时，程序生成的树应全部去物化")
	_check_equal(_world.get_tree_reference_count(), 0, "引用表应清空")
	var _unused := pig_chunks


## 猪驻留圈永不被卸载，且能被分帧管线主动补齐。
func _test_pig_chunk_never_unloaded() -> void:
	var pig_chunk := Vector2i(5, 5)
	_manager._pig_cells = func() -> Array: return [pig_chunk]
	_manager.config.keep_radius_chunks = 0
	_manager.config.pig_residency_radius_chunks = 1
	_manager._last_center = Vector2i(0, 0)
	_manager.ensure_chunk_now(pig_chunk)
	_manager.ensure_chunk_now(pig_chunk + Vector2i(1, 0))
	_manager.ensure_chunk_now(Vector2i(9, 9))
	_manager._evaluate_unload()
	_check(_manager.is_loaded(pig_chunk), "猪所在区块永不被卸载")
	_check(_manager.is_loaded(pig_chunk + Vector2i(1, 0)), "猪驻留圈内区块不被卸载")
	_check(not _manager.is_loaded(Vector2i(9, 9)), "猪驻留圈外且超出 keep 半径的区块应被卸载")
	# 恢复默认，避免影响后续用例。
	_manager.config.keep_radius_chunks = config.keep_radius_chunks
	_manager._pig_cells = Callable()
	_manager._last_center = Vector2i(2147483647, 2147483647)


## 全局态（战争迷雾 / 新生猪编号）不受卸载影响。
func _test_unload_keeps_global_state() -> void:
	var next_index := _world._next_born_pig_index
	var chunk := Vector2i(-3, 2)
	_manager.ensure_chunk_now(chunk)
	_world._next_born_pig_index = next_index + 3
	_manager.unload_chunk(chunk)
	_check_equal(_world._next_born_pig_index, next_index + 3, "卸载不得重置新生猪编号（全局态）")


## 卸载再加载：部分采集的矿 / 锤了一半的树 不能被生成基底覆盖回去。
func _test_unload_reload_keeps_damage() -> void:
	var chunk := Vector2i(7, 7)
	var data := _manager.ensure_chunk_now(chunk)
	_check(not data.ores.is_empty(), "测试区块应有矿")
	var roots: Array[Vector2i] = []
	for obstacle in data.obstacles:
		if int(obstacle["kind"]) == ChunkData.KIND_TREE and GridMath.chunk_of_cell(obstacle["cell"], config.chunk_size) == chunk:
			roots.append(obstacle["cell"])
	_check(not roots.is_empty(), "测试区块应有树")
	if data.ores.is_empty() or roots.is_empty():
		return
	# 必须挑一块"一次挖不空"的矿，否则分不出"部分采集"与"采空"两句语义。
	var ore_cell := Vector2i(2147483647, 2147483647)
	for entry in data.ores:
		if int(entry["amount"]) >= 3:
			ore_cell = entry["cell"]
			break
	if ore_cell == Vector2i(2147483647, 2147483647):
		ore_cell = data.ores[0]["cell"]
	var ore_base := _world.get_ore_amount(ore_cell)
	var tree_root: Vector2i = roots[0]
	var tree_base := _world.get_tree_remaining_hits(tree_root)
	_world.hit_ore(ore_cell, 1)
	_world.hit_tree(tree_root)
	# 第一步：直接卸载（同会话内，尚未落盘 → 走 flush 分支）。
	_manager.unload_chunk(chunk)
	_manager.ensure_chunk_now(chunk)
	_check_equal(_world.get_ore_amount(ore_cell), ore_base - 1, "卸载重载后部分采集量不得回退")
	_check_equal(_world.get_tree_remaining_hits(tree_root), tree_base - 1, "卸载重载后树的损伤不得回退")
	# 第二步：先落盘再卸载重载。
	_world.hit_ore(ore_cell, 1)
	_manager.flush_chunk(chunk)
	_manager.unload_chunk(chunk)
	_manager.ensure_chunk_now(chunk)
	_check_equal(_world.get_ore_amount(ore_cell), ore_base - 2, "落盘后卸载重载，采集量必须仍然一致")
	_check(not _manager.is_dirty(chunk), "重载后的块应当是干净的")


## 物化幂等：重复 ensure 同一块不会重复登记引用/重复加树。
func _test_materialize_idempotent() -> void:
	var chunk := Vector2i(6, -4)
	_manager.ensure_chunk_now(chunk)
	var first_count := _world.tree_roots.size()
	var first_refs := _world.get_tree_reference_count()
	_manager.ensure_chunk_now(chunk)
	_check_equal(_world.tree_roots.size(), first_count, "重复 ensure 不应重复加树")
	_check_equal(_world.get_tree_reference_count(), first_refs, "重复 ensure 不应重复计数")
	_manager.unload_chunk(chunk)
	_manager.unload_chunk(chunk)
	_check(not _manager.is_loaded(chunk), "重复卸载应安全")