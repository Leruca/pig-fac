class_name PigFacHud
extends Control
## 固定在屏幕上的 HUD：选中猪、手持物、操作提示、坐标、背包/箱子/合成/行为面板。

signal crafting_requested
signal behavior_requested
signal pig_selection_requested(pig: Pig)
signal map_command_requested(cell: Vector2i)

@onready var inventory_ui: InventoryUI = $InventoryUI
@onready var chest_ui: InventoryUI = $ChestUI
@onready var crafting_ui: CraftingUI = $CraftingUI
@onready var nest_ui: NestUI = $NestUI
@onready var behavior_ui: BehaviorUI = $BehaviorUI

var _info_panel: PanelContainer
var _help_panel: PanelContainer
var _detail_map_panel: PanelContainer
var _big_map_panel: PanelContainer
var _minimap_detail: FarmMinimap
var _minimap_big: FarmMinimap
var _map_overlay: FarmMapOverlay
var _furnace_ui: FurnaceUI
var esc_menu: EscMenu
var _hint_toast: PanelContainer
var _hint_toast_label: Label
var _game: Node
var _craft_button: Button
var _behavior_button: Button
var _status_dot: Panel
var _status_label: Label
var _held_icon: TextureRect
var _held_label: Label
var _hint_label: Label
var _coords_label: Label
var _inventory: Inventory
var _bound_pig: Pig
var _pig_name := ""

var _current_cell := Vector2i.ZERO
var _cell_size := 36
var _map_zoom := 1.0
var _has_active_cell := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_theme()
	_build_info_panel()
	_build_help_panel()
	_build_minimaps()
	_build_hint_toast()
	_build_action_buttons()
	_build_map_overlay()
	_build_furnace_ui()
	_build_esc_menu()
	_info_panel.visible = false
	_help_panel.visible = false
	inventory_ui.visible = false
	chest_ui.visible = false
	crafting_ui.visible = false
	nest_ui.visible = false
	behavior_ui.visible = false
	resized.connect(_layout_panels)
	_layout_panels.call_deferred()


func setup_map(game_node: Node) -> void:
	_game = game_node
	_minimap_detail.setup(game_node, FarmMinimap.Mode.DETAIL)
	_minimap_big.setup(game_node, FarmMinimap.Mode.BIG)
	_map_overlay.setup(game_node)
	_layout_panels()


func is_map_open() -> bool:
	return _map_overlay != null and _map_overlay.is_open()


func close_map() -> void:
	if _map_overlay != null:
		_map_overlay.close()


func open_furnace(furnace: Dictionary, owner_name: String) -> void:
	close_chest()
	close_nest()
	close_crafting()
	close_behavior()
	if _furnace_ui == null:
		_build_furnace_ui()
	_furnace_ui.setup(furnace, owner_name)
	_furnace_ui.set_bag_inventory(_inventory)
	_furnace_ui.visible = true
	inventory_ui.visible = true


func close_furnace() -> void:
	if _furnace_ui != null:
		_furnace_ui.unbind()
		_furnace_ui.visible = false


func is_furnace_open() -> bool:
	return _furnace_ui != null and _furnace_ui.visible


func _build_furnace_ui() -> void:
	if _furnace_ui != null:
		return
	_furnace_ui = FurnaceUI.new()
	add_child(_furnace_ui)
	_furnace_ui.visible = false
	_layout_panels()


func is_esc_menu_open() -> bool:
	return esc_menu != null and esc_menu.is_open()


func open_esc_menu(save_path: String, muted: bool, has_save: bool, seed_text: String) -> void:
	if esc_menu == null:
		return
	close_map()
	close_chest()
	close_nest()
	close_furnace()
	close_behavior()
	close_crafting()
	esc_menu.open(save_path, muted, has_save, seed_text)


func close_esc_menu() -> void:
	if esc_menu != null:
		esc_menu.close()


func _on_minimap_clicked(mode: int) -> void:
	if _map_overlay == null:
		return
	close_chest()
	close_nest()
	close_furnace()
	close_behavior()
	close_crafting()
	_map_overlay.open(mode)


func _on_minimap_pig_clicked(pig: Pig) -> void:
	pig_selection_requested.emit(pig)


func _on_map_command_requested(cell: Vector2i) -> void:
	map_command_requested.emit(cell)
	close_map()


