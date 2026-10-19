class_name NoiseField
extends RefCounted
## 值噪声的"窗口缓存"：把一块矩形区域内所有 octave 的**格点表**一次性算好，
## 之后每格的取样只是数组下标 + 双线性插值（无哈希、无 Dictionary、无浮点）。
##
## 为什么需要它：矿脉/障碍层要对成百上千个散落格点判定"是不是水"，
## 每次都重算格点哈希会慢一个数量级。窗口缓存让重复查询降到 ~0.5µs/次，
## 且结果与 fill_rows 的逐行计算**逐位一致**（同一份格点表、同一套定点插值）。
##
## 结构：覆盖 [origin, origin+size) 的窗口；1/2 octave 走直连字段（最常见、最快），
## 3/4 octave 走通用数组（性能不敏感，只在配置改大 octave 时用到）。

const SMOOTH_TABLE_SIZE := 4096
const WEIGHT_SCALE := 65536

static var _smooth_table: PackedInt32Array = PackedInt32Array()

var origin_x: int = 0
var origin_y: int = 0
var size_x: int = 0
var size_y: int = 0
var octave_count: int = 1
var weight_total: int = 1

## 地形阈值（0..65535 口径），build 时从配置拷贝。
var water_q: int = 19660
var sand_q: int = 23592
var dirt_q: int = 30146

# --- octave 0 / 1 的直连字段（热路径） ---
var _g0: PackedInt32Array = PackedInt32Array()
var _i0: PackedInt32Array = PackedInt32Array()
var _w0: PackedInt32Array = PackedInt32Array()
var _iw0: PackedInt32Array = PackedInt32Array()
var _ra0: PackedInt32Array = PackedInt32Array()
var _rb0: PackedInt32Array = PackedInt32Array()
var _rw0: PackedInt32Array = PackedInt32Array()
var _nx0: int = 0
var _g1: PackedInt32Array = PackedInt32Array()
var _i1: PackedInt32Array = PackedInt32Array()
var _w1: PackedInt32Array = PackedInt32Array()
var _iw1: PackedInt32Array = PackedInt32Array()
var _ra1: PackedInt32Array = PackedInt32Array()
var _rb1: PackedInt32Array = PackedInt32Array()
var _rw1: PackedInt32Array = PackedInt32Array()
var _nx1: int = 0
var _amp0: int = 1
var _amp1: int = 2

# --- 3/4 octave 的通用数组 ---
var _multi_grid: Array[PackedInt32Array] = []
var _multi_index: Array[PackedInt32Array] = []
var _multi_weight: Array[PackedInt32Array] = []
var _multi_rows_a: Array[PackedInt32Array] = []
var _multi_rows_b: Array[PackedInt32Array] = []
var _multi_rows_w: Array[PackedInt32Array] = []
var _multi_amp: PackedInt32Array = PackedInt32Array()

var _seed: int = 0
var _base_salt: int = 0
var _scale_q16: int = 1180


static func smooth_table() -> PackedInt32Array:
	if _smooth_table.is_empty():
		_smooth_table = PackedInt32Array()
		_smooth_table.resize(SMOOTH_TABLE_SIZE)
		for index in SMOOTH_TABLE_SIZE:
			var weight := index * WEIGHT_SCALE / SMOOTH_TABLE_SIZE
			var squared := (weight * weight) >> 16
			var factor := 3 * WEIGHT_SCALE - ((2 * squared * WEIGHT_SCALE) >> 16) / WEIGHT_SCALE
			_smooth_table[index] = clampi((factor * squared) >> 16, 0, WEIGHT_SCALE)
	return _smooth_table


static func weight_of(frac: int) -> int:
	return smooth_table()[(frac * SMOOTH_TABLE_SIZE) >> 16]


