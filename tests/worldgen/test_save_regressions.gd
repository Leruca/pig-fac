extends WorldGenNodeTestBase
## 存档复审回归（save-perf hunter 发现的数据丢失缺陷）：
##   S2 读档后 apply_overrides 的差分必须在「卸载→重载」后仍然生效；
##   S3 石头/灌木的部分耐久必须落盘；
##   S4 未加载的脏块不能静默跳过（会被 clear_dirty 永久丢弃）；
##   S5 块文件必须原子写（中断不会留下半截文件）；
##   S6 猪跨块移动不得被两个块各记一次（读档重复生成）。
## 运行：godot --headless --path . res://tests/worldgen/test_save_regressions.tscn

const SEED := 13579
var _world: WorldObjects
var _manager: ChunkManager


func _ready() -> void:
	config = WorldGenConfig.load_default()
	_cleanup_files()
	DirAccess.make_dir_recursive_absolute(ChunkStore.BLOCK_ROOT)
	_setup()
	_test_damage_survives_reload_then_unload()
	_test_natural_block_hp_persists()
	_test_unloaded_dirty_chunk_is_not_silently_skipped()
	_test_atomic_write_no_tmp_left()
	_test_load_applies_deltas()
	_cleanup_files()
	_finish("SAVE REGRESSION TESTS")


func _cleanup_files() -> void:
	var dir := DirAccess.open(ChunkStore.BLOCK_ROOT)
	if dir == null:
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".json") or file_name.ends_with(".tmp") or file_name.ends_with(".bak"):
			dir.remove(file_name)


func _setup() -> void:
	_world = WorldObjects.new()
	_world.cell_size = 36
	_world.worldgen_seed = SEED
	_world.worldgen_config = config
	add_child(_world)
	_manager = ChunkManager.new()
	add_child(_manager)
	_manager.setup(config, SEED, _world)


## S2：读档套用差分后，卸载再重载必须保持损伤（曾回满）。
func _test_damage_survives_reload_then_unload() -> void:
	var chunk := Vector2i(2, 0)
	var data := _manager.ensure_chunk_now(chunk)
	var ore_cell := Vector2i(2147483647, 2147483647)
	for entry in data.ores:
		if int(entry["amount"]) >= 3:
			ore_cell = entry["cell"]
			break
	_check(ore_cell != Vector2i(2147483647, 2147483647), "测试区块应有 amount>=3 的矿")
	if ore_cell == Vector2i(2147483647, 2147483647):
		return
	var base := _world.get_ore_amount(ore_cell)
	_world.hit_ore(ore_cell, 1)
	_manager.flush_chunk(chunk)
	# 模拟「读档」：**从生成基底重新物化**，再套用磁盘差分（这才是真实读档路径）。
	var payload := _read(chunk)
	_manager.unload_chunk(chunk)
	_manager._live_overrides.erase(chunk)
	_manager.ensure_chunk_now(chunk)
	_manager.apply_overrides(chunk, payload)
	_check_equal(_world.get_ore_amount(ore_cell), base - 1, "读档套用后损伤应正确")
	# 关键：读档之后卸载再重载，损伤不能回退。
	_manager.unload_chunk(chunk)
	_manager.ensure_chunk_now(chunk)
	_check_equal(_world.get_ore_amount(ore_cell), base - 1, "读档→卸载→重载后损伤不得回退（S2）")


