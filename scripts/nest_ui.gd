class_name NestUI
extends PanelContainer
## 猪窝面板：3 个输入槽（两只亲代猪 + 食物）和 1 个输出槽（新生猪）。

var _nest: Dictionary
var _inventory: Inventory
var _bag_inventory: Inventory
var _title_label: Label
var _slots: Array[InventorySlot] = []
var _slot_icons: Array[TextureRect] = []
var _slot_counts: Array[Label] = []
var _rgb_labels: Array[Label] = []
var _food_label: Label
var _progress_label: Label
var _progress_bar: ProgressBar
var _status_label: Label
var _message_label: Label


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(500.0, 0.0)
	add_theme_stylebox_override("panel", UIStyle.make_panel(UIStyle.PANEL, 18))
	_build_layout()


func setup(nest: Dictionary, owner_name: String) -> void:
	if _inventory != null and _inventory.changed.is_connected(_on_inventory_changed):
		_inventory.changed.disconnect(_on_inventory_changed)
	_nest = nest
	_inventory = nest.get("inventory") as Inventory
	if _inventory != null:
		_inventory.changed.connect(_on_inventory_changed)
	_title_label.text = "猪窝 · %s" % owner_name
	for slot in _slots:
		slot.inventory = _inventory
	_message_label.text = ""
	_refresh()


func set_bag_inventory(inventory: Inventory) -> void:
	_bag_inventory = inventory


func unbind() -> void:
	if _inventory != null and _inventory.changed.is_connected(_on_inventory_changed):
		_inventory.changed.disconnect(_on_inventory_changed)
	_inventory = null
	_bag_inventory = null
	_nest = {}
	for slot in _slots:
		slot.inventory = null
	visible = false


func is_open() -> bool:
	return visible


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
	_title_label = _make_label("猪窝", 22, UIStyle.TEXT, true)
	header.add_child(_title_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	var hint := _make_label("Esc 关闭", 12, UIStyle.TEXT_MUTED)
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(hint)

	var subtitle := _make_label(
		"两只亲代猪 + 食物 ≥ 10   ·   10 秒后消耗 10 食物，产出一只新猪",
		12,
		UIStyle.TEXT_MUTED
	)
	content.add_child(subtitle)

	var separator := ColorRect.new()
	separator.color = Color(0.72, 0.80, 0.59, 0.14)
	separator.custom_minimum_size = Vector2(0.0, 1.0)
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(separator)

	var cards := HBoxContainer.new()
	cards.add_theme_constant_override("separation", 8)
	content.add_child(cards)
	cards.add_child(_build_card("亲代 A", 0, false))
	cards.add_child(_build_card("亲代 B", 1, false))
	cards.add_child(_build_card("食物 ≥ 10", 2, false))
	cards.add_child(_build_card("新生猪", 3, true))

	var progress_row := HBoxContainer.new()
	content.add_child(progress_row)
	_food_label = _make_label("食物 0 / 10", 12, UIStyle.TEXT_MUTED)
	progress_row.add_child(_food_label)
	var progress_spacer := Control.new()
	progress_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	progress_row.add_child(progress_spacer)
	_progress_label = _make_label("0.0 / 10.0s", 12, UIStyle.TEXT_MUTED)
	progress_row.add_child(_progress_label)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = WorldObjects.NEST_BREED_SECONDS
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(0.0, 10.0)
	_progress_bar.add_theme_stylebox_override(
		"background",
		UIStyle.make_panel(Color(0.09, 0.12, 0.07, 0.9), 5, UIStyle.SLOT_BORDER, 1, false)
	)
	_progress_bar.add_theme_stylebox_override(
		"fill",
		UIStyle.make_panel(UIStyle.ACCENT, 5, UIStyle.ACCENT, 0, false)
	)
	content.add_child(_progress_bar)

	_status_label = _make_label("", 12, UIStyle.TEXT_MUTED)
	content.add_child(_status_label)
	_message_label = _make_label("", 12, UIStyle.BAD)
	content.add_child(_message_label)


func _build_card(title_text: String, index: int, is_output: bool) -> Control:
	var card := VBoxContainer.new()
	card.custom_minimum_size = Vector2(104.0, 0.0)
	card.add_theme_constant_override("separation", 4)

	var label := _make_label(title_text, 12, UIStyle.TEXT_MUTED, true)
	card.add_child(label)

	var slot := InventorySlot.new()
	slot.custom_minimum_size = Vector2(62.0, 62.0)
	slot.size = Vector2(62.0, 62.0)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	slot.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	slot.owner_ui = self
	slot.slot_index = index
	slot.gui_input.connect(_on_nest_slot_gui_input.bind(index))
	slot.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(
			Color(0.10, 0.14, 0.09, 0.95),
			10,
			UIStyle.ACCENT if is_output else UIStyle.SLOT_BORDER,
			1,
			false
		)
	)
	card.add_child(slot)

	var icon := TextureRect.new()
	icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon.offset_left = 7.0
	icon.offset_top = 7.0
	icon.offset_right = -7.0
	icon.offset_bottom = -7.0
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)

	var count_label := _make_label("", 12, UIStyle.TEXT, true)
	count_label.anchor_left = 1.0
	count_label.anchor_top = 1.0
	count_label.anchor_right = 1.0
	count_label.anchor_bottom = 1.0
	count_label.offset_left = -32.0
	count_label.offset_top = -20.0
	count_label.offset_right = -4.0
	count_label.offset_bottom = -2.0
	count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	count_label.add_theme_font_size_override("font_size", 12)
	count_label.add_theme_color_override("font_outline_color", Color(0.04, 0.06, 0.03, 0.95))
	count_label.add_theme_constant_override("outline_size", 3)
	slot.add_child(count_label)

	var rgb_label := _make_label("—", 10, UIStyle.TEXT_MUTED)
	rgb_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(rgb_label)

	_slots.append(slot)
	_slot_icons.append(icon)
	_slot_counts.append(count_label)
	_rgb_labels.append(rgb_label)
	return card


