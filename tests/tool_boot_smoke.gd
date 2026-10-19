extends Node
## 冒烟：真实 main.tscn 启动若干帧，检查区块生成 / 物化 / 地形查询 / 存读档都通了。
func _ready() -> void:
	var main: Node = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	var manager: ChunkManager = main.chunk_manager
	print("boot: seed=%d version=%d loaded=%d" % [manager.get_seed(), main.worldgen_config.worldgen_version, manager.loaded_count()])
	for _i in 240:
		await get_tree().process_frame
	print("boot: loaded=%d materialized=%d trees=%d ores=%d" % [
		manager.loaded_count(), main.world_objects.get_materialized_count(),
		main.world_objects.tree_roots.size(), main.world_objects.ores.size()])
	var center: Vector2i = main.get_center_focus_cell()
	print("boot: terrain(center)=%s terrain(+5000)=%s" % [
		TerrainTypes.type_name(manager.get_cell_terrain(center)),
		TerrainTypes.type_name(manager.get_cell_terrain(center + Vector2i(5000, 5000)))])
	var blocked := 0
	for y in range(-6, 7):
		for x in range(-6, 7):
			if manager.get_cell_terrain(Vector2i(x, y)) == TerrainTypes.WATER:
				blocked += 1
	print("boot: water in 13x13 around origin = %d (expect 0)" % blocked)
	var save_result: Dictionary = main._save_manager.save_game()
	print("boot: save -> %s" % str(save_result))
	var load_result: Dictionary = main._save_manager.load_game()
	print("boot: load -> %s" % str(load_result))
	print("boot: after load pigs=%d loaded=%d" % [main.pigs.size(), main.chunk_manager.loaded_count()])
	get_tree().quit(0)