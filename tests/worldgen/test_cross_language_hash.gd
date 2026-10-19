extends SceneTree
## 跨语言黄金哈希对拍（确定性可被独立实现复核）。
## 流程：本脚本导出"完整序列化输入" -> 调用 tools/golden_check.py（纯 Python 实现）-> 比对哈希。
## 运行：godot --headless --path . -s res://tests/worldgen/test_cross_language_hash.gd

const EXPORT_PATH := "user://golden_export.json"
const CHECKER := "res://tools/golden_check.py"

var _failures: Array[String] = []


func _initialize() -> void:
	var config := WorldGenConfig.load_default()
	var entries: Array = []
	var seeds := ["12345", "0", "-1", "9223372036854775807", "hello猪"]
	var chunks := [[0, 0], [1, 0], [-1, -1]]
	for seed_text in seeds:
		var seed_value := SeedSystem.parse_seed(seed_text)
		for pair in chunks:
			var chunk := Vector2i(int(pair[0]), int(pair[1]))
			var generator := WorldGenerator.new(config, seed_value)
			var data := generator.generate_chunk(chunk)
			var terrain_bytes: Array = []
			for value in data.terrain:
				terrain_bytes.append(int(value))
			var obstacles: Array = []
			for obstacle in data.obstacles:
				var cell: Vector2i = obstacle["cell"]
				obstacles.append({"cell": [cell.x, cell.y], "kind": int(obstacle["kind"]), "hp": int(obstacle["hp"])})
			var ores: Array = []
			for ore in data.ores:
				var ore_cell: Vector2i = ore["cell"]
				ores.append({
					"cell": [ore_cell.x, ore_cell.y],
					"ore_id": int(ore["ore_id"]),
					"amount": int(ore["amount"]),
					"vein_id": int(ore.get("vein_id", 0)),
				})
			entries.append({
				"seed_text": seed_text,
				"seed_int": seed_value,
				"worldgen_version": config.worldgen_version,
				"chunk": [chunk.x, chunk.y],
				"hash": ChunkHasher.chunk_hash(
					seed_value, config.worldgen_version, chunk, data.terrain, data.obstacles, data.ores
				),
				"terrain": terrain_bytes,
				"obstacles": obstacles,
				"ores": ores,
			})

	var file := FileAccess.open(EXPORT_PATH, FileAccess.WRITE)
	if file == null:
		_failures.append("无法写出导出文件")
		_report()
		return
	file.store_string(JSON.stringify({"entries": entries}))
	file.close()

	var python := OS.get_environment("PYTHON")
	if python.is_empty():
		python = "python3"
	var checker_path := ProjectSettings.globalize_path(CHECKER)
	var export_path := ProjectSettings.globalize_path(EXPORT_PATH)
	var output: Array = []
	var code := OS.execute(python, [checker_path, export_path], output, true)
	var text := "\n".join(output)
	print(text.strip_edges())
	if code != 0:
		_failures.append("Python 独立实现复算失败（exit=%d）：%s" % [code, text.strip_edges()])
	elif not text.contains("0 mismatches"):
		_failures.append("Python 复算必须报告 0 mismatches")
	if entries.size() < 15:
		_failures.append("至少应对拍 15 条（实际 %d）" % entries.size())
	_report()


func _report() -> void:
	if _failures.is_empty():
		print("CROSS LANGUAGE HASH TESTS PASSED")
		quit(0)
	else:
		for failure in _failures:
			push_error("CROSS LANGUAGE HASH TESTS FAILED: %s" % failure)
		print("CROSS LANGUAGE HASH TESTS FAILED: %d" % _failures.size())
		quit(1)
