class_name ObstacleLayer
extends RefCounted
## 自然障碍层：3×3 树（按根格归属区块）与 1 格石头。
##
## 候选点粗网格（step = obstacle.cell_chunk_cells）：
##   把"每格一次 splitmix"压成"每 step² 格一次"。每个候选点最多产出 1 棵树
##   或 1 块石头（以候选点为树根 / 石头格）。*_chance_millis 是"每候选点"的千分概率。
##
## 边界带（跨区块连续性，§4/§5.2）：
##   邻块的树根可能把 3×3 footprint 伸进本块，所以本块 ChunkData 还要收录
##   根格落在 [origin-(footprint-1), origin+size-1] 范围内的树。
##   候选点对齐到**全局** step 网格，邻块重算时得到完全相同的结果。
##
## 规则：
##   - 树的 3×3 任何一格是 WATER 就不种（§4.3），且非 SAND 占比低于
##     tree_ground_pad_millis 也不种（树偏好草地/泥土，避免贴着水边长一排）。
##   - hp 用 hash2 派生（替代 randi_range），同一种子同一格永远相同。

const TREE := "tree"
const ROCK := "rock"


const SALT_OFFSET_JITTER := 15486047


## 候选点格坐标：全局 step 网格的格点 + 确定性抖动（抖动只依赖格点下标）。
## 抖动是必要的：没有它，树根永远落在 step 的整数倍上，3×3 footprint 根本无法跨越
## 区块接缝（边界带逻辑会变成死代码），而且树会在地图上排成可见的网格。
static func candidate_cell(seed_value: int, config: WorldGenConfig, grid_x: int, grid_y: int) -> Vector2i:
	var step := config.obstacle_cell_chunk_cells
	var base := Vector2i(grid_x * step, grid_y * step)
	if step <= 1:
		return base
	var roll := SeedSystem.quick32(seed_value, config.obstacle_salt + SALT_OFFSET_JITTER, grid_x, grid_y)
	return base + Vector2i(
		int(SeedSystem.ushr(roll, 7) % step),
		int(SeedSystem.ushr(roll, 31) % step)
	)


## 本块需要枚举的候选点下标范围（全局 step 网格上的整数下标，闭区间）。
static func candidate_bounds(config: WorldGenConfig, chunk: Vector2i) -> Rect2i:
	var size := config.chunk_size
	var origin := GridMath.chunk_origin(chunk, size)
	var step := config.obstacle_cell_chunk_cells
	var pad := config.tree_footprint - 1
	var first_x := GridMath.floor_div(origin.x - pad, step)
	var last_x := GridMath.floor_div(origin.x + size - 1, step)
	var first_y := GridMath.floor_div(origin.y - pad, step)
	var last_y := GridMath.floor_div(origin.y + size - 1, step)
	return Rect2i(Vector2i(first_x, first_y), Vector2i(last_x - first_x + 1, last_y - first_y + 1))


## 生成本块收录的障碍（树 + 石头 + 灌木）。
##
## **跨区块一致性**（本层最关键的约束）：
## 冲突消解必须是 (seed, config, 候选点全局下标) 的纯函数，与「正在生成哪个区块」无关。
## 做法分三点：
##   1. 在**扩展窗口**（本块候选窗口外扩 PAD_GRID 个格点）上按全局下标升序扫描；
##   2. 占位表 occupied 对**窗口内所有候选**无条件维护（不区分它是否与本块相交），
##      因此任意两个区块对同一个候选看到的前缀状态一致；
##   3. 只有 footprint 与本块相交的才真正 append 进 obstacles。
## PAD_GRID 必须大于「一个候选能挡住另一个候选的最大距离」= footprint-1 + (step-1)，
## step=8 / footprint=3 时是 9 格，PAD_GRID=3 个格点 = 24 格，安全。
##
## 曾经的写法是「本块自己的 occupied 字典 + 只对相交候选占位」：边界带的候选会与邻块的树
## 不对称地互相否决，导致同一棵树只被其中一个区块收录 → 砍伐无法落盘、遮挡随加载顺序变化。
const PAD_GRID := 3


