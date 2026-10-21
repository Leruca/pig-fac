class_name SavePaths
extends RefCounted
## 存档路径集中管理；测试通过 PIGFAC_TEST_SAVE_ROOT 或 set_root() 隔离，
## 绝不把测试数据写进玩家的 user://saves/main。

const DEFAULT_ROOT := "user://saves/main"
const SLOTS_ROOT := "user://saves/slots"
const ACTIVE_SLOT_FILE := "user://saves/active_slot.txt"

static var _root_override := ""


static func set_root(path: String) -> void:
	_root_override = path


static func reset_root() -> void:
	_root_override = ""


static func slot_path(slot_id: String) -> String:
	if slot_id == "main" or slot_id.is_empty():
		return DEFAULT_ROOT
	return "%s/%s" % [SLOTS_ROOT, slot_id]


static func current_slot() -> String:
	if not _root_override.is_empty():
		return "main"
	var env := OS.get_environment("PIGFAC_TEST_SAVE_ROOT").strip_edges()
	if not env.is_empty():
		return "main"
	if FileAccess.file_exists(ACTIVE_SLOT_FILE):
		var id := FileAccess.get_file_as_string(ACTIVE_SLOT_FILE).strip_edges()
		if not id.is_empty():
			return id
	return "main"


static func set_current_slot(slot_id: String) -> bool:
	var clean := slot_id.strip_edges()
	if clean.is_empty() or clean.contains("/") or clean.contains("\\") or clean == "." or clean == "..":
		return false
	var parent := ACTIVE_SLOT_FILE.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent):
		if DirAccess.make_dir_recursive_absolute(parent) != OK:
			return false
	var file := FileAccess.open(ACTIVE_SLOT_FILE, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(clean)
	file.close()
	return true


## 无限存档槽：返回 "main"（旧存档）与 saves/slots 下所有已存在的槽位。
static func list_slots() -> Array[String]:
	var out: Array[String] = []
	if FileAccess.file_exists(DEFAULT_ROOT + "/global.json"):
		out.append("main")
	var dir := DirAccess.open(SLOTS_ROOT)
	if dir != null:
		for child in dir.get_directories():
			if FileAccess.file_exists("%s/%s/global.json" % [SLOTS_ROOT, child]):
				out.append(child)
	var active := current_slot()
	if not active.is_empty() and not out.has(active):
		out.append(active)
	return out


## 创建新槽位（不覆盖任何已有目录），并设为当前槽。
static func create_slot(prefix: String = "slot") -> String:
	var base := prefix.strip_edges()
	if base.is_empty():
		base = "slot"
	var index := 1
	while true:
		var candidate := "%s_%d" % [base, index]
		var path := slot_path(candidate)
		if not DirAccess.dir_exists_absolute(path):
			if DirAccess.make_dir_recursive_absolute(path + "/blocks") != OK:
				return ""
			if not set_current_slot(candidate):
				return ""
			return candidate
		index += 1
	return ""


static func root() -> String:
	if not _root_override.is_empty():
		return _root_override
	var env := OS.get_environment("PIGFAC_TEST_SAVE_ROOT").strip_edges()
	if not env.is_empty():
		return env
	return slot_path(current_slot())


static func blocks() -> String:
	return "%s/blocks" % root()


static func global_file() -> String:
	return "%s/global.json" % root()


static func seed_file() -> String:
	return "%s/seed.txt" % root()


static func ensure_dirs() -> bool:
	var root_dir := root()
	if root_dir.begins_with("user://"):
		var user_dir := DirAccess.open("user://")
		if user_dir == null:
			return false
		if user_dir.make_dir_recursive(root_dir.trim_prefix("user://")) != OK:
			return false
	else:
		if DirAccess.make_dir_recursive_absolute(root_dir) != OK:
			return false
	return DirAccess.make_dir_recursive_absolute(blocks()) == OK


## 新游戏用：删除整个存档目录（包括 global / blocks / seed）。
static func clear_root() -> bool:
	if DirAccess.dir_exists_absolute(root()):
		_remove_dir_recursive(root())
	return not DirAccess.dir_exists_absolute(root())


static func _remove_dir_recursive(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	for file_name in dir.get_files():
		dir.remove(file_name)
	for directory_name in dir.get_directories():
		_remove_dir_recursive("%s/%s" % [path, directory_name])
	DirAccess.remove_absolute(path)


static func atomic_write_text(path: String, text: String) -> bool:
	var parent := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent):
		if DirAccess.make_dir_recursive_absolute(parent) != OK:
			return false
	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(text)
	file.close()
	var dir := DirAccess.open(parent)
	if dir == null:
		return false
	var target_name := path.get_file()
	var tmp_name := tmp_path.get_file()
	# Godot 的 rename 在不同平台上对覆盖行为不完全一致；先尝试覆盖，
	# 失败时再删除旧文件重试。写入始终先落到 .tmp。
	if dir.rename(tmp_name, target_name) == OK:
		return true
	if dir.file_exists(target_name):
		dir.remove(target_name)
	if dir.rename(tmp_name, target_name) == OK:
		return true
	dir.remove(tmp_name)
	return false
