class_name FarmMapOverlay
extends Control
## 全屏地图：DETAIL 固定显示当前细节块（16×16 格，每格 16m）；
## BIG 显示带迷雾的大地图。左键区块进入，右键命令选中猪前往。

signal closed
signal command_requested(cell: Vector2i)

enum Mode { DETAIL, BIG }

const DETAIL_SIDE := 16
const DETAIL_CELL_METERS := 16
const DETAIL_MAP_PIXELS := 512

var game: Node
var mode := Mode.DETAIL
var _map_rect := Rect2()
var _detail_block := Vector2i.ZERO
var _title_label: Label
var _hint_label: Label
var _close_button: Button
var _hover_block := Vector2i(2147483647, 2147483647)


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_title_label = _make_label("地图", 22, UIStyle.TEXT, true)
	add_child(_title_label)
	_hint_label = _make_label("", 12, UIStyle.TEXT_MUTED)
	add_child(_hint_label)

	_close_button = Button.new()
	_close_button.text = "关闭 (Esc)"
	_close_button.focus_mode = Control.FOCUS_NONE
	_close_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_close_button.add_theme_font_override("font", UIStyle.bold_font())
	_close_button.add_theme_font_size_override("font_size", 13)
	_close_button.add_theme_color_override("font_color", UIStyle.TEXT)
	_close_button.add_theme_stylebox_override(
		"normal",
		UIStyle.make_panel(Color(0.12, 0.17, 0.10, 0.98), 8, UIStyle.SLOT_BORDER, 1, false)
	)
	_close_button.add_theme_stylebox_override(
		"hover",
		UIStyle.make_panel(Color(0.20, 0.27, 0.15, 1.0), 8, UIStyle.ACCENT, 1, false)
	)
	_close_button.pressed.connect(close)
	add_child(_close_button)
	resized.connect(_layout_map)
	_layout_map.call_deferred()


func setup(game_node: Node) -> void:
	game = game_node


func open(map_mode: int) -> void:
	mode = map_mode
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_hover_block = Vector2i(2147483647, 2147483647)
	if mode == Mode.DETAIL and game != null:
		_detail_block = game.current_big_block()
	_title_label.text = (
		"细节地图 · B(%d,%d)" % [_detail_block.x, _detail_block.y]
		if mode == Mode.DETAIL
		else "大地图 · 左键进入区块 / 右键命令猪前往"
	)
	_hint_label.text = (
		"固定显示当前 16×16 细节格（每格 16m，1m = 2px）；右键让选中猪前往"
		if mode == Mode.DETAIL
		else "亮色为已探索，暗色为迷雾；左键进入该区块，右键让选中猪走到区块中心"
	)
	_layout_map()
	queue_redraw()


func close() -> void:
	if not visible:
		return
	visible = false
	closed.emit()


func is_open() -> bool:
	return visible


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()


func _layout_map() -> void:
	if _title_label == null or size.x <= 0.0:
		return
	var map_size := float(DETAIL_MAP_PIXELS) if mode == Mode.DETAIL else minf(size.x * 0.72, size.y * 0.78)
	_map_rect = Rect2(
		Vector2((size.x - map_size) * 0.5, (size.y - map_size) * 0.5 + 18.0),
		Vector2.ONE * map_size
	)
	_title_label.reset_size()
	_title_label.position = Vector2((size.x - _title_label.size.x) * 0.5, _map_rect.position.y - 52.0)
	_hint_label.reset_size()
	_hint_label.position = Vector2(
		(size.x - _hint_label.size.x) * 0.5,
		_map_rect.end.y + 10.0
	)
	_close_button.size = Vector2(104.0, 32.0)
	_close_button.position = Vector2(_map_rect.end.x - 104.0, _map_rect.position.y - 48.0)
	queue_redraw()


