class_name SaveManager
extends RefCounted
## 单存档、按大地图区块拆分的存档系统。
## user://saves/main/global.json
## user://saves/main/blocks/block_x_y.json

const VERSION := 1
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


func save_game() -> Dictionary:
	if main == null:
		return {"ok": false, "message": "游戏尚未初始化。"}
	if not _ensure_folders():
		return {"ok": false, "message": "无法创建存档目录。"}
	_clear_block_files()
	var blocks: Dictionary = {}
	for pig_value in main.pigs:
		var pig: Pig = pig_value
		if pig == null:
			continue
		var pig_cell: Vector2i = main.grid.world_to_cell(pig.global_position)
		var bucket := _bucket(blocks, main.block_of_cell(pig_cell))
		bucket["pigs"].append(_encode_pig(pig))
	var farm: Farm = main.farm
	for cell_value in farm.plots.keys():
		var cell: Vector2i = cell_value
		var plot: Dictionary = farm.plots[cell]
		var bucket := _bucket(blocks, main.block_of_cell(cell))
		bucket["farm"].append({
			"cell": _encode_value(cell),
			"crop_id": str(plot.get("crop_id", "")),
			"stage": int(plot.get("stage", 0)),
			"elapsed": float(plot.get("elapsed", 0.0)),
		})
	var world: WorldObjects = main.world_objects
	for root_value in world.tree_roots:
		var root: Vector2i = root_value
		var bucket := _bucket(blocks, main.block_of_cell(root))
		bucket["trees"].append({
			"root": _encode_value(root),
			"hits": world.get_tree_remaining_hits(root),
		})
	for cell_value in world.logs.keys():
		var cell: Vector2i = cell_value
		_bucket(blocks, main.block_of_cell(cell))["logs"].append(_encode_value(cell))
	for cell_value in world.planks.keys():
		var cell: Vector2i = cell_value
		_bucket(blocks, main.block_of_cell(cell))["planks"].append(_encode_value(cell))
	for cell_value in world.saplings.keys():
		var cell: Vector2i = cell_value
		var data: Dictionary = world.saplings[cell]
		_bucket(blocks, main.block_of_cell(cell))["saplings"].append({
			"cell": _encode_value(cell),
			"stage": int(data.get("stage", 0)),
			"elapsed": float(data.get("elapsed", 0.0)),
		})
	for cell_value in world.chests.keys():
		var cell: Vector2i = cell_value
		var inventory: Inventory = world.chests[cell]
		_bucket(blocks, main.block_of_cell(cell))["chests"].append({
			"cell": _encode_value(cell),
			"inventory": _encode_inventory(inventory),
		})
	for cell_value in world.fences.keys():
		var cell: Vector2i = cell_value
		_bucket(blocks, main.block_of_cell(cell))["fences"].append(_encode_value(cell))
	for root_value in world.nests.keys():
		var root: Vector2i = root_value
		var nest: Dictionary = world.nests[root]
		var inventory: Inventory = nest.get("inventory")
		_bucket(blocks, main.block_of_cell(root))["nests"].append({
			"root": _encode_value(root),
			"inventory": _encode_inventory(inventory),
			"progress": float(nest.get("progress", 0.0)),
			"active": bool(nest.get("active", false)),
		})

	for key in blocks.keys():
		var block_data: Dictionary = blocks[key]
		if not _write_json(
			"%s/%s.json" % [BLOCK_ROOT, str(block_data["key"])],
			block_data
		):
			return {"ok": false, "message": "写入区块存档失败：%s" % str(block_data["key"])}

	var visited: Array = []
	for block_value in main._visited_blocks.keys():
		var block: Vector2i = block_value
		visited.append([block.x, block.y])
	var camera_position: Vector2 = main.camera.global_position
	var global_data := {
		"version": VERSION,
		"camera": _encode_value(camera_position),
		"zoom": float(main._map_zoom),
		"visited_blocks": visited,
		"audio_muted": bool(main.is_audio_muted()),
		"next_born_pig_index": int(main.world_objects._next_born_pig_index),
	}
	if not _write_json(GLOBAL_FILE, global_data):
		return {"ok": false, "message": "写入 global.json 失败。"}
	return {
		"ok": true,
		"message": "已保存 %d 个区块，%d 只猪。" % [blocks.size(), main.pigs.size()],
	}


