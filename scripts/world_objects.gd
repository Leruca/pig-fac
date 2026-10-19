class_name WorldObjects
extends Node2D
## 世界中的可交互实体：3×3 大树、石头、灌木、矿点、树苗、木头、木板、箱子、栅栏和猪窝。
##
## 三件事在本文件里完成：
## 1. **数据层**：程序生成物（树/石头/灌木/矿）由 ChunkManager 物化进来，玩家建造物
##    （木头/木板/箱子/栅栏/猪窝/树苗）由交互代码放置；两者共用同一套占地查询。
## 2. **空间索引**：树/窝/矿按 32×32 格分桶，is_blocked / find_tree_root 只查所在桶，
##    不再是 O(n) 线性扫；_draw 也按可视区域裁剪（物化几百棵树后仍然够快）。
## 3. **成对物化 API**：materialize_chunk / dematerialize_chunk，配合引用计数，
##    保证"根格在邻块、footprint 伸进本块"的树不会因为卸载邻块而消失（不穿树）。
##
## 全局态（不按块重建）：_next_born_pig_index（归 SaveManager）、_visited_blocks（归 Main）。
## 卸载只动物化对象与索引，不碰它们。计时推进（作物/树苗/繁育）不标脏。

signal tree_grew(cell: Vector2i)
signal nest_changed(root: Vector2i)
## 任何会让区块 overrides 变化的改动都会发这个信号（含跨块的树苗成熟/猪捡放）。
signal chunk_dirty(cell: Vector2i)

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

const FURNACE_SLOT_INPUT := 0
const FURNACE_SLOT_FUEL := 1
const FURNACE_SLOT_OUTPUT := 2
const FURNACE_SMELT_SECONDS := 5.0
const FURNACE_FUEL_SECONDS := {
	"wood": 20.0,
	"planks": 10.0,
	"coal": 40.0,
}
const FURNACE_SMELT_RECIPES := {
	"copper_ore": {"ingot": "copper_ingot", "seconds": 5.0},
	"iron_ore": {"ingot": "iron_ingot", "seconds": 5.0},
	"gold_ore": {"ingot": "gold_ingot", "seconds": 5.0},
}

const STEM := Color("#6F4A2B")
const LEAF_DARK := Color("#3E8436")
const LEAF_MID := Color("#61AA45")
const LEAF_LIGHT := Color("#91CF62")
const SAPLING_SPARKLE := Color("#FFE18A")

const ROCK_FILL := Color("#8C8C86")
const ROCK_LIGHT := Color("#B3B3AC")
const ROCK_DARK := Color("#5F5F5A")
const BUSH_FILL := Color("#3F7A36")
const BUSH_LIGHT := Color("#63A552")
const ORE_COLORS := {
	1: Color("#C87F4A"),
	2: Color("#9AA7B5"),
	3: Color("#E0B23C"),
	4: Color("#5E5E66"),
	5: Color("#A3A39D"),
}

## 空间索引桶大小（格）。必须 >= 最大 footprint（3），这样"格 -> 桶"最多 4 个桶。
const BUCKET_SIZE := 32
const BUCKET_SHIFT := 5

@export var cell_size: int = 36

var tree_roots: Array[Vector2i] = []
## cell -> true
var logs: Dictionary = {}
## cell -> true
var planks: Dictionary = {}
## cell -> {"stage": int, "elapsed": float, "mature_root": Vector2i, "mature_hp": int}
var saplings: Dictionary = {}
## cell -> Inventory（每个箱子独立 40 格）
var chests: Dictionary = {}
## cell -> true
var fences: Dictionary = {}
## cell -> "stone" / "stone_brick"
var placed_blocks: Dictionary = {}
## cell -> {"inventory": Inventory(3), "burn_remaining": float, "burn_total": float, "smelt_progress": float}
var furnaces: Dictionary = {}
## root -> {"inventory": Inventory(4), "progress": float, "active": bool}
var nests: Dictionary = {}
## cell -> {"ore_id": int, "amount": int, "vein_id": int}
var ores: Dictionary = {}
## cell -> {"kind": int, "hp": int, "stone": int}   程序生成的石头 / 石头矿脉 / 灌木
var natural_blocks: Dictionary = {}
## tree root -> remaining hammer hits
var _tree_hits: Dictionary = {}
var _next_born_pig_index := 4

## 已物化的区块 -> {"trees": Array, "ores": Array, "blocks": Array}
var _materialized: Dictionary = {}
## 区块 -> {树根: true}：物化时登记的树根；卸载某块只会解除它自己的引用。
var _tree_refs: Dictionary = {}
var _block_multimesh: MultiMeshInstance2D
var _ore_multimesh: MultiMeshInstance2D
var _blocks_dirty := false
var _ores_dirty := false
## 被移除/采空的程序生成物（运行时镜像；落盘时写进 overrides）。物化时据此跳过。
var _removed_trees: Dictionary = {}
var _removed_ores: Dictionary = {}

## 空间索引 --------------------------------------------------------------
## 桶坐标 -> {cell: {"kind": ..., "hp": ...}}  一格一物（含树 footprint 的每一格）
var _cell_index: Dictionary = {}
var _visible_cell_entries_cache: Dictionary = {}
## 桶坐标 -> {root: true}   树的 footprint 与桶相交
var _tree_index: Dictionary = {}
## 桶坐标 -> {root: true}   窝的 footprint 与桶相交
var _nest_index: Dictionary = {}

## 由 Main 注入：检查农田、猪等 WorldObjects 不直接了解的额外占地情况。
var mature_area_guard: Callable = Callable()
## 由 Main 注入：确定性耐久的来源（世界生成种子 + 配置）。
var worldgen_seed: int = 0
var _last_canvas_transform := Transform2D.IDENTITY
var _canvas_transform_ready := false
var worldgen_config: WorldGenConfig = null
## 由 ChunkManager 注入：把"待落盘的脏格"交给它（世界坐标）。
var dirty_sink: Callable = Callable()
## 可视裁剪用的世界矩形（由 _draw 每次更新）。
var _visible_rect := Rect2()

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
	_setup_visual_multimeshes()
	queue_redraw()


