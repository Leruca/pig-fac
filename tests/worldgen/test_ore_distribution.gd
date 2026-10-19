extends WorldGenTestBase
## 矿点分布（§6 / 验收 8）：大样本统计矿型比例与密度；水中无矿；有矿区块占比。
## 运行：godot --headless --path . -s res://tests/worldgen/test_ore_distribution.gd

const SEED := 987654
const SAMPLE_CHUNKS := 64


func _run() -> void:
	var generator := WorldGenerator.new(config, SEED)
	var query := func(cell: Vector2i) -> int: return generator.terrain_type_at(cell)
	var by_type := {}
	var total_cells := 0
	var chunks_with_ore := 0
	var water_ores := 0
	var overlapping := 0
	var chunks: Array[Vector2i] = []
	var side := int(sqrt(float(SAMPLE_CHUNKS)))
	for offset_y in side:
		for offset_x in side:
			chunks.append(Vector2i(offset_x - side / 2, offset_y - side / 2))
	for chunk in chunks:
		var ores := OreLayer.collect_chunk(SEED, config, chunk, query)
		if not ores.is_empty():
			chunks_with_ore += 1
		var seen := {}
		for ore in ores:
			var cell: Vector2i = ore["cell"]
			if seen.has(cell):
				overlapping += 1
			seen[cell] = true
			total_cells += 1
			var ore_id := int(ore["ore_id"])
			by_type[ore_id] = int(by_type.get(ore_id, 0)) + 1
			if not TerrainTypes.is_walkable(int(query.call(cell))):
				water_ores += 1
	_check_equal(water_ores, 0, "矿点不得落在水里")
	_check_equal(overlapping, 0, "同一区块内同一格不得出现两次矿")
	_check(chunks_with_ore >= chunks.size() / 2, "至少一半的采样区块应有矿（实际 %d/%d）" % [chunks_with_ore, chunks.size()])

	# 每块矿格数量应在合理密度区间：vein_count_per_region 32~64 条 × 平均 5~8 格 / 16 块。
	var per_chunk := float(total_cells) / float(chunks.size())
	_check(per_chunk >= 2.0 and per_chunk <= 80.0, "每块矿格数量应在 2~80（实际 %.1f）" % per_chunk)

	# 类型比例：铜 > 铁 > 金（weight 60/30/10）。大样本下允许较宽松的容差。
	var copper := int(by_type.get(1, 0))
	var iron := int(by_type.get(2, 0))
	var gold := int(by_type.get(3, 0))
	_check(copper + iron + gold > 0, "至少应统计到矿格")
	_check(copper > gold, "铜的权重(60)高于金(10)，样本里应当更多")
	_check(iron > gold, "铁的权重(30)高于金(10)，样本里应当更多")
	var copper_ratio := float(copper) / float(maxi(1, total_cells))
	_check_almost(copper_ratio, 0.6, 0.25, "铜的比例应接近权重 0.6")

	# 每格 amount 区间与"无单格碎矿"。
	var bad_amount := 0
	for chunk in chunks:
		for ore in OreLayer.collect_chunk(SEED, config, chunk, query):
			var ore_type := config.ore_type_by_id(int(ore["ore_id"]))
			var amount := int(ore["amount"])
			if amount < int(ore_type["min_cell_amount"]) or amount > int(ore_type["max_cell_amount"]):
				bad_amount += 1
	_check_equal(bad_amount, 0, "每格矿量必须在配置区间内（无单格碎矿）")

	# 出生区（区块 (0,0) 的原点附近）统计上应比远处稀疏：这里只验证"确实为 0"。
	var spawn_ores := 0
	for ore in OreLayer.collect_chunk(SEED, config, Vector2i(0, 0), query):
		if maxi(absi(int(ore["cell"].x)), absi(int(ore["cell"].y))) <= config.spawn_safe_radius_cells:
			spawn_ores += 1
	_check_equal(spawn_ores, 0, "出生保护区内的生成矿量应为 0")

	# depth_bias：远处 REGION 的金矿占比应高于出生点附近（同一套权重 + bias 的结果）。
	var near_gold := _gold_ratio(Vector2i(0, 0), query)
	var far_gold := _gold_ratio(Vector2i(6, 6), query)
	_check(far_gold >= near_gold, "远处金矿占比(%.3f)不应低于出生点附近(%.3f)" % [far_gold, near_gold])
	_finish("ORE DISTRIBUTION TESTS")


func _gold_ratio(region: Vector2i, query: Callable) -> float:
	var gold := 0
	var total := 0
	for vein in OreLayer.region_veins(SEED, config, region, query):
		var cells: Array = vein["cells"]
		total += cells.size()
		if int(vein["ore_id"]) == 3:
			gold += cells.size()
	return float(gold) / float(maxi(1, total))
