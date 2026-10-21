class_name ChunkManager
extends Node
## 区块缓存、分帧按需生成、引用计数卸载、脏标记（§5）。
##
## 分工：
##   ChunkManager  只管"哪些块在内存里 / 哪些块要落盘 / 当前种子与版本"
##   WorldGenerator 纯函数生成（可以被它分帧驱动）
##   WorldObjects  物化进来的实体（materialize/dematerialize 成对）
##   SaveManager   全局态（pigs / visited_blocks / next_born_pig_index）+ 调用本类落盘
##
## 关键纪律：
## - ensure_radius 只在"中心块变化"时触发，不每帧扫描；
## - 卸载评估由 1s 定时器驱动；
## - 已加载区块的物化集合只增不减地按引用计数维护：卸载 A 不会删掉相邻 B 还要的跨区树；
## - 猪所在块永不被卸载；猪周围 pig_residency_radius_chunks 圈强制已生成。

signal chunk_ready(chunk: Vector2i)
signal chunk_unloaded(chunk: Vector2i)
signal generation_busy_changed(busy: bool)

const LOADING_LIMIT_PER_FRAME := 1

var config: WorldGenConfig
var generator: WorldGenerator
var world: WorldObjects
var cell_size: int = 36

## chunk -> {"data": ChunkData, "dirty": bool, "last_used": float, "materialized": bool}
var _chunks: Dictionary = {}
## FIFO 生成队列（Vector2i）
var _queue: Array[Vector2i] = []
## 正在分帧生成的 job
var _active_chunk: Variant = null
var _active_job: Variant = null
var _active_materialize := false

var _dirty_chunks: Dictionary = {}
var _materialize_queue: Array[Vector2i] = []
var _last_center := Vector2i(2147483647, 2147483647)
var _unload_clock := 0.0
var _seed_value: int = 0
var _worldgen_version: int = 1
var _pig_cells: Callable = Callable()
## 由 Main 注入的农田字典（cell -> plot）。overrides 里的 farm 条目要写回它。
var farm_plots: Dictionary = {}
var _ready := false
## 读档期间的"待惰性重生成"块（visited 但未加载）
var _pending_restore: Dictionary = {}
var _load_snapshot: Dictionary = {}
## 本会话内已经落过盘的 overrides（chunk -> overrides）。
## 块被卸载再加载时必须重新套用，否则"部分采集的矿 / 锤了一半的树 / 敲损的石头"
## 会在重新物化时被**生成基底**覆盖回去（静默丢档）。
var _live_overrides: Dictionary = {}
var _stats := {"generated": 0, "materialized": 0, "unloaded": 0, "queued": 0}


func setup(
	config_value: WorldGenConfig,
	seed_value: int,
	world_objects: WorldObjects,
	pig_cells: Callable = Callable()
) -> void:
	config = config_value
	_seed_value = seed_value
	_worldgen_version = config.worldgen_version
	generator = WorldGenerator.new(config, seed_value)
	world = world_objects
	_pig_cells = pig_cells
	_world_dirty_sink_bind()
	_ready = true


func _world_dirty_sink_bind() -> void:
	# WorldObjects 的所有 mutator 通过 chunk_dirty 信号通知这里（信号驱动，杜绝枚举遗漏）。
	if not world.chunk_dirty.is_connected(_on_cell_dirty):
		world.chunk_dirty.connect(_on_cell_dirty)
	world.dirty_sink = Callable()


func set_cell_size(size: int) -> void:
	cell_size = size


func get_seed() -> int:
	return _seed_value


func get_worldgen_version() -> int:
	return _worldgen_version


func _process(delta: float) -> void:
	if not _ready:
		return
	_drive_generation()
	_process_materialize_queue()
	_unload_clock += delta
	if _unload_clock >= config.unload_eval_seconds:
		_unload_clock = 0.0
		_evaluate_unload()


# ===== 对外查询 ========================================================

func is_loaded(chunk: Vector2i) -> bool:
	return _chunks.has(chunk)


func is_dirty(chunk: Vector2i) -> bool:
	return _dirty_chunks.has(chunk)