func _setup_visual_multimeshes() -> void:
	_block_multimesh = _make_multimesh_instance(Vector2(float(cell_size), float(cell_size)), -2)
	_ore_multimesh = _make_multimesh_instance(Vector2(float(cell_size) * 0.46, float(cell_size) * 0.46), -1)


func _make_multimesh_instance(quad_size: Vector2, z: int) -> MultiMeshInstance2D:
	var instance := MultiMeshInstance2D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.use_colors = true
	var quad := QuadMesh.new()
	quad.size = quad_size
	multimesh.mesh = quad
	instance.multimesh = multimesh
	instance.z_index = z
	add_child(instance)
	return instance


func _rebuild_visual_multimeshes() -> void:
	if _block_multimesh == null or _ore_multimesh == null:
		return
	var block_mm := _block_multimesh.multimesh
	block_mm.instance_count = placed_blocks.size()
	var block_index := 0
	for cell_value in placed_blocks.keys():
		var cell: Vector2i = cell_value
		var color := Color("#8F918B") if str(placed_blocks[cell]) == "stone" else Color("#9B9B94")
		block_mm.set_instance_transform_2d(
			block_index,
			Transform2D(0.0, Vector2(cell) * float(cell_size) + Vector2.ONE * (float(cell_size) * 0.5))
		)
		block_mm.set_instance_color(block_index, color)
		block_index += 1

	var ore_mm := _ore_multimesh.multimesh
	ore_mm.instance_count = ores.size()
	var ore_index := 0
	for cell_value in ores.keys():
		var cell: Vector2i = cell_value
		var ore: Dictionary = ores[cell]
		var ore_id := int(ore.get("ore_id", 0))
		var amount := int(ore.get("amount", 1))
		var scale := 0.55 + minf(0.45, float(amount) / 14000.0)
		var ore_transform := Transform2D(PI * 0.25, Vector2.ZERO)
		ore_transform = ore_transform.scaled_local(Vector2(scale, scale))
		ore_transform.origin = Vector2(cell) * float(cell_size) + Vector2.ONE * (float(cell_size) * 0.5)
		ore_mm.set_instance_transform_2d(ore_index, ore_transform)
		ore_mm.set_instance_color(ore_index, ORE_COLORS.get(ore_id, Color("#B0B0B0")))
		ore_index += 1


func _process(delta: float) -> void:
	advance_sapling_growth(delta)
	_advance_nests(delta)
	_advance_furnaces(delta)
	if _blocks_dirty or _ores_dirty:
		_blocks_dirty = false
		_ores_dirty = false
		_rebuild_visual_multimeshes()
	if not is_visible_in_tree():
		return
	# 只有镜头 transform 变化时才重提交可视对象；物品改变会由各 mutator 主动
	# queue_redraw。否则每帧遍历/重绘物品会把复杂场景的帧率压到很低。
	var canvas_transform := get_viewport().get_canvas_transform()
	if not _canvas_transform_ready or canvas_transform != _last_canvas_transform:
		_canvas_transform_ready = true
		_last_canvas_transform = canvas_transform
		queue_redraw()


# ===== 脏标记 ==========================================================

## 所有 mutator 统一走这里；ChunkManager 订阅后转成"区块待落盘"。
func mark_dirty(cell: Vector2i) -> void:
	chunk_dirty.emit(cell)
	if dirty_sink.is_valid():
		dirty_sink.call(cell)


# ===== 空间索引 ========================================================

static func bucket_of(cell: Vector2i) -> Vector2i:
	return Vector2i(cell.x >> BUCKET_SHIFT, cell.y >> BUCKET_SHIFT)


func _index_add_cell(cell: Vector2i, kind: String, hp: int = 0) -> void:
	var key := bucket_of(cell)
	if not _cell_index.has(key):
		_cell_index[key] = {}
	_cell_index[key][cell] = {"kind": kind, "hp": hp}


func _index_remove_cell(cell: Vector2i) -> void:
	var key := bucket_of(cell)
	if not _cell_index.has(key):
		return
	var bucket: Dictionary = _cell_index[key]
	bucket.erase(cell)
	if bucket.is_empty():
		_cell_index.erase(key)


func _index_add_tree(root: Vector2i, footprint: int) -> void:
	var first := bucket_of(root)
	var last := bucket_of(root + Vector2i(footprint - 1, footprint - 1))
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			var key := Vector2i(bx, by)
			if not _tree_index.has(key):
				_tree_index[key] = {}
			_tree_index[key][root] = true


func _index_remove_tree(root: Vector2i, footprint: int) -> void:
	var first := bucket_of(root)
	var last := bucket_of(root + Vector2i(footprint - 1, footprint - 1))
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			var key := Vector2i(bx, by)
			if not _tree_index.has(key):
				continue
			var bucket: Dictionary = _tree_index[key]
			bucket.erase(root)
			if bucket.is_empty():
				_tree_index.erase(key)


func _index_add_nest(root: Vector2i) -> void:
	var first := bucket_of(root)
	var last := bucket_of(root + Vector2i(NEST_SIZE - 1, NEST_SIZE - 1))
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			var key := Vector2i(bx, by)
			if not _nest_index.has(key):
				_nest_index[key] = {}
			_nest_index[key][root] = true


func _index_remove_nest(root: Vector2i) -> void:
	var first := bucket_of(root)
	var last := bucket_of(root + Vector2i(NEST_SIZE - 1, NEST_SIZE - 1))
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			var key := Vector2i(bx, by)
			if not _nest_index.has(key):
				continue
			var bucket: Dictionary = _nest_index[key]
			bucket.erase(root)
			if bucket.is_empty():
				_nest_index.erase(key)


## 清空全部索引（读档重建时用）。
func clear_indexes() -> void:
	_cell_index.clear()
	_tree_index.clear()
	_nest_index.clear()


