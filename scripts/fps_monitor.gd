class_name FPSMonitor
extends PanelContainer
## 右上角常驻 FPS 监控。可在 Esc 设置里关闭；默认开启。

var _label: Label
var _elapsed := 0.0
var _frames := 0
var _enabled := true


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	process_mode = Node.PROCESS_MODE_ALWAYS
	z_index = 200
	custom_minimum_size = Vector2(150.0, 34.0)
	add_theme_stylebox_override(
		"panel",
		UIStyle.make_panel(Color(0.04, 0.07, 0.035, 0.82), 8, UIStyle.SLOT_BORDER, 1, false)
	)
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_label.offset_left = 10.0
	_label.offset_right = -10.0
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_font_override("font", UIStyle.bold_font())
	_label.add_theme_font_size_override("font_size", 12)
	_label.add_theme_color_override("font_outline_color", Color(0.01, 0.02, 0.01, 0.9))
	_label.add_theme_constant_override("outline_size", 3)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	visible = _enabled
	set_process(_enabled)
	_refresh()


func set_enabled(enabled: bool) -> void:
	_enabled = enabled
	visible = enabled
	set_process(enabled)
	if enabled:
		_refresh()


func is_enabled() -> bool:
	return _enabled


func _process(delta: float) -> void:
	_elapsed += delta
	_frames += 1
	if _elapsed < 0.25:
		return
	var fps := float(_frames) / maxf(0.001, _elapsed)
	var ms := 1000.0 / maxf(0.001, fps)
	_elapsed = 0.0
	_frames = 0
	_refresh(fps, ms)


func _refresh(fps: float = 0.0, ms: float = 0.0) -> void:
	if _label == null:
		return
	if fps <= 0.0:
		_label.text = "FPS --  ·  -- ms"
		return
	_label.text = "FPS %d  ·  %.1f ms" % [int(round(fps)), ms]
	if fps < 30.0:
		_label.add_theme_color_override("font_color", UIStyle.BAD)
	elif fps < 50.0:
		_label.add_theme_color_override("font_color", UIStyle.ACCENT)
	else:
		_label.add_theme_color_override("font_color", UIStyle.GOOD)