func load_game() -> Dictionary:
	if main == null:
		return {"ok": false, "message": "游戏尚未初始化。"}
	if not FileAccess.file_exists(GLOBAL_FILE):
		return {"ok": false, "message": "还没有存档。"}
	var global_text := FileAccess.get_file_as_string(GLOBAL_FILE)
	var global_value: Variant = JSON.parse_string(global_text)
	if not (global_value is Dictionary):
		return {"ok": false, "message": "global.json 无法解析。"}
	var global: Dictionary = global_value
	if int(global.get("version", 0)) != VERSION:
		return {"ok": false, "message": "存档版本不匹配。"}

	var block_files: Array[String] = []
	var block_dir := DirAccess.open(BLOCK_ROOT)
	if block_dir == null:
		return {"ok": false, "message": "没有区块存档目录。"}
	for file_name in block_dir.get_files():
		if file_name.ends_with(".json"):
			block_files.append(file_name)
	block_files.sort()

	var block_payloads: Array[Dictionary] = []
	for file_name in block_files:
		var text := FileAccess.get_file_as_string("%s/%s" % [BLOCK_ROOT, file_name])
		var value: Variant = JSON.parse_string(text)
		if not (value is Dictionary):
			return {"ok": false, "message": "区块文件无法解析：%s" % file_name}
		block_payloads.append(value)

	_clear_runtime()
	main.world_objects._next_born_pig_index = int(global.get("next_born_pig_index", 4))

	for block_data in block_payloads:
		_load_block(block_data)

	main._visited_blocks.clear()
	for pair in global.get("visited_blocks", []):
		if pair is Array and pair.size() >= 2:
			main._visited_blocks[Vector2i(int(pair[0]), int(pair[1]))] = true

	var camera_position: Vector2 = _decode_value(global.get("camera", [0.0, 0.0]))
	var zoom := clampf(float(global.get("zoom", 1.0)), 0.1, 4.0)
	main._map_zoom = zoom
	main.camera.zoom = Vector2.ONE * zoom
	main.camera.global_position = camera_position
	main._free_camera_position = camera_position
	main._camera_offset = Vector2.ZERO
	main._last_pig_cell = Vector2i(2147483647, 2147483647)
	main._mark_visible_blocks()
	main.apply_audio_muted(bool(global.get("audio_muted", false)))
	main.hud.set_map_zoom(zoom)
	main.hud.set_hint("存档已读取：%d 个区块，%d 只猪。" % [block_payloads.size(), main.pigs.size()])
	main.farm.queue_redraw()
	main.world_objects.queue_redraw()
	return {
		"ok": true,
		"message": "读取成功：%d 个区块，%d 只猪。" % [block_payloads.size(), main.pigs.size()],
	}


func _load_block(block_data: Dictionary) -> void:
	var world: WorldObjects = main.world_objects
	var farm: Farm = main.farm
	for plot_value in block_data.get("farm", []):
		if not (plot_value is Dictionary):
			continue
		var plot: Dictionary = plot_value
		var cell: Vector2i = _decode_value(plot.get("cell", [0, 0]))
		farm.plots[cell] = {
			"crop_id": str(plot.get("crop_id", "")),
			"stage": int(plot.get("stage", 0)),
			"elapsed": float(plot.get("elapsed", 0.0)),
		}
	for tree_value in block_data.get("trees", []):
		if not (tree_value is Dictionary):
			continue
		var tree: Dictionary = tree_value
		var root: Vector2i = _decode_value(tree.get("root", [0, 0]))
		world.add_tree(root)
		world._tree_hits[root] = int(tree.get("hits", 3))
	for cell_value in block_data.get("logs", []):
		world.logs[_decode_value(cell_value)] = true
	for cell_value in block_data.get("planks", []):
		world.planks[_decode_value(cell_value)] = true
	for cell_value in block_data.get("fences", []):
		world.fences[_decode_value(cell_value)] = true
	for sapling_value in block_data.get("saplings", []):
		if not (sapling_value is Dictionary):
			continue
		var sapling: Dictionary = sapling_value
		var cell: Vector2i = _decode_value(sapling.get("cell", [0, 0]))
		world.saplings[cell] = {
			"stage": int(sapling.get("stage", 0)),
			"elapsed": float(sapling.get("elapsed", 0.0)),
		}
	for chest_value in block_data.get("chests", []):
		if not (chest_value is Dictionary):
			continue
		var chest: Dictionary = chest_value
		var cell: Vector2i = _decode_value(chest.get("cell", [0, 0]))
		world.chests[cell] = _decode_inventory(chest.get("inventory", {}))
	for nest_value in block_data.get("nests", []):
		if not (nest_value is Dictionary):
			continue
		var nest: Dictionary = nest_value
		var root: Vector2i = _decode_value(nest.get("root", [0, 0]))
		world.nests[root] = {
			"inventory": _decode_inventory(nest.get("inventory", {}), 4),
			"progress": float(nest.get("progress", 0.0)),
			"active": bool(nest.get("active", false)),
		}
	for pig_value in block_data.get("pigs", []):
		if pig_value is Dictionary:
			_load_pig(pig_value)


func _load_pig(data: Dictionary) -> void:
	var pig: Pig = PIG_SCENE.instantiate()
	pig.name = "LoadedPig%d" % (main.pigs.size() + 1)
	main.add_child(pig)
	var position: Vector2 = _decode_value(data.get("position", [0.0, 0.0]))
	pig.global_position = position
	var cell: Vector2i = _decode_value(data.get("cell", [0, 0]))
	pig.target_cell = cell
	pig.display_name = str(data.get("name", "猪"))
	var rgb: Vector3i = _decode_value(data.get("rgb", [255, 170, 190]))
	var tint: Color = _decode_value(data.get("tint", [1.0, 0.67, 0.75, 1.0]))
	pig.set_identity(rgb, tint)
	pig.set_inventory(_decode_inventory(data.get("inventory", {})))
	var behavior_value: Variant = _decode_value(data.get("behavior_program", []))
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
	var world: WorldObjects = main.world_objects
	world.tree_roots.clear()
	world.logs.clear()
	world.planks.clear()
	world.saplings.clear()
	world.chests.clear()
	world.fences.clear()
	world.nests.clear()
	world._tree_hits.clear()
	main._visited_blocks.clear()


