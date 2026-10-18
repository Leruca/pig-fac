class_name WorldObjects
extends Node2D
## 世界中的可交互障碍物：3 × 3 大树、树苗、木头、木板、箱子、栅栏和猪窝。
##
## 树和木头、木板、箱子、栅栏、猪窝阻挡寻路；互动范围只按格子距离计算，不受
## 障碍影响。树需要敲 3~5 下才会倒。树苗每 30 秒生长一个阶段，90 秒成熟后转换
## 成 3 × 3 大树。每个箱子拥有独立的 40 格 Inventory；栅栏根据相邻方块按方向
## 伸出连接杆；猪窝占 3 × 3，内部 4 格用于两只亲代猪、食物和新生猪。

signal tree_grew(cell: Vector2i)
signal nest_changed(root: Vector2i)

const TREE_SIZE := 3
const SAPLING_CENTER_OFFSET := Vector2i(1, 1)
const INVALID_CELL := Vector2i(-999999, -999999)
const SAPLING_STAGE_SECONDS := 30.0
const SAPLING_MATURE_STAGE := 3

const NEST_SIZE := 3
const NEST_BREED_SECONDS := 10.0
const NEST_FOOD_REQUIRED := 10
const NEST_SLOT_PARENT_A := 0
const NEST_SLOT_PARENT_B := 1
const NEST_SLOT_FOOD := 2
const NEST_SLOT_OUTPUT := 3

const STEM := Color("#6F4A2B")
const LEAF_DARK := Color("#3E8436")
const LEAF_MID := Color("#61AA45")
const LEAF_LIGHT := Color("#91CF62")
const SAPLING_SPARKLE := Color("#FFE18A")

@export var cell_size: int = 36

var tree_roots: Array[Vector2i] = []
var logs: Dictionary = {}
## cell -> true
var planks: Dictionary = {}
## cell -> {"stage": int, "elapsed": float}
var saplings: Dictionary = {}
## cell -> Inventory（每个箱子独立 40 格）
var chests: Dictionary = {}
## cell -> true
var fences: Dictionary = {}
## root -> {"inventory": Inventory(4), "progress": float, "active": bool}
var nests: Dictionary = {}
## tree root -> remaining hammer hits
var _tree_hits: Dictionary = {}
var _next_born_pig_index := 4

## 由 Main 注入：检查农田、猪等 WorldObjects 不直接了解的额外占地情况。
var mature_area_guard: Callable = Callable()

var _tree_texture: Texture2D
var _log_texture: Texture2D
var _chest_texture: Texture2D
var _nest_texture: Texture2D


func _ready() -> void:
	z_index = 1
	_tree_texture = load("res://assets/tree.svg") as Texture2D
	_log_texture = load("res://assets/log.svg") as Texture2D
	_chest_texture = load("res://assets/chest.svg") as Texture2D
	_nest_texture = load("res://assets/pig_nest.svg") as Texture2D
	queue_redraw()


func _process(delta: float) -> void:
	advance_sapling_growth(delta)
	_advance_nests(delta)


func add_tree(root: Vector2i) -> void:
	if not tree_roots.has(root):
		tree_roots.append(root)
		_tree_hits[root] = randi_range(3, 5)
		queue_redraw()


func remove_tree(root: Vector2i) -> bool:
	var index := tree_roots.find(root)
	if index < 0:
		return false
	tree_roots.remove_at(index)
	_tree_hits.erase(root)
	queue_redraw()
	return true


func get_tree_remaining_hits(root: Vector2i) -> int:
	return int(_tree_hits.get(root, 0))


## 锤一下树。返回 {"felled": bool, "remaining": int}。
func hit_tree(root: Vector2i) -> Dictionary:
	if not tree_roots.has(root):
		return {}
	var remaining := maxi(0, get_tree_remaining_hits(root) - 1)
	if remaining <= 0:
		remove_tree(root)
		return {"felled": true, "remaining": 0}
	_tree_hits[root] = remaining
	queue_redraw()
	return {"felled": false, "remaining": remaining}


func find_tree_root(cell: Vector2i) -> Vector2i:
	for root in tree_roots:
		if (
			cell.x >= root.x
			and cell.x < root.x + TREE_SIZE
			and cell.y >= root.y
			and cell.y < root.y + TREE_SIZE
		):
			return root
	return INVALID_CELL