## 从现有字典重建全部索引（读档/测试兜底）。
func rebuild_indexes() -> void:
	clear_indexes()
	for root in tree_roots:
		_index_add_tree(root, TREE_SIZE)
	for cell in logs.keys():
		_index_add_cell(cell, "log")
	for cell in planks.keys():
		_index_add_cell(cell, "plank")
	for cell in saplings.keys():
		_index_add_cell(cell, "sapling")
	for cell in chests.keys():
		_index_add_cell(cell, "chest")
	for cell in fences.keys():
		_index_add_cell(cell, "fence")
	for cell in placed_blocks.keys():
		_index_add_cell(cell, "block")
	for cell in furnaces.keys():
		_index_add_cell(cell, "furnace")
	for root in nests.keys():
		_index_add_nest(root)
	for cell in ores.keys():
		var ore: Dictionary = ores[cell]
		_index_add_cell(cell, "ore", int(ore.get("amount", 0)))
	for cell in natural_blocks.keys():
		var block: Dictionary = natural_blocks[cell]
		_index_add_cell(cell, "natural", int(block.get("hp", 0)))
	_rebuild_visual_multimeshes()
	_blocks_dirty = false
	_ores_dirty = false


# ===== 树 ==============================================================

## 添加树。hp <= 0 时用世界生成种子派生（替代 randi_range，保证重载一致）。
func add_tree(root: Vector2i, hp: int = -1) -> void:
	if tree_roots.has(root):
		return
	tree_roots.append(root)
	if hp <= 0:
		hp = _derive_tree_hp(root)
	_tree_hits[root] = hp
	_index_add_tree(root, TREE_SIZE)
	queue_redraw()


func _derive_tree_hp(root: Vector2i) -> int:
	if worldgen_config != null:
		return ObstacleLayer.tree_hp_at(worldgen_seed, worldgen_config, root)
	# 没有世界生成上下文时（纯逻辑测试）：用坐标哈希而不是 randi，保持确定性。
	var mixed := SeedSystem.hash2(0, 0, root.x, root.y)
	return 3 + int(SeedSystem.ushr(mixed, 19) % 3)


func remove_tree(root: Vector2i) -> bool:
	var index := tree_roots.find(root)
	if index < 0:
		return false
	tree_roots.remove_at(index)
	_tree_hits.erase(root)
	_index_remove_tree(root, TREE_SIZE)
	_removed_trees[root] = true
	mark_dirty(root)
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
	mark_dirty(root)
	queue_redraw()
	return {"felled": false, "remaining": remaining}


## 只查"该格所在桶"的树，O(桶内树数) 而不是 O(全部树)。
func find_tree_root(cell: Vector2i) -> Vector2i:
	var key := bucket_of(cell)
	if not _tree_index.has(key):
		return INVALID_CELL
	var bucket: Dictionary = _tree_index[key]
	for root_value in bucket.keys():
		var root: Vector2i = root_value
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


# ===== 树苗 ============================================================

func plant_sapling(cell: Vector2i, mature_root: Vector2i = INVALID_CELL, mature_hp: int = -1) -> bool:
	if is_blocked(cell):
		return false
	if mature_root == INVALID_CELL:
		mature_root = cell - SAPLING_CENTER_OFFSET
	if mature_hp <= 0:
		mature_hp = _derive_tree_hp(mature_root)
	saplings[cell] = {
		"stage": 0,
		"elapsed": 0.0,
		"mature_root": mature_root,
		"mature_hp": mature_hp,
	}
	_index_add_cell(cell, "sapling")
	mark_dirty(cell)
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
	mark_dirty(cell)
	queue_redraw()
	if int(data["stage"]) >= SAPLING_MATURE_STAGE:
		_try_mature(cell)
	return true


## 自然生长；独立成方法便于测试时快进时间。
## 计时推进**不**标脏（否则任何有作物/树苗的块每帧都脏，增量存档退化）；
## 只有阶段变化与成熟落定才标脏。
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
			mark_dirty(cell)
			queue_redraw()
		if stage >= SAPLING_MATURE_STAGE:
			_try_mature(cell)


## 树苗长成 3×3 大树。根格可能落在**相邻区块**，所以两个块都要标脏（§7.2）。
func _try_mature(cell: Vector2i) -> bool:
	if not saplings.has(cell):
		return false
	var data: Dictionary = saplings[cell]
	if int(data.get("stage", 0)) < SAPLING_MATURE_STAGE:
		return false

	var root: Vector2i = data.get("mature_root", cell - SAPLING_CENTER_OFFSET)
	var mature_hp := int(data.get("mature_hp", -1))
	for offset_y in TREE_SIZE:
		for offset_x in TREE_SIZE:
			var check_cell := root + Vector2i(offset_x, offset_y)
			if check_cell == cell:
				continue
			if is_blocked(check_cell):
				return false

	if mature_area_guard.is_valid():
		if not bool(mature_area_guard.call(root, TREE_SIZE)):
			return false

	saplings.erase(cell)
	_index_remove_cell(cell)
	add_tree(root, mature_hp)
	mark_dirty(cell)
	if root != cell:
		mark_dirty(root)
	tree_grew.emit(cell)
	return true


# ===== 建造物 ==========================================================

func place_log(cell: Vector2i) -> bool:
	if is_blocked(cell):
		return false
	logs[cell] = true
	_index_add_cell(cell, "log")
	mark_dirty(cell)
	queue_redraw()
	return true


func has_log(cell: Vector2i) -> bool:
	return logs.has(cell)


func remove_log(cell: Vector2i) -> bool:
	if not logs.has(cell):
		return false
	logs.erase(cell)
	_index_remove_cell(cell)
	mark_dirty(cell)
	queue_redraw()
	return true


func place_plank(cell: Vector2i) -> bool:
	if is_blocked(cell):
		return false
	planks[cell] = true
	_index_add_cell(cell, "plank")
	mark_dirty(cell)
	queue_redraw()
	return true


func has_plank(cell: Vector2i) -> bool:
	return planks.has(cell)


func remove_plank(cell: Vector2i) -> bool:
	if not planks.has(cell):
		return false
	planks.erase(cell)
	_index_remove_cell(cell)
	mark_dirty(cell)
	queue_redraw()
	return true


func place_chest(cell: Vector2i) -> Inventory:
	if is_blocked(cell):
		return null
	var inventory := Inventory.new(Inventory.DEFAULT_SLOT_COUNT)
	chests[cell] = inventory
	_index_add_cell(cell, "chest")
	_bind_container_dirty(cell, inventory)
	mark_dirty(cell)
	queue_redraw()
	return inventory


