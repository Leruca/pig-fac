extends SceneTree
## 种子对拍 CLI：输出/比较每块黄金哈希，可生成 golden/hashes.json。
##
## 用法：
##   godot --headless --path . -s res://tools/seed_compare.gd -- --seed 123 --chunks 0,0 1,0 [-2,3]
##   godot --headless --path . -s res://tools/seed_compare.gd -- --update-golden
##
## 输出每块 "chunk=x,y hash=<16 hex>"，同 checkout 双跑 diff 为空 = 确定性验收。

const GOLDEN_PATH := "res://tests/golden/hashes.json"
const DEFAULT_SEEDS := ["12345", "0", "-1", "9223372036854775807", "hello猪"]
const DEFAULT_CHUNKS := [[0, 0], [1, 0], [0, 1], [-1, -1], [2, 3]]


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--update-golden"):
		_update_golden()
		quit(0)
		return
	if args.has("--export-json"):
		_export_json(_arg_value(args, "--export-json", "user://golden_export.json"))
		quit(0)
		return
	var seeds: Array[String] = []
	var chunks: Array = []
	var index := 0
	while index < args.size():
		var arg := str(args[index])
		if arg == "--seed" and index + 1 < args.size():
			seeds.append(str(args[index + 1]))
			index += 2
			continue
		if arg == "--chunks":
			index += 1
			while index < args.size() and not str(args[index]).begins_with("--"):
				chunks.append(_parse_chunk(str(args[index])))
				index += 1
			continue
		index += 1
	if seeds.is_empty():
		seeds.append("12345")
	if chunks.is_empty():
		chunks.append(Vector2i(0, 0))

	var config := WorldGenConfig.load_default()
	for seed_text in seeds:
		var seed_value := SeedSystem.parse_seed(seed_text)
		for chunk in chunks:
			var generator := WorldGenerator.new(config, seed_value)
			var data := generator.generate_chunk(chunk)
			var hash := ChunkHasher.chunk_hash(
				seed_value, config.worldgen_version, chunk, data.terrain, data.obstacles, data.ores
			)
			print("seed=%s chunk=%d,%d hash=%s obstacles=%d ores=%d" % [
				seed_text, chunk.x, chunk.y, hash, data.obstacles.size(), data.ores.size()
			])
	quit(0)


func _update_golden() -> void:
	var config := WorldGenConfig.load_default()
	var entries: Array = []
	for seed_text in DEFAULT_SEEDS:
		var seed_value := SeedSystem.parse_seed(seed_text)
		for pair in DEFAULT_CHUNKS:
			var chunk := Vector2i(int(pair[0]), int(pair[1]))
			var generator := WorldGenerator.new(config, seed_value)
			var data := generator.generate_chunk(chunk)
			var hash := ChunkHasher.chunk_hash(
				seed_value, config.worldgen_version, chunk, data.terrain, data.obstacles, data.ores
			)
			entries.append({
				"seed": seed_text,
				"chunk": [chunk.x, chunk.y],
				"hash": hash,
				"obstacles": data.obstacles.size(),
				"ores": data.ores.size(),
			})
			print("golden seed=%s chunk=%d,%d hash=%s" % [seed_text, chunk.x, chunk.y, hash])
	var payload := {
		"note": "黄金哈希：worldgen 有意变更后必须重新生成并 Review diff（见 docs/worldgen.md）。",
		"worldgen_version": config.worldgen_version,
		"entries": entries,
	}
	var dir := DirAccess.open("res://tests")
	if dir != null and not dir.dir_exists("golden"):
		dir.make_dir("golden")
	var file := FileAccess.open(GOLDEN_PATH, FileAccess.WRITE)
	if file == null:
		push_error("无法写入 %s" % GOLDEN_PATH)
		return
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()
	print("已写入 %d 条黄金哈希 -> %s" % [entries.size(), GOLDEN_PATH])


## 导出完整序列化输入（地形字节 + 障碍 + 矿 + hash），供 tools/golden_check.py 用
## 独立 Python 实现复算黄金哈希 —— 跨语言验证"规范化序列化"这一步没有漂移。
func _export_json(path: String) -> void:
	var config := WorldGenConfig.load_default()
	var entries: Array = []
	for seed_text in DEFAULT_SEEDS:
		var seed_value := SeedSystem.parse_seed(seed_text)
		for pair in DEFAULT_CHUNKS:
			var chunk := Vector2i(int(pair[0]), int(pair[1]))
			var generator := WorldGenerator.new(config, seed_value)
			var data := generator.generate_chunk(chunk)
			var hash := ChunkHasher.chunk_hash(
				seed_value, config.worldgen_version, chunk, data.terrain, data.obstacles, data.ores
			)
			var terrain_bytes: Array = []
			for value in data.terrain:
				terrain_bytes.append(int(value))
			var obstacles: Array = []
			for obstacle in data.obstacles:
				var cell: Vector2i = obstacle["cell"]
				obstacles.append({
					"cell": [cell.x, cell.y],
					"kind": int(obstacle["kind"]),
					"hp": int(obstacle["hp"]),
				})
			var ores: Array = []
			for ore in data.ores:
				var cell: Vector2i = ore["cell"]
				ores.append({
					"cell": [cell.x, cell.y],
					"ore_id": int(ore["ore_id"]),
					"amount": int(ore["amount"]),
					"vein_id": int(ore.get("vein_id", 0)),
				})
			entries.append({
				"seed_text": seed_text,
				"seed_int": seed_value,
				"worldgen_version": config.worldgen_version,
				"chunk": [chunk.x, chunk.y],
				"hash": hash,
				"terrain": terrain_bytes,
				"obstacles": obstacles,
				"ores": ores,
			})
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		print("无法写入 %s" % path)
		return
	file.store_string(JSON.stringify({"entries": entries}))
	file.close()
	print("已导出 %d 条完整序列化输入 -> %s" % [entries.size(), path])


func _arg_value(args: PackedStringArray, key: String, fallback: String) -> String:
	for index in args.size():
		if str(args[index]) == key and index + 1 < args.size():
			return str(args[index + 1])
	return fallback


func _parse_chunk(text: String) -> Vector2i:
	var cleaned := text.replace("[", "").replace("]", "")
	var parts := cleaned.split(",")
	if parts.size() < 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))