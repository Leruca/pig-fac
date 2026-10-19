extends WorldGenTestBase
## 负坐标与接缝（§3.1 / §4 跨区块连续性）：
##   - chunk/local/region 公式在 -128 / -127 / 0 等边界上的取值；
##   - 相邻区块接缝处地形连续（同一点用两侧任一区块计算应一致）；
##   - 3×3 树边界带去重：既不缺漏也不重复。
## 运行：godot --headless --path . -s res://tests/worldgen/test_negative_coords.gd

const SEED := 777


func _run() -> void:
	_test_grid_math_examples()
	_test_local_roundtrip_over_range()
	_test_setup_boundary_continuity()
	_test_tree_boundary_band()
	_finish("NEGATIVE COORDS & SEAM TESTS")


func _test_grid_math_examples() -> void:
	# 文档里的三个例子（docs/worldgen.md 坐标系一节）。
	_check_equal(GridMath.chunk_of_cell(Vector2i(-128, 0), 255), Vector2i(-1, 0), "cell -128 属于区块 -1")
	# 区块 -1 覆盖 [-382, -128]（255 格），因此 cell -128 是它的最后一格，局部坐标 254。
	# （PLAN §3.1 的 1 维示例把这里写成 127，与本方案的 chunk_origin 定义矛盾，以本定义为准。）
	_check_equal(GridMath.local_of_cell(Vector2i(-128, 0), Vector2i(-1, 0), 255), Vector2i(254, 127), "cell -128 在区块 -1 内的局部坐标")
	_check_equal(GridMath.chunk_of_cell(Vector2i(-127, 0), 255), Vector2i(0, 0), "cell -127 属于区块 0")
	_check_equal(GridMath.local_of_cell(Vector2i(-127, 0), Vector2i(0, 0), 255), Vector2i(0, 127), "cell -127 是区块 0 的第一列")
	_check_equal(GridMath.chunk_of_cell(Vector2i(0, 0), 255), Vector2i(0, 0), "原点属于区块 0")
	_check_equal(GridMath.local_of_cell(Vector2i(0, 0), Vector2i(0, 0), 255), Vector2i(127, 127), "原点的局部坐标是 (127,127)")
	_check_equal(GridMath.chunk_of_cell(Vector2i(127, 127), 255), Vector2i(0, 0), "区块 0 的右上角")
	_check_equal(GridMath.chunk_of_cell(Vector2i(128, 128), 255), Vector2i(1, 1), "cell 128 进入区块 1")
	# region 必须用 floor 除法：-1 属于 region -1，而不是 0。
	_check_equal(GridMath.region_of_chunk(Vector2i(-1, 0), 4), Vector2i(-1, 0), "区块 -1 的 region 是 -1")
	_check_equal(GridMath.region_of_chunk(Vector2i(-4, -4), 4), Vector2i(-1, -1), "区块 -4 的 region 是 -1")
	_check_equal(GridMath.region_of_chunk(Vector2i(-5, -5), 4), Vector2i(-2, -2), "区块 -5 的 region 是 -2")
	_check_equal(GridMath.region_of_chunk(Vector2i(0, 0), 4), Vector2i(0, 0), "区块 0 的 region 是 0")
	# 区块原点公式：chunk * 255 - 127。
	_check_equal(GridMath.chunk_origin(Vector2i(-1, -1), 255), Vector2i(-382, -382), "区块 -1 的原点是 -382")
	_check_equal(GridMath.chunk_origin(Vector2i(0, 0), 255), Vector2i(-127, -127), "区块 0 的原点是 -127")


