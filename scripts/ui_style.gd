class_name UIStyle
extends RefCounted
## 项目内共享的 UI 色彩与样式工厂，避免每个界面各写一套颜色。

const TEXT := Color("#F8F2E3")
const TEXT_MUTED := Color("#B8C4A9")
const ACCENT := Color("#F2C45B")
const GOOD := Color("#A9D86E")
const BAD := Color("#E88C7D")

const PANEL := Color(0.086, 0.118, 0.075, 0.94)
const PANEL_SOFT := Color(0.12, 0.16, 0.10, 0.94)
const PANEL_BORDER := Color(0.70, 0.78, 0.58, 0.22)
const SLOT := Color(0.15, 0.19, 0.13, 0.94)
const SLOT_FILLED := Color(0.22, 0.27, 0.17, 0.96)
const SLOT_BORDER := Color(0.55, 0.64, 0.45, 0.24)
const SLOT_BORDER_FILLED := Color(0.83, 0.90, 0.62, 0.40)

static var _regular_font: SystemFont
static var _bold_font: SystemFont


static func regular_font() -> SystemFont:
	if _regular_font == null:
		_regular_font = _make_font(400)
	return _regular_font


static func bold_font() -> SystemFont:
	if _bold_font == null:
		_bold_font = _make_font(700)
	return _bold_font


## 使用系统中文字体，并保留 emoji 字体作为回退。Godot 会按顺序寻找可用字体。
static func _make_font(weight: int) -> SystemFont:
	var font := SystemFont.new()
	font.font_names = PackedStringArray([
		"Microsoft YaHei UI",
		"Microsoft YaHei",
		"Noto Sans CJK SC",
		"Noto Sans SC",
		"PingFang SC",
		"Segoe UI Emoji",
		"Segoe UI",
	])
	font.font_weight = weight
	font.allow_system_fallback = true
	font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
	return font


static func make_panel(
	bg: Color = PANEL,
	radius: int = 16,
	border: Color = PANEL_BORDER,
	border_width: int = 1,
	with_shadow: bool = true
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	if with_shadow:
		style.shadow_color = Color(0.02, 0.04, 0.01, 0.34)
		style.shadow_size = 18
		style.shadow_offset = Vector2(0, 7)
	return style


static func make_keycap() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.21, 0.26, 0.17, 0.98)
	style.border_color = Color(0.72, 0.80, 0.59, 0.30)
	style.set_border_width_all(1)
	style.set_corner_radius_all(7)
	return style


static func make_dot(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(99)
	style.border_color = color.lightened(0.22)
	style.set_border_width_all(1)
	return style
