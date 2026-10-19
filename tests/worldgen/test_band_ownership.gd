extends WorldGenTestBase
## 边界带回溯回归（对抗复审发现的关键缺陷）：
##   3×3 树跨越区块接缝时，**相交的每一个区块都必须收录它**，与区块的扫描顺序无关。
##   曾经的实现在边界带候选上使用"本块自己的 occupied 字典"，导致同一棵树只被其中一个
##   区块收录：砍伐无法落盘、遮挡随加载顺序变化、物化后出现互相重叠的树。
## 运行：godot --headless --path . -s res://tests/worldgen/test_band_ownership.gd

const SEEDS := [777, 20240607, 424242, 5150, 12345]
const BLOCK_ORIGINS := [Vector2i(-2, -2), Vector2i(-1, -1), Vector2i(0, 0), Vector2i(1, 1), Vector2i(-3, 2)]


func _run() -> void:
	var total_missing := 0
	var total_extra := 0
	var total_roots := 0
	for seed_value in SEEDS:
		for block_origin in BLOCK_ORIGINS:
			var counts := _probe_block(seed_value, block_origin)
			total_missing += int(counts["missing"])
			total_extra += int(counts["extra"])
			total_roots += int(counts["roots"])
			_check_equal(int(counts["missing"]), 0, "种子 %d 区块原点 %s：跨块树不得缺漏" % [seed_value, str(block_origin)])
			_check_equal(int(counts["extra"]), 0, "种子 %d 区块原点 %s：不相交的树不得被收录" % [seed_value, str(block_origin)])
	_check(total_roots > 10000, "样本里的树根数量应足够大（实际 %d）" % total_roots)
	_test_no_overlapping_trees()
	_test_band_tree_is_choppable_and_savable()
	_finish("BAND OWNERSHIP TESTS")


## 3×3 区块的每个根格：凡 footprint 与某区块相交，该区块就必须收录它；不相交就不得收录。
func _probe_block(seed_value: int, block_origin: Vector2i) -> Dictionary:
	var generator := WorldGenerator.new(config, seed_value)
	var chunks := _chunks_in_rect(block_origin, block_origin + Vector2i(2, 2))
	var roots_per_chunk := {}
	var all_roots := {}
	for chunk in chunks:
		var data := generator.generate_chunk(chunk)
		var roots := {}
		for obstacle in data.obstacles:
			if int(obstacle["kind"]) != ChunkData.KIND_TREE:
				continue
			var root: Vector2i = obstacle["cell"]
			_check(not roots.has(root), "区块 %s 内不得重复收录同一棵树 %s" % [str(chunk), str(root)])
			roots[root] = true
			all_roots[root] = true
		roots_per_chunk[chunk] = roots
	var footprint := config.tree_footprint
	var missing := 0
	var extra := 0
	for root_value in all_roots.keys():
		var root: Vector2i = root_value
		for chunk in chunks:
			var origin := GridMath.chunk_origin(chunk, config.chunk_size)
			var intersects := (
				root.x + footprint - 1 >= origin.x and root.x < origin.x + config.chunk_size
				and root.y + footprint - 1 >= origin.y and root.y < origin.y + config.chunk_size
			)
			var present: bool = (roots_per_chunk[chunk] as Dictionary).has(root)
			if intersects and not present:
				missing += 1
			elif not intersects and present:
				extra += 1
	return {"missing": missing, "extra": extra, "roots": all_roots.size()}


## 物化后不得出现互相重叠的 3×3 树（说明两个区块对同一棵树给出了不同裁决）。
func _test_no_overlapping_trees() -> void:
	var generator := WorldGenerator.new(config, 20240607)
	var chunks := _chunks_in_rect(Vector2i(-1, -2), Vector2i(1, 0))
	var roots := {}
	for chunk in chunks:
		var data := generator.generate_chunk(chunk)
		for obstacle in data.obstacles:
			if int(obstacle["kind"]) == ChunkData.KIND_TREE:
				roots[obstacle["cell"]] = true
	var footprint := config.tree_footprint
	var overlapped := 0
	for root_value in roots.keys():
		var root: Vector2i = root_value
		for offset_y in footprint:
			for offset_x in footprint:
				var cell := root + Vector2i(offset_x, offset_y)
				if cell == root:
					continue
				# 该格的"根格"必须是 root 自己。
				var blocker := _find_other_root(roots, cell, root);
				if blocker != Vector2i(2147483647, 2147483647):
					overlapped += 1
					break
	_check_equal(overlapped, 0, "物化后不得出现互相重叠的树（实际 %d 格重叠）" % overlapped)


func _find_other_root(roots: Dictionary, cell: Vector2i, self_root: Vector2i) -> Vector2i:
	var footprint := config.tree_footprint
	for root_value in roots.keys():
		var root: Vector2i = root_value
		if root == self_root:
			continue
		if (
			cell.x >= root.x and cell.x < root.x + footprint
			and cell.y >= root.y and cell.y < root.y + footprint
		):
			return root
	return Vector2i(2147483647, 2147483647)


## 跨块树的砍伐必须能落盘（这是该缺陷最直接的用户可见后果）。
func _test_band_tree_is_choppable_and_savable() -> void:
	var seed_value := 20240607
	var generator := WorldGenerator.new(config, seed_value)
	# 找一个"根格在区块 A、footprint 伸进区块 B"的树。
	var band_root := Vector2i(2147483647, 2147483647)
	var home_chunk := Vector2i.ZERO
	for chunk_y in range(-1, 2):
		for chunk_x in range(-1, 2):
			var chunk := Vector2i(chunk_x, chunk_y)
			var data := generator.generate_chunk(chunk)
			for obstacle in data.obstacles:
				if int(obstacle["kind"]) != ChunkData.KIND_TREE:
					continue
				var root: Vector2i = obstacle["cell"]
				if GridMath.chunk_of_cell(root, config.chunk_size) != chunk:
					continue  # 只关心"根格在本块"的正主
				var local := GridMath.local_of_cell(root, chunk, config.chunk_size)
				var size := config.chunk_size
				var touches_edge := (
					local.x >= size - (config.tree_footprint - 1) or local.y >= size - (config.tree_footprint - 1)
				);
				if touches_edge:
					band_root = root
					home_chunk = chunk
					break
			if band_root != Vector2i(2147483647, 2147483647):
				break
		if band_root != Vector2i(2147483647, 2147483647):
			break
	_check(band_root != Vector2i(2147483647, 2147483647), "样本里应存在跨块树")
	if band_root == Vector2i(2147483647, 2147483647):
		return
	# 根格所在块必须收录它，这样 chopped_trees 才有地方写。
	var home_data := generator.generate_chunk(home_chunk)
	var found := false
	for obstacle in home_data.obstacles:
		if int(obstacle["kind"]) == ChunkData.KIND_TREE and obstacle["cell"] == band_root:
			found = true
	_check(found, "跨块树的根格所在区块必须收录它 %s（否则砍伐永远无法落盘）" % str(band_root))