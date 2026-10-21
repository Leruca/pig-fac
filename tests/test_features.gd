extends Node
## 新增资源/方块/熔炉的功能测试。

var _failures: Array[String] = []


func _ready() -> void:
	_test_stone_node()
	_test_worldgen_stone()
	_test_placed_blocks_and_furnace()
	_test_furnace_smelting()
	_test_furnace_shift()
	_test_recipes()
	_test_tool_recipes()
	_test_production_line()
	if _failures.is_empty():
		print("FEATURE TESTS PASSED: stone, blocks, furnace, tools, production line.")
		get_tree().quit(0)
	else:
		for failure in _failures:
			push_error("FEATURE TEST FAILED: " + failure)
		get_tree().quit(1)


func _test_stone_node() -> void:
	var world := WorldObjects.new()
	add_child(world)
	var cell := Vector2i(2, 2)
	var hp := 7
	var amount := 23
	world.place_natural_block(cell, ChunkData.KIND_ROCK, hp, amount)
	var collected := 0
	for index in hp:
		var hit := world.hit_natural_block(cell)
		collected += int(hit.get("stone_yield", 0))
		if index < hp - 1:
			_check(not bool(hit.get("destroyed", true)), "stone node should survive until last hit")
	_check(collected == amount, "stone node should yield exactly its stored amount (%d != %d)" % [collected, amount])
	_check(not world.has_natural_block(cell), "stone node should disappear after last hit")
	world.queue_free()


func _test_worldgen_stone() -> void:
	var config := WorldGenConfig.load_default()
	var generator := WorldGenerator.new(config, 13579)
	var data := generator.generate_chunk(Vector2i(0, 0))
	var stone_count := 0
	for obstacle in data.obstacles:
		if int(obstacle["kind"]) != ChunkData.KIND_ROCK:
			continue
		stone_count += 1
		_check(
			int(obstacle["hp"]) >= config.rock_hp_min
			and int(obstacle["hp"]) <= config.rock_hp_max,
			"generated ordinary stone hp should be within 6..10"
		)
		_check(
			int(obstacle["stone_amount"]) >= config.rock_amount_min
			and int(obstacle["stone_amount"]) <= config.rock_amount_max,
			"generated ordinary stone amount should be within 16..30"
		)
	_check(stone_count > 0, "chunk (0,0) should contain generated ordinary stones")


func _test_placed_blocks_and_furnace() -> void:
	var world := WorldObjects.new()
	add_child(world)
	_check(world.place_placed_block(Vector2i(3, 3), "stone"), "stone block should be placeable")
	_check(world.is_blocked(Vector2i(3, 3)), "placed stone should block movement")
	_check(not world.place_placed_block(Vector2i(3, 3), "stone_brick"), "occupied cell should reject a second block")
	_check(world.remove_placed_block(Vector2i(3, 3)), "placed stone should be removable")
	var furnace := world.place_furnace(Vector2i(4, 4))
	_check(not furnace.is_empty(), "furnace should be placeable")
	_check(world.is_blocked(Vector2i(4, 4)), "furnace should occupy its cell")
	_check(world.remove_furnace(Vector2i(4, 4)), "furnace should be removable")
	world.queue_free()


func _test_furnace_smelting() -> void:
	var world := WorldObjects.new()
	add_child(world)
	var furnace := world.place_furnace(Vector2i(5, 5))
	_check(not furnace.is_empty(), "2x2 furnace should be placeable")
	var inventory: Inventory = furnace["inventory"]
	inventory.add_item("copper_ore", 1)
	for index in 12:
		world._advance_furnaces(0.5)
	_check(inventory.get_slot(WorldObjects.FURNACE_SLOT_OUTPUT).is_empty(), "furnace must not smelt without fuel")
	_check(float(world.get_furnace(Vector2i(5, 5)).get("smelt_progress", 0.0)) == 0.0, "furnace progress must reset without fuel")
	inventory.add_item("wood", 1)
	for index in 11:
		world._advance_furnaces(0.5)
	var output := inventory.get_slot(WorldObjects.FURNACE_SLOT_OUTPUT)
	_check(str(output.get("item_id", "")) == "copper_ingot", "furnace should smelt copper ore into copper ingot")
	_check(int(output.get("count", 0)) == 1, "furnace should produce exactly one ingot")
	_check(inventory.get_slot(WorldObjects.FURNACE_SLOT_INPUT).is_empty(), "furnace should consume one ore")
	_check(world.get_furnace_root(Vector2i(6, 6)) == Vector2i(5, 5), "2x2 furnace should occupy all four cells")
	world.queue_free()


