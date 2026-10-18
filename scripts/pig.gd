class_name Pig
extends Node2D
## 主角猪：负责选中状态、平滑移动与脚下反馈。
##
## 移动暂时是直线趋近格子中心，不包含碰撞/寻路；后续可以在 move_to_cell()
## 中接入 AStar2D 或 NavigationAgent2D，而不需要改动输入与 UI。

signal selected_changed(is_selected: bool)
signal move_started(target_cell: Vector2i)
signal arrived(cell: Vector2i)

@export var move_speed := 330.0
@export var hit_radius := 30.0
@export var display_name := "猪 1"
@export var body_tint := Color.WHITE
## 繁育用的 RGB 值（0-255）。仅作为数据与猪窝遗传使用，不直接参与移动/碰撞。
@export var pig_rgb := Vector3i(255, 170, 190)

## 每只猪拥有自己的 Inventory 实例，由 Main 在启动时注入。
var inventory: Inventory

var is_selected := false:
	set(value):
		if is_selected == value:
			return
		is_selected = value
		queue_redraw()
		selected_changed.emit(is_selected)

var is_moving := false
var is_stunned := false
var target_cell := Vector2i.ZERO
## 行为设计模块列表。每个元素是 Dictionary，由 BehaviorUI 编辑、Main 执行。
var behavior_program: Array[Dictionary] = []
var behavior_running := false
## 每只猪独立的行为执行状态；未选中的自动猪也会继续推进。
var behavior_wait := 0.0
var behavior_module_index := 0
var behavior_area_index := 0
var behavior_move_active := false
var behavior_path: Array[Vector2i] = []
## 手动指令：取消选中后仍会继续执行完剩余路径和待执行动作。
var command_path: Array[Vector2i] = []
var command_action: Dictionary = {}
## 供脚步音效做“离屏幕中心/缩放”衰减。
var audio_center_world := Vector2.ZERO
var audio_zoom := 1.0
var audio_cell_size := 36.0

var _target_position := Vector2.ZERO
var _walk_clock := 0.0
var _step_timer := 0.0
var _sprite_rest_position := Vector2.ZERO
var _held_item_id := ""
var _held_count := 0
var _held_badge: Panel
var _held_icon: TextureRect
var _held_count_label: Label
var _step_player: AudioStreamPlayer

@onready var _sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	_sprite_rest_position = _sprite.position
	_sprite.modulate = body_tint
	_build_held_badge()
	_build_step_player()
	if inventory != null:
		_connect_inventory(inventory)
	_update_held_visual()
	queue_redraw()


func _process(delta: float) -> void:
	if is_stunned:
		queue_redraw()
		return

	if is_selected:
		queue_redraw()

	if not is_moving:
		return

	var to_target := _target_position - global_position
	var step := move_speed * delta
	if to_target.length_squared() <= step * step:
		global_position = _target_position
		_finish_move()
		return

	var direction := to_target.normalized()
	global_position += direction * step
	_walk_clock += delta

	# 每抖动一下播放一次脚步音效。
	_step_timer -= delta
	if _step_timer <= 0.0:
		_step_timer = 0.24
		_play_step_sound()

	# 轻微上下颠动 + 摆动，让 36px 格子的移动更有生命感。
	_sprite.position.y = _sprite_rest_position.y - absf(sin(_walk_clock * 13.0)) * 1.8
	_sprite.rotation = sin(_walk_clock * 13.0) * 0.035
	if absf(direction.x) > 0.02:
		_sprite.flip_h = direction.x < 0.0


func _draw() -> void:
	# 柔和的地面阴影。
	draw_set_transform(Vector2(0.0, 22.0), 0.0, Vector2(1.0, 0.36))
	draw_circle(Vector2.ZERO, 29.0, Color(0.09, 0.14, 0.06, 0.24))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	if is_stunned:
		_draw_stun_stars()

	if not is_selected:
		return

	var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() / 230.0)
	# 选中圈严格贴合 1×1 格子（36 px），不再比猪大一圈。
	draw_arc(
		Vector2.ZERO,
		18.0,
		0.0,
		TAU,
		40,
		Color(1.0, 0.84, 0.34, 0.35 + 0.25 * pulse),
		2.2,
		true
	)
	draw_arc(
		Vector2.ZERO,
		18.0,
		0.0,
		TAU,
		40,
		Color(1.0, 0.92, 0.62, 0.10 + 0.12 * pulse),
		1.0,
		true
	)


func _draw_stun_stars() -> void:
	var clock := Time.get_ticks_msec() / 1000.0
	for index in 3:
		var angle := clock * 3.2 + float(index) * TAU / 3.0
		var center := Vector2(
			cos(angle) * 13.0,
			-40.0 + sin(angle) * 4.0
		)
		_draw_star(center, 5.2, 2.2, Color("#FFE07A"))
		_draw_star(center, 3.0, 1.2, Color("#FFF5B8"))


func _draw_star(center: Vector2, outer: float, inner: float, color: Color) -> void:
	var points := PackedVector2Array()
	for index in 10:
		var radius := outer if index % 2 == 0 else inner
		var angle := -PI * 0.5 + float(index) * PI / 5.0
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	draw_colored_polygon(points, color)


func set_selected(value: bool) -> void:
	if is_stunned and value:
		return
	is_selected = value


func set_identity(rgb_value: Vector3i, tint: Color) -> void:
	pig_rgb = rgb_value
	body_tint = tint
	if is_inside_tree() and _sprite != null:
		_sprite.modulate = tint


