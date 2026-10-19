class_name Farm
extends Node2D
## 耕地与作物层。
##
## 每个格子最多有一个地块（plot）。地块先被锄头锄成耕地，然后可以种下作物。
## 作物按 30 秒一个阶段生长，90 秒达到成熟阶段（stage 3）。

signal plot_changed(cell: Vector2i)
## 玩家操作导致的阶段变化（浇水催熟）→ 需要落盘。
signal crop_stage_changed(cell: Vector2i, crop_id: String, stage: int)
## 自然生长导致的阶段变化 → **不**落盘（§5.3 计时豁免，否则每块每 30 秒都脏）。
signal crop_grew(cell: Vector2i, crop_id: String, stage: int)

const SOIL_DARK := Color("#5D412C")
const SOIL := Color("#7B5538")
const SOIL_LIGHT := Color("#966A46")
const SOIL_BORDER := Color("#4A321F")
const FURROW := Color(0.36, 0.23, 0.14, 0.55)

const STEM := Color("#2F612A")
const POTATO_LEAF := Color("#357A31")
const POTATO_LEAF_LIGHT := Color("#68B84B")
const CARROT_LEAF := Color("#3D7E2C")
const CARROT_LEAF_LIGHT := Color("#8AC64C")
const FLOWER := Color("#FFF4D5")
const FLOWER_CENTER := Color("#E5B84C")
const POTATO_SKIN := Color("#D19654")
const CARROT_ROOT := Color("#F08A36")
const SPARKLE := Color("#FFE18A")

@export var cell_size: int = 36

## cell(Vector2i) -> { "crop_id": String, "stage": int, "elapsed": float }
var plots: Dictionary = {}


func _process(delta: float) -> void:
	advance_growth(delta)


func _refresh() -> void:
	if is_inside_tree():
		queue_redraw()


func till(cell: Vector2i) -> bool:
	if plots.has(cell):
		return false
	plots[cell] = {"crop_id": "", "stage": 0, "elapsed": 0.0}
	_refresh()
	plot_changed.emit(cell)
	return true


func plant(cell: Vector2i, crop_id: String) -> bool:
	if not ItemDB.is_crop(crop_id) or not plots.has(cell):
		return false
	var plot: Dictionary = plots[cell]
	if not str(plot.get("crop_id", "")).is_empty():
		return false
	plot["crop_id"] = crop_id
	plot["stage"] = 0
	plot["elapsed"] = 0.0
	_refresh()
	plot_changed.emit(cell)
	return true


## 铲子：把没有作物的耕地恢复成普通草地。
func flatten(cell: Vector2i) -> bool:
	if not plots.has(cell) or has_crop(cell):
		return false
	plots.erase(cell)
	_refresh()
	plot_changed.emit(cell)
	return true


## 超级水壶：将作物直接推进一个生长阶段。
func water(cell: Vector2i) -> bool:
	if not has_crop(cell):
		return false
	var plot: Dictionary = plots[cell]
	var crop_id := str(plot.get("crop_id", ""))
	var stage := int(plot.get("stage", 0))
	var mature_stage := ItemDB.get_mature_stage(crop_id)
	if stage >= mature_stage:
		return false
	stage += 1
	plot["stage"] = stage
	plot["elapsed"] = 0.0
	_refresh()
	crop_stage_changed.emit(cell, crop_id, stage)
	return true


## 空手收割。max_amount 用于避免背包已满时凭空吞掉产量。
## 返回 {} 表示不可收割；成功时返回 {"crop_id": String, "amount": int}。
func harvest(cell: Vector2i, max_amount: int = 999) -> Dictionary:
	if not is_mature(cell) or max_amount <= 0:
		return {}

	var plot: Dictionary = plots[cell]
	var crop_id := str(plot.get("crop_id", ""))
	var yield_range := ItemDB.get_yield_range(crop_id)
	var amount := randi_range(yield_range.x, yield_range.y)
	amount = mini(amount, max_amount)
	if amount <= 0:
		return {}

	plot["crop_id"] = ""
	plot["stage"] = 0
	plot["elapsed"] = 0.0
	_refresh()
	plot_changed.emit(cell)
	return {"crop_id": crop_id, "amount": amount}


