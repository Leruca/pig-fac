class_name ChunkStore
extends RefCounted
## 区块差分存档（overrides）的构建与读写。
##
## 设计（§7.2 / §7.3）：
## - 程序化生成部分**不落盘**：它是 (seed, version, chunk) 的纯函数。
## - 只落"玩家改动"的差分，且差分是**从活体状态与重生成基底做差**得来的，
##   而不是按操作枚举记录。好处：
##     * 撤销全部改动 → 差分自然为空 → 删除该块文件（脏→净回归，不会复活旧改动）；
##     * 行为系统/建造/挖矿走同一份物化表，天然全覆盖，不会漏某个 mutator；
##     * 差分与生成顺序无关，读档不需要重放操作日志。
## - 空 overrides 的文件一律删除（而不是写空文件），保证"与生成一致"的块不占磁盘。

const SAVE_VERSION := 2
const BLOCK_ROOT := "user://saves/main/blocks"


## 由活体状态 + 生成基底构建一块的 overrides。返回的字典恒为规范结构。
static func build_overrides(
	world: WorldObjects,
	base: ChunkData,
	chunk: Vector2i,
	chunk_size: int,
	chunk_radius: int,
	farm_plots: Dictionary
) -> Dictionary:
	var origin := Vector2i(chunk.x * chunk_size - chunk_radius, chunk.y * chunk_size - chunk_radius)
	var overrides := {
		"mined": {},
		"removed_ores": [],
		"chopped_trees": [],
		"tree_hits": {},
		"planted_trees": [],
		"removed_naturals": [],
		"natural_hits": {},
		"saplings": [],
		"logs": [],
		"planks": [],
		"fences": [],
		"chests": [],
		"nests": [],
		"farm": [],
	}

	# --- 矿：生成基底 vs 活体 ---
	var base_ore_cells := {}
	for ore in base.ores:
		var cell: Vector2i = ore["cell"]
		base_ore_cells[cell] = int(ore["amount"])
		var live := world.get_ore_amount(cell)
		if live <= 0:
			overrides["removed_ores"].append(_encode_cell(cell))
		elif live < int(ore["amount"]):
			overrides["mined"][_cell_key(cell)] = int(ore["amount"]) - live

	# --- 树：生成基底 vs 活体 ---
	var base_tree_roots := {}
	for obstacle in base.obstacles:
		if int(obstacle["kind"]) != ChunkData.KIND_TREE:
			continue
		var root: Vector2i = obstacle["cell"]
		# 只处理"根格在本块"的树：边界带的树由它自己的根格区块负责。
		if GridMath.chunk_of_cell(root, chunk_size) != chunk:
			continue
		base_tree_roots[root] = int(obstacle["hp"])
		if not world.tree_roots.has(root):
			overrides["chopped_trees"].append(_encode_cell(root))
			continue
		var remaining := world.get_tree_remaining_hits(root)
		if remaining < int(obstacle["hp"]):
			overrides["tree_hits"][_cell_key(root)] = remaining

	# --- 玩家种下的树（不在生成基底里）：根格在本块才记录 ---
	for root_value in world.tree_roots:
		var root: Vector2i = root_value
		if base_tree_roots.has(root):
			continue
		if GridMath.chunk_of_cell(root, chunk_size) != chunk:
			continue
		overrides["planted_trees"].append({
			"root": _encode_cell(root),
			"hits": world.get_tree_remaining_hits(root),
		})

	# --- 自然障碍（石头/灌木）---
	for obstacle in base.obstacles:
		var kind := int(obstacle["kind"])
		if kind == ChunkData.KIND_TREE:
			continue
		var cell: Vector2i = obstacle["cell"]
		if not world.has_natural_block(cell):
			overrides["removed_naturals"].append(_encode_cell(cell))
			continue
		# 石头/灌木的**部分损伤**也必须落盘，否则敲一下 hp>=2 的石头，
		# overrides 仍为空 → 文件被删 → 读档后耐久回满。
		var remaining := world.get_natural_hp(cell)
		if remaining < int(obstacle.get("hp", 1)):
			overrides["natural_hits"][_cell_key(cell)] = remaining

	# --- 建造物 / 树苗：按格归属 ---
	for cell_value in world.logs.keys():
		var cell: Vector2i = cell_value
		if _in_chunk(cell, origin, chunk_size):
			overrides["logs"].append(_encode_cell(cell))
	for cell_value in world.planks.keys():
		var cell: Vector2i = cell_value
		if _in_chunk(cell, origin, chunk_size):
			overrides["planks"].append(_encode_cell(cell))
	for cell_value in world.fences.keys():
		var cell: Vector2i = cell_value
		if _in_chunk(cell, origin, chunk_size):
			overrides["fences"].append(_encode_cell(cell))
	for cell_value in world.chests.keys():
		var cell: Vector2i = cell_value
		if _in_chunk(cell, origin, chunk_size):
			var inventory: Inventory = world.chests[cell]
			overrides["chests"].append({
				"cell": _encode_cell(cell),
				"inventory": SaveCodec.encode_inventory(inventory),
			})
	for cell_value in world.saplings.keys():
		var cell: Vector2i = cell_value
		if not _in_chunk(cell, origin, chunk_size):
			continue
		var data: Dictionary = world.saplings[cell]
		overrides["saplings"].append({
			"cell": _encode_cell(cell),
			"stage": int(data.get("stage", 0)),
			"elapsed": float(data.get("elapsed", 0.0)),
			"mature_root": _encode_cell(data.get("mature_root", cell - WorldObjects.SAPLING_CENTER_OFFSET)),
			"mature_hp": int(data.get("mature_hp", 0)),
		})
	for root_value in world.nests.keys():
		var root: Vector2i = root_value
		if not _in_chunk(root, origin, chunk_size):
			continue
		var nest: Dictionary = world.nests[root]
		overrides["nests"].append({
			"root": _encode_cell(root),
			"inventory": SaveCodec.encode_inventory(nest.get("inventory")),
			"progress": float(nest.get("progress", 0.0)),
			"active": bool(nest.get("active", false)),
		})

	# --- 农田（地块按格归属）---
	for cell_value in farm_plots.keys():
		var cell: Vector2i = cell_value
		if not _in_chunk(cell, origin, chunk_size):
			continue
		var plot: Dictionary = farm_plots[cell]
		overrides["farm"].append({
			"cell": _encode_cell(cell),
			"crop_id": str(plot.get("crop_id", "")),
			"stage": int(plot.get("stage", 0)),
			"elapsed": float(plot.get("elapsed", 0.0)),
		})
	return overrides


