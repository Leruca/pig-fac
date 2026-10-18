extends Node
## 无界面背包逻辑测试。
## 运行：godot --headless --path . res://tests/test_inventory.tscn

var _failures: Array[String] = []


func _ready() -> void:
	_test_item_database()
	_test_initial_potato()
	_test_stacking_and_overflow()
	_test_unknown_item()
	_test_full_capacity()
	_test_selection_and_consumption()
	_test_capacity_helpers()
	_test_inventory_transfers()
	_test_crafting()
	_test_pig_item_metadata()

	if _failures.is_empty():
		print("INVENTORY TESTS PASSED: 40 slots, 64 stack, transfers, crafting, pig metadata.")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error("INVENTORY TEST FAILED: " + failure)
		get_tree().quit(1)


func _test_item_database() -> void:
	_check(ItemDB.has_item("potato"), "potato should exist in ItemDB")
	_check(ItemDB.has_item("carrot"), "carrot should exist in ItemDB")
	_check(ItemDB.get_max_stack("potato") == 64, "potato max stack should be 64")
	_check(ItemDB.get_max_stack("carrot") == 64, "carrot max stack should be 64")
	_check(ItemDB.get_max_stack("hoe") == 1, "hoe should not stack")
	_check(ItemDB.get_max_stack("super_watering_can") == 1, "watering can should not stack")
	_check(ItemDB.get_max_stack("shovel") == 1, "shovel should not stack")
	_check(ItemDB.get_max_stack("hammer") == 1, "hammer should not stack")
	_check(ItemDB.get_max_stack("wood") == 64, "wood should stack to 64")
	_check(ItemDB.has_item("sapling"), "sapling should exist in ItemDB")
	_check(ItemDB.get_max_stack("sapling") == 64, "sapling should stack to 64")
	_check(ItemDB.get_kind("sapling") == "sapling", "sapling should have the sapling kind")
	_check(ItemDB.is_crop("potato"), "potato should be a crop")
	_check(ItemDB.is_crop("carrot"), "carrot should be a crop")
	_check(ItemDB.get_tool_action("hoe") == "till", "hoe should till soil")
	_check(ItemDB.get_tool_action("super_watering_can") == "water", "watering can should water crops")
	_check(ItemDB.get_tool_action("shovel") == "flatten", "shovel should flatten farmland")
	_check(ItemDB.get_tool_action("hammer") == "hammer", "hammer should have the hammer action")
	_check(ItemDB.get_kind("wood") == "material", "wood should be a material")
	_check(ItemDB.get_kind("planks") == "material", "planks should be a material")
	_check(ItemDB.get_kind("stick") == "material", "stick should be a material")
	_check(ItemDB.get_kind("chest") == "chest", "chest should be a chest item")
	_check(ItemDB.get_kind("fence") == "fence", "fence should be a fence item")
	_check(ItemDB.get_kind("pig") == "pig", "pig should be a pig item")
	_check(ItemDB.get_max_stack("pig") == 1, "pig item should not stack")
	_check(ItemDB.get_kind("pig_nest") == "nest", "pig nest should be a nest item")
	_check(ItemDB.get_max_stack("pig_nest") == 64, "pig nest should stack to 64")
	_check(not ItemDB.get_display_name("potato").is_empty(), "potato should have a display name")


func _test_initial_potato() -> void:
	var inventory := Inventory.new(40)
	var leftover := inventory.add_item("potato", 12)
	_check(inventory.slot_count == 40, "inventory should have exactly 40 slots")
	_check(leftover == 0, "12 potatoes should fit")
	_check(inventory.get_used_slot_count() == 1, "initial potato should use one slot")
	_check(inventory.get_total_count("potato") == 12, "initial potato count should be 12")
	_check(int(inventory.get_slot(0).get("count", 0)) == 12, "first slot should hold 12 potatoes")


func _test_stacking_and_overflow() -> void:
	var inventory := Inventory.new(40)
	inventory.add_item("potato", 12)
	var leftover := inventory.add_item("potato", 60)
	_check(leftover == 0, "60 additional potatoes should fit")
	_check(int(inventory.get_slot(0).get("count", 0)) == 64, "first stack should cap at 64")
	_check(int(inventory.get_slot(1).get("count", 0)) == 8, "overflow should continue in second slot")
	_check(inventory.get_used_slot_count() == 2, "72 potatoes should use two slots")
	_check(inventory.get_total_count("potato") == 72, "total should be 72")


