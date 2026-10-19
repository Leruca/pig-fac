extends WorldGenTestBase
## 黄金哈希（§8 / 验收 12）：对拍 tests/golden/hashes.json。
## 更新流程：确认 worldgen 变更是**有意**的 → 运行 tools/seed_compare.gd -- --update-golden → Review diff。
## 运行：godot --headless --path . -s res://tests/worldgen/test_golden_hashes.gd

const GOLDEN_PATH := "res://tests/golden/hashes.json"


func _run() -> void:
	if not FileAccess.file_exists(GOLDEN_PATH):
		_check(false, "缺少黄金哈希文件 %s（先跑 tools/seed_compare.gd -- --update-golden）" % GOLDEN_PATH)
		_finish("GOLDEN HASH TESTS")
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(GOLDEN_PATH))
	_check(parsed is Dictionary, "黄金哈希文件应是 JSON 对象")
	if not (parsed is Dictionary):
		_finish("GOLDEN HASH TESTS")
		return
	var golden: Dictionary = parsed
	_check_equal(int(golden.get("worldgen_version", -1)), config.worldgen_version, "黄金哈希的 worldgen_version 必须与当前配置一致")
	var entries: Array = golden.get("entries", [])
	_check(entries.size() > 0, "黄金哈希文件应至少有一项")
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var seed_text := str(entry.get("seed", "0"))
		var seed_value := SeedSystem.parse_seed(seed_text)
		var chunk := Vector2i(int(entry["chunk"][0]), int(entry["chunk"][1]))
		var generator := WorldGenerator.new(config, seed_value)
		var data := generator.generate_chunk(chunk)
		var hash := ChunkHasher.chunk_hash(
			seed_value, config.worldgen_version, chunk, data.terrain, data.obstacles, data.ores
		)
		_check_equal(
			hash,
			str(entry.get("hash", "")),
			"种子 %s 区块 %s 的黄金哈希必须一致" % [seed_text, str(chunk)]
		)
	# 再跑一遍，确保本进程内两次结果一致（catch 掉跨次运行的不确定性）。
	var first := entries[0] as Dictionary
	if not first.is_empty():
		var seed_a := SeedSystem.parse_seed(str(first.get("seed", "0")))
		var chunk_a := Vector2i(int(first["chunk"][0]), int(first["chunk"][1]))
		var gen_a := WorldGenerator.new(config, seed_a)
		var data_a := gen_a.generate_chunk(chunk_a)
		var hash_a := ChunkHasher.chunk_hash(seed_a, config.worldgen_version, chunk_a, data_a.terrain, data_a.obstacles, data_a.ores)
		var gen_b := WorldGenerator.new(config, seed_a)
		var data_b := gen_b.generate_chunk(chunk_a)
		var hash_b := ChunkHasher.chunk_hash(seed_a, config.worldgen_version, chunk_a, data_b.terrain, data_b.obstacles, data_b.ores)
		_check_equal(hash_b, hash_a, "同一进程内两次生成必须逐位一致")
	_finish("GOLDEN HASH TESTS")
