extends Node2D
## 原型入口：输入、猪、农田、树木、箱子、栅栏、猪窝、寻路、合成和 UI。
##
## 每只猪都有独立的 Inventory。只有当前选中的猪会显示自己的背包；取消选择时
## 背包一起隐藏。农耕/采集互动范围是切比雪夫距离 3（7 × 7）；超出范围时猪会
## 自动寻路到范围内的可用格子，到达后继续执行原操作。树需要敲 3~5 下，
## 箱子提供 40 格独立库存，栅栏会自动连接相邻方块，猪窝负责 RGB 繁育。

const INTERACTION_RANGE := 3
const MIN_MAP_ZOOM := 0.65
const MAX_MAP_ZOOM := 1.8
const MAP_ZOOM_STEP := 1.12
const PATH_MAX_EXPANDED := 12000
const MAX_PATH_DISTANCE := 100
const DIAGONAL_COST := 1.41421356237
const TREE_ROOT := Vector2i(5, -2)
const TREE_WOOD_MIN := 8
const TREE_WOOD_MAX := 11
const TREE_SAPLING_MIN := 2
const TREE_SAPLING_MAX := 3
const BUSH_STICK_MIN := 1
const BUSH_STICK_MAX := 3
const PIG_SCENE := preload("res://scenes/pig.tscn")

const PATH_DIRECTIONS := [
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1),
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

enum BehaviorPickMode { NONE, AREA, CONTAINER, POSITION }

const INVALID_CELL := Vector2i(-999999, -999999)
const BEHAVIOR_INTERACTION_SECONDS := 1.0
const BEHAVIOR_SKIP_DELAY := 0.25
const AUDIO_FADE_CELLS := 50.0
const AUDIO_MIN_DB := -80.0
const CAMERA_PAN_THRESHOLD := 6.0
## 大地图一个格子覆盖以块中心为原点的 ±127 个细节格，即 255×255 格。
const BIG_BLOCK_SIZE := 255
const BIG_BLOCK_RADIUS := 127
## 细节地图：16×16 个展示格，每格 16m；1m = 2px，因此全屏细节图为 512×512。
const DETAIL_MAP_SIDE := 16
const DETAIL_MAP_CELL_METERS := 16
const DETAIL_MAP_METERS := 256
const DETAIL_MAP_PX_PER_METER := 2

## 世界生成：种子来自 global.json（新档未指定时随机一次后固定写入）。
var worldgen_config: WorldGenConfig
var chunk_manager: ChunkManager

@onready var grid: WorldGrid = $WorldGrid
@onready var farm: Farm = $Farm
@onready var world_objects: WorldObjects = $WorldObjects
@onready var interaction_range: InteractionRange = $InteractionRange
@onready var move_marker: MoveMarker = $MoveMarker
@onready var leaf_burst: LeafBurst = $LeafBurst
@onready var stun_burst: StunBurst = $StunBurst
@onready var behavior_area_overlay: BehaviorAreaOverlay = $BehaviorAreaOverlay
@onready var chop_sound: AudioStreamPlayer = $ChopSound
@onready var hammer_sound: AudioStreamPlayer = $HammerSound
@onready var till_sound: AudioStreamPlayer = $TillSound
@onready var plant_sound: AudioStreamPlayer = $PlantSound
@onready var water_sound: AudioStreamPlayer = $WaterSound
@onready var stun_sound: AudioStreamPlayer = $StunSound
@onready var camera: Camera2D = $Camera2D
@onready var hud: PigFacHud = $UI/HUD
@onready var pig_one: Pig = $Pig1
@onready var pig_two: Pig = $Pig2
@onready var pig_three: Pig = $Pig3
@onready var chunk_manager_node: ChunkManager = $ChunkManager

var pigs: Array[Pig] = []
var active_pig: Pig

var _last_pig_cell := Vector2i(2147483647, 2147483647)
var _map_zoom := 1.0
var _right_dragging := false
var _drag_item_id := ""
var _drag_last_cell := Vector2i(2147483647, 2147483647)
var _drag_visited: Dictionary = {}
var _path_queue: Array[Vector2i] = []
var _pending_action: Dictionary = {}

var _behavior_pick_mode := BehaviorPickMode.NONE
var _behavior_pick_module := -1
var _behavior_area_start := INVALID_CELL
var _behavior_area_end := INVALID_CELL
var _behavior_area_dragging := false

var _camera_offset := Vector2.ZERO
var _free_camera_position := Vector2.ZERO
var _camera_pan_pending := false
var _camera_pan_dragging := false
var _camera_pan_moved := false
var _camera_pan_start_screen := Vector2.ZERO
var _camera_pan_last_screen := Vector2.ZERO
var _audio_muted := false
var _fps_visible := true
var _save_manager: SaveManager
## 已探索的大地图块；键为 Vector2i 块坐标。
var _visited_blocks: Dictionary = {}


func _ready() -> void:
	# 常态上限 120；极端压力测试可用命令行/调试器临时把 Engine.max_fps 设为 0。
	Engine.max_fps = 120
	farm.cell_size = grid.cell_size
	world_objects.cell_size = grid.cell_size
	world_objects.mature_area_guard = _can_grow_tree_area
	# 农田改动要落盘：plot_changed（锄/种/铲/收）与 crop_stage_changed（浇水催熟）都是玩家操作；
	# 自然生长只发 crop_grew，不会把块标脏（§5.3 计时豁免）。
	farm.plot_changed.connect(_on_farm_plot_changed)
	farm.crop_stage_changed.connect(_on_farm_crop_stage_changed)
	world_objects.add_tree(TREE_ROOT)

	pigs = [pig_one, pig_two, pig_three]
	for pig in pigs:
		pig.set_inventory(_create_starter_inventory())
		pig.target_cell = grid.world_to_cell(pig.global_position)
		pig.set_selected(false)
		pig.arrived.connect(_on_pig_arrived.bind(pig))
		pig.inventory.selection_changed.connect(_on_held_item_changed.bind(pig))

	chop_sound.stream = load("res://assets/audio/chop.wav") as AudioStream
	hammer_sound.stream = load("res://assets/audio/hammer.wav") as AudioStream
	till_sound.stream = load("res://assets/audio/till.wav") as AudioStream
	plant_sound.stream = load("res://assets/audio/plant.wav") as AudioStream
	water_sound.stream = load("res://assets/audio/water.wav") as AudioStream
	stun_sound.stream = load("res://assets/audio/stun.wav") as AudioStream
	for player in [chop_sound, hammer_sound, till_sound, plant_sound, water_sound, stun_sound]:
		player.set_meta("base_volume_db", player.volume_db)
	_free_camera_position = camera.global_position
	hud.crafting_requested.connect(_on_crafting_button_pressed)
	hud.behavior_requested.connect(_on_behavior_button_pressed)
	hud.behavior_ui.area_pick_requested.connect(_on_behavior_area_pick_requested)
	hud.behavior_ui.container_pick_requested.connect(_on_behavior_container_pick_requested)
	hud.behavior_ui.position_pick_requested.connect(_on_behavior_position_pick_requested)
	hud.behavior_ui.program_changed.connect(_on_behavior_program_changed)
	hud.pig_selection_requested.connect(_on_minimap_pig_selected)
	hud.map_command_requested.connect(_on_map_command_requested)
	hud.esc_menu.resume_requested.connect(_close_pause_menu)
	hud.esc_menu.save_requested.connect(_on_pause_save_requested)
	hud.esc_menu.load_requested.connect(_on_pause_load_requested)
	hud.esc_menu.volume_toggle_requested.connect(_on_pause_volume_toggle_requested)
	hud.esc_menu.fps_toggle_requested.connect(_on_pause_fps_toggle_requested)
	hud.esc_menu.new_game_requested.connect(_on_new_game_requested)
	_save_manager = SaveManager.new()
	_save_manager.setup(self)
	chunk_manager = chunk_manager_node
	worldgen_config = WorldGenConfig.load_default()
	world_objects.worldgen_config = worldgen_config
	# 种子优先级：已有存档 → 环境变量 PIGFAC_SEED（工具/CI）→ 随机一次后写入存档。
	# 用 has_saved_seed() 而不是 seed_value == 0：0 是合法种子。
	var seed_value := _save_manager.stored_seed()
	if not _save_manager.has_saved_seed():
		var override := OS.get_environment("PIGFAC_SEED").strip_edges()
		if not override.is_empty():
			seed_value = SeedSystem.parse_seed(override)
		else:
			seed_value = SeedSystem.splitmix64(Time.get_unix_time_from_system() * 1000.0)
		# 先落盘 seed，避免玩家没保存就退出后换地图。
		_save_manager.persist_seed(seed_value)
	world_objects.worldgen_seed = seed_value
	chunk_manager.setup(worldgen_config, seed_value, world_objects, _pig_chunk_callable())
	chunk_manager.farm_plots = farm.plots
	world_objects.terrain_blocker = chunk_manager.is_terrain_blocked
	grid.setup(chunk_manager, worldgen_config, seed_value)
	# 教学树：hp 由世界生成种子派生（替代 randi_range），属于玩家侧固定物，不写进 overrides。
	world_objects.add_tree(TREE_ROOT)
	world_objects.rebuild_indexes()
	apply_audio_muted(false)
	hud.set_fps_visible(true)
	hud.unbind_pig()
	hud.setup_map(self)
	_mark_visible_blocks()
	hud.set_hint(_base_hint())
	interaction_range.clear_target()
	camera.zoom = Vector2.ONE
	hud.set_map_zoom(_map_zoom)

	for pig in pigs:
		print(
			"[PigFac] %s 背包：40 格 | 锄头 ×%d | 水壶 ×%d | 铲子 ×%d | 锤子 ×%d | 土豆 ×%d | 胡萝卜 ×%d"
			% [
				pig.display_name,
				pig.inventory.get_total_count("hoe"),
				pig.inventory.get_total_count("super_watering_can"),
				pig.inventory.get_total_count("shovel"),
				pig.inventory.get_total_count("hammer"),
				pig.inventory.get_total_count("potato"),
				pig.inventory.get_total_count("carrot"),
			]
		)


func _process(delta: float) -> void:
	if _right_dragging and not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_end_right_drag()
	if (_camera_pan_pending or _camera_pan_dragging) and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_camera_pan_pending = false
		_camera_pan_dragging = false
		_camera_pan_moved = false

	if active_pig != null:
		# 摄像机默认跟随当前猪；拖动空地产生偏移后仍跟随，但保留观察位置。
		camera.global_position = active_pig.global_position + _camera_offset
		_free_camera_position = camera.global_position
		var cell := grid.world_to_cell(active_pig.global_position)
		if cell != _last_pig_cell:
			# 猪跨区块移动会改变两个区块的记录 → 两边都标脏（§5.3）。
			if chunk_manager != null and _last_pig_cell != Vector2i(2147483647, 2147483647):
				var old_chunk := chunk_manager.chunk_of_cell(_last_pig_cell)
				var new_chunk := chunk_manager.chunk_of_cell(cell)
				if old_chunk != new_chunk:
					_mark_pig_chunk_dirty(_last_pig_cell)
					_mark_pig_chunk_dirty(cell)
			_last_pig_cell = cell
			hud.set_pig_cell(cell, grid.cell_size)
	else:
		camera.global_position = _free_camera_position

	_update_audio_environment()
	_mark_visible_blocks()
	_advance_behavior(delta)


func _update_audio_environment() -> void:
	for pig in pigs:
		pig.set_audio_environment(camera.global_position, _map_zoom, float(grid.cell_size))


func get_camera_center_cell() -> Vector2i:
	return grid.world_to_cell(camera.global_position)


func block_of_cell(cell: Vector2i) -> Vector2i:
	return Vector2i(
		floori((float(cell.x) + float(BIG_BLOCK_RADIUS)) / float(BIG_BLOCK_SIZE)),
		floori((float(cell.y) + float(BIG_BLOCK_RADIUS)) / float(BIG_BLOCK_SIZE))
	)


func block_center_cell(block: Vector2i) -> Vector2i:
	return block * BIG_BLOCK_SIZE


func detail_map_origin_cell(block: Vector2i) -> Vector2i:
	var half := int(DETAIL_MAP_METERS / 2)
	return block_center_cell(block) - Vector2i(half, half)


func detail_map_block() -> Vector2i:
	return current_big_block()


func current_big_block() -> Vector2i:
	return block_of_cell(get_camera_center_cell())


func is_block_visited(block: Vector2i) -> bool:
	return bool(_visited_blocks.get(block, false))


func _mark_visible_blocks() -> void:
	_visited_blocks[block_of_cell(get_camera_center_cell())] = true
	for pig in pigs:
		if pig != null:
			_visited_blocks[block_of_cell(grid.world_to_cell(pig.global_position))] = true
	if chunk_manager != null:
		# 以当前镜头位置为中心预生成 5×5 区块；ensure_radius 只在中心块变化时排队。
		# 选中猪时相机跟随猪，因此镜头位置仍是实际视野中心。
		chunk_manager.ensure_radius(grid.world_to_cell(camera.global_position))


