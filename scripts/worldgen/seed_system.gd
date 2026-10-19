class_name SeedSystem
extends RefCounted
## 64 位确定性种子系统（世界生成唯一的随机性来源）。
##
## 设计要点（见 docs/worldgen.md）：
## - 内部一律使用 64 位有符号整数；GDScript 的整数溢出会**静默回绕**（实测确认），
##   因此不需要分段乘法，直接 * / + 即可。
## - GDScript 的 >> 是算术右移，负数的符号位会被复制。splitmix64 / hash2 必须使用
##   逻辑右移 ushr()，否则跨语言（Python/C）不可复核。
## - 大于 2^63 的十六进制字面量在 GDScript 里会报错并被静默替换成错误值，
##   因此 C1/C2/C3 使用等价的**有符号十进制**字面量。
## - 唯一允许的整数 -> [0,1) 映射是 u01()（取低 53 位 / 2^53），禁止任何变体。

## splitmix64 常量（注释为对应的无符号十六进制值）。
const C1 := -7046029254386353131  # 0x9E3779B97F4A7C15
const C2 := -4658895280553007687  # 0xBF58476D1CE4E5B9
const C3 := -7723592293110705685  # 0x94D049BB133111EB

const MASK32 := 0xFFFFFFFF
const MASK53 := 0x1FFFFFFFFFFFFF
const U01_SCALE := 9007199254740992.0
## FNV-1a 64 位参数（offset basis 0xCBF29CE484222325 / prime 0x100000001B3）。
const FNV_OFFSET := -3750763034362895579
const FNV_PRIME := 1099511628211

const DECIMAL_PATTERN := "^-?[0-9]+$"
const HEX_PATTERN := "^0[xX][0-9a-fA-F]{1,16}$"


## 逻辑右移。GDScript 的 >> 对负数会补 1，必须先掩掉高位。
static func ushr(value: int, bits: int) -> int:
	if bits <= 0:
		return value
	if bits >= 64:
		return 0
	return (value >> bits) & ((1 << (64 - bits)) - 1)


## splitmix64 的单次混合（不含状态推进）。
static func mix64(z_in: int) -> int:
	var z := z_in
	z = (z ^ ushr(z, 30)) * C2
	z = (z ^ ushr(z, 27)) * C3
	return z ^ ushr(z, 31)


## splitmix64(x)：把 x 当作状态推进一次后的输出。
static func splitmix64(x: int) -> int:
	return mix64(x + C1)


## 坐标哈希：hash(seed, layer_salt, x, y)。与遍历顺序、生成顺序无关。
## 坐标先折叠到 32 位二补码，负坐标规则唯一确定。
static func hash2(seed_value: int, layer_salt: int, x: int, y: int) -> int:
	var h := splitmix64(seed_value + layer_salt)
	h = splitmix64(h + (x & MASK32))
	h = splitmix64(h + (y & MASK32))
	return h


## 便宜的 32 位坐标哈希（**只用于粗筛**：候选点抽样、装饰抖动等"每格一次"的场合）。
## 它的结果仍完全由 (seed, salt, x, y) 决定，因此确定性不受影响；但**不**允许用于
## 需要与 Python 参考实现逐位对拍的地方（那里必须用 hash2/splitmix64）。
static func quick32(seed_value: int, salt: int, x: int, y: int) -> int:
	# 必须先把 seed 的**高 32 位**折进来：只用低 32 位的话，
	# seed 与 seed+2^32 会得到完全相同的树/石头/灌木布局（地形仍不同），
	# 而 FNV 回退种子（如 "hello猪"）高低位是任意的。
	var folded := (seed_value ^ salt)
	folded = (folded ^ ushr(folded, 32)) & MASK32
	var h := folded
	h = (h ^ (x & MASK32)) * 0x85EBCA6B
	h = (h ^ SeedSystem.ushr(h, 13)) & MASK32
	h = (h ^ (y & MASK32)) * 0xC2B2AE35
	h = (h ^ SeedSystem.ushr(h, 16)) & MASK32
	h = (h * 0x27D4EB2F) & MASK32
	return h ^ SeedSystem.ushr(h, 15)