func has_chest(cell: Vector2i) -> bool:
	return chests.has(cell)


func get_chest(cell: Vector2i) -> Inventory:
	return chests.get(cell) as Inventory


func remove_chest(cell: Vector2i) -> bool:
	if not chests.has(cell):
		return false
	_unbind_container_dirty(cell)
	chests.erase(cell)
	_index_remove_cell(cell)
	mark_dirty(cell)
	queue_redraw()
	return true


func place_fence(cell: Vector2i) -> bool:
	if is_blocked(cell):
		return false
	fences[cell] = true
	_index_add_cell(cell, "fence")
	mark_dirty(cell)
	queue_redraw()
	return true


func has_fence(cell: Vector2i) -> bool:
	return fences.has(cell)


func remove_fence(cell: Vector2i) -> bool:
	if not fences.has(cell):
		return false
	fences.erase(cell)
	_index_remove_cell(cell)
	mark_dirty(cell)
	queue_redraw()
	return true


func get_fence_count() -> int:
	return fences.size()


# ===== 可放置整格方块 / 熔炉 =========================================

func place_placed_block(cell: Vector2i, kind: String) -> bool:
	if kind != "stone" and kind != "stone_brick":
		return false
	if is_blocked(cell):
		return false
	placed_blocks[cell] = kind
	_index_add_cell(cell, "block")
	_blocks_dirty = true
	mark_dirty(cell)
	queue_redraw()
	return true


func has_placed_block(cell: Vector2i) -> bool:
	return placed_blocks.has(cell)


func get_placed_block(cell: Vector2i) -> String:
	return str(placed_blocks.get(cell, ""))


func remove_placed_block(cell: Vector2i) -> bool:
	if not placed_blocks.has(cell):
		return false
	placed_blocks.erase(cell)
	_index_remove_cell(cell)
	_blocks_dirty = true
	mark_dirty(cell)
	queue_redraw()
	return true


func place_furnace(cell: Vector2i) -> Dictionary:
	if is_blocked(cell):
		return {}
	var inventory := Inventory.new(3)
	var data := {
		"inventory": inventory,
		"burn_remaining": 0.0,
		"burn_total": 0.0,
		"smelt_progress": 0.0,
	}
	furnaces[cell] = data
	_index_add_cell(cell, "furnace")
	_bind_container_dirty(cell, inventory)
	mark_dirty(cell)
	queue_redraw()
	return data


func has_furnace(cell: Vector2i) -> bool:
	return furnaces.has(cell)


func get_furnace(cell: Vector2i) -> Dictionary:
	return furnaces.get(cell, {})


func remove_furnace(cell: Vector2i) -> bool:
	if not furnaces.has(cell):
		return false
	_unbind_container_dirty(cell)
	furnaces.erase(cell)
	_index_remove_cell(cell)
	mark_dirty(cell)
	queue_redraw()
	return true


func _advance_furnaces(delta: float) -> void:
	for cell_value in furnaces.keys():
		var cell: Vector2i = cell_value
		var data: Dictionary = furnaces[cell]
		var inventory: Inventory = data.get("inventory")
		if inventory == null:
			continue
		var input_slot := inventory.get_slot(FURNACE_SLOT_INPUT)
		var input_id := str(input_slot.get("item_id", ""))
		var recipe: Dictionary = FURNACE_SMELT_RECIPES.get(input_id, {})
		var can_smelt := not recipe.is_empty() and int(input_slot.get("count", 0)) > 0
		if can_smelt:
			can_smelt = _furnace_output_accepts(
				inventory, str(recipe.get("ingot", "")), 1
			)

		var burn := float(data.get("burn_remaining", 0.0))
		if burn <= 0.0 and can_smelt:
			var fuel_slot := inventory.get_slot(FURNACE_SLOT_FUEL)
			var fuel_id := str(fuel_slot.get("item_id", ""))
			var fuel_seconds := float(FURNACE_FUEL_SECONDS.get(fuel_id, 0.0))
			if fuel_seconds > 0.0 and inventory.remove_from_slot(FURNACE_SLOT_FUEL, 1):
				data["burn_total"] = fuel_seconds
				burn = fuel_seconds
				mark_dirty(cell)
		if burn > 0.0:
			burn = maxf(0.0, burn - delta)
			data["burn_remaining"] = burn

		if not can_smelt:
			data["smelt_progress"] = 0.0
			continue
		var progress := float(data.get("smelt_progress", 0.0)) + delta
		var seconds := float(recipe.get("seconds", FURNACE_SMELT_SECONDS))
		if progress < seconds:
			data["smelt_progress"] = progress
			continue
		var ingot := str(recipe.get("ingot", ""))
		if not inventory.remove_from_slot(FURNACE_SLOT_INPUT, 1):
			data["smelt_progress"] = 0.0
			continue
		_add_to_slot(inventory, FURNACE_SLOT_OUTPUT, ingot, 1)
		data["smelt_progress"] = 0.0
		mark_dirty(cell)


func _furnace_output_accepts(inventory: Inventory, item_id: String, amount: int) -> bool:
	if item_id.is_empty():
		return false
	var slot := inventory.get_slot(FURNACE_SLOT_OUTPUT)
	if slot.is_empty():
		return true
	if str(slot.get("item_id", "")) != item_id:
		return false
	return int(slot.get("count", 0)) + amount <= ItemDB.get_max_stack(item_id)


func _add_to_slot(inventory: Inventory, index: int, item_id: String, amount: int) -> bool:
	if amount <= 0 or not ItemDB.has_item(item_id):
		return false
	var slot := inventory.get_slot(index)
	if slot.is_empty():
		slot = {"item_id": item_id, "count": amount}
	elif str(slot.get("item_id", "")) == item_id:
		slot["count"] = int(slot.get("count", 0)) + amount
	else:
		return false
	inventory.slots[index] = slot
	inventory.changed.emit()
	queue_redraw()
	return true