func is_tree_cell(cell: Vector2i) -> bool:
	return find_tree_root(cell) != INVALID_CELL


func plant_sapling(cell: Vector2i) -> bool:
	if is_blocked(cell):
		return false
	saplings[cell] = {"stage": 0, "elapsed": 0.0}
	queue_redraw()
	return true


func has_sapling(cell: Vector2i) -> bool:
	return saplings.has(cell)


func get_sapling_stage(cell: Vector2i) -> int:
	if not saplings.has(cell):
		return -1
	return int(saplings[cell].get("stage", 0))


func get_sapling_seconds_to_next_stage(cell: Vector2i) -> float:
	if not saplings.has(cell):
		return 0.0
	var data: Dictionary = saplings[cell]
	if int(data.get("stage", 0)) >= SAPLING_MATURE_STAGE:
		return 0.0
	return maxf(0.0, SAPLING_STAGE_SECONDS - float(data.get("elapsed", 0.0)))


## 超级水壶对树苗使用：推进一个阶段。
func water_sapling(cell: Vector2i) -> bool:
	if not saplings.has(cell):
		return false
	var data: Dictionary = saplings[cell]
	var stage := int(data.get("stage", 0))
	if stage >= SAPLING_MATURE_STAGE:
		_try_mature(cell)
		return false

	data["stage"] = stage + 1
	data["elapsed"] = 0.0
	queue_redraw()
	if int(data["stage"]) >= SAPLING_MATURE_STAGE:
		_try_mature(cell)
	return true


## 自然生长；独立成方法便于测试时快进时间。
func advance_sapling_growth(seconds: float) -> void:
	if seconds <= 0.0:
		return
	for cell in saplings.keys():
		if not saplings.has(cell):
			continue
		var data: Dictionary = saplings[cell]
		var stage := int(data.get("stage", 0))
		if stage >= SAPLING_MATURE_STAGE:
			_try_mature(cell)
			continue

		var elapsed := float(data.get("elapsed", 0.0)) + seconds
		var advanced := false
		while elapsed >= SAPLING_STAGE_SECONDS and stage < SAPLING_MATURE_STAGE:
			elapsed -= SAPLING_STAGE_SECONDS
			stage += 1
			advanced = true
		data["stage"] = stage
		data["elapsed"] = elapsed
		if advanced:
			queue_redraw()
		if stage >= SAPLING_MATURE_STAGE:
			_try_mature(cell)


func _try_mature(cell: Vector2i) -> bool:
	if not saplings.has(cell):
		return false
	var data: Dictionary = saplings[cell]
	if int(data.get("stage", 0)) < SAPLING_MATURE_STAGE:
		return false

	# 以树苗为中心，大树占 3 × 3。
	var root := cell - SAPLING_CENTER_OFFSET
	for y in TREE_SIZE:
		for x in TREE_SIZE:
			var check_cell := root + Vector2i(x, y)
			if check_cell == cell:
				continue
			if is_blocked(check_cell):
				return false

	if mature_area_guard.is_valid():
		if not bool(mature_area_guard.call(root, TREE_SIZE)):
			return false

	saplings.erase(cell)
	add_tree(root)
	tree_grew.emit(cell)
	return true


func place_log(cell: Vector2i) -> bool:
	if is_blocked(cell):
		return false
	logs[cell] = true
	queue_redraw()
	return true


func has_log(cell: Vector2i) -> bool:
	return logs.has(cell)


func remove_log(cell: Vector2i) -> bool:
	if not logs.has(cell):
		return false
	logs.erase(cell)
	queue_redraw()
	return true


func place_plank(cell: Vector2i) -> bool:
	if is_blocked(cell):
		return false
	planks[cell] = true
	queue_redraw()
	return true


func has_plank(cell: Vector2i) -> bool:
	return planks.has(cell)


func remove_plank(cell: Vector2i) -> bool:
	if not planks.has(cell):
		return false
	planks.erase(cell)
	queue_redraw()
	return true


