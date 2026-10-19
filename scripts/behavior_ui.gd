class_name BehaviorUI
extends PanelContainer
## 右下角行为设计面板：拖动排序、反复添加四种模块，由 Main 以 1 秒 1 次互动执行。

signal area_pick_requested(module_index: int)
signal container_pick_requested(module_index: int)
signal position_pick_requested(module_index: int)
signal program_changed

const ITEM_OPTIONS: Array[String] = [
	"potato", "carrot", "wood", "planks", "stick", "chest", "fence",
	"stone", "stone_brick", "furnace", "sapling", "pig_nest", "pig",
	"hoe", "super_watering_can", "shovel", "hammer",
]
const TOOL_OPTIONS := [
	{"id": "hoe", "name": "锄头"},
	{"id": "super_watering_can", "name": "超级水壶"},
	{"id": "shovel", "name": "铲子"},
	{"id": "hammer", "name": "锤子"},
	{"id": "potato", "name": "土豆种子"},
	{"id": "carrot", "name": "胡萝卜种子"},
	{"id": "hand", "name": "空手 / 收割"},
]
const INVALID_CELL := Vector2i(-999999, -999999)

var _pig: Pig
var _title_label: Label
var _run_button: Button
var _status_label: Label
var _step_label: Label
var _list: VBoxContainer
var _scroll: ScrollContainer
var _picker_overlay: Control
var _picker_title: Label
var _picker_caption: Label
var _picker_grid: GridContainer
var _picker_mode := ""
var _picker_module := -1


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(500.0, 0.0)
	add_theme_stylebox_override("panel", UIStyle.make_panel(UIStyle.PANEL, 18))
	_build_layout()


func setup(pig: Pig) -> void:
	_pig = pig
	_title_label.text = "行为设计 · %s" % (pig.display_name if pig != null else "")
	_hide_picker()
	_refresh()


func unbind() -> void:
	_pig = null
	_hide_picker()
	visible = false


func is_open() -> bool:
	return visible


func set_module_position(index: int, cell: Vector2i) -> void:
	if _pig == null or index < 0 or index >= _pig.behavior_program.size():
		return
	_pig.behavior_program[index]["cell"] = cell
	_refresh()
	program_changed.emit()


func set_module_area(index: int, area: Rect2i) -> void:
	if _pig == null or index < 0 or index >= _pig.behavior_program.size():
		return
	_pig.behavior_program[index]["rect"] = area
	_refresh()
	program_changed.emit()


func set_module_container(index: int, cell: Vector2i) -> void:
	if _pig == null or index < 0 or index >= _pig.behavior_program.size():
		return
	_pig.behavior_program[index]["container_cell"] = cell
	_refresh()
	program_changed.emit()


func set_runtime_step(text: String) -> void:
	if _step_label != null:
		_step_label.text = text


func move_module(from_index: int, to_index: int) -> void:
	if _pig == null:
		return
	var program := _pig.behavior_program
	if from_index < 0 or from_index >= program.size():
		return
	if to_index < 0 or to_index >= program.size() or from_index == to_index:
		return
	var module := program[from_index]
	program.remove_at(from_index)
	program.insert(to_index, module)
	_refresh()
	program_changed.emit()


func _build_layout() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	var header := HBoxContainer.new()
	content.add_child(header)
	_title_label = _make_label("行为设计", 20, UIStyle.TEXT, true)
	header.add_child(_title_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	var clear_button := _make_button("清空", 54.0)
	clear_button.pressed.connect(_clear_program)
	header.add_child(clear_button)

	var subtitle := _make_label("拖动排序 · 自动时锁定手动操作 · 每 1 秒互动一次", 11, UIStyle.TEXT_MUTED)
	content.add_child(subtitle)

	var run_row := HBoxContainer.new()
	run_row.add_theme_constant_override("separation", 8)
	content.add_child(run_row)
	_run_button = _make_button("开始自动", 104.0)
	_run_button.pressed.connect(_toggle_run)
	run_row.add_child(_run_button)
	_status_label = _make_label("已暂停", 12, UIStyle.TEXT_MUTED)
	_status_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	run_row.add_child(_status_label)

	_step_label = _make_label("步骤：—", 11, UIStyle.TEXT_MUTED)
	content.add_child(_step_label)

	var palette := GridContainer.new()
	palette.columns = 2
	palette.add_theme_constant_override("h_separation", 6)
	palette.add_theme_constant_override("v_separation", 5)
	content.add_child(palette)
	palette.add_child(_make_add_button("移动到位置", "move"))
	palette.add_child(_make_add_button("区域使用工具", "tool"))
	palette.add_child(_make_add_button("把物品存入容器", "store"))
	palette.add_child(_make_add_button("从容器拿取物品", "take"))

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0.0, 180.0)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_scroll)

	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 5)
	_scroll.add_child(_list)
	_build_picker_overlay()


