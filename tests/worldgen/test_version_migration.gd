extends WorldGenNodeTestBase
## 版本迁移（迁移式烘焙，§2.4）：
##   旧 overrides 用**新版生成器**重算基底后重新落地 ——
##   绝对值字段（建造物/箱子/农田/猪）一条不丢；
##   相对值字段按新基底夹取（基底里已不存在的矿/树/石头丢弃，mined/hits 夹取到合法区间）。
## 运行：godot --headless --path . res://tests/worldgen/test_version_migration.tscn

const SEED := 246810


func _ready() -> void:
	SavePaths.set_root("user://saves/test_version_migration")
	config = WorldGenConfig.load_default()
	_test_absolutes_preserved()
	_test_relatives_clamped()
	_test_empty_after_rebase_deletes_file()
	_test_same_version_is_noop()
	_finish("VERSION MIGRATION TESTS")


func _base_for(chunk: Vector2i, version: int) -> ChunkData:
	var custom := WorldGenConfig.load_default()
	custom.worldgen_version = version
	var generator := WorldGenerator.new(custom, SEED)
	return generator.generate_chunk(chunk)


## 建造物 / 箱子内容 / 农田 / 猪：与基底无关，必须原样保留。
func _test_absolutes_preserved() -> void:
	var chunk := Vector2i(0, 0)
	var old_overrides := {
		"logs": [[1, 2], [3, 4]],
		"planks": [[5, 6]],
		"fences": [[7, 8]],
		"chests": [{"cell": [9, 10], "inventory": {"slot_count": 40, "slots": [{"item_id": "wood", "count": 7}]}}],
		"nests": [{"root": [11, 12], "inventory": {"slot_count": 4, "slots": []}, "progress": 3.5, "active": true}],
		"farm": [{"cell": [13, 14], "crop_id": "potato", "stage": 2, "elapsed": 12.5}],
		"saplings": [{"cell": [15, 16], "stage": 1, "elapsed": 4.0, "mature_root": [14, 15], "mature_hp": 4}],
		"planted_trees": [{"root": [20, 20], "hits": 3}],
		"pigs": [{"name": "猪 9", "cell": [0, 0]}],
	}
	var base := _base_for(chunk, 2)
	var rebased := ChunkMigration.rebase_overrides(old_overrides, base)
	_check_equal(rebased["logs"].size(), 2, "木头必须保留")
	_check_equal(rebased["planks"].size(), 1, "木板必须保留")
	_check_equal(rebased["fences"].size(), 1, "栅栏必须保留")
	_check_equal(rebased["chests"].size(), 1, "箱子必须保留")
	_check_equal(rebased["nests"].size(), 1, "猪窝必须保留")
	_check_equal(rebased["farm"].size(), 1, "农田必须保留")
	_check_equal(rebased["saplings"].size(), 1, "树苗必须保留")
	_check(rebased["saplings"][0].has("mature_root"), "树苗的预定根格必须保留")
	_check_equal(int(rebased["saplings"][0]["mature_hp"]), 4, "树苗的预定耐久必须保留")
	_check_equal(rebased["planted_trees"].size(), 1, "玩家种的树必须保留")
	_check_equal(rebased["pigs"].size(), 1, "猪必须保留")