func place_chest(cell: Vector2i) -> Inventory:
	if is_blocked(cell):
		return null
	var inventory := Inventory.new(Inventory.DEFAULT_SLOT_COUNT)
	chests[cell] = inventory
	queue_redraw()
	return inventory


func has_chest(cell: Vector2i) -> bool:
	return chests.has(cell)


func get_chest(cell: Vector2i) -> Inventory:
	return chests.get(cell) as Inventory


func remove_chest(cell: Vector2i) -> bool:
	if not chests.has(cell):
		return false
	chests.erase(cell)
	queue_redraw()
	return true


func place_fence(cell: Vector2i) -> bool:
	if is_blocked(cell):
		return false
	fences[cell] = true
	queue_redraw()
	return true


func has_fence(cell: Vector2i) -> bool:
	return fences.has(cell)


func remove_fence(cell: Vector2i) -> bool:
	if not fences.has(cell):
		return false
	fences.erase(cell)
	queue_redraw()
	return true


func get_fence_count() -> int:
	return fences.size()


func place_nest(root: Vector2i) -> Dictionary:
	for y in NEST_SIZE:
		for x in NEST_SIZE:
			if is_blocked(root + Vector2i(x, y)):
				return {}
	var inventory := Inventory.new(4)
	var data := {
		"root": root,
		"inventory": inventory,
		"progress": 0.0,
		"active": false,
	}
	nests[root] = data
	queue_redraw()
	return data


func find_nest_root(cell: Vector2i) -> Vector2i:
	for root in nests.keys():
		var root_cell: Vector2i = root
		if (
			cell.x >= root_cell.x
			and cell.x < root_cell.x + NEST_SIZE
			and cell.y >= root_cell.y
			and cell.y < root_cell.y + NEST_SIZE
		):
			return root_cell
	return INVALID_CELL


func has_nest(root: Vector2i) -> bool:
	return nests.has(root)


func get_nest(root: Vector2i) -> Dictionary:
	return nests.get(root, {})


func remove_nest(root: Vector2i) -> bool:
	if not nests.has(root):
		return false
	nests.erase(root)
	queue_redraw()
	return true


func get_nest_progress(root: Vector2i) -> float:
	var data := get_nest(root)
	return float(data.get("progress", 0.0))


func is_nest_active(root: Vector2i) -> bool:
	var data := get_nest(root)
	return bool(data.get("active", false))


func _advance_nests(delta: float) -> void:
	for root in nests.keys():
		var data: Dictionary = nests[root]
		var inventory: Inventory = data["inventory"]
		var parent_a := inventory.get_slot(NEST_SLOT_PARENT_A)
		var parent_b := inventory.get_slot(NEST_SLOT_PARENT_B)
		var food := inventory.get_slot(NEST_SLOT_FOOD)
		var output := inventory.get_slot(NEST_SLOT_OUTPUT)
		var food_id := str(food.get("item_id", ""))
		var valid := (
			_is_parent_pig(parent_a)
			and _is_parent_pig(parent_b)
			and ItemDB.is_crop(food_id)
			and int(food.get("count", 0)) >= NEST_FOOD_REQUIRED
			and output.is_empty()
		)
		if not valid:
			data["progress"] = 0.0
			data["active"] = false
			continue

		data["active"] = true
		var progress := float(data.get("progress", 0.0)) + delta
		data["progress"] = progress
		if progress < NEST_BREED_SECONDS:
			continue

		if not inventory.remove_from_slot(NEST_SLOT_FOOD, NEST_FOOD_REQUIRED):
			data["progress"] = 0.0
			data["active"] = false
			continue
		var child := _make_child_pig(parent_a, parent_b)
		inventory.slots[NEST_SLOT_OUTPUT] = child
		inventory.changed.emit()
		data["progress"] = 0.0
		data["active"] = false
		var root_cell: Vector2i = root
		nest_changed.emit(root_cell)


func _is_parent_pig(slot: Dictionary) -> bool:
	return (
		not slot.is_empty()
		and str(slot.get("item_id", "")) == "pig"
		and slot.has("pig_rgb")
		and slot.has("pig_inventory")
	)


