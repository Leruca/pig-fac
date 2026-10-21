class_name MachineUI
extends PanelContainer
## 产线机器面板。
##
## 辊压机/冲压机/装配台是手摇加工：直接读取当前猪的背包，按配方扣料并产出。
## 猪力发电机/肉肉仓有独立状态：猪槽、电力、加工进度和鲜肉产物。

var _world: WorldObjects
var _machine: Dictionary
var _cell: Vector2i
var _bag: Inventory
var _title_label: Label
var _description_label: Label
var _body: VBoxContainer
var _status_label: Label
var _message_label: Label
var _power_bar: ProgressBar
var _power_label: Label
var _progress_bar: ProgressBar
var _progress_label: Label
var _pig_icon: TextureRect
var _pig_label: Label
var _output_icon: TextureRect
var _output_label: Label
var _insert_pig_button: Button
var _remove_pig_button: Button
var _collect_button: Button
var _recipe_buttons: Array[Button] = []
var _recipe_rows: Array[Dictionary] = []


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(510.0, 0.0)
	add_theme_stylebox_override("panel", UIStyle.make_panel(UIStyle.PANEL, 18))
	_build_base()


func setup(
	world: WorldObjects,
	machine: Dictionary,
	cell: Vector2i,
	owner_name: String,
	bag: Inventory
) -> void:
	_unbind()
	_world = world
	_machine = machine
	_cell = cell
	_bag = bag
	if _bag != null:
		_bag.changed.connect(_refresh)
	_title_label.text = "%s · %s" % [
		WorldObjects.MACHINE_TYPES.get(str(machine.get("type", "")), "机器"),
		owner_name,
	]
	_description_label.text = _description_for(str(machine.get("type", "")))
	_rebuild_body()
	_message_label.text = ""
	_refresh()


func unbind() -> void:
	_unbind()
	visible = false


func is_open() -> bool:
	return visible


func _unbind() -> void:
	if _bag != null and _bag.changed.is_connected(_refresh):
		_bag.changed.disconnect(_refresh)
	_bag = null
	_world = null
	_machine = {}
	_cell = Vector2i.ZERO
	_recipe_buttons.clear()
	_recipe_rows.clear()


func _process(_delta: float) -> void:
	if visible:
		_refresh_dynamic()


func _build_base() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 9)
	margin.add_child(content)

	var header := HBoxContainer.new()
	content.add_child(header)
	_title_label = _make_label("机器", 22, UIStyle.TEXT, true)
	header.add_child(_title_label)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	header.add_child(_make_label("Esc 关闭", 12, UIStyle.TEXT_MUTED))

	_description_label = _make_label("", 12, UIStyle.TEXT_MUTED)
	content.add_child(_description_label)
	var separator := ColorRect.new()
	separator.color = Color(0.72, 0.80, 0.59, 0.14)
	separator.custom_minimum_size = Vector2(0.0, 1.0)
	separator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(separator)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 7)
	content.add_child(_body)
	_status_label = _make_label("", 12, UIStyle.TEXT_MUTED)
	content.add_child(_status_label)
	_message_label = _make_label("", 12, UIStyle.BAD)
	content.add_child(_message_label)


func _rebuild_body() -> void:
	for child in _body.get_children():
		child.queue_free()
	_recipe_buttons.clear()
	_recipe_rows.clear()
	_power_bar = null
	_progress_bar = null
	_pig_icon = null
	_output_icon = null
	var machine_type := str(_machine.get("type", ""))
	if WorldObjects.PROCESSING_RECIPES.has(machine_type):
		_build_recipe_list(machine_type)
	elif machine_type == "pig_generator":
		_build_generator_card()
	elif machine_type == "meat_storage":
		_build_meat_card()


func _build_recipe_list(machine_type: String) -> void:
	var recipes: Array = WorldObjects.PROCESSING_RECIPES.get(machine_type, [])
	for recipe_value in recipes:
		var recipe: Dictionary = recipe_value
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_body.add_child(row)
		var icon := TextureRect.new()
		icon.texture = ItemDB.get_icon(str(recipe.get("output", "")))
		icon.custom_minimum_size = Vector2(40.0, 40.0)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(icon)
		var text_box := VBoxContainer.new()
		text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text_box)
		text_box.add_child(_make_label(
			"%s ×%d" % [
				ItemDB.get_display_name(str(recipe.get("output", ""))),
				int(recipe.get("output_amount", 1)),
			],
			14,
			UIStyle.TEXT,
			true
		))
		var ingredient_label := _make_label(
			_format_ingredients(recipe.get("ingredients", {})),
			12,
			UIStyle.TEXT_MUTED
		)
		text_box.add_child(ingredient_label)
		var button := Button.new()
		button.text = "加工"
		button.custom_minimum_size = Vector2(74.0, 34.0)
		button.pressed.connect(_on_recipe_pressed.bind(recipe))
		row.add_child(button)
		_recipe_buttons.append(button)
		_recipe_rows.append({"recipe": recipe, "button": button, "ingredients": ingredient_label})