func _make_add_button(text: String, type: String) -> Button:
	var button := _make_button(text, 0.0)
	button.custom_minimum_size = Vector2(0.0, 30.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(_add_module.bind(type))
	return button


func _build_picker_overlay() -> void:
	_picker_overlay = Control.new()
	_picker_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_picker_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_picker_overlay.visible = false
	add_child(_picker_overlay)

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.02, 0.03, 0.02, 0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_picker_dim_input)
	_picker_overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_picker_overlay.add_child(center)

	var window := PanelContainer.new()
	window.custom_minimum_size = Vector2(382.0, 240.0)
	window.mouse_filter = Control.MOUSE_FILTER_STOP
	window.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(UIStyle.PANEL, 12, UIStyle.ACCENT, 1, true)
	)
	center.add_child(window)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	window.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	margin.add_child(content)

	var header := HBoxContainer.new()
	content.add_child(header)
	_picker_title = _make_label("选择工具", 16, UIStyle.TEXT, true)
	header.add_child(_picker_title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	var close := _make_button("×", 28.0)
	close.pressed.connect(_hide_picker)
	header.add_child(close)

	_picker_caption = _make_label("", 11, UIStyle.TEXT_MUTED)
	content.add_child(_picker_caption)

	_picker_grid = GridContainer.new()
	_picker_grid.columns = 5
	_picker_grid.add_theme_constant_override("h_separation", 5)
	_picker_grid.add_theme_constant_override("v_separation", 5)
	content.add_child(_picker_grid)


func _on_picker_dim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
			_hide_picker()


func _hide_picker() -> void:
	if _picker_overlay != null:
		_picker_overlay.visible = false
	_picker_mode = ""
	_picker_module = -1


func _add_module(type: String) -> void:
	if _pig == null:
		return
	var cell := _pig.target_cell
	var module: Dictionary
	match type:
		"move":
			module = {"type": "move", "cell": cell}
		"tool":
			module = {"type": "tool", "item_id": "hoe", "rect": Rect2i()}
		"store":
			module = {"type": "store", "container_cell": INVALID_CELL, "item_id": "potato"}
		"take":
			module = {"type": "take", "container_cell": INVALID_CELL, "item_id": "potato"}
		_:
			return
	_pig.behavior_program.append(module)
	_refresh()
	program_changed.emit()


func _clear_program() -> void:
	if _pig == null:
		return
	_pig.behavior_program.clear()
	_pig.behavior_running = false
	_refresh()
	program_changed.emit()


func _delete_module(index: int) -> void:
	if _pig == null or index < 0 or index >= _pig.behavior_program.size():
		return
	_pig.behavior_program.remove_at(index)
	if _pig.behavior_program.is_empty():
		_pig.behavior_running = false
	_refresh()
	program_changed.emit()


func _toggle_run() -> void:
	if _pig == null:
		return
	if _pig.behavior_program.is_empty():
		return
	_pig.behavior_running = not _pig.behavior_running
	_refresh_status()


func _refresh() -> void:
	if _title_label == null:
		return
	if _pig != null:
		_title_label.text = "行为设计 · %s" % _pig.display_name
	for child in _list.get_children():
		_list.remove_child(child)
		child.queue_free()
	var program: Array = _pig.behavior_program if _pig != null else []
	if program.is_empty():
		_list.add_child(_make_label("还没有模块。点上方按钮添加，模块可以反复添加。", 12, UIStyle.TEXT_MUTED))
	else:
		for index in program.size():
			_list.add_child(_build_module_row(index, program[index]))
	_refresh_status()


func _refresh_status() -> void:
	if _run_button == null or _pig == null:
		return
	if _pig.behavior_program.is_empty():
		_pig.behavior_running = false
	_run_button.disabled = _pig.behavior_program.is_empty()
	if _pig.behavior_running and not _pig.behavior_program.is_empty():
		_run_button.text = "暂停自动"
		_status_label.text = "运行中 · %d 个模块" % _pig.behavior_program.size()
		_status_label.add_theme_color_override("font_color", UIStyle.GOOD)
	else:
		_run_button.text = "开始自动"
		_status_label.text = "已暂停"
		_status_label.add_theme_color_override("font_color", UIStyle.TEXT_MUTED)
		if _step_label != null:
			_step_label.text = "步骤：已暂停"


func _build_module_row(index: int, module: Dictionary) -> Control:
	var row := BehaviorModuleRow.new()
	row.owner_ui = self
	row.module_index = index
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(Color(0.10, 0.14, 0.09, 0.94), 8, UIStyle.SLOT_BORDER, 1, false)
	)
	var outer := HBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	outer.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(outer)

	var handle := _make_label("⋮⋮", 15, UIStyle.ACCENT, true)
	handle.custom_minimum_size = Vector2(24.0, 0.0)
	handle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = Control.CURSOR_DRAG
	handle.tooltip_text = "拖动排序"
	handle.set_drag_forwarding(
		_handle_drag_data.bind(index),
		_handle_can_drop.bind(index),
		_handle_drop.bind(index)
	)
	outer.add_child(handle)

	var badge := _make_label("#%d" % (index + 1), 11, UIStyle.ACCENT, true)
	badge.custom_minimum_size = Vector2(24.0, 0.0)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	outer.add_child(badge)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 3)
	body.mouse_filter = Control.MOUSE_FILTER_PASS
	outer.add_child(body)

	var type := str(module.get("type", ""))
	var title := _make_label(_module_title(type), 12, UIStyle.TEXT, true)
	body.add_child(title)
	match type:
		"move":
			body.add_child(_build_move_controls(index, module))
		"tool":
			body.add_child(_build_tool_controls(index, module))
		"store", "take":
			body.add_child(_build_container_controls(index, module))

	var delete_button := _make_button("×", 28.0)
	delete_button.custom_minimum_size = Vector2(28.0, 26.0)
	delete_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	delete_button.pressed.connect(_delete_module.bind(index))
	outer.add_child(delete_button)
	return row


