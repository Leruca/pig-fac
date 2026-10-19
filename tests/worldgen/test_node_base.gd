class_name WorldGenNodeTestBase
extends Node
## 场景版测试基类：需要 autoload（ItemDB）或真实节点树（WorldObjects/ChunkManager）的测试用它。
## 运行：godot --headless --path . res://tests/worldgen/<name>.tscn

var _failures: Array[String] = []
var _checks := 0
var config: WorldGenConfig


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures.append(message)


func _check_equal(actual: Variant, expected: Variant, message: String) -> void:
	_checks += 1
	if actual != expected:
		_failures.append("%s（期望 %s，实际 %s）" % [message, str(expected), str(actual)])


func _finish(label: String) -> void:
	if _failures.is_empty():
		print("%s PASSED (%d checks)" % [label, _checks])
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error("%s FAILED: %s" % [label, failure])
		print("%s FAILED: %d/%d checks" % [label, _failures.size(), _checks])
		get_tree().quit(1)
