class_name WorldGenConfig
extends RefCounted
## config/worldgen.json 的类型化读取器。
##
## 纪律：世界生成内部**不出现浮点随机**。所有概率/阈值/密度在配置里以"毫单位"或
## 定点整数表达；浮点只允许出现在调试可视化与 UI。
##
## 关于候选格点（obstacle/eco 共用）：
##   为了把 255×255=65025 格的逐格哈希压到一次 64×64 的扫描，障碍/生态层在
##   step=cell_chunk_cells 的**粗网格**上取样，每个格点最多产出 1 棵树 / 1 块石头 /
##   1 丛灌木。因此配置里的 *_chance_millis 是"每个候选点的千分概率"，
##   折算到每格概率 = chance_millis / 1000 / step²。

const CONFIG_PATH := "res://config/worldgen.json"

var worldgen_version: int = 1
var chunk_size: int = 255
var chunk_radius: int = 127
var spawn_safe_radius_cells: int = 24
var spawn_reserved_cells: Array[Vector2i] = []
var spawn_reserved_footprints: Array[Dictionary] = []

var gen_ms_per_frame: float = 8.0
var gen_rows_per_slice: int = 32
var ensure_radius_chunks: int = 1
var keep_radius_chunks: int = 2
## 5×5 只保证数据预生成；只有这个半径内的区块物化到 WorldObjects，
## 避免 25×255² 的树/矿全部进入绘制与索引。
var materialize_radius_chunks: int = 1
var pig_residency_radius_chunks: int = 1
var unload_eval_seconds: float = 1.0
var eager_load_radius_chunks: int = 1

var bench_chunk_count: int = 100
var bench_avg_ms_max: float = 60.0
var bench_p99_ms_max: float = 150.0

var terrain_salt: int = 0
var terrain_noise_scale_q16: int = 1180
var terrain_octaves: int = 2
var terrain_water_millis: int = 300
var terrain_sand_millis: int = 360
var terrain_dirt_millis: int = 460

var eco_salt: int = 0
var tuft_chance_millis: int = 0
var flower_chance_millis: int = 0
var bush_chance_millis: int = 64
var bush_hp: int = 1

var obstacle_salt: int = 0
var obstacle_cell_chunk_cells: int = 8
var tree_chance_millis: int = 384
var rock_chance_millis: int = 256
var rock_hp_min: int = 1
var rock_hp_max: int = 2
var stone_chance_millis: int = 56
var stone_hp_min: int = 6
var stone_hp_max: int = 10
var stone_amount_min: int = 16
var stone_amount_max: int = 30
var tree_hp_min: int = 3
var tree_hp_max: int = 5
var tree_footprint: int = 3
var tree_ground_pad_millis: int = 640

var ore_salt: int = 0
var ore_region_chunks: int = 4
var vein_count_min: int = 32
var vein_count_max: int = 64
var min_vein_cells: int = 3
## 每条矿脉的总矿量区间；>0 时覆盖旧的每格 min/max_cell_amount。
var vein_total_amount_min: int = 0
var vein_total_amount_max: int = 0
var ore_types: Array[Dictionary] = []
var ore_total_weight: int = 0
var depth_bias_radius_cells: int = 600


static func load_default() -> WorldGenConfig:
	var config := WorldGenConfig.new()
	config._apply_defaults()
	if not FileAccess.file_exists(CONFIG_PATH):
		push_error("WorldGen: 缺少配置文件 %s，使用内置默认值。" % CONFIG_PATH)
		return config
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
	if not (parsed is Dictionary):
		push_error("WorldGen: 配置文件无法解析，使用内置默认值。")
		return config
	config.apply_dict(parsed)
	return config


