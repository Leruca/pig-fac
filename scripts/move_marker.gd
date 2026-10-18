class_name MoveMarker
extends Node2D
## 右键落点的短暂标记。点击后显示一圈金色脉冲，随后自动淡出。

const DURATION := 0.72

var _remaining := 0.0


func _ready() -> void:
	z_index = 1
	visible = false


func play(world_position: Vector2) -> void:
	global_position = world_position
	_remaining = DURATION
	visible = true
	queue_redraw()


func stop() -> void:
	_remaining = 0.0
	visible = false


func _process(delta: float) -> void:
	if _remaining <= 0.0:
		return
	_remaining = maxf(0.0, _remaining - delta)
	if _remaining <= 0.0:
		visible = false
	queue_redraw()


func _draw() -> void:
	var progress := 1.0 - (_remaining / DURATION)
	var alpha := clampf(_remaining / DURATION, 0.0, 1.0)
	var radius := lerpf(11.0, 22.0, ease(progress, 0.35))
	var pulse_color := Color(1.0, 0.90, 0.55, alpha)
	var faint_color := Color(1.0, 0.96, 0.76, alpha * 0.45)

	draw_arc(Vector2.ZERO, radius, 0.0, TAU, 36, pulse_color, 2.5, true)
	draw_arc(Vector2.ZERO, radius + 5.0, 0.0, TAU, 36, faint_color, 1.2, true)
	draw_circle(Vector2.ZERO, 2.8, pulse_color)

	var tick_start := radius + 2.0
	var tick_end := radius + 8.0
	for direction in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
		draw_line(direction * tick_start, direction * tick_end, faint_color, 1.5)
