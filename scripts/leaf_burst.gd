class_name LeafBurst
extends CPUParticles2D
## 砍树时在树冠位置喷出的一小把落叶。

var _leaf_texture: Texture2D


func _ready() -> void:
	z_index = 5
	_leaf_texture = load("res://assets/leaf.svg") as Texture2D
	texture = _leaf_texture
	amount = 20
	lifetime = 1.05
	one_shot = true
	explosiveness = 0.9
	randomness = 0.6
	emitting = false
	local_coords = false
	direction = Vector2(0.0, -1.0)
	spread = 80.0
	initial_velocity_min = 35.0
	initial_velocity_max = 95.0
	gravity = Vector2(0.0, 155.0)
	scale_amount_min = 0.55
	scale_amount_max = 1.15
	angular_velocity_min = -220.0
	angular_velocity_max = 220.0
	color = Color(0.85, 0.95, 0.62, 1.0)


func burst(world_position: Vector2) -> void:
	global_position = world_position
	emitting = true
	restart()
