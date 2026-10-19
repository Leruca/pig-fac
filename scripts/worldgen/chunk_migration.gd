class_name ChunkMigration
extends RefCounted
## worldgen_version 升级时的区块差分迁移（迁移式烘焙，§2.4）。
##
## 为什么这样做：overrides 里存的绝大多数是**玩家意图的绝对值**（放了什么、种了什么、
## 砍掉了哪棵树、箱子装了什么），与生成基底无关；只有 `mined` / `tree_hits` /
## `removed_ores` / `chopped_trees` / `removed_naturals` 这五项引用了"生成基底里存在什么"。
##
## 因此迁移 = 用**新版生成器**重算基底，把旧 overrides 重新落到新基底上：
##   - 绝对值类字段原样保留（玩家改动一条不丢）；
##   - 相对值类字段按新基底重新夹取：基底里已经不存在的矿/树/石头就丢弃该条；
##     `mined` 夹到 `0..基底量`，`tree_hits` 夹到 `1..基底耐久-1`（>= 基底耐久视为无效）；
##   - 空的 overrides 删文件（与脏→净同一条规则）。
##
## 好处：不需要永久维护 N 份历史生成器，也不会"拒绝旧档"。
## 代价：升级是**一次性**开销，且只在有 overrides 的块上发生（clean 块本来就重算）。


## 迁移一批区块 payload。返回新 payload 字典（chunk -> payload）。
## 纯函数：不碰 WorldObjects，不需要先物化。
static func migrate_payloads(
	payloads: Dictionary,
	from_version: int,
	to_version: int,
	generator: WorldGenerator
) -> Dictionary:
	var out := {}
	if from_version == to_version:
		for chunk_value in payloads.keys():
			out[chunk_value] = payloads[chunk_value]
		return out
	for chunk_value in payloads.keys():
		var chunk: Vector2i = chunk_value
		var payload: Dictionary = payloads[chunk_value]
		var base: ChunkData = generator.generate_chunk(chunk)
		out[chunk] = {
			"chunk": [chunk.x, chunk.y],
			"worldgen_version": to_version,
			"overrides": rebase_overrides(payload.get("overrides", {}), base),
			"migrated_from": from_version,
		}
	return out


## 把一份旧 overrides 重新落到新基底上。返回规范结构的 overrides。
static func rebase_overrides(old_overrides: Dictionary, base: ChunkData) -> Dictionary:
	var out := {
		"mined": {},
		"removed_ores": [],
		"chopped_trees": [],
		"tree_hits": {},
		"planted_trees": [],
		"removed_naturals": [],
		"saplings": [],
		"logs": [],
		"planks": [],
		"fences": [],
		"chests": [],
		"nests": [],
		"farm": [],
		"pigs": [],
	}

	# 新基底里的矿（amount 用于夹取 mined）。
	var base_ores := {}
	for ore in base.ores:
		base_ores[ore["cell"]] = int(ore["amount"]);
	# 新基底里的树（root -> 耐久）。
	var base_trees := {}
	var base_naturals := {}
	for obstacle in base.obstacles:
		if int(obstacle["kind"]) == ChunkData.KIND_TREE:
			base_trees[obstacle["cell"]] = int(obstacle.get("hp", 0));
		else:
			base_naturals[obstacle["cell"]] = true

	# --- 相对值：按新基底夹取 ---
	for entry in old_overrides.get("removed_ores", []):
		var cell := ChunkStore.decode_cell(entry)
		if base_ores.has(cell):
			out["removed_ores"].append([cell.x, cell.y])
	for key in old_overrides.get("mined", {}).keys():
		var cell := ChunkStore.parse_cell_key(str(key))
		if not base_ores.has(cell):
			continue
		var mined := int(old_overrides["mined"][key])
		var clamped := clampi(mined, 0, int(base_ores[cell]))
		if clamped <= 0:
			continue
		if clamped >= int(base_ores[cell]):
			# 相当于把这一格采空了。
			out["removed_ores"].append([cell.x, cell.y])
			continue
		out["mined"][ChunkStore._cell_key_static(cell)] = clamped
	for entry in old_overrides.get("chopped_trees", []):
		var root := ChunkStore.decode_cell(entry)
		if base_trees.has(root):
			out["chopped_trees"].append([root.x, root.y])
	for key in old_overrides.get("tree_hits", {}).keys():
		var root := ChunkStore.parse_cell_key(str(key))
		if not base_trees.has(root):
			continue
		var base_hp := int(base_trees[root])
		var remaining := int(old_overrides["tree_hits"][key])
		if remaining <= 0:
			# 等于已经砍倒。
			out["chopped_trees"].append([root.x, root.y])
			continue
		if remaining >= base_hp:
			continue  # 新树的耐久更低/相同 → 这条损伤不再有意义
		out["tree_hits"][ChunkStore._cell_key_static(root)] = remaining
	for entry in old_overrides.get("removed_naturals", []):
		var cell := ChunkStore.decode_cell(entry)
		if base_naturals.has(cell):
			out["removed_naturals"].append([cell.x, cell.y])

	# --- 绝对值：原样保留 ---
	for key in ["planted_trees", "saplings", "logs", "planks", "fences", "chests", "nests", "farm", "pigs"]:
		var value: Variant = old_overrides.get(key, [])
		if value is Array:
			out[key] = (value as Array).duplicate(true)
	return out


## 迁移并写盘（用于 SaveManager 读档时）。返回 {ok, migrated, deleted, message}。
static func migrate_and_write(
	payloads: Dictionary,
	from_version: int,
	to_version: int,
	generator: WorldGenerator
) -> Dictionary:
	var migrated := migrate_payloads(payloads, from_version, to_version, generator)
	var written := 0
	var deleted := 0
	var written_files := 0
	var deleted_files := 0
	for chunk_value in migrated.keys():
		var chunk: Vector2i = chunk_value
		var payload: Dictionary = migrated[chunk_value]
		var result := ChunkStore.write_block(chunk, to_version, payload.get("overrides", {}))
		if not bool(result.get("ok", false)):
			return {
				"ok": false,
				"message": "迁移写盘失败：%s" % str(chunk),
				"migrated": migrated,
			}
		if bool(result.get("deleted", false)):
			deleted += 1
			deleted_files += 1
		else:
			written += 1
			written_files += 1
	return {
		"ok": true,
		"migrated": migrated,
		"written": written,
		"deleted": deleted,
		"message": "已将 %d 个区块从 worldgen_version %d 迁移到 %d（%d 写盘 / %d 删除）。"
			% [migrated.size(), from_version, to_version, written_files, deleted_files],
	}
