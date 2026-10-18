class_name InteractionRange
extends Node2D
## 选中猪时绘制 7 × 7 的互动范围框（切比雪夫距离 ≤ 3）。
##
## 只影响农耕操作，不限制移动；范围以猪当前所在格子为中心。

const RANGE := 3

@export var cell_size: int = 36

var _target: Node2D
var _active := false


func _ready() -> void:
	z_index = -5
	visible = false


func follow(target: Node2D) -> void:
	_target = target
	_active = is_instance_valid(target)
	visible = _active
	queue_redraw()


func clear_target() -> void:
	_target = null
	_active = false
	visible = false


func _process(_delta: float) -> void:
	if not _active:
		return
	if not is_instance_valid(_target):
		clear_target()
		return
	queue_redraw()


func _draw() -> void:
	if not _active or not is_instance_valid(_target):
		return

	var center := Vector2i(
		floori(_target.global_position.x / float(cell_size)),
		floori(_target.global_position.y / float(cell_size))
	)
	var top_left := Vector2(center - Vector2i(RANGE, RANGE)) * float(cell_size)
	var bottom_right := Vector2(center + Vector2i(RANGE + 1, RANGE + 1)) * float(cell_size)
	var rect := Rect2(top_left, bottom_right - top_left)
	var border := Color(1.0, 0.90, 0.55, 0.52)

	draw_rect(rect, Color(1.0, 0.92, 0.55, 0.028), true)
	draw_dashed_line(rect.position, Vector2(rect.end.x, rect.position.y), border, 2.0, 8.0)
	draw_dashed_line(Vector2(rect.position.x, rect.end.y), rect.end, border, 2.0, 8.0)
	draw_dashed_line(rect.position, Vector2(rect.position.x, rect.end.y), border, 2.0, 8.0)
	draw_dashed_line(Vector2(rect.end.x, rect.position.y), rect.end, border, 2.0, 8.0)

	# 四个角加深一点，方便在草地上看出范围。
	var corner := 13.0
	var corner_color := Color(1.0, 0.88, 0.50, 0.86)
	draw_line(rect.position, rect.position + Vector2(corner, 0.0), corner_color, 2.5)
	draw_line(rect.position, rect.position + Vector2(0.0, corner), corner_color, 2.5)
	draw_line(
		Vector2(rect.end.x, rect.position.y),
		Vector2(rect.end.x - corner, rect.position.y),
		corner_color,
		2.5
	)
	draw_line(
		Vector2(rect.end.x, rect.position.y),
		Vector2(rect.end.x, rect.position.y + corner),
		corner_color,
		2.5
	)
	draw_line(
		Vector2(rect.position.x, rect.end.y),
		Vector2(rect.position.x + corner, rect.end.y),
		corner_color,
		2.5
	)
	draw_line(
		Vector2(rect.position.x, rect.end.y),
		Vector2(rect.position.x, rect.end.y - corner),
		corner_color,
		2.5
	)
	draw_line(rect.end - Vector2(corner, 0.0), rect.end, corner_color, 2.5)
	draw_line(rect.end - Vector2(0.0, corner), rect.end, corner_color, 2.5)