func apply_dict(source: Dictionary) -> void:
	worldgen_version = int(source.get("worldgen_version", worldgen_version))
	chunk_size = int(source.get("chunk_size", chunk_size))
	# chunk_radius 必须由 chunk_size 推导，不能是独立的第二个事实来源：
	# TerrainLayer / ChunkStore / WorldObjects 读它，而 GridMath 用 (size-1)/2。
	# 两者一旦不一致，地形窗口和存档差分会整体错位。
	chunk_radius = (chunk_size - 1) / 2
	var configured_radius := int(source.get("chunk_radius", chunk_radius))
	if configured_radius != chunk_radius:
		push_warning("WorldGen: chunk_radius=%d 与 chunk_size=%d 不匹配，已强制取 %d。" % [
			configured_radius, chunk_size, chunk_radius])
	spawn_safe_radius_cells = int(source.get("spawn_safe_radius_cells", spawn_safe_radius_cells))
	spawn_reserved_cells.clear()
	for pair in source.get("spawn_reserved_cells", []):
		if pair is Array and pair.size() >= 2:
			spawn_reserved_cells.append(Vector2i(int(pair[0]), int(pair[1])))
	spawn_reserved_footprints.clear()
	for entry in source.get("spawn_reserved_footprints", []):
		if not (entry is Dictionary):
			continue
		var root_pair: Variant = entry.get("root", [0, 0])
		if not (root_pair is Array) or root_pair.size() < 2:
			continue
		spawn_reserved_footprints.append({
			"root": Vector2i(int(root_pair[0]), int(root_pair[1])),
			"size": int(entry.get("size", 3)),
		})

	var budgets: Dictionary = source.get("budgets", {})
	gen_ms_per_frame = float(budgets.get("gen_ms_per_frame", gen_ms_per_frame))
	gen_rows_per_slice = maxi(1, int(budgets.get("gen_rows_per_slice", gen_rows_per_slice)))
	ensure_radius_chunks = maxi(0, int(budgets.get("ensure_radius_chunks", ensure_radius_chunks)))
	keep_radius_chunks = maxi(ensure_radius_chunks, int(budgets.get("keep_radius_chunks", keep_radius_chunks)))
	materialize_radius_chunks = clampi(
		int(budgets.get("materialize_radius_chunks", materialize_radius_chunks)),
		0,
		ensure_radius_chunks
	)
	pig_residency_radius_chunks = maxi(0, int(budgets.get("pig_residency_radius_chunks", pig_residency_radius_chunks)))
	unload_eval_seconds = maxf(0.1, float(budgets.get("unload_eval_seconds", unload_eval_seconds)))
	eager_load_radius_chunks = maxi(0, int(budgets.get("eager_load_radius_chunks", eager_load_radius_chunks)))

	var bench: Dictionary = source.get("bench", {})
	bench_chunk_count = maxi(1, int(bench.get("chunk_count", bench_chunk_count)))
	bench_avg_ms_max = float(bench.get("avg_ms_max", bench_avg_ms_max))
	bench_p99_ms_max = float(bench.get("p99_ms_max", bench_p99_ms_max))

	var layers: Dictionary = source.get("layers", {})
	var terrain: Dictionary = layers.get("terrain", {})
	terrain_salt = SeedSystem.fnv1a64(str(terrain.get("salt", "t3rra1n")))
	terrain_noise_scale_q16 = maxi(1, int(terrain.get("noise_scale_q16", terrain_noise_scale_q16)))
	terrain_octaves = clampi(int(terrain.get("octaves", terrain_octaves)), 1, 4)
	terrain_water_millis = _millis_of(terrain, "water_threshold", terrain_water_millis)
	terrain_sand_millis = _millis_of(terrain, "sand_threshold", terrain_sand_millis)
	terrain_dirt_millis = _millis_of(terrain, "dirt_threshold", terrain_dirt_millis)

	var eco: Dictionary = layers.get("eco", {})
	eco_salt = SeedSystem.fnv1a64(str(eco.get("salt", "ec0l0gy")))
	bush_chance_millis = int(eco.get("bush_chance_millis", bush_chance_millis))
	bush_hp = maxi(1, int(eco.get("bush_hp", bush_hp)))
	tuft_chance_millis = int(eco.get("tuft_chance_millis", tuft_chance_millis))
	flower_chance_millis = int(eco.get("flower_chance_millis", flower_chance_millis))

	var obstacle: Dictionary = layers.get("obstacle", {})
	obstacle_salt = SeedSystem.fnv1a64(str(obstacle.get("salt", "0bstacl")))
	obstacle_cell_chunk_cells = clampi(int(obstacle.get("cell_chunk_cells", obstacle_cell_chunk_cells)), 1, 64)
	tree_chance_millis = int(obstacle.get("tree_chance_millis", tree_chance_millis))
	rock_chance_millis = int(obstacle.get("rock_chance_millis", rock_chance_millis))
	var hp: Array = obstacle.get("tree_hp", [tree_hp_min, tree_hp_max])
	if hp.size() >= 2:
		tree_hp_min = maxi(1, int(hp[0]))
		tree_hp_max = maxi(tree_hp_min, int(hp[1]))
	var rock_hp: Array = obstacle.get("rock_hp", [rock_hp_min, rock_hp_max])
	if rock_hp.size() >= 2:
		rock_hp_min = maxi(1, int(rock_hp[0]))
		rock_hp_max = maxi(rock_hp_min, int(rock_hp[1]))
	stone_chance_millis = clampi(int(obstacle.get("stone_chance_millis", stone_chance_millis)), 0, 1000)
	var stone_hp: Array = obstacle.get("stone_hp", [stone_hp_min, stone_hp_max])
	if stone_hp.size() >= 2:
		stone_hp_min = maxi(1, int(stone_hp[0]))
		stone_hp_max = maxi(stone_hp_min, int(stone_hp[1]))
	var stone_amount: Array = obstacle.get("stone_amount", [stone_amount_min, stone_amount_max])
	if stone_amount.size() >= 2:
		stone_amount_min = maxi(1, int(stone_amount[0]))
		stone_amount_max = maxi(stone_amount_min, int(stone_amount[1]))
	tree_footprint = clampi(int(obstacle.get("tree_footprint", tree_footprint)), 1, 3)
	tree_ground_pad_millis = clampi(int(obstacle.get("tree_ground_pad_millis", tree_ground_pad_millis)), 0, 1000)

	var ore: Dictionary = layers.get("ore", {})
	ore_salt = SeedSystem.fnv1a64(str(ore.get("salt", "0rev31n")))
	ore_region_chunks = maxi(1, int(ore.get("region_chunks", ore_region_chunks)))
	var counts: Array = ore.get("vein_count_per_region", [vein_count_min, vein_count_max])
	if counts.size() >= 2:
		vein_count_min = maxi(0, int(counts[0]))
		vein_count_max = maxi(vein_count_min, int(counts[1]))
	min_vein_cells = maxi(1, int(ore.get("min_vein_cells", min_vein_cells)))
	vein_total_amount_min = maxi(0, int(ore.get("vein_total_amount_min", vein_total_amount_min)))
	vein_total_amount_max = maxi(
		vein_total_amount_min,
		int(ore.get("vein_total_amount_max", vein_total_amount_max))
	)
	depth_bias_radius_cells = maxi(1, int(ore.get("depth_bias_radius_cells", depth_bias_radius_cells)))
	ore_types.clear()
	ore_total_weight = 0
	for entry in ore.get("types", []):
		if not (entry is Dictionary):
			continue
		var vein: Array = entry.get("vein_size", [3, 6])
		var low: int = int(vein[0]) if vein.size() >= 1 else 3
		var high: int = int(vein[1]) if vein.size() >= 2 else low
		var weight := maxi(0, int(entry.get("weight", 1)))
		if weight <= 0:
			continue
		var min_amount := maxi(1, int(entry.get("min_cell_amount", 1)))
		var max_amount := maxi(min_amount, int(entry.get("max_cell_amount", min_amount)))
		ore_types.append({
			"id": str(entry.get("id", "unknown")),
			"weight": weight,
			"depth_bias_millis": int(entry.get("depth_bias_millis", _millis(entry.get("depth_bias", 0.0)))),
			"vein_size_min": maxi(1, mini(low, high)),
			"vein_size_max": maxi(maxi(1, mini(low, high)), maxi(low, high)),
			"min_cell_amount": min_amount,
			"max_cell_amount": max_amount,
			"ore_id": ore_types.size() + 1,
		})
		ore_total_weight += weight
	if ore_types.is_empty():
		_apply_ore_defaults()


