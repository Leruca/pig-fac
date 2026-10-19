class_name WorldGenerator
extends RefCounted
## 纯函数生成管线：generate_chunk(seed, version, chunk) -> ChunkData。
##
## 纪律（§1）：
## - 无全局可变状态、不读时钟、不用 randi/RandomNumberGenerator；
## - 层间依赖只允许"纯函数调纯函数"（Ore/Eco/Obstacle -> Terrain 同坐标查询），无环；
## - 结果只由 (seed, worldgen_version, chunk, config) 决定，与遍历/生成顺序无关。
##
## 分帧：make_job() 返回可切片任务；step() 每次推进 rows_per_slice 行或 ms_per_frame
## 毫秒，先到先停。未分帧的 generate_chunk() 就是"一次跑完的 job"，两条路径共用同一
## 份代码，避免"快路径/慢路径"两套实现漂移。

const ROWS_PER_SLICE_DEFAULT := 32

var config: WorldGenConfig
var seed_value: int = 0
var worldgen_version: int = 1

var _terrain: TerrainLayer

## 区块级噪声窗口缓存（矿脉层判定水域用）。
var _region_fields: Dictionary = {}
var _region_order: Array[Vector2i] = []
## 噪声窗口只存格点（每块两个 octave 的格点表约几 KB），可以放心多缓存。
## 早先设成 8 会在按行扫描区块时不断淘汰，导致每次查询都重建窗口（p99 抖动 3 倍）。
const REGION_FIELD_LIMIT := 256


func _init(config_value: WorldGenConfig = null, seed_in: int = 0) -> void:
	config = config_value if config_value != null else WorldGenConfig.load_default()
	seed_value = seed_in
	worldgen_version = config.worldgen_version
	_terrain = TerrainLayer.new()


## 一次性生成（测试 / bench / 工具用）。
func generate_chunk(chunk: Vector2i) -> ChunkData:
	var job := make_job(chunk)
	while not job.step(config.chunk_size * config.chunk_size, 1 << 30):
		pass
	return job.finish()


## 创建一个可切片的生成任务。
func make_job(chunk: Vector2i) -> ChunkJob:
	return ChunkJob.new(self, chunk)


## 地形单点查询（用于跨块/区域判定；带 REGION 窗口缓存）。
func terrain_type_at(cell: Vector2i) -> int:
	return _field_for_cell(cell).terrain_at(cell.x, cell.y)


func is_water_at(cell: Vector2i) -> bool:
	return terrain_type_at(cell) == TerrainTypes.WATER


func clear_caches() -> void:
	_region_fields.clear()
	_region_order.clear()
	OreLayer.reset_cache()


## 噪声窗口按**区块**缓存（不是按 REGION）：一块 255×255 正好覆盖本块的
## 障碍/生态/矿脉查询，窗口外查询会退化到逐点精算（慢 10 倍），所以窗口一定要贴住区块。
## 缓存上限按块数计，淘汰最久未用的。
func _field_for_cell(cell: Vector2i) -> NoiseField:
	var chunk := GridMath.chunk_of_cell(cell, config.chunk_size)
	if _region_fields.has(chunk):
		return _region_fields[chunk]
	var size := config.chunk_size
	var origin := GridMath.chunk_origin(chunk, size)
	var field := NoiseField.new()
	field.build(seed_value, config, Rect2i(origin, Vector2i(size, size)))
	_region_fields[chunk] = field
	_region_order.append(chunk)
	while _region_order.size() > REGION_FIELD_LIMIT:
		var evicted: Vector2i = _region_order.pop_front()
		_region_fields.erase(evicted)
	return field


