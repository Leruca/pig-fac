class_name InventoryUI
extends PanelContainer
## 40 格背包界面：8 列 × 5 行，每格显示图标、数量与悬浮提示。
##
## UI 只读取 Inventory 的数据；增删物品应该调用 Inventory，界面通过 changed 信号刷新。

const COLUMNS := 8
const SLOT_SIZE := 50
const SLOT_GAP := 6

var _inventory: Inventory
var _transfer_target: Inventory
var _transfer_handler := Callable()
var _grid: GridContainer
var _title_label: Label
var _count_label: Label
var _slot_panels: Array[InventorySlot] = []
var _slot_icons: Array[TextureRect] = []
var _slot_counts: Array[Label] = []
var _hovered_slots: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", UIStyle.make_panel(UIStyle.PANEL, 18))
	_build_layout()
	_build_slots()


func setup(inventory: Inventory, owner_name: String = "", base_title: String = "背包") -> void:
	if _inventory != null:
		if _inventory.changed.is_connected(_on_inventory_changed):
			_inventory.changed.disconnect(_on_inventory_changed)
		if _inventory.selection_changed.is_connected(_on_selection_changed):
			_inventory.selection_changed.disconnect(_on_selection_changed)
	_inventory = inventory
	if _inventory != null:
		_inventory.changed.connect(_on_inventory_changed)
		_inventory.selection_changed.connect(_on_selection_changed)
	if owner_name.is_empty():
		_title_label.text = base_title
	else:
		_title_label.text = "%s · %s" % [base_title, owner_name]
	for slot in _slot_panels:
		slot.inventory = _inventory
	_refresh()


func unbind() -> void:
	if _inventory != null:
		if _inventory.changed.is_connected(_on_inventory_changed):
			_inventory.changed.disconnect(_on_inventory_changed)
		if _inventory.selection_changed.is_connected(_on_selection_changed):
			_inventory.selection_changed.disconnect(_on_selection_changed)
	_inventory = null
	for slot in _slot_panels:
		slot.inventory = null
	visible = false


func toggle() -> void:
	visible = not visible
	if visible:
		_refresh()


func is_open() -> bool:
	return visible


func set_transfer_target(inventory: Inventory) -> void:
	_transfer_target = inventory
	_transfer_handler = Callable()


func set_transfer_handler(handler: Callable) -> void:
	_transfer_handler = handler
	_transfer_target = null


func _build_layout() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	content.add_child(header)

	var title := _make_label("背包", 22, UIStyle.TEXT, true)
	header.add_child(title)
	_title_label = title

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)

	_count_label = _make_label("0 / 40 格", 13, UIStyle.TEXT_MUTED)
	_count_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(_count_label)

	var subtitle := _make_label("8 × 5 槽位   ·   普通物品每格堆叠 64   ·   Shift 点击自动转移", 12, UIStyle.TEXT_MUTED)
	content.add_child(subtitle)

	var separator := ColorRect.new()
	separator.color = Color(0.72, 0.80, 0.59, 0.13)
	separator.custom_minimum_size = Vector2(0.0, 1.0)
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(separator)

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", SLOT_GAP)
	_grid.add_theme_constant_override("v_separation", SLOT_GAP)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(_grid)


func _build_slots() -> void:
	for index in Inventory.DEFAULT_SLOT_COUNT:
		var slot := InventorySlot.new()
		slot.slot_index = index
		slot.owner_ui = self
		slot.custom_minimum_size = Vector2(SLOT_SIZE, SLOT_SIZE)
		slot.mouse_filter = Control.MOUSE_FILTER_STOP
		slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		slot.gui_input.connect(_on_slot_gui_input.bind(index))
		slot.mouse_entered.connect(_on_slot_hovered.bind(index, true))
		slot.mouse_exited.connect(_on_slot_hovered.bind(index, false))
		_grid.add_child(slot)
		_slot_panels.append(slot)

		var icon := TextureRect.new()
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		icon.offset_left = 8.0
		icon.offset_top = 8.0
		icon.offset_right = -8.0
		icon.offset_bottom = -8.0
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(icon)
		_slot_icons.append(icon)

		var count_label := _make_label("", 13, UIStyle.TEXT, true)
		count_label.anchor_left = 1.0
		count_label.anchor_top = 1.0
		count_label.anchor_right = 1.0
		count_label.anchor_bottom = 1.0
		count_label.offset_left = -38.0
		count_label.offset_top = -23.0
		count_label.offset_right = -5.0
		count_label.offset_bottom = -2.0
		count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		count_label.add_theme_font_size_override("font_size", 13)
		count_label.add_theme_color_override("font_outline_color", Color(0.05, 0.07, 0.04, 0.95))
		count_label.add_theme_constant_override("outline_size", 4)
		count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(count_label)
		_slot_counts.append(count_label)

		_style_slot(index)


