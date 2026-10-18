extends Node
## 运行时结构测试：三只猪、独立背包、猪占格、树/箱子/栅栏/猪窝、寻路与缩放。
## 运行：godot --headless --path . res://tests/test_runtime.tscn

var _failures: Array[String] = []
var _main: Node


func _ready() -> void:
	_main = load("res://scenes/main.tscn").instantiate()
	add_child(_main)
	await get_tree().process_frame
	await get_tree().process_frame

	_test_three_pigs_and_inventories()
	_test_world_objects()
	_test_sapling_growth()
	_test_pathfinding_quality()
	_test_selection_and_bag_visibility()
	_test_chest_and_crafting_ui()
	_test_nest_ui()
	_test_interaction_range()
	_test_hammer_blocks()
	_test_pig_path_blocking()
	await _test_auto_move()
	await _test_auto_open_chest()
	_test_pig_capture_and_place()
	_test_map_zoom()

	if _failures.is_empty():
		print("RUNTIME TESTS PASSED: 3 pigs, pig cell blocking, collect/place, nest RGB, all blocks, UI.")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error("RUNTIME TEST FAILED: " + failure)
		get_tree().quit(1)


func _test_three_pigs_and_inventories() -> void:
	var pigs: Array = _main.pigs
	_check(pigs.size() == 3, "there should be three pigs")
	if pigs.size() < 3:
		return
	_check(pigs[0].inventory != pigs[1].inventory, "each pig should own a separate Inventory")
	_check(pigs[0].inventory != pigs[2].inventory, "third pig should own a separate Inventory")
	_check(pigs[0].inventory.slot_count == 40, "pig 1 bag should have 40 slots")
	_check(pigs[1].inventory.slot_count == 40, "pig 2 bag should have 40 slots")
	_check(pigs[2].inventory.slot_count == 40, "pig 3 bag should have 40 slots")
	_check(pigs[0].inventory.get_total_count("shovel") == 1, "pig 1 should start with a shovel")
	_check(pigs[0].inventory.get_total_count("hammer") == 1, "pig 1 should start with a hammer")
	_check(pigs[1].inventory.get_total_count("shovel") == 1, "pig 2 should start with a shovel")
	_check(pigs[1].inventory.get_total_count("hammer") == 1, "pig 2 should start with a hammer")
	_check(pigs[2].inventory.get_total_count("hammer") == 1, "pig 3 should start with a hammer")
	_check(pigs[0]._step_player.stream != null, "pigs should load a footstep sound")
	_check(pigs[0].pig_rgb != pigs[1].pig_rgb, "initial pigs should have distinct RGB values")

	var pig1_potatoes: int = pigs[0].inventory.get_total_count("potato")
	var pig2_potatoes: int = pigs[1].inventory.get_total_count("potato")
	var pig3_potatoes: int = pigs[2].inventory.get_total_count("potato")
	_check(pig1_potatoes == 12, "pig 1 should start with 12 potatoes")
	_check(pig2_potatoes == 12, "pig 2 should start with 12 potatoes")
	_check(pig3_potatoes == 12, "pig 3 should start with 12 potatoes")

	pigs[0].inventory.add_item("potato", 1)
	_check(pigs[0].inventory.get_total_count("potato") == 13, "pig 1 bag should change independently")
	_check(pigs[1].inventory.get_total_count("potato") == 12, "pig 2 bag should not change")
	_check(pigs[2].inventory.get_total_count("potato") == 12, "pig 3 bag should not change")


