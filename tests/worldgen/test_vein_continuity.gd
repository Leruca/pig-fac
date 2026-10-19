extends WorldGenTestBase
## 矿脉连续性（§6）：跨区块、跨 REGION 边界不截断；无单格脉；重叠 tie-break 稳定。
## 运行：godot --headless --path . -s res://tests/worldgen/test_vein_continuity.gd

const SEED := 5150


func _run() -> void:
	_test_region_boundary_present()
	_test_no_single_cell_veins()
	_test_overlap_tiebreak_stable()
	_test_chunk_slices_agree_with_region()
	_test_walk_is_deterministic_and_connected()
	_finish("VEIN CONTINUITY TESTS")


func _terrain_query() -> Callable:
	var generator := WorldGenerator.new(config, SEED)
	return func(cell: Vector2i) -> int: return generator.terrain_type_at(cell)


## REGION 边界不系统性漏脉：区块的结果必须与"扩大到 5×5 邻域 REGION"的参考结果一致。
## （脉长 ≤ vein_size_max << REGION 边长，所以 3×3 邻域必须已经足够。）
func _test_region_boundary_present() -> void:
	var query := _terrain_query()
	var region_chunks := config.ore_region_chunks
	# 取贴着 REGION 边界上下两侧的区块（chunk y = region_chunks-1 与 region_chunks）。
	var boundary_chunks: Array[Vector2i] = [
		Vector2i(0, region_chunks - 1),
		Vector2i(0, region_chunks),
		Vector2i(-1, region_chunks - 1),
		Vector2i(-1, region_chunks),
		Vector2i(3, region_chunks),
	]
	var mismatches := 0
	var total_ores := 0
	for chunk in boundary_chunks:
		var direct := OreLayer.collect_chunk(SEED, config, chunk, query)
		var reference := _collect_with_neighbourhood(chunk, 2, query)
		total_ores += direct.size()
		if direct.size() != reference.size():
			mismatches += 1
			continue
		for index in direct.size():
			if direct[index]["cell"] != reference[index]["cell"] or direct[index]["ore_id"] != reference[index]["ore_id"]:
				mismatches += 1
				break
	_check_equal(mismatches, 0, "REGION 边界区块的矿点必须与 5×5 邻域参考结果一致（3×3 邻域足够）")
	_check(total_ores > 0, "REGION 边界区块事实上应当有矿（实际 %d 个）" % total_ores)


## 参考实现：自己扫描 radius 圈邻域 REGION，不依赖 OreLayer 的 3×3 假设。
func _collect_with_neighbourhood(chunk: Vector2i, radius: int, query: Callable) -> Array[Dictionary]:
	var size := config.chunk_size
	var origin := GridMath.chunk_origin(chunk, size)
	var region := GridMath.region_of_chunk(chunk, config.ore_region_chunks)
	var found := {}
	for offset_y in range(-radius, radius + 1):
		for offset_x in range(-radius, radius + 1):
			var neighbor := region + Vector2i(offset_x, offset_y)
			var builder := OreLayer.RegionBuilder.new(SEED, config, neighbor, query)
			while not builder.step(1 << 30, 1 << 30):
				pass
			for vein in builder.veins:
				var ore_id := int(vein["ore_id"])
				var vein_id := int(vein["vein_id"])
				var cells: Array = vein["cells"]
				var amounts: Array = vein["amounts"]
				for index in cells.size():
					var cell: Vector2i = cells[index]
					if cell.x < origin.x or cell.x >= origin.x + size or cell.y < origin.y or cell.y >= origin.y + size:
						continue
					var existing: Variant = found.get(cell)
					if existing == null or int(existing["vein_id"]) > vein_id:
						found[cell] = {"cell": cell, "ore_id": ore_id, "amount": int(amounts[index])}
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

## 任何一条脉过滤后的格数都 >= min_vein_cells；不在水里；总矿量 >= 配置下限。
func _test_no_single_cell_veins() -> void:
	var query := _terrain_query()
	var veins := OreLayer.region_veins(SEED, config, Vector2i(0, 0), query)
	_check(not veins.is_empty(), "REGION (0,0) 应至少有一条矿脉")
	var too_small := 0
	var water_cells := 0
	var bad_amount := 0
	for vein in veins:
		var cells: Array = vein["cells"]
		if cells.size() < config.min_vein_cells:
			too_small += 1
		var amounts: Array = vein["amounts"]
		_check_equal(amounts.size(), cells.size(), "每格都应有 amount")
		var vein_total := 0
		for index in cells.size():
			var cell: Vector2i = cells[index]
			if not TerrainTypes.is_walkable(int(query.call(cell))):
				water_cells += 1
			var amount := int(amounts[index])
			if amount <= 0:
				bad_amount += 1
			vein_total += amount
		if config.vein_total_amount_min > 0 and vein_total < config.vein_total_amount_min:
			bad_amount += 1
	_check_equal(too_small, 0, "过滤后少于 min_vein_cells 的整条脉必须被丢弃")
	_check_equal(water_cells, 0, "矿不能生成在水里")
	_check_equal(
		bad_amount,
		0,
		"每格矿量为正，且整条脉总矿量 >= %d" % config.vein_total_amount_min
	)