func dirty_count() -> int:
	return _dirty_chunks.size()


func loaded_count() -> int:
	return _chunks.size()


func stats() -> Dictionary:
	var copy := _stats.duplicate()
	copy["loaded"] = _chunks.size()
	copy["dirty"] = _dirty_chunks.size()
	copy["queued"] = _queue.size()
	copy["pending_restore"] = _pending_restore.size()
	return copy


func chunk_of_cell(cell: Vector2i) -> Vector2i:
	return GridMath.chunk_of_cell(cell, config.chunk_size)


func local_of_cell(cell: Vector2i, chunk: Vector2i = Vector2i(2147483647, 2147483647)) -> Vector2i:
	if chunk.x == 2147483647:
		chunk = chunk_of_cell(cell)
	return GridMath.local_of_cell(cell, chunk, config.chunk_size)


func get_chunk(chunk: Vector2i) -> ChunkData:
	if not _chunks.has(chunk):
		return null
	return _chunks[chunk]["data"] as ChunkData


## 地形查询。已加载直查；未加载**不同步生成**（§5.5 查询纪律），返回 -1。
func get_cell_terrain(cell: Vector2i) -> int:
	var chunk := chunk_of_cell(cell)
	if not _chunks.has(chunk):
		return -1
	var data: ChunkData = _chunks[chunk]["data"]
	var local := GridMath.local_of_cell(cell, chunk, config.chunk_size)
	return data.terrain[local.y * config.chunk_size + local.x]


## 是否"已知且不可通行"。未加载返回 false（寻路时视为可通过，避免生成雪崩）。
func is_cell_water(cell: Vector2i) -> bool:
	return get_cell_terrain(cell) == TerrainTypes.WATER


func get_cell_ore(cell: Vector2i) -> Dictionary:
	return world.get_ore(cell)


## 供 WorldObjects.is_blocked 用的地形判定：只挡"已加载且是水"的格。
func is_terrain_blocked(cell: Vector2i) -> bool:
	return is_cell_water(cell)


# ===== 加载 / 分帧 =====================================================

## 仅在中心块变化时触发（由 Main 调用；内部再去重）。
func ensure_radius(center_cell: Vector2i) -> void:
	var center := chunk_of_cell(center_cell)
	if center == _last_center:
		return
	_last_center = center
	# 镜头换块时丢弃旧镜头排队的待生成区块，避免旧队列把新 5×5 饿死；
	# 读档待恢复块必须保留，否则远处存档会永远不恢复。
	var preserved: Array[Vector2i] = []
	for queued in _queue:
		if _pending_restore.has(queued):
			preserved.append(queued)
	_queue.clear()
	for queued in preserved:
		_queue.append(queued)
	# 当前镜头所在块必须立刻可用，避免镜头跨块时整屏"未生成"底色；
	# 周围 5×5（ensure_radius_chunks=2）继续走分帧队列预生成。
	ensure_chunk_now(center)
	_enqueue_around(center, config.ensure_radius_chunks)
	_materialize_queue.clear()
	_queue_materialize_around(center, config.materialize_radius_chunks)
	_dematerialize_outside(center, config.materialize_radius_chunks)


## 5×5 的数据在 _chunks 里，但只把镜头附近 materialize_radius_chunks 物化到
## WorldObjects；物化也分帧，避免跨区块时一次把 9 块的树/矿塞进主线程。
func _queue_materialize_around(center: Vector2i, radius: int) -> void:
	for chunk_value in _chunks.keys():
		var chunk: Vector2i = chunk_value
		if maxi(absi(chunk.x - center.x), absi(chunk.y - center.y)) > radius:
			continue
		if bool(_chunks[chunk]["materialized"]):
			continue
		if not _materialize_queue.has(chunk):
			_materialize_queue.append(chunk)


func _process_materialize_queue() -> void:
	if _materialize_queue.is_empty():
		return
	var chunk: Vector2i = _materialize_queue.pop_front()
	if not _chunks.has(chunk):
		return
	if not bool(_chunks[chunk]["materialized"]):
		_materialize(chunk, _chunks[chunk]["data"])