func _test_world_objects() -> void:
	var objects: WorldObjects = _main.world_objects
	var tree_root := Vector2i(5, -2)
	_check(objects.find_tree_root(tree_root) == tree_root, "tree should exist at its root")
	_check(objects.find_tree_root(tree_root + Vector2i(2, 2)) == tree_root, "tree should cover 3x3 cells")
	_check(objects.is_blocked(tree_root + Vector2i(2, 2)), "corner tree cells should block movement")
	_check(not objects.is_blocked(tree_root + Vector2i(3, 0)), "cells outside the tree should be free")
	_check(
		_main._find_path_to_cell(tree_root + Vector2i(-1, 0), tree_root).is_empty(),
		"pathfinding should refuse to enter a tree cell"
	)

	var log_cell := Vector2i(1, 5)
	_check(objects.place_log(log_cell), "wood should be placeable on a free cell")
	_check(objects.is_blocked(log_cell), "placed wood should block movement")
	_check(
		_main._find_path_to_cell(Vector2i(0, 5), log_cell).is_empty(),
		"pathfinding should refuse to enter a wood cell"
	)
	var detour: Array = _main._find_path_to_cell(Vector2i(0, 5), Vector2i(2, 5))
	_check(not detour.is_empty(), "pathfinding should route around placed wood")
	_check(not detour.has(log_cell), "detour should not pass through the wood cell")
	_check(detour.size() > 2, "detour around wood should be longer than a straight path")
	_check(objects.remove_log(log_cell), "wood should be removable")
	_check(not objects.is_blocked(log_cell), "removed wood should free the cell")

	var tree_hits := objects.get_tree_remaining_hits(tree_root)
	_check(tree_hits >= 3 and tree_hits <= 5, "tree should require 3-5 hammer hits")

	var test_tree_root := Vector2i(12, 12)
	objects.add_tree(test_tree_root)
	var hits_needed := objects.get_tree_remaining_hits(test_tree_root)
	var hits_done := 0
	while objects.find_tree_root(test_tree_root) != WorldObjects.INVALID_CELL and hits_done < 6:
		objects.hit_tree(test_tree_root)
		hits_done += 1
	_check(hits_done >= 3 and hits_done <= 5, "tree should fall after 3-5 hits")
	_check(hits_done == hits_needed, "tree hit count should match generated health")

	var chest_cell := Vector2i(0, 14)
	var chest_inventory := objects.place_chest(chest_cell)
	_check(chest_inventory != null, "chest should be placeable")
	_check(chest_inventory.slot_count == 40, "chest should have 40 slots")
	_check(objects.has_chest(chest_cell), "chest should be tracked in the world")
	_check(objects.is_blocked(chest_cell), "chest should block movement")
	var second_chest := objects.place_chest(Vector2i(1, 14))
	_check(second_chest != null, "a second chest should be placeable")
	_check(second_chest != chest_inventory, "each chest should own a separate inventory")
	_check(second_chest.slot_count == 40, "second chest should also have 40 slots")

	var fence_a := Vector2i(3, 14)
	var fence_b := Vector2i(4, 14)
	_check(objects.place_fence(fence_a), "first fence should place")
	_check(objects.place_fence(fence_b), "second fence should place")
	_check(objects.has_fence(fence_a) and objects.has_fence(fence_b), "fences should be tracked")
	_check(objects.is_blocked(fence_a), "fence should block movement")
	_check(objects.get_fence_count() == 2, "fence count should include both fences")
	_check(_main.chop_sound.stream != null, "chopping sound should be loaded")
	_check(_main.leaf_burst is LeafBurst, "leaf burst effect should exist")
	_check(_main.hammer_sound.stream != null, "hammer sound should be loaded")
	_check(_main.till_sound.stream != null, "till sound should be loaded")
	_check(_main.plant_sound.stream != null, "plant sound should be loaded")
	_check(_main.water_sound.stream != null, "water sound should be loaded")
	_check(_main.stun_sound.stream != null, "stun sound should be loaded")
	_check(_main.stun_burst is StunBurst, "stun burst effect should exist")

	var plank_cell := Vector2i(2, 10)
	_check(objects.place_plank(plank_cell), "planks should be placeable as a block")
	_check(objects.has_plank(plank_cell), "plank block should be tracked")
	_check(objects.is_blocked(plank_cell), "plank block should block movement")
	_check(objects.remove_plank(plank_cell), "plank block should be removable")
	_check(not objects.is_blocked(plank_cell), "removed planks should free the cell")

	var nest_root := Vector2i(20, 20)
	var nest := objects.place_nest(nest_root)
	_check(not nest.is_empty(), "pig nest should be placeable")
	var nest_inventory: Inventory = nest.get("inventory")
	_check(nest_inventory.slot_count == 4, "pig nest should have 4 slots")
	_check(objects.find_nest_root(nest_root + Vector2i(2, 2)) == nest_root, "nest should cover 3x3")
	_check(objects.is_blocked(nest_root + Vector2i(1, 1)), "nest cells should block movement")
	nest_inventory.slots[0] = {
		"item_id": "pig",
		"count": 1,
		"pig_name": "亲代 A",
		"pig_rgb": Vector3i(100, 100, 100),
		"pig_tint": Color.WHITE,
		"pig_inventory": Inventory.new(40),
	}
	nest_inventory.slots[1] = {
		"item_id": "pig",
		"count": 1,
		"pig_name": "亲代 B",
		"pig_rgb": Vector3i(200, 200, 200),
		"pig_tint": Color.WHITE,
		"pig_inventory": Inventory.new(40),
	}
	nest_inventory.slots[2] = {"item_id": "potato", "count": 10}
	objects._advance_nests(WorldObjects.NEST_BREED_SECONDS + 0.1)
	var child: Dictionary = nest_inventory.get_slot(WorldObjects.NEST_SLOT_OUTPUT)
	_check(str(child.get("item_id", "")) == "pig", "nest should output a pig item")
	_check(int(nest_inventory.get_slot(2).get("count", 0)) == 0, "nest should consume 10 food")
	var child_rgb: Vector3i = child.get("pig_rgb", Vector3i.ZERO)
	_check(
		child_rgb.x >= 140 and child_rgb.x <= 160
		and child_rgb.y >= 140 and child_rgb.y <= 160
		and child_rgb.z >= 140 and child_rgb.z <= 160,
		"child RGB should be close to the parent average"
	)
	var child_inventory: Variant = child.get("pig_inventory")
	_check(child_inventory is Inventory, "child pig should have an inventory")
	if child_inventory is Inventory:
		var child_bag: Inventory = child_inventory
		_check(child_bag.slot_count == 40 and child_bag.is_empty(), "child pig backpack should be empty")
	_check(str(nest_inventory.get_slot(0).get("item_id", "")) == "pig", "nest should keep parents")


