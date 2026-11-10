class_name BehaviorTemplateStore
extends RefCounted
## 行为程序磁盘模板：跨存档保存/读取，文件在 user://behavior_templates.json。

const PATH := "user://behavior_templates.json"


static func _read_all() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	return parsed if parsed is Dictionary else {}


static func _write_all(data: Dictionary) -> bool:
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


static func list_templates() -> Array[String]:
	var out: Array[String] = []
	var data := _read_all()
	for key in data.keys():
		out.append(str(key))
	out.sort()
	return out


static func save_template(name: String, program: Array) -> bool:
	var clean := name.strip_edges()
	if clean.is_empty():
		return false
	var data := _read_all()
	data[clean] = SaveCodec.encode(program)
	return _write_all(data)


static func load_template(name: String) -> Array[Dictionary]:
	var data := _read_all()
	var raw: Variant = data.get(name, [])
	var decoded: Variant = SaveCodec.decode(raw)
	var out: Array[Dictionary] = []
	if decoded is Array:
		for module in decoded:
			if module is Dictionary:
				out.append(module)
	return out


static func delete_template(name: String) -> bool:
	var data := _read_all()
	if not data.has(name):
		return false
	data.erase(name)
	return _write_all(data)
