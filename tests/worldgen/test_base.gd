class_name WorldGenTestBase
extends SceneTree
## 世界生成测试基类（SceneTree，可直接 godot --headless -s 运行）。
## 约定：子类实现 _run()，退出码由 _finish() 决定。

var _failures: Array[String] = []
var _checks := 0
var config: WorldGenConfig


func _initialize() -> void:
	config = WorldGenConfig.load_default()
	_run()


func _run() -> void:
	push_error("测试类必须实现 _run()")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _check_equal(actual: Variant, expected: Variant, message: String) -> void:
	_checks += 1
	if actual != expected:
		_failures.append("%s（期望 %s，实际 %s）" % [message, str(expected), str(actual)])


func _check_almost(actual: float, expected: float, tolerance: float, message: String) -> void:
	_checks += 1
	if absf(actual - expected) > tolerance:
		_failures.append("%s（期望 %f ± %f，实际 %f）" % [message, expected, tolerance, actual])


func _finish(label: String) -> void:
	if _failures.is_empty():
		print("%s PASSED (%d checks)" % [label, _checks])
		quit(0)
	else:
		for failure in _failures:
			push_error("%s FAILED: %s" % [label, failure])
		print("%s FAILED: %d/%d checks" % [label, _failures.size(), _checks])
		quit(1)


func _chunks_in_rect(min_chunk: Vector2i, max_chunk: Vector2i) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for y in range(min_chunk.y, max_chunk.y + 1):
		for x in range(min_chunk.x, max_chunk.x + 1):
			out.append(Vector2i(x, y))
	return out


func _hash_of(generator: WorldGenerator, seed_value: int, data: ChunkData) -> String:
	return ChunkHasher.chunk_hash(
		seed_value, generator.config.worldgen_version, data.chunk, data.terrain, data.obstacles, data.ores
	)
