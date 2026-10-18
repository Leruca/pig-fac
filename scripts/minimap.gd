class_name FarmMinimap
extends Control
## 左上角的小地图：DETAIL 固定显示当前细节块，BIG 显示大地图区块与迷雾。
## 点击猪会选中猪；点击空白处打开对应全屏地图。

signal map_clicked(mode: int)
signal pig_clicked(pig: Pig)

enum Mode { DETAIL, BIG }

const DETAIL_SIDE := 16
const DETAIL_CELL_METERS := 16

var game: Node
var mode := Mode.DETAIL


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = true
	custom_minimum_size = Vector2(172.0, 172.0)


func setup(game_node: Node, map_mode: int) -> void:
	game = game_node
	mode = map_mode
	tooltip_text = "点击猪选中；点击空白打开细节地图" if mode == Mode.DETAIL else "点击猪选中；点击空白打开大地图"
	queue_redraw()


func _process(_delta: float) -> void:
	if visible and game != null:
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			var pig := _pig_at_position(button.position)
			if pig != null:
				pig_clicked.emit(pig)
			else:
				map_clicked.emit(mode)
			accept_event()


func _draw() -> void:
	if game == null or size.x <= 4.0 or size.y <= 4.0:
		return
	if mode == Mode.DETAIL:
		_draw_detail()
	else:
		_draw_big()


func _detail_geometry() -> Dictionary:
	var side := DETAIL_SIDE
	var cell_px := minf(size.x, size.y) / float(side)
	var map_size := cell_px * float(side)
	var map_origin := (size - Vector2.ONE * map_size) * 0.5
	var block: Vector2i = game.detail_map_block()
	var origin_cell: Vector2i = game.detail_map_origin_cell(block)
	return {
		"side": side,
		"cell_px": cell_px,
		"map_size": map_size,
		"map_origin": map_origin,
		"origin_cell": origin_cell,
		"map_rect": Rect2(map_origin, Vector2.ONE * map_size),
	}


func _draw_detail() -> void:
	var geometry := _detail_geometry()
	var cell_px: float = geometry["cell_px"]
	var map_origin: Vector2 = geometry["map_origin"]
	var origin_cell: Vector2i = geometry["origin_cell"]
	var map_rect: Rect2 = geometry["map_rect"]
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.045, 0.065, 0.038, 0.98), true)
	# 16×16 个展示格，每格代表 16m。
	for local_y in DETAIL_SIDE:
		for local_x in DETAIL_SIDE:
			var sample := origin_cell + Vector2i(local_x * DETAIL_CELL_METERS + 8, local_y * DETAIL_CELL_METERS + 8)
			var color := Color(0.10, 0.16, 0.08, 1.0)
			if game.farm.is_tilled(sample):
				color = Color(0.33, 0.23, 0.13, 1.0)
			if game.farm.has_crop(sample):
				color = Color(0.22, 0.45, 0.16, 1.0)
			if game.world_objects.is_blocked(sample):
				color = Color(0.13, 0.24, 0.11, 1.0)
			var rect := Rect2(
				map_origin + Vector2(float(local_x), float(local_y)) * cell_px,
				Vector2.ONE * cell_px
			)
			draw_rect(rect, color, true)
			draw_rect(rect, Color(0.55, 0.72, 0.43, 0.10), false, 1.0)

	var cell_px_value: float = geometry["cell_px"]
	var map_origin_value: Vector2 = geometry["map_origin"]
	var origin_value: Vector2i = geometry["origin_cell"]
	var map_rect_value: Rect2 = geometry["map_rect"]
	var cell_size_value := float(game.grid.cell_size)
	var camera_local_meters: Vector2 = (game.camera.global_position / cell_size_value) - Vector2(origin_value)
	var camera_point: Vector2 = map_origin_value + camera_local_meters * (cell_px_value / float(DETAIL_CELL_METERS))
	draw_line(camera_point + Vector2(-5.0, 0.0), camera_point + Vector2(5.0, 0.0), Color(0.95, 0.98, 0.83, 0.8), 1.0)
	draw_line(camera_point + Vector2(0.0, -5.0), camera_point + Vector2(0.0, 5.0), Color(0.95, 0.98, 0.83, 0.8), 1.0)

	for pig_value in game.pigs:
		var pig: Pig = pig_value
		var point := _detail_pig_point(pig, geometry)
		if map_rect_value.has_point(point):
			_draw_pig_dot(pig, point)
		elif pig == game.active_pig:
			_draw_edge_marker(point, map_rect_value)

	draw_rect(map_rect_value, Color(0.62, 0.78, 0.48, 0.35), false, 1.0)


