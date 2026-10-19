class_name ChunkHasher
extends RefCounted
## 规范化序列化 + FNV-1a 64 黄金哈希（世界生成验收的唯一事实来源）。
##
## 规范（docs/worldgen.md §8）：
##   int    -> "i" + big_endian_8bytes(v 位模式)
##   string -> "s" + u32_len + utf8_bytes
##   bool   -> "b" + (0|1)
##   array  -> "a" + u32_count + concat(canonical(e))
##   dict   -> "d" + u32_count + concat(canonical(k) + canonical(v))   # 键按 utf8 字节序
##   PackedByteArray -> "p" + u32_len + raw_bytes
##   float  -> 禁止（ChunkData 内不允许 float）
##
## 约定补充：Vector2i 按 "a" + 两个 int 编码（即 [x, y] 的规范形式）。
## 数组元素固定按 (cell.y, cell.x, kind/id) 排序，绝不保留生成/遍历顺序。

const TAG_INT := 105          # "i"

## 本次序列化是否遇到违规类型（见 chunk_hash）。
static var _invalid := false
const TAG_STRING := 115       # "s"
const TAG_BOOL := 98          # "b"
const TAG_ARRAY := 97         # "a"
const TAG_DICT := 100         # "d"
const TAG_PACKED_BYTES := 112 # "p"

## 规范化失败（float / 非字符串键）→ 把哈希标记成不可信，绝不返回一个"看起来正常"的值。
const INVALID_HASH := "invalid"


## ChunkData 的黄金哈希。hash = FNV-1a64(canonical(元数据) + canonical(内容))。
static func chunk_hash(
	seed_value: int,
	worldgen_version: int,
	chunk: Vector2i,
	terrain: PackedByteArray,
	obstacles: Array,
	ores: Array
) -> String:
	_invalid = false
	var payload := PackedByteArray()
	_append_int(payload, seed_value)
	_append_int(payload, worldgen_version)
	_append_int(payload, chunk.x)
	_append_int(payload, chunk.y)
	# 地形：定长 255*255，直接拼接原始字节。
	payload.append(TAG_PACKED_BYTES)
	_append_u32(payload, terrain.size())
	payload.append_array(terrain)
	# 障碍与矿点：先排序，再规范化。
	var sorted_obstacles := obstacles.duplicate()
	sorted_obstacles.sort_custom(_obstacle_less)
	_append_value(payload, sorted_obstacles)
	var sorted_ores := ores.duplicate()
	sorted_ores.sort_custom(_ore_less)
	_append_value(payload, sorted_ores)
	var digest := SeedSystem.to_hex64(SeedSystem.fnv1a64_bytes(payload))
	if _invalid:
		push_error("ChunkHasher: 规范化失败（float 或非字符串键），本哈希不可信")
		return INVALID_HASH
	return digest


## 障碍排序键：(cell.y, cell.x, kind)。
static func _obstacle_less(a: Variant, b: Variant) -> bool:
	var ca: Vector2i = a["cell"]
	var cb: Vector2i = b["cell"]
	if ca.y != cb.y:
		return ca.y < cb.y
	if ca.x != cb.x:
		return ca.x < cb.x
	return int(a.get("kind", 0)) < int(b.get("kind", 0))


## 矿点排序键：(cell.y, cell.x, ore_id)。
static func _ore_less(a: Variant, b: Variant) -> bool:
	var ca: Vector2i = a["cell"]
	var cb: Vector2i = b["cell"]
	if ca.y != cb.y:
		return ca.y < cb.y
	if ca.x != cb.x:
		return ca.x < cb.x
	return int(a.get("ore_id", 0)) < int(b.get("ore_id", 0))


static func canonical_bytes(value: Variant) -> PackedByteArray:
	_invalid = false
	var out := PackedByteArray()
	_append_value(out, value)
	return out


static func _append_u32(buffer: PackedByteArray, value: int) -> void:
	buffer.append((value >> 24) & 0xFF)
	buffer.append((value >> 16) & 0xFF)
	buffer.append((value >> 8) & 0xFF)
	buffer.append(value & 0xFF)


static func _append_int(buffer: PackedByteArray, value: int) -> void:
	buffer.append(TAG_INT)
	for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
		buffer.append((value >> shift) & 0xFF)


static func _append_value(buffer: PackedByteArray, value: Variant) -> void:
	match typeof(value):
		TYPE_INT:
			_append_int(buffer, int(value))
		TYPE_FLOAT:
			# 规范明确禁止 float 进入哈希。**必须让哈希失败**，不能 int() 后继续编码：
			# int(0.5) == int(0.9) == 0，两个不同状态会塌缩成同一个黄金哈希，
			# 而 push_error 在 --headless 下不中止进程，golden 对拍会静默通过。
			push_error("ChunkHasher: float 不允许进入黄金哈希（ChunkData 只允许整数）")
			_invalid = true
			_append_u32(buffer, 0xDEADBEEF)
		TYPE_BOOL:
			buffer.append(TAG_BOOL)
			buffer.append(1 if bool(value) else 0)
		TYPE_STRING, TYPE_STRING_NAME:
			var bytes := str(value).to_utf8_buffer()
			buffer.append(TAG_STRING)
			_append_u32(buffer, bytes.size())
			buffer.append_array(bytes)
		TYPE_PACKED_BYTE_ARRAY:
			var packed: PackedByteArray = value
			buffer.append(TAG_PACKED_BYTES)
			_append_u32(buffer, packed.size())
			buffer.append_array(packed)
		TYPE_VECTOR2I:
			var cell: Vector2i = value
			buffer.append(TAG_ARRAY)
			_append_u32(buffer, 2)
			_append_int(buffer, cell.x)
			_append_int(buffer, cell.y)
		TYPE_ARRAY:
			var items: Array = value
			buffer.append(TAG_ARRAY)
			_append_u32(buffer, items.size())
			for item in items:
				_append_value(buffer, item)
		TYPE_DICTIONARY:
			var dict: Dictionary = value
			var keys: Array = dict.keys()
			# 键必须全是 String，否则 "1" 与 1 会编码成同样的字节，
			# 同一份内容因插入顺序不同得到两个哈希（dict 键空间不单射）。
			for key in keys:
				if typeof(key) != TYPE_STRING and typeof(key) != TYPE_STRING_NAME:
					push_error("ChunkHasher: dict 键必须是 String（实际 %s）" % type_string(typeof(key)))
					_invalid = true
			keys.sort_custom(_dict_key_less)
			buffer.append(TAG_DICT)
			_append_u32(buffer, keys.size())
			for key in keys:
				_append_value(buffer, str(key))
				_append_value(buffer, dict[key])
		_:
			push_error("ChunkHasher: 不支持的类型 %d" % typeof(value))
			_append_int(buffer, 0)


## 键按 (类型, utf8 字节) 排序 —— 只用字符串排序在 int/str 混键时不是全序。
static func _dict_key_less(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if ta != tb:
		return ta < tb
	return _bytes_less(str(a).to_utf8_buffer(), str(b).to_utf8_buffer())


static func _bytes_less(a: PackedByteArray, b: PackedByteArray) -> bool:
	var limit := mini(a.size(), b.size())
	for index in limit:
		if a[index] != b[index]:
			return a[index] < b[index]
	return a.size() < b.size()