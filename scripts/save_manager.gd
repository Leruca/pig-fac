class_name SaveManager
extends RefCounted
## 单存档：global.json（全局态）+ blocks/x_y.json（区块 overrides 差分）。
##
## 与旧版的差别（§7）：
## - global.json 增加 "seed"（**字符串**，64 位整数直接存 JSON 会丢精度）与
##   "worldgen_version"；visited_blocks / next_born_pig_index 等全局态照旧全量写。
## - **不再 _clear_block_files() 全删**：保存遍历 dirty 集合，overrides 为空则删文件
##   （玩家撤销全部改动 → 回到生成一致状态 → 文件必须消失，否则旧改动会复活）。
## - 读档：先**全部解析成功**再清空重建（安全性不变），但重生成分批进行：
##   只急切恢复相机周围 N 块，其余标记"待惰性重生成"，走与运行时同一套分片管线。

const VERSION := 2
const SAVE_ROOT := "user://saves/main"
const BLOCK_ROOT := "user://saves/main/blocks"
const GLOBAL_FILE := "user://saves/main/global.json"
const PIG_SCENE := preload("res://scenes/pig.tscn")

var main: Node


func setup(main_node: Node) -> void:
	main = main_node


func save_path() -> String:
	return ProjectSettings.globalize_path(SAVE_ROOT)


func has_save() -> bool:
	return FileAccess.file_exists(GLOBAL_FILE)


## 当前存档是否带有种子。用 has_saved_seed() 区分「没有存档」与「存档里的种子正好是 0」——
## 0 是合法种子（golden hashes 里有），不能用 0 当哨兵值。
func has_saved_seed() -> bool:
	if not has_save():
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GLOBAL_FILE))
	if not (parsed is Dictionary):
		return false
	return (parsed as Dictionary).has("seed")


## 当前存档的种子（无档时返回 0，调用方应先用 has_saved_seed()）。
func stored_seed() -> int:
	if not has_saved_seed():
		return 0
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GLOBAL_FILE))
	if not (parsed is Dictionary):
		return 0
	return SeedSystem.parse_seed(str(parsed.get("seed", "0")))


func save_game() -> Dictionary:
	if main == null:
		return {"ok": false, "message": "游戏尚未初始化。"}
	if not _ensure_folders():
		return {"ok": false, "message": "无法创建存档目录。"}
	var manager: ChunkManager = main.chunk_manager
	var world: WorldObjects = main.world_objects
	var farm: Farm = main.farm

	# 1) 落盘所有 dirty 块。
	#    猪是**全局态**（与 _visited_blocks / _next_born_pig_index 同类），统一写进 global.json，
	#    不再按块分桶：曾经分桶既会用「只有 pigs 字段」的 payload 覆盖掉整块文件（丢档），
	#    又会在猪跨块移动时被两个块各记一次（读档重复生成）。
	var written := 0
	var deleted := 0
	for chunk in manager.dirty_chunks():
		# 未加载的脏块（例如树苗跨块成熟把邻块标脏）必须先生成再落盘，否则改动会被丢掉。
		if not manager.is_loaded(chunk):
			manager.ensure_chunk_now(chunk)
		var result := manager.flush_chunk(chunk, farm.plots)
		if not bool(result.get("ok", false)):
			return {"ok": false, "message": "写入区块存档失败：%s" % str(chunk)}
		if bool(result.get("deleted", false)):
			deleted += 1
		else:
			written += 1
	# 4) 全局文件
	var visited: Array = []
	for block_value in main._visited_blocks.keys():
		var block: Vector2i = block_value
		visited.append([block.x, block.y])
	var camera_position: Vector2 = main.camera.global_position
	var pigs_global: Array = []
	for pig_value in main.pigs:
		var pig: Pig = pig_value
		if pig != null:
			pigs_global.append(_encode_pig(pig))
	var global_data := {
		"version": VERSION,
		"seed": SeedSystem.seed_to_string(manager.get_seed()),
		"pigs": pigs_global,
		"worldgen_version": manager.get_worldgen_version(),
		"camera": SaveCodec.encode(camera_position),
		"zoom": float(main._map_zoom),
		"visited_blocks": visited,
		"audio_muted": bool(main.is_audio_muted()),
		"next_born_pig_index": int(main.world_objects._next_born_pig_index),
		"tick": int(Time.get_ticks_msec()),
	}
	if not _write_json(GLOBAL_FILE, global_data):
		return {"ok": false, "message": "写入 global.json 失败。"}
	manager.clear_dirty()
	return {
		"ok": true,
		"message": "已保存 %d 个区块（%d 删除/回归，%d 只猪）。" % [written, deleted, main.pigs.size()],
	}


