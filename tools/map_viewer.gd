extends SceneTree
## 地图可视化 / 导出（验收 14）。
## 输入种子与半径 → 纯函数生成 → 输出 PNG（地形底色 + 矿点按类型着色 + 同脉连线 + 区块/REGION 网格线）。
##
## 用法：
##   godot --headless --path . -s res://tools/map_viewer.gd -- --seed "12345" --radius 2 --out /tmp/map.png
##   godot --headless --path . -s res://tools/map_viewer.gd -- --seed "12345" --radius 1 --out /tmp/map.png --veins /tmp/veins.json
##
## radius 以**区块**为单位（1 = 3×3 个区块 = 765×765 格）。

const PX_PER_CELL := 1
const GRID_INK := Color(0.0, 0.0, 0.0, 0.22)
const REGION_INK := Color(0.95, 0.35, 0.2, 0.55)


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var seed_text := "12345"
	var radius := 1
	var out_path := "user://map.png"
	var vein_path := ""
	var index := 0
	while index < args.size():
		var arg := str(args[index])
		match arg:
			"--seed":
				if index + 1 < args.size():
					seed_text = str(args[index + 1])
					index += 1
			"--radius":
				if index + 1 < args.size():
					radius = maxi(0, int(args[index + 1]))
					index += 1
			"--out":
				if index + 1 < args.size():
					out_path = str(args[index + 1])
					index += 1
			"--veins":
				if index + 1 < args.size():
					vein_path = str(args[index + 1])
					index += 1
		index += 1

	var config := WorldGenConfig.load_default()
	var seed_value := SeedSystem.parse_seed(seed_text)
	var generator := WorldGenerator.new(config, seed_value)
	var side := radius * 2 + 1
	var size := config.chunk_size * side
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var chunks := 0
	var ore_total := 0
	var started := Time.get_ticks_usec()
	var vein_export: Array = []
	for chunk_y in range(-radius, radius + 1):
		for chunk_x in range(-radius, radius + 1):
			var chunk := Vector2i(chunk_x, chunk_y)
			var data := generator.generate_chunk(chunk)
			chunks += 1
			var origin := GridMath.chunk_origin(chunk, config.chunk_size)
			# 地形
			for local_y in config.chunk_size:
				var pixel_y := origin.y + local_y + _origin_shift(config, radius)
				var row_base := local_y * config.chunk_size
				for local_x in config.chunk_size:
					var pixel_x := origin.x + local_x + _origin_shift(config, radius)
					if pixel_x < 0 or pixel_y < 0 or pixel_x >= size or pixel_y >= size:
						continue
					image.set_pixel(pixel_x, pixel_y, TerrainTypes.color_of(data.terrain[row_base + local_x]))
			# 障碍（树暗绿点、石头灰点）
			for obstacle in data.obstacles:
				var cell: Vector2i = obstacle["cell"]
				var point := _to_pixel(cell, config, radius)
				if not _inside(point, size):
					continue
				match int(obstacle["kind"]):
					ChunkData.KIND_TREE:
						image.fill_rect(Rect2i(point, Vector2i(3, 3)), Color("#1F4D22"))
					ChunkData.KIND_ROCK:
						image.set_pixelv(point, Color("#6F6F68"))
					_:
						image.set_pixelv(point, Color("#2F6B27"))
			# 矿点
			var ore_cells := {}
			for ore in data.ores:
				var cell: Vector2i = ore["cell"]
				ore_cells[cell] = true
				ore_total += 1
				var point := _to_pixel(cell, config, radius)
				if _inside(point, size):
					image.fill_rect(Rect2i(point - Vector2i(1, 1), Vector2i(3, 3)), _ore_color(int(ore["ore_id"])))
			# 同脉连线（只在本区块内连，跨块的由相邻区块补上）
			for ore in data.ores:
				var cell: Vector2i = ore["cell"]
				for offset in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, -1)]:
					if ore_cells.has(cell + offset):
						var from_point := _to_pixel(cell, config, radius)
						var to_point := _to_pixel(cell + offset, config, radius)
						if _inside(from_point, size) and _inside(to_point, size):
							_draw_line(image, from_point, to_point, _ore_color(int(ore["ore_id"])).darkened(0.25), size)
			if not vein_path.is_empty():
				vein_export.append({
					"chunk": [chunk.x, chunk.y],
					"ores": data.ores.duplicate(true),
				})
	# 区块与 REGION 网格线
	for grid_index in range(-radius, radius + 2):
		var line_pos := (grid_index + radius) * config.chunk_size
		if line_pos > 0 and line_pos < size - 1:
			_draw_vline(image, line_pos, GRID_INK, size)
			_draw_hline(image, line_pos, GRID_INK, size)
	for region_index in range(-radius, radius + 2):
		var region_cells := config.chunk_size * config.ore_region_chunks
		var line_pos := (region_index + radius) * region_cells
		if line_pos > 0 and line_pos < size - 1:
			_draw_vline(image, line_pos, REGION_INK, size)
			_draw_hline(image, line_pos, REGION_INK, size)

	var save_error := image.save_png(out_path)
	var elapsed := float(Time.get_ticks_usec() - started) / 1000.0
	print("map_viewer: seed=%s radius=%d chunks=%d ores=%d size=%dx%d -> %s (%.1f ms, save_err=%d)" % [
		seed_text, radius, chunks, ore_total, size, size, out_path, elapsed, save_error
	])
	if not vein_path.is_empty():
		var file := FileAccess.open(vein_path, FileAccess.WRITE)
		if file != null:
			file.store_string(JSON.stringify({"seed": seed_text, "radius": radius, "chunks": vein_export}, "\t"))
			file.close()
			print("map_viewer: 矿点清单已导出 -> %s" % vein_path)
	quit(0 if save_error == OK else 1)