func _test_sapling_growth() -> void:
	var objects: WorldObjects = _main.world_objects
	var cell := Vector2i(0, 10)
	_check(objects.plant_sapling(cell), "sapling should be plantable on free ground")
	_check(objects.has_sapling(cell), "planted sapling should be tracked")
	_check(objects.is_blocked(cell), "sapling should block its cell")
	_check(objects.get_sapling_stage(cell) == 0, "sapling should start at stage 0")

	objects.advance_sapling_growth(29.0)
	_check(objects.get_sapling_stage(cell) == 0, "sapling should still be stage 0 at 29s")
	objects.advance_sapling_growth(1.1)
	_check(objects.get_sapling_stage(cell) == 1, "sapling should reach stage 1 after 30s")
	objects.advance_sapling_growth(60.0)
	_check(not objects.has_sapling(cell), "sapling should convert after 90s")
	var root := cell - WorldObjects.SAPLING_CENTER_OFFSET
	_check(objects.find_tree_root(cell) == root, "mature sapling should become a 3x3 tree")
	_check(objects.remove_tree(root), "test tree should be removable")

	var watered := Vector2i(8, 10)
	_check(objects.plant_sapling(watered), "second sapling should be plantable")
	_check(objects.water_sapling(watered), "watering should advance sapling to stage 1")
	_check(objects.get_sapling_stage(watered) == 1, "sapling should be stage 1 after watering")
	_check(objects.water_sapling(watered), "watering should advance sapling to stage 2")
	_check(objects.water_sapling(watered), "watering should mature the sapling")
	_check(not objects.has_sapling(watered), "watered sapling should convert into a tree")
	_check(
		objects.find_tree_root(watered) != WorldObjects.INVALID_CELL,
		"watered sapling should become a big tree"
	)
	objects.remove_tree(watered - WorldObjects.SAPLING_CENTER_OFFSET)