## 覆盖 rect（半开区间）的格点窗口。
func build(seed_value: int, config: WorldGenConfig, rect: Rect2i) -> void:
	origin_x = rect.position.x
	origin_y = rect.position.y
	size_x = maxi(1, rect.size.x)
	size_y = maxi(1, rect.size.y)
	octave_count = clampi(config.terrain_octaves, 1, 4)
	water_q = config.terrain_threshold("water")
	sand_q = config.terrain_threshold("sand")
	dirt_q = config.terrain_threshold("dirt")
	_seed = seed_value
	_base_salt = config.terrain_salt
	_scale_q16 = config.terrain_noise_scale_q16

	weight_total = 0
	for k in octave_count:
		weight_total += 1 << (octave_count - 1 - k)

	_multi_grid = []
	_multi_index = []
	_multi_weight = []
	_multi_rows_a = []
	_multi_rows_b = []
	_multi_rows_w = []
	_multi_amp = PackedInt32Array()

	for k in octave_count:
		var scale := config.terrain_noise_scale_q16 << k
		var salt := config.terrain_salt + k
		var amplitude := 1 << (octave_count - 1 - k)
		var indices := PackedInt32Array()
		var weights := PackedInt32Array()
		indices.resize(size_x)
		weights.resize(size_x)
		var first_gx := GridMath.floor_div(origin_x * scale, WEIGHT_SCALE) - 1
		for x in size_x:
			var position := (origin_x + x) * scale
			indices[x] = (position >> 16) - first_gx
			weights[x] = weight_of(position & 0xFFFF)
		var last_gx := first_gx + indices[size_x - 1] + 1
		var nx := last_gx - first_gx + 1
		var first_gy := GridMath.floor_div(origin_y * scale, WEIGHT_SCALE) - 1
		var last_gy := GridMath.floor_div((origin_y + size_y - 1) * scale, WEIGHT_SCALE) + 1
		var ny := last_gy - first_gy + 1

		var grid := PackedInt32Array()
		grid.resize(nx * ny)
		for gy in ny:
			var base := gy * nx
			var prefix := SeedSystem.splitmix64(seed_value + salt)
			prefix = SeedSystem.splitmix64(prefix + ((first_gy + gy) & SeedSystem.MASK32))
			for gxi in nx:
				var mixed := SeedSystem.splitmix64(prefix + ((first_gx + gxi) & SeedSystem.MASK32))
				grid[base + gxi] = (mixed >> 32) & 0xFFFF

		var rows_a := PackedInt32Array()
		var rows_b := PackedInt32Array()
		var rows_w := PackedInt32Array()
		rows_a.resize(size_y)
		rows_b.resize(size_y)
		rows_w.resize(size_y)
		for y in size_y:
			var position_y := (origin_y + y) * scale
			var gy := position_y >> 16
			rows_a[y] = (gy - first_gy) * nx
			rows_b[y] = rows_a[y] + nx
			rows_w[y] = weight_of(position_y & 0xFFFF)

		match k:
			0:
				_g0 = grid
				_i0 = indices
				_w0 = weights
				_iw0 = _inverse_weights(weights)
				_ra0 = rows_a
				_rb0 = rows_b
				_rw0 = rows_w
				_nx0 = nx
				_amp0 = amplitude
			1:
				_g1 = grid
				_i1 = indices
				_w1 = weights
				_iw1 = _inverse_weights(weights)
				_ra1 = rows_a
				_rb1 = rows_b
				_rw1 = rows_w
				_nx1 = nx
				_amp1 = amplitude
			_:
				_multi_grid.append(grid)
				_multi_index.append(indices)
				_multi_weight.append(weights)
				_multi_rows_a.append(rows_a)
				_multi_rows_b.append(rows_b)
				_multi_rows_w.append(rows_w)
				_multi_amp.append(amplitude)
	prepare_buffers()


## 单点噪声值（0..65535，全场加权平均后的**精确** floor 值）。
## 注意：判类（是水/沙/泥/草）不走这个值，而是用 raw_value_at() 与 threshold*weight_total 比较 ——
## 这样点查询与 fill_rows 用的是**同一个整数比较**，不存在除法的舍入分歧。
func value_at(x: int, y: int) -> int:
	return raw_value_at(x, y) / weight_total


## 未归一化的加权和（= fill_rows 内部比较的那个量）。判类请用 classify()。
func raw_value_at(x: int, y: int) -> int:
	var local_x := x - origin_x
	var local_y := y - origin_y
	if local_x < 0 or local_y < 0 or local_x >= size_x or local_y >= size_y:
		return raw_exact_value(x, y)
	if octave_count == 1:
		return _sample0(local_x, local_y)
	if octave_count == 2:
		return _sample0(local_x, local_y) * 2 + _sample1(local_x, local_y)
	var total := _sample0(local_x, local_y) * _amp0 + _sample1(local_x, local_y) * _amp1
	for index in _multi_grid.size():
		total += _sample_multi(index, local_x, local_y) * _multi_amp[index]
	return total


