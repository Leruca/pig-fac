class_name WorldGrid
extends Node2D
## 无限格子地图的视觉层。
##
## 不存在固定地图尺寸：每帧只绘制摄像机可见范围内的格子，因此格子可以一直向四周
## 延伸。地形底色来自 ChunkManager 的 TerrainLayer（未生成的区块显示"未探索"底色，
## 而不是错误的水/陆地信息）；视觉装饰（草丛/小花）**不物化**，绘制时用
## SeedSystem.hash2(seed, eco_salt, x, y) 即时求值 —— 内存 0 开销，且带种子。

@export_range(16, 96, 1) var cell_size: int = 36

const GRASS_A := Color("#9BC57A")
const GRASS_B := Color("#92BD72")
const GRID_LINE := Color(0.29, 0.43, 0.22, 0.25)
const TUFTS := Color(0.26, 0.42, 0.20, 0.40)
const FLOWERS := Color("#F4DE8A")
## 未生成区块的底色（比草地暗，明确表示"还没有地形数据"）。
const UNKNOWN_A := Color("#7E9C66")
const UNKNOWN_B := Color("#77935F")

## 由 Main 注入。
var chunk_manager: ChunkManager
var worldgen_config: WorldGenConfig
var seed_value: int = 0

var _decor_cache: Dictionary = {}
var _terrain_noise: NoiseTexture2D
var _last_canvas_transform := Transform2D.IDENTITY
var _canvas_transform_ready := false


func _ready() -> void:
	z_index = -20
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED


func _make_terrain_noise() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = seed_value
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.09
	noise.fractal_octaves = 3
	_terrain_noise = NoiseTexture2D.new()
	_terrain_noise.width = 256
	_terrain_noise.height = 256
	_terrain_noise.seamless = true
	_terrain_noise.noise = noise


func setup(manager: ChunkManager, config: WorldGenConfig, seed_in: int) -> void:
	chunk_manager = manager
	worldgen_config = config
	seed_value = seed_in
	_decor_cache.clear()
	_make_terrain_noise()
	queue_redraw()


func _process(_delta: float) -> void:
	# 镜头不动时地形不需要逐帧重提交；只有 transform 变化才重绘。
	var canvas_transform := get_viewport().get_canvas_transform()
	if not _canvas_transform_ready or canvas_transform != _last_canvas_transform:
		_canvas_transform_ready = true
		_last_canvas_transform = canvas_transform
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

	# 地形底色 + 种子化的草丛/小花。地形信息只从已加载区块读取（未加载 = 未知底色），
	# 装饰只依赖 (seed, salt, 坐标)，所以镜头移动时不会跳变。
	# 草地是绝对多数：先画一整块草地底色，只对非草地/未加载格补矩形，
	# 把每帧 1000+ 次 draw_rect 降到几百次（5×5 预生成时尤其明显）。
	draw_rect(
		Rect2(min_world, max_world - min_world),
		GRASS_A,
		true
	)
	for y in range(first_cell.y, last_cell.y + 1):
		for x in range(first_cell.x, last_cell.x + 1):
			var cell := Vector2i(x, y)
			var cell_rect := Rect2(Vector2(x, y) * cell_extent, Vector2.ONE * cell_extent)
			var terrain_type := _terrain_of(cell)
			if terrain_type < 0 or terrain_type != TerrainTypes.GRASS:
				draw_rect(cell_rect, _base_color(cell, terrain_type), true)
			if terrain_type == TerrainTypes.WATER:
				_draw_water_ripple(cell, cell_rect)
			elif terrain_type >= 0:
				_draw_cell_decor(cell, cell_rect)

	# 草地/泥土/沙地的弱随机纹理：一层低透明度、按 seed 生成的可平铺噪声。
	if _terrain_noise != null:
		draw_texture_rect(
			_terrain_noise,
			Rect2(min_world, max_world - min_world),
			true,
			Color(0.10, 0.09, 0.06, 0.055)
		)

	# 细网格线。
	for x in range(first_cell.x, last_cell.x + 2):
		var px := float(x * cell_size)
		draw_line(Vector2(px, min_world.y), Vector2(px, max_world.y), GRID_LINE, 1.0)
	for y in range(first_cell.y, last_cell.y + 2):
		var py := float(y * cell_size)
		draw_line(Vector2(min_world.x, py), Vector2(max_world.x, py), GRID_LINE, 1.0)


## 已加载 -> 地形枚举；未加载 -> -1。
func _terrain_of(cell: Vector2i) -> int:
	if chunk_manager == null:
		return -1
	return chunk_manager.get_cell_terrain(cell)


func _base_color(cell: Vector2i, terrain_type: int) -> Color:
	if terrain_type < 0:
		return UNKNOWN_A if posmod(cell.x + cell.y, 2) == 0 else UNKNOWN_B
	match terrain_type:
		TerrainTypes.WATER:
			return Color("#5C97C7")
		TerrainTypes.SAND:
			return Color("#E0D0A0").lerp(Color("#D6C595"), 0.35 if posmod(cell.x + cell.y, 2) == 0 else 0.6)
		TerrainTypes.DIRT:
			return Color("#B08A5B").lerp(Color("#A67F51"), 0.35 if posmod(cell.x + cell.y, 2) == 0 else 0.6)
		_:
			return GRASS_A if posmod(cell.x + cell.y, 2) == 0 else GRASS_B


func _draw_water_ripple(cell: Vector2i, cell_rect: Rect2) -> void:
	# 极轻的水面纹理（同样由坐标哈希决定，不需要状态）。
	var roll := SeedSystem.hash2(seed_value, 9173, cell.x, cell.y)
	if (roll & 0x7FFF) % 3 != 0:
		return
	var inset := Vector2(6.0 + float(SeedSystem.ushr(roll, 5) % 12), 8.0 + float(SeedSystem.ushr(roll, 9) % 16))
	draw_line(
		cell_rect.position + inset,
		cell_rect.position + inset + Vector2(9.0, 0.0),
		Color(0.85, 0.93, 1.0, 0.22),
		1.2
	)


func _draw_cell_decor(cell: Vector2i, cell_rect: Rect2) -> void:
	if worldgen_config == null:
		return
	if worldgen_config.tuft_chance_millis == 0 and worldgen_config.flower_chance_millis == 0:
		return
	var decor := EcoLayer.visual_decor(seed_value, worldgen_config, cell)
	if bool(decor["tuft"]):
		var tuft: Vector2 = cell_rect.position + (decor["tuft_offset"] as Vector2)
		draw_line(tuft, tuft + Vector2(-2.5, -5.0), TUFTS, 1.2)
		draw_line(tuft, tuft + Vector2(0.5, -6.0), TUFTS, 1.2)
		draw_line(tuft, tuft + Vector2(2.5, -4.0), TUFTS, 1.2)
	if bool(decor["flower"]):
		var flower: Vector2 = cell_rect.position + (decor["flower_offset"] as Vector2)
		draw_circle(flower, 1.8, FLOWERS)
		draw_circle(flower, 0.7, Color("#C9833F"))