func _make_child_pig(parent_a: Dictionary, parent_b: Dictionary) -> Dictionary:
	var rgb_a: Vector3i = parent_a.get("pig_rgb", Vector3i(255, 170, 190))
	var rgb_b: Vector3i = parent_b.get("pig_rgb", Vector3i(255, 170, 190))
	var red := clampi(roundi((rgb_a.x + rgb_b.x) * 0.5) + randi_range(-10, 10), 0, 255)
	var green := clampi(roundi((rgb_a.y + rgb_b.y) * 0.5) + randi_range(-10, 10), 0, 255)
	var blue := clampi(roundi((rgb_a.z + rgb_b.z) * 0.5) + randi_range(-10, 10), 0, 255)
	var rgb := Vector3i(red, green, blue)
	var tint := Color(red / 255.0, green / 255.0, blue / 255.0).lerp(Color.WHITE, 0.35)
	var child_name := "猪 %d" % _next_born_pig_index
	_next_born_pig_index += 1
	return {
		"item_id": "pig",
		"count": 1,
		"pig_name": child_name,
		"pig_rgb": rgb,
		"pig_tint": tint,
		"pig_inventory": Inventory.new(Inventory.DEFAULT_SLOT_COUNT),
	}


func is_blocked(cell: Vector2i) -> bool:
	if (
		has_log(cell)
		or has_plank(cell)
		or is_tree_cell(cell)
		or has_sapling(cell)
		or has_chest(cell)
		or has_fence(cell)
	):
		return true
	for root in nests.keys():
		var root_cell: Vector2i = root
		if (
			cell.x >= root_cell.x
			and cell.x < root_cell.x + NEST_SIZE
			and cell.y >= root_cell.y
			and cell.y < root_cell.y + NEST_SIZE
		):
			return true
	return false


func _draw() -> void:
	for root in tree_roots:
		var tree_rect := Rect2(
			Vector2(root) * float(cell_size),
			Vector2.ONE * (float(cell_size) * float(TREE_SIZE))
		)
		# 树冠视觉上略微伸进相邻格子，树根仍严格占据 3 × 3 的碰撞范围。
		var visual_rect := Rect2(
			tree_rect.position - Vector2(8.0, 12.0),
			tree_rect.size + Vector2(16.0, 16.0)
		)
		if _tree_texture != null:
			draw_texture_rect(_tree_texture, visual_rect, false)

	for cell in saplings.keys():
		_draw_sapling(cell, int(saplings[cell].get("stage", 0)))

	for cell in logs.keys():
		var log_rect := Rect2(
			Vector2(cell) * float(cell_size),
			Vector2.ONE * float(cell_size)
		)
		if _log_texture != null:
			draw_texture_rect(_log_texture, log_rect, false)

	for cell in planks.keys():
		_draw_plank_block(cell)

	for cell in chests.keys():
		var chest_rect := Rect2(
			Vector2(cell) * float(cell_size),
			Vector2.ONE * float(cell_size)
		)
		if _chest_texture != null:
			draw_texture_rect(_chest_texture, chest_rect, false)

	for root in nests.keys():
		var nest_rect := Rect2(
			Vector2(root) * float(cell_size),
			Vector2.ONE * (float(cell_size) * float(NEST_SIZE))
		)
		if _nest_texture != null:
			draw_texture_rect(_nest_texture, nest_rect, false)

	for cell in fences.keys():
		_draw_fence(cell)


func _draw_plank_block(cell: Vector2i) -> void:
	# 程序化绘制，保证木板方块严格铺满 36×36 整格，没有透明边距。
	var origin := Vector2(cell) * float(cell_size)
	var size := float(cell_size)
	var board_height := size / 3.0
	var border := Color("#4A2C18")
	var colors := [
		Color("#C68C55"),
		Color("#B97A45"),
		Color("#D29A62"),
	]
	for index in 3:
		var rect := Rect2(
			origin.x,
			origin.y + board_height * float(index),
			size,
			board_height
		)
		draw_rect(rect, colors[index], true)
		draw_line(
			Vector2(rect.position.x + 1.0, rect.position.y + 1.0),
			Vector2(rect.end.x - 1.0, rect.position.y + 1.0),
			Color(0.93, 0.76, 0.52, 0.8),
			1.2
		)
		draw_line(
			Vector2(rect.position.x + 1.0, rect.end.y - 1.0),
			Vector2(rect.end.x - 1.0, rect.end.y - 1.0),
			Color(0.38, 0.23, 0.12, 0.85),
			1.2
		)
	draw_rect(Rect2(origin, Vector2.ONE * size), border, false, 1.6)
	# 木纹和钉点，让整格木板有材质感。
	draw_line(
		origin + Vector2(size * 0.2, board_height * 0.55),
		origin + Vector2(size * 0.8, board_height * 0.55),
		Color(0.55, 0.34, 0.18, 0.55),
		1.0
	)
	draw_circle(origin + Vector2(size * 0.16, board_height * 1.55), 1.2, Color("#6C4328"))
	draw_circle(origin + Vector2(size * 0.84, board_height * 1.55), 1.2, Color("#6C4328"))


