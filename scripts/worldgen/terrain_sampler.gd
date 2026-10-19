class_name TerrainSampler
extends RefCounted
## 地形查表的轻量包装：优先用"本块已生成的地形数组"（一次下标访问），
## 只有落在区块外的查询才回落到 NoiseField（窗口缓存 + 双线性）。
##
## 为什么需要它：障碍/生态层每个候选点要做 9 格水域判定。直接调 NoiseField
## 每次约 15µs，1000 个候选点就是 15ms；改成查表后单格 ~0.05µs。

var _terrain: PackedByteArray
var _origin: Vector2i
var _size: int
var _field: NoiseField


func _init(terrain: PackedByteArray, origin: Vector2i, size: int, field: NoiseField) -> void:
	_terrain = terrain
	_origin = origin
	_size = size
	_field = field


func terrain_at(x: int, y: int) -> int:
	var local_x := x - _origin.x
	var local_y := y - _origin.y
	if local_x >= 0 and local_y >= 0 and local_x < _size and local_y < _size:
		return _terrain[local_y * _size + local_x]
	return _field.terrain_at(x, y)


func is_water(x: int, y: int) -> bool:
	return terrain_at(x, y) == TerrainTypes.WATER


## 矩形（footprint×footprint）内是否有水。在块内的部分走数组，出界的角走 field。
func any_water(origin_cell: Vector2i, footprint: int) -> bool:
	for offset_y in footprint:
		for offset_x in footprint:
			if is_water(origin_cell.x + offset_x, origin_cell.y + offset_y):
				return true
	return false