func _test_unknown_item() -> void:
	var inventory := Inventory.new(40)
	var leftover := inventory.add_item("missing_item", 5)
	_check(leftover == 5, "unknown items should not enter the inventory")
	_check(inventory.is_empty(), "unknown item should leave inventory empty")


func _test_full_capacity() -> void:
	var inventory := Inventory.new(40)
	var capacity := 40 * 64
	var leftover := inventory.add_item("potato", capacity + 10)
	_check(leftover == 10, "inventory should reject exactly the overflow")
	_check(inventory.get_used_slot_count() == 40, "full inventory should use all 40 slots")
	_check(inventory.get_total_count("potato") == capacity, "full inventory should hold 2560 potatoes")
	_check(int(inventory.get_slot(0).get("count", 0)) == 64, "each slot should cap at 64")


func _test_selection_and_consumption() -> void:
	var inventory := Inventory.new(40)
	inventory.add_item("potato", 12)
	inventory.add_item("hoe", 1)
	inventory.add_item("carrot", 6)

	inventory.select_slot(0)
	_check(inventory.selected_index == 0, "selecting an occupied slot should set the held slot")
	_check(inventory.get_held_item_id() == "potato", "held item should be potato")
	_check(inventory.get_held_count() == 12, "held count should be 12")

	_check(inventory.consume_selected(1), "consuming one seed should succeed")
	_check(inventory.get_held_count() == 11, "seed consumption should reduce the held stack")
	_check(inventory.selected_index == 0, "held slot should remain selected while seeds remain")

	inventory.select_slot(1)
	_check(inventory.get_held_item_id() == "hoe", "held item should switch to hoe")
	inventory.select_slot(0)
	_check(inventory.consume_selected(11), "consuming the rest of the stack should succeed")
	_check(inventory.selected_index == -1, "held item should clear when the last seed is consumed")
	_check(inventory.get_held_item_id().is_empty(), "cleared selection should mean empty hand")
	_check(inventory.get_slot(0).is_empty(), "empty stack should clear its slot")


func _test_capacity_helpers() -> void:
	var inventory := Inventory.new(40)
	inventory.add_item("potato", 64)
	inventory.add_item("carrot", 10)
	var expected_potato_space := 38 * 64
	_check(
		inventory.get_free_capacity("potato") == expected_potato_space,
		"capacity should count only empty slots and matching partial stacks"
	)
	var expected_carrot_space := (64 - 10) + 38 * 64
	_check(
		inventory.get_free_capacity("carrot") == expected_carrot_space,
		"capacity should include the partial carrot stack"
	)
	_check(inventory.can_add_item("carrot", expected_carrot_space), "all free capacity should be usable")
	_check(not inventory.can_add_item("carrot", expected_carrot_space + 1), "over-capacity should be rejected")


func _test_inventory_transfers() -> void:
	var source := Inventory.new(40)
	var target := Inventory.new(40)
	source.add_item("wood", 10)
	source.add_item("hoe", 1)
	source.add_item("potato", 60)
	source.add_item("potato", 10)
	source.select_slot(0)

	_check(source.can_remove_item("wood", 4), "enough wood should be removable")
	_check(source.remove_item("wood", 4), "removing wood should succeed")
	_check(source.get_total_count("wood") == 6, "wood should be removed across the inventory")
	_check(not source.remove_item("wood", 99), "over-removal should fail atomically")
	_check(source.get_total_count("wood") == 6, "failed removal should not consume wood")

	_check(source.move_stack_to(target, 0, 0), "stack should move to another inventory")
	_check(source.get_slot(0).is_empty(), "source slot should empty after moving")
	_check(target.get_total_count("wood") == 6, "target should receive the stack")
	_check(source.selected_index == -1, "moving the selected stack away should clear held selection")

	var merge_source := Inventory.new(40)
	merge_source.slots[0] = {"item_id": "potato", "count": 60}
	merge_source.slots[1] = {"item_id": "potato", "count": 10}
	_check(merge_source.move_stack_to(merge_source, 1, 0), "same-item stacks should merge")
	_check(int(merge_source.get_slot(0).get("count", 0)) == 64, "merge should fill the target stack")
	_check(int(merge_source.get_slot(1).get("count", 0)) == 6, "merge should leave the remainder")

	var swap_source := Inventory.new(40)
	swap_source.add_item("wood", 3)
	swap_source.add_item("hoe", 1)
	swap_source.select_slot(0)
	_check(swap_source.move_stack_to(swap_source, 0, 1), "different items should swap")
	_check(swap_source.get_held_item_id() == "hoe", "selected slot should show the swapped-in item")
	_check(swap_source.get_total_count("wood") == 3, "swap should preserve both stacks")


