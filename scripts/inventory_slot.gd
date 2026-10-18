class_name InventorySlot
extends Panel
## 背包/箱子的单个槽位。除点击选择外，负责把物品拖到另一个槽位。

var inventory: Inventory
var slot_index := -1
var owner_ui: Node


func _get_drag_data(_at_position: Vector2) -> Variant:
	if inventory == null:
		return null
	var slot := inventory.get_slot(slot_index)
	if slot.is_empty():
		return null

	var item_id := str(slot.get("item_id", ""))
	var count := int(slot.get("count", 0))
	var preview := _make_drag_preview(item_id, count)
	if preview != null:
		set_drag_preview(preview)

	return {
		"source_inventory": inventory,
		"source_index": slot_index,
		"item_id": item_id,
		"count": count,
	}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if inventory == null:
		return false
	if not (data is Dictionary):
		return false
	var source_inventory: Variant = data.get("source_inventory")
	return source_inventory is Inventory


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if owner_ui == null or inventory == null:
		return
	if not (data is Dictionary):
		return
	owner_ui.handle_slot_drop(data, slot_index)


func _make_drag_preview(item_id: String, count: int) -> Control:
	var preview := PanelContainer.new()
	preview.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(Color(0.10, 0.14, 0.08, 0.96), 10, UIStyle.ACCENT, 1, true)
	)
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 7)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_right", 9)
	margin.add_theme_constant_override("margin_bottom", 5)
	preview.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	margin.add_child(row)

	var icon := TextureRect.new()
	icon.texture = ItemDB.get_icon(item_id)
	icon.custom_minimum_size = Vector2(30.0, 30.0)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var label := Label.new()
	label.text = "%s ×%d" % [ItemDB.get_display_name(item_id), count]
	label.add_theme_font_override("font", UIStyle.bold_font())
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", UIStyle.TEXT)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	return preview