## Image 没有 draw_line，用最简单的 DDA 画线（够用且不引依赖）。
func _draw_line(image: Image, from_point: Vector2i, to_point: Vector2i, color: Color, size: int) -> void:
	var steps := maxi(absi(to_point.x - from_point.x), absi(to_point.y - from_point.y))
	if steps <= 0:
		return
	for index in steps + 1:
		var ratio := float(index) / float(steps)
		var point := Vector2i(
			roundi(lerpf(float(from_point.x), float(to_point.x), ratio)),
			roundi(lerpf(float(from_point.y), float(to_point.y), ratio))
		)
		if _inside(point, size):
			image.set_pixelv(point, color)


func _blend_pixel(image: Image, point: Vector2i, color: Color, size: int) -> void:
	if not _inside(point, size):
		return
	var base := image.get_pixelv(point)
	image.set_pixelv(point, base.lerp(color, color.a))


func _draw_vline(image: Image, column: int, color: Color, size: int) -> void:
	if column <= 0 or column >= size:
		return
	for row in size:
		_blend_pixel(image, Vector2i(column, row), color, size)


func _draw_hline(image: Image, row: int, color: Color, size: int) -> void:
	if row <= 0 or row >= size:
		return
	for column in size:
		_blend_pixel(image, Vector2i(column, row), color, size)


## 图片左上角对应的世界格：取最左/最上区块的原点。
func _origin_shift(config: WorldGenConfig, radius: int) -> int:
	var corner := GridMath.chunk_origin(Vector2i(-radius, -radius), config.chunk_size)
	return -corner.x


func _to_pixel(cell: Vector2i, config: WorldGenConfig, radius: int) -> Vector2i:
	var shift := _origin_shift(config, radius)
	return Vector2i(cell.x + shift, cell.y + shift)


func _inside(point: Vector2i, size: int) -> bool:
	return point.x >= 0 and point.y >= 0 and point.x < size and point.y < size


func _ore_color(ore_id: int) -> Color:
	match ore_id:
		1:
			return Color("#D98A3D")
		2:
			return Color("#C9D3DE")
		3:
			return Color("#FFD447")
		_:
			return Color("#9FE8D8")