func load_game() -> Dictionary:
	if main == null:
		return {"ok": false, "message": "游戏尚未初始化。"}
	if not FileAccess.file_exists(GLOBAL_FILE):
		return {"ok": false, "message": "还没有存档。"}
	var global_value: Variant = JSON.parse_string(FileAccess.get_file_as_string(GLOBAL_FILE))
	if not (global_value is Dictionary):
		return {"ok": false, "message": "global.json 无法解析。"}
	var global: Dictionary = global_value
	var version := int(global.get("version", 0))
	if version < 1 or version > VERSION:
		return {"ok": false, "message": "存档版本不匹配（%d，期望 %d）。" % [version, VERSION]}

	# 1) 先全部解析成功（失败时不动内存状态）。
	var block_result := ChunkStore.read_all_blocks()
	if not bool(block_result.get("ok", false)):
		return {"ok": false, "message": str(block_result.get("message", "区块文件读取失败。"))}
	var payloads: Dictionary = block_result["blocks"]

	# 1.5) 版本迁移（迁移式烘焙，§2.4）：旧档的 overrides 用**新版生成器**重算基底后重新落地。
	#     只在 worldgen_version 不一致时发生；迁移结果立刻写盘，之后按新版走。
	var seed_value := SeedSystem.parse_seed(str(global.get("seed", "0")))
	if seed_value == 0:
		seed_value = int(global.get("seed", 0))
	var stored_worldgen_version := int(global.get("worldgen_version", 0))
	var current_version: int = main.worldgen_config.worldgen_version
	if stored_worldgen_version != 0 and stored_worldgen_version != current_version:
		var migration_generator := WorldGenerator.new(main.worldgen_config, seed_value)
		var migration := ChunkMigration.migrate_and_write(
			payloads, stored_worldgen_version, current_version, migration_generator
		)
		if not bool(migration.get("ok", false)):
			return {"ok": false, "message": str(migration.get("message", "版本迁移失败。"))}
		payloads = migration["migrated"]
		print("[WorldGen] %s" % str(migration.get("message", "")))

	# 2) 再清空重建。
	_clear_runtime()
	main.chunk_manager.setup(main.worldgen_config, seed_value, main.world_objects, main._pig_chunk_callable())
	main.chunk_manager.farm_plots = main.farm.plots
	main.world_objects._next_born_pig_index = int(global.get("next_born_pig_index", 4))

	# 3) 猪：优先读全局列表；旧档（pigs 还在块文件里）走兼容分支。
	var pig_entries: Array = global.get("pigs", [])
	if pig_entries.is_empty():
		for payload in payloads.values():
			for pig_value in payload.get("overrides", {}).get("pigs", []):
				if pig_value is Dictionary:
					pig_entries.append(pig_value)
	for pig_value in pig_entries:
		if pig_value is Dictionary:
			_load_pig(pig_value)

	main._visited_blocks.clear()
	for pair in global.get("visited_blocks", []):
		if pair is Array and pair.size() >= 2:
			main._visited_blocks[Vector2i(int(pair[0]), int(pair[1]))] = true

	var camera_position: Vector2 = SaveCodec.decode(global.get("camera", [0.0, 0.0]))
	var zoom := clampf(float(global.get("zoom", 1.0)), 0.1, 4.0)
	main._map_zoom = zoom
	main.camera.zoom = Vector2.ONE * zoom
	main.camera.global_position = camera_position
	main._free_camera_position = camera_position
	main._camera_offset = Vector2.ZERO
	main._last_pig_cell = Vector2i(2147483647, 2147483647)
	main.apply_audio_muted(bool(global.get("audio_muted", false)))
	main.hud.set_map_zoom(zoom)

	# 4) 家园块（有猪/有改动的块）急切同步恢复；其余走惰性分帧管线。
	var home_chunks: Array[Vector2i] = []
	for chunk_key in payloads.keys():
		var chunk: Vector2i = chunk_key
		var overrides: Dictionary = payloads[chunk].get("overrides", {})
		if overrides.has("pigs") and not (overrides["pigs"] as Array).is_empty():
			home_chunks.append(chunk)
	var eager_radius: int = main.worldgen_config.eager_load_radius_chunks
	var center_chunk: Vector2i = main.chunk_manager.chunk_of_cell(
		main.grid.world_to_cell(camera_position)
	)
	for chunk_key in payloads.keys():
		var chunk: Vector2i = chunk_key
		var distance := maxi(absi(chunk.x - center_chunk.x), absi(chunk.y - center_chunk.y))
		if distance <= eager_radius:
			home_chunks.append(chunk)
	for chunk in home_chunks:
		if not payloads.has(chunk):
			continue
		main.chunk_manager.ensure_chunk_now(chunk)
		main.chunk_manager.apply_overrides(chunk, payloads[chunk])
		payloads.erase(chunk)
	# 剩下的登记为"待惰性重生成"。
	main.chunk_manager.prime_restore(payloads)
	main.chunk_manager.resume_load(main.grid.world_to_cell(camera_position))
	main.farm.queue_redraw()
	main.world_objects.queue_redraw()
	main._mark_visible_blocks()
	main.hud.set_hint(
		"存档已读取：%d 个区块待按需恢复，%d 只猪。"
		% [payloads.size(), main.pigs.size()]
	)
	return {
		"ok": true,
		"message": "读取成功：%d 个区块待按需恢复，%d 只猪。" % [payloads.size(), main.pigs.size()],
	}


