class_name OreLayer
extends RefCounted
## 矿脉层：REGION 内的确定性随机游走矿脉，支持跨区块 / 跨 REGION 连续。
##
## 规则（docs/worldgen.md §6）：
## 1. REGION = region_chunks × region_chunks 个区块。某区块的矿脉来源 = 本 REGION
##    + 相邻 8 个 REGION（3×3 邻域），否则 REGION 边界会系统性漏脉。
## 2. 每 REGION 脉数 = 纯整数均匀取样（不用浮点泊松）。
## 3. 每条脉的 id / 类型 / 锚点 / 目标大小由派生流确定；形状 = 确定性随机游走。
## 4. 两脉重叠：vein_id 数值小者占优（确定性 tie-break，与生成顺序无关）。
## 5. 地形过滤：落在 WATER 的格剔除；剔除后**整条脉**剩余格数 < min_vein_cells 才丢弃。
## 6. 每格 amount = 本脉独立派生流取样，无单格碎矿。
##
## REGION 级缓存：物化一个新块时相邻 8 个 REGION 通常已算过，命中率 ~90%。
## 缓存只按 (seed, version, region) 索引，是纯函数结果的记忆化，不引入顺序依赖。
## 构建过程是**可切片状态机**（chunk_region()）：完成前不写缓存，且不依赖调用顺序。

const SALT_OFFSET_COUNT := 101
const SALT_OFFSET_VEIN := 211
const SALT_OFFSET_WALK := 307
const SALT_OFFSET_SIZE := 503
const SALT_OFFSET_AMOUNT := 601

const DIRECTION_PAIRS := 8

static var _region_cache: Dictionary = {}
static var _cache_seed: int = 0
static var _cache_version: int = 0
## 矿脉相关配置的指纹。只按 (seed, worldgen_version) 索引是不够的：
## 调 vein_count/types/min_vein_cells 而不 bump version（文档里描述的调参流程）
## 会命中旧 config 生成的脉 → 同一 (seed, version, config, chunk) 出现两个哈希。
static var _cache_config_key: int = 0
static var _cache_hits: int = 0
static var _cache_misses: int = 0


static func reset_cache() -> void:
	_region_cache.clear()
	_cache_seed = 0
	_cache_version = 0
	_cache_config_key = 0
	_cache_hits = 0
	_cache_misses = 0


static func cache_stats() -> Dictionary:
	return {"hits": _cache_hits, "misses": _cache_misses, "regions": _region_cache.size()}


static func cache_stats_print() -> void:
	var stats := cache_stats()
	print("[ore] region cache: hits=%d misses=%d regions=%d" % [stats["hits"], stats["misses"], stats["regions"]])


## 把影响矿脉生成的每个配置项都折进指纹（新增字段时记得加进来）。
static func config_fingerprint(config: WorldGenConfig) -> int:
	var parts := PackedStringArray([
		str(config.ore_salt),
		str(config.ore_region_chunks),
		str(config.vein_count_min),
		str(config.vein_count_max),
		str(config.min_vein_cells),
		str(config.vein_total_amount_min),
		str(config.vein_total_amount_max),
		str(config.depth_bias_radius_cells),
		str(config.worldgen_version),
	])
	for entry in config.ore_types:
		parts.append("%s/%d/%d/%d/%d/%d/%d" % [
			str(entry["id"]), int(entry["weight"]), int(entry["depth_bias_millis"]),
			int(entry["vein_size_min"]), int(entry["vein_size_max"]),
			int(entry["min_cell_amount"]), int(entry["max_cell_amount"]),
		])
	return SeedSystem.fnv1a64("|".join(parts))


static func _ensure_cache_owner(seed_value: int, config: WorldGenConfig) -> void:
	var fingerprint := config_fingerprint(config)
	if (
		_cache_seed != seed_value
		or _cache_version != config.worldgen_version
		or _cache_config_key != fingerprint
	):
		reset_cache()
		_cache_seed = seed_value
		_cache_version = config.worldgen_version
		_cache_config_key = fingerprint


## 已缓存的 REGION 矿脉；未缓存返回空数组（不触发生成）。
static func cached_region(seed_value: int, config: WorldGenConfig, region: Vector2i) -> Array:
	_ensure_cache_owner(seed_value, config)
	if _region_cache.has(region):
		return _region_cache[region]
	return []


## 同步取得一个 REGION 的矿脉（会先切片跑完）。
static func region_veins(seed_value: int, config: WorldGenConfig, region: Vector2i, terrain_query: Callable) -> Array:
	var cached := cached_region(seed_value, config, region)
	if not cached.is_empty() or _region_cache.has(region):
		return cached
	_cache_misses += 1
	var builder := RegionBuilder.new(seed_value, config, region, terrain_query)
	while not builder.step(1 << 30, 1 << 30):
		pass
	_region_cache[region] = builder.veins
	return builder.veins


