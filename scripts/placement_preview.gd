class_name PlacementPreview
extends Node2D
## 手持可放置物时的 footprint 预览：绿色可放，红色不可放。
## 2×2 以鼠标格为左上角；3×3（猪窝/装配台/肉肉仓）以鼠标格为中心。

var game: Node
var _last_hint := ""


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var state := _state()
	if state.is_empty():
		return
	var root: Vector2i = state["root"]
	var size: int = state["size"]
	var cell_size := float(game.grid.cell_size)
	var valid: bool = state["valid"]
	var fill := Color(0.30, 0.78, 0.36, 0.20) if valid else Color(0.90, 0.28, 0.24, 0.20)
	var border := Color(0.55, 0.96, 0.55, 0.95) if valid else Color(1.0, 0.45, 0.38, 0.95)
	for y in size:
		for x in size:
			var rect := Rect2(
				Vector2(root + Vector2i(x, y)) * cell_size,
				Vector2.ONE * cell_size
			)
			draw_rect(rect, fill, true)
			draw_rect(rect.grow(-1.0), border, false, 1.6)
	# 中心/左上锚点标记，帮助理解 3×3 中心与 2×2 左上角。
	var anchor_cell := root
	if size >= 3:
		var half := floori(float(size) * 0.5)
		anchor_cell = root + Vector2i(half, half)
	draw_circle(
		(Vector2(anchor_cell) + Vector2.ONE * 0.5) * cell_size,
		4.0,
		Color(1.0, 0.92, 0.45, 0.95)
	)


func hint_text() -> String:
	var state := _state()
	if state.is_empty():
		return ""
	var size: int = state["size"]
	var valid: bool = state["valid"]
	var name := str(state["name"])
	var anchor := "鼠标格为中心" if size >= 3 else "鼠标格为左上角"
	if valid:
		return "放置 %d×%d %s：%s；绿色区域可放，右键确认。" % [size, size, name, anchor]
	return "放置 %d×%d %s：%s；红色区域有阻挡，换个位置。" % [size, size, name, anchor]


func _state() -> Dictionary:
	if game == null or game.active_pig == null:
		return {}
	var item_id: String = game.active_pig.inventory.get_held_item_id()
	if item_id.is_empty():
		return {}
	var size := 1
	var display_name := ItemDB.get_display_name(item_id)
	if item_id == "furnace":
		size = WorldObjects.FURNACE_SIZE
	elif item_id == "pig_nest":
		size = WorldObjects.NEST_SIZE
	elif ItemDB.get_kind(item_id) == "machine":
		size = int(WorldObjects.MACHINE_SIZES.get(
			str(ItemDB.get_item(item_id).get("machine_type", "")), 1
		))
	elif item_id not in ["stone", "stone_brick", "chest", "fence", "wood", "planks", "sapling", "pig"]:
		return {}
	var mouse_cell: Vector2i = game.grid.world_to_cell(game.get_global_mouse_position())
	var root := mouse_cell
	if size >= 3:
		var half := floori(float(size) * 0.5)
		root -= Vector2i(half, half)
	var valid := true
	for y in size:
		for x in size:
			var cell := root + Vector2i(x, y)
			if game.world_objects.is_blocked(cell) or game.farm.is_tilled(cell):
				valid = false
			for pig in game.pigs:
				if game.grid.world_to_cell(pig.global_position) == cell:
					valid = false
	return {
		"root": root,
		"size": size,
		"valid": valid,
		"name": display_name,
	}