## 新档：写入种子与版本（只调用一次，之后种子固定）。
func init_new_game(seed_value: int) -> void:
	main.worldgen_config = WorldGenConfig.load_default()
	main.chunk_manager.setup(main.worldgen_config, seed_value, main.world_objects, main._pig_chunk_callable())
	main.chunk_manager.farm_plots = main.farm.plots


func _load_pig(data: Dictionary) -> void:
	var pig: Pig = PIG_SCENE.instantiate()
	pig.name = "LoadedPig%d" % (main.pigs.size() + 1)
	main.add_child(pig)
	var position: Vector2 = SaveCodec.decode(data.get("position", [0.0, 0.0]))
	pig.global_position = position
	var cell: Vector2i = SaveCodec.decode(data.get("cell", [0, 0]))
	pig.target_cell = cell
	pig.display_name = str(data.get("name", "猪"))
	var rgb: Vector3i = SaveCodec.decode(data.get("rgb", [255, 170, 190]))
	var tint: Color = SaveCodec.decode(data.get("tint", [1.0, 0.67, 0.75, 1.0]))
	pig.set_identity(rgb, tint)
	pig.set_inventory(SaveCodec.decode_inventory(data.get("inventory", {})))
	var behavior_value: Variant = SaveCodec.decode(data.get("behavior_program", []))
	pig.behavior_program.clear()
	if behavior_value is Array:
		for module in behavior_value:
			if module is Dictionary:
				pig.behavior_program.append(module)
	pig.behavior_running = bool(data.get("behavior_running", false))
	pig.behavior_module_index = int(data.get("behavior_module_index", 0))
	pig.behavior_area_index = int(data.get("behavior_area_index", 0))
	pig.set_selected(false)
	main.pigs.append(pig)
	main._register_pig(pig)
	if bool(data.get("is_stunned", false)):
		pig.stun()


func _clear_runtime() -> void:
	main.hud.unbind_pig()
	main.hud.close_map()
	main.active_pig = null
	main._path_queue.clear()
	main._pending_action.clear()
	main._camera_offset = Vector2.ZERO
	main._camera_pan_pending = false
	main._camera_pan_dragging = false
	main._behavior_pick_mode = 0
	main._behavior_pick_module = -1
	main.behavior_area_overlay.clear()
	main.move_marker.stop()
	main.interaction_range.clear_target()
	for pig_value in main.pigs.duplicate():
		var pig: Pig = pig_value
		if pig == null:
			continue
		main._disconnect_pig_inventory(pig)
		pig.get_parent().remove_child(pig)
		pig.queue_free()
	main.pigs.clear()
	main.farm.plots.clear()
	main.chunk_manager.clear_all()
	var world: WorldObjects = main.world_objects
	world.tree_roots.clear()
	world.logs.clear()
	world.planks.clear()
	world.saplings.clear()
	world.chests.clear()
	world.fences.clear()
	world.nests.clear()
	world.ores.clear()
	world.natural_blocks.clear()
	world._tree_hits.clear()
	world._removed_trees.clear()
	world._removed_ores.clear()
	world._tree_refs.clear()
	world._materialized.clear()
	world.clear_indexes()
	main._visited_blocks.clear()


func _encode_pig(pig: Pig) -> Dictionary:
	var cell: Vector2i = main.grid.world_to_cell(pig.global_position)
	return {
		"name": pig.display_name,
		"position": SaveCodec.encode(pig.global_position),
		"cell": SaveCodec.encode(cell),
		"target_cell": SaveCodec.encode(pig.target_cell),
		"rgb": SaveCodec.encode(pig.pig_rgb),
		"tint": SaveCodec.encode(pig.body_tint),
		"is_stunned": pig.is_stunned,
		"inventory": SaveCodec.encode_inventory(pig.inventory),
		"behavior_program": SaveCodec.encode(pig.behavior_program),
		"behavior_running": pig.behavior_running,
		"behavior_module_index": pig.behavior_module_index,
		"behavior_area_index": pig.behavior_area_index,
	}


func _ensure_folders() -> bool:
	var root := DirAccess.open("user://")
	if root == null:
		return false
	if root.make_dir_recursive("saves/main/blocks") != OK:
		return false
	return true


func _write_json(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true