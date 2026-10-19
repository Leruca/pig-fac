class_name FurnaceUI
extends PanelContainer
## 熔炉面板：输入槽 / 燃料槽 / 输出槽 + 燃烧与熔炼进度。

var _furnace: Dictionary
var _inventory: Inventory
var _bag_inventory: Inventory
var _title_label: Label
var _slots: Array[InventorySlot] = []
var _slot_icons: Array[TextureRect] = []
var _slot_counts: Array[Label] = []
var _burn_bar: ProgressBar
var _smelt_bar: ProgressBar
var _burn_label: Label
var _smelt_label: Label
var _status_label: Label
var _message_label: Label


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(470.0, 0.0)
	add_theme_stylebox_override("panel", UIStyle.make_panel(UIStyle.PANEL, 18))
	_build_layout()


func setup(furnace: Dictionary, owner_name: String) -> void:
	_unbind_inventory()
	_furnace = furnace
	_inventory = furnace.get("inventory") as Inventory
	if _inventory != null:
		_inventory.changed.connect(_on_inventory_changed)
	_title_label.text = "熔炉 · %s" % owner_name
	for slot in _slots:
		slot.inventory = _inventory
	_message_label.text = ""
	_refresh()


func set_bag_inventory(inventory: Inventory) -> void:
	_bag_inventory = inventory


func unbind() -> void:
	_unbind_inventory()
	_furnace = {}
	_bag_inventory = null
	for slot in _slots:
		slot.inventory = null
	visible = false


func is_open() -> bool:
	return visible


func _unbind_inventory() -> void:
	if _inventory != null and _inventory.changed.is_connected(_on_inventory_changed):
		_inventory.changed.disconnect(_on_inventory_changed)
	_inventory = null


func _on_inventory_changed() -> void:
	_refresh()


func _process(_delta: float) -> void:
	if visible and _inventory != null:
		_refresh_progress()


func _build_layout() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 8)
	margin.add_child(content)

	var header := HBoxContainer.new()
	content.add_child(header)
	_title_label = _make_label("熔炉", 22, UIStyle.TEXT, true)
	header.add_child(_title_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	header.add_child(_make_label("Esc 关闭", 12, UIStyle.TEXT_MUTED))

	content.add_child(_make_label(
		"矿石 → 锭    ·   燃料：木头 20s / 木板 10s / 煤炭 40s",
		12,
		UIStyle.TEXT_MUTED
	))
	var separator := ColorRect.new()
	separator.color = Color(0.72, 0.80, 0.59, 0.14)
	separator.custom_minimum_size = Vector2(0.0, 1.0)
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(separator)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 8)
	content.add_child(cards)
	cards.add_child(_build_card("矿石输入", WorldObjects.FURNACE_SLOT_INPUT))
	cards.add_child(_build_card("燃料", WorldObjects.FURNACE_SLOT_FUEL))
	cards.add_child(_build_card("熔炼产物", WorldObjects.FURNACE_SLOT_OUTPUT))

	_burn_label = _make_label("燃烧 0.0 / 0.0s", 12, UIStyle.TEXT_MUTED)
	content.add_child(_burn_label)
	_burn_bar = _make_bar()
	content.add_child(_burn_bar)

	_smelt_label = _make_label("熔炼 0.0 / 5.0s", 12, UIStyle.TEXT_MUTED)
	content.add_child(_smelt_label)
	_smelt_bar = _make_bar()
	content.add_child(_smelt_bar)

	_status_label = _make_label("", 12, UIStyle.TEXT_MUTED)
	content.add_child(_status_label)
	_message_label = _make_label("", 12, UIStyle.BAD)
	content.add_child(_message_label)


func _build_card(title_text: String, index: int) -> Control:
	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(136.0, 0.0)
	card.add_theme_constant_override("separation", 4)
	card.add_child(_make_label(title_text, 12, UIStyle.TEXT_MUTED, true))

	var slot := InventorySlot.new()
	slot.custom_minimum_size = Vector2(72.0, 72.0)
	slot.size = Vector2(72.0, 72.0)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	slot.owner_ui = self
	slot.slot_index = index
	slot.gui_input.connect(_on_slot_gui_input.bind(index))
	slot.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(
			Color(0.10, 0.14, 0.09, 0.95),
			10,
			UIStyle.ACCENT if index == WorldObjects.FURNACE_SLOT_OUTPUT else UIStyle.SLOT_BORDER,
			1,
			false
		)
	)
	card.add_child(slot)

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

	var count_label := _make_label("", 12, UIStyle.TEXT, true)
	count_label.anchor_left = 1.0
	count_label.anchor_top = 1.0
	count_label.anchor_right = 1.0
	count_label.anchor_bottom = 1.0
	count_label.offset_left = -34.0
	count_label.offset_top = -21.0
	count_label.offset_right = -4.0
	count_label.offset_bottom = -2.0
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_label.add_theme_color_override("font_outline_color", Color(0.04, 0.06, 0.03, 0.95))
	count_label.add_theme_constant_override("outline_size", 3)
	count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(count_label)

	_slots.append(slot)
	_slot_icons.append(icon)
	_slot_counts.append(count_label)
	return card