## 相机中心格：有选中的猪时用猪的位置（相机跟随它），否则用自由相机位置。
func get_center_focus_cell() -> Vector2i:
	if active_pig != null:
		return grid.world_to_cell(active_pig.global_position)
	return grid.world_to_cell(camera.global_position)


## 猪所在区块（ChunkManager 用它保证「猪周围永远已生成」，路径规划前不逐格兜底）。
func _pig_chunk_callable() -> Callable:
	return func() -> Array:
		var chunks: Array = []
		for pig_value in pigs:
			var pig: Pig = pig_value
			if pig == null:
				continue
			chunks.append(chunk_manager.chunk_of_cell(grid.world_to_cell(pig.global_position)))
		if active_pig != null:
			chunks.append(chunk_manager.chunk_of_cell(get_center_focus_cell()))
		return chunks


## 农田地块变化 → 区块标脏（overrides.farm 需要落盘）。
func _on_farm_plot_changed(cell: Vector2i) -> void:
	_mark_pig_chunk_dirty(cell)


## 浇水催熟（玩家操作）→ 标脏；自然生长发的是 crop_grew，天然豁免。
func _on_farm_crop_stage_changed(cell: Vector2i, _crop_id: String, _stage: int) -> void:
	_mark_pig_chunk_dirty(cell)


## 猪的增删/移动会让区块记录变化 → 目标块与来源块都必须标脏。
func _mark_pig_chunk_dirty(cell: Vector2i) -> void:
	if chunk_manager == null:
		return
	chunk_manager.mark_cell_dirty(cell)


## 交互落点校验：会到达的格子必须先确保所在区块已生成（单块、有限次）。
func ensure_cell_chunk(cell: Vector2i) -> void:
	if chunk_manager != null:
		chunk_manager.ensure_chunk_now(chunk_manager.chunk_of_cell(cell))


func enter_big_block(block: Vector2i) -> void:
	if not is_block_visited(block):
		hud.set_hint("该区块尚未探索，不能直接移动镜头。")
		return
	_visited_blocks[block] = true
	var center_cell := block_center_cell(block)
	var world_center := grid.cell_to_world_center(center_cell)
	# 地图导航只移动镜头，不传送猪；传送方法保留但默认不调用。
	if active_pig != null:
		_camera_offset = world_center - active_pig.global_position
	else:
		_free_camera_position = world_center
		camera.global_position = world_center
	_camera_pan_pending = false
	_camera_pan_dragging = false
	_camera_pan_moved = false
	_mark_visible_blocks()
	hud.close_map()
	hud.set_hint("镜头进入大地图区块 (%d, %d)；猪不会被传送。" % [block.x, block.y])


## 保留的传送逻辑：当前版本不调用，避免地图导航把猪带走。
func teleport_active_pig_to_block(block: Vector2i) -> void:
	_visited_blocks[block] = true
	var center_cell := block_center_cell(block)
	var world_center := grid.cell_to_world_center(center_cell)
	if active_pig != null:
		_cancel_path_motion()
		active_pig.behavior_path.clear()
		active_pig.behavior_move_active = false
		active_pig.behavior_wait = 0.0
		active_pig.stop_moving()
		active_pig.global_position = world_center
		active_pig.target_cell = center_cell
		_camera_offset = Vector2.ZERO
		_last_pig_cell = center_cell
		interaction_range.follow(active_pig)
		hud.set_pig_cell(center_cell, grid.cell_size)
	else:
		_free_camera_position = world_center
		camera.global_position = world_center
	_mark_visible_blocks()
	hud.close_map()


func _input(event: InputEvent) -> void:
	# Esc 在 UI 获得焦点时也要可靠地关闭最上层面板，所以直接在最前层处理。
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_end_right_drag()
			_handle_escape()
			get_viewport().set_input_as_handled()


func _handle_escape() -> void:
	_camera_pan_pending = false
	_camera_pan_dragging = false
	_camera_pan_moved = false
	if hud.is_esc_menu_open():
		_close_pause_menu()
		return
	if hud.is_map_open():
		hud.close_map()
		hud.set_hint(_base_hint())
	elif _behavior_pick_mode != BehaviorPickMode.NONE:
		_cancel_behavior_pick()
	elif hud.is_chest_open():
		hud.close_chest()
		hud.set_hint(_base_hint())
	elif hud.is_nest_open():
		hud.close_nest()
		hud.set_hint(_base_hint())
	elif hud.is_furnace_open():
		hud.close_furnace()
		hud.set_hint(_base_hint())
	elif hud.is_machine_open():
		hud.close_machine()
		hud.set_hint(_base_hint())
	elif hud.is_behavior_open():
		hud.close_behavior()
		hud.set_hint(_base_hint())
	elif hud.is_crafting_open():
		hud.close_crafting()
		hud.set_hint(_base_hint())
	else:
		_open_pause_menu()


func _open_pause_menu() -> void:
	_end_right_drag()
	hud.open_esc_menu(
		_save_manager.save_path(),
		_audio_muted,
		_save_manager.has_save(),
		SeedSystem.seed_to_string(chunk_manager.get_seed()),
		_fps_visible
	)
	get_tree().paused = true


func _close_pause_menu() -> void:
	hud.close_esc_menu()
	get_tree().paused = false


func _on_pause_save_requested() -> void:
	var result := _save_manager.save_game()
	var ok := bool(result.get("ok", false))
	hud.esc_menu.set_status(str(result.get("message", "")), not ok)
	hud.esc_menu.set_has_save(_save_manager.has_save())


func _on_pause_load_requested() -> void:
	var result := _save_manager.load_game()
	var ok := bool(result.get("ok", false))
	if not ok:
		hud.esc_menu.set_status(str(result.get("message", "读取失败。")), true)
		hud.esc_menu.set_has_save(_save_manager.has_save())
		return
	get_tree().paused = false
	hud.close_esc_menu()
	hud.set_hint(str(result.get("message", "读取成功。")))


func _on_pause_volume_toggle_requested() -> void:
	apply_audio_muted(not _audio_muted)
	if hud.esc_menu != null:
		hud.esc_menu.set_muted(_audio_muted)
		hud.esc_menu.set_status("音效已%s。" % ("关闭" if _audio_muted else "开启"))


func _on_pause_fps_toggle_requested() -> void:
	apply_fps_visible(not _fps_visible)
	if hud.esc_menu != null:
		hud.esc_menu.set_fps_visible(_fps_visible)
		hud.esc_menu.set_status("FPS 监控已%s。" % ("开启" if _fps_visible else "关闭"))


func apply_fps_visible(enabled: bool) -> void:
	_fps_visible = enabled
	hud.set_fps_visible(enabled)


func is_fps_visible() -> bool:
	return _fps_visible


func _on_new_game_requested(seed_text: String) -> void:
	var seed_value := 0
	if seed_text.is_empty():
		seed_value = SeedSystem.splitmix64(Time.get_unix_time_from_system() * 1000.0)
	else:
		seed_value = SeedSystem.parse_seed(seed_text)
	_close_pause_menu()
	if not SavePaths.clear_root():
		hud.set_hint("无法清空旧存档目录，新游戏未开始。")
		return
	OS.set_environment("PIGFAC_SEED", SeedSystem.seed_to_string(seed_value))
	var reload_error := get_tree().reload_current_scene()
	if reload_error != OK:
		hud.set_hint("新游戏启动失败（错误码 %d）。" % reload_error)


func apply_audio_muted(muted: bool) -> void:
	_audio_muted = muted
	var master_index := AudioServer.get_bus_index("Master")
	if master_index >= 0:
		AudioServer.set_bus_mute(master_index, muted)


func is_audio_muted() -> bool:
	return _audio_muted


func _unhandled_input(event: InputEvent) -> void:
	if _behavior_pick_mode != BehaviorPickMode.NONE:
		if _handle_behavior_pick_input(event):
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton:
		if event.pressed and (
			event.button_index == MOUSE_BUTTON_WHEEL_UP
			or event.button_index == MOUSE_BUTTON_WHEEL_DOWN
		):
			_zoom_map(event.button_index == MOUSE_BUTTON_WHEEL_UP)
			get_viewport().set_input_as_handled()
			return

		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_end_right_drag()
				if _pig_at_world(get_global_mouse_position()) != null:
					_cancel_path_motion()
					_handle_left_click()
				else:
					_begin_camera_pan(event.position)
				get_viewport().set_input_as_handled()
			else:
				if _camera_pan_pending or _camera_pan_dragging:
					_finish_camera_pan()
					get_viewport().set_input_as_handled()
			return

		if event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_begin_right_drag()
			else:
				_end_right_drag()
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseMotion:
		if _camera_pan_pending or _camera_pan_dragging:
			_update_camera_pan(event.position)
			get_viewport().set_input_as_handled()
			return
		if _right_dragging:
			_update_right_drag()
			get_viewport().set_input_as_handled()
		return

	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_B:
			_end_right_drag()
			if active_pig == null:
				hud.set_hint("先左键选中一只猪，再打开它自己的背包。")
			else:
				hud.toggle_inventory()
				if hud.is_inventory_open():
					hud.set_hint("背包已打开：点击选择物品，或把物品拖到另一个格子或箱子里。")
				else:
					hud.set_hint(_base_hint())
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_C:
			_end_right_drag()
			if active_pig == null:
				hud.set_hint("先左键选中一只猪，再打开合成。")
			elif hud.toggle_crafting():
				if hud.is_crafting_open():
					hud.set_hint("合成已打开：使用当前猪背包里的材料。")
				else:
					hud.set_hint(_base_hint())
			get_viewport().set_input_as_handled()


func _pig_at_world(world_position: Vector2) -> Pig:
	for pig in pigs:
		if pig.contains_global_point(world_position):
			return pig
	return null


func _begin_camera_pan(screen_position: Vector2) -> void:
	_camera_pan_pending = true
	_camera_pan_dragging = false
	_camera_pan_moved = false
	_camera_pan_start_screen = screen_position
	_camera_pan_last_screen = screen_position


func _update_camera_pan(screen_position: Vector2) -> void:
	if not _camera_pan_dragging:
		if screen_position.distance_to(_camera_pan_start_screen) < CAMERA_PAN_THRESHOLD:
			_camera_pan_last_screen = screen_position
			return
		_camera_pan_dragging = true
		_camera_pan_moved = true
		_apply_camera_pan(screen_position - _camera_pan_start_screen)
		_camera_pan_last_screen = screen_position
		return
	_apply_camera_pan(screen_position - _camera_pan_last_screen)
	_camera_pan_last_screen = screen_position


func _apply_camera_pan(screen_delta: Vector2) -> void:
	var zoom := maxf(camera.zoom.x, 0.01)
	var world_delta := -screen_delta / zoom
	if active_pig != null:
		_camera_offset += world_delta
		camera.global_position = active_pig.global_position + _camera_offset
	else:
		_free_camera_position += world_delta
		camera.global_position = _free_camera_position


func _finish_camera_pan() -> void:
	var moved := _camera_pan_moved
	_camera_pan_pending = false
	_camera_pan_dragging = false
	_camera_pan_moved = false
	if moved:
		return
	_handle_left_click()


func _handle_left_click() -> void:
	var world_position := get_global_mouse_position()
	for pig in pigs:
		if pig.contains_global_point(world_position):
			if pig.is_stunned:
				hud.set_hint("%s 晕倒了，空手右键可以把它捡起来。" % pig.display_name)
				return
			_select_pig(pig)
			return

	if active_pig != null:
		_deselect_pig()
	else:
		hud.set_hint(_base_hint())


func _select_pig(pig: Pig) -> void:
	if active_pig != pig:
		_park_manual_command(active_pig)
		hud.close_chest()
		hud.close_nest()
		hud.close_furnace()
		hud.close_behavior()
		if active_pig != null:
			active_pig.set_selected(false)
		active_pig = pig
		_camera_offset = Vector2.ZERO
		pig.set_selected(true)
		interaction_range.follow(pig)
		move_marker.stop()
		_last_pig_cell = grid.world_to_cell(pig.global_position)
		hud.bind_pig(pig.display_name, pig.inventory, pig)
		hud.set_pig_cell(_last_pig_cell, grid.cell_size)
	else:
		hud.show_inventory()

	hud.set_hint(_base_hint())


func _deselect_pig() -> void:
	if active_pig == null:
		return
	_end_right_drag()
	_park_manual_command(active_pig)
	_free_camera_position = camera.global_position
	_camera_offset = Vector2.ZERO
	active_pig.set_selected(false)
	active_pig = null
	_last_pig_cell = Vector2i(2147483647, 2147483647)
	interaction_range.clear_target()
	move_marker.stop()
	hud.unbind_pig()
	hud.set_hint(_base_hint())


func _park_manual_command(pig: Pig) -> void:
	if pig == null:
		return
	if not _path_queue.is_empty():
		pig.command_path = _path_queue.duplicate()
	if not _pending_action.is_empty():
		pig.command_action = _pending_action.duplicate()
	_path_queue.clear()
	_pending_action.clear()


