extends SceneTree
## 编译自检：加载 scripts/ 下所有 GDScript，报告编译失败的文件。
## 用法：godot --headless --path . -s res://tests/tool_compile_check.gd

const ROOTS := ["res://scripts", "res://tests", "res://tools"]

func _initialize() -> void:
	var failures: Array[String] = []
	var files: Array[String] = []
	for root in ROOTS:
		_collect(root, files)
	files.sort()
	for path in files:
		if path.ends_with("tool_compile_check.gd"):
			continue
		var script: Variant = load(path)
		if script == null or not (script is Script):
			failures.append(path)
			print("FAIL %s" % path)
		elif script.get_instance_base_type() == "" and script.can_instantiate() == false:
			# 解析失败时 load 可能仍返回 GDScript 但不能实例化；用它做二次判定。
			failures.append(path)
			print("FAIL (cannot instantiate) %s" % path)
	print("compile check: %d files, %d failures" % [files.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)


func _collect(root: String, out: Array[String]) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		return
	for file_name in dir.get_files():
		if file_name.ends_with(".gd"):
			out.append("%s/%s" % [root, file_name])
	for sub in dir.get_directories():
		_collect("%s/%s" % [root, sub], out)