func _make_bar() -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0.0, 9.0)
	bar.add_theme_stylebox_override(
		"background", UIStyle.make_panel(Color(0.09, 0.12, 0.07, 0.9), 5, UIStyle.SLOT_BORDER, 1, false)
	)
	bar.add_theme_stylebox_override(
		"fill", UIStyle.make_panel(UIStyle.ACCENT, 5, UIStyle.ACCENT, 0, false)
	)
	return bar


func _refresh() -> void:
	if _inventory == null:
		return
	for index in _slots.size():
		var data := _inventory.get_slot(index)
		var icon := _slot_icons[index]
		var count_label := _slot_counts[index]
		var panel := _slots[index]
		if data.is_empty():
			icon.texture = null
			count_label.text = ""
			panel.tooltip_text = "空槽"
		else:
			var item_id := str(data.get("item_id", ""))
			var count := int(data.get("count", 0))
			icon.texture = ItemDB.get_icon(item_id)
			count_label.text = str(count) if count > 1 else ""
			panel.tooltip_text = "%s ×%d" % [ItemDB.get_display_name(item_id), count]
	_refresh_progress()


func _refresh_progress() -> void:
	if _inventory == null:
		return
	var burn := float(_furnace.get("burn_remaining", 0.0))
	var burn_total := float(_furnace.get("burn_total", 0.0))
	var progress := float(_furnace.get("smelt_progress", 0.0))
	_burn_bar.max_value = maxf(0.001, burn_total)
	_burn_bar.value = burn
	_burn_label.text = "燃烧 %.1f / %.1fs" % [burn, burn_total]
	_smelt_bar.max_value = WorldObjects.FURNACE_SMELT_SECONDS
	_smelt_bar.value = progress
	_smelt_label.text = "熔炼 %.1f / %.1fs" % [progress, WorldObjects.FURNACE_SMELT_SECONDS]

	var input := _inventory.get_slot(WorldObjects.FURNACE_SLOT_INPUT)
	var fuel := _inventory.get_slot(WorldObjects.FURNACE_SLOT_FUEL)
	var output := _inventory.get_slot(WorldObjects.FURNACE_SLOT_OUTPUT)
	var input_id := str(input.get("item_id", ""))
	var recipe: Dictionary = WorldObjects.FURNACE_SMELT_RECIPES.get(input_id, {})
	if not recipe.is_empty():
		_status_label.text = "正在熔炼 %s → %s" % [
			ItemDB.get_display_name(input_id),
			ItemDB.get_display_name(str(recipe.get("ingot", ""))),
		]
	elif not output.is_empty():
		_status_label.text = "产物已就绪，拖出输出槽后继续。"
	elif burn > 0.0:
		_status_label.text = "燃料燃烧中，等待矿石。"
	elif not fuel.is_empty():
		_status_label.text = "有燃料；放入矿石后开始燃烧。"
	else:
		_status_label.text = "放入矿石，并在燃料槽放入木头/木板/煤炭。"


func _on_slot_gui_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	if not Input.is_key_pressed(KEY_SHIFT) or _bag_inventory == null or _inventory == null:
		return
	var data := _inventory.get_slot(index)
	if data.is_empty():
		return
	var item_id := str(data.get("item_id", ""))
	for _attempt in 80:
		if _inventory.get_slot(index).is_empty():
			break
		var target_index := _find_bag_target(item_id)
		if target_index < 0:
			break
		if not _inventory.move_stack_to(_bag_inventory, index, target_index):
			break
	_refresh()
	_slots[index].accept_event()


func _find_bag_target(item_id: String) -> int:
	if _bag_inventory == null:
		return -1
	var max_stack := ItemDB.get_max_stack(item_id)
	for index in _bag_inventory.slot_count:
		var slot := _bag_inventory.get_slot(index)
		if slot.is_empty():
			return index
		if str(slot.get("item_id", "")) == item_id and int(slot.get("count", 0)) < max_stack:
			return index
	return -1


func handle_slot_drop(data: Dictionary, target_index: int) -> void:
	if _inventory == null:
		return
	var source_value: Variant = data.get("source_inventory")
	if not (source_value is Inventory):
		return
	var source: Inventory = source_value
	var source_index := int(data.get("source_index", -1))
	var source_slot := source.get_slot(source_index)
	if source_slot.is_empty():
		return
	var item_id := str(source_slot.get("item_id", ""))
	if target_index == WorldObjects.FURNACE_SLOT_OUTPUT:
		_message_label.text = "输出槽只能取出，不能放入。"
		return
	if target_index == WorldObjects.FURNACE_SLOT_INPUT:
		if ItemDB.get_kind(item_id) != "ore":
			_message_label.text = "输入槽只能放矿石。"
			return
	elif target_index == WorldObjects.FURNACE_SLOT_FUEL:
		if not WorldObjects.FURNACE_FUEL_SECONDS.has(item_id):
			_message_label.text = "燃料只能是木头、木板或煤炭。"
			return
	if source.move_stack_to(_inventory, source_index, target_index):
		_message_label.text = ""
		_refresh()


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