func _draw_fence(cell: Vector2i) -> void:
	var origin := Vector2(cell) * float(cell_size)
	var center := origin + Vector2(float(cell_size) * 0.5, float(cell_size) * 0.5)
	var rail := Color("#C8894C")
	var rail_light := Color("#E8B97C")
	var rail_dark := Color("#8B582F")
	var border := Color("#452916")
	var post := Color("#AE713F")
	var post_light := Color("#DCA76A")

	# 地面阴影
	draw_set_transform(center + Vector2(0.0, 16.0), 0.0, Vector2(1.0, 0.28))
	draw_circle(Vector2.ZERO, 16.0, Color(0.08, 0.12, 0.05, 0.26))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	var east := _fence_connects(cell + Vector2i.RIGHT)
	var west := _fence_connects(cell + Vector2i.LEFT)
	var south := _fence_connects(cell + Vector2i.DOWN)
	var north := _fence_connects(cell + Vector2i.UP)
	var east_ext := _fence_solid_extension(cell, Vector2i.RIGHT)
	var west_ext := _fence_solid_extension(cell, Vector2i.LEFT)
	var south_ext := _fence_solid_extension(cell, Vector2i.DOWN)
	var north_ext := _fence_solid_extension(cell, Vector2i.UP)

	# 类似道路连接：只在有相邻方块的方向伸出双杆，没有邻居就只保留中心木桩。
	if west:
		for offset in [-9.0, 2.0]:
			var west_rect := Rect2(
				origin.x - west_ext,
				center.y + offset,
				center.x - origin.x + west_ext,
				6.0
			)
			_draw_fence_rail(west_rect, rail, rail_light, rail_dark, border, true)
	if east:
		for offset in [-9.0, 2.0]:
			var east_rect := Rect2(
				center.x,
				center.y + offset,
				origin.x + float(cell_size) - center.x + east_ext,
				6.0
			)
			_draw_fence_rail(east_rect, rail, rail_light, rail_dark, border, true)
	if north:
		for offset in [-9.0, 2.0]:
			var north_rect := Rect2(
				center.x + offset,
				origin.y - north_ext,
				6.0,
				center.y - origin.y + north_ext
			)
			_draw_fence_rail(north_rect, rail, rail_light, rail_dark, border, false)
	if south:
		for offset in [-9.0, 2.0]:
			var south_rect := Rect2(
				center.x + offset,
				center.y,
				6.0,
				origin.y + float(cell_size) - center.y + south_ext
			)
			_draw_fence_rail(south_rect, rail, rail_light, rail_dark, border, false)

	# 中心桩：没有邻居时就是一根独立木桩。
	var post_rect := Rect2(center.x - 5.0, origin.y + 2.0, 10.0, float(cell_size) - 4.0)
	draw_rect(post_rect, post, true)
	draw_rect(post_rect, border, false, 1.4)
	draw_line(
		Vector2(center.x - 2.6, post_rect.position.y + 2.0),
		Vector2(center.x - 2.6, post_rect.end.y - 2.0),
		post_light,
		1.3
	)
	# 桩顶与桩脚的深色包边，让它看起来是扎进地里的木桩。
	draw_rect(Rect2(post_rect.position.x - 1.5, post_rect.position.y, 13.0, 4.0), rail_dark, true)
	draw_rect(Rect2(post_rect.position.x - 1.5, post_rect.position.y, 13.0, 4.0), border, false, 1.0)
	draw_rect(Rect2(post_rect.position.x - 1.5, post_rect.end.y - 4.0, 13.0, 4.0), rail_dark, true)
	draw_rect(
		Rect2(post_rect.position.x - 1.5, post_rect.end.y - 4.0, 13.0, 4.0),
		border,
		false,
		1.0
	)