func place_nest(root: Vector2i) -> Dictionary:
	for offset_y in NEST_SIZE:
		for offset_x in NEST_SIZE:
			if is_blocked(root + Vector2i(offset_x, offset_y)):
				return {}
	var inventory := Inventory.new(4)
	var data := {
		"root": root,
		"inventory": inventory,
		"progress": 0.0,
		"active": false,
	}
	nests[root] = data
	_index_add_nest(root)
	_bind_container_dirty(root, inventory)
	mark_dirty(root)
	queue_redraw()
	return data


func find_nest_root(cell: Vector2i) -> Vector2i:
	var key := bucket_of(cell)
	if not _nest_index.has(key):
		return INVALID_CELL
	var bucket: Dictionary = _nest_index[key]
	for root_value in bucket.keys():
		var root: Vector2i = root_value
		if (
			cell.x >= root.x
			and cell.x < root.x + NEST_SIZE
			and cell.y >= root.y
			and cell.y < root.y + NEST_SIZE
		):
			return root
	return INVALID_CELL


func has_nest(root: Vector2i) -> bool:
	return nests.has(root)


func get_nest(root: Vector2i) -> Dictionary:
	return nests.get(root, {})


func remove_nest(root: Vector2i) -> bool:
	if not nests.has(root):
		return false
	_unbind_container_dirty(root)
	nests.erase(root)
	_index_remove_nest(root)
	mark_dirty(root)
	queue_redraw()
	return true


func get_nest_progress(root: Vector2i) -> float:
	var data := get_nest(root)
	return float(data.get("progress", 0.0))


func is_nest_active(root: Vector2i) -> bool:
	var data := get_nest(root)
	return bool(data.get("active", false))


## 每帧推进繁育进度：**计时不标脏**，只有产出小猪的那一刻标脏。
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
		mark_dirty(root_cell)
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


## 箱子/猪窝的内容变化也要标脏（否则只把东西放进箱子、不挖不拆，块永远是干净的）。
## 用 Callable 绑定 cell，避免每帧轮询容器内容。Inventory.changed 在内容真变时才发。
var _container_bindings: Dictionary = {}


func _bind_container_dirty(cell: Vector2i, inventory: Inventory) -> void:
	if inventory == null:
		return
	var marker: Variant = _container_bindings.get(cell)
	if marker is Inventory and is_instance_valid(marker):
		if marker == inventory:
			return
		var old_inventory: Inventory = marker
		var old_callback := Callable(self, "_on_container_changed").bind(cell)
		if old_inventory.changed.is_connected(old_callback):
			old_inventory.changed.disconnect(old_callback)
	_container_bindings[cell] = inventory
	var callback := Callable(self, "_on_container_changed").bind(cell)
	if not inventory.changed.is_connected(callback):
		inventory.changed.connect(callback, CONNECT_DEFERRED)


func _on_container_changed(cell: Vector2i) -> void:
	mark_dirty(cell)


## 拆掉箱子/猪窝时必须解绑，否则会泄漏 Inventory 与信号连接（并持续对旧格子标脏）。
func _unbind_container_dirty(cell: Vector2i) -> void:
	var marker: Variant = _container_bindings.get(cell)
	_container_bindings.erase(cell)
	if not (marker is Inventory):
		return
	var inventory: Inventory = marker
	if not is_instance_valid(inventory):
		return
	var callback := Callable(self, "_on_container_changed").bind(cell)
	if inventory.changed.is_connected(callback):
		inventory.changed.disconnect(callback)


# ===== 矿点 / 自然障碍 =================================================

func has_ore(cell: Vector2i) -> bool:
	return ores.has(cell)


func get_ore(cell: Vector2i) -> Dictionary:
	return ores.get(cell, {})


func get_ore_amount(cell: Vector2i) -> int:
	if not ores.has(cell):
		return 0
	return int(ores[cell].get("amount", 0))


## 放置矿点（物化/读档用）。
func place_ore(cell: Vector2i, ore_id: int, amount: int, vein_id: int = 0) -> void:
	if amount <= 0:
		return
	ores[cell] = {"ore_id": ore_id, "amount": amount, "vein_id": vein_id}
	_index_add_cell(cell, "ore", amount)
	_ores_dirty = true
	queue_redraw()


func remove_ore(cell: Vector2i) -> bool:
	if not ores.has(cell):
		return false
	ores.erase(cell)
	_index_remove_cell(cell)
	_removed_ores[cell] = true
	_ores_dirty = true
	mark_dirty(cell)
	queue_redraw()
	return true


## 锤一下矿：amount 递减，归零即移除。返回 {"mined": bool, "remaining": int, "ore_id": int}。
func hit_ore(cell: Vector2i, amount: int = 1) -> Dictionary:
	if not ores.has(cell):
		return {}
	var ore: Dictionary = ores[cell]
	var ore_id := int(ore.get("ore_id", 0))
	var remaining := maxi(0, int(ore.get("amount", 0)) - maxi(1, amount))
	if remaining <= 0:
		remove_ore(cell)
		return {"mined": true, "remaining": 0, "ore_id": ore_id}
	ore["amount"] = remaining
	ores[cell] = ore
	_ores_dirty = true
	mark_dirty(cell)
	queue_redraw()
	return {"mined": false, "remaining": remaining, "ore_id": ore_id}


## 矿种显示名（1 起 ore_id）。
func get_ore_name(ore_id: int) -> String:
	if worldgen_config != null:
		var entry := worldgen_config.ore_type_by_id(ore_id)
		if not entry.is_empty():
			return ore_display_name(str(entry["id"]))
	return "矿石"


func get_ore_item_id(ore_id: int) -> String:
	if worldgen_config != null:
		var entry := worldgen_config.ore_type_by_id(ore_id)
		if not entry.is_empty():
			match str(entry["id"]):
				"copper":
					return "copper_ore"
				"iron":
					return "iron_ore"
				"gold":
					return "gold_ore"
				"coal":
					return "coal"
				"stone":
					return "stone"
	return "copper_ore"


func ore_display_name(ore_name: String) -> String:
	match ore_name:
		"copper":
			return "铜矿"
		"iron":
			return "铁矿"
		"gold":
			return "金矿"
		"coal":
			return "煤矿"
		"stone":
			return "石矿"
		_:
			return ore_name