func _dematerialize_outside(center: Vector2i, radius: int) -> void:
	for chunk_value in _chunks.keys():
		var chunk: Vector2i = chunk_value
		if maxi(absi(chunk.x - center.x), absi(chunk.y - center.y)) <= radius:
			continue
		if not bool(_chunks[chunk]["materialized"]):
			continue
		if bool(_chunks[chunk]["dirty"]):
			# 玩家改动过的块先落盘，避免去物化吞掉 delta。
			var flush_result := flush_chunk(chunk)
			if not bool(flush_result.get("ok", false)):
				continue
		world.dematerialize_chunk(chunk)
		_chunks[chunk]["materialized"] = false


## 强制立即确保一块（不进入队列）：读档/寻路规划前同步用。
func ensure_chunk_now(chunk: Vector2i) -> ChunkData:
	if _chunks.has(chunk):
		_chunks[chunk]["last_used"] = Time.get_ticks_msec() / 1000.0
		if not bool(_chunks[chunk]["materialized"]):
			_materialize(chunk, _chunks[chunk]["data"])
		return _chunks[chunk]["data"]
	var data := generator.generate_chunk(chunk)
	_register_chunk(chunk, data)
	_materialize(chunk, data)
	return data


## 把一块加进队列（去重）。
func request_chunk(chunk: Vector2i) -> void:
	if _chunks.has(chunk) or _queue.has(chunk):
		return
	_queue.append(chunk)


func _enqueue_around(center: Vector2i, radius: int) -> void:
	# 由近及远入队，保证最近的块先物化（玩家肉眼可见的地方优先）。
	for ring in range(0, radius + 1):
		for offset_y in range(-ring, ring + 1):
			for offset_x in range(-ring, ring + 1):
				if maxi(absi(offset_x), absi(offset_y)) != ring:
					continue
				request_chunk(center + Vector2i(offset_x, offset_y))


func _drive_generation() -> void:
	# 猪驻留：猪所在块必须常驻且已生成（路径规划前不逐格兜底）。
	if _pig_cells.is_valid():
		for chunk_value in _pig_cells.call():
			var chunk: Vector2i = chunk_value
			if not _chunks.has(chunk) and not _queue.has(chunk):
				_queue.push_front(chunk)

	# 预热队列优先级低于正式生成，但会在空闲帧里消化掉。
	_process_region_queue(2)
	if _active_job == null:
		while not _queue.is_empty():
			var next: Vector2i = _queue.pop_front()
			if _chunks.has(next):
				continue
			_active_chunk = next
			_active_job = generator.make_job(next)
			_active_materialize = (
				maxi(absi(next.x - _last_center.x), absi(next.y - _last_center.y))
				<= config.materialize_radius_chunks
			)
			break
		if _active_job == null:
			return

	var budget_ms := int(maxf(1.0, config.gen_ms_per_frame))
	var finished: bool = _active_job.step(config.gen_rows_per_slice, budget_ms)
	if finished:
		var data: ChunkData = _active_job.finish()
		var chunk: Vector2i = _active_chunk
		_register_chunk(chunk, data)
		if _active_materialize:
			_materialize(chunk, data)
		_active_job = null
		_active_chunk = null
		warm_ore_regions(chunk)
		chunk_ready.emit(chunk)
		generation_busy_changed.emit(not _queue.is_empty())


func _register_chunk(chunk: Vector2i, data: ChunkData) -> void:
	_chunks[chunk] = {
		"data": data,
		"dirty": false,
		"last_used": Time.get_ticks_msec() / 1000.0,
		"materialized": false,
	}
	_stats["generated"] = int(_stats["generated"]) + 1
	# 读档时该块可能有 overrides 待应用（此时还没有物化，正好按基底+差分建表）。
	if _load_snapshot.has(chunk):
		var payload: Dictionary = _load_snapshot[chunk]
		_load_snapshot.erase(chunk)
		_pending_restore[chunk] = payload