func _test_furnace_shift() -> void:
	var world := WorldObjects.new()
	add_child(world)
	var furnace := world.place_furnace(Vector2i(9, 9))
	var furnace_inventory: Inventory = furnace["inventory"]
	var bag := Inventory.new(40)
	bag.add_item("copper_ore", 1)
	bag.add_item("wood", 1)
	var ui := FurnaceUI.new()
	add_child(ui)
	ui.setup(furnace, "test")
	ui.set_bag_inventory(bag)
	_check(ui.try_auto_store_from_inventory(bag, 0), "shift should route ore into furnace input")
	_check(furnace_inventory.get_total_count("copper_ore") == 1, "furnace input should receive shifted ore")
	_check(ui.try_auto_store_from_inventory(bag, 1), "shift should route fuel into furnace fuel slot")
	_check(furnace_inventory.get_total_count("wood") == 1, "furnace fuel should receive shifted wood")
	ui.queue_free()
	world.queue_free()


func _test_recipes() -> void:
	var inventory := Inventory.new(40)
	inventory.add_item("stone", 8)
	var brick_recipe := Crafting.RECIPES[Crafting.RECIPES.size() - 2]
	_check(Crafting.craft(inventory, brick_recipe), "stone -> stone brick recipe should craft")
	_check(inventory.get_total_count("stone_brick") == 2, "4 stone should produce 2 stone bricks")
	var furnace_recipe := Crafting.RECIPES[Crafting.RECIPES.size() - 1]
	_check(not Crafting.craft(inventory, furnace_recipe), "furnace recipe should require 4 stone bricks")
	inventory.add_item("stone_brick", 2)
	_check(Crafting.craft(inventory, furnace_recipe), "4 stone bricks should craft a furnace")
	_check(inventory.get_total_count("furnace") == 1, "crafted furnace should enter the inventory")
	_check(WorldObjects.FURNACE_FUEL_SECONDS.has("wood"), "wood should be a furnace fuel")
	_check(WorldObjects.FURNACE_FUEL_SECONDS.has("planks"), "planks should be a furnace fuel")
	_check(WorldObjects.FURNACE_FUEL_SECONDS.has("coal"), "coal should be a furnace fuel")
	_check(
		float(WorldObjects.FURNACE_FUEL_SECONDS["wood"]) != float(WorldObjects.FURNACE_FUEL_SECONDS["coal"]),
		"different fuels should have different burn times"
	)


func _test_tool_recipes() -> void:
	var expectations := {
		"hoe": {"stick": 2, "stone": 2},
		"shovel": {"stick": 2, "stone": 3},
		"hammer": {"stick": 3, "stone": 4},
		"super_watering_can": {"copper_ingot": 4, "stick": 2},
	}
	for tool_id in expectations.keys():
		var recipe := _find_recipe(str(tool_id))
		_check(not recipe.is_empty(), "tool recipe %s should exist" % tool_id)
		if recipe.is_empty():
			continue
		var inventory := Inventory.new(40)
		_check(not Crafting.craft(inventory, recipe), "%s recipe should need materials" % tool_id)
		var ingredients: Dictionary = expectations[tool_id]
		for item_id in ingredients.keys():
			inventory.add_item(str(item_id), int(ingredients[item_id]))
		_check(Crafting.craft(inventory, recipe), "%s recipe should craft with materials" % tool_id)
		_check(inventory.get_total_count(str(tool_id)) == 1, "crafted %s should enter inventory" % tool_id)