## 唯一的判类入口：raw 与 threshold*weight_total 直接比较（与 fill_rows 逐位一致）。
func classify(raw_value: int) -> int:
	if raw_value < water_q * weight_total:
		return TerrainTypes.WATER
	if raw_value < sand_q * weight_total:
		return TerrainTypes.SAND
	if raw_value < dirt_q * weight_total:
		return TerrainTypes.DIRT
	return TerrainTypes.GRASS


## 单点判类（所有跨块查询都走这里）。
func terrain_at(x: int, y: int) -> int:
	return classify(raw_value_at(x, y))


## **必须先垂直后水平**，与 fill_rows 的混合顺序逐位一致（顺序不同会差 1）。
func _sample0(local_x: int, local_y: int) -> int:
	var grid := _g0
	var weight_y := _rw0[local_y]
	var inverse_y := WEIGHT_SCALE - weight_y
	var left := _i0[local_x]
	var weight_x := _w0[local_x]
	var inverse_x := WEIGHT_SCALE - weight_x
	var row_a := _ra0[local_y]
	var row_b := _rb0[local_y]
	var v_left := (grid[row_a + left] * inverse_y + grid[row_b + left] * weight_y) >> 16
	var v_right := (grid[row_a + left + 1] * inverse_y + grid[row_b + left + 1] * weight_y) >> 16
	return (v_left * inverse_x + v_right * weight_x) >> 16


## 同 _sample0：先垂直后水平。
func _sample1(local_x: int, local_y: int) -> int:
	var grid := _g1
	var weight_y := _rw1[local_y]
	var inverse_y := WEIGHT_SCALE - weight_y
	var left := _i1[local_x]
	var weight_x := _w1[local_x]
	var inverse_x := WEIGHT_SCALE - weight_x
	var row_a := _ra1[local_y]
	var row_b := _rb1[local_y]
	var v_left := (grid[row_a + left] * inverse_y + grid[row_b + left] * weight_y) >> 16
	var v_right := (grid[row_a + left + 1] * inverse_y + grid[row_b + left + 1] * weight_y) >> 16
	return (v_left * inverse_x + v_right * weight_x) >> 16


func _sample_multi(index: int, local_x: int, local_y: int) -> int:
	var grid := _multi_grid[index]
	var weight_y := _multi_rows_w[index][local_y]
	var inverse_y := WEIGHT_SCALE - weight_y
	var left := _multi_index[index][local_x]
	var weight_x := _multi_weight[index][local_x]
	var inverse_x := WEIGHT_SCALE - weight_x
	var top_offset := _multi_rows_a[index][local_y] + left
	var bottom_offset := _multi_rows_b[index][local_y] + left
	var top := (grid[top_offset] * inverse_x + grid[top_offset + 1] * weight_x) >> 16
	var bottom := (grid[bottom_offset] * inverse_x + grid[bottom_offset + 1] * weight_x) >> 16
	return (top * inverse_y + bottom * weight_y) >> 16


## 窗口外查询：按同一公式逐点计算，返回**未归一化**的加权和。
## （调用方应把它交给 classify()，与 fill_rows 的比较口径完全一致。）
func raw_exact_value(x: int, y: int) -> int:
	var total := 0
	for k in octave_count:
		var scale := _scale_q16 << k
		var position_x := x * scale
		var position_y := y * scale
		var gx := position_x >> 16
		var gy := position_y >> 16
		var fx := weight_of(position_x & 0xFFFF)
		var fy := weight_of(position_y & 0xFFFF)
		var prefix := SeedSystem.splitmix64(_seed + _base_salt + k)
		var row_a := SeedSystem.splitmix64(prefix + (gy & SeedSystem.MASK32))
		var row_b := SeedSystem.splitmix64(prefix + ((gy + 1) & SeedSystem.MASK32))
		var h00 := (SeedSystem.splitmix64(row_a + (gx & SeedSystem.MASK32)) >> 32) & 0xFFFF
		var h10 := (SeedSystem.splitmix64(row_a + ((gx + 1) & SeedSystem.MASK32)) >> 32) & 0xFFFF
		var h01 := (SeedSystem.splitmix64(row_b + (gx & SeedSystem.MASK32)) >> 32) & 0xFFFF
		var h11 := (SeedSystem.splitmix64(row_b + ((gx + 1) & SeedSystem.MASK32)) >> 32) & 0xFFFF
		# 与 _sample0/_sample1 相同的混合顺序：先垂直、后水平。
		var v_left := (h00 * (WEIGHT_SCALE - fy) + h01 * fy) >> 16
		var v_right := (h10 * (WEIGHT_SCALE - fy) + h11 * fy) >> 16
		total += ((v_left * (WEIGHT_SCALE - fx) + v_right * fx) >> 16) * (1 << (octave_count - 1 - k))
	return total


