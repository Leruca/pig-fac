class_name WorldGrid
extends Node2D
## 无限格子地图的视觉层。
##
## 不存在固定地图尺寸：这里每帧只绘制摄像机可见范围内的格子，因此格子可以
## 一直向四周延伸。后续接入区块数据、地形或寻路时，可以沿用同一套格子坐标。

@export_range(16, 96, 1) var cell_size: int = 36

const GRASS_A := Color("#9BC57A")
const GRASS_B := Color("#92BD72")
const GRID_LINE := Color(0.29, 0.43, 0.22, 0.25)
const TUFTS := Color(0.26, 0.42, 0.20, 0.40)
const FLOWERS := Color("#F4DE8A")


func _ready() -> void:
	z_index = -20


func _process(_delta: float) -> void:
	# 摄像机平滑跟随猪移动时格子也在移动，所以保持重绘。
	queue_redraw()


## 世界坐标 -> 格子坐标。负数也使用 floor，保证 (-1, -1) 是有效格子。
func world_to_cell(world_position: Vector2) -> Vector2i:
	return Vector2i(
		floori(world_position.x / float(cell_size)),
		floori(world_position.y / float(cell_size))
	)


## 格子坐标 -> 格子中心的世界坐标。
func cell_to_world_center(cell: Vector2i) -> Vector2:
	return Vector2(cell) * float(cell_size) + Vector2.ONE * (float(cell_size) * 0.5)


func _draw() -> void:
	var viewport_size := get_viewport_rect().size
	var to_world := get_viewport().get_canvas_transform().affine_inverse()

	var top_left := to_world * Vector2.ZERO
	var top_right := to_world * Vector2(viewport_size.x, 0.0)
	var bottom_left := to_world * Vector2(0.0, viewport_size.y)
	var bottom_right := to_world * viewport_size

	var min_world := Vector2(
		minf(minf(top_left.x, top_right.x), minf(bottom_left.x, bottom_right.x)),
		minf(minf(top_left.y, top_right.y), minf(bottom_left.y, bottom_right.y))
	)
	var max_world := Vector2(
		maxf(maxf(top_left.x, top_right.x), maxf(bottom_left.x, bottom_right.x)),
		maxf(maxf(top_left.y, top_right.y), maxf(bottom_left.y, bottom_right.y))
	)

	var first_cell := world_to_cell(min_world) - Vector2i.ONE
	var last_cell := world_to_cell(max_world) + Vector2i.ONE
	var cell_extent := float(cell_size)

	# 棋盘格底色 + 固定哈希生成的草丛/小花。哈希只依赖格子坐标，所以镜头移动
	# 时装饰不会跳变，也天然支持无限地图。
	for y in range(first_cell.y, last_cell.y + 1):
		for x in range(first_cell.x, last_cell.x + 1):
			var cell := Vector2i(x, y)
			var cell_rect := Rect2(Vector2(x, y) * cell_extent, Vector2.ONE * cell_extent)
			var base := GRASS_A if posmod(x + y, 2) == 0 else GRASS_B
			draw_rect(cell_rect, base, true)
			_draw_cell_decor(cell, cell_rect)

	# 细网格线。
	for x in range(first_cell.x, last_cell.x + 2):
		var px := float(x * cell_size)
		draw_line(Vector2(px, min_world.y), Vector2(px, max_world.y), GRID_LINE, 1.0)
	for y in range(first_cell.y, last_cell.y + 2):
		var py := float(y * cell_size)
		draw_line(Vector2(min_world.x, py), Vector2(max_world.x, py), GRID_LINE, 1.0)


func _draw_cell_decor(cell: Vector2i, cell_rect: Rect2) -> void:
	var hash_value := ((cell.x * 73856093) ^ (cell.y * 19349663)) & 0x7FFFFFFF
	if hash_value % 7 == 0:
		var tuft := cell_rect.position + Vector2(
			float(8 + ((hash_value >> 4) % 22)),
			float(12 + ((hash_value >> 9) % 16))
		)
		draw_line(tuft, tuft + Vector2(-2.5, -5.0), TUFTS, 1.2)
		draw_line(tuft, tuft + Vector2(0.5, -6.0), TUFTS, 1.2)
		draw_line(tuft, tuft + Vector2(2.5, -4.0), TUFTS, 1.2)

	if hash_value % 29 == 0:
		var flower := cell_rect.position + Vector2(
			float(10 + ((hash_value >> 3) % 18)),
			float(10 + ((hash_value >> 7) % 14))
		)
		draw_circle(flower, 1.8, FLOWERS)
		draw_circle(flower, 0.7, Color("#C9833F"))