## 收集某个区块内应有的矿点（遍历 3×3 邻域 REGION，重建全脉，取 ∩ 本块）。
static func collect_chunk(
	seed_value: int,
	config: WorldGenConfig,
	chunk: Vector2i,
	terrain_query: Callable
) -> Array[Dictionary]:
	var region := GridMath.region_of_chunk(chunk, config.ore_region_chunks)
	for region_y in range(region.y - 1, region.y + 2):
		for region_x in range(region.x - 1, region.x + 2):
			region_veins(seed_value, config, Vector2i(region_x, region_y), terrain_query)
	return collect_from_cache(seed_value, config, chunk)


## 只用当前缓存里的 REGION 收集本块矿点（缺失的 REGION 视为无脉）。
static func collect_from_cache(seed_value: int, config: WorldGenConfig, chunk: Vector2i) -> Array[Dictionary]:
	var size := config.chunk_size
	var origin := GridMath.chunk_origin(chunk, size)
	var region := GridMath.region_of_chunk(chunk, config.ore_region_chunks)
	var found := {}
	for region_y in range(region.y - 1, region.y + 2):
		for region_x in range(region.x - 1, region.x + 2):
			var key := Vector2i(region_x, region_y)
			if not _region_cache.has(key):
				continue
			_cache_hits += 1
			var veins: Array = _region_cache[key]
			for vein in veins:
				var ore_id := int(vein["ore_id"])
				var vein_id := int(vein["vein_id"])
				var cells: Array = vein["cells"]
				var amounts: Array = vein["amounts"]
				for index in cells.size():
					var cell: Vector2i = cells[index]
					if (
						cell.x >= origin.x and cell.x < origin.x + size
						and cell.y >= origin.y and cell.y < origin.y + size
					):
						var existing: Variant = found.get(cell)
						if existing == null or int(existing["vein_id"]) > vein_id:
							found[cell] = {
								"cell": cell,
								"ore_id": ore_id,
								"amount": int(amounts[index]),
								"vein_id": vein_id,
							}
	var out: Array[Dictionary] = []
	for key in found.keys():
		out.append(found[key])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ca: Vector2i = a["cell"]
		var cb: Vector2i = b["cell"]
		if ca.y != cb.y:
			return ca.y < cb.y
		if ca.x != cb.x:
			return ca.x < cb.x
		return int(a["ore_id"]) < int(b["ore_id"])
	)
	return out