func _test_crafting() -> void:
	var inventory := Inventory.new(40)
	inventory.add_item("wood", 2)
	var planks_recipe: Dictionary = Crafting.RECIPES[0]
	_check(Crafting.can_craft(inventory, planks_recipe), "wood should be enough for planks")
	_check(Crafting.craft(inventory, planks_recipe), "wood should craft into planks")
	_check(inventory.get_total_count("wood") == 1, "crafting should consume one wood")
	_check(inventory.get_total_count("planks") == 4, "one wood should make four planks")

	var sticks_recipe: Dictionary = Crafting.RECIPES[1]
	_check(Crafting.craft(inventory, sticks_recipe), "planks should craft into sticks")
	_check(inventory.get_total_count("planks") == 2, "sticks should consume two planks")
	_check(inventory.get_total_count("stick") == 4, "two planks should make four sticks")

	inventory.add_item("planks", 8)
	var chest_recipe: Dictionary = Crafting.RECIPES[2]
	_check(Crafting.craft(inventory, chest_recipe), "eight planks should craft a chest")
	_check(inventory.get_total_count("chest") == 1, "crafting should produce one chest")
	_check(inventory.get_total_count("planks") == 2, "chest recipe should consume eight planks")

	inventory.add_item("stick", 6)
	var fence_recipe: Dictionary = Crafting.RECIPES[3]
	_check(Crafting.can_craft(inventory, fence_recipe), "six sticks should be enough for a fence")
	_check(Crafting.craft(inventory, fence_recipe), "six sticks should craft a fence")
	_check(inventory.get_total_count("fence") == 1, "crafting should produce one fence")
	_check(inventory.get_total_count("stick") == 4, "fence recipe should consume six sticks")

	var empty := Inventory.new(40)
	_check(not Crafting.can_craft(empty, chest_recipe), "missing materials should not be craftable")
	_check(not Crafting.craft(empty, chest_recipe), "crafting without materials should fail")

	# 猪窝：4 木头 + 4 木板 + 1 箱子
	inventory.add_item("wood", 4)
	inventory.add_item("planks", 4)
	var nest_recipe: Dictionary = Crafting.RECIPES[4]
	_check(Crafting.can_craft(inventory, nest_recipe), "nest materials should be enough")
	_check(Crafting.craft(inventory, nest_recipe), "nest should be craftable")
	_check(inventory.get_total_count("pig_nest") == 1, "crafting should produce one pig nest")
	_check(inventory.get_total_count("chest") == 0, "nest recipe should consume the chest")


func _test_pig_item_metadata() -> void:
	var bag := Inventory.new(40)
	var pig_inventory := Inventory.new(40)
	pig_inventory.add_item("wood", 3)
	var pig_stack := {
		"item_id": "pig",
		"count": 1,
		"pig_name": "猪 9",
		"pig_rgb": Vector3i(12, 34, 56),
		"pig_tint": Color(0.7, 0.8, 0.9),
		"pig_inventory": pig_inventory,
	}
	_check(bag.add_item_stack(pig_stack), "pig item stack should fit in an empty slot")
	_check(bag.get_total_count("pig") == 1, "bag should contain one pig item")
	_check(bag.get_slot(0).get("pig_rgb") == Vector3i(12, 34, 56), "pig RGB metadata should persist")
	_check(
		bag.get_slot(0).get("pig_inventory") == pig_inventory,
		"pig inventory reference should be preserved"
	)

	var target := Inventory.new(40)
	_check(bag.move_stack_to(target, 0, 0), "pig item should move between inventories")
	_check(
		target.get_slot(0).get("pig_inventory") == pig_inventory,
		"moving a pig item should keep its inventory"
	)
	_check(
		target.get_slot(0).get("pig_name") == "猪 9",
		"moving a pig item should keep its name"
	)


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