func _encode_pig(pig: Pig) -> Dictionary:
	var cell: Vector2i = main.grid.world_to_cell(pig.global_position)
	return {
		"name": pig.display_name,
		"position": _encode_value(pig.global_position),
		"cell": _encode_value(cell),
		"target_cell": _encode_value(pig.target_cell),
		"rgb": _encode_value(pig.pig_rgb),
		"tint": _encode_value(pig.body_tint),
		"is_stunned": pig.is_stunned,
		"inventory": _encode_inventory(pig.inventory),
		"behavior_program": _encode_value(pig.behavior_program),
		"behavior_running": pig.behavior_running,
		"behavior_module_index": pig.behavior_module_index,
		"behavior_area_index": pig.behavior_area_index,
	}


func _bucket(blocks: Dictionary, block: Vector2i) -> Dictionary:
	var key := "%d_%d" % [block.x, block.y]
	if not blocks.has(key):
		blocks[key] = {
			"key": key,
			"block": [block.x, block.y],
			"pigs": [],
			"farm": [],
			"trees": [],
			"logs": [],
			"planks": [],
			"saplings": [],
			"chests": [],
			"fences": [],
			"nests": [],
		}
	return blocks[key]


func _encode_value(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2:
			return {"$vec2": [value.x, value.y]}
		TYPE_VECTOR2I:
			return {"$vec2i": [value.x, value.y]}
		TYPE_VECTOR3I:
			return {"$vec3i": [value.x, value.y, value.z]}
		TYPE_RECT2I:
			return {"$rect2i": [value.position.x, value.position.y, value.size.x, value.size.y]}
		TYPE_COLOR:
			return {"$color": [value.r, value.g, value.b, value.a]}
		TYPE_DICTIONARY:
			var out := {}
			for key in value.keys():
				out[str(key)] = _encode_value(value[key])
			return out
		TYPE_ARRAY:
			var out_array := []
			for item in value:
				out_array.append(_encode_value(item))
			return out_array
		_:
			return value


func _decode_value(value: Variant) -> Variant:
	if value is Dictionary:
		if value.has("$vec2"):
			var pair: Array = value["$vec2"]
			return Vector2(float(pair[0]), float(pair[1]))
		if value.has("$vec2i"):
			var pair: Array = value["$vec2i"]
			return Vector2i(int(pair[0]), int(pair[1]))
		if value.has("$vec3i"):
			var triple: Array = value["$vec3i"]
			return Vector3i(int(triple[0]), int(triple[1]), int(triple[2]))
		if value.has("$rect2i"):
			var rect: Array = value["$rect2i"]
			return Rect2i(int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3]))
		if value.has("$color"):
			var rgba: Array = value["$color"]
			return Color(float(rgba[0]), float(rgba[1]), float(rgba[2]), float(rgba[3]))
		var out := {}
		for key in value.keys():
			out[key] = _decode_value(value[key])
		return out
	if value is Array:
		var out_array := []
		for item in value:
			out_array.append(_decode_value(item))
		return out_array
	return value


func _encode_inventory(inventory: Inventory) -> Dictionary:
	if inventory == null:
		return {"slot_count": 40, "slots": []}
	var slots: Array = []
	for index in inventory.slot_count:
		var slot := inventory.get_slot(index)
		if slot.is_empty():
			slots.append({})
			continue
		var encoded := {}
		for key in slot.keys():
			var value: Variant = slot[key]
			if value is Inventory:
				encoded[key] = _encode_inventory(value)
			else:
				encoded[key] = _encode_value(value)
		slots.append(encoded)
	return {"slot_count": inventory.slot_count, "slots": slots}


func _decode_inventory(value: Variant, default_slots: int = 40) -> Inventory:
	var data: Dictionary = value if value is Dictionary else {}
	var slot_count := int(data.get("slot_count", default_slots))
	var inventory := Inventory.new(slot_count)
	var slots: Array = data.get("slots", [])
	for index in mini(slots.size(), inventory.slot_count):
		var source: Variant = slots[index]
		if not (source is Dictionary) or source.is_empty():
			continue
		var decoded := {}
		for key in source.keys():
			var item: Variant = source[key]
			if str(key) == "pig_inventory" and item is Dictionary:
				decoded[key] = _decode_inventory(item)
			else:
				decoded[key] = _decode_value(item)
		inventory.slots[index] = decoded
	return inventory


func _ensure_folders() -> bool:
	var root := DirAccess.open("user://")
	if root == null:
		return false
	if root.make_dir_recursive("saves/main/blocks") != OK:
		return false
	return true


func _clear_block_files() -> void:
	var dir := DirAccess.open(BLOCK_ROOT)
	if dir == null:
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".json"):
			dir.remove(file_name)


func _write_json(path: String, data: Dictionary) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true