## 自然生长推进；拆出来便于测试时直接快进时间。
func advance_growth(seconds: float) -> void:
	if seconds <= 0.0:
		return

	for cell in plots.keys():
		var plot: Dictionary = plots[cell]
		var crop_id := str(plot.get("crop_id", ""))
		if crop_id.is_empty():
			continue

		var stage := int(plot.get("stage", 0))
		var mature_stage := ItemDB.get_mature_stage(crop_id)
		if stage >= mature_stage:
			continue

		var stage_seconds := ItemDB.get_growth_stage_seconds(crop_id)
		var elapsed := float(plot.get("elapsed", 0.0)) + seconds
		var advanced := false
		while elapsed >= stage_seconds and stage < mature_stage:
			elapsed -= stage_seconds
			stage += 1
			advanced = true

		plot["elapsed"] = elapsed
		plot["stage"] = stage
		if advanced:
			_refresh()
			crop_grew.emit(cell, crop_id, stage)


func is_tilled(cell: Vector2i) -> bool:
	return plots.has(cell)


func has_crop(cell: Vector2i) -> bool:
	if not plots.has(cell):
		return false
	return not str(plots[cell].get("crop_id", "")).is_empty()


func get_crop_id(cell: Vector2i) -> String:
	if not plots.has(cell):
		return ""
	return str(plots[cell].get("crop_id", ""))


func get_crop_stage(cell: Vector2i) -> int:
	if not has_crop(cell):
		return -1
	return int(plots[cell].get("stage", 0))


func is_mature(cell: Vector2i) -> bool:
	if not has_crop(cell):
		return false
	var crop_id := get_crop_id(cell)
	return get_crop_stage(cell) >= ItemDB.get_mature_stage(crop_id)


func get_seconds_to_next_stage(cell: Vector2i) -> float:
	if not has_crop(cell) or is_mature(cell):
		return 0.0
	var crop_id := get_crop_id(cell)
	var stage_seconds := ItemDB.get_growth_stage_seconds(crop_id)
	var elapsed := float(plots[cell].get("elapsed", 0.0))
	return maxf(0.0, stage_seconds - elapsed)


func get_seconds_to_mature(cell: Vector2i) -> float:
	if not has_crop(cell) or is_mature(cell):
		return 0.0
	var crop_id := get_crop_id(cell)
	var stage_seconds := ItemDB.get_growth_stage_seconds(crop_id)
	var mature_stage := ItemDB.get_mature_stage(crop_id)
	var stages_left := mature_stage - get_crop_stage(cell)
	var elapsed := float(plots[cell].get("elapsed", 0.0))
	return maxf(0.0, float(stages_left) * stage_seconds - elapsed)


func _draw() -> void:
	for cell in plots.keys():
		_draw_soil(cell)
		if has_crop(cell):
			_draw_crop(cell, plots[cell])


func _draw_soil(cell: Vector2i) -> void:
	var origin := Vector2(cell) * float(cell_size)
	var soil_rect := Rect2(origin + Vector2(2.5, 2.5), Vector2.ONE * (float(cell_size) - 5.0))
	draw_rect(soil_rect, SOIL_DARK, true)
	draw_rect(soil_rect.grow(-2.0), SOIL, true)
	draw_rect(soil_rect, SOIL_BORDER, false, 1.2)

	var furrow_start := origin.x + 7.0
	var furrow_end := origin.x + float(cell_size) - 7.0
	for index in 3:
		var y := origin.y + 10.0 + float(index) * 7.0
		draw_line(Vector2(furrow_start, y), Vector2(furrow_end, y), FURROW, 1.1)

	draw_line(
		Vector2(origin.x + 6.0, origin.y + 6.0),
		Vector2(origin.x + 12.0, origin.y + 6.0),
		SOIL_LIGHT,
		1.3
	)
	draw_circle(Vector2(origin.x + float(cell_size) - 8.0, origin.y + 8.0), 1.2, SOIL_LIGHT)


func _draw_crop(cell: Vector2i, plot: Dictionary) -> void:
	var crop_id := str(plot.get("crop_id", ""))
	var stage := int(plot.get("stage", 0))
	var mature_stage := ItemDB.get_mature_stage(crop_id)
	var center := Vector2(cell) * float(cell_size) + Vector2.ONE * (float(cell_size) * 0.5)
	var base := center + Vector2(0.0, 12.0)

	if crop_id == "potato":
		_draw_potato(base, stage)
	else:
		_draw_carrot(base, stage)

	_draw_stage_pips(cell, stage, mature_stage)

	if stage >= mature_stage:
		_draw_sparkle(center + Vector2(13.0, -13.0), 4.2, SPARKLE)
		_draw_sparkle(center + Vector2(-13.0, -7.0), 2.8, Color(1.0, 0.93, 0.66, 0.9))


