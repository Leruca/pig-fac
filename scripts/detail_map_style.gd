class_name DetailMapStyle
extends RefCounted
## 细节地图配色：每个 16×16 格小块取"占比最大"的地形/水域/农田/障碍；
## 矿脉是稀缺资源，矿格存在时优先以矿种颜色覆盖，保证矿脉在地图上可见。
##
## 这个类同时被左上角小地图和全屏细节地图使用，避免两边配色漂移。

const BLOCK_CELLS := 16
const SAMPLE_STEP := 4

const WATER := Color(0.16, 0.32, 0.48, 1.0)
const SAND := Color(0.50, 0.45, 0.32, 1.0)
const DIRT := Color(0.33, 0.25, 0.15, 1.0)
const GRASS := Color(0.16, 0.27, 0.12, 1.0)
const UNKNOWN := Color(0.055, 0.080, 0.045, 1.0)
const TILLED := Color(0.33, 0.23, 0.13, 1.0)
const CROP := Color(0.22, 0.45, 0.16, 1.0)
const BLOCKED := Color(0.13, 0.24, 0.11, 1.0)
const ORE_FALLBACK := Color(0.75, 0.53, 0.18, 1.0)


static func color_for_block(game: Node, origin: Vector2i) -> Color:
	if game == null or game.chunk_manager == null:
		return UNKNOWN
	var terrain_counts := {0: 0, 1: 0, 2: 0, 3: 0}
	var unknown := 0
	var water_count := 0
	var tilled_count := 0
	var crop_count := 0
	var blocked_count := 0
	var ore_type_counts := {}
	var ore_cells := 0

	# 地形/水域/农田/障碍按 4 格步长采样（16×16 → 4×4），
	# 足够判断一个 16m 小块的主导项，同时避免小地图每 0.1s 扫 65k 格拖垮帧率。
	# 矿石单独遍历已物化的矿表，避免采样漏掉小矿脉。
	for y in range(0, BLOCK_CELLS, SAMPLE_STEP):
		for x in range(0, BLOCK_CELLS, SAMPLE_STEP):
			var cell := origin + Vector2i(x, y)
			var terrain_type: int = game.chunk_manager.get_cell_terrain(cell)
			if terrain_type < 0:
				unknown += 1
			else:
				terrain_counts[terrain_type] = int(terrain_counts.get(terrain_type, 0)) + 1
				if terrain_type == TerrainTypes.WATER:
					water_count += 1
			if game.farm.is_tilled(cell):
				tilled_count += 1
			if game.farm.has_crop(cell):
				crop_count += 1
			if terrain_type != TerrainTypes.WATER and game.world_objects.is_blocked(cell):
				blocked_count += 1

	for ore_cell_value in game.world_objects.ores.keys():
		var ore_cell: Vector2i = ore_cell_value
		if (
			ore_cell.x < origin.x or ore_cell.x >= origin.x + BLOCK_CELLS
			or ore_cell.y < origin.y or ore_cell.y >= origin.y + BLOCK_CELLS
		):
			continue
		ore_cells += 1
		var ore: Dictionary = game.world_objects.ores[ore_cell]
		var ore_id := int(ore.get("ore_id", 0))
		ore_type_counts[ore_id] = int(ore_type_counts.get(ore_id, 0)) + 1

	var max_terrain := 0
	var dominant_terrain := -1
	for terrain_type in terrain_counts.keys():
		var count := int(terrain_counts[terrain_type])
		if count > max_terrain:
			max_terrain = count
			dominant_terrain = int(terrain_type)
	if unknown > max_terrain:
		max_terrain = unknown
		dominant_terrain = -1

	# 矿石优先：一个 16m 小块里只要出现矿格，就用主导矿种的颜色标出来。
	if ore_cells > 0:
		return _ore_color(ore_type_counts)
	# 水域、农田、障碍都只在确实占多数时覆盖地形底色。
	if water_count > 0 and water_count >= max_terrain:
		return WATER
	if crop_count > 0 and crop_count >= max_terrain:
		return CROP
	if tilled_count > 0 and tilled_count >= max_terrain:
		return TILLED
	if blocked_count > 0 and blocked_count >= max_terrain:
		return BLOCKED
	match dominant_terrain:
		TerrainTypes.WATER:
			return WATER
		TerrainTypes.SAND:
			return SAND
		TerrainTypes.DIRT:
			return DIRT
		TerrainTypes.GRASS:
			return GRASS
		_:
			return UNKNOWN


static func _ore_color(ore_type_counts: Dictionary) -> Color:
	var best_id := 0
	var best_count := -1
	for ore_id in ore_type_counts.keys():
		var count := int(ore_type_counts[ore_id])
		if count > best_count:
			best_count = count
			best_id = int(ore_id)
	if WorldObjects.ORE_COLORS.has(best_id):
		return WorldObjects.ORE_COLORS[best_id]
	return ORE_FALLBACK