func bind_pig(pig_name: String, inventory: Inventory, pig: Pig = null) -> void:
	_disconnect_inventory()
	_inventory = inventory
	_bound_pig = pig
	_pig_name = pig_name
	if _inventory != null:
		_inventory.changed.connect(_refresh_held)
		_inventory.selection_changed.connect(_on_held_selection_changed)

	inventory_ui.setup(inventory, pig_name)
	inventory_ui.visible = true
	inventory_ui.set_transfer_target(null)
	chest_ui.set_transfer_target(null)
	crafting_ui.setup(inventory)
	if behavior_ui.visible:
		behavior_ui.setup(_bound_pig)
	_craft_button.visible = true
	_behavior_button.visible = true
	set_selection(true, pig_name)
	_refresh_held()


func unbind_pig() -> void:
	_disconnect_inventory()
	_inventory = null
	_bound_pig = null
	_pig_name = ""
	inventory_ui.unbind()
	inventory_ui.visible = false
	close_chest()
	close_nest()
	close_furnace()
	close_behavior()
	crafting_ui.unbind()
	crafting_ui.visible = false
	inventory_ui.set_transfer_target(null)
	chest_ui.set_transfer_target(null)
	_craft_button.visible = false
	_behavior_button.visible = false
	set_selection(false)
	_has_active_cell = false
	if _held_icon != null:
		_held_icon.texture = null
		_held_icon.visible = false
		_held_label.text = "手持  —"
		_held_label.add_theme_color_override("font_color", UIStyle.TEXT_MUTED)
	if _coords_label != null:
		_coords_label.text = "当前未选择猪"


func set_selection(is_selected: bool, pig_name: String = "") -> void:
	if _status_dot == null:
		return
	var color := UIStyle.GOOD if is_selected else Color("#8C9880")
	_status_dot.add_theme_stylebox_override("panel", UIStyle.make_dot(color))
	if is_selected:
		_status_label.text = "%s 已选中" % (pig_name if not pig_name.is_empty() else _pig_name)
	else:
		_status_label.text = "猪未选中"
	_status_label.add_theme_color_override(
		"font_color",
		UIStyle.TEXT if is_selected else UIStyle.TEXT_MUTED
	)


func set_hint(text: String) -> void:
	if _hint_label != null:
		_hint_label.text = text
	if _hint_toast_label != null:
		_hint_toast_label.text = text
		if _hint_toast != null:
			_hint_toast.reset_size()
			_hint_toast.position = Vector2(
				(size.x - _hint_toast.size.x) * 0.5,
				size.y - _hint_toast.size.y - 24.0
			)


func set_pig_cell(cell: Vector2i, cell_size: int = 36) -> void:
	_current_cell = cell
	_cell_size = cell_size
	_has_active_cell = true
	_refresh_coords()


func set_map_zoom(zoom: float) -> void:
	_map_zoom = zoom
	if _has_active_cell:
		_refresh_coords()


func toggle_inventory() -> bool:
	if _inventory == null:
		return false
	inventory_ui.toggle()
	return true


func show_inventory() -> void:
	if _inventory != null:
		inventory_ui.visible = true


func close_inventory() -> void:
	if inventory_ui.visible:
		inventory_ui.visible = false


func is_inventory_open() -> bool:
	return _inventory != null and inventory_ui.visible


func open_chest(inventory: Inventory, owner_name: String) -> void:
	close_nest()
	close_furnace()
	close_behavior()
	close_crafting()
	chest_ui.setup(inventory, owner_name, "箱子")
	chest_ui.visible = true
	inventory_ui.set_transfer_target(inventory)
	chest_ui.set_transfer_target(_inventory)


func close_chest() -> void:
	chest_ui.unbind()
	chest_ui.visible = false
	inventory_ui.set_transfer_target(null)
	chest_ui.set_transfer_target(null)


func is_chest_open() -> bool:
	return chest_ui.visible


func open_nest(nest: Dictionary, owner_name: String) -> void:
	close_chest()
	close_furnace()
	close_behavior()
	close_crafting()
	nest_ui.setup(nest, owner_name)
	nest_ui.set_bag_inventory(_inventory)
	nest_ui.visible = true
	inventory_ui.set_transfer_handler(nest_ui.try_auto_store_from_inventory)