func _draw_potato(base: Vector2, stage: int) -> void:
	var leaf_count := 2 + stage * 2
	var leaf_length := 8.0 + float(stage) * 3.8
	var stem_height := 5.0 + float(stage) * 4.2
	var stem_top := base + Vector2(0.0, -stem_height)
	draw_line(base, stem_top, STEM, 1.8)
	_draw_mound(base)

	var spread := 1.9
	for index in leaf_count:
		var ratio := 0.0 if leaf_count <= 1 else float(index) / float(leaf_count - 1)
		var angle := -PI * 0.5 + lerpf(-spread, spread, ratio)
		var origin := base + Vector2(0.0, -4.0 - float(stage) * 2.2)
		var color := POTATO_LEAF if index % 2 == 0 else POTATO_LEAF_LIGHT
		_draw_leaf(origin, angle, leaf_length, 2.0 + float(stage) * 0.72, color)

	if stage >= 2:
		for flower_offset in [Vector2(-6.0, -15.0), Vector2(5.5, -18.0)]:
			_draw_flower(stem_top + flower_offset)

	if stage >= 3:
		_draw_tuber(base + Vector2(-9.0, 4.0), 5.4)
		_draw_tuber(base + Vector2(9.0, 5.0), 4.7)


func _draw_carrot(base: Vector2, stage: int) -> void:
	var leaf_count := 4 + stage * 2
	var leaf_length := 9.0 + float(stage) * 4.0
	_draw_mound(base)

	var spread := 1.42
	for index in leaf_count:
		var ratio := 0.0 if leaf_count <= 1 else float(index) / float(leaf_count - 1)
		var angle := -PI * 0.5 + lerpf(-spread, spread, ratio)
		var origin := base + Vector2(0.0, -2.0)
		var color := CARROT_LEAF if index % 2 == 0 else CARROT_LEAF_LIGHT
		_draw_leaf(origin, angle, leaf_length, 1.8 + float(stage) * 0.36, color)

	if stage >= 3:
		# 成熟的胡萝卜把橙色肩膀顶出土面。
		draw_set_transform(base + Vector2(0.0, 4.0), 0.0, Vector2(1.0, 0.55))
		draw_circle(Vector2.ZERO, 6.8, CARROT_ROOT)
		draw_circle(Vector2(-1.6, -1.0), 2.2, Color("#FFC06E"))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		draw_circle(Vector2(0.0, 0.5), 1.8, Color("#B85D23"))


func _draw_mound(base: Vector2) -> void:
	draw_set_transform(base + Vector2(0.0, 1.0), 0.0, Vector2(1.0, 0.42))
	draw_circle(Vector2.ZERO, 6.0, Color(0.31, 0.20, 0.12, 0.65))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_stage_pips(cell: Vector2i, stage: int, mature_stage: int) -> void:
	var origin := Vector2(cell) * float(cell_size)
	var start := origin + Vector2(float(cell_size) * 0.5 - 5.0, 5.0)
	for index in mature_stage:
		var filled := index < stage
		var color := Color("#D7EE9D") if filled else Color(0.26, 0.17, 0.10, 0.55)
		draw_circle(start + Vector2(float(index) * 5.0, 0.0), 1.6, color)



func _draw_leaf(origin: Vector2, angle: float, length: float, width: float, color: Color) -> void:
	var direction := Vector2(cos(angle), sin(angle))
	var perpendicular := Vector2(-direction.y, direction.x)
	var points := PackedVector2Array([
		origin,
		origin + direction * length * 0.42 + perpendicular * width,
		origin + direction * length,
		origin + direction * length * 0.42 - perpendicular * width,
	])
	draw_colored_polygon(points, color)
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, color.darkened(0.34), 0.85)
	draw_line(origin, origin + direction * length, color.darkened(0.22), 0.7)


func _draw_flower(position: Vector2) -> void:
	draw_circle(position, 3.1, FLOWER)
	draw_circle(position + Vector2(0.0, -0.4), 1.1, FLOWER_CENTER)


func _draw_tuber(position: Vector2, radius: float) -> void:
	draw_set_transform(position, -0.18, Vector2(1.0, 0.62))
	draw_circle(Vector2.ZERO, radius, POTATO_SKIN)
	draw_circle(Vector2(-1.0, -1.0), radius * 0.35, Color("#E2AF76"))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_sparkle(position: Vector2, size: float, color: Color) -> void:
	draw_line(position + Vector2(-size, 0.0), position + Vector2(size, 0.0), color, 1.2)
	draw_line(position + Vector2(0.0, -size), position + Vector2(0.0, size), color, 1.2)
	draw_circle(position, 1.1, color)