## 生成本块收录的障碍。obstacles 追加 {cell, kind, hp}。
static func generate(
	seed_value: int,
	config: WorldGenConfig,
	sampler: TerrainSampler,
	chunk: Vector2i,
	obstacles: Array[Dictionary]
) -> void:
	var size := config.chunk_size
	var origin := GridMath.chunk_origin(chunk, size)
	var window := candidate_bounds(config, chunk)
	var expanded := Rect2i(
		window.position - Vector2i(PAD_GRID, PAD_GRID),
		window.size + Vector2i(PAD_GRID * 2, PAD_GRID * 2)
	)
	var footprint := config.tree_footprint
	var occupied := {}

	for index_y in expanded.size.y:
		var grid_y := expanded.position.y + index_y
		for index_x in expanded.size.x:
			var grid_x := expanded.position.x + index_x
			var cell := candidate_cell(seed_value, config, grid_x, grid_y)
			var bucket := SeedSystem.quick32(seed_value, config.obstacle_salt, grid_x, grid_y) % 1000
			if bucket < config.tree_chance_millis:
				_resolve_tree(seed_value, config, sampler, origin, size, footprint, cell, occupied, obstacles)
			elif bucket < config.tree_chance_millis + config.rock_chance_millis:
				_resolve_rock(seed_value, config, sampler, origin, size, cell, occupied, obstacles)
			elif config.bush_chance_millis > 0:
				_resolve_bush(seed_value, config, sampler, origin, size, cell, occupied, obstacles)


## 树的消解。注意：**占位与否**与"是否收录进本块"是两件事。
static func _resolve_tree(
	seed_value: int,
	config: WorldGenConfig,
	sampler: TerrainSampler,
	origin: Vector2i,
	size: int,
	footprint: int,
	root: Vector2i,
	occupied: Dictionary,
	obstacles: Array[Dictionary]
) -> void:
	for offset_y in footprint:
		for offset_x in footprint:
			if occupied.has(root + Vector2i(offset_x, offset_y)):
				return
	var pads_needed := (footprint * footprint * config.tree_ground_pad_millis + 999) / 1000
	var pads := 0
	for offset_y in footprint:
		for offset_x in footprint:
			var terrain_type := sampler.terrain_at(root.x + offset_x, root.y + offset_y)
			if not TerrainTypes.is_walkable(terrain_type):
				return
			if terrain_type != TerrainTypes.SAND:
				pads += 1
	if pads < pads_needed:
		return
	# 无条件占位：即使这棵树不属于本块，邻块也会得到同一个裁决。
	for offset_y in footprint:
		for offset_x in footprint:
			occupied[root + Vector2i(offset_x, offset_y)] = true
	if not _intersects_chunk(root, footprint, origin, size):
		return
	obstacles.append({
		"cell": root,
		"kind": ChunkData.KIND_TREE,
		"hp": tree_hp_at(seed_value, config, root),
	})


static func _resolve_rock(
	seed_value: int,
	config: WorldGenConfig,
	sampler: TerrainSampler,
	origin: Vector2i,
	size: int,
	cell: Vector2i,
	occupied: Dictionary,
	obstacles: Array[Dictionary]
) -> void:
	if occupied.has(cell):
		return
	if not TerrainTypes.is_walkable(sampler.terrain_at(cell.x, cell.y)):
		return
	occupied[cell] = true
	if not _intersects_chunk(cell, 1, origin, size):
		return
	var roll := SeedSystem.hash2(seed_value, config.obstacle_salt + 104729, cell.x, cell.y)
	var span := config.rock_hp_max - config.rock_hp_min + 1
	obstacles.append({
		"cell": cell,
		"kind": ChunkData.KIND_ROCK,
		"hp": config.rock_hp_min + int(SeedSystem.ushr(roll, 23) % span),
	})


static func _resolve_bush(
	seed_value: int,
	config: WorldGenConfig,
	sampler: TerrainSampler,
	origin: Vector2i,
	size: int,
	cell: Vector2i,
	occupied: Dictionary,
	obstacles: Array[Dictionary]
) -> void:
	# 灌木按同一套占位消解，因此不会长在树的 3×3 footprint 里（曾经会）。
	EcoLayer.try_place_bush(seed_value, config, sampler, cell, occupied, obstacles)
	if obstacles.is_empty():
		return
	var last: Dictionary = obstacles[obstacles.size() - 1]
	if int(last.get("kind", 0)) != ChunkData.KIND_BUSH or last.get("cell", Vector2i.ZERO) != cell:
		return
	if not _intersects_chunk(cell, 1, origin, size):
		obstacles.pop_back()
## 树耐久：种树时也用这个函数派生，保证"程序生成的树"和"种下长成的树"同源。
static func tree_hp_at(seed_value: int, config: WorldGenConfig, root: Vector2i) -> int:
	var roll := SeedSystem.hash2(seed_value, config.obstacle_salt + 7919, root.x, root.y)
	var span := config.tree_hp_max - config.tree_hp_min + 1
	return config.tree_hp_min + int(SeedSystem.ushr(roll, 17) % span)


## footprint 是否与本块相交（本块 = [origin, origin+size)）。
static func _intersects_chunk(cell: Vector2i, footprint: int, origin: Vector2i, size: int) -> bool:
	return (
		cell.x + footprint - 1 >= origin.x
		and cell.x < origin.x + size
		and cell.y + footprint - 1 >= origin.y
		and cell.y < origin.y + size
	)