## 预热本块 3×3 邻域 REGION 的矿脉（纯函数、可切片；已缓存的直接跳过）。
## 这样做是为了让"下一块"的矿脉查询命中缓存，避免单帧出现 200ms 级尖峰。
func warm_ore_regions(chunk: Vector2i) -> void:
	var region := GridMath.region_of_chunk(chunk, config.ore_region_chunks)
	for region_y in range(region.y - 1, region.y + 2):
		for region_x in range(region.x - 1, region.x + 2):
			var key := Vector2i(region_x, region_y)
			if OreLayer.cached_region(_seed_value, config, key).is_empty() and not OreLayer._region_cache.has(key):
				_queue_region(key)


## 待预热的 REGION（由 _drive_generation 分帧消耗）。
var _region_queue: Array[Vector2i] = []
## 当前正在推进的预热 builder（跨帧保留，避免每帧重头开始）。
var _region_builder: Variant = null


func _queue_region(region: Vector2i) -> void:
	if not _region_queue.has(region):
		_region_queue.append(region)


## 预热队列。**预算在 builder 内部就生效**：一个 REGION 只有 ~50 条脉，
## 之前"整块 REGION 跑完再检查预算"会超 5 倍（实测 11ms vs 2ms 预算）。
func _process_region_queue(budget_ms: int) -> bool:
	if _region_queue.is_empty():
		return false
	var started := Time.get_ticks_usec()
	while not _region_queue.is_empty():
		var region: Vector2i = _region_queue[0]
		if _region_builder == null:
			_region_builder = OreLayer.RegionBuilder.new(
				_seed_value, config, region,
				func(cell: Vector2i) -> int: return generator.terrain_type_at(cell)
			)
		# 每次最多 2 条脉 + 毫秒闸门，两者都在 builder 里生效。
		var remaining_ms := maxi(0, budget_ms - (Time.get_ticks_usec() - started) / 1000)
		var finished: bool = _region_builder.step(2, remaining_ms)
		if finished:
			_region_builder = null
			_region_queue.pop_front()
		if (Time.get_ticks_usec() - started) / 1000 >= budget_ms:
			break
	return not _region_queue.is_empty()


func _materialize(chunk: Vector2i, data: ChunkData) -> void:
	if not _chunks.has(chunk) or _chunks[chunk]["materialized"]:
		return
	var trees: Array = []
	var ores: Array = []
	var blocks: Array = []
	for obstacle in data.obstacles:
		var kind := int(obstacle["kind"])
		if kind == ChunkData.KIND_TREE:
			trees.append(obstacle)
		else:
			blocks.append(obstacle)
	ores = data.ores
	world.materialize_chunk(chunk, config.chunk_size, config.chunk_radius, trees, ores, blocks)
	_chunks[chunk]["materialized"] = true
	_stats["materialized"] = int(_stats["materialized"]) + 1
	# 读档的待恢复 payload 优先；其次是本会话内已落过盘的 overrides（卸载→重载）。
	if _pending_restore.has(chunk):
		var payload: Dictionary = _pending_restore[chunk]
		_pending_restore.erase(chunk)
		apply_overrides(chunk, payload)
		chunk_ready.emit(chunk)
	elif _live_overrides.has(chunk):
		var live: Dictionary = _live_overrides[chunk]
		apply_overrides(chunk, {"worldgen_version": _worldgen_version, "overrides": live})
		chunk_ready.emit(chunk)


# ===== 脏标记 ==========================================================

func _on_cell_dirty(cell: Vector2i) -> void:
	var chunk := chunk_of_cell(cell)
	mark_chunk_dirty(chunk)


func mark_chunk_dirty(chunk: Vector2i) -> void:
	_dirty_chunks[chunk] = true
	if _chunks.has(chunk):
		_chunks[chunk]["dirty"] = true


func mark_cell_dirty(cell: Vector2i) -> void:
	mark_chunk_dirty(chunk_of_cell(cell))


func clear_dirty() -> void:
	_dirty_chunks.clear()
	for key in _chunks.keys():
		_chunks[key]["dirty"] = false