## 分帧任务：行切片推进 Terraform -> 障碍/生态 -> 矿脉 -> SpawnGuard。
class ChunkJob:
	extends RefCounted

	var chunk: Vector2i
	var data: ChunkData
	var done := false

	var _generator: WorldGenerator
	var _field: NoiseField
	var _rows_done := 0
	var _rows_total := 0
	var _layers_done := false
	var _ore_done := false
	var _ore_builders: Array = []
	var _ore_index := 0

	func _init(generator: WorldGenerator, chunk_in: Vector2i) -> void:
		_generator = generator
		chunk = chunk_in
		_rows_total = generator.config.chunk_size
		data = ChunkData.new()
		data.chunk = chunk
		data.worldgen_version = generator.worldgen_version
		data.seed_value = generator.seed_value
		data.terrain = PackedByteArray()
		data.terrain.resize(_rows_total * _rows_total)
		_field = generator._terrain.make_field(generator.seed_value, generator.config, chunk)

	## 推进一次。返回 true 表示整块完成。
	## row_budget / ms_budget 双闸门：先到先停。
	func step(row_budget: int, ms_budget: int) -> bool:
		if done:
			return true
		if not _layers_done:
			# 双闸门：本帧最多推进 row_budget 行，且最多花 ms_budget 毫秒，先到先停。
			# （曾经只检查毫秒闸门，行预算是死参数，gen_ms_per_frame 调大就会一帧跑完整块。）
			var row_budget_total := maxi(1, row_budget)
			var rows_this_call := 0
			var started := Time.get_ticks_usec()
			while _rows_done < _rows_total and rows_this_call < row_budget_total:
				var end_row := mini(_rows_done + row_budget_total - rows_this_call, _rows_total)
				_field.fill_rows(data.terrain, _rows_done, end_row)
				rows_this_call += end_row - _rows_done
				_rows_done = end_row
				if (Time.get_ticks_usec() - started) / 1000 >= ms_budget:
					break
			if _rows_done < _rows_total:
				return false
			_generate_obstacles()
			_layers_done = true
		# 矿脉阶段：逐个 REGION 推进（大多数 REGION 已在缓存里，命中时几乎零成本）。
		if not _ore_done:
			var ore_started := Time.get_ticks_usec()
			var total := _ore_builders.size()
			while _ore_index < total:
				var builder: OreLayer.RegionBuilder = _ore_builders[_ore_index]
				# 冷 REGION 一次最多 4 条脉，配合毫秒闸门，单帧不会爆。
				if builder.step(4, ms_budget):
					_ore_index += 1
				if (Time.get_ticks_usec() - ore_started) / 1000 >= ms_budget:
					break
			if _ore_index >= total:
				data.ores = OreLayer.collect_from_cache(_generator.seed_value, _generator.config, chunk)
				SpawnGuard.apply(_generator.seed_value, _generator.config, chunk, data)
				_ore_done = true
		if not _ore_done:
			return false
		# 黄金哈希是惰性的（ChunkHasher.chunk_hash 需要时才调用），生成热路径不算。
		done = true
		return true

	func _generate_obstacles() -> void:
		var generator := _generator
		var config := generator.config
		var obstacles: Array[Dictionary] = []
		var terrain_origin := GridMath.chunk_origin(chunk, config.chunk_size)
		var terrain_sampler := TerrainSampler.new(data.terrain, terrain_origin, config.chunk_size, _field)
		ObstacleLayer.generate(generator.seed_value, config, terrain_sampler, chunk, obstacles)
		data.obstacles = obstacles
		# 障碍层是一次性完成的（~10-25ms）。它不再分片，因为分片需要在候选点之间保存
		# occupied 表；把它压小的办法是减小 candidate 窗口（PAD_GRID），而不是切碎。
		# 矿脉：为 3×3 邻域 REGION 各建一个可切片 builder（已缓存的会立刻完成）。
		_ore_builders = []
		var region := GridMath.region_of_chunk(chunk, config.ore_region_chunks)
		for region_y in range(region.y - 1, region.y + 2):
			for region_x in range(region.x - 1, region.x + 2):
				var key := Vector2i(region_x, region_y)
				if OreLayer.cached_region(generator.seed_value, config, key).is_empty() and not OreLayer._region_cache.has(key):
					_ore_builders.append(OreLayer.RegionBuilder.new(
						generator.seed_value, config, key,
						func(cell: Vector2i) -> int: return generator.terrain_type_at(cell)
					))
		_ore_index = 0
		if _ore_builders.is_empty():
			data.ores = OreLayer.collect_from_cache(generator.seed_value, config, chunk)
			SpawnGuard.apply(generator.seed_value, config, chunk, data)
			_ore_done = true

	func finish() -> ChunkData:
		return data