func _test_pathfinding_quality() -> void:
	var horizontal: Array = _main._find_path_to_cell(Vector2i(0, 8), Vector2i(5, 8))
	_check(horizontal.size() == 5, "clear horizontal path should take 5 steps")
	for index in 5:
		_check(horizontal[index] == Vector2i(index + 1, 8), "horizontal path should stay straight")

	var diagonal: Array = _main._find_path_to_cell(Vector2i(0, 8), Vector2i(5, 13))
	_check(diagonal.size() == 5, "clear diagonal path should take 5 diagonal steps")
	for index in 5:
		_check(
			diagonal[index] == Vector2i(index + 1, index + 9),
			"diagonal path should stay on the direct diagonal"
		)


func _test_selection_and_bag_visibility() -> void:
	var pigs: Array = _main.pigs
	_main._select_pig(pigs[0])
	_check(_main.active_pig == pigs[0], "selecting a pig should make it active")
	_check(_main.hud.inventory_ui.visible, "the active pig's bag should be visible")
	_check(_main.hud.is_inventory_open(), "the active pig's bag should be open")
	_check(not _main.hud.chest_ui.visible, "the chest UI should start hidden")
	_check(not _main.hud.crafting_ui.visible, "the crafting UI should start hidden")

	_main._deselect_pig()
	_check(_main.active_pig == null, "deselecting should clear the active pig")
	_check(not _main.hud.inventory_ui.visible, "the bag should hide when no pig is selected")
	_check(not _main.hud.is_inventory_open(), "the bag should not be open without a selected pig")


func _test_chest_and_crafting_ui() -> void:
	var pigs: Array = _main.pigs
	_main._select_pig(pigs[0])
	_main._open_chest(Vector2i(0, 14))
	_check(_main.hud.chest_ui.visible, "opening a chest should show the chest UI")
	_check(_main.hud.chest_ui._inventory != null, "the chest UI should bind a chest inventory")
	_check(_main.hud.chest_ui._inventory.slot_count == 40, "chest UI should show 40 slots")
	_main.hud.close_chest()
	_check(not _main.hud.chest_ui.visible, "closing a chest should hide the chest UI")

	_main._open_chest(Vector2i(0, 14))
	_main._handle_escape()
	_check(not _main.hud.chest_ui.visible, "Escape should close the chest UI first")

	_check(_main.hud.toggle_crafting(), "crafting should open for the selected pig")
	_check(_main.hud.crafting_ui.visible, "crafting UI should become visible")
	_main._handle_escape()
	_check(not _main.hud.crafting_ui.visible, "Escape should close the crafting UI")


func _test_nest_ui() -> void:
	var pigs: Array = _main.pigs
	_main._select_pig(pigs[0])
	_main._open_nest(Vector2i(20, 20))
	_check(_main.hud.nest_ui.visible, "opening a nest should show the nest UI")
	_check(_main.hud.nest_ui._inventory != null, "nest UI should bind a nest inventory")
	_check(_main.hud.nest_ui._inventory.slot_count == 4, "nest UI should show 4 slots")

	var bag: Inventory = pigs[0].inventory
	var potato_slot := -1
	for index in bag.slot_count:
		if str(bag.get_slot(index).get("item_id", "")) == "potato":
			potato_slot = index
			break
	_check(potato_slot >= 0, "active pig should have potatoes for nest UI test")
	if potato_slot >= 0:
		_main.hud.nest_ui.handle_slot_drop(
			{"source_inventory": bag, "source_index": potato_slot},
			WorldObjects.NEST_SLOT_FOOD
		)
		_check(
			int(_main.hud.nest_ui._inventory.get_slot(WorldObjects.NEST_SLOT_FOOD).get("count", 0)) >= 10,
			"food should drag into the nest food slot"
		)
	var hoe_slot := 0
	_main.hud.nest_ui.handle_slot_drop(
		{"source_inventory": bag, "source_index": hoe_slot},
		WorldObjects.NEST_SLOT_PARENT_A
	)
	_check(
		str(_main.hud.nest_ui._inventory.get_slot(WorldObjects.NEST_SLOT_PARENT_A).get("item_id", "")) == "pig",
		"non-pig item should be rejected from a parent slot"
	)
	_main._handle_escape()
	_check(not _main.hud.nest_ui.visible, "Escape should close the nest UI")


