class_name BehaviorModuleRow
extends PanelContainer
## 行为模块行：拖动整行到其他行即可重排。

var owner_ui: Node
var module_index := -1


func _get_drag_data(_at_position: Vector2) -> Variant:
	if owner_ui == null or module_index < 0:
		return null
	var preview := PanelContainer.new()
	preview.add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(Color(0.12, 0.18, 0.10, 0.96), 8, UIStyle.ACCENT, 1, false)
	)
	var label := Label.new()
	label.text = "移动模块 #%d" % (module_index + 1)
	label.add_theme_font_override("font", UIStyle.bold_font())
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", UIStyle.TEXT)
	label.add_theme_constant_override("outline_size", 2)
	preview.add_child(label)
	set_drag_preview(preview)
	return {"behavior_module_index": module_index}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("behavior_module_index")


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if owner_ui == null or not (data is Dictionary):
		return
	owner_ui.move_module(int(data.get("behavior_module_index", -1)), module_index)