## overrides 是否"与生成一致"（即可以删文件）。
static func is_empty(overrides: Dictionary) -> bool:
	for key in overrides.keys():
		var value: Variant = overrides[key]
		if value is Dictionary:
			if not value.is_empty():
				return false
		elif value is Array:
			if not value.is_empty():
				return false
		elif value is String:
			if not value.is_empty():
				return false
	return true


static func block_file_name(chunk: Vector2i) -> String:
	return "%d_%d.json" % [chunk.x, chunk.y]


static func block_file_path(chunk: Vector2i) -> String:
	return "%s/%s" % [BLOCK_ROOT, block_file_name(chunk)]


## 写一块的 overrides；空 overrides → 删掉已存在的文件（脏→净回归）。
static func write_block(chunk: Vector2i, worldgen_version: int, overrides: Dictionary) -> Dictionary:
	var path := block_file_path(chunk)
	if is_empty(overrides):
		if FileAccess.file_exists(path):
			var dir := DirAccess.open(BLOCK_ROOT)
			if dir != null:
				dir.remove(block_file_name(chunk))
		return {"ok": true, "deleted": true, "path": path}
	var payload := {
		"chunk": [chunk.x, chunk.y],
		"worldgen_version": worldgen_version,
		"overrides": overrides,
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "message": "无法写入区块文件：%s" % path}
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	return {"ok": true, "deleted": false, "path": path}


## 读出所有区块文件。返回 {chunk: payload}；解析失败直接返回错误（先全部解析成功再清空重建）。
static func read_all_blocks() -> Dictionary:
	var result := {"ok": true, "blocks": {}, "message": ""}
	var dir := DirAccess.open(BLOCK_ROOT)
	if dir == null:
		return result
	var file_names: Array[String] = []
	for file_name in dir.get_files():
		if file_name.ends_with(".json"):
			file_names.append(file_name)
	file_names.sort()
	# 单个区块文件损坏不应让**整档**读不出来：跳过并记录下来，
	# 由调用方决定是否提示玩家（其余区块照常恢复）。
	var skipped: Array[String] = []
	for file_name in file_names:
		var path := "%s/%s" % [BLOCK_ROOT, file_name]
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not (parsed is Dictionary):
			skipped.append(file_name)
			continue
		var payload: Dictionary = parsed
		var pair: Variant = payload.get("chunk", null)
		if not (pair is Array) or pair.size() < 2:
			skipped.append(file_name)
			continue
		var chunk := Vector2i(int(pair[0]), int(pair[1]))
		result["blocks"][chunk] = payload
	result["skipped"] = skipped
	if not skipped.is_empty():
		push_warning("ChunkStore: 跳过 %d 个损坏的区块文件：%s" % [skipped.size(), ", ".join(skipped)])
	return result


static func _cell_key(cell: Vector2i) -> String:
	return "%d,%d" % [cell.x, cell.y]


## 供 ChunkMigration 复用的同一套键格式（两处必须完全一致，否则迁移会丢条目）。
static func _cell_key_static(cell: Vector2i) -> String:
	return _cell_key(cell)


static func parse_cell_key(key: String) -> Vector2i:
	var parts := key.split(",")
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


static func _encode_cell(cell: Vector2i) -> Array:
	return [cell.x, cell.y]


static func decode_cell(value: Variant, fallback: Vector2i = Vector2i.ZERO) -> Vector2i:
	if value is Array and value.size() >= 2:
		return Vector2i(int(value[0]), int(value[1]))
	return fallback


static func _in_chunk(cell: Vector2i, origin: Vector2i, chunk_size: int) -> bool:
	return (
		cell.x >= origin.x and cell.x < origin.x + chunk_size
		and cell.y >= origin.y and cell.y < origin.y + chunk_size
	)