func _test_production_line() -> void:
	var world := WorldObjects.new()
	add_child(world)
	for recipe_id in ["roller", "press", "assembler"]:
		var recipe := _find_recipe(str(recipe_id))
		_check(not recipe.is_empty(), "%s machine recipe should exist" % recipe_id)
		var inventory := Inventory.new(40)
		var ingredients: Dictionary = recipe.get("ingredients", {})
		for item_id in ingredients.keys():
			inventory.add_item(str(item_id), int(ingredients[item_id]))
		_check(Crafting.craft(inventory, recipe), "%s machine recipe should craft" % recipe_id)
		_check(inventory.get_total_count(str(recipe_id)) == 1, "%s machine should enter inventory" % recipe_id)

	var roller_cell := Vector2i(1, 1)
	var press_cell := Vector2i(4, 1)
	var assembler_cell := Vector2i(7, 1)
	_check(not world.place_machine(roller_cell, "roller").is_empty(), "roller should be placeable")
	_check(not world.place_machine(press_cell, "press").is_empty(), "press should be placeable")
	_check(not world.place_machine(assembler_cell, "assembler").is_empty(), "assembler should be placeable")
	_check(world.get_machine_root(assembler_cell) == Vector2i(6, 0), "3x3 assembler should center on mouse cell")
	_check(world.is_blocked(Vector2i(8, 2)), "3x3 assembler should occupy its far corner")

	var workshop := Inventory.new(40)
	workshop.add_item("iron_ingot", 1)
	var rolled := world.process_machine(roller_cell, workshop)
	_check(bool(rolled.get("ok", false)), "roller should process iron ingot")
	_check(workshop.get_total_count("iron_plate") == 1, "roller should output iron plate")
	var pressed := world.process_machine(press_cell, workshop)
	_check(bool(pressed.get("ok", false)), "press should process iron plate")
	_check(workshop.get_total_count("iron_wire") == 2, "press should output two iron wires")

	workshop.add_item("iron_plate", 4)
	workshop.add_item("copper_wire", 8)
	workshop.add_item("stick", 4)
	var assembled := world.process_machine(assembler_cell, workshop)
	_check(bool(assembled.get("ok", false)), "assembler should build pig generator")
	_check(workshop.get_total_count("pig_generator") == 1, "assembly should output pig generator")
	workshop.add_item("iron_plate", 6)
	workshop.add_item("copper_wire", 6)
	workshop.add_item("chest", 1)
	var meat_assembled := world.process_machine(assembler_cell, workshop)
	_check(bool(meat_assembled.get("ok", false)), "assembler should build meat storage")
	_check(workshop.get_total_count("meat_storage") == 1, "assembly should output meat storage")

	var generator_cell := Vector2i(1, 6)
	var meat_cell := Vector2i(4, 6)
	world.place_machine(generator_cell, "pig_generator")
	world.place_machine(meat_cell, "meat_storage")
	_check(world.get_machine_root(meat_cell) == Vector2i(3, 5), "3x3 meat storage should center on mouse cell")
	var pigs := Inventory.new(40)
	pigs.add_item("pig", 2)
	_check(world.insert_pig_into_machine(generator_cell, pigs), "generator should accept a pig")
	world._advance_machines(10.0)
	_check(world.get_machine(generator_cell).get("power", 0.0) >= 20.0, "generator should build power")
	_check(world.insert_pig_into_machine(meat_cell, pigs), "meat storage should accept a pig")
	world._advance_machines(6.2)
	var meat_machine := world.get_machine(meat_cell)
	var output: Dictionary = meat_machine.get("output", {})
	_check(str(output.get("item_id", "")) == "fresh_meat", "meat storage should produce fresh meat")
	_check(int(output.get("count", 0)) == 2, "meat storage should produce two fresh meat")
	_check(world.collect_machine_output(meat_cell, pigs), "produced meat should be collectable")
	_check(pigs.get_total_count("fresh_meat") == 2, "fresh meat should enter bag")
	world.queue_free()


func _find_recipe(recipe_id: String) -> Dictionary:
	for recipe in Crafting.RECIPES:
		if str(recipe.get("id", "")) == recipe_id:
			return recipe
	return {}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