## 相对值：新基底里已经不存在的矿/树/石头必须丢弃；存在的要夹取到合法区间。
func _test_relatives_clamped() -> void:
	var chunk := Vector2i(1, 1)
	var base := _base_for(chunk, 2)
	var present_ore := Vector2i(2147483647, 2147483647)
	var absent_ore := Vector2i(100000, 100000)
	for ore in base.ores:
		present_ore = ore["cell"]
		break
	var present_tree := Vector2i(2147483647, 2147483647)
	for obstacle in base.obstacles:
		if int(obstacle["kind"]) == ChunkData.KIND_TREE:
			present_tree = obstacle["cell"]
			break
	_check(present_ore != Vector2i(2147483647, 2147483647), "测试区块应有矿")
	_check(present_tree != Vector2i(2147483647, 2147483647), "测试区块应有树")
	if present_ore == Vector2i(2147483647, 2147483647) or present_tree == Vector2i(2147483647, 2147483647):
		return
	var key_ore := ChunkStore._cell_key_static(present_ore)
	var key_tree := ChunkStore._cell_key_static(present_tree)
	var old_overrides := {
		"mined": {key_ore: 999999, "100000,100000": 5},
		"removed_ores": [[absent_ore.x, absent_ore.y]],
		"tree_hits": {key_tree: 999999},
		"chopped_trees": [[100000, 100000]],
		"removed_naturals": [[100000, 100000]],
	}
	var rebased := ChunkMigration.rebase_overrides(old_overrides, base)
	# mined 远超基底量 → 等价采空，转成 removed_ores。
	var removed: Array = rebased["removed_ores"]
	var has_present := removed.has([present_ore.x, present_ore.y])
	_check(has_present, "mined 超过基底量应等价于采空（转进 removed_ores）")
	_check(not rebased["mined"].has("100000,100000"), "基底里不存在的矿必须丢弃 mined 条目")
	_check(not removed.has([absent_ore.x, absent_ore.y]), "基底里不存在的矿必须丢弃 removed_ores 条目")
	# tree_hits 的语义是"剩余可敲次数"。旧树耐久 4、玩家敲了 1 下 → 旧档记 3。
	# 若记下的剩余次数 >= 新基底的耐久，说明相对新树"一下都没敲过"，这条损伤应当丢弃。
	var tree_base_hp := 0
	for obstacle in base.obstacles:
		if int(obstacle["kind"]) == ChunkData.KIND_TREE and obstacle["cell"] == present_tree:
			tree_base_hp = int(obstacle["hp"])
	_check(tree_base_hp >= 1, "基底树的耐久应至少为 1")
	_check(not rebased["chopped_trees"].has([present_tree.x, present_tree.y]), "剩余次数高于新耐久 = 没受过伤，不应判成砍倒")
	_check(not rebased["tree_hits"].has(key_tree), "剩余次数高于新耐久 = 没受过伤，条目应被丢弃")
	# remaining <= 0 才是"已砍倒"。
	var felled := ChunkMigration.rebase_overrides({"tree_hits": {key_tree: 0}}, base)
	_check(felled["chopped_trees"].has([present_tree.x, present_tree.y]), "剩余次数为 0 应等价砍倒")
	_check(not rebased["chopped_trees"].has([100000, 100000]), "基底里不存在的树必须丢弃 chopped 条目")
	_check(not rebased["removed_naturals"].has([100000, 100000]), "基底里不存在的石头必须丢弃")
	# 合法中间值要保留。
	var mid_base_hp := 0
	for obstacle in base.obstacles:
		if int(obstacle["kind"]) == ChunkData.KIND_TREE and obstacle["cell"] == present_tree:
			mid_base_hp = int(obstacle["hp"])
	if mid_base_hp >= 2:
		var mid_overrides := {"tree_hits": {key_tree: mid_base_hp - 1}}
		var mid_rebased := ChunkMigration.rebase_overrides(mid_overrides, base)
		_check_equal(
			int(mid_rebased["tree_hits"].get(key_tree, -1)),
			mid_base_hp - 1,
			"合法范围内的 tree_hits 必须原样保留"
		)


## 重基之后若什么都不剩（所有相对条目都指向已消失的基底物），文件应被删除而不是留空壳。
func _test_empty_after_rebase_deletes_file() -> void:
	SavePaths.ensure_dirs()
	var chunk := Vector2i(-5, -5)
	var stale := {
		"mined": {"100000,100000": 3},
		"removed_ores": [[100000, 100000]],
		"tree_hits": {"100000,100000": 2},
	}
	ChunkStore.write_block(chunk, 1, stale)
	_check(FileAccess.file_exists(ChunkStore.block_file_path(chunk)), "前置条件：stale 文件应已写出")
	# 必须真的跨版本，否则 migrate_and_write 会原样保留（no-op）。
	var newer := WorldGenConfig.load_default()
	newer.worldgen_version = config.worldgen_version + 1
	var generator := WorldGenerator.new(newer, SEED)
	var result := ChunkMigration.migrate_and_write({chunk: {"overrides": stale}}, 1, newer.worldgen_version, generator)
	_check(bool(result.get("ok", false)), "迁移应成功")
	_check(not FileAccess.file_exists(ChunkStore.block_file_path(chunk)), "重基后为空必须删掉旧文件")


## 版本相同 → 不做任何重基（保留原 payload 原样）。
func _test_same_version_is_noop() -> void:
	var generator := WorldGenerator.new(config, SEED)
	var payloads := {Vector2i(0, 0): {"overrides": {"logs": [[1, 1]]}, "worldgen_version": 1}}
	var migrated := ChunkMigration.migrate_payloads(payloads, 1, 1, generator)
	_check_equal((migrated[Vector2i(0, 0)]["overrides"] as Dictionary)["logs"].size(), 1, "同版本不应改动 overrides")