## 重叠处 vein_id 小者占优：重复重建、清缓存重建都必须一致。
func _test_overlap_tiebreak_stable() -> void:
	var chunk := Vector2i(1, 1)
	var query := _terrain_query()
	OreLayer.reset_cache()
	var first := OreLayer.collect_chunk(SEED, config, chunk, query)
	var again := OreLayer.collect_chunk(SEED, config, chunk, query)
	_check_equal(again.size(), first.size(), "重复收集矿点数量必须一致")
	var same := true
	for index in first.size():
		if first[index]["cell"] != again[index]["cell"] or first[index]["ore_id"] != again[index]["ore_id"]:
			same = false
	_check(same, "重复收集的矿点序列必须逐项一致（排序稳定）")
	OreLayer.reset_cache()
	var cold := OreLayer.collect_chunk(SEED, config, chunk, query)
	_check_equal(cold.size(), first.size(), "清缓存后矿点数量必须一致")
	for index in first.size():
		_check_equal(str(cold[index]["cell"]), str(first[index]["cell"]), "清缓存后第 %d 个矿点位置一致" % index)


## 区块切片的并集 == REGION 全脉 ∩ 该 REGION（跨块不重不漏）。
func _test_chunk_slices_agree_with_region() -> void:
	var query := _terrain_query()
	var size := config.chunk_size
	var region := Vector2i(0, 0)
	var region_origin := GridMath.region_origin_cell(region, config.ore_region_chunks, size)
	var region_span := size * config.ore_region_chunks
	var from_region := {}
	for vein in OreLayer.region_veins(SEED, config, region, query):
		for cell in vein["cells"]:
			if cell.x >= region_origin.x and cell.x < region_origin.x + region_span and cell.y >= region_origin.y and cell.y < region_origin.y + region_span:
				from_region[cell] = int(vein["ore_id"])
	var from_chunks := {}
	var chunks_in_region := config.ore_region_chunks
	for offset_y in chunks_in_region:
		for offset_x in chunks_in_region:
			var chunk := region * chunks_in_region + Vector2i(offset_x, offset_y)
			for ore in OreLayer.collect_chunk(SEED, config, chunk, query):
				var cell: Vector2i = ore["cell"]
				_check_equal(GridMath.chunk_of_cell(cell, size), chunk, "矿点 %s 应恰好落在收集它的区块 %s 内" % [str(cell), str(chunk)])
				from_chunks[cell] = int(ore["ore_id"])
	var missing := 0
	for cell_value in from_region.keys():
		if not from_chunks.has(cell_value):
			missing += 1
	_check_equal(missing, 0, "区块切片不得漏掉 REGION 内矿脉的格子")
	var mismatched_ore := 0
	for cell_value in from_chunks.keys():
		if from_region.has(cell_value) and int(from_chunks[cell_value]) != int(from_region[cell_value]):
			mismatched_ore += 1
	_check_equal(mismatched_ore, 0, "同一格在两处得到的矿种必须一致")


## 随机游走形状：无重复格、8 邻接连通。
func _test_walk_is_deterministic_and_connected() -> void:
	var query := _terrain_query()
	var veins := OreLayer.region_veins(SEED, config, Vector2i(-1, 1), query)
	_check(not veins.is_empty(), "REGION (-1,1) 应有矿脉可供形状校验")
	for vein in veins:
		var cells: Array = vein["cells"]
		var seen := {}
		var duplicates := 0
		for cell in cells:
			if seen.has(cell):
				duplicates += 1
			seen[cell] = true
		_check_equal(duplicates, 0, "一条脉内不应有重复格")
		if cells.size() > 1:
			_check_equal(_reachable_count(cells), cells.size(), "矿脉格必须 8 邻接连通")


func _reachable_count(cells: Array) -> int:
	var set := {}
	for cell in cells:
		set[cell] = true
	var start: Vector2i = cells[0]
	var stack: Array = [start]
	var visited := {start: true}
	while not stack.is_empty():
		var current: Vector2i = stack.pop_back()
		for offset_y in range(-1, 2):
			for offset_x in range(-1, 2):
				if offset_x == 0 and offset_y == 0:
					continue
				var next_cell := current + Vector2i(offset_x, offset_y)
				if set.has(next_cell) and not visited.has(next_cell):
					visited[next_cell] = true
					stack.append(next_cell)
	return visited.size()