func _draw_edge_marker(point: Vector2, map_rect: Rect2) -> void:
	var clamped := Vector2(
		clampf(point.x, map_rect.position.x + 5.0, map_rect.end.x - 5.0),
		clampf(point.y, map_rect.position.y + 5.0, map_rect.end.y - 5.0)
	)
	draw_circle(clamped, 3.5, Color(1.0, 0.84, 0.34, 0.95))
	draw_arc(clamped, 6.0, 0.0, TAU, 16, Color(1.0, 0.92, 0.62, 0.8), 1.2, true)


func _detail_pig_point(pig: Pig, geometry: Dictionary) -> Vector2:
	var cell_px: float = geometry["cell_px"]
	var map_origin: Vector2 = geometry["map_origin"]
	var origin_cell: Vector2i = geometry["origin_cell"]
	var cell_size := float(game.grid.cell_size)
	var local_meters := (pig.global_position / cell_size) - Vector2(origin_cell)
	var pixels_per_meter := cell_px / float(DETAIL_CELL_METERS)
	return map_origin + local_meters * pixels_per_meter


func _draw_big() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.035, 0.055, 0.030, 0.98), true)
	var span := 9
	var cell_px := minf(size.x, size.y) / float(span)
	var current: Vector2i = game.current_big_block()
	var origin := current - Vector2i(span / 2, span / 2)
	var map_size := cell_px * float(span)
	var map_origin := (size - Vector2.ONE * map_size) * 0.5
	var map_rect := Rect2(map_origin, Vector2.ONE * map_size)

	for local_y in span:
		for local_x in span:
			var block: Vector2i = origin + Vector2i(local_x, local_y)
			var rect := Rect2(
				map_origin + Vector2(float(local_x), float(local_y)) * cell_px,
				Vector2.ONE * cell_px
			)
			var visited: bool = game.is_block_visited(block)
			var color := Color(0.19, 0.28, 0.15, 1.0) if visited else Color(0.025, 0.035, 0.022, 1.0)
			draw_rect(rect.grow(-1.0), color, true)
			draw_rect(rect, Color(0.58, 0.73, 0.45, 0.18), false, 1.0)
			if not visited:
				draw_line(rect.position + Vector2(3.0, 3.0), rect.end - Vector2(3.0, 3.0), Color(0.10, 0.14, 0.09, 0.7), 1.0)
			if block == current:
				draw_rect(rect.grow(-1.0), Color(1.0, 0.84, 0.34, 0.95), false, 2.0)

	for pig_value in game.pigs:
		var pig: Pig = pig_value
		var point := _big_pig_point(pig, span, cell_px, origin, map_origin)
		if map_rect.has_point(point):
			_draw_pig_dot(pig, point)
		elif pig == game.active_pig:
			_draw_edge_marker(point, map_rect)

	draw_rect(Rect2(map_origin, Vector2.ONE * map_size), Color(0.72, 0.84, 0.58, 0.35), false, 1.0)


func _big_pig_point(pig: Pig, span: int, cell_px: float, origin: Vector2i, map_origin: Vector2) -> Vector2:
	var block: Vector2i = game.block_of_cell(game.grid.world_to_cell(pig.global_position))
	var offset := Vector2.ZERO
	var pig_index: int = game.pigs.find(pig)
	if pig_index == 1:
		offset = Vector2(4.0, -4.0)
	elif pig_index == 2:
		offset = Vector2(-4.0, 4.0)
	var local := Vector2(block - origin) + Vector2(0.5, 0.5)
	return map_origin + local * cell_px + offset


func _draw_pig_dot(pig: Pig, point: Vector2) -> void:
	var is_active: bool = pig == game.active_pig
	draw_circle(point, 4.2 if is_active else 3.2, pig.body_tint)
	draw_circle(point, 1.2, Color(0.05, 0.08, 0.04, 0.95))
	if is_active:
		draw_arc(point, 7.0, 0.0, TAU, 20, Color(1.0, 0.84, 0.34), 1.6, true)


func _pig_at_position(local_position: Vector2) -> Pig:
	if game == null:
		return null
	var candidates: Array[Pig] = []
	if mode == Mode.DETAIL:
		var geometry := _detail_geometry()
		for pig_value in game.pigs:
			var pig: Pig = pig_value
			if _detail_pig_point(pig, geometry).distance_to(local_position) <= 9.0:
				candidates.append(pig)
	else:
		var span := 9
		var cell_px := minf(size.x, size.y) / float(span)
		var current: Vector2i = game.current_big_block()
		var origin := current - Vector2i(span / 2, span / 2)
		var map_size := cell_px * float(span)
		var map_origin := (size - Vector2.ONE * map_size) * 0.5
		for pig_value in game.pigs:
			var pig: Pig = pig_value
			if _big_pig_point(pig, span, cell_px, origin, map_origin).distance_to(local_position) <= 9.0:
				candidates.append(pig)
	if candidates.is_empty():
		return null
	var active_index := candidates.find(game.active_pig)
	if active_index >= 0:
		return candidates[(active_index + 1) % candidates.size()]
	return candidates[0]
