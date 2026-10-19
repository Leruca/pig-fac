extends WorldGenNodeTestBase
## 存档往返（§7）：挖矿（部分+采空）、锤树、砍树、建造、撤销全部改动（脏→净删文件）、
## 树苗跨块成熟 → 保存 → 重建 → 状态一致；clean 块不入档。
## 运行：godot --headless --path . res://tests/worldgen/test_save_roundtrip.tscn

const SEED := 31415926
var _world: WorldObjects
var _manager: ChunkManager
var _extra: Array[Node] = []


func _ready() -> void:
	config = WorldGenConfig.load_default()
	_cleanup_files()
	_setup_scene()
	_test_partial_and_full_mining()
	_test_tree_hits_and_chopping()
	_test_building_roundtrip()
	_test_container_contents_dirty_chunk()
	_test_dirty_to_clean_deletes_file()
	_test_crop_growth_does_not_dirty()
	_test_farm_roundtrip()
	_test_sapling_cross_chunk_maturity()
	_test_clean_chunk_not_persisted()
	_cleanup_files()
	_finish("SAVE ROUNDTRIP TESTS")


func _cleanup_files() -> void:
	var dir := DirAccess.open(ChunkStore.BLOCK_ROOT)
	if dir == null:
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".json"):
			dir.remove(file_name)


func _setup_scene() -> void:
	var _err := DirAccess.open("user://").make_dir_recursive("saves/main/blocks")
	_world = WorldObjects.new()
	_world.cell_size = 36
	_world.worldgen_seed = SEED
	_world.worldgen_config = config
	add_child(_world)
	_manager = ChunkManager.new()
	add_child(_manager)
	_manager.setup(config, SEED, _world)


func _ensure(chunk: Vector2i) -> ChunkData:
	return _manager.ensure_chunk_now(chunk)


