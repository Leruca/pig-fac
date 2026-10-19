class_name SpawnGuard
extends RefCounted
## 出生保护区：最高优先级的地形/障碍/矿点逐格覆写（§4.5）。
##
## 规则：
##   - dist(cell, origin) <= R 的格子强制 GRASS；
##   - 删除任何 **footprint 覆盖这些格子** 的 obstacle（含 3×3 树与灌木）与 ore；
##     不是只看根格是否在半径内——根格在 R+1、树冠伸进 R 的树必须被移除；
##   - spawn_reserved_cells（初始猪位）与 spawn_reserved_footprints（教学树 9 格）
##     显式豁免：既不强制清空，也不阻止手动放置。
##
## 注意：这里只作用于**程序化生成结果**（ChunkData）。玩家手动放的东西在
## WorldObjects / overrides 里，不会经过这里。

static func apply(
	seed_value: int,
	config: WorldGenConfig,
	chunk: Vector2i,
	data: ChunkData
) -> void:
	var _unused := seed_value
	var size := config.chunk_size
	var origin := GridMath.chunk_origin(chunk, size)
	var radius := config.spawn_safe_radius_cells
	var reserved_cells := {}
	for cell in config.spawn_reserved_cells:
		reserved_cells[cell] = true
	var reserved_footprint := {}
	for entry in config.spawn_reserved_footprints:
		var root: Vector2i = entry["root"]
		var footprint := int(entry["size"])
		for offset_y in footprint:
			for offset_x in footprint:
				reserved_footprint[root + Vector2i(offset_x, offset_y)] = true

	# 1) 半径内的地形强制 GRASS（保留教学树/猪位不动）。
	# 只遍历保护方块的交集，而不是把 65025 格全扫一遍。
	var local_left := maxi(0, -radius - origin.x)
	var local_top := maxi(0, -radius - origin.y)
	var local_right := mini(size - 1, radius - origin.x)
	var local_bottom := mini(size - 1, radius - origin.y)
	for local_y in range(local_top, local_bottom + 1):
		var cell_y := origin.y + local_y
		var row_base := local_y * size
		for local_x in range(local_left, local_right + 1):
			data.terrain[row_base + local_x] = TerrainTypes.GRASS

	# 保护区外接矩形：绝大多数障碍/矿点一次包围盒测试就被排除。
	var protect_rect := Rect2i(
		Vector2i(-radius - config.tree_footprint + 1, -radius - config.tree_footprint + 1),
		Vector2i(radius * 2 + config.tree_footprint, radius * 2 + config.tree_footprint)
	)

	# 2) 删除 footprint 与保护区相交的障碍。
	if not data.obstacles.is_empty():
		var kept: Array[Dictionary] = []
		for obstacle in data.obstacles:
			var root: Vector2i = obstacle["cell"]
			var kind := int(obstacle["kind"])
			var footprint := 1
			if kind == ChunkData.KIND_TREE:
				footprint = config.tree_footprint
			if protect_rect.has_point(root) and _footprint_hits_protected(
				root, footprint, radius, reserved_footprint, reserved_cells
			):
				continue
			kept.append(obstacle)
		data.obstacles = kept

	# 3) 删除保护区内的矿点。
	if not data.ores.is_empty():
		var kept_ores: Array[Dictionary] = []
		for ore in data.ores:
			var cell: Vector2i = ore["cell"]
			if _cell_distance(cell) <= radius:
				continue
			kept_ores.append(ore)
		data.ores = kept_ores


## 出生点 = 世界原点（区块 (0,0) 的中心，覆盖 [-127,127]）。
static func _cell_distance(cell: Vector2i) -> int:
	return maxi(absi(cell.x), absi(cell.y))


static func _footprint_hits_protected(
	root: Vector2i,
	footprint: int,
	radius: int,
	reserved_footprint: Dictionary,
	reserved_cells: Dictionary
) -> bool:
	for offset_y in footprint:
		for offset_x in footprint:
			var cell := root + Vector2i(offset_x, offset_y)
			if reserved_footprint.has(cell) or reserved_cells.has(cell):
				return true
			if _cell_distance(cell) <= radius:
				return true
	return false