func dirty_chunks() -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for key in _dirty_chunks.keys():
		out.append(key)
	return out


# ===== 卸载 ============================================================

func _evaluate_unload() -> void:
	var keep := config.keep_radius_chunks
	var center: Vector2i = _last_center
	var resident := {}
	if _pig_cells.is_valid():
		for chunk_value in _pig_cells.call():
			var pig_chunk: Vector2i = chunk_value
			for offset_y in range(-config.pig_residency_radius_chunks, config.pig_residency_radius_chunks + 1):
				for offset_x in range(-config.pig_residency_radius_chunks, config.pig_residency_radius_chunks + 1):
					resident[pig_chunk + Vector2i(offset_x, offset_y)] = true
	for chunk_value in _chunks.keys():
		var chunk: Vector2i = chunk_value
		if resident.has(chunk) or chunk == center:
			continue
		var distance := maxi(absi(chunk.x - center.x), absi(chunk.y - center.y))
		if distance <= keep:
			continue
		unload_chunk(chunk)


## 卸载一块：先把脏块落盘（卸载即冻结计时语义），再 dematerialize。
func unload_chunk(chunk: Vector2i) -> void:
	if not _chunks.has(chunk):
		return
	_materialize_queue.erase(chunk)
	if _chunks[chunk]["dirty"]:
		var result := flush_chunk(chunk)
		if not bool(result.get("ok", false)):
			push_error("ChunkManager: 卸载前落盘失败 %s" % str(chunk))
	if _chunks.has(chunk) and _chunks[chunk]["materialized"]:
		world.dematerialize_chunk(chunk)
	_chunks.erase(chunk)
	_dirty_chunks.erase(chunk)
	_stats["unloaded"] = int(_stats["unloaded"]) + 1
	chunk_unloaded.emit(chunk)


# ===== overrides 应用 / 落盘 ===========================================

