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
var _redraw_elapsed := 0.0
var _map_texture: ImageTexture
var _map_texture_mode := -1
var _map_texture_block := Vector2i(2147483647, 2147483647)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	clip_contents = true
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	custom_minimum_size = Vector2(172.0, 172.0)


func setup(game_node: Node, map_mode: int) -> void:
	game = game_node
	mode = map_mode
	tooltip_text = "点击猪选中；点击空白打开细节地图" if mode == Mode.DETAIL else "点击猪选中；点击空白打开大地图"
	_map_texture_mode = -1
	_rebuild_map_texture()
	queue_redraw()


func _process(delta: float) -> void:
	if not is_visible_in_tree() or game == null:
		return
	# 小地图只做 10Hz 刷新：地形/迷雾不会每帧变化，60Hz 重绘两个 16×16 地图
	# 在区块较多时会明显占用主线程。
	_redraw_elapsed += delta
	if _redraw_elapsed < 0.1:
		return
	_redraw_elapsed = 0.0
	_rebuild_map_texture()
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


func _rebuild_map_texture() -> void:
	if game == null:
		return
	var side := DETAIL_SIDE if mode == Mode.DETAIL else 9
	var image := Image.create(side, side, false, Image.FORMAT_RGBA8)
	if mode == Mode.DETAIL:
		var origin: Vector2i = _detail_geometry()["origin_cell"]
		for local_y in DETAIL_SIDE:
			for local_x in DETAIL_SIDE:
				var block_origin := origin + Vector2i(
					local_x * DETAIL_CELL_METERS,
					local_y * DETAIL_CELL_METERS
				)
				image.set_pixel(local_x, local_y, DetailMapStyle.color_for_block(game, block_origin))
	else:
		var current: Vector2i = game.current_big_block()
		var origin := current - Vector2i(4, 4)
		for local_y in 9:
			for local_x in 9:
				var block: Vector2i = origin + Vector2i(local_x, local_y)
				var color := Color(0.19, 0.28, 0.15, 1.0) if game.is_block_visited(block) else Color(0.025, 0.035, 0.022, 1.0)
				image.set_pixel(local_x, local_y, color)
	_map_texture = ImageTexture.create_from_image(image)
	_map_texture_mode = mode
	_map_texture_block = game.current_big_block()


func _draw_detail() -> void:
	var geometry := _detail_geometry()
	var cell_px: float = geometry["cell_px"]
	var map_origin: Vector2 = geometry["map_origin"]
	var map_rect: Rect2 = geometry["map_rect"]
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.045, 0.065, 0.038, 0.98), true)
	# 16×16 个展示格预渲染成一张 16×16 纹理，避免每帧 512 次 draw_rect。
	if _map_texture != null and _map_texture_mode == Mode.DETAIL:
		draw_texture_rect(_map_texture, map_rect, false)
	for grid_index in DETAIL_SIDE + 1:
		var grid_offset := float(grid_index) * cell_px
		draw_line(
			map_origin + Vector2(grid_offset, 0.0),
			map_origin + Vector2(grid_offset, map_rect.size.y),
			Color(0.55, 0.72, 0.43, 0.10),
			1.0
		)
		draw_line(
			map_origin + Vector2(0.0, grid_offset),
			map_origin + Vector2(map_rect.size.x, grid_offset),
			Color(0.55, 0.72, 0.43, 0.10),
			1.0
		)

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

	if _map_texture != null and _map_texture_mode == Mode.BIG:
		draw_texture_rect(_map_texture, map_rect, false)
	for local_y in span:
		for local_x in span:
			var block: Vector2i = origin + Vector2i(local_x, local_y)
			var rect := Rect2(
				map_origin + Vector2(float(local_x), float(local_y)) * cell_px,
				Vector2.ONE * cell_px
			)
			if not game.is_block_visited(block):
				draw_line(rect.position + Vector2(3.0, 3.0), rect.end - Vector2(3.0, 3.0), Color(0.10, 0.14, 0.09, 0.7), 1.0)
			if block == current:
				draw_rect(rect.grow(-1.0), Color(1.0, 0.84, 0.34, 0.95), false, 2.0)

	for grid_index in span + 1:
		var grid_offset := float(grid_index) * cell_px
		draw_line(
			map_origin + Vector2(grid_offset, 0.0),
			map_origin + Vector2(grid_offset, map_rect.size.y),
			Color(0.58, 0.73, 0.45, 0.18),
			1.0
		)
		draw_line(
			map_origin + Vector2(0.0, grid_offset),
			map_origin + Vector2(map_rect.size.x, grid_offset),
			Color(0.58, 0.73, 0.45, 0.18),
			1.0
		)

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
