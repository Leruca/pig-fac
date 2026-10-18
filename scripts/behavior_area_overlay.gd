class_name BehaviorAreaOverlay
extends Node2D
## 行为模块“区域使用工具”的框选预览。

var _active := false
var _start := Vector2i.ZERO
var _end := Vector2i.ZERO


func _ready() -> void:
	z_index = 6
	visible = true


func show_selection(start_cell: Vector2i, end_cell: Vector2i) -> void:
	_active = true
	_start = start_cell
	_end = end_cell
	queue_redraw()


func clear() -> void:
	_active = false
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	var min_cell := Vector2i(mini(_start.x, _end.x), mini(_start.y, _end.y))
	var max_cell := Vector2i(maxi(_start.x, _end.x), maxi(_start.y, _end.y))
	var cell_size := 36.0
	var rect := Rect2(
		Vector2(min_cell) * cell_size,
		Vector2(max_cell - min_cell + Vector2i.ONE) * cell_size
	)
	draw_rect(rect, Color(0.55, 0.95, 0.42, 0.16), true)
	draw_rect(rect, Color(0.76, 1.0, 0.55, 0.95), false, 2.2)
	var columns := max_cell.x - min_cell.x + 1
	var rows := max_cell.y - min_cell.y + 1
	for x in range(1, columns):
		var px := rect.position.x + float(x) * cell_size
		draw_line(
			Vector2(px, rect.position.y),
			Vector2(px, rect.end.y),
			Color(0.76, 1.0, 0.55, 0.35),
			1.0
		)
	for y in range(1, rows):
		var py := rect.position.y + float(y) * cell_size
		draw_line(
			Vector2(rect.position.x, py),
			Vector2(rect.end.x, py),
			Color(0.76, 1.0, 0.55, 0.35),
			1.0
		)