## 归一化的窗口外取值（调试/工具用；判类请用 raw_exact_value + classify）。
func exact_value(x: int, y: int) -> int:
	return raw_exact_value(x, y) / weight_total


## 矩形（半开区间）内是否有水。与 classify()/fill_rows 用同一个整数比较。
func any_water(rect: Rect2i) -> bool:
	var limit := water_q * weight_total
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			if raw_value_at(x, y) < limit:
				return true
	return false

## 逐行填充地形（ChunkManager 分帧切片调用）。out 必须是 size_x*size_y。
## 两 octave 的情况是常态：每行先把两个 octave 的"垂直插值行"各滚一遍，
## 再逐格做 2 次水平插值并按权重合并，最后与 3×阈值比较（避免除法）。
func fill_rows(out: PackedByteArray, start_row: int, end_row: int) -> void:
	end_row = mini(end_row, size_y)
	var row_begin := maxi(0, start_row)
	if octave_count > 2:
		for y in range(row_begin, end_row):
			var base := y * size_x
			for x in size_x:
				_write_type(out, base + x, classify(raw_value_at(origin_x + x, origin_y + y)))
		return

	var water_limit := water_q
	var sand_limit := sand_q
	var dirt_limit := dirt_q
	if octave_count == 2:
		water_limit = water_q * 3
		sand_limit = sand_q * 3
		dirt_limit = dirt_q * 3

	var buf0 := _buf0
	var buf1 := _buf1
	var split := octave_count == 2

	for y in range(row_begin, end_row):
		var weight := _rw0[y]
		var inv := WEIGHT_SCALE - weight
		var a_offset := _ra0[y]
		var b_offset := _rb0[y]
		for column in _nx0:
			buf0[column] = (_g0[a_offset + column] * inv + _g0[b_offset + column] * weight) >> 16
		if split:
			weight = _rw1[y]
			inv = WEIGHT_SCALE - weight
			a_offset = _ra1[y]
			b_offset = _rb1[y]
			for column in _nx1:
				buf1[column] = (_g1[a_offset + column] * inv + _g1[b_offset + column] * weight) >> 16
		var base := y * size_x
		if split:
			var i0 := _i0
			var w0 := _w0
			var iw0 := _iw0
			var i1 := _i1
			var w1 := _w1
			var iw1 := _iw1
			for x in size_x:
				var left := i0[x]
				var value := (buf0[left] * iw0[x] + buf0[left + 1] * w0[x]) >> 16
				left = i1[x]
				value = value * 2 + ((buf1[left] * iw1[x] + buf1[left + 1] * w1[x]) >> 16)
				if value < water_limit:
					out[base + x] = TerrainTypes.WATER
				elif value < sand_limit:
					out[base + x] = TerrainTypes.SAND
				elif value < dirt_limit:
					out[base + x] = TerrainTypes.DIRT
				else:
					out[base + x] = TerrainTypes.GRASS
		else:
			for x in size_x:
				var left := _i0[x]
				var value := (buf0[left] * _iw0[x] + buf0[left + 1] * _w0[x]) >> 16
				if value < water_limit:
					out[base + x] = TerrainTypes.WATER
				elif value < sand_limit:
					out[base + x] = TerrainTypes.SAND
				elif value < dirt_limit:
					out[base + x] = TerrainTypes.DIRT
				else:
					out[base + x] = TerrainTypes.GRASS


static func _inverse_weights(weights: PackedInt32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(weights.size())
	for index in weights.size():
		out[index] = WEIGHT_SCALE - weights[index]
	return out


func _write_type(out: PackedByteArray, index: int, terrain_type: int) -> void:
	out[index] = terrain_type


var _buf0: PackedInt32Array = PackedInt32Array()
var _buf1: PackedInt32Array = PackedInt32Array()


## build 末尾调用：按格点宽度预分配两个垂直插值行缓冲。
func prepare_buffers() -> void:
	_buf0 = PackedInt32Array()
	_buf0.resize(maxi(1, _nx0))
	_buf1 = PackedInt32Array()
	_buf1.resize(maxi(1, _nx1))