func _draw() -> void:
	if not visible or game == null:
		return
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.01, 0.02, 0.01, 0.96), true)
	draw_rect(_map_rect, Color(0.055, 0.080, 0.045, 1.0), true)
	draw_rect(_map_rect, Color(0.56, 0.72, 0.43, 0.55), false, 2.0)
	if mode == Mode.DETAIL:
		_draw_detail()
	else:
		_draw_big()


func _draw_detail() -> void:
	var cell_px := _map_rect.size.x / float(DETAIL_SIDE)
	var origin: Vector2i = game.detail_map_origin_cell(_detail_block)
	var sample_offset := int(DETAIL_CELL_METERS / 2)
	for local_y in DETAIL_SIDE:
		for local_x in DETAIL_SIDE:
			var sample := origin + Vector2i(
				local_x * DETAIL_CELL_METERS + sample_offset,
				local_y * DETAIL_CELL_METERS + sample_offset
			)
			var color := _detail_cell_color(sample)
			var rect := Rect2(
				_map_rect.position + Vector2(float(local_x), float(local_y)) * cell_px,
				Vector2.ONE * cell_px
			)
			draw_rect(rect, color, true)
			draw_rect(rect, Color(0.55, 0.72, 0.43, 0.16), false, 1.0)

	var cell_size := float(game.grid.cell_size)
	var pixels_per_meter := _map_rect.size.x / float(DETAIL_SIDE * DETAIL_CELL_METERS)
	for pig_value in game.pigs:
		var pig: Pig = pig_value
		var local_meters := (pig.global_position / cell_size) - Vector2(origin)
		var point := _map_rect.position + local_meters * pixels_per_meter
		if _map_rect.has_point(point):
			draw_circle(point, 5.0, pig.body_tint)
			draw_circle(point, 1.4, Color(0.05, 0.08, 0.04, 0.95))
			if pig == game.active_pig:
				draw_arc(point, 8.0, 0.0, TAU, 20, Color(1.0, 0.84, 0.34), 1.8, true)

	var camera_local_meters: Vector2 = (game.camera.global_position / cell_size) - Vector2(origin)
	var camera_point: Vector2 = _map_rect.position + camera_local_meters * pixels_per_meter
	if _map_rect.has_point(camera_point):
		draw_line(camera_point + Vector2(-7.0, 0.0), camera_point + Vector2(7.0, 0.0), Color(0.95, 0.98, 0.83, 0.9), 1.2)
		draw_line(camera_point + Vector2(0.0, -7.0), camera_point + Vector2(0.0, 7.0), Color(0.95, 0.98, 0.83, 0.9), 1.2)


## 细节地图配色：地形（ChunkManager）→ 农田 → 作物 → 矿/障碍。
func _detail_cell_color(sample: Vector2i) -> Color:
	var terrain_type := -1
	if game.chunk_manager != null:
		terrain_type = game.chunk_manager.get_cell_terrain(sample)
	var color := Color(0.055, 0.080, 0.045, 1.0)
	match terrain_type:
		TerrainTypes.WATER:
			color = Color(0.16, 0.32, 0.48, 1.0)
		TerrainTypes.SAND:
			color = Color(0.50, 0.45, 0.32, 1.0)
		TerrainTypes.DIRT:
			color = Color(0.33, 0.25, 0.15, 1.0)
		TerrainTypes.GRASS:
			color = Color(0.16, 0.27, 0.12, 1.0)
		_:
			color = Color(0.055, 0.080, 0.045, 1.0)
	if game.farm.is_tilled(sample):
		color = Color(0.33, 0.23, 0.13, 1.0)
	if game.farm.has_crop(sample):
		color = Color(0.22, 0.45, 0.16, 1.0)
	if game.world_objects.has_ore(sample):
		color = Color(0.75, 0.53, 0.18, 1.0)
	elif game.world_objects.is_blocked(sample):
		color = Color(0.13, 0.24, 0.11, 1.0)
	return color