func has_natural_block(cell: Vector2i) -> bool:
	return natural_blocks.has(cell)


func get_natural_block(cell: Vector2i) -> Dictionary:
	return natural_blocks.get(cell, {})


func get_natural_hp(cell: Vector2i) -> int:
	if not natural_blocks.has(cell):
		return 0
	return int(natural_blocks[cell].get("hp", 0))


func get_natural_stone(cell: Vector2i) -> int:
	if not natural_blocks.has(cell):
		return 0
	return int(natural_blocks[cell].get("stone", 0))


func place_natural_block(cell: Vector2i, kind: int, hp: int, stone_amount: int = 0) -> void:
	natural_blocks[cell] = {"kind": kind, "hp": hp, "stone": stone_amount}
	_index_add_cell(cell, "natural", hp)
	queue_redraw()


func remove_natural_block(cell: Vector2i) -> bool:
	if not natural_blocks.has(cell):
		return false
	natural_blocks.erase(cell)
	_index_remove_cell(cell)
	mark_dirty(cell)
	queue_redraw()
	return true


## 锤石头/灌木/石头矿脉。返回 {"destroyed": bool, "remaining": int, "kind": int,
## "stone_yield": int, "stone_remaining": int}。
func hit_natural_block(cell: Vector2i) -> Dictionary:
	if not natural_blocks.has(cell):
		return {}
	var block: Dictionary = natural_blocks[cell]
	var kind := int(block.get("kind", 0))
	var remaining := maxi(0, int(block.get("hp", 0)) - 1)
	var stone_remaining := int(block.get("stone", 0))
	var stone_yield := 0
	if stone_remaining > 0:
		var hits_for_stone := maxi(1, remaining + 1)
		stone_yield = maxi(1, int(ceil(float(stone_remaining) / float(hits_for_stone))))
		stone_yield = mini(stone_yield, stone_remaining)
		stone_remaining -= stone_yield
	if remaining <= 0:
		remove_natural_block(cell)
		return {
			"destroyed": true,
			"remaining": 0,
			"kind": kind,
			"stone_yield": stone_yield,
			"stone_remaining": 0,
		}
	block["hp"] = remaining
	block["stone"] = stone_remaining
	natural_blocks[cell] = block
	if _cell_index.has(bucket_of(cell)):
		_cell_index[bucket_of(cell)][cell] = {"kind": "natural", "hp": remaining}
	mark_dirty(cell)
	queue_redraw()
	return {
		"destroyed": false,
		"remaining": remaining,
		"kind": kind,
		"stone_yield": stone_yield,
		"stone_remaining": stone_remaining,
	}


# ===== 物化 / 去物化（成对 API，§5.2）=================================

## 把一块的程序生成物物化进来。
## 树：只登记引用（footprint 跨块），实体数据已由另一块或本块 place 过。
## 矿/石头/灌木：本块数据直接落表（这些不跨块）。
func materialize_chunk(
	chunk: Vector2i,
	chunk_size: int,
	chunk_radius: int,
	trees: Array,
	ores_data: Array,
	blocks_data: Array
) -> void:
	var record := {"trees": [], "ores": [], "blocks": []}
	var origin := Vector2i(chunk.x * chunk_size - chunk_radius, chunk.y * chunk_size - chunk_radius)
	for entry in trees:
		var root: Vector2i = entry["cell"]
		if _removed_trees.has(root):
			continue
		record["trees"].append(root)
		var refs := int(_tree_refs.get(root, 0))
		if refs == 0:
			# 首次被任意区块引用：真正把树放进世界。
			add_tree(root, int(entry.get("hp", 0)))
		_tree_refs[root] = refs + 1
	for entry in ores_data:
		var cell: Vector2i = entry["cell"]
		if _removed_ores.has(cell) or ores.has(cell):
			continue
		place_ore(cell, int(entry["ore_id"]), int(entry["amount"]), int(entry.get("vein_id", 0)))
		record["ores"].append(cell)
	for entry in blocks_data:
		var cell: Vector2i = entry["cell"]
		if natural_blocks.has(cell):
			continue
		place_natural_block(
			cell,
			int(entry["kind"]),
			int(entry.get("hp", 1)),
			int(entry.get("stone_amount", 0))
		)
		record["blocks"].append(cell)
	_materialized[chunk] = record
	var _unused := origin


## 卸载一块：只移除"不再被任何加载区块引用"的对象（引用计数差集）。
func dematerialize_chunk(chunk: Vector2i) -> void:
	if not _materialized.has(chunk):
		return
	var record: Dictionary = _materialized[chunk]
	_materialized.erase(chunk)
	for root_value in record["trees"]:
		var root: Vector2i = root_value
		var refs := int(_tree_refs.get(root, 1)) - 1
		if refs <= 0:
			_tree_refs.erase(root)
			# 只清索引与表，不写 _removed_trees（这不是"被砍掉"，读档要能重建）。
			var index := tree_roots.find(root)
			if index >= 0:
				tree_roots.remove_at(index)
			_tree_hits.erase(root)
			_index_remove_tree(root, TREE_SIZE)
		else:
			_tree_refs[root] = refs
	for cell_value in record["ores"]:
		var cell: Vector2i = cell_value
		if ores.has(cell):
			ores.erase(cell)
			_index_remove_cell(cell)
	for cell_value in record["blocks"]:
		var cell: Vector2i = cell_value
		if natural_blocks.has(cell):
			natural_blocks.erase(cell)
			_index_remove_cell(cell)
	queue_redraw()


func is_chunk_materialized(chunk: Vector2i) -> bool:
	return _materialized.has(chunk)


func get_materialized_count() -> int:
	return _materialized.size()


func get_tree_reference_count() -> int:
	return _tree_refs.size()


# ===== 占地查询 ========================================================

## 世界生成的地形查询（由 ChunkManager 注入）。未生成区块视为可通过（§5.5）。
var terrain_blocker: Callable = Callable()