func _test_hammer_blocks() -> void:
	var pigs: Array = _main.pigs
	_main._select_pig(pigs[0])
	var objects: WorldObjects = _main.world_objects
	var plank_cell := Vector2i(2, 12)
	objects.place_plank(plank_cell)
	var planks_before: int = pigs[0].inventory.get_total_count("planks")
	_main._use_hammer(plank_cell)
	_check(not objects.has_plank(plank_cell), "hammer should remove a plank block")
	_check(
		pigs[0].inventory.get_total_count("planks") == planks_before + 1,
		"hammering a plank block should recover one plank"
	)

	var fence_cell := Vector2i(3, 12)
	objects.place_fence(fence_cell)
	var fences_before: int = pigs[0].inventory.get_total_count("fence")
	_main._use_hammer(fence_cell)
	_check(not objects.has_fence(fence_cell), "hammer should remove a fence")
	_check(
		pigs[0].inventory.get_total_count("fence") == fences_before + 1,
		"hammering a fence should recover one fence"
	)

	var chest_cell := Vector2i(4, 12)
	objects.place_chest(chest_cell)
	_main._use_hammer(chest_cell)
	_check(not objects.has_chest(chest_cell), "hammer should remove an empty chest")
	var blocked_chest_cell := Vector2i(5, 12)
	var blocked_chest := objects.place_chest(blocked_chest_cell)
	blocked_chest.add_item("wood", 1)
	_main._use_hammer(blocked_chest_cell)
	_check(objects.has_chest(blocked_chest_cell), "hammer should not destroy a non-empty chest")

	var nest_root := Vector2i(10, 12)
	var hammer_nest := objects.place_nest(nest_root)
	_check(not hammer_nest.is_empty(), "second pig nest should be placeable for hammer test")
	_main._use_hammer(nest_root + Vector2i(1, 1))
	_check(not objects.has_nest(nest_root), "hammer should remove an empty pig nest")


func _test_interaction_range() -> void:
	var pigs: Array = _main.pigs
	_main._select_pig(pigs[0])
	pigs[0].inventory.select_slot(0)
	_check(pigs[0].inventory.get_held_item_id() == "hoe", "pig 1 should hold the hoe")
	_check(pigs[0]._held_badge.visible, "pig should show a held-item badge")

	var far_cell := Vector2i(4, 0)
	_main._apply_pointer_action(far_cell, false)
	_check(not _main.farm.is_tilled(far_cell), "distance 4 should be rejected")

	var near_cell := Vector2i(3, 0)
	_main._apply_pointer_action(near_cell, false)
	_check(_main.farm.is_tilled(near_cell), "distance 3 should be allowed")

	var diagonal_cell := Vector2i(3, 3)
	_main._apply_pointer_action(diagonal_cell, false)
	_check(_main.farm.is_tilled(diagonal_cell), "Chebyshev distance 3 diagonally should be allowed")


