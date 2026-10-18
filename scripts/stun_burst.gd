class_name StunBurst
extends CPUParticles2D
## 锤子敲晕猪时迸出的星形打击特效。


func _ready() -> void:
	z_index = 8
	texture = load("res://assets/star.svg") as Texture2D
	amount = 14
	lifetime = 0.7
	one_shot = true
	explosiveness = 1.0
	randomness = 0.45
	emitting = false
	local_coords = false
	direction = Vector2(0.0, -1.0)
	spread = 180.0
	initial_velocity_min = 45.0
	initial_velocity_max = 120.0
	gravity = Vector2(0.0, 90.0)
	scale_amount_min = 0.5
	scale_amount_max = 1.1
	angular_velocity_min = -360.0
	angular_velocity_max = 360.0


func burst(world_position: Vector2) -> void:
	global_position = world_position + Vector2(0.0, -16.0)
	emitting = true
	restart()