## 把一块的 overrides 应用到活体状态（读档 & 惰性恢复都走这里）。
## 把一块的 overrides 应用到活体状态。
## **前提**：调用时该块的物化状态是"刚由生成基底物化出来"的（ensure_chunk_now 之后）。
## 若块里已经有活体改动，必须先 dematerialize + 重新物化，否则会重复扣减（mined 会越扣越多）。
func apply_overrides(chunk: Vector2i, payload: Dictionary) -> void:
	var overrides: Dictionary = payload.get("overrides", {})
	var version := int(payload.get("worldgen_version", _worldgen_version))
	var _unused := version

	for entry in overrides.get("removed_ores", []):
		world.remove_ore(ChunkStore.decode_cell(entry))
	for key in overrides.get("mined", {}).keys():
		var cell := ChunkStore.parse_cell_key(str(key))
		var mined := int(overrides["mined"][key])
		if world.has_ore(cell):
			world.hit_ore(cell, mined)
	for entry in overrides.get("chopped_trees", []):
		var root := ChunkStore.decode_cell(entry)
		if world.tree_roots.has(root):
			# 读档时"已砍掉"的树不应触发 chunk_dirty 之外的语义，直接删表即可。
			world.remove_tree(root)
	for key in overrides.get("tree_hits", {}).keys():
		var root := ChunkStore.parse_cell_key(str(key))
		if world.tree_roots.has(root):
			world._tree_hits[root] = int(overrides["tree_hits"][key])
	for entry in overrides.get("planted_trees", []):
		var root := ChunkStore.decode_cell(entry.get("root", [0, 0]))
		if not world.tree_roots.has(root):
			world.add_tree(root, int(entry.get("hits", 0)))
	for entry in overrides.get("removed_naturals", []):
		world.remove_natural_block(ChunkStore.decode_cell(entry))
	for key in overrides.get("natural_hits", {}).keys():
		var cell := ChunkStore.parse_cell_key(str(key))
		if world.has_natural_block(cell):
			var block: Dictionary = world.natural_blocks[cell]
			block["hp"] = int(overrides["natural_hits"][key])
			world.natural_blocks[cell] = block
			world._index_add_cell(cell, "natural", int(block["hp"]))
	for key in overrides.get("natural_stones", {}).keys():
		var cell := ChunkStore.parse_cell_key(str(key))
		if world.has_natural_block(cell):
			var block: Dictionary = world.natural_blocks[cell]
			block["stone"] = int(overrides["natural_stones"][key])
			world.natural_blocks[cell] = block
	for entry in overrides.get("logs", []):
		world.place_log(ChunkStore.decode_cell(entry))
	for entry in overrides.get("planks", []):
		world.place_plank(ChunkStore.decode_cell(entry))
	for entry in overrides.get("fences", []):
		world.place_fence(ChunkStore.decode_cell(entry))
	var needs_reindex := false
	for entry in overrides.get("placed_blocks", []):
		var cell := ChunkStore.decode_cell(entry.get("cell", [0, 0]))
		world.placed_blocks[cell] = str(entry.get("kind", "stone"))
		world._index_add_cell(cell, "block")
		needs_reindex = true
	for entry in overrides.get("furnaces", []):
		var cell := ChunkStore.decode_cell(entry.get("cell", [0, 0]))
		world.furnaces[cell] = {
			"inventory": SaveCodec.decode_inventory(entry.get("inventory", {}), 3),
			"burn_remaining": float(entry.get("burn_remaining", 0.0)),
			"burn_total": float(entry.get("burn_total", 0.0)),
			"smelt_progress": float(entry.get("smelt_progress", 0.0)),
		}
		world._bind_container_dirty(cell, world.furnaces[cell]["inventory"])
		world._index_add_cell(cell, "furnace")
		needs_reindex = true
	for entry in overrides.get("machines", []):
		var cell := ChunkStore.decode_cell(entry.get("cell", [0, 0]))
		var machine_type := str(entry.get("type", ""))
		if not WorldObjects.MACHINE_TYPES.has(machine_type):
			continue
		world.machines[cell] = {
			"type": machine_type,
			"pig": SaveCodec.decode(entry.get("pig", {})),
			"power": float(entry.get("power", 0.0)),
			"progress": float(entry.get("progress", 0.0)),
			"output": SaveCodec.decode(entry.get("output", {})),
			"power_accum": float(entry.get("power_accum", 0.0)),
		}
		world._index_add_cell(cell, "machine")
		needs_reindex = true
	for entry in overrides.get("chests", []):
		var cell := ChunkStore.decode_cell(entry.get("cell", [0, 0]))
		if not world.has_chest(cell):
			world.chests[cell] = SaveCodec.decode_inventory(entry.get("inventory", {}))
			world._bind_container_dirty(cell, world.chests[cell])
			needs_reindex = true
	for entry in overrides.get("saplings", []):
		var cell := ChunkStore.decode_cell(entry.get("cell", [0, 0]))
		world.saplings[cell] = {
			"stage": int(entry.get("stage", 0)),
			"elapsed": float(entry.get("elapsed", 0.0)),
			"mature_root": ChunkStore.decode_cell(
				entry.get("mature_root", [cell.x - 1, cell.y - 1]),
				cell - WorldObjects.SAPLING_CENTER_OFFSET
			),
			"mature_hp": int(entry.get("mature_hp", 0)),
		}
		needs_reindex = true
	# 农田地块：overrides 里按格归属，读档/惰性恢复时写回 Main 的 farm.plots。
	for entry in overrides.get("farm", []):
		var plot_cell := ChunkStore.decode_cell(entry.get("cell", [0, 0]))
		farm_plots[plot_cell] = {
			"crop_id": str(entry.get("crop_id", "")),
			"stage": int(entry.get("stage", 0)),
			"elapsed": float(entry.get("elapsed", 0.0)),
		}
	for entry in overrides.get("nests", []):
		var root := ChunkStore.decode_cell(entry.get("root", [0, 0]))
		world.nests[root] = {
			"root": root,
			"inventory": SaveCodec.decode_inventory(entry.get("inventory", {}), 4),
			"progress": float(entry.get("progress", 0.0)),
			"active": bool(entry.get("active", false)),
		}
		world._bind_container_dirty(root, world.nests[root]["inventory"])
		needs_reindex = true
	if needs_reindex:
		world.rebuild_indexes()
	# 关键：把**已经应用过的差分**记进 _live_overrides。
	# 否则这块一旦被卸载再重载，物化会从生成基底重建，玩家挖掉/敲掉的进度就回退了
	# （而且下一次 flush 会以「新的基底」重新算差分，把损伤越写越少）。
	var applied: Dictionary = overrides.duplicate(true)
	applied.erase("pigs")
	if ChunkStore.is_empty(applied):
		_live_overrides.erase(chunk)
	else:
		_live_overrides[chunk] = applied
	_pending_restore.erase(chunk)
	_dirty_chunks.erase(chunk)
	if _chunks.has(chunk):
		_chunks[chunk]["dirty"] = false


