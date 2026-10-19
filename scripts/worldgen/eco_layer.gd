class_name EcoLayer
extends RefCounted
## 生态层：可交互灌木（进 ChunkData.obstacles）与视觉装饰（不进 ChunkData）。
##
## 视觉草丛/小花**不物化**：0.14 密度若进物化表 ≈32MB/9 块。WorldGrid 在绘制时用
## SeedSystem.hash2(seed, eco_salt, x, y) 即时求值，内存 0 开销（现状本来就是
## 绘制时求值，这里只是把不带种子的坐标哈希换成带种子的 hash2）。
##
## 灌木与障碍层共用同一张候选点网格（含确定性抖动，见 ObstacleLayer.candidate_cell），
## 每候选点最多 1 丛灌木，bush_chance_millis 是"每候选点"的千分概率。

const TUFTS := Color(0.26, 0.42, 0.20, 0.40)
const FLOWERS := Color("#F4DE8A")


## 尝试在候选点放置灌木。
## occupied 是障碍层共享的占位表（树的 3×3 + 石头 + 灌木各占 1 格）。
## 传入后灌木就不会长在树的 footprint 里 —— 否则同一格会同时被树和灌木占用。
static func try_place_bush(
	seed_value: int,
	config: WorldGenConfig,
	sampler: TerrainSampler,
	cell: Vector2i,
	occupied: Dictionary,
	obstacles: Array[Dictionary]
) -> void:
	if config.bush_chance_millis <= 0:
		return
	if occupied.has(cell):
		return
	var roll := SeedSystem.quick32(seed_value, config.eco_salt, cell.x, cell.y)
	if roll % 1000 >= config.bush_chance_millis:
		return
	if not TerrainTypes.is_walkable(sampler.terrain_at(cell.x, cell.y)):
		return
	occupied[cell] = true
	obstacles.append({
		"cell": cell,
		"kind": ChunkData.KIND_BUSH,
		"hp": config.bush_hp,
	})


## 视觉装饰：只依赖 (seed, eco_salt, cell)，绘制时求值。
## 返回 {"tuft": bool, "flower": bool, "tuft_offset": Vector2, "flower_offset": Vector2}。
static func visual_decor(seed_value: int, config: WorldGenConfig, cell: Vector2i) -> Dictionary:
	var roll := SeedSystem.hash2(seed_value, config.eco_salt + 1, cell.x, cell.y)
	var value := roll & 0x7FFFFFFF
	var has_tuft := false
	var has_flower := false
	if config.tuft_chance_millis > 0:
		has_tuft = value % 1000 < config.tuft_chance_millis
	else:
		has_tuft = value % 7 == 0
	if config.flower_chance_millis > 0:
		has_flower = (SeedSystem.ushr(roll, 33) & 0x3FFFFFFF) % 1000 < config.flower_chance_millis
	else:
		has_flower = value % 29 == 0
	var tuft_offset := Vector2(
		8.0 + float(SeedSystem.ushr(roll, 4) % 22),
		12.0 + float(SeedSystem.ushr(roll, 9) % 16)
	)
	var flower_offset := Vector2(
		10.0 + float(SeedSystem.ushr(roll, 13) % 18),
		10.0 + float(SeedSystem.ushr(roll, 7) % 14)
	)
	return {
		"tuft": has_tuft,
		"flower": has_flower,
		"tuft_offset": tuft_offset,
		"flower_offset": flower_offset,
	}