## 任意格：cell = chunk_origin(chunk) + local，且 local ∈ [0,255)。
func _test_local_roundtrip_over_range() -> void:
	var mismatches := 0
	for value in range(-700, 701, 7):
		var cell := Vector2i(value, -value)
		var chunk := GridMath.chunk_of_cell(cell, 255)
		var local := GridMath.local_of_cell(cell, chunk, 255)
		var rebuilt := GridMath.chunk_origin(chunk, 255) + local
		if rebuilt != cell or local.x < 0 or local.x >= 255 or local.y < 0 or local.y >= 255:
			mismatches += 1
	_check_equal(mismatches, 0, "chunk/local 往返在 -700..700 范围内必须全部成立")
	# floor 除法自检（不能退化成向零取整）。
	for pair in [[-1, 4, -1], [-4, 4, -1], [-5, 4, -2], [3, 4, 0], [-8, 4, -2]]:
		_check_equal(GridMath.floor_div(pair[0], pair[1]), pair[2], "floor_div(%d,%d)" % [pair[0], pair[1]])


## 接缝：同一格用左右/上下两个相邻区块的 NoiseField 计算，地形类型必须一致。
func _test_setup_boundary_continuity() -> void:
	var left := Vector2i(0, 0)
	var right := Vector2i(1, 0)
	var field_left := TerrainLayer.new().make_field(SEED, config, left)
	var field_right := TerrainLayer.new().make_field(SEED, config, right)
	var mismatches := 0
	# 接缝 x = 255*0 + 127 = 127；两侧各取 ±16 格。
	for offset in range(-16, 17):
		for y_offset in range(-40, 41, 8):
			var x := 127 + offset
			var y := y_offset
			if field_left.terrain_at(x, y) != field_right.terrain_at(x, y):
				mismatches += 1
	_check_equal(mismatches, 0, "左右区块对同一格的地形判定必须一致（接缝连续）")

	var bottom := TerrainLayer.new().make_field(SEED, config, Vector2i(0, 1))
	var bottom_mismatches := 0
	for offset in range(-16, 17):
		for x_offset in range(-40, 41, 8):
			var x := x_offset
			var y := 127 + offset
			if field_left.terrain_at(x, y) != bottom.terrain_at(x, y):
				bottom_mismatches += 1
	_check_equal(bottom_mismatches, 0, "上下区块对同一格的地形判定必须一致（接缝连续）")

	# 负侧接缝同样成立（区块 -1 与 0 的边界在 x = -127）。
	var negative := TerrainLayer.new().make_field(SEED, config, Vector2i(-1, 0))
	var negative_mismatches := 0
	for offset in range(-16, 17):
		for y_offset in range(-40, 41, 8):
			var x := -127 + offset
			var y := y_offset
			if field_left.terrain_at(x, y) != negative.terrain_at(x, y):
				negative_mismatches += 1
	_check_equal(negative_mismatches, 0, "负坐标接缝（区块 -1/0）也必须连续")


## 3×3 树跨块：每个根格在所有"footprint 与根格相交的区块"里都恰好出现一次。
func _test_tree_boundary_band() -> void:
	var generator := WorldGenerator.new(config, SEED)
	# 取 3×3 个区块，标出每个区块收录到的树根。
	var chunks := _chunks_in_rect(Vector2i(-1, -1), Vector2i(1, 1))
	var roots_per_chunk := {}
	var all_roots := {}
	for chunk in chunks:
		var data := generator.generate_chunk(chunk)
		var roots := {}
		for obstacle in data.obstacles:
			if int(obstacle["kind"]) != ChunkData.KIND_TREE:
				continue
			var root: Vector2i = obstacle["cell"]
			_check(not roots.has(root), "区块 %s 内不应重复收录同一棵树 %s" % [str(chunk), str(root)])
			roots[root] = true
			all_roots[root] = true
		roots_per_chunk[chunk] = roots

	# 对每个根格：凡 footprint 与之相交的区块都必须收录它；不相交的不得收录。
	var footprint := config.tree_footprint
	var missing := 0
	var extra := 0
	for root_value in all_roots.keys():
		var root: Vector2i = root_value
		var home := GridMath.chunk_of_cell(root, config.chunk_size)
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
		_check_equal(home, GridMath.chunk_of_cell(root, config.chunk_size), "根格归属区块稳定")
	_check_equal(missing, 0, "跨块 footprint 的树在相交区块中不得缺漏")
	_check_equal(extra, 0, "与区块不相交的树不得被收录")
