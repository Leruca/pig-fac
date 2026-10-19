class_name GridMath
extends RefCounted
## 区块 / REGION / 局部坐标公式（负坐标安全，全整数）。
##
##   chunk_of_cell(cell)  = floor((cell + radius) / size)
##   local_of_cell(cell)  = cell - (chunk * size - radius)   -> [0, size)
##   region_of_chunk(c)   = floor_div(c, region_chunks)
##
## 注意 chunk_of_cell 必须用 floor 语义：cell=-128 -> chunk=-1, local=127；
## cell=-127 -> chunk=0, local=0。GDScript 的整数 / 对负数是向零取整，
## 因此这里用"先加偏移再做非负整数除法"的写法，避免任何浮点。

const DEFAULT_SIZE := 255
const DEFAULT_RADIUS := 127


static func chunk_of_cell(cell: Vector2i, size: int = DEFAULT_SIZE) -> Vector2i:
	var radius := (size - 1) / 2
	return Vector2i(
		_floor_div(cell.x + radius, size),
		_floor_div(cell.y + radius, size)
	)


static func chunk_origin(chunk: Vector2i, size: int = DEFAULT_SIZE) -> Vector2i:
	var radius := (size - 1) / 2
	return chunk * size - Vector2i(radius, radius)


static func local_of_cell(cell: Vector2i, chunk: Vector2i, size: int = DEFAULT_SIZE) -> Vector2i:
	return cell - chunk_origin(chunk, size)


static func region_of_chunk(chunk: Vector2i, region_chunks: int = 4) -> Vector2i:
	return Vector2i(
		_floor_div(chunk.x, region_chunks),
		_floor_div(chunk.y, region_chunks)
	)


static func region_origin_cell(region: Vector2i, region_chunks: int = 4, size: int = DEFAULT_SIZE) -> Vector2i:
	return chunk_origin(region * region_chunks, size)


## 非负/负数都返回 floor 语义的整数除法。
static func floor_div(value: int, divisor: int) -> int:
	return _floor_div(value, divisor)


static func _floor_div(value: int, divisor: int) -> int:
	if divisor == 0:
		return 0
	var quotient := value / divisor
	if value % divisor != 0 and (value < 0) != (divisor < 0):
		quotient -= 1
	return quotient
