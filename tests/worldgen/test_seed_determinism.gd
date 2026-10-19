extends WorldGenTestBase
## 确定性：同种子同区块哈希一致；不同种子不同；int64 极值种子不溢出。
## 运行：godot --headless --path . -s res://tests/worldgen/test_seed_determinism.gd

const SEEDS := [12345, 0, -1, 9223372036854775807, -9223372036854775808 + 0]
const CHUNKS := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, -1), Vector2i(2, 3)]


func _run() -> void:
	_test_repeatable()
	_test_seed_sensitive()
	_test_extreme_seeds()
	_test_golden_hash_sensitive_to_terrain()
	_finish("SEED DETERMINISM TESTS")


func _seed_chunk_hash(seed_value: int, chunk: Vector2i) -> String:
	var generator := WorldGenerator.new(config, seed_value)
	var data := generator.generate_chunk(chunk)
	return ChunkHasher.chunk_hash(
		seed_value, config.worldgen_version, chunk, data.terrain, data.obstacles, data.ores
	)


func _test_repeatable() -> void:
	for seed_value in SEEDS.slice(0, 3):
		for chunk in CHUNKS:
			var first := _seed_chunk_hash(seed_value, chunk)
			var second := _seed_chunk_hash(seed_value, chunk)
			_check_equal(second, first, "同种子 %d 同区块 %s 两次哈希必须一致" % [seed_value, str(chunk)])


func _test_seed_sensitive() -> void:
	var chunk := Vector2i(0, 0)
	var seen := {}
	for seed_value in [12345, 54321, 999, 1000]:
		var hash := _seed_chunk_hash(seed_value, chunk)
		_check(not seen.has(hash), "不同种子 %d 不应与其它种子哈希相同" % seed_value)
		seen[hash] = true


## 极值种子：调试构建下跑全管线，溢出会立刻暴露（GDScript 溢出静默回绕，
## 因此这里同时校验"不报错"与"结果非退化"）。
func _test_extreme_seeds() -> void:
	for seed_value in [9223372036854775807, -1, 0]:
		var generator := WorldGenerator.new(config, seed_value)
		var data := generator.generate_chunk(Vector2i(0, 0))
		var hash := ChunkHasher.chunk_hash(
			seed_value, config.worldgen_version, Vector2i(0, 0), data.terrain, data.obstacles, data.ores
		)
		_check(hash.length() == 16, "极值种子 %d 的哈希应是 16 位十六进制" % seed_value)
		_check(data.terrain.size() == 65025, "极值种子 %d 的地形长度错误" % seed_value)
		# 地形至少有 2 种类型，避免"全草地/全水"的退化输出。
		var kinds := {}
		for value in data.terrain:
			kinds[value] = true
		_check(kinds.size() >= 2, "极值种子 %d 的地形应是多种类型（实际 %d 种）" % [seed_value, kinds.size()])


func _test_golden_hash_sensitive_to_terrain() -> void:
	var terrain := PackedByteArray()
	terrain.resize(4)
	var base := ChunkHasher.chunk_hash(1, 1, Vector2i.ZERO, terrain, [], [])
	terrain[0] = 1
	var changed := ChunkHasher.chunk_hash(1, 1, Vector2i.ZERO, terrain, [], [])
	_check(base != changed, "地形字节变化必须改变黄金哈希")
	var other_chunk := ChunkHasher.chunk_hash(1, 1, Vector2i(0, 1), terrain, [], [])
	_check(changed != other_chunk, "区块坐标必须参与黄金哈希")
	var other_version := ChunkHasher.chunk_hash(1, 2, Vector2i.ZERO, terrain, [], [])
	_check(changed != other_version, "worldgen_version 必须参与黄金哈希")