func stun() -> void:
	if is_stunned:
		return
	is_stunned = true
	stop_moving()
	set_selected(false)
	_sprite.rotation = deg_to_rad(18.0)
	_sprite.position.y = _sprite_rest_position.y + 5.0
	_step_timer = 0.0
	queue_redraw()


func _build_step_player() -> void:
	_step_player = AudioStreamPlayer.new()
	_step_player.volume_db = -20.0
	_step_player.stream = load("res://assets/audio/step.wav") as AudioStream
	add_child(_step_player)


func _play_step_sound() -> void:
	if _step_player == null or _step_player.stream == null:
		return
	var cell_size := maxf(audio_cell_size, 1.0)
	var distance_cells := global_position.distance_to(audio_center_world) / cell_size
	var distance_factor := clampf(1.0 - distance_cells / 50.0, 0.0, 1.0)
	var zoom_factor := clampf(audio_zoom, 0.0, 1.0)
	var linear := distance_factor * zoom_factor
	_step_player.volume_db = -20.0 + (linear_to_db(linear) if linear > 0.001 else -80.0)
	_step_player.pitch_scale = randf_range(0.9, 1.12)
	_step_player.play()


func set_audio_environment(center_world: Vector2, zoom: float, cell_size: float) -> void:
	audio_center_world = center_world
	audio_zoom = zoom
	audio_cell_size = cell_size


func set_inventory(value: Inventory) -> void:
	if inventory != null:
		_disconnect_inventory(inventory)
	inventory = value
	if is_inside_tree() and inventory != null:
		_connect_inventory(inventory)
	_update_held_visual()


func _connect_inventory(value: Inventory) -> void:
	if not value.changed.is_connected(_update_held_visual):
		value.changed.connect(_update_held_visual)
	if not value.selection_changed.is_connected(_on_inventory_selection_changed):
		value.selection_changed.connect(_on_inventory_selection_changed)


func _disconnect_inventory(value: Inventory) -> void:
	if value.changed.is_connected(_update_held_visual):
		value.changed.disconnect(_update_held_visual)
	if value.selection_changed.is_connected(_on_inventory_selection_changed):
		value.selection_changed.disconnect(_on_inventory_selection_changed)


func _on_inventory_selection_changed(_index: int) -> void:
	_update_held_visual()


func _build_held_badge() -> void:
	_held_badge = Panel.new()
	_held_badge.position = Vector2(18.0, -54.0)
	_held_badge.size = Vector2(34.0, 34.0)
	_held_badge.z_index = 20
	_held_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_held_badge.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(Color(0.10, 0.14, 0.08, 0.94), 17, UIStyle.ACCENT, 1, false)
	)
	add_child(_held_badge)

	_held_icon = TextureRect.new()
	_held_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_held_icon.offset_left = 4.0
	_held_icon.offset_top = 4.0
	_held_icon.offset_right = -4.0
	_held_icon.offset_bottom = -4.0
	_held_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_held_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_held_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_held_badge.add_child(_held_icon)

	_held_count_label = Label.new()
	_held_count_label.anchor_left = 1.0
	_held_count_label.anchor_top = 1.0
	_held_count_label.anchor_right = 1.0
	_held_count_label.anchor_bottom = 1.0
	_held_count_label.offset_left = -30.0
	_held_count_label.offset_top = -18.0
	_held_count_label.offset_right = 1.0
	_held_count_label.offset_bottom = 3.0
	_held_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_held_count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_held_count_label.add_theme_font_override("font", UIStyle.bold_font())
	_held_count_label.add_theme_font_size_override("font_size", 11)
	_held_count_label.add_theme_color_override("font_color", UIStyle.TEXT)
	_held_count_label.add_theme_color_override("font_outline_color", Color(0.04, 0.06, 0.03, 0.95))
	_held_count_label.add_theme_constant_override("outline_size", 3)
	_held_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_held_badge.add_child(_held_count_label)
	_held_badge.visible = false


func _update_held_visual() -> void:
	if _held_badge == null:
		return
	if inventory == null:
		_held_item_id = ""
		_held_count = 0
		_held_badge.visible = false
		return

	_held_item_id = inventory.get_held_item_id()
	_held_count = inventory.get_held_count()
	if _held_item_id.is_empty():
		_held_badge.visible = false
		return

	_held_badge.visible = true
	_held_icon.texture = ItemDB.get_icon(_held_item_id)
	_held_count_label.text = str(_held_count) if _held_count > 1 else ""
	_held_count_label.visible = _held_count > 1


func contains_global_point(world_point: Vector2) -> bool:
	return global_position.distance_squared_to(world_point) <= hit_radius * hit_radius


func move_to_cell(cell: Vector2i, grid_cell_size: int) -> void:
	if is_stunned:
		return
	target_cell = cell
	_target_position = Vector2(cell) * float(grid_cell_size) + Vector2.ONE * (float(grid_cell_size) * 0.5)
	move_started.emit(cell)

	if global_position.distance_squared_to(_target_position) <= 0.25:
		_finish_move()
		return

	is_moving = true
	_walk_clock = 0.0
	_step_timer = 0.0


func _finish_move() -> void:
	is_moving = false
	_sprite.position = _sprite_rest_position
	_sprite.rotation = 0.0
	_step_timer = 0.0
	arrived.emit(target_cell)


## 立即停下，不发出 arrived；用于取消自动路径或切换猪。
func stop_moving() -> void:
	is_moving = false
	_sprite.position = _sprite_rest_position
	_sprite.rotation = 0.0
	_step_timer = 0.0