func _zoom_map(zoom_in: bool) -> void:
	var factor := MAP_ZOOM_STEP if zoom_in else 1.0 / MAP_ZOOM_STEP
	_map_zoom = clampf(snappedf(_map_zoom * factor, 0.01), MIN_MAP_ZOOM, MAX_MAP_ZOOM)
	camera.zoom = Vector2.ONE * _map_zoom
	hud.set_map_zoom(_map_zoom)


func _begin_right_drag() -> void:
	if active_pig == null:
		hud.set_hint("还没选中猪：先左键点击一只猪，再使用工具或移动。")
		return
	if active_pig.behavior_running:
		hud.set_hint("这只猪正在自动执行行为；先暂停自动，才能手动操作。")
		return

	_end_right_drag()
	var cell := grid.world_to_cell(get_global_mouse_position())
	var held_item := active_pig.inventory.get_held_item_id()
	var starts_on_crop := farm.has_crop(cell)

	# 猪的交互优先：锤子打晕 / 空手捡起晕猪。
	var target_pig := _find_pig_at_cell(cell)
	if target_pig != null:
		if held_item == "hammer":
			if target_pig.is_stunned:
				hud.set_hint("这只猪已经晕了，换成空手右键把它捡起来。")
			elif not _is_in_interaction_range(cell):
				_start_auto_action(cell, held_item)
			else:
				_stun_pig(target_pig)
		elif held_item.is_empty():
			if target_pig.is_stunned:
				if not _is_in_interaction_range(cell):
					_start_auto_action(cell, "", "pickup_pig")
				else:
					_pickup_pig(target_pig)
			else:
				hud.set_hint("先用锤子把这只猪打晕，才能把它捡起来。")
		else:
			hud.set_hint("手持锤子才能打晕猪；空手才能捡起晕猪。")
		return

	# 产线机器：非锤子时右键打开；拿锤子时拆掉。
	if world_objects.has_machine(cell) and held_item != "hammer":
		if not _is_in_interaction_range(cell):
			_start_auto_action(cell, "", "open_machine")
		else:
			_open_machine(cell)
		return

	# 熔炉：非锤子时右键打开；拿锤子时拆掉。
	if world_objects.has_furnace(cell) and held_item != "hammer":
		if not _is_in_interaction_range(cell):
			_start_auto_action(cell, "", "open_furnace")
		else:
			_open_furnace(cell)
		return

	# 箱子：非锤子时右键打开；拿锤子时交给下面的敲击逻辑拆掉。
	if world_objects.has_chest(cell) and held_item != "hammer":
		if not _is_in_interaction_range(cell):
			_start_auto_action(cell, "", "open_chest")
		else:
			_open_chest(cell)
		return

	# 猪窝：非锤子时右键打开；拿锤子时拆掉。
	var nest_root := world_objects.find_nest_root(cell)
	if nest_root != WorldObjects.INVALID_CELL and held_item != "hammer":
		if not _is_in_interaction_range(cell):
			_start_auto_action(cell, "", "open_nest")
		else:
			_open_nest(nest_root)
		return

	# 空手点击空地是移动；即使目标很远也直接寻路，不受互动范围限制。
	if held_item.is_empty() and not starts_on_crop:
		_move_to_cell(cell)
		return

	if not _is_in_interaction_range(cell):
		_start_auto_action(cell, held_item)
		return

	_cancel_path_motion()
	_drag_item_id = held_item
	_drag_last_cell = cell
	_drag_visited.clear()
	_drag_visited[cell] = true
	_right_dragging = true
	_apply_pointer_action(cell, false)


func _update_right_drag() -> void:
	if active_pig == null:
		_end_right_drag()
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		_end_right_drag()
		return

	var held_item := active_pig.inventory.get_held_item_id()
	if not _drag_item_id.is_empty() and held_item != _drag_item_id:
		# 种子在拖动中耗尽后停止，避免自动切换成空手继续操作。
		_end_right_drag()
		return

	var cell := grid.world_to_cell(get_global_mouse_position())
	if cell == _drag_last_cell:
		return
	_drag_last_cell = cell
	if _drag_visited.has(cell):
		return
	_drag_visited[cell] = true

	_apply_pointer_action(cell, false)

	if not _drag_item_id.is_empty() and active_pig.inventory.get_held_item_id() != _drag_item_id:
		_end_right_drag()


func _end_right_drag() -> void:
	_right_dragging = false
	_drag_item_id = ""
	_drag_last_cell = Vector2i(2147483647, 2147483647)
	_drag_visited.clear()


func _start_auto_action(cell: Vector2i, held_item: String, action_kind: String = "use") -> void:
	move_marker.play(grid.cell_to_world_center(cell))
	_cancel_path_motion()

	var start := grid.world_to_cell(active_pig.global_position)
	var path := _find_path_into_range(start, cell)
	if path.is_empty():
		hud.set_hint("目标超出互动范围，而且找不到可以靠近的空位。")
		return

	_pending_action = {
		"cell": cell,
		"held_item": held_item,
		"kind": action_kind,
	}
	_path_queue = path
	hud.set_hint("目标超出互动范围，%s正在自动靠近……" % active_pig.display_name)
	_advance_path()


func _execute_pending_action() -> void:
	if active_pig == null or _pending_action.is_empty():
		return

	var action: Dictionary = _pending_action.duplicate()
	_pending_action.clear()
	_execute_command_action_for(active_pig, action)


func _execute_command_action_for(pig: Pig, action: Dictionary) -> void:
	if pig == null or action.is_empty():
		return
	var cell: Vector2i = action.get("cell", Vector2i.ZERO)
	var action_kind := str(action.get("kind", "use"))
	if action_kind == "open_chest":
		if pig == active_pig:
			_open_chest(cell)
		return
	if action_kind == "open_nest":
		if pig == active_pig:
			var nest_root := world_objects.find_nest_root(cell)
			if nest_root != WorldObjects.INVALID_CELL:
				_open_nest(nest_root)
		return
	if action_kind == "open_furnace":
		if pig == active_pig and world_objects.has_furnace(cell):
			_open_furnace(cell)
		return
	if action_kind == "open_machine":
		if pig == active_pig and world_objects.has_machine(cell):
			_open_machine(cell)
		return
	if action_kind == "pickup_pig":
		if not pig.inventory.get_held_item_id().is_empty():
			return
		if not _is_pig_in_interaction_range(pig, cell):
			return
		var stunned_pig := _find_pig_at_cell(cell)
		if stunned_pig != null and stunned_pig.is_stunned:
			_pickup_pig(stunned_pig, pig)
		return

	var held_item := str(action.get("held_item", ""))
	if pig.inventory.get_held_item_id() != held_item:
		return
	if not _is_pig_in_interaction_range(pig, cell):
		return
	if held_item.is_empty():
		if farm.has_crop(cell):
			_harvest_crop(cell, pig)
		return
	_use_held_item(held_item, cell, pig)


func _advance_path() -> void:
	if active_pig == null:
		return
	if _path_queue.is_empty():
		if not _pending_action.is_empty():
			_execute_pending_action()
		else:
			hud.set_hint(_base_hint())
		return

	var next: Vector2i = _path_queue.pop_front()
	active_pig.move_to_cell(next, grid.cell_size)


func _cancel_path_motion() -> void:
	var had_manual_command := not _path_queue.is_empty() or not _pending_action.is_empty()
	_path_queue.clear()
	_pending_action.clear()
	if active_pig != null:
		had_manual_command = had_manual_command or not active_pig.command_path.is_empty() or not active_pig.command_action.is_empty()
		active_pig.command_path.clear()
		active_pig.command_action.clear()
	# 新手动指令会取消旧路径；取消选择/切猪则不经过这里。
	if active_pig != null and (had_manual_command or active_pig.behavior_path.is_empty()):
		active_pig.stop_moving()


func _move_to_cell(cell: Vector2i) -> void:
	if active_pig == null:
		return

	_cancel_path_motion()
	move_marker.play(grid.cell_to_world_center(cell))

	for pig in pigs:
		if pig != active_pig and grid.world_to_cell(pig.global_position) == cell:
			hud.set_hint("这个格子被另一只猪占着，请绕开它。")
			return

	if world_objects.is_blocked(cell):
		hud.set_hint("这个格子被树、树苗、木头、木板、箱子、栅栏或猪窝挡住了。")
		return

	var start := grid.world_to_cell(active_pig.global_position)
	if start == cell:
		hud.set_hint("%s 已经站在格子 (%d, %d) 上了。" % [active_pig.display_name, cell.x, cell.y])
		return

	var path := _find_path_to_cell(start, cell)
	if path.is_empty():
		hud.set_hint("找不到通往目标格子的路径。")
		return

	_path_queue = path
	_pending_action.clear()
	hud.set_hint("%s 正在前往格子 (%d, %d)…" % [active_pig.display_name, cell.x, cell.y])
	_advance_path()


func _apply_pointer_action(cell: Vector2i, allow_move: bool) -> bool:
	if active_pig == null:
		return false

	move_marker.play(grid.cell_to_world_center(cell))
	var held_item := active_pig.inventory.get_held_item_id()

	if held_item == "hammer":
		var target_pig := _find_pig_at_cell(cell)
		if target_pig != null:
			if not _is_in_interaction_range(cell):
				return false
			_stun_pig(target_pig)
			return true

	if held_item.is_empty():
		if farm.has_crop(cell):
			if not _ensure_interaction_range(cell):
				return false
			_harvest_crop(cell)
			return true
		if allow_move:
			_move_to_cell(cell)
			return true
		return false

	if not _ensure_interaction_range(cell):
		return false
	_use_held_item(held_item, cell)
	return true


func _ensure_interaction_range(cell: Vector2i) -> bool:
	if active_pig == null:
		return false
	if _is_in_interaction_range(cell):
		ensure_cell_chunk(cell)
		return true
	var distance := _cell_distance(grid.world_to_cell(active_pig.global_position), cell)
	hud.set_hint(
		"超出互动范围：目标距离 %d 格，猪最多只能操作周围 %d 格（切比雪夫距离）。"
		% [distance, INTERACTION_RANGE]
	)
	return false


func _is_in_interaction_range(cell: Vector2i) -> bool:
	return _is_pig_in_interaction_range(active_pig, cell)


func _is_pig_in_interaction_range(pig: Pig, cell: Vector2i) -> bool:
	if pig == null:
		return false
	return _cell_distance(grid.world_to_cell(pig.global_position), cell) <= INTERACTION_RANGE