func _build_generator_card() -> void:
	var card := _build_state_card("猪力发电机", false, false)
	_pig_icon = card["pig_icon"]
	_pig_label = card["pig_label"]
	_power_bar = card["power_bar"]
	_power_label = card["power_label"]
	_insert_pig_button = card["insert_button"]
	_remove_pig_button = card["remove_button"]
	_insert_pig_button.pressed.connect(_on_insert_pig)
	_remove_pig_button.pressed.connect(_on_remove_pig)


func _build_meat_card() -> void:
	var card := _build_state_card("肉肉仓")
	_pig_icon = card["pig_icon"]
	_pig_label = card["pig_label"]
	_progress_bar = card["progress_bar"]
	_progress_label = card["progress_label"]
	_power_label = card["power_label"]
	_output_icon = card["output_icon"]
	_output_label = card["output_label"]
	_insert_pig_button = card["insert_button"]
	_remove_pig_button = card["remove_button"]
	_collect_button = card["collect_button"]
	_insert_pig_button.pressed.connect(_on_insert_pig)
	_remove_pig_button.pressed.connect(_on_remove_pig)
	_collect_button.pressed.connect(_on_collect_output)


func _build_state_card(
	title_text: String,
	show_progress: bool = true,
	show_output: bool = true
) -> Dictionary:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 6)
	_body.add_child(card)
	card.add_child(_make_label(title_text, 14, UIStyle.TEXT_MUTED, true))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	card.add_child(row)
	var pig_icon := TextureRect.new()
	pig_icon.texture = ItemDB.get_icon("pig")
	pig_icon.custom_minimum_size = Vector2(42.0, 42.0)
	pig_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pig_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(pig_icon)
	var pig_label := _make_label("猪槽：空", 12, UIStyle.TEXT_MUTED)
	pig_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(pig_label)
	var insert_button := Button.new()
	insert_button.text = "放入猪"
	insert_button.custom_minimum_size = Vector2(78.0, 32.0)
	row.add_child(insert_button)
	var remove_button := Button.new()
	remove_button.text = "取出猪"
	remove_button.custom_minimum_size = Vector2(78.0, 32.0)
	row.add_child(remove_button)
	var progress_bar := _make_bar(Color("#E0B23C"))
	var progress_label := _make_label("加工进度：0%", 12, UIStyle.TEXT_MUTED)
	var power_bar := _make_bar(UIStyle.ACCENT)
	var power_label := _make_label("电力：0 / 100", 12, UIStyle.TEXT_MUTED)
	card.add_child(power_label)
	card.add_child(power_bar)
	if show_progress:
		card.add_child(progress_label)
		card.add_child(progress_bar)
	var output_row := HBoxContainer.new()
	output_row.add_theme_constant_override("separation", 8)
	var output_icon := TextureRect.new()
	output_icon.texture = ItemDB.get_icon("fresh_meat")
	output_icon.custom_minimum_size = Vector2(34.0, 34.0)
	output_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	output_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var output_label := _make_label("产物：无", 12, UIStyle.TEXT_MUTED)
	output_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var collect_button := Button.new()
	collect_button.text = "取出鲜肉"
	collect_button.custom_minimum_size = Vector2(96.0, 32.0)
	if show_output:
		output_row.add_child(output_icon)
		output_row.add_child(output_label)
		output_row.add_child(collect_button)
		card.add_child(output_row)
	return {
		"pig_icon": pig_icon,
		"pig_label": pig_label,
		"insert_button": insert_button,
		"remove_button": remove_button,
		"power_bar": power_bar,
		"power_label": power_label,
		"progress_bar": progress_bar,
		"progress_label": progress_label,
		"output_icon": output_icon,
		"output_label": output_label,
		"collect_button": collect_button,
	}


func _refresh() -> void:
	if _bag == null or _world == null:
		return
	_refresh_dynamic()