func close_nest() -> void:
	nest_ui.unbind()
	nest_ui.visible = false
	inventory_ui.set_transfer_handler(Callable())


func is_nest_open() -> bool:
	return nest_ui.visible


func open_behavior(pig: Pig) -> void:
	if pig == null:
		return
	close_chest()
	close_nest()
	close_furnace()
	close_crafting()
	behavior_ui.setup(pig)
	behavior_ui.visible = true
	if _behavior_button != null:
		_behavior_button.text = "关闭行为"


func close_behavior() -> void:
	behavior_ui.unbind()
	behavior_ui.visible = false
	if _behavior_button != null:
		_behavior_button.text = "行为设计"


func is_behavior_open() -> bool:
	return behavior_ui.visible


func toggle_crafting() -> bool:
	if _inventory == null:
		return false
	if not crafting_ui.visible:
		close_behavior()
		close_chest()
		close_nest()
		close_furnace()
	crafting_ui.toggle()
	if _craft_button != null:
		_craft_button.text = "关闭合成" if crafting_ui.visible else "合成 (C)"
	return true


func close_crafting() -> void:
	crafting_ui.visible = false
	if _craft_button != null:
		_craft_button.text = "合成 (C)"


func is_crafting_open() -> bool:
	return crafting_ui.visible


func _refresh_coords() -> void:
	if _coords_label == null or not _has_active_cell:
		return
	var short_side := roundi(get_viewport_rect().size.y / (float(_cell_size) * _map_zoom))
	_coords_label.text = "当前格子  (%d, %d)   ·   缩放 %d%%   ·   短边 %d 格" % [
		_current_cell.x,
		_current_cell.y,
		roundi(_map_zoom * 100.0),
		short_side,
	]


func _refresh_held() -> void:
	if _held_label == null:
		return
	if _inventory == null:
		_held_icon.texture = null
		_held_icon.visible = false
		_held_label.text = "手持  —"
		_held_label.add_theme_color_override("font_color", UIStyle.TEXT_MUTED)
		return

	var item_id := _inventory.get_held_item_id()
	if item_id.is_empty():
		_held_icon.texture = null
		_held_icon.visible = false
		_held_label.text = "手持  空手"
		_held_label.add_theme_color_override("font_color", UIStyle.TEXT_MUTED)
		return

	_held_icon.texture = ItemDB.get_icon(item_id)
	_held_icon.visible = true
	_held_label.text = "手持  %s ×%d" % [
		ItemDB.get_display_name(item_id),
		_inventory.get_held_count(),
	]
	_held_label.add_theme_color_override("font_color", UIStyle.TEXT)


func _on_held_selection_changed(_index: int) -> void:
	_refresh_held()


func _disconnect_inventory() -> void:
	if _inventory == null:
		return
	if _inventory.changed.is_connected(_refresh_held):
		_inventory.changed.disconnect(_refresh_held)
	if _inventory.selection_changed.is_connected(_on_held_selection_changed):
		_inventory.selection_changed.disconnect(_on_held_selection_changed)


func _apply_theme() -> void:
	var ui_theme := Theme.new()
	ui_theme.default_font = UIStyle.regular_font()
	ui_theme.default_font_size = 16
	theme = ui_theme