func _build_move_controls(index: int, module: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var target: Vector2i = module.get("cell", Vector2i.ZERO)
	var label := _make_label("目标 (%d, %d)" % [target.x, target.y], 11, UIStyle.TEXT_MUTED)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	var pick := _make_button("选择位置", 86.0)
	pick.custom_minimum_size = Vector2(86.0, 26.0)
	pick.pressed.connect(_request_position.bind(index))
	row.add_child(pick)
	return row


func _build_tool_controls(index: int, module: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	box.add_child(top)
	var tool_id := str(module.get("item_id", "hoe"))
	top.add_child(_make_selector_button(tool_id, index, "tool"))
	var area_label := _make_label(_area_text(module.get("rect", Rect2i())), 11, UIStyle.TEXT_MUTED)
	area_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(area_label)
	var pick := _make_button("框选区域", 86.0)
	pick.custom_minimum_size = Vector2(86.0, 26.0)
	pick.pressed.connect(_request_area.bind(index))
	top.add_child(pick)
	return box


func _build_container_controls(index: int, module: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	box.add_child(top)
	var item_id := str(module.get("item_id", "potato"))
	top.add_child(_make_selector_button(item_id, index, "item"))
	var cell: Vector2i = module.get("container_cell", INVALID_CELL)
	var cell_text := "未选择容器"
	if cell != INVALID_CELL:
		cell_text = "容器 (%d,%d)" % [cell.x, cell.y]
	var cell_label := _make_label(cell_text, 11, UIStyle.TEXT_MUTED)
	cell_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(cell_label)
	var pick := _make_button("选择容器", 86.0)
	pick.custom_minimum_size = Vector2(86.0, 26.0)
	pick.pressed.connect(_request_container.bind(index))
	top.add_child(pick)
	return box


func _make_selector_button(item_id: String, index: int, mode: String) -> Button:
	var display_name := "空手" if item_id == "hand" else ItemDB.get_display_name(item_id)
	var button := _make_button(display_name, 132.0)
	button.custom_minimum_size = Vector2(132.0, 28.0)
	button.tooltip_text = display_name if item_id != "hand" else "空手 / 收割"
	button.pressed.connect(_show_picker.bind(mode, index))
	return button


func _show_picker(mode: String, module_index: int) -> void:
	if _pig == null or _picker_overlay == null:
		return
	if module_index < 0 or module_index >= _pig.behavior_program.size():
		return
	_picker_mode = mode
	_picker_module = module_index
	for child in _picker_grid.get_children():
		_picker_grid.remove_child(child)
		child.queue_free()
	if mode == "tool":
		_picker_title.text = "选择工具"
		_picker_caption.text = "不可用的工具会半透明显示；左上角空格代表空手。"
		_add_picker_entry("hand", module_index, true, true)
		for tool in TOOL_OPTIONS:
			var tool_id := str(tool["id"])
			if tool_id == "hand":
				continue
			_add_picker_entry(tool_id, module_index, _tool_available(tool_id), false)
	else:
		_picker_title.text = "选择物品"
		_picker_caption.text = "点击图标选择要存入/取出的物品。"
		for item_id in ITEM_OPTIONS:
			_add_picker_entry(item_id, module_index, true, false)
	_picker_overlay.visible = true


func _add_picker_entry(item_id: String, module_index: int, available: bool, empty_slot: bool) -> void:
	var module: Dictionary = _pig.behavior_program[module_index]
	var current := str(module.get("item_id", ""))
	var button := Button.new()
	button.custom_minimum_size = Vector2(58.0, 58.0)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_stylebox_override(
		"normal",
		UIStyle.make_panel(
			Color(0.12, 0.17, 0.10, 0.96),
			9,
			UIStyle.ACCENT if item_id == current else UIStyle.SLOT_BORDER,
			2 if item_id == current else 1,
			false
		)
	)
	button.add_theme_stylebox_override(
		"hover",
		UIStyle.make_panel(Color(0.20, 0.27, 0.15, 1.0), 9, UIStyle.ACCENT, 1, false)
	)
	if empty_slot:
		button.tooltip_text = "空手"
		button.add_theme_stylebox_override(
			"normal",
			UIStyle.make_panel(
				Color(0.12, 0.17, 0.10, 0.96),
				9,
				UIStyle.ACCENT if item_id == current else UIStyle.TEXT_MUTED,
				2 if item_id == current else 1,
				false
			)
		)
	else:
		button.tooltip_text = ItemDB.get_display_name(item_id)
		if not available:
			button.disabled = true
			button.modulate = Color(1.0, 1.0, 1.0, 0.34)
			button.tooltip_text += "（背包里没有）"
		_add_picker_icon(button, ItemDB.get_icon(item_id))
	button.pressed.connect(_choose_picker_entry.bind(item_id))
	_picker_grid.add_child(button)


func _add_picker_icon(button: Button, texture: Texture2D) -> void:
	if texture == null:
		return
	var icon := TextureRect.new()
	icon.texture = texture
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 9.0
	icon.offset_top = 9.0
	icon.offset_right = -9.0
	icon.offset_bottom = -9.0
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(icon)


func _tool_available(tool_id: String) -> bool:
	if _pig == null:
		return false
	if tool_id == "hand":
		return true
	return _pig.inventory.get_total_count(tool_id) > 0


func _choose_picker_entry(item_id: String) -> void:
	if _pig == null or _picker_module < 0 or _picker_module >= _pig.behavior_program.size():
		_hide_picker()
		return
	if _picker_mode == "tool" and item_id != "hand" and not _tool_available(item_id):
		return
	_pig.behavior_program[_picker_module]["item_id"] = item_id
	_hide_picker()
	_refresh()
	program_changed.emit()


func _request_position(index: int) -> void:
	position_pick_requested.emit(index)


func _request_area(index: int) -> void:
	area_pick_requested.emit(index)


func _request_container(index: int) -> void:
	container_pick_requested.emit(index)


func _handle_drag_data(_at_position: Vector2, index: int) -> Variant:
	return {"behavior_module_index": index}


func _handle_can_drop(_at_position: Vector2, _data: Variant, _index: int) -> bool:
	return true


func _handle_drop(_at_position: Vector2, data: Variant, index: int) -> void:
	if data is Dictionary and data.has("behavior_module_index"):
		move_module(int(data.get("behavior_module_index", -1)), index)


func _area_text(rect_value: Variant) -> String:
	if not (rect_value is Rect2i):
		return "未框选"
	var rect: Rect2i = rect_value
	if rect.size.x <= 0 or rect.size.y <= 0:
		return "未框选"
	return "区域 (%d,%d) %d×%d" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y]


func _module_title(type: String) -> String:
	match type:
		"move":
			return "移动到指定格子"
		"tool":
			return "区域内使用工具"
		"store":
			return "把背包物品存入容器"
		"take":
			return "从容器拿取物品"
		_:
			return "未知模块"


func _make_button(text: String, min_width: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(min_width, 30.0)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", UIStyle.bold_font())
	button.add_theme_font_size_override("font_size", 12)
	button.add_theme_color_override("font_color", UIStyle.TEXT)
	button.add_theme_color_override("font_hover_color", UIStyle.ACCENT)
	button.add_theme_stylebox_override(
		"normal",
		UIStyle.make_panel(Color(0.19, 0.24, 0.15, 0.97), 7, UIStyle.SLOT_BORDER, 1, false)
	)
	button.add_theme_stylebox_override(
		"hover",
		UIStyle.make_panel(Color(0.25, 0.31, 0.20, 1.0), 7, UIStyle.ACCENT, 1, false)
	)
	button.add_theme_stylebox_override(
		"pressed",
		UIStyle.make_panel(Color(0.13, 0.17, 0.10, 1.0), 7, UIStyle.ACCENT, 1, false)
	)
	button.add_theme_stylebox_override(
		"disabled",
		UIStyle.make_panel(Color(0.11, 0.14, 0.09, 0.9), 7, UIStyle.SLOT_BORDER, 1, false)
	)
	return button


func _make_label(
	text: String,
	font_size: int,
	color: Color = UIStyle.TEXT,
	use_bold: bool = false
) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_override("font", UIStyle.bold_font() if use_bold else UIStyle.regular_font())
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