## S3：石头/灌木的部分耐久必须落盘。
func _test_natural_block_hp_persists() -> void:
	var chunk := Vector2i(-4, 1)
	var data := _manager.ensure_chunk_now(chunk)
	var target := Vector2i(2147483647, 2147483647)
	for obstacle in data.obstacles:
		var kind := int(obstacle["kind"])
		if kind != ChunkData.KIND_TREE and int(obstacle.get("hp", 1)) >= 2:
			target = obstacle["cell"]
			break
	if target == Vector2i(2147483647, 2147483647):
		# 没有 hp>=2 的石头/灌木时，退回用灌木（hp=1）验证「敲掉」路径仍然落盘。
		for obstacle in data.obstacles:
			if int(obstacle["kind"]) != ChunkData.KIND_TREE:
				target = obstacle["cell"]
				break
	_check(target != Vector2i(2147483647, 2147483647), "测试区块应有石头或灌木")
	if target == Vector2i(2147483647, 2147483647):
		return
	var hp_before := _world.get_natural_hp(target)
	_world.hit_natural_block(target)
	var hp_after := _world.get_natural_hp(target)
	_manager.flush_chunk(chunk)
	var payload := _read(chunk)
	var overrides: Dictionary = payload.get("overrides", {})
	if hp_before >= 2 and hp_after >= 1:
		_check(overrides.has("natural_hits"), "部分损伤应写进 natural_hits（S3）")
		_check_equal(
			int((overrides.get("natural_hits", {}) as Dictionary).get(ChunkStore._cell_key_static(target), -1)),
			hp_after,
			"natural_hits 应记录剩余耐久"
		)
		_manager.unload_chunk(chunk)
		_manager.ensure_chunk_now(chunk)
		_manager.apply_overrides(chunk, payload)
		_check_equal(_world.get_natural_hp(target), hp_after, "读档后石头/灌木耐久必须一致（S3）")
	else:
		_check(overrides.get("removed_naturals", []).size() >= 1, "敲碎的石头/灌木应写进 removed_naturals")


## S4：未加载的脏块不能返回 ok=true 而被 clear_dirty 丢掉。
func _test_unloaded_dirty_chunk_is_not_silently_skipped() -> void:
	var chunk := Vector2i(9, 9)
	_manager.mark_chunk_dirty(chunk)
	var result := _manager.flush_chunk(chunk)
	_check(not bool(result.get("ok", true)), "未加载的脏块落盘必须失败而不是静默跳过（S4）")
	_manager._dirty_chunks.erase(chunk)


## S5：写盘必须是 tmp + rename，不留半截文件。
func _test_atomic_write_no_tmp_left() -> void:
	var chunk := Vector2i(1, 3)
	_manager.ensure_chunk_now(chunk)
	# 必须在**该区块内的空闲格**放东西，否则 place_log 失败 → 没有差分可写。
	var placed := false
	var origin := GridMath.chunk_origin(chunk, config.chunk_size)
	for step in 2000:
		var cell := Vector2i(origin.x + 30 + (step % 40) * 2, origin.y + 30 + (step / 40) * 2)
		if not _world.is_blocked(cell):
			placed = _world.place_log(cell)
			break
	_check(placed, "应能在区块 (1,3) 找到空闲格并放下木头")
	_manager.flush_chunk(chunk)
	var path := ChunkStore.block_file_path(chunk)
	_check(FileAccess.file_exists(path), "块文件应已写出")
	_check(not FileAccess.file_exists(path + ".tmp"), "不得残留 .tmp 中间文件（S5）")
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	_check(parsed is Dictionary, "写出的块文件必须是完整可解析的 JSON（S5）")


## 读档把差分套回基底时，所有字段都应生效（挖矿/砍树/建造）。
func _test_load_applies_deltas() -> void:
	var chunk := Vector2i(-6, -6)
	_manager.ensure_chunk_now(chunk)
	var cell := Vector2i(-1500, -1500)
	_check(not _world.is_blocked(cell), "前置条件：格子应空")
	_world.place_log(cell)
	_manager.flush_chunk(chunk)
	var payload := _read(chunk)
	_check(not payload.is_empty(), "应有块文件")
	_manager.unload_chunk(chunk)
	_manager.ensure_chunk_now(chunk)
	_manager.apply_overrides(chunk, payload)
	_check(_world.has_log(cell), "读档后木头必须还在")


func _read(chunk: Vector2i) -> Dictionary:
	var path := ChunkStore.block_file_path(chunk)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}