func _refresh() -> void:
	if _inventory == null:
		return

	_count_label.text = "%d / %d 格" % [_inventory.get_used_slot_count(), _inventory.slot_count]

	for index in Inventory.DEFAULT_SLOT_COUNT:
		var slot := _inventory.get_slot(index)
		var icon := _slot_icons[index]
		var count_label := _slot_counts[index]
		var panel := _slot_panels[index]
		panel.inventory = _inventory

		if slot.is_empty():
			icon.texture = null
			count_label.text = ""
			panel.tooltip_text = "空槽位"
		else:
			var item_id := str(slot.get("item_id", ""))
			var count := int(slot.get("count", 0))
			icon.texture = ItemDB.get_icon(item_id)
			count_label.text = str(count) if count > 1 else ""
			var max_stack := ItemDB.get_max_stack(item_id)
			var description := ItemDB.get_description(item_id)
			if item_id == "pig":
				var rgb: Vector3i = slot.get("pig_rgb", Vector3i.ZERO)
				description += "\nRGB (%d, %d, %d)   ·   背包物品 %d 格" % [
					rgb.x,
					rgb.y,
					rgb.z,
					_pig_inventory_used(slot),
				]
			panel.tooltip_text = "%s  ×%d\n%s\n堆叠 %d / %d" % [
				ItemDB.get_display_name(item_id),
				count,
				description,
				count,
				max_stack,
			]

		_style_slot(index)


func _style_slot(index: int) -> void:
	var panel := _slot_panels[index]
	var filled := _inventory != null and not _inventory.get_slot(index).is_empty()
	var selected := _inventory != null and _inventory.selected_index == index
	var hovered := bool(_hovered_slots.get(index, false))
	var background := UIStyle.SLOT_FILLED if filled else UIStyle.SLOT
	var border := UIStyle.SLOT_BORDER_FILLED if filled else UIStyle.SLOT_BORDER
	var border_width := 1

	if hovered:
		background = background.lightened(0.06)
		border = border.lightened(0.20)
	if selected:
		background = UIStyle.SLOT_FILLED.lightened(0.10)
		border = UIStyle.ACCENT
		border_width = 2

	panel.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(background, 9, border, border_width, false)
	)


func _on_slot_gui_input(event: InputEvent, index: int) -> void:
	if _inventory == null:
		return
	if not (event is InputEventMouseButton):
		return
	if not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:
		return
	if Input.is_key_pressed(KEY_SHIFT):
		if _transfer_handler.is_valid():
			if bool(_transfer_handler.call(_inventory, index)):
				_slot_panels[index].accept_event()
				return
		elif _transfer_target != null:
			if _transfer_stack_to_target(index):
				_slot_panels[index].accept_event()
				return

	if _inventory.get_slot(index).is_empty():
		_inventory.clear_selection()
	elif _inventory.selected_index == index:
		_inventory.clear_selection()
	else:
		_inventory.select_slot(index)
	_slot_panels[index].accept_event()


func _transfer_stack_to_target(index: int) -> bool:
	if _inventory == null or _transfer_target == null or _transfer_target == _inventory:
		return false
	if _inventory.get_slot(index).is_empty():
		return false
	var moved_any := false
	# 目标槽可能先合并已有半堆，再继续占用空槽，直到整堆转移完。
	for _attempt in 80:
		if _inventory.get_slot(index).is_empty():
			break
		var target_index := _find_transfer_target_slot(index)
		if target_index < 0:
			break
		if not _inventory.move_stack_to(_transfer_target, index, target_index):
			break
		moved_any = true
	return moved_any


func _find_transfer_target_slot(source_index: int) -> int:
	var source := _inventory.get_slot(source_index)
	if source.is_empty():
		return -1
	var item_id := str(source.get("item_id", ""))
	var max_stack := ItemDB.get_max_stack(item_id)
	for index in _transfer_target.slot_count:
		var slot := _transfer_target.get_slot(index)
		if slot.is_empty():
			return index
		if str(slot.get("item_id", "")) == item_id and int(slot.get("count", 0)) < max_stack:
			return index
	return -1


func handle_slot_drop(data: Dictionary, target_index: int) -> void:
	if _inventory == null:
		return
	var source_inventory: Variant = data.get("source_inventory")
	if not (source_inventory is Inventory):
		return
	var source_inv: Inventory = source_inventory
	var source_index := int(data.get("source_index", -1))
	if source_inv.move_stack_to(_inventory, source_index, target_index):
		_refresh()


func _pig_inventory_used(slot: Dictionary) -> int:
	var inventory: Variant = slot.get("pig_inventory")
	if inventory is Inventory:
		var pig_inventory: Inventory = inventory
		return pig_inventory.get_used_slot_count()
	return 0


func _on_slot_hovered(index: int, hovered: bool) -> void:
	_hovered_slots[index] = hovered
	_style_slot(index)


func _on_inventory_changed() -> void:
	_refresh()


func _on_selection_changed(_index: int) -> void:
	for slot_index in _slot_panels.size():
		_style_slot(slot_index)


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