func _build_info_panel() -> void:
	_info_panel = PanelContainer.new()
	_info_panel.name = "InfoPanel"
	_info_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_info_panel.custom_minimum_size = Vector2(380.0, 0.0)
	_info_panel.add_theme_stylebox_override("panel", UIStyle.make_panel())
	add_child(_info_panel)

	var margin := _make_margin(18, 16, 18, 16)
	_info_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 7)
	margin.add_child(content)

	var eyebrow := _make_label("PIGFAC  /  PROTOTYPE 02", 11, UIStyle.ACCENT, true)
	content.add_child(eyebrow)

	var title := _make_label("猪猪农场", 30, UIStyle.TEXT, true)
	content.add_child(title)

	var subtitle := _make_label("每只猪都有独立的 40 格背包。", 13, UIStyle.TEXT_MUTED)
	content.add_child(subtitle)

	content.add_child(_make_separator())

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)
	content.add_child(status_row)

	_status_dot = Panel.new()
	_status_dot.custom_minimum_size = Vector2(10.0, 10.0)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_status_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_dot.add_theme_stylebox_override("panel", UIStyle.make_dot(Color("#8C9880")))
	status_row.add_child(_status_dot)

	_status_label = _make_label("猪未选中", 15, UIStyle.TEXT_MUTED, true)
	status_row.add_child(_status_label)

	var held_row := HBoxContainer.new()
	held_row.add_theme_constant_override("separation", 8)
	content.add_child(held_row)

	_held_icon = TextureRect.new()
	_held_icon.custom_minimum_size = Vector2(18.0, 18.0)
	_held_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_held_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_held_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_held_icon.visible = false
	held_row.add_child(_held_icon)

	_held_label = _make_label("手持  —", 14, UIStyle.TEXT_MUTED, true)
	_held_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	held_row.add_child(_held_label)

	_hint_label = _make_label("左键选中一只猪，再选择背包物品，然后右键目标。", 13, UIStyle.TEXT_MUTED)
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size = Vector2(340.0, 52.0)
	content.add_child(_hint_label)

	_coords_label = _make_label("当前未选择猪", 12, Color(0.72, 0.78, 0.65, 0.9))
	content.add_child(_coords_label)

	_info_panel.position = Vector2(24.0, 24.0)


func _build_help_panel() -> void:
	_help_panel = PanelContainer.new()
	_help_panel.name = "HelpPanel"
	_help_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_help_panel.custom_minimum_size = Vector2(300.0, 0.0)
	_help_panel.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(UIStyle.PANEL_SOFT, 16)
	)
	add_child(_help_panel)

	var margin := _make_margin(16, 14, 16, 14)
	_help_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)

	var title := _make_label("操作", 12, UIStyle.ACCENT, true)
	content.add_child(title)
	content.add_child(_make_control_row("左键", "选中猪 / 点空地取消"))
	content.add_child(_make_control_row("右键", "使用手持物 / 空手移动"))
	content.add_child(_make_control_row("拖动", "连续耕地、播种、砍伐、放置"))
	content.add_child(_make_control_row("背包", "点击选择；拖拽整理 / 存箱"))
	content.add_child(_make_control_row("箱子", "右键打开，拖动物品"))
	content.add_child(_make_control_row("猪窝", "右键打开，拖猪/食物"))
	content.add_child(_make_control_row("范围", "3 格内，超出自动靠近"))
	content.add_child(_make_control_row("滚轮", "缩放地图"))
	content.add_child(_make_control_row("B", "开关当前猪的背包"))
	content.add_child(_make_control_row("C", "打开 / 关闭合成"))
	content.add_child(_make_control_row("Esc", "收起面板 / 取消选择"))