func _draw_big() -> void:
	var span := 15
	var cell_px := _map_rect.size.x / float(span)
	var current: Vector2i = game.current_big_block()
	var origin := current - Vector2i(span / 2, span / 2)
	for local_y in span:
		for local_x in span:
			var block: Vector2i = origin + Vector2i(local_x, local_y)
			var rect := Rect2(
				_map_rect.position + Vector2(float(local_x), float(local_y)) * cell_px,
				Vector2.ONE * cell_px
			)
			var visited: bool = game.is_block_visited(block)
			var color := Color(0.18, 0.27, 0.14, 1.0) if visited else Color(0.025, 0.035, 0.022, 1.0)
			draw_rect(rect.grow(-1.0), color, true)
			draw_rect(rect, Color(0.58, 0.73, 0.45, 0.20), false, 1.0)
			if not visited:
				draw_line(
					rect.position + Vector2(4.0, 4.0),
					rect.end - Vector2(4.0, 4.0),
					Color(0.10, 0.14, 0.09, 0.7),
					1.0
				)
			if block == current:
				draw_rect(rect.grow(-1.0), Color(1.0, 0.84, 0.34, 0.95), false, 2.0)
			if block == _hover_block:
				draw_rect(rect.grow(-2.0), Color(1.0, 0.94, 0.74, 0.85), false, 2.0)

	for pig_value in game.pigs:
		var pig: Pig = pig_value
		var block: Vector2i = game.block_of_cell(game.grid.world_to_cell(pig.global_position))
		var local := Vector2(block - origin) + Vector2(0.5, 0.5)
		var point := _map_rect.position + local * cell_px
		if _map_rect.has_point(point):
			draw_circle(point, 4.5, pig.body_tint)
			if pig == game.active_pig:
				draw_arc(point, 7.0, 0.0, TAU, 20, Color(1.0, 0.84, 0.34), 1.6, true)


func _gui_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventMouseMotion:
		if mode == Mode.BIG:
			var block := _block_at(event.position)
			if block != _hover_block:
				_hover_block = block
				queue_redraw()
		return
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if not button.pressed:
			return
		if button.button_index == MOUSE_BUTTON_RIGHT:
			if _map_rect.has_point(button.position):
				var target := _command_cell_at(button.position)
				if target != Vector2i(2147483647, 2147483647):
					command_requested.emit(target)
			accept_event()
			return
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if not _map_rect.has_point(button.position):
			close()
			accept_event()
			return
		if mode == Mode.BIG:
			var block := _block_at(button.position)
			if block.x != 2147483647:
				game.enter_big_block(block)
				close()
		accept_event()


func _command_cell_at(local_position: Vector2) -> Vector2i:
	if not _map_rect.has_point(local_position):
		return Vector2i(2147483647, 2147483647)
	if mode == Mode.DETAIL:
		var origin: Vector2i = game.detail_map_origin_cell(_detail_block)
		var pixels_per_meter := _map_rect.size.x / float(DETAIL_SIDE * DETAIL_CELL_METERS)
		var local_meters := (local_position - _map_rect.position) / pixels_per_meter
		return origin + Vector2i(floori(local_meters.x), floori(local_meters.y))
	return game.block_center_cell(_block_at(local_position))


func _block_at(screen_position: Vector2) -> Vector2i:
	if not _map_rect.has_point(screen_position):
		return Vector2i(2147483647, 2147483647)
	var span := 15
	var cell_px := _map_rect.size.x / float(span)
	var local := (screen_position - _map_rect.position) / cell_px
	if local.x < 0.0 or local.y < 0.0 or local.x >= float(span) or local.y >= float(span):
		return Vector2i(2147483647, 2147483647)
	var current: Vector2i = game.current_big_block()
	var origin := current - Vector2i(span / 2, span / 2)
	return origin + Vector2i(floori(local.x), floori(local.y))


func _make_label(
	text: String,
	font_size: int,
	color: Color = UIStyle.TEXT,
	use_bold: bool = false
) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", UIStyle.bold_font() if use_bold else UIStyle.regular_font())
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