## 生成一块的 overrides 并写盘（空 → 删文件）。返回写盘结果。
## plots 省略时用注入的 farm_plots（Main 的 farm.plots）。
func flush_chunk(chunk: Vector2i, plots: Dictionary = {}) -> Dictionary:
	var data := get_chunk(chunk)
	if data == null:
		# 不能假装成功：调用方（SaveManager）会因此 clear_dirty 而永久丢掉这块的改动。
		return {"ok": false, "skipped": true, "message": "区块 %s 未加载，无法生成差分" % str(chunk)}
	var effective_plots := plots if not plots.is_empty() else farm_plots
	var overrides := ChunkStore.build_overrides(
		world, data, chunk, config.chunk_size, config.chunk_radius, effective_plots
	)
	var result := ChunkStore.write_block(chunk, _worldgen_version, overrides)
	if bool(result.get("ok", false)):
		_dirty_chunks.erase(chunk)
		if _chunks.has(chunk):
			_chunks[chunk]["dirty"] = false
		# 记住最近一次落盘的差分：卸载后重新生成时必须套用（而不是相信生成基底）。
		if ChunkStore.is_empty(overrides):
			_live_overrides.erase(chunk)
		else:
			_live_overrides[chunk] = overrides.duplicate(true)
	return result


## 读档：把所有块 payload 先登记为"待应用"，等各自区块生成/物化后套用。
func prime_restore(payloads: Dictionary) -> void:
	_load_snapshot = payloads.duplicate()


func has_pending_restore() -> bool:
	return not _pending_restore.is_empty() or not _load_snapshot.is_empty()


## 读档顺序：只急切恢复中心附近 N 块，其余走同一条分帧管线（§7.3）。
func resume_load(center_cell: Vector2i) -> void:
	var center := chunk_of_cell(center_cell)
	_last_center = Vector2i(2147483647, 2147483647)
	# 待恢复的块先入队（近的优先）。
	var radius := config.eager_load_radius_chunks
	for payload_chunk in _load_snapshot.keys():
		var chunk: Vector2i = payload_chunk
		var distance := maxi(absi(chunk.x - center.x), absi(chunk.y - center.y))
		if distance <= radius:
			_queue.push_front(chunk)
	for payload_chunk in _load_snapshot.keys():
		var chunk: Vector2i = payload_chunk
		_pending_restore[chunk] = _load_snapshot[chunk]
	_load_snapshot.clear()
	ensure_radius(center_cell)


## 一次性同步恢复（测试用：不走分帧，直接生成+套用）。
func restore_now() -> void:
	for chunk_value in _pending_restore.keys():
		var chunk: Vector2i = chunk_value
		ensure_chunk_now(chunk)
		if _pending_restore.has(chunk):
			apply_overrides(chunk, _pending_restore[chunk])


func clear_all() -> void:
	for chunk_value in _chunks.keys():
		var chunk: Vector2i = chunk_value
		if _chunks[chunk]["materialized"]:
			world.dematerialize_chunk(chunk)
	_chunks.clear()
	_dirty_chunks.clear()
	_queue.clear()
	_materialize_queue.clear()
	_pending_restore.clear()
	_load_snapshot.clear()
	_live_overrides.clear()
	_active_job = null
	_active_chunk = null
	generator.clear_caches()