## 整数 -> [0,1) 的唯一映射：低 53 位 / 2^53（double 尾数精确）。
static func u01(h: int) -> float:
	return float(h & MASK53) / U01_SCALE


## 由 64 位哈希派生的确定性随机流（splitmix64 状态机）。
class Stream:
	extends RefCounted

	var _state: int

	func _init(state_value: int) -> void:
		_state = state_value

	## 下一个 64 位输出。
	func next_int() -> int:
		_state = _state + SeedSystem.C1
		return SeedSystem.mix64(_state)

	## [0, bound) 的均匀整数；bound <= 0 时返回 0。
	func next_below(bound: int) -> int:
		if bound <= 1:
			return 0
		return (next_int() & SeedSystem.MASK53) % bound

	## [low, high] 的均匀整数（闭区间；high < low 时交换）。
	func next_range(low: int, high: int) -> int:
		if high < low:
			var swap := low
			low = high
			high = swap
		return low + next_below(high - low + 1)

	## [0,1) 浮点，仅供调试可视化；世界生成内部禁止使用。
	func next_u01() -> float:
		return SeedSystem.u01(next_int())


## 在 (seed, salt, 坐标) 上开一条确定性流。
static func rng_at(seed_value: int, layer_salt: int, x: int, y: int) -> Stream:
	return Stream.new(hash2(seed_value, layer_salt, x, y))


## 在 64 位 id 上开一条确定性流（矿脉等没有二维坐标的实体）。
static func rng_at_id(seed_value: int, layer_salt: int, entity_id: int) -> Stream:
	return Stream.new(hash2(seed_value, layer_salt, entity_id & MASK32, ushr(entity_id, 32) & MASK32))


## FNV-1a 64：字符串盐、种子回退解析、ChunkHasher 共用。
static func fnv1a64_bytes(data: PackedByteArray) -> int:
	var h := FNV_OFFSET
	for index in data.size():
		h = (h ^ int(data[index])) * FNV_PRIME
	return h


static func fnv1a64(text: String) -> int:
	return fnv1a64_bytes(text.to_utf8_buffer())


## 把任意字符串解析成 64 位种子。分支语义见 docs/worldgen.md §种子格式。
static func parse_seed(text: String) -> int:
	var trimmed := text.strip_edges()
	if trimmed.is_empty():
		return fnv1a64("")
	var pattern := RegEx.create_from_string(DECIMAL_PATTERN)
	if pattern.search(trimmed) != null:
		var parsed := trimmed.to_int()
		# 往返校验：超出 int64 会被 saturate / 报错，往返失败即回退到字符串哈希。
		if str(parsed) == trimmed:
			return parsed
	var hex_pattern := RegEx.create_from_string(HEX_PATTERN)
	if hex_pattern.search(trimmed) != null:
		return _parse_hex(trimmed)
	return fnv1a64(trimmed)


## 手动按位累积十六进制，避免 String.hex_to_int() 在 >2^63 时报错并返回错值。
static func _parse_hex(text: String) -> int:
	var value := 0
	for index in range(2, text.length()):
		value = value * 16 + _hex_digit(text.unicode_at(index))
	return value


static func _hex_digit(code: int) -> int:
	if code >= 48 and code <= 57:
		return code - 48
	if code >= 97 and code <= 102:
		return code - 87
	if code >= 65 and code <= 70:
		return code - 55
	return 0


## 种子的规范字符串：始终十进制有符号（JSON 必须按字符串存储，否则 double 丢精度）。
static func seed_to_string(seed_value: int) -> String:
	return str(seed_value)


## 生成本次会话的新种子：只在"新档且未指定种子"时调用一次，之后固定写入 global.json。
static func random_seed() -> int:
	var ticks := Time.get_unix_time_from_system()
	var noisy := int(ticks * 1000.0) ^ Time.get_ticks_usec()
	return splitmix64(noisy)


## 稳定的 16 进制小写表示（用于黄金哈希输出，避免 %x 对负数的实现差异）。
static func to_hex64(value: int) -> String:
	var digits := "0123456789abcdef"
	var chars: Array[String] = []
	for index in 16:
		chars.append(digits.substr((value >> (60 - index * 4)) & 0xF, 1))
	return "".join(chars)