func try_auto_store_from_inventory(source: Inventory, source_index: int) -> bool:
	if source == null or _inventory == null:
		return false
	var source_slot := source.get_slot(source_index)
	if source_slot.is_empty():
		return false
	var item_id := str(source_slot.get("item_id", ""))
	var target_index := -1
	if item_id == "pig":
		for index in [0, 1]:
			if _inventory.get_slot(index).is_empty():
				target_index = index
				break
	elif ItemDB.is_crop(item_id):
		var food_slot := _inventory.get_slot(2)
		if food_slot.is_empty():
			target_index = 2
		elif (
			str(food_slot.get("item_id", "")) == item_id
			and int(food_slot.get("count", 0)) < ItemDB.get_max_stack(item_id)
		):
			target_index = 2
	if target_index < 0:
		_set_message("猪窝只能接收猪、土豆或胡萝卜，且对应槽位要有空间。")
		return false
	return source.move_stack_to(_inventory, source_index, target_index)


func _on_nest_slot_gui_input(event: InputEvent, index: int) -> void:
	if not (event is InputEventMouseButton):
		return
	var button := event as InputEventMouseButton
	if not button.pressed or button.button_index != MOUSE_BUTTON_LEFT:
		return
	if not Input.is_key_pressed(KEY_SHIFT) or _bag_inventory == null or _inventory == null:
		return
	var source_slot := _inventory.get_slot(index)
	if source_slot.is_empty():
		return
	var item_id := str(source_slot.get("item_id", ""))
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
	if target_index == WorldObjects.NEST_SLOT_OUTPUT:
		_set_message("输出槽只能取出，不能放入。")
		return
	if target_index == WorldObjects.NEST_SLOT_FOOD:
		if not ItemDB.is_crop(item_id):
			_set_message("食物槽只能放土豆或胡萝卜。")
			return
	else:
		if item_id != "pig":
			_set_message("亲代槽只能放猪。")
			return

	if source.move_stack_to(_inventory, source_index, target_index):
		_message_label.text = ""
		_refresh()


