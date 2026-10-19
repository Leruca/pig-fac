class_name EscMenu
extends Control
## Esc 暂停菜单：继续、保存、读取、音效开关。

signal resume_requested
signal save_requested
signal load_requested
signal volume_toggle_requested
signal new_game_requested(seed_text: String)

var _status_label: Label
var _save_path_label: Label
var _seed_label: Label
var _seed_input: LineEdit
var _new_game_button: Button
var _volume_button: Button
var _load_button: Button
var _panel: PanelContainer
var _seed_text := ""
var _new_game_armed := false


func _ready() -> void:
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_layout()


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		resume_requested.emit()
		get_viewport().set_input_as_handled()


func open(save_path: String, muted: bool, has_save: bool, seed_text: String) -> void:
	visible = true
	_set_muted_text(muted)
	_set_has_save(has_save)
	set_seed(seed_text)
	if _seed_input != null:
		_seed_input.text = seed_text
	_reset_new_game_button()
	_save_path_label.text = "存档目录：%s" % save_path
	_status_label.text = "游戏已暂停"
	_status_label.add_theme_color_override("font_color", UIStyle.TEXT_MUTED)


func close() -> void:
	visible = false


func is_open() -> bool:
	return visible


func set_status(text: String, is_error: bool = false) -> void:
	if _status_label == null:
		return
	_status_label.text = text
	_status_label.add_theme_color_override(
		"font_color",
		UIStyle.BAD if is_error else UIStyle.GOOD
	)


func set_muted(muted: bool) -> void:
	_set_muted_text(muted)


func set_has_save(has_save: bool) -> void:
	_set_has_save(has_save)


func set_seed(seed_text: String) -> void:
	_seed_text = seed_text
	if _seed_label != null:
		_seed_label.text = "世界种子：%s" % seed_text


func _set_muted_text(muted: bool) -> void:
	if _volume_button != null:
		_volume_button.text = "音效：关" if muted else "音效：开"


func _set_has_save(has_save: bool) -> void:
	if _load_button != null:
		_load_button.disabled = not has_save


func _build_layout() -> void:
	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.01, 0.02, 0.01, 0.78)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(430.0, 0.0)
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", UIStyle.make_panel(UIStyle.PANEL, 18))
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_bottom", 20)
	_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 10)
	margin.add_child(content)

	var title := _make_label("暂停菜单", 26, UIStyle.TEXT, true)
	content.add_child(title)
	var subtitle := _make_label("游戏暂停中；存档会覆盖当前存档目录。", 12, UIStyle.TEXT_MUTED)
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(subtitle)

	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override("separation", 8)
	content.add_child(seed_row)
	_seed_label = _make_label("世界种子：", 12, UIStyle.TEXT_MUTED)
	_seed_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	seed_row.add_child(_seed_label)
	var copy_seed := _make_button("复制种子", 30.0)
	copy_seed.custom_minimum_size = Vector2(90.0, 30.0)
	copy_seed.add_theme_font_size_override("font_size", 12)
	copy_seed.pressed.connect(func() -> void:
		DisplayServer.clipboard_set(_seed_text)
		set_status("种子已复制到剪贴板。")
	)
	seed_row.add_child(copy_seed)

	var new_game_row := HBoxContainer.new()
	new_game_row.add_theme_constant_override("separation", 8)
	content.add_child(new_game_row)
	_seed_input = LineEdit.new()
	_seed_input.placeholder_text = "输入种子，留空则随机"
	_seed_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_input.custom_minimum_size = Vector2(0.0, 34.0)
	_seed_input.add_theme_font_override("font", UIStyle.regular_font())
	_seed_input.add_theme_font_size_override("font_size", 12)
	_seed_input.add_theme_color_override("font_color", UIStyle.TEXT)
	_seed_input.add_theme_color_override("font_placeholder_color", UIStyle.TEXT_MUTED)
	_seed_input.add_theme_stylebox_override(
		"normal",
		UIStyle.make_panel(Color(0.09, 0.13, 0.08, 0.98), 8, UIStyle.SLOT_BORDER, 1, false)
	)
	new_game_row.add_child(_seed_input)
	_new_game_button = _make_button("新游戏", 34.0)
	_new_game_button.custom_minimum_size = Vector2(100.0, 34.0)
	_new_game_button.add_theme_font_size_override("font_size", 12)
	_new_game_button.pressed.connect(_on_new_game_pressed)
	new_game_row.add_child(_new_game_button)

	var separator := ColorRect.new()
	separator.color = Color(0.72, 0.80, 0.59, 0.14)
	separator.custom_minimum_size = Vector2(0.0, 1.0)
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(separator)

	var resume_button := _make_button("继续游戏", 44.0)
	resume_button.pressed.connect(func() -> void: resume_requested.emit())
	content.add_child(resume_button)

	var save_button := _make_button("保存游戏", 40.0)
	save_button.pressed.connect(func() -> void: save_requested.emit())
	content.add_child(save_button)

	_load_button = _make_button("读取存档", 40.0)
	_load_button.pressed.connect(func() -> void: load_requested.emit())
	content.add_child(_load_button)

	_volume_button = _make_button("音效：开", 40.0)
	_volume_button.pressed.connect(func() -> void: volume_toggle_requested.emit())
	content.add_child(_volume_button)

	_status_label = _make_label("游戏已暂停", 12, UIStyle.TEXT_MUTED)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(380.0, 0.0)
	content.add_child(_status_label)

	_save_path_label = _make_label("存档目录：user://saves/main", 10, Color(0.66, 0.72, 0.59, 0.9))
	_save_path_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(_save_path_label)


func _on_new_game_pressed() -> void:
	if _new_game_button == null:
		return
	if not _new_game_armed:
		_new_game_armed = true
		_new_game_button.text = "确认新游戏"
		set_status("新游戏会清空当前存档和世界，再次点击确认。", true)
		return
	_reset_new_game_button()
	new_game_requested.emit(_seed_input.text.strip_edges() if _seed_input != null else "")


func _reset_new_game_button() -> void:
	_new_game_armed = false
	if _new_game_button != null:
		_new_game_button.text = "新游戏"


func _make_button(text: String, height: float) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0.0, height)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", UIStyle.bold_font())
	button.add_theme_font_size_override("font_size", 14)
	button.add_theme_color_override("font_color", UIStyle.TEXT)
	button.add_theme_color_override("font_hover_color", UIStyle.ACCENT)
	button.add_theme_color_override("font_disabled_color", Color(0.55, 0.59, 0.50, 0.7))
	button.add_theme_stylebox_override(
		"normal",
		UIStyle.make_panel(Color(0.16, 0.21, 0.12, 0.98), 9, UIStyle.SLOT_BORDER, 1, false)
	)
	button.add_theme_stylebox_override(
		"hover",
		UIStyle.make_panel(Color(0.24, 0.30, 0.18, 1.0), 9, UIStyle.ACCENT, 1, false)
	)
	button.add_theme_stylebox_override(
		"pressed",
		UIStyle.make_panel(Color(0.11, 0.15, 0.09, 1.0), 9, UIStyle.ACCENT, 1, false)
	)
	button.add_theme_stylebox_override(
		"disabled",
		UIStyle.make_panel(Color(0.10, 0.13, 0.08, 0.9), 9, UIStyle.SLOT_BORDER, 1, false)
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