func _make_control_row(key_text: String, description: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var keycap := PanelContainer.new()
	keycap.custom_minimum_size = Vector2(52.0, 27.0)
	keycap.add_theme_stylebox_override("panel", UIStyle.make_keycap())
	var key_label := _make_label(key_text, 12, UIStyle.ACCENT, true)
	key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	keycap.add_child(key_label)
	row.add_child(keycap)

	var description_label := _make_label(description, 13, UIStyle.TEXT_MUTED)
	description_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	description_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(description_label)
	return row


func _build_minimaps() -> void:
	_detail_map_panel = _make_minimap_panel("细节地图 · 16×16格")
	_minimap_detail = _detail_map_panel.get_meta("minimap")
	_minimap_detail.map_clicked.connect(_on_minimap_clicked)
	_minimap_detail.pig_clicked.connect(_on_minimap_pig_clicked)
	_big_map_panel = _make_minimap_panel("大地图 · 9×9区块")
	_minimap_big = _big_map_panel.get_meta("minimap")
	_minimap_big.map_clicked.connect(_on_minimap_clicked)
	_minimap_big.pig_clicked.connect(_on_minimap_pig_clicked)


func _make_minimap_panel(title_text: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	panel.custom_minimum_size = Vector2(192.0, 216.0)
	panel.add_theme_stylebox_override("panel", UIStyle.make_panel(UIStyle.PANEL, 12))
	add_child(panel)
	var margin := _make_margin(8, 7, 8, 8)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	margin.add_child(content)
	var title := _make_label(title_text, 11, UIStyle.ACCENT, true)
	content.add_child(title)
	var minimap := FarmMinimap.new()
	minimap.custom_minimum_size = Vector2(172.0, 172.0)
	content.add_child(minimap)
	panel.set_meta("minimap", minimap)
	return panel


func _build_hint_toast() -> void:
	_hint_toast = PanelContainer.new()
	_hint_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_toast.custom_minimum_size = Vector2(360.0, 0.0)
	_hint_toast.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(UIStyle.PANEL_SOFT, 10)
	)
	add_child(_hint_toast)
	var margin := _make_margin(12, 8, 12, 8)
	_hint_toast.add_child(margin)
	_hint_toast_label = _make_label("左键选中猪；拖动空地移动镜头。", 12, UIStyle.TEXT_MUTED)
	_hint_toast_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_toast_label.custom_minimum_size = Vector2(336.0, 0.0)
	margin.add_child(_hint_toast_label)


func _build_map_overlay() -> void:
	_map_overlay = FarmMapOverlay.new()
	add_child(_map_overlay)
	_map_overlay.command_requested.connect(_on_map_command_requested)
	if _game != null:
		_map_overlay.setup(_game)
	_map_overlay.visible = false


func _build_esc_menu() -> void:
	esc_menu = EscMenu.new()
	add_child(esc_menu)
	esc_menu.visible = false


func _build_action_buttons() -> void:
	_craft_button = _make_action_button("合成 (C)")
	_craft_button.pressed.connect(_on_craft_button_pressed)
	add_child(_craft_button)
	_behavior_button = _make_action_button("行为设计")
	_behavior_button.pressed.connect(_on_behavior_button_pressed)
	add_child(_behavior_button)
	_craft_button.visible = false
	_behavior_button.visible = false


func _make_action_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.size = Vector2(132.0, 36.0)
	button.custom_minimum_size = Vector2(132.0, 36.0)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", UIStyle.bold_font())
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", UIStyle.TEXT)
	button.add_theme_color_override("font_hover_color", UIStyle.ACCENT)
	button.add_theme_stylebox_override(
		"normal",
		UIStyle.make_panel(Color(0.10, 0.14, 0.09, 0.96), 9, UIStyle.SLOT_BORDER, 1, false)
	)
	button.add_theme_stylebox_override(
		"hover",
		UIStyle.make_panel(Color(0.18, 0.24, 0.14, 0.98), 9, UIStyle.ACCENT, 1, false)
	)
	button.add_theme_stylebox_override(
		"pressed",
		UIStyle.make_panel(Color(0.07, 0.10, 0.06, 0.98), 9, UIStyle.ACCENT, 1, false)
	)
	return button


func _on_craft_button_pressed() -> void:
	crafting_requested.emit()


func _on_behavior_button_pressed() -> void:
	behavior_requested.emit()


func _layout_panels() -> void:
	if _detail_map_panel != null:
		_detail_map_panel.reset_size()
		_detail_map_panel.position = Vector2(24.0, 24.0)
		_big_map_panel.reset_size()
		_big_map_panel.position = Vector2(24.0 + _detail_map_panel.size.x + 12.0, 24.0)
	if _craft_button != null:
		var button_x := size.x * 0.5 - 66.0
		_craft_button.position = Vector2(button_x, 24.0)
		_behavior_button.position = Vector2(button_x, 66.0)
	if _hint_toast != null:
		_hint_toast.reset_size()
		_hint_toast.position = Vector2(
			(size.x - _hint_toast.size.x) * 0.5,
			size.y - _hint_toast.size.y - 24.0
		)
	if _map_overlay != null:
		_map_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	if _furnace_ui != null:
		_furnace_ui.reset_size()
		_furnace_ui.position = Vector2(
			size.x - _furnace_ui.size.x - 24.0,
			size.y - _furnace_ui.size.y - 24.0
		)
	if esc_menu != null:
		esc_menu.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _make_margin(left: int, top: int, right: int, bottom: int) -> MarginContainer:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", left)
	margin.add_theme_constant_override("margin_top", top)
	margin.add_theme_constant_override("margin_right", right)
	margin.add_theme_constant_override("margin_bottom", bottom)
	return margin


func _make_separator() -> ColorRect:
	var separator := ColorRect.new()
	separator.color = Color(0.72, 0.80, 0.59, 0.14)
	separator.custom_minimum_size = Vector2(0.0, 1.0)
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return separator


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