func _draw_fence_rail(
	rect: Rect2,
	rail: Color,
	rail_light: Color,
	rail_dark: Color,
	border: Color,
	horizontal: bool
) -> void:
	draw_rect(rect, rail, true)
	draw_rect(rect, border, false, 1.2)
	if horizontal:
		draw_line(
			Vector2(rect.position.x + 1.0, rect.position.y + 1.0),
			Vector2(rect.end.x - 1.0, rect.position.y + 1.0),
			rail_light,
			1.2
		)
		draw_line(
			Vector2(rect.position.x + 1.0, rect.end.y - 1.0),
			Vector2(rect.end.x - 1.0, rect.end.y - 1.0),
			rail_dark,
			1.0
		)
	else:
		draw_line(
			Vector2(rect.position.x + 1.0, rect.position.y + 1.0),
			Vector2(rect.position.x + 1.0, rect.end.y - 1.0),
			rail_light,
			1.2
		)
		draw_line(
			Vector2(rect.end.x - 1.0, rect.position.y + 1.0),
			Vector2(rect.end.x - 1.0, rect.end.y - 1.0),
			rail_dark,
			1.0
		)


func _fence_connects(cell: Vector2i) -> bool:
	return (
		has_fence(cell)
		or has_chest(cell)
		or has_log(cell)
		or has_plank(cell)
		or is_tree_cell(cell)
		or find_nest_root(cell) != INVALID_CELL
	)


## 栅栏连到方块时，木杆向对方格子多伸一点，填掉贴图边距。
func _fence_solid_extension(cell: Vector2i, direction: Vector2i) -> float:
	var neighbor := cell + direction
	if has_fence(neighbor):
		return 0.0
	if (
		has_chest(neighbor)
		or has_log(neighbor)
		or has_plank(neighbor)
		or is_tree_cell(neighbor)
		or find_nest_root(neighbor) != INVALID_CELL
	):
		return 4.0
	return 0.0


func _draw_sapling(cell: Vector2i, stage: int) -> void:
	var origin := Vector2(cell) * float(cell_size)
	var base := origin + Vector2(float(cell_size) * 0.5, float(cell_size) - 7.0)
	var height := 6.0 + float(stage) * 4.2
	var crown := base + Vector2(0.0, -height)

	draw_set_transform(base + Vector2(0.0, 2.0), 0.0, Vector2(1.0, 0.35))
	draw_circle(Vector2.ZERO, 7.0 + float(stage) * 1.8, Color(0.10, 0.16, 0.06, 0.22))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

	draw_line(base, crown, STEM, 1.8)
	for index in 2 + stage * 2:
		var angle := TAU * float(index) / float(2 + stage * 2)
		var leaf_center := crown + Vector2(cos(angle), sin(angle)) * (3.2 + float(stage) * 1.1)
		var color := LEAF_DARK if index % 2 == 0 else LEAF_MID
		draw_circle(leaf_center, 2.7 + float(stage) * 0.55, color)
	draw_circle(crown, 2.4 + float(stage) * 0.8, LEAF_LIGHT)

	if stage >= SAPLING_MATURE_STAGE:
		draw_line(crown + Vector2(-4.0, -5.0), crown + Vector2(4.0, -5.0), SAPLING_SPARKLE, 1.2)
		draw_line(crown + Vector2(0.0, -9.0), crown + Vector2(0.0, -1.0), SAPLING_SPARKLE, 1.2)

	var pip_start := origin + Vector2(float(cell_size) * 0.5 - 5.0, 5.0)
	for index in SAPLING_MATURE_STAGE:
		var filled := index < stage
		var color := Color("#D7EE9D") if filled else Color(0.26, 0.17, 0.10, 0.55)
		draw_circle(pip_start + Vector2(float(index) * 5.0, 0.0), 1.6, color)