func terrain_threshold(which: String) -> int:
	var millis := terrain_dirt_millis
	if which == "water":
		millis = terrain_water_millis
	elif which == "sand":
		millis = terrain_sand_millis
	return (65535 * millis) / 1000


## ore_id -> 类型定义（1 起）。
func ore_type_by_id(ore_id: int) -> Dictionary:
	for entry in ore_types:
		if int(entry["ore_id"]) == ore_id:
			return entry
	return {}


func ore_id_by_name(name: String) -> int:
	for entry in ore_types:
		if str(entry["id"]) == name:
			return int(entry["ore_id"])
	return 0


func _apply_defaults() -> void:
	spawn_reserved_cells = [Vector2i(0, 0), Vector2i(4, 0), Vector2i(8, 0)]
	spawn_reserved_footprints = [{"root": Vector2i(5, -2), "size": 3}]
	terrain_salt = SeedSystem.fnv1a64("t3rra1n")
	eco_salt = SeedSystem.fnv1a64("ec0l0gy")
	obstacle_salt = SeedSystem.fnv1a64("0bstacl")
	ore_salt = SeedSystem.fnv1a64("0rev31n")
	_apply_ore_defaults()


func _apply_ore_defaults() -> void:
	ore_types = [
		{
			"id": "copper", "weight": 60, "depth_bias_millis": 0,
			"vein_size_min": 6, "vein_size_max": 14,
			"min_cell_amount": 2, "max_cell_amount": 4, "ore_id": 1,
		},
		{
			"id": "iron", "weight": 30, "depth_bias_millis": 300,
			"vein_size_min": 4, "vein_size_max": 9,
			"min_cell_amount": 2, "max_cell_amount": 3, "ore_id": 2,
		},
		{
			"id": "gold", "weight": 10, "depth_bias_millis": 600,
			"vein_size_min": 3, "vein_size_max": 6,
			"min_cell_amount": 1, "max_cell_amount": 2, "ore_id": 3,
		},
		{
			"id": "coal", "weight": 20, "depth_bias_millis": 120,
			"vein_size_min": 4, "vein_size_max": 8,
			"min_cell_amount": 1, "max_cell_amount": 2, "ore_id": 4,
		},
	]
	ore_total_weight = 120


static func _millis(value: Variant) -> int:
	if value == null:
		return 0
	return int(round(float(value) * 1000.0))


static func _millis_of(source: Dictionary, key: String, fallback: int) -> int:
	if source.has(key):
		return _millis(source[key])
	return fallback