func _refresh_dynamic() -> void:
	if _machine.is_empty() or _world == null:
		return
	var machine_type := str(_machine.get("type", ""))
	if WorldObjects.PROCESSING_RECIPES.has(machine_type):
		var can_any := false
		for row in _recipe_rows:
			var recipe: Dictionary = row["recipe"]
			var button: Button = row["button"]
			var available := (
				_bag != null
				and Crafting.can_craft(_bag, recipe)
				and _bag.can_add_item(str(recipe.get("output", "")), int(recipe.get("output_amount", 1)))
			)
			button.disabled = not available
			can_any = can_any or available
			var label: Label = row["ingredients"]
			label.add_theme_color_override(
				"font_color",
				UIStyle.TEXT_MUTED if available else Color(0.75, 0.50, 0.43, 0.9)
			)
		_status_label.text = (
			"材料已放入背包；点击“加工”手摇一次。"
			if can_any
			else "把对应的锭/板/线/零件放进背包后再加工。"
		)
	elif machine_type == "pig_generator":
		var power := float(_machine.get("power", 0.0))
		var has_pig := not (_machine.get("pig", {}) as Dictionary).is_empty()
		_power_bar.max_value = WorldObjects.GENERATOR_POWER_MAX
		_power_bar.value = power
		_power_label.text = "电力：%d / %d" % [int(power), int(WorldObjects.GENERATOR_POWER_MAX)]
		_pig_label.text = "猪槽：%s" % (
			"发电中" if has_pig else "空（放入一头猪）"
		)
		_insert_pig_button.disabled = has_pig or _bag == null
		_remove_pig_button.disabled = not has_pig
		_status_label.text = (
			"猪在发电机轮子里跑动，每秒产生 2 电力。附近肉肉仓会消耗电力。"
			if has_pig
			else "放入一头被捡起的猪，开始发电。"
		)
	elif machine_type == "meat_storage":
		var pig := _machine.get("pig", {}) as Dictionary
		var output := _machine.get("output", {}) as Dictionary
		var power := _world.get_power_near(_cell)
		var progress := float(_machine.get("progress", 0.0))
		_progress_bar.max_value = WorldObjects.MEAT_PROCESS_SECONDS
		_progress_bar.value = progress
		_progress_label.text = "加工进度：%d / %d 秒" % [
			int(progress),
			int(WorldObjects.MEAT_PROCESS_SECONDS),
		]
		_power_label.text = "附近电力：%d / %d" % [
			int(power),
			int(WorldObjects.MEAT_POWER_COST),
		]
		_pig_label.text = "输入猪：%s" % ("已放入" if not pig.is_empty() else "空")
		if output.is_empty():
			_output_label.text = "产物：无"
		else:
			_output_label.text = "产物：%s ×%d" % [
				ItemDB.get_display_name(str(output.get("item_id", ""))),
				int(output.get("count", 0)),
			]
		_insert_pig_button.disabled = not pig.is_empty() or _bag == null
		_remove_pig_button.disabled = pig.is_empty()
		_collect_button.disabled = output.is_empty() or _bag == null
		if output.is_empty() and pig.is_empty():
			_status_label.text = "放入猪；附近有发电中的猪力发电机时自动加工。"
		elif output.is_empty() and not pig.is_empty() and power < WorldObjects.MEAT_POWER_COST:
			_status_label.text = "没有足够电力：在 3 格内放一台发电中的猪力发电机。"
		elif not output.is_empty():
			_status_label.text = "鲜肉已产出，取出后可以继续放入猪。"
		else:
			_status_label.text = "加工中：需要 5 电力，产出 2 份鲜肉。"


func _on_recipe_pressed(recipe: Dictionary) -> void:
	if _bag == null:
		return
	var output_id := str(recipe.get("output", ""))
	var output_amount := int(recipe.get("output_amount", 1))
	if not _bag.can_add_item(output_id, output_amount):
		_message_label.text = "背包空间不足，产物需要 %d 格。" % output_amount
		return
	if Crafting.craft(_bag, recipe):
		_message_label.text = ""
		_status_label.text = "加工完成：%s ×%d" % [
			ItemDB.get_display_name(output_id),
			output_amount,
		]
	else:
		_message_label.text = "材料不足，无法加工。"


func _on_insert_pig() -> void:
	if _world != null and _world.insert_pig_into_machine(_cell, _bag):
		_message_label.text = ""
		_refresh_dynamic()
	else:
		_message_label.text = "背包里没有被捡起的猪，或猪槽已占用。"


func _on_remove_pig() -> void:
	if _world != null and _world.remove_pig_from_machine(_cell, _bag):
		_message_label.text = ""
		_refresh_dynamic()
	else:
		_message_label.text = "背包没有空位，无法取回猪。"


func _on_collect_output() -> void:
	if _world != null and _world.collect_machine_output(_cell, _bag):
		_message_label.text = ""
		_refresh_dynamic()
	else:
		_message_label.text = "背包空间不足，无法取出鲜肉。"


func _description_for(machine_type: String) -> String:
	match machine_type:
		"roller":
			return "手摇机器：铁锭/铜锭/金锭 → 对应金属板。"
		"press":
			return "手摇机器：铁板/铜板/金板 → 对应金属线。"
		"assembler":
			return "手摇装配：用金属板和线装配猪力发电机、肉肉仓。"
		"pig_generator":
			return "猪进去滚动发电；3 格内的肉肉仓可以使用这些电力。"
		"meat_storage":
			return "输入猪，消耗附近发电机的电力，产出鲜肉。"
	return ""


func _format_ingredients(ingredients: Dictionary) -> String:
	var parts: Array[String] = []
	for item_id in ingredients.keys():
		parts.append("%s ×%d" % [
			ItemDB.get_display_name(str(item_id)),
			int(ingredients[item_id]),
		])
	return " + ".join(parts)


func _make_bar(color: Color) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0.0, 9.0)
	bar.add_theme_stylebox_override(
		"background", UIStyle.make_panel(Color(0.09, 0.12, 0.07, 0.9), 5, UIStyle.SLOT_BORDER, 1, false)
	)
	bar.add_theme_stylebox_override("fill", UIStyle.make_panel(color, 5, color, 0, false))
	return bar


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
