class_name CraftingUI
extends PanelContainer
## 合成面板。使用当前选中猪的背包作为材料来源。

var _inventory: Inventory
var _rows: Array[Dictionary] = []
var _status_label: Label


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(470.0, 0.0)
	add_theme_stylebox_override("panel", UIStyle.make_panel(UIStyle.PANEL, 18))
	_build_layout()


func setup(inventory: Inventory) -> void:
	if _inventory != null and _inventory.changed.is_connected(_on_inventory_changed):
		_inventory.changed.disconnect(_on_inventory_changed)
	_inventory = inventory
	if _inventory != null:
		_inventory.changed.connect(_on_inventory_changed)
	_refresh()


func unbind() -> void:
	if _inventory != null and _inventory.changed.is_connected(_on_inventory_changed):
		_inventory.changed.disconnect(_on_inventory_changed)
	_inventory = null
	visible = false


func toggle() -> void:
	visible = not visible
	if visible:
		_refresh()


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
	var title := _make_label("合成", 22, UIStyle.TEXT, true)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	var hint := _make_label("C 关闭", 12, UIStyle.TEXT_MUTED)
	hint.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(hint)

	var subtitle := _make_label(
		"使用当前猪的背包材料；点击配方合成。按住 Shift 点击一次合成一组（最多 64 个产物）。",
		12,
		UIStyle.TEXT_MUTED
	)
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(subtitle)

	var separator := ColorRect.new()
	separator.color = Color(0.72, 0.80, 0.59, 0.14)
	separator.custom_minimum_size = Vector2(0.0, 1.0)
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(separator)

	for index in Crafting.RECIPES.size():
		content.add_child(_build_recipe_row(index))

	_status_label = _make_label("", 12, UIStyle.TEXT_MUTED)
	_status_label.custom_minimum_size = Vector2(0.0, 20.0)
	content.add_child(_status_label)


func _build_recipe_row(index: int) -> Control:
	var recipe: Dictionary = Crafting.RECIPES[index]
	var output_id := str(recipe.get("output", ""))
	var output_amount := int(recipe.get("output_amount", 1))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var icon := TextureRect.new()
	icon.texture = ItemDB.get_icon(output_id)
	icon.custom_minimum_size = Vector2(38.0, 38.0)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(icon)

	var text_box := VBoxContainer.new()
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_box.add_theme_constant_override("separation", 1)
	row.add_child(text_box)

	var name_label := _make_label(
		"%s ×%d" % [ItemDB.get_display_name(output_id), output_amount],
		14,
		UIStyle.TEXT,
		true
	)
	text_box.add_child(name_label)

	var ingredient_label := _make_label(
		_ingredient_text(recipe),
		12,
		UIStyle.TEXT_MUTED
	)
	text_box.add_child(ingredient_label)

	var button := Button.new()
	button.text = "合成 ×%d" % output_amount
	button.custom_minimum_size = Vector2(94.0, 34.0)
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_override("font", UIStyle.bold_font())
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", UIStyle.TEXT)
	button.add_theme_color_override("font_hover_color", UIStyle.ACCENT)
	button.add_theme_color_override("font_disabled_color", Color(0.55, 0.59, 0.50, 0.7))
	button.add_theme_stylebox_override(
		"normal",
		UIStyle.make_panel(Color(0.19, 0.24, 0.15, 0.97), 8, UIStyle.SLOT_BORDER, 1, false)
	)
	button.add_theme_stylebox_override(
		"hover",
		UIStyle.make_panel(Color(0.25, 0.31, 0.20, 1.0), 8, UIStyle.ACCENT, 1, false)
	)
	button.add_theme_stylebox_override(
		"pressed",
		UIStyle.make_panel(Color(0.13, 0.17, 0.10, 1.0), 8, UIStyle.ACCENT, 1, false)
	)
	button.add_theme_stylebox_override(
		"disabled",
		UIStyle.make_panel(Color(0.11, 0.14, 0.09, 0.9), 8, UIStyle.SLOT_BORDER, 1, false)
	)
	button.pressed.connect(_craft.bind(index))
	row.add_child(button)

	_rows.append({
		"button": button,
		"ingredients": ingredient_label,
		"recipe": recipe,
	})
	return row


func _ingredient_text(recipe: Dictionary) -> String:
	var parts: Array[String] = []
	var ingredients: Dictionary = recipe.get("ingredients", {})
	for item_id in ingredients.keys():
		parts.append(
			"%s ×%d"
			% [ItemDB.get_display_name(str(item_id)), int(ingredients[item_id])]
		)
	return " + ".join(parts)


func _refresh() -> void:
	if _inventory == null:
		return
	for row in _rows:
		var recipe: Dictionary = row["recipe"]
		var button: Button = row["button"]
		var ingredient_label: Label = row["ingredients"]
		var available := Crafting.can_craft(_inventory, recipe)
		button.disabled = not available
		ingredient_label.add_theme_color_override(
			"font_color",
			UIStyle.TEXT_MUTED if available else Color(0.75, 0.50, 0.43, 0.9)
		)


func _craft(index: int) -> void:
	if _inventory == null:
		return
	var recipe: Dictionary = Crafting.RECIPES[index]
	var output_id := str(recipe.get("output", ""))
	var output_amount := int(recipe.get("output_amount", 1))
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var target_total := ItemDB.get_max_stack(output_id) if shift else output_amount
	var crafted_amount := 0
	var groups := 0
	while crafted_amount < target_total and Crafting.craft(_inventory, recipe):
		crafted_amount += output_amount
		groups += 1
	if groups > 0:
		if shift:
			_status_label.text = "连续合成 %d 组：%s ×%d" % [
				groups, ItemDB.get_display_name(output_id), crafted_amount
			]
		else:
			_status_label.text = "合成成功：%s ×%d" % [
				ItemDB.get_display_name(output_id), crafted_amount
			]
		_status_label.add_theme_color_override("font_color", UIStyle.GOOD)
	else:
		_status_label.text = "材料不足，或背包没有空间放置产物。"
		_status_label.add_theme_color_override("font_color", UIStyle.BAD)
	_refresh()


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