func is_blocked(cell: Vector2i) -> bool:
	var key := bucket_of(cell)
	var bucket: Variant = _cell_index.get(key)
	if bucket != null and bucket.has(cell):
		return true
	if not _nest_index.is_empty() and find_nest_root(cell) != INVALID_CELL:
		return true
	if not _tree_index.is_empty() and find_tree_root(cell) != INVALID_CELL:
		return true
	if terrain_blocker.is_valid() and bool(terrain_blocker.call(cell)):
		return true
	return false


# ===== 绘制 ============================================================

func _draw() -> void:
	var to_world := get_viewport().get_canvas_transform().affine_inverse()
	var viewport_size := get_viewport_rect().size
	var corners := [
		to_world * Vector2.ZERO,
		to_world * Vector2(viewport_size.x, 0.0),
		to_world * Vector2(0.0, viewport_size.y),
		to_world * viewport_size,
	]
	var min_point: Vector2 = corners[0]
	var max_point: Vector2 = corners[0]
	for corner in corners:
		min_point.x = minf(min_point.x, corner.x)
		min_point.y = minf(min_point.y, corner.y)
		max_point.x = maxf(max_point.x, corner.x)
		max_point.y = maxf(max_point.y, corner.y)
	# 树冠/树苗会伸出格子 20px，绘制裁剪框外扩一格。
	_visible_rect = Rect2(min_point, max_point - min_point).grow(float(cell_size))

	for root_value in _visible_tree_roots():
		var root: Vector2i = root_value
		if not _rect_intersects(root, TREE_SIZE):
			continue
		var tree_rect := Rect2(
			Vector2(root) * float(cell_size),
			Vector2.ONE * (float(cell_size) * float(TREE_SIZE))
		)
		# 树冠视觉上略微伸进相邻格子，树根仍严格占据 3 × 3 的碰撞范围。
		if _tree_texture != null:
			draw_texture_rect(_tree_texture, tree_rect, false)
		elif not tree_rect.intersects(_visible_rect):
			continue

	for cell_value in _visible_cell_entries():
		var cell: Vector2i = cell_value
		var entry: Dictionary = _visible_cell_entries_cache[cell]
		var kind := str(entry.get("kind", ""))
		match kind:
			"sapling":
				if saplings.has(cell):
					_draw_sapling(cell, int(saplings[cell].get("stage", 0)))
			"ore":
				pass
			"natural":
				if natural_blocks.has(cell):
					_draw_natural_block(cell, int(natural_blocks[cell].get("kind", 0)))
			"log":
				if _log_texture != null:
					draw_texture_rect(
						_log_texture,
						Rect2(Vector2(cell) * float(cell_size), Vector2.ONE * float(cell_size)),
						false
					)
			"plank":
				_draw_plank_block(cell)
			"block":
				pass
			"furnace":
				_draw_furnace(cell)
			"chest":
				if _chest_texture != null:
					draw_texture_rect(
						_chest_texture,
						Rect2(Vector2(cell) * float(cell_size), Vector2.ONE * float(cell_size)),
						false
					)
			"fence":
				_draw_fence(cell)

	for root in _visible_nest_roots():
		var nest_rect := Rect2(
			Vector2(root) * float(cell_size),
			Vector2.ONE * (float(cell_size) * float(NEST_SIZE))
		)
		if _nest_texture != null:
			draw_texture_rect(_nest_texture, nest_rect, false)


func _visible_cell_entries() -> Array[Vector2i]:
	_visible_cell_entries_cache.clear()
	if _cell_index.is_empty():
		return []
	var first := bucket_of(_world_to_cell_unclamped(_visible_rect.position)) - Vector2i.ONE
	var last := bucket_of(_world_to_cell_unclamped(_visible_rect.end)) + Vector2i.ONE
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			var bucket: Variant = _cell_index.get(Vector2i(bx, by))
			if not (bucket is Dictionary):
				continue
			for cell in bucket.keys():
				if _cell_visible(cell):
					_visible_cell_entries_cache[cell] = bucket[cell]
	return _visible_cell_entries_cache.keys()


func _visible_nest_roots() -> Array[Vector2i]:
	var roots: Array[Vector2i] = []
	if _nest_index.is_empty():
		return roots
	var first := bucket_of(_world_to_cell_unclamped(_visible_rect.position)) - Vector2i.ONE
	var last := bucket_of(_world_to_cell_unclamped(_visible_rect.end)) + Vector2i.ONE
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			var bucket: Variant = _nest_index.get(Vector2i(bx, by))
			if bucket is Dictionary:
				for root in bucket.keys():
					var root_cell: Vector2i = root
					if _rect_intersects(root_cell, NEST_SIZE):
						roots.append(root_cell)
	return roots


func _visible_tree_roots() -> Array[Vector2i]:
	var roots: Dictionary = {}
	if _tree_index.is_empty():
		return []
	var first := bucket_of(_world_to_cell_unclamped(_visible_rect.position)) - Vector2i.ONE
	var last := bucket_of(_world_to_cell_unclamped(_visible_rect.end)) + Vector2i.ONE
	for by in range(first.y, last.y + 1):
		for bx in range(first.x, last.x + 1):
			var bucket: Variant = _tree_index.get(Vector2i(bx, by))
			if bucket is Dictionary:
				for root in bucket.keys():
					roots[root] = true
	var out: Array[Vector2i] = []
	for root in roots.keys():
		var root_value: Vector2i = root
		out.append(root_value)
	return out


func _world_to_cell_unclamped(world_position: Vector2) -> Vector2i:
	return Vector2i(
		floori(world_position.x / float(cell_size)),
		floori(world_position.y / float(cell_size))
	)


func _cell_visible(cell: Vector2i) -> bool:
	return _rect_intersects(cell, 1)


func _rect_intersects(origin_cell: Vector2i, size_cells: int) -> bool:
	var rect := Rect2(
		Vector2(origin_cell) * float(cell_size),
		Vector2.ONE * (float(cell_size) * float(size_cells))
	)
	return rect.intersects(_visible_rect)