func _refresh() -> void:
	if _inventory == null:
		return
	for index in _slots.size():
		var slot_data := _inventory.get_slot(index)
		var icon := _slot_icons[index]
		var count_label := _slot_counts[index]
		var panel := _slots[index]
		if slot_data.is_empty():
			icon.texture = null
			count_label.text = ""
			panel.tooltip_text = "空槽"
		else:
			var item_id := str(slot_data.get("item_id", ""))
			var count := int(slot_data.get("count", 0))
			icon.texture = ItemDB.get_icon(item_id)
			count_label.text = str(count) if count > 1 else ""
			if item_id == "pig":
				var rgb: Vector3i = slot_data.get("pig_rgb", Vector3i.ZERO)
				var pig_name := str(slot_data.get("pig_name", "猪"))
				panel.tooltip_text = "%s\nRGB (%d, %d, %d)\n背包物品 %d 格" % [
					pig_name,
					rgb.x,
					rgb.y,
					rgb.z,
					_pig_inventory_size(slot_data),
				]
			else:
				panel.tooltip_text = "%s ×%d" % [ItemDB.get_display_name(item_id), count]
		_update_rgb_label(index, slot_data)

	_refresh_progress()


func _refresh_progress() -> void:
	if _inventory == null:
		return
	var progress := float(_nest.get("progress", 0.0))
	_progress_bar.value = progress
	_progress_label.text = "%.1f / %.1fs" % [progress, WorldObjects.NEST_BREED_SECONDS]
	var food := _inventory.get_slot(WorldObjects.NEST_SLOT_FOOD)
	var food_id := str(food.get("item_id", ""))
	var food_count := int(food.get("count", 0)) if ItemDB.is_crop(food_id) else 0
	_food_label.text = "食物 %d / %d" % [food_count, WorldObjects.NEST_FOOD_REQUIRED]

	var a := _inventory.get_slot(WorldObjects.NEST_SLOT_PARENT_A)
	var b := _inventory.get_slot(WorldObjects.NEST_SLOT_PARENT_B)
	var out := _inventory.get_slot(WorldObjects.NEST_SLOT_OUTPUT)
	if not out.is_empty():
		_status_label.text = "新生猪已产出，拖出输出槽后可继续繁育。"
	elif str(a.get("item_id", "")) != "pig" or str(b.get("item_id", "")) != "pig":
		_status_label.text = "需要两只亲代猪。"
	elif food_count < WorldObjects.NEST_FOOD_REQUIRED:
		_status_label.text = "食物不足 %d。" % WorldObjects.NEST_FOOD_REQUIRED
	elif bool(_nest.get("active", false)):
		_status_label.text = "繁育中……"
	else:
		_status_label.text = "准备中……"


func _update_rgb_label(index: int, slot_data: Dictionary) -> void:
	var rgb_label := _rgb_labels[index]
	if slot_data.is_empty() or str(slot_data.get("item_id", "")) != "pig":
		rgb_label.text = "—"
		rgb_label.add_theme_color_override("font_color", UIStyle.TEXT_MUTED)
		return
	var rgb: Vector3i = slot_data.get("pig_rgb", Vector3i.ZERO)
	rgb_label.text = "RGB %d,%d,%d" % [rgb.x, rgb.y, rgb.z]
	rgb_label.add_theme_color_override("font_color", UIStyle.TEXT_MUTED)


func _pig_inventory_size(slot_data: Dictionary) -> int:
	var inventory: Variant = slot_data.get("pig_inventory")
	if inventory is Inventory:
		var pig_inventory: Inventory = inventory
		return pig_inventory.get_used_slot_count()
	return 0


func _set_message(text: String) -> void:
	_message_label.text = text


func _on_inventory_changed() -> void:
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
