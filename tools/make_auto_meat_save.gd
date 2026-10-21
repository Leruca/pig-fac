extends Node
## 生成"自动鲜肉产线"演示存档到 user://saves/slots/auto_meat。
## 运行：
##   godot --headless --path . res://tools/make_auto_meat_save.tscn

var _main: Node
var _occupied: Array[Rect2i] = []


func _ready() -> void:
	OS.unset_environment("PIGFAC_TEST_SAVE_ROOT")
	OS.set_environment("PIGFAC_SEED", "auto-meat-line")
	var previous := SavePaths.current_slot()
	var slot := "auto_meat"
	if not SavePaths.set_current_slot(slot):
		push_error("cannot select save slot")
		get_tree().quit(1)
		return
	SavePaths.clear_root()
	if not SavePaths.ensure_dirs():
		push_error("cannot create save slot")
		get_tree().quit(1)
		return
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	await get_tree().process_frame
	await get_tree().process_frame
	for _index in 30:
		await get_tree().process_frame
	_build_line()
	var result: Dictionary = _main._save_manager.save_game()
	print("AUTO SAVE: ", result.get("message", ""))
	print("AUTO SAVE ROOT: ", SavePaths.root())
	SavePaths.set_current_slot(previous)
	get_tree().quit(0 if bool(result.get("ok", false)) else 1)


func _free_area(anchor: Vector2i, size: int) -> Vector2i:
	for radius in 60:
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				var root := anchor + Vector2i(x, y)
				if _area_free(root, size):
					return root
	return WorldObjects.INVALID_CELL


func _area_free(root: Vector2i, size: int) -> bool:
	var rect := Rect2i(root, Vector2i(size, size))
	for occupied in _occupied:
		if occupied.intersects(rect):
			return false
	for y in size:
		for x in size:
			var cell := root + Vector2i(x, y)
			if _main.world_objects.is_blocked(cell):
				return false
			if _main.farm.is_tilled(cell):
				return false
			for pig in _main.pigs:
				if _main.grid.world_to_cell(pig.global_position) == cell:
					return false
	_occupied.append(rect)
	return true


func _pig_item(name_value: String, rgb: Vector3i) -> Dictionary:
	return {
		"item_id": "pig",
		"count": 1,
		"pig_name": name_value,
		"pig_rgb": rgb,
		"pig_tint": Color(rgb.x / 255.0, rgb.y / 255.0, rgb.z / 255.0).lerp(Color.WHITE, 0.35),
		"pig_inventory": Inventory.new(Inventory.DEFAULT_SLOT_COUNT),
	}


func _build_line() -> void:
	var world: WorldObjects = _main.world_objects
	var base: Vector2i = _main.grid.world_to_cell(_main.camera.global_position)
	var pair_root := _free_area(base + Vector2i(2, -3), 6)
	var generator_root := pair_root
	var meat_root := pair_root + Vector2i(3, 0)
	var nest_root := _free_area(base + Vector2i(-5, 0), 3)
	var food_chest := _free_area(base + Vector2i(-9, 0), 1)
	var meat_chest := _free_area(base + Vector2i(14, 2), 1)
	if (
		pair_root == WorldObjects.INVALID_CELL
		or nest_root == WorldObjects.INVALID_CELL
		or food_chest == WorldObjects.INVALID_CELL
		or meat_chest == WorldObjects.INVALID_CELL
	):
		push_error("not enough free space for demo line")
		return
	var generator: Dictionary = world.place_machine(generator_root, "pig_generator")
	var meat: Dictionary = world.place_machine(meat_root + Vector2i(1, 1), "meat_storage")
	world.place_nest(nest_root)
	world.place_chest(food_chest)
	world.place_chest(meat_chest)
	if generator.is_empty() or meat.is_empty():
		push_error("machines failed to place")
		return
	generator["pig"] = _pig_item("发电机猪", Vector3i(248, 164, 188))
	generator["power"] = 100.0
	meat["pig"] = _pig_item("肉肉仓猪", Vector3i(232, 190, 170))

	var nest: Dictionary = world.get_nest(nest_root)
	var nest_inventory: Inventory = nest.get("inventory")
	nest_inventory.slots[0] = _pig_item("父本", Vector3i(240, 140, 150))
	nest_inventory.slots[1] = _pig_item("母本", Vector3i(210, 160, 220))
	nest_inventory.slots[2] = {"item_id": "potato", "count": 64}
	nest_inventory.changed.emit()

	var food_inventory: Inventory = world.get_chest(food_chest)
	for index in food_inventory.slot_count:
		food_inventory.slots[index] = {"item_id": "potato", "count": 64}
	food_inventory.changed.emit()

	if _main.pigs.size() >= 2:
		var meat_worker: Pig = _main.pigs[0]
		meat_worker.behavior_program = [
			{"type": "take", "container_cell": nest_root, "item_id": "pig"},
			{"type": "machine", "machine_cell": meat_root},
			{"type": "store", "container_cell": meat_chest, "item_id": "fresh_meat"},
		]
		meat_worker.behavior_module_index = 0
		meat_worker.behavior_running = true

		var food_worker: Pig = _main.pigs[1]
		food_worker.behavior_program = [
			{"type": "take", "container_cell": food_chest, "item_id": "potato"},
			{"type": "store", "container_cell": nest_root, "item_id": "potato"},
		]
		food_worker.behavior_module_index = 0
		food_worker.behavior_running = true

	for cell in [generator_root, meat_root, nest_root, food_chest, meat_chest]:
		world.mark_dirty(cell)
	world.queue_redraw()