func _draw_ore(cell: Vector2i, ore_id: int, amount: int) -> void:
	var origin := Vector2(cell) * float(cell_size)
	var center := origin + Vector2.ONE * (float(cell_size) * 0.5)
	var color: Color = ORE_COLORS.get(ore_id, Color("#B0B0B0"))
	# 矿石堆：三块大小随剩余量收缩，一眼看出还能挖几次。
	var radius := 6.0 + minf(6.0, float(amount) * 1.6)
	draw_set_transform(center + Vector2(0.0, 10.0), 0.0, Vector2(1.0, 0.38))
	draw_circle(Vector2.ZERO, radius, Color(0.08, 0.10, 0.06, 0.28))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	draw_circle(center + Vector2(-4.5, 3.0), radius * 0.62, color.darkened(0.18))
	draw_circle(center + Vector2(4.0, 4.5), radius * 0.5, color.darkened(0.32))
	draw_circle(center + Vector2(0.5, -3.0), radius * 0.55, color)
	draw_circle(center + Vector2(-1.0, -4.5), radius * 0.22, color.lightened(0.45))


func _draw_natural_block(cell: Vector2i, kind: int) -> void:
	var origin := Vector2(cell) * float(cell_size)
	var center := origin + Vector2.ONE * (float(cell_size) * 0.5)
	var half_width := 36.0
	draw_set_transform(center + Vector2(0.0, 12.0), 0.0, Vector2(1.0, 0.34))
	draw_circle(Vector2.ZERO, half_width * 0.72, Color(0.08, 0.12, 0.05, 0.26))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if kind == ChunkData.KIND_BUSH:
		for index in 4:
			var angle := TAU * float(index) / 4.0 + 0.4
			draw_circle(center + Vector2(cos(angle), sin(angle)) * 5.0, 6.4, BUSH_FILL)
		draw_circle(center, 6.0, BUSH_LIGHT)
		return

	var base_y := center.y + 15.0
	var peak_y := center.y - (30.0 if kind == ChunkData.KIND_STONE else 22.0)
	var points := PackedVector2Array([
		Vector2(center.x - half_width, base_y),
		Vector2(center.x - half_width * 0.58, peak_y + 14.0),
		Vector2(center.x - half_width * 0.18, peak_y),
		Vector2(center.x + half_width * 0.23, peak_y + 8.0),
		Vector2(center.x + half_width * 0.62, peak_y + 19.0),
		Vector2(center.x + half_width, base_y),
	])
	if kind == ChunkData.KIND_STONE:
		draw_colored_polygon(points, Color("#6B7078"))
		var lit := PackedVector2Array([
			Vector2(center.x - half_width * 0.18, peak_y),
			Vector2(center.x + half_width * 0.23, peak_y + 8.0),
			Vector2(center.x + half_width * 0.10, base_y - 4.0),
			Vector2(center.x - half_width * 0.30, base_y - 8.0),
		])
		draw_colored_polygon(lit, Color("#8E959E"))
		draw_polyline(points, Color("#3C4047"), 2.2, true)
		# 石头矿脉：山体里露出的浅色石脉。
		draw_line(
			Vector2(center.x - 14.0, base_y - 6.0),
			Vector2(center.x + 12.0, peak_y + 17.0),
			Color("#D5D8D4"),
			2.4
		)
		draw_line(
			Vector2(center.x - 8.0, base_y - 9.0),
			Vector2(center.x + 2.0, peak_y + 20.0),
			Color("#B7BCC0"),
			1.6
		)
	else:
		draw_colored_polygon(points, ROCK_FILL)
		var rock_lit := PackedVector2Array([
			Vector2(center.x - half_width * 0.18, peak_y),
			Vector2(center.x + half_width * 0.23, peak_y + 8.0),
			Vector2(center.x + half_width * 0.12, base_y - 5.0),
			Vector2(center.x - half_width * 0.28, base_y - 8.0),
		])
		draw_colored_polygon(rock_lit, ROCK_LIGHT)
		draw_polyline(points, ROCK_DARK, 2.0, true)


# ===== 既有绘制工具（木板/栅栏/树苗）==================================

func _draw_placed_block(cell: Vector2i, kind: String) -> void:
	var origin := Vector2(cell) * float(cell_size)
	var size := float(cell_size)
	var fill := Color("#8F918B") if kind == "stone" else Color("#9B9B94")
	var border := Color("#4D514C") if kind == "stone" else Color("#55564F")
	draw_rect(Rect2(origin, Vector2.ONE * size), fill, true)
	draw_rect(Rect2(origin, Vector2.ONE * size), border, false, 1.4)
	if kind == "stone_brick":
		# 只保留一条砖缝方向线，避免每块 4~5 次 draw 调用。
		var y := origin.y + size * 0.5
		draw_line(Vector2(origin.x, y), Vector2(origin.x + size, y), border, 1.0)


func _draw_furnace(cell: Vector2i) -> void:
	var origin := Vector2(cell) * float(cell_size)
	var size := float(cell_size)
	draw_rect(Rect2(origin, Vector2.ONE * size), Color("#8C8E88"), true)
	draw_rect(Rect2(origin, Vector2.ONE * size), Color("#4A4C47"), false, 2.0)
	draw_rect(
		Rect2(origin + Vector2(7.0, 7.0), Vector2(size - 14.0, size - 14.0)),
		Color("#6E706A"),
		true
	)
	draw_rect(
		Rect2(origin + Vector2(10.0, 14.0), Vector2(size - 20.0, size - 22.0)),
		Color("#242522"),
		true
	)
	var data: Dictionary = furnaces.get(cell, {})
	var burning := float(data.get("burn_remaining", 0.0)) > 0.0
	if burning:
		draw_circle(
			origin + Vector2(size * 0.5, size * 0.78),
			7.0,
			Color(1.0, 0.48, 0.12, 0.82)
		)
		draw_circle(
			origin + Vector2(size * 0.5, size * 0.80),
			3.5,
			Color(1.0, 0.85, 0.35, 0.9)
		)
	draw_line(
		origin + Vector2(9.0, 10.0),
		origin + Vector2(size - 9.0, 10.0),
		Color("#D0D1C8"),
		2.0
	)


# ===== 既有绘制工具（木板/栅栏/树苗）==================================

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
		or has_ore(cell)
		or has_natural_block(cell)
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
		or has_natural_block(neighbor)
		or has_placed_block(neighbor)
		or has_furnace(neighbor)
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