## 一个 REGION 的矿脉构建器：逐条脉推进，可被 ChunkJob 按时间预算切片。
class RegionBuilder:
	extends RefCounted

	var region: Vector2i
	var veins: Array = []
	var done := false

	var _seed: int
	var _config: WorldGenConfig
	var _terrain_query: Callable
	var _total: int = 0
	var _next_index: int = 0
	var _origin: Vector2i
	var _span: int = 0
	var _owner: Dictionary = {}
	var _salt: int = 0

	func _init(seed_value: int, config: WorldGenConfig, region_in: Vector2i, terrain_query: Callable) -> void:
		_seed = seed_value
		_config = config
		_terrain_query = terrain_query
		region = region_in
		_salt = config.ore_salt
		_origin = GridMath.region_origin_cell(region, config.ore_region_chunks, config.chunk_size)
		_span = config.chunk_size * config.ore_region_chunks
		var roll := SeedSystem.hash2(seed_value, _salt + SALT_OFFSET_COUNT, region.x, region.y)
		var count_span := config.vein_count_max - config.vein_count_min + 1
		_total = config.vein_count_min + int(SeedSystem.ushr(roll, 11) % count_span)

	## 推进 max_veins 条脉或 ms_budget 毫秒。返回 true 表示整个 REGION 完成。
	func step(max_veins: int, ms_budget: int) -> bool:
		if done:
			return true
		var started := Time.get_ticks_usec()
		var processed := 0
		while _next_index < _total:
			_build_vein(_next_index)
			_next_index += 1
			processed += 1
			if processed >= max_veins:
				break
			if (Time.get_ticks_usec() - started) / 1000 >= ms_budget:
				break
		if _next_index >= _total:
			done = true
			# 内嵌类不能直接写外部类的 static var，必须显式限定。
			OreLayer._cache_misses += 1
			OreLayer._region_cache[region] = veins
		return done

	func _build_vein(vein_index: int) -> void:
		var salt := _salt
		var vein_id := SeedSystem.hash2(
			_seed,
			salt + SALT_OFFSET_VEIN,
			region.x * 4096 + (vein_index % 4096),
			region.y * 4096 + (vein_index / 4096)
		)
		var stream := SeedSystem.rng_at_id(_seed, salt + SALT_OFFSET_WALK, vein_id)
		var ore_type := _pick_type(stream)
		if ore_type.is_empty():
			return
		var size_span := int(ore_type["vein_size_max"]) - int(ore_type["vein_size_min"]) + 1
		var target_size := int(ore_type["vein_size_min"]) + stream.next_below(size_span)
		if target_size < _config.min_vein_cells:
			return
		var anchor := Vector2i(
			_origin.x + stream.next_below(_span),
			_origin.y + stream.next_below(_span)
		)
		var cells := _walk(vein_id, anchor, target_size)
		if cells.is_empty():
			return
		var kept: Array[Vector2i] = []
		for cell in cells:
			var existing: Variant = _owner.get(cell)
			if existing == null or int(existing) > vein_id:
				_owner[cell] = vein_id
				kept.append(cell)
		if kept.size() < _config.min_vein_cells:
			return
		var walkable: Array[Vector2i] = []
		for cell in kept:
			if TerrainTypes.is_walkable(int(_terrain_query.call(cell))):
				walkable.append(cell)
		if walkable.size() < _config.min_vein_cells:
			return
		var min_amount := int(ore_type["min_cell_amount"])
		var amount_span := int(ore_type["max_cell_amount"]) - min_amount + 1
		var amounts: Array = []
		var amount_stream := SeedSystem.rng_at_id(_seed, salt + SALT_OFFSET_AMOUNT, vein_id)
		if _config.vein_total_amount_min > 0:
			# 大矿脉：每条脉总矿量至少 50,000，按格子均分（余数给前几格），
			# 保证整条脉的 amount 求和落在配置区间内。
			var total_span := _config.vein_total_amount_max - _config.vein_total_amount_min + 1
			var total_amount := _config.vein_total_amount_min + amount_stream.next_below(total_span)
			var base_amount := int(total_amount / walkable.size())
			var remainder := total_amount % walkable.size()
			for index in walkable.size():
				amounts.append(base_amount + (1 if index < remainder else 0))
		else:
			for _cell in walkable.size():
				amounts.append(min_amount + amount_stream.next_below(amount_span))
		veins.append({
			"vein_id": vein_id,
			"ore_id": int(ore_type["ore_id"]),
			"cells": walkable,
			"amounts": amounts,
		})

	## depth_bias：离出生点越远，高价值矿权重越高（定点，无浮点随机）。
	func _pick_type(stream: SeedSystem.Stream) -> Dictionary:
		var config := _config
		if config.ore_types.is_empty():
			return {}
		var center := _origin + Vector2i(_span / 2, _span / 2)
		var distance := maxi(absi(center.x), absi(center.y))
		var depth_q := clampi((distance * 1000) / config.depth_bias_radius_cells, 0, 1000)
		var total := 0
		var weights: Array = []
		for entry in config.ore_types:
			var bias := int(entry["depth_bias_millis"])
			var weight := int(entry["weight"])
			var adjusted := (weight * (1000 + (bias * depth_q) / 1000)) / 1000
			adjusted = maxi(1, adjusted)
			weights.append(adjusted)
			total += adjusted
		if total <= 0:
			return {}
		var pick := stream.next_below(total)
		var running := 0
		for index in config.ore_types.size():
			running += weights[index]
			if pick < running:
				return config.ore_types[index]
		return config.ore_types[config.ore_types.size() - 1]

	## 确定性随机游走：8 方向 + 1/4 停留，撞到自己就跳过（步数不减）。
	func _walk(vein_id: int, anchor: Vector2i, target_size: int) -> Array[Vector2i]:
		var stream := SeedSystem.rng_at_id(_seed, _salt + SALT_OFFSET_WALK, vein_id)
		var cells: Array[Vector2i] = [anchor]
		var seen := {anchor: true}
		var current := anchor
		var guard := target_size * 8 + 16
		var steps := 0
		while cells.size() < target_size and steps < guard:
			steps += 1
			var move := stream.next_below(DIRECTION_PAIRS + 2)
			if move >= DIRECTION_PAIRS:
				continue
			var direction := Vector2i(
				[1, -1, 0, 0, 1, 1, -1, -1][move],
				[0, 0, 1, -1, 1, -1, 1, -1][move]
			)
			var next_cell := current + direction
			if seen.has(next_cell):
				continue
			seen[next_cell] = true
			cells.append(next_cell)
			current = next_cell
		return cells