func _cell_distance(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## 八方向网格上的真实移动距离：直走 1，斜走 √2。
func _octile_distance(a: Vector2i, b: Vector2i) -> float:
	var dx := absi(a.x - b.x)
	var dy := absi(a.y - b.y)
	return float(maxi(dx, dy)) + (DIAGONAL_COST - 1.0) * float(mini(dx, dy))


func _find_path_to_cell(
	start: Vector2i,
	goal: Vector2i,
	moving_pig: Pig = null,
	max_distance: int = MAX_PATH_DISTANCE
) -> Array[Vector2i]:
	if start == goal:
		return []
	if _cell_distance(start, goal) > max_distance:
		return []
	if _is_path_blocked(goal, moving_pig):
		return []
	return _search_path(start, goal, false, moving_pig)


func _find_path_into_range(start: Vector2i, target: Vector2i, moving_pig: Pig = null) -> Array[Vector2i]:
	if _cell_distance(start, target) > MAX_PATH_DISTANCE:
		return []
	return _search_path(start, target, true, moving_pig)


func _is_path_blocked(cell: Vector2i, moving_pig: Pig = null) -> bool:
	if world_objects.is_blocked(cell):
		return true
	var self_pig := moving_pig if moving_pig != null else active_pig
	for pig in pigs:
		if pig == self_pig:
			continue
		if grid.world_to_cell(pig.global_position) == cell:
			return true
	return false


## A* 寻路。使用斜向 √2 的真实代价，避免在空地上走出不必要的折线。
## stop_in_range 为 true 时，找到任意一个与目标切比雪夫距离 ≤3 的空格就停止。
## 使用二叉堆维护 open 集，并限制展开数量与目标距离，避免不可达目标卡死。
func _search_path(start: Vector2i, target: Vector2i, stop_in_range: bool, moving_pig: Pig = null) -> Array[Vector2i]:
	var open: Array[Dictionary] = [{
		"cell": start,
		"g": 0.0,
		"f": _octile_distance(start, target),
	}]
	var g_score: Dictionary = {start: 0.0}
	var came_from: Dictionary = {}
	var expanded := 0

	while not open.is_empty() and expanded < PATH_MAX_EXPANDED:
		var best: Dictionary = _heap_pop(open)
		var current: Vector2i = best.get("cell", start)
		var current_g := float(best.get("g", 0.0))
		if current_g > float(g_score.get(current, INF)) + 0.0001:
			continue
		expanded += 1

		if current != start:
			var reached := false
			if stop_in_range:
				reached = _cell_distance(current, target) <= INTERACTION_RANGE and current != target
			else:
				reached = current == target
			if reached:
				return _reconstruct_path(came_from, start, current)

		for direction_value in PATH_DIRECTIONS:
			var direction: Vector2i = direction_value
			var next_cell: Vector2i = current + direction
			if _is_path_blocked(next_cell, moving_pig):
				continue

			var diagonal: bool = direction.x != 0 and direction.y != 0
			if diagonal:
				var side_x := current + Vector2i(direction.x, 0)
				var side_y := current + Vector2i(0, direction.y)
				if _is_path_blocked(side_x, moving_pig) or _is_path_blocked(side_y, moving_pig):
					continue

			var step_cost: float = DIAGONAL_COST if diagonal else 1.0
			var tentative_g: float = current_g + step_cost
			if tentative_g >= float(g_score.get(next_cell, INF)) - 0.0001:
				continue

			g_score[next_cell] = tentative_g
			came_from[next_cell] = current
			_heap_push(open, {
				"cell": next_cell,
				"g": tentative_g,
				"f": tentative_g + _octile_distance(next_cell, target),
			})

	return []


func _heap_push(heap: Array[Dictionary], item: Dictionary) -> void:
	heap.append(item)
	var index := heap.size() - 1
	while index > 0:
		var parent := int((index - 1) * 0.5)
		if float(heap[parent].get("f", INF)) <= float(item.get("f", INF)):
			break
		heap[index] = heap[parent]
		index = parent
	heap[index] = item


func _heap_pop(heap: Array[Dictionary]) -> Dictionary:
	var root: Dictionary = heap[0]
	var last: Dictionary = heap.pop_back()
	if heap.is_empty():
		return root
	var index := 0
	var size := heap.size()
	while true:
		var left := index * 2 + 1
		if left >= size:
			break
		var right := left + 1
		var smallest := left
		if right < size and float(heap[right].get("f", INF)) < float(heap[left].get("f", INF)):
			smallest = right
		if float(heap[smallest].get("f", INF)) >= float(last.get("f", INF)):
			break
		heap[index] = heap[smallest]
		index = smallest
	heap[index] = last
	return root


func _reconstruct_path(came_from: Dictionary, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = []
	var current := goal
	while current != start:
		if not came_from.has(current):
			path.clear()
			return path
		path.push_front(current)
		current = came_from[current]
	return path


func _use_held_item(item_id: String, cell: Vector2i, actor: Pig = null) -> void:
	var user := actor if actor != null else active_pig
	if ItemDB.is_tool(item_id):
		var action := ItemDB.get_tool_action(item_id)
		match action:
			"till":
				_use_hoe(cell)
			"water":
				_use_super_watering_can(cell)
			"flatten":
				_use_shovel(cell)
			"hammer":
				_use_hammer(cell, user)
			_:
				hud.set_hint("这件工具暂时没有可用动作。")
		return

	if ItemDB.is_crop(item_id):
		_plant_crop(item_id, cell, user)
		return

	if item_id == "wood":
		_place_wood(cell)
		return

	if item_id == "planks":
		_place_plank(cell)
		return

	if item_id == "sapling":
		_plant_sapling(cell)
		return

	if item_id == "chest":
		_place_chest(cell)
		return

	if item_id == "fence":
		_place_fence(cell)
		return

	if item_id == "stone" or item_id == "stone_brick":
		_place_stone_block(item_id, cell)
		return

	if item_id == "furnace":
		_place_furnace(cell)
		return

	if ItemDB.get_kind(item_id) == "machine":
		_place_machine(cell, str(ItemDB.get_item(item_id).get("machine_type", "")))
		return

	if item_id == "pig":
		_place_pig(cell)
		return

	if item_id == "pig_nest":
		_place_pig_nest(cell)
		return

	hud.set_hint("这个物品暂时不能对地面使用。")


func _use_hoe(cell: Vector2i) -> void:
	if world_objects.is_blocked(cell):
		hud.set_hint("这里被树、树苗、木头、箱子或栅栏占着，清理后才能锄地。")
		return
	if farm.has_crop(cell):
		hud.set_hint("这个耕地里还有作物，先空手收割再锄。")
		return
	if farm.is_tilled(cell):
		hud.set_hint("这个格子已经是耕地了。")
		return
	if farm.till(cell):
		_play_sfx(till_sound, 0.9, 1.08, cell)
		hud.set_hint("锄出了耕地。换成土豆或胡萝卜种子，右键耕地即可种下。")
	else:
		hud.set_hint("这里无法锄成耕地。")


func _use_shovel(cell: Vector2i) -> void:
	if farm.has_crop(cell):
		hud.set_hint("这块耕地上还有作物，先空手收割再铲平。")
		return
	if not farm.is_tilled(cell):
		hud.set_hint("铲子只能把耕地铲平，这里本来就不是耕地。")
		return
	if farm.flatten(cell):
		hud.set_hint("铲平了耕地，这里恢复成普通草地。")


func _plant_crop(crop_id: String, cell: Vector2i, actor: Pig = null) -> void:
	var user := actor if actor != null else active_pig
	if user == null:
		return
	var crop_name := ItemDB.get_display_name(crop_id)
	if world_objects.is_blocked(cell):
		hud.set_hint("这里被树或木头占着，不能种植。")
		return
	if farm.has_crop(cell):
		hud.set_hint("这个格子里已经种了%s。" % ItemDB.get_display_name(farm.get_crop_id(cell)))
		return
	if not farm.is_tilled(cell):
		hud.set_hint("普通草地不能直接种植，需要先用锄头锄成耕地。")
		return
	if user.inventory.get_held_item_id() != crop_id:
		hud.set_hint("手持物品已经变化，请重新选择种子。")
		return

	if not user.inventory.consume_selected(1):
		hud.set_hint("手里的%s不够了。" % crop_name)
		return

	if not farm.plant(cell, crop_id):
		user.inventory.add_item(crop_id, 1)
		hud.set_hint("种植失败，%s已经退回背包。" % crop_name)
		return

	_play_sfx(plant_sound, 0.92, 1.1, cell)
	var stage_seconds := ItemDB.get_growth_stage_seconds(crop_id)
	var mature_seconds := stage_seconds * float(ItemDB.get_mature_stage(crop_id))
	hud.set_hint(
		"种下了%s。每 %.0f 秒生长一个阶段，约 %.0f 秒成熟。"
		% [crop_name, stage_seconds, mature_seconds]
	)


func _use_super_watering_can(cell: Vector2i) -> void:
	if world_objects.has_sapling(cell):
		_water_sapling(cell)
		return

	if not farm.has_crop(cell):
		if farm.is_tilled(cell):
			hud.set_hint("这块耕地上还没有作物，超级水壶只能对着作物或树苗使用。")
		else:
			hud.set_hint("超级水壶只能对着耕地作物或树苗使用。")
		return
	if farm.is_mature(cell):
		hud.set_hint("%s已经完全成熟，空手右键收割吧。" % ItemDB.get_display_name(farm.get_crop_id(cell)))
		return

	var crop_id := farm.get_crop_id(cell)
	if farm.water(cell):
		_play_sfx(water_sound, 0.94, 1.08, cell)
		var stage := farm.get_crop_stage(cell)
		var mature_stage := ItemDB.get_mature_stage(crop_id)
		if stage >= mature_stage:
			hud.set_hint("超级水壶催熟了%s！现在可以空手收割。" % ItemDB.get_display_name(crop_id))
		else:
			hud.set_hint(
				"超级水壶：%s生长到 %d/%d 阶段。"
				% [ItemDB.get_display_name(crop_id), stage, mature_stage]
			)
	else:
		hud.set_hint("这株作物已经无法继续催熟了。")


func _water_sapling(cell: Vector2i) -> void:
	var stage_before := world_objects.get_sapling_stage(cell)
	var advanced := world_objects.water_sapling(cell)
	if advanced:
		_play_sfx(water_sound, 0.94, 1.08, cell)

	if world_objects.find_tree_root(cell) != WorldObjects.INVALID_CELL:
		hud.set_hint("超级水壶催熟了树苗，长成了 3 × 3 大树！")
		return
	if advanced:
		var stage := world_objects.get_sapling_stage(cell)
		hud.set_hint(
			"超级水壶：树苗生长到 %d/%d 阶段。"
			% [stage, WorldObjects.SAPLING_MATURE_STAGE]
		)
		return
	if stage_before >= WorldObjects.SAPLING_MATURE_STAGE:
		hud.set_hint("树苗已经成熟，但周围没有足够的 3 × 3 空地长成大树。")
	else:
		hud.set_hint("树苗现在无法继续催熟。")


func _use_hammer(cell: Vector2i, actor: Pig = null) -> void:
	var user := actor if actor != null else active_pig
	if user == null:
		return
	# 矿点：锤一下采 1 单位，采空即移除（amount 归零等价 removed）。
	if world_objects.has_ore(cell):
		var ore := world_objects.get_ore(cell)
		var ore_id := int(ore.get("ore_id", 0))
		var ore_item := world_objects.get_ore_item_id(ore_id)
		if not user.inventory.can_add_item(ore_item, 1):
			hud.set_hint("背包没有空位，无法装下%s。" % ItemDB.get_display_name(ore_item))
			return
		var hit_ore := world_objects.hit_ore(cell, 1)
		var ore_name := world_objects.get_ore_name(ore_id)
		user.inventory.add_item(ore_item, 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		if bool(hit_ore.get("mined", false)):
			hud.set_hint("采空了%s，获得 1 个%s。" % [ore_name, ItemDB.get_display_name(ore_item)])
		else:
			hud.set_hint("%s 还剩 %d 单位；获得 1 个%s。" % [
				ore_name,
				int(hit_ore.get("remaining", 0)),
				ItemDB.get_display_name(ore_item),
			])
		return

	# 石头/灌木/石头矿脉：按耐久递减；石头矿脉每下会掉石头。
	if world_objects.has_natural_block(cell):
		var block := world_objects.get_natural_block(cell)
		var kind := int(block.get("kind", 0))
		var stone_remaining := int(block.get("stone", 0))
		var hits_left := maxi(1, int(block.get("hp", 1)))
		if stone_remaining > 0:
			var expected_yield := maxi(1, int(ceil(float(stone_remaining) / float(hits_left))))
			if user.inventory.get_free_capacity("stone") < expected_yield:
				hud.set_hint("背包空间不足：这一下会掉落石头 ×%d。" % expected_yield)
				return
		var bush_sticks := 0
		if kind == ChunkData.KIND_BUSH and hits_left <= 1:
			bush_sticks = randi_range(BUSH_STICK_MIN, BUSH_STICK_MAX)
			if user.inventory.get_free_capacity("stick") < bush_sticks:
				hud.set_hint("背包空间不足：敲碎灌木会掉落木棍 ×%d。" % bush_sticks)
				return
		var hit_block := world_objects.hit_natural_block(cell)
		var stone_yield := int(hit_block.get("stone_yield", 0))
		if stone_yield > 0:
			user.inventory.add_item("stone", stone_yield)
		if bush_sticks > 0:
			user.inventory.add_item("stick", bush_sticks)
		_play_sfx(hammer_sound, 0.92, 1.08, cell)
		var block_name := "石头矿脉" if kind == ChunkData.KIND_STONE else (
			"灌木" if kind == ChunkData.KIND_BUSH else "石头"
		)
		if bool(hit_block.get("destroyed", false)):
			if stone_yield > 0:
				hud.set_hint("采空了%s，获得石头 ×%d。" % [block_name, stone_yield])
			elif bush_sticks > 0:
				hud.set_hint("敲碎了%s，获得木棍 ×%d。" % [block_name, bush_sticks])
			else:
				hud.set_hint("敲碎了%s。" % block_name)
		else:
			if stone_yield > 0:
				hud.set_hint(
					"敲击%s，获得石头 ×%d；还需 %d 下。"
					% [block_name, stone_yield, int(hit_block.get("remaining", 0))]
				)
			else:
				hud.set_hint("还需要敲 %d 下。" % int(hit_block.get("remaining", 0)))
		return

	var tree_root := world_objects.find_tree_root(cell)
	if tree_root != WorldObjects.INVALID_CELL:
		var remaining := world_objects.get_tree_remaining_hits(tree_root)
		var felling := remaining <= 1
		var wood_amount := 0
		var sapling_amount := 0
		if felling:
			wood_amount = randi_range(TREE_WOOD_MIN, TREE_WOOD_MAX)
			sapling_amount = randi_range(TREE_SAPLING_MIN, TREE_SAPLING_MAX)
			var free_wood := user.inventory.get_free_capacity("wood")
			var free_saplings := user.inventory.get_free_capacity("sapling")
			if free_wood < wood_amount or free_saplings < sapling_amount:
				hud.set_hint(
					"背包空间不足：这一下会掉落木头 ×%d、树苗 ×%d。"
					% [wood_amount, sapling_amount]
				)
				return

		_play_chop_feedback(tree_root)
		var hit_result := world_objects.hit_tree(tree_root)
		if bool(hit_result.get("felled", false)):
			var wood_left := user.inventory.add_item("wood", wood_amount)
			var sapling_left := user.inventory.add_item("sapling", sapling_amount)
			if wood_left != 0 or sapling_left != 0:
				push_error("伐树掉落物未能完全进入背包")
			hud.set_hint(
				"大树倒下了！获得木头 ×%d、树苗 ×%d。"
				% [wood_amount, sapling_amount]
			)
		else:
			hud.set_hint(
				"砍树中……还需 %d 下。"
				% int(hit_result.get("remaining", 0))
			)
		return

	if world_objects.has_sapling(cell):
		hud.set_hint("这株树苗还没长成大树，可以用超级水壶催熟。")
		return

	if world_objects.has_log(cell):
		if user.inventory.get_free_capacity("wood") < 1:
			hud.set_hint("背包空间不足，先把木头收回来需要 1 个空位。")
			return
		world_objects.remove_log(cell)
		user.inventory.add_item("wood", 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		hud.set_hint("拆掉了地上的木头，收回木头 ×1。")
		return

	if world_objects.has_plank(cell):
		if user.inventory.get_free_capacity("planks") < 1:
			hud.set_hint("背包空间不足，拆木板需要 1 个空位。")
			return
		world_objects.remove_plank(cell)
		user.inventory.add_item("planks", 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		hud.set_hint("拆掉了一格木板，收回木板 ×1。")
		return

	if world_objects.has_fence(cell):
		if user.inventory.get_free_capacity("fence") < 1:
			hud.set_hint("背包空间不足，拆栅栏需要 1 个空位。")
			return
		world_objects.remove_fence(cell)
		user.inventory.add_item("fence", 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		hud.set_hint("拆掉了木栅栏，收回木栅栏 ×1。")
		return

	if world_objects.has_placed_block(cell):
		var block_kind := world_objects.get_placed_block(cell)
		if user.inventory.get_free_capacity(block_kind) < 1:
			hud.set_hint("背包空间不足，拆方块需要 1 个空位。")
			return
		world_objects.remove_placed_block(cell)
		user.inventory.add_item(block_kind, 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		hud.set_hint("拆掉了一格%s，收回 ×1。" % ItemDB.get_display_name(block_kind))
		return

	if world_objects.has_machine(cell):
		var machine := world_objects.get_machine(cell)
		var machine_type := str(machine.get("type", ""))
		var machine_item := machine_type
		if not (machine.get("pig", {}) as Dictionary).is_empty():
			hud.set_hint("机器里还有猪，先取出来再拆。")
			return
		if not (machine.get("output", {}) as Dictionary).is_empty():
			hud.set_hint("机器里还有产物，先取出来再拆。")
			return
		if user.inventory.get_free_capacity(machine_item) < 1:
			hud.set_hint("背包空间不足，拆机器需要 1 个空位。")
			return
		world_objects.remove_machine(cell)
		if user == active_pig:
			hud.close_machine()
		user.inventory.add_item(machine_item, 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		hud.set_hint("拆掉了%s，收回 ×1。" % WorldObjects.MACHINE_TYPES.get(machine_type, "机器"))
		return

	if world_objects.has_furnace(cell):
		var furnace := world_objects.get_furnace(cell)
		var furnace_inventory: Inventory = furnace.get("inventory")
		if furnace_inventory != null and not furnace_inventory.is_empty():
			hud.set_hint("熔炉里还有矿石、燃料或产物，先清空再拆。")
			return
		if user.inventory.get_free_capacity("furnace") < 1:
			hud.set_hint("背包空间不足，拆熔炉需要 1 个空位。")
			return
		world_objects.remove_furnace(cell)
		if user == active_pig:
			hud.close_furnace()
		user.inventory.add_item("furnace", 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		hud.set_hint("拆掉了熔炉，收回熔炉 ×1。")
		return

	if world_objects.has_chest(cell):
		var chest_inventory := world_objects.get_chest(cell)
		if chest_inventory != null and not chest_inventory.is_empty():
			hud.set_hint("箱子里还有物品，先把东西清空再拆。")
			return
		if user.inventory.get_free_capacity("chest") < 1:
			hud.set_hint("背包空间不足，拆箱子需要 1 个空位。")
			return
		world_objects.remove_chest(cell)
		if user == active_pig:
			hud.close_chest()
		user.inventory.add_item("chest", 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		hud.set_hint("拆掉了空箱子，收回箱子 ×1。")
		return

	var nest_root := world_objects.find_nest_root(cell)
	if nest_root != WorldObjects.INVALID_CELL:
		var nest := world_objects.get_nest(nest_root)
		var nest_inventory: Inventory = nest.get("inventory")
		if nest_inventory != null and not nest_inventory.is_empty():
			hud.set_hint("猪窝里还有猪或食物，先清空再拆。")
			return
		if user.inventory.get_free_capacity("pig_nest") < 1:
			hud.set_hint("背包空间不足，拆猪窝需要 1 个空位。")
			return
		world_objects.remove_nest(nest_root)
		if user == active_pig:
			hud.close_nest()
		user.inventory.add_item("pig_nest", 1)
		_play_sfx(hammer_sound, 0.94, 1.06, cell)
		hud.set_hint("拆掉了空猪窝，收回猪窝 ×1。")
		return

	hud.set_hint("锤子可以拆树、木头、木板、栅栏、石方块、石砖方块、空熔炉、空箱子和空猪窝。")


func _play_chop_feedback(tree_root: Vector2i) -> void:
	var canopy := (
		Vector2(tree_root) * float(grid.cell_size)
		+ Vector2(float(grid.cell_size) * 1.5, float(grid.cell_size) * 1.15)
	)
	leaf_burst.burst(canopy)
	_play_sfx(chop_sound, 0.9, 1.12, tree_root)


func _place_wood(cell: Vector2i) -> void:
	if farm.is_tilled(cell):
		hud.set_hint("木头不能放在耕地上，先用铲子把耕地铲平。")
		return
	if world_objects.is_blocked(cell):
		hud.set_hint("这个格子已经被树、树苗、木头、木板、箱子、栅栏或猪窝占用了。")
		return
	for pig in pigs:
		if grid.world_to_cell(pig.global_position) == cell:
			hud.set_hint("不能把木头放在猪脚下的格子里。")
			return

	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的木头不够了。")
		return
	if not world_objects.place_log(cell):
		active_pig.inventory.add_item("wood", 1)
		hud.set_hint("木头没能放下，已退回背包。")
		return

	hud.set_hint("把木头放在了格子 (%d, %d)，现在它是一格障碍物。" % [cell.x, cell.y])


func _plant_sapling(cell: Vector2i) -> void:
	if farm.is_tilled(cell):
		hud.set_hint("树苗只能种在平地上，不能种在耕地里。")
		return
	if world_objects.is_blocked(cell):
		hud.set_hint("这个格子被树、树苗、木头、箱子或栅栏占用了。")
		return
	for pig in pigs:
		if grid.world_to_cell(pig.global_position) == cell:
			hud.set_hint("不能把树苗种在猪脚下的格子里。")
			return
	if active_pig.inventory.get_held_item_id() != "sapling":
		hud.set_hint("手持物品已经变化，请重新选择树苗。")
		return

	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的树苗不够了。")
		return
	if not world_objects.plant_sapling(cell):
		active_pig.inventory.add_item("sapling", 1)
		hud.set_hint("树苗没能种下，已退回背包。")
		return

	_play_sfx(plant_sound, 0.92, 1.1, cell)
	hud.set_hint("种下了树苗。每 30 秒生长一个阶段，约 90 秒长成 3 × 3 大树。")


func _place_chest(cell: Vector2i) -> void:
	if farm.is_tilled(cell):
		hud.set_hint("箱子不能放在耕地上。")
		return
	if world_objects.is_blocked(cell):
		hud.set_hint("这个格子已经被树、树苗、木头、木板、箱子、栅栏或猪窝占用了。")
		return
	for pig in pigs:
		if grid.world_to_cell(pig.global_position) == cell:
			hud.set_hint("不能把箱子放在猪脚下的格子里。")
			return
	if active_pig.inventory.get_held_item_id() != "chest":
		hud.set_hint("手持物品已经变化，请重新选择箱子。")
		return

	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的箱子不够了。")
		return
	var chest_inventory := world_objects.place_chest(cell)
	if chest_inventory == null:
		active_pig.inventory.add_item("chest", 1)
		hud.set_hint("箱子没能放下，已退回背包。")
		return

	hud.set_hint("放下了箱子 (%d, %d)。右键箱子打开，它也有 40 格空间。" % [cell.x, cell.y])


func _place_fence(cell: Vector2i) -> void:
	if farm.is_tilled(cell):
		hud.set_hint("木栅栏只能放在平地上，不能放在耕地里。")
		return
	if world_objects.is_blocked(cell):
		hud.set_hint("这个格子已经被树、树苗、木头、木板、箱子、栅栏或猪窝占用了。")
		return
	for pig in pigs:
		if grid.world_to_cell(pig.global_position) == cell:
			hud.set_hint("不能把栅栏放在猪脚下的格子里。")
			return
	if active_pig.inventory.get_held_item_id() != "fence":
		hud.set_hint("手持物品已经变化，请重新选择木栅栏。")
		return

	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的木栅栏不够了。")
		return
	if not world_objects.place_fence(cell):
		active_pig.inventory.add_item("fence", 1)
		hud.set_hint("木栅栏没能放下，已退回背包。")
		return

	hud.set_hint("放下了木栅栏，相邻的栅栏和方块会自动连接。")


func _place_stone_block(item_id: String, cell: Vector2i) -> void:
	if farm.is_tilled(cell):
		hud.set_hint("石头方块只能放在平地上，不能放在耕地里。")
		return
	if world_objects.is_blocked(cell):
		hud.set_hint("这个格子已经被其他方块或自然物占用了。")
		return
	for pig in pigs:
		if grid.world_to_cell(pig.global_position) == cell:
			hud.set_hint("不能把方块放在猪脚下的格子里。")
			return
	if active_pig.inventory.get_held_item_id() != item_id:
		hud.set_hint("手持物品已经变化，请重新选择方块。")
		return
	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的方块不够了。")
		return
	if not world_objects.place_placed_block(cell, item_id):
		active_pig.inventory.add_item(item_id, 1)
		hud.set_hint("方块没能放下，已退回背包。")
		return
	hud.set_hint("放下了%s，它占满一整格并阻挡移动。" % ItemDB.get_display_name(item_id))


func _place_furnace(cell: Vector2i) -> void:
	for y in WorldObjects.FURNACE_SIZE:
		for x in WorldObjects.FURNACE_SIZE:
			var footprint_cell := cell + Vector2i(x, y)
			if farm.is_tilled(footprint_cell):
				hud.set_hint("熔炉是 2×2，不能放在耕地上。")
				return
			if world_objects.is_blocked(footprint_cell):
				hud.set_hint("熔炉是 2×2，这个范围内已经有其他方块或自然物。")
				return
			for pig in pigs:
				if grid.world_to_cell(pig.global_position) == footprint_cell:
					hud.set_hint("熔炉是 2×2，不能压在猪脚下。")
					return
	if active_pig.inventory.get_held_item_id() != "furnace":
		hud.set_hint("手持物品已经变化，请重新选择熔炉。")
		return
	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的熔炉不够了。")
		return
	if world_objects.place_furnace(cell).is_empty():
		active_pig.inventory.add_item("furnace", 1)
		hud.set_hint("熔炉没能放下，已退回背包。")
		return
	hud.set_hint("放下了 2×2 熔炉，以鼠标格为左上角。右键打开，放入矿石和燃料即可熔炼。")


func _place_machine(cell: Vector2i, machine_type: String) -> void:
	if not WorldObjects.MACHINE_TYPES.has(machine_type):
		hud.set_hint("这台机器类型无法放置。")
		return
	var machine_size := int(WorldObjects.MACHINE_SIZES.get(machine_type, 1))
	var machine_root := WorldObjects.machine_root_for_anchor(cell, machine_size)
	for y in machine_size:
		for x in machine_size:
			var footprint_cell := machine_root + Vector2i(x, y)
			if farm.is_tilled(footprint_cell):
				hud.set_hint("机器是 %d×%d，不能放在耕地上。" % [machine_size, machine_size])
				return
			if world_objects.is_blocked(footprint_cell):
				hud.set_hint("机器是 %d×%d，这个范围内已经有其他方块或自然物。" % [machine_size, machine_size])
				return
			for pig in pigs:
				if grid.world_to_cell(pig.global_position) == footprint_cell:
					hud.set_hint("机器是 %d×%d，不能压在猪脚下。" % [machine_size, machine_size])
					return
	var held_id := active_pig.inventory.get_held_item_id()
	if held_id.is_empty() or ItemDB.get_kind(held_id) != "machine":
		hud.set_hint("手持物品已经变化，请重新选择机器。")
		return
	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的机器不够了。")
		return
	if world_objects.place_machine(cell, machine_type).is_empty():
		active_pig.inventory.add_item(held_id, 1)
		hud.set_hint("机器没能放下，已退回背包。")
		return
	var anchor_hint := "以鼠标格为中心" if machine_size >= 3 else "以鼠标格为左上角"
	hud.set_hint("放下了 %d×%d %s，%s。右键打开，锤子可拆回。" % [
		machine_size, machine_size, WorldObjects.MACHINE_TYPES[machine_type], anchor_hint
	])


func _place_plank(cell: Vector2i) -> void:
	if farm.is_tilled(cell):
		hud.set_hint("木板不能放在耕地上，先用铲子把耕地铲平。")
		return
	if world_objects.is_blocked(cell):
		hud.set_hint("这个格子已经被树、树苗、木头、木板、箱子、栅栏或猪窝占用了。")
		return
	for pig in pigs:
		if grid.world_to_cell(pig.global_position) == cell:
			hud.set_hint("不能把木板放在猪脚下的格子里。")
			return
	if active_pig.inventory.get_held_item_id() != "planks":
		hud.set_hint("手持物品已经变化，请重新选择木板。")
		return

	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的木板不够了。")
		return
	if not world_objects.place_plank(cell):
		active_pig.inventory.add_item("planks", 1)
		hud.set_hint("木板没能放下，已退回背包。")
		return

	hud.set_hint("把木板放在了格子 (%d, %d)，它占满一格并阻挡移动。" % [cell.x, cell.y])


func _place_pig_nest(cell: Vector2i) -> void:
	# 鼠标选中的格子是猪窝中心，3×3 的 root 向左上偏移一格。
	var half := int(WorldObjects.NEST_SIZE / 2)
	var root := cell - Vector2i(half, half)
	for y in WorldObjects.NEST_SIZE:
		for x in WorldObjects.NEST_SIZE:
			var check_cell := root + Vector2i(x, y)
			if farm.is_tilled(check_cell):
				hud.set_hint("猪窝占地 3×3，不能压在耕地上。")
				return
			if world_objects.is_blocked(check_cell):
				hud.set_hint("猪窝占地 3×3，这片区域里有其他方块挡着。")
				return
			for pig in pigs:
				if grid.world_to_cell(pig.global_position) == check_cell:
					hud.set_hint("猪窝占地 3×3，不能压在猪身上。")
					return
	if active_pig.inventory.get_held_item_id() != "pig_nest":
		hud.set_hint("手持物品已经变化，请重新选择猪窝。")
		return

	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("手里的猪窝不够了。")
		return
	if world_objects.place_nest(root).is_empty():
		active_pig.inventory.add_item("pig_nest", 1)
		hud.set_hint("猪窝没能放下，已退回背包。")
		return

	hud.set_hint(
		"放下了 3×3 猪窝，中心在 (%d, %d)。右键打开，放入两只猪和食物。"
		% [cell.x, cell.y]
	)


## 给 WorldObjects 的额外占地检查：大树不能长到耕地或猪脚下。
func _can_grow_tree_area(root: Vector2i, size: int) -> bool:
	for y in size:
		for x in size:
			var cell := root + Vector2i(x, y)
			if farm.is_tilled(cell):
				return false
			for pig in pigs:
				if grid.world_to_cell(pig.global_position) == cell:
					return false
	return true


func _open_chest(cell: Vector2i) -> void:
	var chest_inventory := world_objects.get_chest(cell)
	if chest_inventory == null:
		hud.set_hint("这个箱子已经不存在了。")
		return
	hud.open_chest(chest_inventory, "(%d, %d)" % [cell.x, cell.y])
	hud.set_hint("箱子已打开：可以在箱子和猪的背包之间拖动整理物品。按 Esc 关闭。")


func _open_furnace(cell: Vector2i) -> void:
	var furnace := world_objects.get_furnace(cell)
	if furnace.is_empty():
		hud.set_hint("这个熔炉已经不存在了。")
		return
	hud.open_furnace(furnace, "(%d, %d)" % [cell.x, cell.y])
	hud.set_hint("熔炉已打开：输入矿石，放入木头/木板/煤炭作燃料，产物会进入输出槽。按 Esc 关闭。")


func _open_machine(cell: Vector2i) -> void:
	var root := world_objects.get_machine_root(cell)
	if root == WorldObjects.INVALID_CELL:
		hud.set_hint("这台机器已经不存在了。")
		return
	var machine := world_objects.get_machine(root)
	if machine.is_empty():
		hud.set_hint("这台机器已经不存在了。")
		return
	hud.open_machine(world_objects, machine, root, "(%d, %d)" % [root.x, root.y])
	hud.set_hint("机器已打开：按面板提示放入猪或材料，按 Esc 关闭。")


func _open_nest(root: Vector2i) -> void:
	var nest := world_objects.get_nest(root)
	if nest.is_empty():
		hud.set_hint("这个猪窝已经不存在了。")
		return
	var half := int(WorldObjects.NEST_SIZE / 2)
	var center := root + Vector2i(half, half)
	hud.open_nest(nest, "(%d, %d)" % [center.x, center.y])
	hud.set_hint("猪窝已打开：拖入两只猪和至少 10 个食物，等待 10 秒产出新生猪。")


func _find_pig_at_cell(cell: Vector2i) -> Pig:
	for pig in pigs:
		if pig == active_pig:
			continue
		if grid.world_to_cell(pig.global_position) == cell:
			return pig
	return null


func _stun_pig(pig: Pig) -> void:
	if pig == null or pig == active_pig:
		return
	if pig.is_stunned:
		hud.set_hint("%s 已经晕了，换成空手右键把它捡起来。" % pig.display_name)
		return
	pig.stun()
	pig.behavior_path.clear()
	pig.behavior_move_active = false
	pig.behavior_wait = 0.0
	pig.command_path.clear()
	pig.command_action.clear()
	stun_burst.burst(pig.global_position)
	_play_sfx(stun_sound, 0.92, 1.08, grid.world_to_cell(pig.global_position))
	hud.set_hint("锤晕了 %s！空手右键可以把它捡进背包。" % pig.display_name)


func _pickup_pig(pig: Pig, actor: Pig = null) -> void:
	if pig == null or pig == active_pig:
		return
	var user := actor if actor != null else active_pig
	if user == null:
		return
	if not pig.is_stunned:
		hud.set_hint("先用锤子把这只猪打晕，才能捡起来。")
		return
	if not user.inventory.get_held_item_id().is_empty():
		hud.set_hint("把手里的东西放下，空手才能捡猪。")
		return

	var stack := {
		"item_id": "pig",
		"count": 1,
		"pig_name": pig.display_name,
		"pig_rgb": pig.pig_rgb,
		"pig_tint": pig.body_tint,
		"pig_inventory": pig.inventory,
	}
	if not user.inventory.add_item_stack(stack):
		hud.set_hint("背包没有空位，无法把猪装进去。")
		return

	_mark_pig_chunk_dirty(grid.world_to_cell(pig.global_position))
	pigs.erase(pig)
	pig.stop_moving()
	_disconnect_pig_inventory(pig)
	pig.get_parent().remove_child(pig)
	pig.queue_free()
	hud.set_hint(
		"把 %s 装进了背包，它原来的背包内容也一起保留了。放到地面会醒来。"
		% pig.display_name
	)


func _place_pig(cell: Vector2i) -> void:
	if farm.is_tilled(cell):
		hud.set_hint("猪不能放在耕地上。")
		return
	if world_objects.is_blocked(cell):
		hud.set_hint("这个格子被树、树苗、木头、木板、箱子、栅栏或猪窝挡住了。")
		return
	for pig in pigs:
		if grid.world_to_cell(pig.global_position) == cell:
			hud.set_hint("这个格子里已经有一只猪了。")
			return

	var slot := active_pig.inventory.get_selected_slot()
	if str(slot.get("item_id", "")) != "pig":
		hud.set_hint("手持物品已经变化，请重新选择猪。")
		return
	var metadata := slot.duplicate()
	if not active_pig.inventory.consume_selected(1):
		hud.set_hint("背包里的猪不见了。")
		return

	var new_pig: Pig = PIG_SCENE.instantiate()
	new_pig.display_name = str(metadata.get("pig_name", "猪"))
	new_pig.pig_rgb = metadata.get("pig_rgb", Vector3i(255, 170, 190))
	new_pig.body_tint = metadata.get("pig_tint", Color.WHITE)
	new_pig.position = grid.cell_to_world_center(cell)
	new_pig.target_cell = cell
	new_pig.z_index = 2
	add_child(new_pig)
	var stored_inventory: Variant = metadata.get("pig_inventory")
	var pig_inventory: Inventory = (
		stored_inventory if stored_inventory is Inventory else Inventory.new(Inventory.DEFAULT_SLOT_COUNT)
	)
	new_pig.set_inventory(pig_inventory)
	new_pig.set_selected(false)
	pigs.append(new_pig)
	_register_pig(new_pig)
	_mark_pig_chunk_dirty(cell)
	hud.set_hint(
		"把 %s 放到了地上，它已经醒来，背包里的 %d 格物品也还在。"
		% [new_pig.display_name, pig_inventory.get_used_slot_count()]
	)


func _register_pig(pig: Pig) -> void:
	pig.arrived.connect(_on_pig_arrived.bind(pig))
	pig.inventory.selection_changed.connect(_on_held_item_changed.bind(pig))


func _play_sfx(
	player: AudioStreamPlayer,
	pitch_min: float = 0.94,
	pitch_max: float = 1.06,
	source_cell: Vector2i = INVALID_CELL
) -> void:
	if player == null or player.stream == null:
		return
	var cell := source_cell
	if cell == INVALID_CELL:
		if active_pig != null:
			cell = grid.world_to_cell(active_pig.global_position)
		else:
			cell = grid.world_to_cell(camera.global_position)
	var linear := _audio_linear_at(cell)
	var base_db := float(player.get_meta("base_volume_db", player.volume_db))
	player.volume_db = base_db + (linear_to_db(linear) if linear > 0.001 else AUDIO_MIN_DB)
	player.pitch_scale = randf_range(pitch_min, pitch_max)
	player.play()


func _audio_linear_at(cell: Vector2i) -> float:
	var source := grid.cell_to_world_center(cell)
	var center := camera.global_position
	var distance_cells := source.distance_to(center) / float(grid.cell_size)
	var distance_factor := clampf(1.0 - distance_cells / AUDIO_FADE_CELLS, 0.0, 1.0)
	var zoom_factor := clampf(_map_zoom, 0.0, 1.0)
	return distance_factor * zoom_factor


func _disconnect_pig_inventory(pig: Pig) -> void:
	if pig == null or pig.inventory == null:
		return
	for connection in pig.inventory.selection_changed.get_connections():
		var callback: Callable = connection.get("callable", Callable())
		if callback.is_valid() and callback.get_object() == self:
			pig.inventory.selection_changed.disconnect(callback)


func _harvest_crop(cell: Vector2i, actor: Pig = null) -> void:
	var user := actor if actor != null else active_pig
	if user == null:
		return
	var crop_id := farm.get_crop_id(cell)
	var crop_name := ItemDB.get_display_name(crop_id)

	if not farm.is_mature(cell):
		var stage := farm.get_crop_stage(cell)
		var mature_stage := ItemDB.get_mature_stage(crop_id)
		var next_seconds := ceili(farm.get_seconds_to_next_stage(cell))
		var mature_seconds := ceili(farm.get_seconds_to_mature(cell))
		hud.set_hint(
			"%s还没成熟（%d/%d），约 %d 秒后进入下一阶段，距成熟约 %d 秒。"
			% [crop_name, stage, mature_stage, next_seconds, mature_seconds]
		)
		return

	var minimum_yield := ItemDB.get_yield_range(crop_id).x
	var free_capacity := user.inventory.get_free_capacity(crop_id)
	if free_capacity < minimum_yield:
		hud.set_hint("背包空间不足，至少需要 %d 个空位才能收割%s。" % [minimum_yield, crop_name])
		return

	var result := farm.harvest(cell, free_capacity)
	if result.is_empty():
		hud.set_hint("现在无法收割%s。" % crop_name)
		return

	var amount := int(result.get("amount", 0))
	var leftover := user.inventory.add_item(crop_id, amount)
	if leftover != 0:
		push_error("收割物品未能完全进入背包：%s ×%d" % [crop_name, leftover])

	hud.set_hint(
		"%s收割%s，获得 ×%d。背包里现在有 %d 个。"
		% [user.display_name, crop_name, amount, user.inventory.get_total_count(crop_id)]
	)
	print(
		"[Farm] %s 收割 %s ×%d，背包总数 %d"
		% [user.display_name, crop_name, amount, user.inventory.get_total_count(crop_id)]
	)


func _on_minimap_pig_selected(pig: Pig) -> void:
	if pig == null:
		return
	_camera_offset = Vector2.ZERO
	_select_pig(pig)


func _on_map_command_requested(cell: Vector2i) -> void:
	if active_pig == null:
		hud.set_hint("先在小地图或世界里选中一只猪，再右键地图让它过去。")
		return
	if active_pig.behavior_running:
		hud.set_hint("这只猪正在自动执行行为；先暂停自动，再下达地图移动指令。")
		return
	_command_pig_to_cell(active_pig, cell)


func _command_pig_to_cell(pig: Pig, cell: Vector2i) -> void:
	if pig == null:
		return
	var target := cell
	if _is_path_blocked(target, pig):
		target = _find_nearby_open_cell(cell, 8, pig)
		if target == INVALID_CELL:
			hud.set_hint("目标附近没有可站立的格子。")
			return
	var start := grid.world_to_cell(pig.global_position)
	if start == target:
		hud.set_hint("%s 已经在这里了。" % pig.display_name)
		return
	_cancel_path_motion()
	var path := _find_path_to_cell(start, target, pig, 2000)
	if path.is_empty():
		hud.set_hint("找不到通往地图目标的路径。")
		return
	pig.command_path = path
	pig.command_action.clear()
	if pig == active_pig:
		_camera_offset = Vector2.ZERO
		move_marker.play(grid.cell_to_world_center(target))
	var next: Vector2i = pig.command_path.pop_front()
	pig.move_to_cell(next, grid.cell_size)
	hud.set_hint("%s 正在前往地图目标 (%d, %d)…" % [pig.display_name, target.x, target.y])


func _find_nearby_open_cell(center: Vector2i, radius: int, moving_pig: Pig) -> Vector2i:
	for distance in range(1, radius + 1):
		for y in range(-distance, distance + 1):
			for x in range(-distance, distance + 1):
				if absi(x) != distance and absi(y) != distance:
					continue
				var cell := center + Vector2i(x, y)
				if not _is_path_blocked(cell, moving_pig):
					return cell
	return INVALID_CELL


func _on_crafting_button_pressed() -> void:
	_end_right_drag()
	if active_pig == null:
		hud.set_hint("先左键选中一只猪，再打开合成。")
		return
	if hud.toggle_crafting():
		if hud.is_crafting_open():
			hud.set_hint("合成已打开：使用当前猪背包里的材料。")
		else:
			hud.set_hint(_base_hint())


func _on_behavior_button_pressed() -> void:
	_end_right_drag()
	if active_pig == null:
		hud.set_hint("先左键选中一只猪，再打开行为设计。")
		return
	if hud.is_behavior_open():
		hud.close_behavior()
		hud.set_hint(_base_hint())
	else:
		hud.open_behavior(active_pig)
		_update_behavior_step_label()
		hud.set_hint("行为设计已打开：添加/拖动模块，点“开始自动”后每 1 秒互动一次。")


func _on_behavior_program_changed() -> void:
	_reset_behavior_runtime(active_pig)


func _reset_behavior_runtime(pig: Pig = null) -> void:
	var target := pig if pig != null else active_pig
	if target == null:
		return
	target.behavior_wait = 0.0
	target.behavior_module_index = 0
	target.behavior_area_index = 0
	target.behavior_move_active = false
	target.behavior_path.clear()
	if target.is_moving:
		target.stop_moving()


func _on_behavior_area_pick_requested(module_index: int) -> void:
	if active_pig == null or not hud.is_behavior_open():
		return
	if module_index < 0 or module_index >= active_pig.behavior_program.size():
		return
	_behavior_pick_mode = BehaviorPickMode.AREA
	_behavior_pick_module = module_index
	_behavior_area_start = INVALID_CELL
	_behavior_area_end = INVALID_CELL
	_behavior_area_dragging = false
	behavior_area_overlay.clear()
	hud.set_hint("按住左键在世界上拖出一个矩形区域；Esc 或右键取消。")


func _on_behavior_container_pick_requested(module_index: int) -> void:
	if active_pig == null or not hud.is_behavior_open():
		return
	if module_index < 0 or module_index >= active_pig.behavior_program.size():
		return
	_behavior_pick_mode = BehaviorPickMode.CONTAINER
	_behavior_pick_module = module_index
	behavior_area_overlay.clear()
	hud.set_hint("左键点击一个已放置的箱子或猪窝作为目标容器；Esc 或右键取消。")


func _on_behavior_position_pick_requested(module_index: int) -> void:
	if active_pig == null or not hud.is_behavior_open():
		return
	if module_index < 0 or module_index >= active_pig.behavior_program.size():
		return
	_behavior_pick_mode = BehaviorPickMode.POSITION
	_behavior_pick_module = module_index
	behavior_area_overlay.clear()
	hud.set_hint("左键点击一个格子作为移动目标；Esc 或右键取消。")


func _handle_behavior_pick_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mouse_button := event as InputEventMouseButton
		if mouse_button.button_index == MOUSE_BUTTON_RIGHT and mouse_button.pressed:
			_cancel_behavior_pick()
			return true
		if mouse_button.button_index == MOUSE_BUTTON_WHEEL_UP or mouse_button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			return true
		if mouse_button.button_index != MOUSE_BUTTON_LEFT:
			return false
		var cell := grid.world_to_cell(get_global_mouse_position())
		if _behavior_pick_mode == BehaviorPickMode.AREA:
			if mouse_button.pressed:
				_behavior_area_start = cell
				_behavior_area_end = cell
				_behavior_area_dragging = true
				behavior_area_overlay.show_selection(cell, cell)
			elif _behavior_area_dragging:
				_behavior_area_end = cell
				_finish_behavior_area_pick()
			return true
		if _behavior_pick_mode == BehaviorPickMode.CONTAINER:
			if mouse_button.pressed:
				_finish_behavior_container_pick(cell)
			return true
		if _behavior_pick_mode == BehaviorPickMode.POSITION:
			if mouse_button.pressed:
				_finish_behavior_position_pick(cell)
			return true
	if event is InputEventMouseMotion:
		if _behavior_pick_mode == BehaviorPickMode.AREA and _behavior_area_dragging:
			var cell := grid.world_to_cell(get_global_mouse_position())
			if cell != _behavior_area_end:
				_behavior_area_end = cell
				behavior_area_overlay.show_selection(_behavior_area_start, _behavior_area_end)
			return true
	return false


func _finish_behavior_area_pick() -> void:
	if active_pig == null or _behavior_pick_module < 0:
		_cancel_behavior_pick()
		return
	var min_cell := Vector2i(
		mini(_behavior_area_start.x, _behavior_area_end.x),
		mini(_behavior_area_start.y, _behavior_area_end.y)
	)
	var max_cell := Vector2i(
		maxi(_behavior_area_start.x, _behavior_area_end.x),
		maxi(_behavior_area_start.y, _behavior_area_end.y)
	)
	var area := Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)
	hud.behavior_ui.set_module_area(_behavior_pick_module, area)
	_behavior_pick_mode = BehaviorPickMode.NONE
	_behavior_pick_module = -1
	_behavior_area_dragging = false
	behavior_area_overlay.clear()
	hud.set_hint("已选择工具区域：%d×%d 格。" % [area.size.x, area.size.y])


func _finish_behavior_container_pick(cell: Vector2i) -> void:
	var container := _behavior_container_info(cell)
	if container.is_empty():
		hud.set_hint("这里不是箱子或猪窝，请左键点击一个容器；Esc 取消。")
		return
	hud.behavior_ui.set_module_container(_behavior_pick_module, cell)
	_behavior_pick_mode = BehaviorPickMode.NONE
	_behavior_pick_module = -1
	behavior_area_overlay.clear()
	hud.set_hint("已选择容器：%s (%d, %d)。" % [
		"猪窝" if str(container.get("kind", "")) == "nest" else "箱子",
		cell.x,
		cell.y,
	])


func _finish_behavior_position_pick(cell: Vector2i) -> void:
	if active_pig == null or _behavior_pick_module < 0:
		_cancel_behavior_pick()
		return
	hud.behavior_ui.set_module_position(_behavior_pick_module, cell)
	_behavior_pick_mode = BehaviorPickMode.NONE
	_behavior_pick_module = -1
	behavior_area_overlay.clear()
	hud.set_hint("已选择移动目标：(%d, %d)。" % [cell.x, cell.y])


func _cancel_behavior_pick() -> void:
	_behavior_pick_mode = BehaviorPickMode.NONE
	_behavior_pick_module = -1
	_behavior_area_dragging = false
	_behavior_area_start = INVALID_CELL
	_behavior_area_end = INVALID_CELL
	behavior_area_overlay.clear()
	hud.set_hint(_base_hint())


func _advance_behavior(delta: float) -> void:
	for pig in pigs:
		if pig == null or not is_instance_valid(pig):
			continue
		_advance_pig_behavior(pig, delta)
	_update_behavior_step_label()


func _advance_pig_behavior(pig: Pig, delta: float) -> void:
	if not pig.behavior_running:
		if not pig.behavior_path.is_empty():
			pig.behavior_path.clear()
			pig.behavior_move_active = false
			pig.stop_moving()
		return
	if pig.behavior_program.is_empty() or pig.is_stunned:
		if pig.is_stunned and not pig.behavior_path.is_empty():
			pig.behavior_path.clear()
			pig.behavior_move_active = false
		return
	# 只有当前选中的猪会被配置/手动拖动暂时打断；其他自动猪继续。
	if pig == active_pig:
		if not _pending_action.is_empty() or not _path_queue.is_empty():
			_cancel_path_motion()
		if _behavior_pick_mode != BehaviorPickMode.NONE:
			return
		if _right_dragging or not _pending_action.is_empty():
			return
	if pig.behavior_wait > 0.0:
		pig.behavior_wait = maxf(0.0, pig.behavior_wait - delta)
		return
	if not pig.command_path.is_empty() or not pig.command_action.is_empty():
		return
	if not pig.behavior_path.is_empty():
		if not pig.is_moving:
			var stalled_next: Vector2i = pig.behavior_path.pop_front()
			pig.move_to_cell(stalled_next, grid.cell_size)
		return
	if pig.is_moving:
		return
	if pig.behavior_move_active:
		pig.behavior_move_active = false

	var program := pig.behavior_program
	if pig.behavior_module_index < 0 or pig.behavior_module_index >= program.size():
		pig.behavior_module_index = 0
		pig.behavior_area_index = 0
	var module: Dictionary = program[pig.behavior_module_index]
	var type := str(module.get("type", ""))
	match type:
		"move":
			_behavior_tick_move(pig, module)
		"tool":
			_behavior_tick_tool(pig, module)
		"store":
			_behavior_tick_container(pig, module, true)
		"take":
			_behavior_tick_container(pig, module, false)
		_:
			_advance_behavior_module(pig)


func _behavior_tick_move(pig: Pig, module: Dictionary) -> void:
	var target: Vector2i = module.get("cell", INVALID_CELL)
	if target == INVALID_CELL:
		_advance_behavior_module(pig)
		return
	if grid.world_to_cell(pig.global_position) == target:
		_advance_behavior_module(pig)
		return
	if _begin_behavior_move(pig, target, false):
		return
	hud.set_hint("行为：%s 无法到达目标格子 (%d, %d)。" % [pig.display_name, target.x, target.y])
	pig.behavior_wait = BEHAVIOR_SKIP_DELAY
	_advance_behavior_module(pig)


func _behavior_tick_tool(pig: Pig, module: Dictionary) -> void:
	var area: Rect2i = module.get("rect", Rect2i())
	if area.size.x <= 0 or area.size.y <= 0:
		pig.behavior_wait = BEHAVIOR_SKIP_DELAY
		_advance_behavior_module(pig)
		return
	var total := area.size.x * area.size.y
	var item_id := str(module.get("item_id", "hand"))
	var checked := 0
	while pig.behavior_area_index < total and checked < 256:
		var local_x := pig.behavior_area_index % area.size.x
		var local_y := int(pig.behavior_area_index / float(area.size.x))
		var cell := area.position + Vector2i(local_x, local_y)
		if _behavior_can_use_tool(pig, item_id, cell):
			if not _is_pig_in_interaction_range(pig, cell):
				if _begin_behavior_move(pig, cell, true):
					return
				pig.behavior_area_index += 1
				checked += 1
				continue
			var used := _behavior_use_tool(pig, item_id, cell)
			pig.behavior_area_index += 1
			if used:
				pig.behavior_wait = BEHAVIOR_INTERACTION_SECONDS
			return
		# 条件不成立：立刻判定下一格，不占用 1 秒。
		pig.behavior_area_index += 1
		checked += 1
	if pig.behavior_area_index >= total:
		_advance_behavior_module(pig)


func _behavior_can_use_tool(pig: Pig, item_id: String, cell: Vector2i) -> bool:
	if pig == null:
		return false
	if item_id != "hand" and _find_inventory_slot(pig.inventory, item_id) < 0:
		return false
	match item_id:
		"hand":
			return farm.has_crop(cell) and farm.is_mature(cell)
		"hoe":
			return (
				not world_objects.is_blocked(cell)
				and not farm.is_tilled(cell)
				and not farm.has_crop(cell)
			)
		"shovel":
			return farm.is_tilled(cell) and not farm.has_crop(cell)
		"super_watering_can":
			if world_objects.has_sapling(cell):
				return world_objects.get_sapling_stage(cell) < WorldObjects.SAPLING_MATURE_STAGE
			return farm.has_crop(cell) and not farm.is_mature(cell)
		"hammer":
			if world_objects.find_tree_root(cell) != WorldObjects.INVALID_CELL:
				return true
			if world_objects.has_sapling(cell):
				return false
			if world_objects.has_log(cell):
				return pig.inventory.get_free_capacity("wood") >= 1
			if world_objects.has_plank(cell):
				return pig.inventory.get_free_capacity("planks") >= 1
			if world_objects.has_fence(cell):
				return pig.inventory.get_free_capacity("fence") >= 1
			if world_objects.has_chest(cell):
				var chest := world_objects.get_chest(cell)
				return (
					chest != null
					and chest.is_empty()
					and pig.inventory.get_free_capacity("chest") >= 1
				)
			var nest_root := world_objects.find_nest_root(cell)
			if nest_root != WorldObjects.INVALID_CELL:
				var nest := world_objects.get_nest(nest_root)
				var nest_inventory: Inventory = nest.get("inventory")
				return (
					nest_inventory != null
					and nest_inventory.is_empty()
					and pig.inventory.get_free_capacity("pig_nest") >= 1
				)
			return false
		"potato", "carrot":
			return (
				farm.is_tilled(cell)
				and not farm.has_crop(cell)
				and not world_objects.is_blocked(cell)
			)
		_:
			return false


func _behavior_tick_container(pig: Pig, module: Dictionary, storing: bool) -> void:
	var container_cell: Vector2i = module.get("container_cell", INVALID_CELL)
	var container := _behavior_container_info(container_cell)
	if container_cell == INVALID_CELL or container.is_empty():
		pig.behavior_wait = BEHAVIOR_SKIP_DELAY
		_advance_behavior_module(pig)
		return
	if not _is_pig_in_interaction_range(pig, container_cell):
		if _begin_behavior_move(pig, container_cell, true):
			return
		pig.behavior_wait = BEHAVIOR_SKIP_DELAY
		_advance_behavior_module(pig)
		return
	var item_id := str(module.get("item_id", ""))
	var moved := (
		_behavior_store_item(pig, item_id, container)
		if storing
		else _behavior_take_item(pig, item_id, container)
	)
	if moved:
		pig.behavior_wait = BEHAVIOR_INTERACTION_SECONDS
	else:
		pig.behavior_wait = BEHAVIOR_SKIP_DELAY
		_advance_behavior_module(pig)


func _behavior_container_info(cell: Vector2i) -> Dictionary:
	if cell == INVALID_CELL:
		return {}
	if world_objects.has_chest(cell):
		var chest := world_objects.get_chest(cell)
		if chest != null:
			return {"kind": "chest", "inventory": chest, "cell": cell}
	var nest_root := world_objects.find_nest_root(cell)
	if nest_root != WorldObjects.INVALID_CELL:
		var nest := world_objects.get_nest(nest_root)
		var nest_inventory: Inventory = nest.get("inventory")
		if nest_inventory != null:
			return {
				"kind": "nest",
				"inventory": nest_inventory,
				"cell": cell,
				"root": nest_root,
			}
	return {}


func _advance_behavior_module(pig: Pig) -> void:
	if pig == null or pig.behavior_program.is_empty():
		return
	pig.behavior_module_index = (pig.behavior_module_index + 1) % pig.behavior_program.size()
	pig.behavior_area_index = 0
	pig.behavior_wait = 0.0


func _update_behavior_step_label() -> void:
	if active_pig == null or not hud.is_behavior_open():
		return
	var program := active_pig.behavior_program
	if not active_pig.behavior_running or program.is_empty():
		hud.behavior_ui.set_runtime_step("步骤：已暂停")
		return
	var index := clampi(active_pig.behavior_module_index, 0, program.size() - 1)
	var module: Dictionary = program[index]
	var type := str(module.get("type", ""))
	var type_name := "未知"
	var focus := "—"
	match type:
		"move":
			type_name = "移动到位置"
			var target: Vector2i = module.get("cell", INVALID_CELL)
			if target != INVALID_CELL:
				focus = "(%d, %d)" % [target.x, target.y]
		"tool":
			var tool_id := str(module.get("item_id", "hand"))
			if tool_id == "hand":
				type_name = "区域空手收割"
			else:
				type_name = "区域使用%s" % ItemDB.get_display_name(tool_id)
			var area: Rect2i = module.get("rect", Rect2i())
			var total := area.size.x * area.size.y
			if area.size.x > 0 and area.size.y > 0 and active_pig.behavior_area_index < total:
				var local_x := active_pig.behavior_area_index % area.size.x
				var local_y := int(active_pig.behavior_area_index / float(area.size.x))
				var cell := area.position + Vector2i(local_x, local_y)
				focus = "(%d, %d)" % [cell.x, cell.y]
			elif area.size.x > 0 and area.size.y > 0:
				focus = "区域完成"
			else:
				focus = "未框选"
		"store":
			type_name = "存入容器"
			var store_cell: Vector2i = module.get("container_cell", INVALID_CELL)
			if store_cell != INVALID_CELL:
				focus = "(%d, %d)" % [store_cell.x, store_cell.y]
			else:
				focus = "未选容器"
		"take":
			type_name = "从容器取出"
			var take_cell: Vector2i = module.get("container_cell", INVALID_CELL)
			if take_cell != INVALID_CELL:
				focus = "(%d, %d)" % [take_cell.x, take_cell.y]
			else:
				focus = "未选容器"
	hud.behavior_ui.set_runtime_step("步骤 #%d：%s · 关注 %s" % [index + 1, type_name, focus])


func _begin_behavior_move(pig: Pig, target: Vector2i, stop_in_range: bool) -> bool:
	if pig == null or pig.is_stunned:
		return false
	var start := grid.world_to_cell(pig.global_position)
	if stop_in_range and _is_pig_in_interaction_range(pig, target):
		return true
	var path: Array[Vector2i]
	if stop_in_range:
		path = _find_path_into_range(start, target, pig)
	else:
		path = _find_path_to_cell(start, target, pig)
	if path.is_empty():
		return false
	if pig == active_pig:
		move_marker.play(grid.cell_to_world_center(target))
	pig.behavior_path = path
	pig.behavior_move_active = true
	var next: Vector2i = pig.behavior_path.pop_front()
	pig.move_to_cell(next, grid.cell_size)
	return true


func _behavior_use_tool(pig: Pig, item_id: String, cell: Vector2i) -> bool:
	if pig == null:
		return false
	if item_id == "hand":
		pig.inventory.clear_selection()
		if farm.has_crop(cell):
			_harvest_crop(cell, pig)
		return true
	var slot := _find_inventory_slot(pig.inventory, item_id)
	if slot < 0:
		if pig == active_pig:
			hud.set_hint("行为：背包里没有 %s。" % ItemDB.get_display_name(item_id))
		return false
	pig.inventory.select_slot(slot)
	_use_held_item(item_id, cell, pig)
	return true


func _find_inventory_slot(inventory: Inventory, item_id: String) -> int:
	for index in inventory.slot_count:
		var slot := inventory.get_slot(index)
		if str(slot.get("item_id", "")) == item_id and int(slot.get("count", 0)) > 0:
			return index
	return -1


func _find_target_slot(inventory: Inventory, item_id: String) -> int:
	var max_stack := ItemDB.get_max_stack(item_id)
	for index in inventory.slot_count:
		var slot := inventory.get_slot(index)
		if slot.is_empty():
			return index
		if str(slot.get("item_id", "")) == item_id and int(slot.get("count", 0)) < max_stack:
			return index
	return -1


func _behavior_store_item(pig: Pig, item_id: String, container: Dictionary) -> bool:
	if pig == null or container.is_empty() or item_id.is_empty():
		return false
	var target_inventory: Inventory = container.get("inventory")
	if target_inventory == null:
		return false
	var from_index := _find_inventory_slot(pig.inventory, item_id)
	if from_index < 0:
		return false
	var target_index := -1
	if str(container.get("kind", "")) == "nest":
		if item_id == "pig":
			target_index = _find_nest_parent_slot(target_inventory)
		elif item_id == "potato" or item_id == "carrot":
			target_index = 2 if _nest_food_slot_available(target_inventory, item_id) else -1
	else:
		target_index = _find_target_slot(target_inventory, item_id)
	if target_index < 0:
		return false
	return pig.inventory.move_stack_to(target_inventory, from_index, target_index)


func _behavior_take_item(pig: Pig, item_id: String, container: Dictionary) -> bool:
	if pig == null or container.is_empty() or item_id.is_empty():
		return false
	var source_inventory: Inventory = container.get("inventory")
	if source_inventory == null:
		return false
	var from_index := -1
	if str(container.get("kind", "")) == "nest":
		if item_id == "pig":
			# 自动取出只取新生猪输出槽，避免把亲代猪拿走导致繁育中断。
			if _slot_has_item(source_inventory, 3, "pig"):
				from_index = 3
		elif item_id == "potato" or item_id == "carrot":
			if _slot_has_item(source_inventory, 2, item_id):
				from_index = 2
	else:
		from_index = _find_inventory_slot(source_inventory, item_id)
	if from_index < 0:
		return false
	var to_index := _find_target_slot(pig.inventory, item_id)
	if to_index < 0:
		return false
	return source_inventory.move_stack_to(pig.inventory, from_index, to_index)


func _slot_has_item(inventory: Inventory, index: int, item_id: String) -> bool:
	var slot := inventory.get_slot(index)
	return (
		str(slot.get("item_id", "")) == item_id
		and int(slot.get("count", 0)) > 0
	)


func _find_nest_parent_slot(inventory: Inventory) -> int:
	for index in [0, 1]:
		if inventory.get_slot(index).is_empty():
			return index
	return -1


func _nest_food_slot_available(inventory: Inventory, item_id: String) -> bool:
	var slot := inventory.get_slot(2)
	if slot.is_empty():
		return true
	return (
		str(slot.get("item_id", "")) == item_id
		and int(slot.get("count", 0)) < ItemDB.get_max_stack(item_id)
	)


func _on_pig_arrived(cell: Vector2i, pig: Pig) -> void:
	if pig == active_pig:
		hud.set_pig_cell(cell, grid.cell_size)

	if not pig.command_path.is_empty():
		var command_next: Vector2i = pig.command_path.pop_front()
		pig.move_to_cell(command_next, grid.cell_size)
		return
	if not pig.command_action.is_empty():
		var action := pig.command_action
		pig.command_action = {}
		_execute_command_action_for(pig, action)
		return

	if not pig.behavior_path.is_empty():
		var next: Vector2i = pig.behavior_path.pop_front()
		pig.move_to_cell(next, grid.cell_size)
		return
	if pig.behavior_move_active:
		pig.behavior_move_active = false
	if pig != active_pig:
		return

	if not _path_queue.is_empty():
		_advance_path()
		return
	if not _pending_action.is_empty():
		_execute_pending_action()
		return
	hud.set_hint(_base_hint())


func _on_held_item_changed(_index: int, pig: Pig) -> void:
	if pig != active_pig:
		return
	if not _pending_action.is_empty():
		_cancel_path_motion()
		hud.set_hint("手持物已经变化，自动行动取消。")
		return
	hud.set_hint(_base_hint())


func _base_hint() -> String:
	if active_pig == null:
		return "左键选中猪；拖动空地可移动镜头。自动模式的猪取消选中后也会继续工作。"

	var held_item := active_pig.inventory.get_held_item_id()
	if held_item.is_empty():
		return "空手：右键成熟作物收割、空地移动；按住右键拖动可连续收割。"

	var item_name := ItemDB.get_display_name(held_item)
	if ItemDB.is_tool(held_item):
		match ItemDB.get_tool_action(held_item):
			"till":
				return "手持%s：右键草地锄地，按住右键可连续锄。" % item_name
			"water":
				return "手持%s：右键作物或树苗催熟一阶段，按住右键连续浇水。" % item_name
			"flatten":
				return "手持%s：右键耕地铲平，按住右键可连续铲。" % item_name
			"hammer":
				return (
					"手持%s：大树敲 3~5 下；木头、木板、栅栏、空箱子和空猪窝可拆回背包。"
					% item_name
				)
			_:
				return "手持%s：右键地面使用。" % item_name

	if ItemDB.is_crop(held_item):
		return "手持%s：右键空耕地种下，按住右键连续播种。" % item_name

	if held_item == "wood":
		return "手持木头：右键空地放置一格木头，按住右键可连续放置。"

	if held_item == "planks":
		return "手持木板：右键空地放置一格木板，锤子可以拆回。"

	if held_item == "sapling":
		return "手持树苗：右键平地种下，约 90 秒长成 3 × 3 大树，可用水壶催熟。"

	if held_item == "pig":
		return "手持猪：右键平地放下，它会醒来，原来的背包内容也会保留。"

	if held_item == "pig_nest":
		return "手持猪窝：右键平地放下 3×3 猪窝，再右键打开放入猪和食物。"

	if held_item == "chest":
		return "手持箱子：右键平地放下；右键已放置的箱子可打开 40 格空间。"

	if held_item == "fence":
		return "手持木栅栏：右键平地放下，相邻栅栏和方块会自动连接。"

	return "右键地面使用手持物品。"


func _create_starter_inventory() -> Inventory:
	var inventory := Inventory.new(Inventory.DEFAULT_SLOT_COUNT)
	_add_item(inventory, "hoe", 1)
	_add_item(inventory, "super_watering_can", 1)
	_add_item(inventory, "shovel", 1)
	_add_item(inventory, "hammer", 1)
	_add_item(inventory, "potato", 12)
	_add_item(inventory, "carrot", 6)
	return inventory


func _add_item(inventory: Inventory, item_id: String, amount: int) -> void:
	var leftover := inventory.add_item(item_id, amount)
	if leftover != 0:
		push_error("初始物品没有完全放入背包：%s 剩余 %d" % [item_id, leftover])