## 在区块内找 n 个"完全空闲"的格子（避开程序生成的树/石头/灌木/矿）。
func _free_cells(chunk: Vector2i, count: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var origin := GridMath.chunk_origin(chunk, config.chunk_size)
	var cursor := Vector2i(origin.x + 40, origin.y + 40)
	for step in 4000:
		if out.size() >= count:
			break
		var cell := Vector2i(origin.x + 40 + (step % 60) * 2, origin.y + 40 + (step / 60) * 2)
		if _world.is_blocked(cell):
			continue
		out.append(cell)
	var _unused := cursor
	return out


func _read_block(chunk: Vector2i) -> Dictionary:
	var path := ChunkStore.block_file_path(chunk)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {}
	return parsed


## 用磁盘上的 overrides 重建一个全新的运行时，切换到它继续断言。
func _reload(chunk: Vector2i) -> void:
	var fresh_world := WorldObjects.new()
	fresh_world.cell_size = 36
	fresh_world.worldgen_seed = SEED
	fresh_world.worldgen_config = config
	add_child(fresh_world)
	var fresh_manager := ChunkManager.new()
	add_child(fresh_manager)
	fresh_manager.setup(config, SEED, fresh_world)
	fresh_manager.ensure_chunk_now(chunk)
	var payload := _read_block(chunk)
	if not payload.is_empty():
		fresh_manager.apply_overrides(chunk, payload)
	var previous_manager := _manager
	var previous_world := _world
	_world = fresh_world
	_manager = fresh_manager
	previous_manager.clear_all()
	_extra.append(previous_manager)
	_extra.append(previous_world)


func _test_partial_and_full_mining() -> void:
	var chunk := Vector2i(1, 0)
	var data := _ensure(chunk)
	_check(not data.ores.is_empty(), "测试区块 (1,0) 应有矿可供挖")
	if data.ores.is_empty():
		return
	var partial: Vector2i = data.ores[0]["cell"]
	var full: Vector2i = data.ores[data.ores.size() - 1]["cell"]
	var partial_base := _world.get_ore_amount(partial)
	var full_base := _world.get_ore_amount(full)
	_world.hit_ore(partial, 1)
	_world.hit_ore(full, full_base)
	_check(not _world.has_ore(full), "采空后矿点应被移除")
	_check(_manager.is_dirty(chunk), "挖矿后区块应被标脏")
	var result := _manager.flush_chunk(chunk)
	_check(bool(result.get("ok", false)), "落盘应成功")
	var payload := _read_block(chunk)
	_check(not payload.is_empty(), "有改动的区块应产生文件")
	var overrides: Dictionary = payload.get("overrides", {})
	_check(overrides.get("mined", {}).size() >= 1, "部分采集应记录在 mined 里")
	_check(overrides.get("removed_ores", []).size() >= 1, "采空应记录在 removed_ores 里")
	_reload(chunk)
	_check(not _world.has_ore(full), "读档后采空的矿点必须仍然为空")
	_check_equal(_world.get_ore_amount(partial), partial_base - 1, "部分采集的剩余量必须一致")


func _test_tree_hits_and_chopping() -> void:
	var chunk := Vector2i(0, 1)
	var data := _ensure(chunk)
	var roots: Array[Vector2i] = []
	for obstacle in data.obstacles:
		var root: Vector2i = obstacle["cell"]
		if int(obstacle["kind"]) == ChunkData.KIND_TREE and GridMath.chunk_of_cell(root, config.chunk_size) == chunk:
			roots.append(root)
	_check(roots.size() >= 2, "测试区块应至少有两棵树（实际 %d）" % roots.size())
	if roots.size() < 2:
		return
	var damaged := roots[0]
	var chopped := roots[1]
	var damaged_hp := _world.get_tree_remaining_hits(damaged)
	_world.hit_tree(damaged)
	_world.remove_tree(chopped)
	_manager.flush_chunk(chunk)
	var payload := _read_block(chunk)
	var overrides: Dictionary = payload.get("overrides", {})
	_check(overrides.get("tree_hits", {}).size() >= 1, "部分损伤应记录在 tree_hits 里")
	_check(overrides.get("chopped_trees", []).size() >= 1, "砍掉的树应记录在 chopped_trees 里")
	_reload(chunk)
	_check(_world.tree_roots.has(damaged), "受伤但没倒的树，读档后必须还在")
	_check_equal(_world.get_tree_remaining_hits(damaged), damaged_hp - 1, "树的可敲次数必须一致")
	_check(not _world.tree_roots.has(chopped), "砍掉的树读档后不得复活")


func _test_building_roundtrip() -> void:
	var chunk := Vector2i(0, 1)
	_ensure(chunk)
	var free := _free_cells(chunk, 4)
	_check_equal(free.size(), 4, "应能在区块 (0,1) 找到 4 个空闲格")
	if free.size() < 4:
		return
	var cell_log := free[0]
	var cell_plank := free[1]
	var cell_fence := free[2]
	var cell_chest := free[3]
	_world.place_log(cell_log)
	_world.place_plank(cell_plank)
	_world.place_fence(cell_fence)
	var chest := _world.place_chest(cell_chest)
	_check(chest != null, "箱子应能放下")
	if chest != null:
		chest.add_item("wood", 7)
	_manager.flush_chunk(chunk)
	_reload(chunk)
	_check(_world.has_log(cell_log), "木头读档后必须在")
	_check(_world.has_plank(cell_plank), "木板读档后必须在")
	_check(_world.has_fence(cell_fence), "栅栏读档后必须在")
	_check(_world.has_chest(cell_chest), "箱子读档后必须在")
	var loaded := _world.get_chest(cell_chest)
	if loaded != null:
		_check_equal(loaded.get_total_count("wood"), 7, "箱子内容必须完整往返")


## 只往箱子里放东西（不挖不拆）也必须落盘：容器内容变化要触发标脏。
func _test_container_contents_dirty_chunk() -> void:
	var chunk := Vector2i(3, -3)
	_ensure(chunk)
	var free := _free_cells(chunk, 1)
	_check(free.size() == 1, "应能在区块 (3,-3) 找到空闲格")
	if free.is_empty():
		return
	var cell := free[0]
	var chest := _world.place_chest(cell)
	_check(chest != null, "箱子应能放下")
	if chest == null:
		return
	# 清掉放箱子本身产生的脏标记，单独验证"内容变化"这一条路径。
	_manager.flush_chunk(chunk)
	_check(not _manager.is_dirty(chunk), "放完箱子并落盘后应重新变干净")
	chest.add_item("wood", 5)
	# Inventory 用 CONNECT_DEFERRED，等一帧让它真正投递。
	await get_tree().process_frame
	_check(_manager.is_dirty(chunk), "只往箱子里放东西也必须把区块标脏")
	_manager.flush_chunk(chunk)
	var payload := _read_block(chunk)
	var chests: Array = (payload.get("overrides", {}) as Dictionary).get("chests", [])
	_check(chests.size() >= 1, "箱子内容应写进 overrides.chests")
	_reload(chunk)
	var restored := _world.get_chest(cell)
	_check(restored != null, "箱子读档后必须还在")
	if restored != null:
		_check_equal(restored.get_total_count("wood"), 5, "只放不改的箱子内容也必须完整往返")


## 玩家把改动全部撤销 → overrides 为空 → 必须删掉已存在的块文件。
func _test_dirty_to_clean_deletes_file() -> void:
	var chunk := Vector2i(2, 2)
	_ensure(chunk)
	var free := _free_cells(chunk, 1)
	_check(free.size() == 1, "应能在区块 (2,2) 找到空闲格")
	if free.is_empty():
		return
	var cell := free[0]
	_check(_world.place_log(cell), "木头应能放下")
	_manager.flush_chunk(chunk)
	_check(FileAccess.file_exists(ChunkStore.block_file_path(chunk)), "有改动时应写出块文件")
	_world.remove_log(cell)
	var result := _manager.flush_chunk(chunk)
	_check(bool(result.get("deleted", false)), "撤销全部改动后应报告删除文件")
	_check(not FileAccess.file_exists(ChunkStore.block_file_path(chunk)), "脏→净回归必须删除块文件")
	_reload(chunk)
	_check(not _world.has_log(cell), "已撤销的改动不得从旧文件里复活")


## 农田计时豁免：自然生长不能把块标脏（否则任何有作物的块每 30 秒都脏）。
func _test_crop_growth_does_not_dirty() -> void:
	var chunk := Vector2i(-3, 3)
	_ensure(chunk)
	var farm := Farm.new()
	add_child(farm)
	_manager.farm_plots = farm.plots
	var free := _free_cells(chunk, 1)
	if free.is_empty():
		farm.queue_free()
		return
	var cell := free[0]
	farm.till(cell)
	_manager.flush_chunk(chunk)
	_check(not _manager.is_dirty(chunk), "锄地落盘后应干净")
	farm.plant(cell, "potato")
	_manager.flush_chunk(chunk)
	_check(not _manager.is_dirty(chunk), "种植落盘后应干净")
	# 自然生长推进两个阶段：不得标脏。
	farm.advance_growth(61.0)
	_check(not _manager.is_dirty(chunk), "自然生长推进不得把区块标脏（计时豁免）")
	farm.queue_free()


## 农田地块：锄地 + 种植 + 生长进度必须完整往返（这是 overrides 里的 farm 字段）。
func _test_farm_roundtrip() -> void:
	var chunk := Vector2i(-2, -2)
	_ensure(chunk)
	var farm := Farm.new()
	farm.cell_size = 36
	add_child(farm)
	_manager.farm_plots = farm.plots
	var free := _free_cells(chunk, 2)
	_check(free.size() == 2, "应能在区块 (-2,-2) 找到两个空闲格")
	if free.size() < 2:
		return
	var tilled := free[0]
	var grown := free[1]
	farm.till(tilled)
	farm.till(grown)
	farm.plant(grown, "potato")
	_manager.mark_cell_dirty(grown)
	# 让生长进度推进到非零，验证 elapsed 也会往返。
	farm.advance_growth(12.0)
	_manager.flush_chunk(chunk)
	var payload := _read_block(chunk)
	var overrides: Dictionary = payload.get("overrides", {})
	_check(overrides.get("farm", []).size() >= 2, "农田地块应写进 overrides.farm")
	farm.plots.clear()
	_manager.apply_overrides(chunk, payload)
	_check(farm.is_tilled(tilled), "空耕地读档后必须还在")
	_check_equal(farm.get_crop_id(grown), "potato", "作物类型必须一致")
	_check(farm.is_tilled(grown), "种了作物的地块读档后必须还在")
	farm.queue_free()


## 树苗跨块成熟：树苗在区块 0，长成的 3×3 树根格落在区块 -1。
func _test_sapling_cross_chunk_maturity() -> void:
	var chunk_a := Vector2i(0, 0)
	var chunk_b := Vector2i(-1, 0)
	_ensure(chunk_a)
	_ensure(chunk_b)
	var sapling_cell := Vector2i(-127, 40)
	var expected_root := sapling_cell + Vector2i(-1, -1)
	_check_equal(GridMath.chunk_of_cell(sapling_cell, config.chunk_size), chunk_a, "树苗应在区块 0")
	_check_equal(GridMath.chunk_of_cell(expected_root, config.chunk_size), chunk_b, "成熟后的根格应跨到区块 -1")
	for offset_y in range(-3, 4):
		for offset_x in range(-3, 4):
			var cell := sapling_cell + Vector2i(offset_x, offset_y)
			var root := _world.find_tree_root(cell)
			if root != WorldObjects.INVALID_CELL:
				_world.remove_tree(root)
			if _world.has_natural_block(cell):
				_world.remove_natural_block(cell)
			if _world.has_ore(cell):
				_world.remove_ore(cell)
	_check(_world.plant_sapling(sapling_cell), "树苗应能种下")
	var sapling_data: Dictionary = _world.saplings[sapling_cell]
	_check_equal(Vector2i(sapling_data["mature_root"]), expected_root, "种下即应预定成熟根格")
	_check(int(sapling_data["mature_hp"]) >= config.tree_hp_min, "种下即应预定成熟耐久")
	_world.advance_sapling_growth(91.0)
	_check(not _world.has_sapling(sapling_cell), "90 秒后树苗应成熟")
	_check(_world.tree_roots.has(expected_root), "成熟后的树应出现在预定根格")
	_manager.flush_chunk(chunk_a)
	_manager.flush_chunk(chunk_b)
	var payload_a := _read_block(chunk_a)
	var payload_b := _read_block(chunk_b)
	_check(not payload_a.is_empty() or not payload_b.is_empty(), "跨块成熟应至少落一个块文件")
	# 根格所在块必须记录这棵新树（否则读档后成孤儿树）。
	var planted_in_b: Array = (payload_b.get("overrides", {}) as Dictionary).get("planted_trees", [])
	_check(planted_in_b.size() >= 1, "新树必须记录在根格所在区块的 planted_trees 里")
	_reload(chunk_b)
	_check(_world.tree_roots.has(expected_root), "读档后跨块成熟的树不得成为孤儿")


## 完全没改动的区块不应产生文件（clean 不入档）。
func _test_clean_chunk_not_persisted() -> void:
	var chunk := Vector2i(4, 4)
	_ensure(chunk)
	var result := _manager.flush_chunk(chunk)
	_check(not FileAccess.file_exists(ChunkStore.block_file_path(chunk)), "未改动的区块不得写文件")
	_check(bool(result.get("deleted", false)), "未改动的区块应报告无需文件")