func _test_pig_capture_and_place() -> void:
	var pigs: Array = _main.pigs
	var target_pig: Pig = pigs[1]
	var target_name := target_pig.display_name
	var target_rgb: Vector3i = target_pig.pig_rgb
	_main._select_pig(pigs[0])
	pigs[0].inventory.clear_selection()
	target_pig.inventory.add_item("wood", 3)
	target_pig.stun()
	_check(target_pig.is_stunned, "hammered pig should be stunned")

	_main._pickup_pig(target_pig)
	_check(pigs.size() == 2, "picking up a pig should remove it from the world")
	var pig_slot := -1
	for index in pigs[0].inventory.slot_count:
		if str(pigs[0].inventory.get_slot(index).get("item_id", "")) == "pig":
			pig_slot = index
			break
	_check(pig_slot >= 0, "captured pig should appear in the bag as an item")
	if pig_slot < 0:
		return
	pigs[0].inventory.select_slot(pig_slot)
	_check(pigs[0].inventory.get_held_item_id() == "pig", "captured pig item should be holdable")

	_main._place_pig(Vector2i(2, 2))
	_check(pigs.size() == 3, "placing a pig should add it back to the world")
	var placed: Pig = pigs[pigs.size() - 1]
	_check(not placed.is_stunned, "placed pig should wake up")
	_check(placed.display_name == target_name, "placed pig should keep its name")
	_check(placed.pig_rgb == target_rgb, "placed pig should keep its RGB")
	_check(placed.inventory.get_total_count("wood") == 3, "placed pig should keep its backpack contents")
	_check(_main.grid.world_to_cell(placed.global_position) == Vector2i(2, 2), "pig should occupy its cell")


func _test_map_zoom() -> void:
	var before: float = _main.camera.zoom.x
	_main._zoom_map(true)
	_check(_main.camera.zoom.x > before, "wheel-up should zoom the map in")
	_check(_main.hud._map_zoom > 1.0, "HUD should receive the new map zoom")
	_main._zoom_map(false)
	_check(absf(_main.camera.zoom.x - before) < 0.001, "wheel-down should restore the previous zoom")
	_main._deselect_pig()


func _test_pig_path_blocking() -> void:
	var pigs: Array = _main.pigs
	_main._select_pig(pigs[0])
	var original_position: Vector2 = pigs[1].global_position
	pigs[1].global_position = _main.grid.cell_to_world_center(Vector2i(4, 8))
	_check(_main._is_path_blocked(Vector2i(4, 8)), "another pig's cell should block pathfinding")
	var path: Array = _main._find_path_to_cell(Vector2i(0, 8), Vector2i(8, 8))
	_check(not path.is_empty(), "path around another pig should exist")
	_check(not path.has(Vector2i(4, 8)), "path should not pass through another pig")
	_check(
		_main._find_path_to_cell(Vector2i(0, 8), Vector2i(4, 8)).is_empty(),
		"pathfinding should refuse another pig's cell"
	)
	pigs[1].global_position = original_position


func _test_auto_move() -> void:
	var pigs: Array = _main.pigs
	pigs[0].move_speed = 5000.0
	var target := Vector2i(7, 5)
	_main._start_auto_action(target, "hoe")
	await get_tree().create_timer(1.2).timeout
	_check(_main.farm.is_tilled(target), "out-of-range action should auto-move and then till the target")
	_check(_main._is_in_interaction_range(target), "auto-move should stop within interaction range")
	_check(_main._path_queue.is_empty(), "auto-move path should finish")
	_check(
		_main.grid.world_to_cell(pigs[0].global_position) != Vector2i.ZERO,
		"pig should physically move toward an out-of-range target"
	)


func _test_auto_open_chest() -> void:
	var pigs: Array = _main.pigs
	pigs[0].move_speed = 8000.0
	var chest_cell := Vector2i(0, 14)
	_check(not _main._is_in_interaction_range(chest_cell), "chest should start out of range")
	_main._start_auto_action(chest_cell, "", "open_chest")
	await get_tree().create_timer(2.0).timeout
	_check(_main.hud.chest_ui.visible, "out-of-range chest should auto-approach and open")
	_check(_main._is_in_interaction_range(chest_cell), "pig should stop within chest interaction range")
	_main.hud.close_chest()


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
