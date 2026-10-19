extends WorldGenTestBase
## 种子序列化与解析分支（§2.1）。
## 运行：godot --headless --path . -s res://tests/worldgen/test_seed_serialization.gd

const MAX_INT := 9223372036854775807
const MIN_INT := -9223372036854775808


func _run() -> void:
	_test_decimal_roundtrip()
	_test_hex()
	_test_fallback()
	_test_json_loses_precision()
	_finish("SEED SERIALIZATION TESTS")


func _test_decimal_roundtrip() -> void:
	for text in ["0", "1", "-1", "123456789", str(MAX_INT)]:
		var parsed := SeedSystem.parse_seed(text)
		_check_equal(str(parsed), text, "十进制 %s 应原样往返" % text)
		# 再走一遍字符串化，确保 global.json 存/取闭环。
		_check_equal(SeedSystem.parse_seed(SeedSystem.seed_to_string(parsed)), parsed, "%s 经字符串往返后应不变" % text)


func _test_hex() -> void:
	_check_equal(SeedSystem.parse_seed("0x10"), 16, "0x10 应解析为 16")
	_check_equal(SeedSystem.parse_seed("0X10"), 16, "0X10 应解析为 16")
	_check_equal(SeedSystem.parse_seed("0x7FFFFFFFFFFFFFFF"), MAX_INT, "最大正值十六进制")
	# 超 2^63 的高位自然落为负 int，位模式唯一（不能被 String.hex_to_int 的报错吞掉）。
	_check_equal(SeedSystem.parse_seed("0xFFFFFFFFFFFFFFFF"), -1, "全 1 位模式应落为 -1")
	_check_equal(SeedSystem.parse_seed("0x8000000000000000"), MIN_INT, "最高位为 1 应落为最小 int64")


func _test_fallback() -> void:
	# 超精度数字：往返校验失败 → 回退到字符串哈希。
	var overflow := SeedSystem.parse_seed("9223372036854775808")
	_check_equal(overflow, SeedSystem.fnv1a64("9223372036854775808"), "溢出数字应回退到字符串哈希")
	# 非数字字符串（含中文）稳定且与空串不同。
	var chinese := SeedSystem.parse_seed("hello猪")
	_check_equal(chinese, SeedSystem.parse_seed("hello猪"), "中文字符串解析应稳定")
	_check_equal(SeedSystem.parse_seed("hello猪 "), chinese, "尾部空格被 strip 后应得到同一种子")
	_check(chinese != SeedSystem.parse_seed(""), "非空字符串不应与空串同种子")
	_check_equal(SeedSystem.parse_seed(""), SeedSystem.fnv1a64(""), "空串回退到 FNV-1a 空输入")
	_check_equal(SeedSystem.parse_seed(" 42 "), 42, "前后空白应被 strip")
	_check_equal(
		SeedSystem.parse_seed("+7"),
		SeedSystem.fnv1a64("+7"),
		"前导 + 不在十进制分支内，应回退字符串哈希"
	)


## 需求「种子存字符串」的硬理由：JSON 大整数必丢精度。
func _test_json_loses_precision() -> void:
	var payload := JSON.stringify({"seed": MAX_INT})
	var parsed: Variant = JSON.parse_string(payload)
	_check(parsed is Dictionary, "JSON 解析应成功")
	var value: Variant = (parsed as Dictionary)["seed"]
	var lossless := typeof(value) == TYPE_INT and int(value) == MAX_INT
	_check(not lossless, "直接存 JSON 数值应当丢精度（这正是必须存字符串的理由）")
	# 存字符串则无损。
	var string_payload := JSON.stringify({"seed": SeedSystem.seed_to_string(MAX_INT)})
	var string_parsed: Dictionary = JSON.parse_string(string_payload)
	_check_equal(SeedSystem.parse_seed(str(string_parsed["seed"])), MAX_INT, "以字符串存储必须无损")