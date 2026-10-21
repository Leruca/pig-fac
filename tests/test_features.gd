extends Node
## 新增资源/方块/熔炉的功能测试。

var _failures: Array[String] = []


func _ready() -> void:
	_test_stone_node()
	_test_worldgen_stone()
	_test_placed_blocks_and_furnace()
	_test_furnace_smelting()
	_test_recipes()
	_test_tool_recipes()
	if _failures.is_empty():
		print("FEATURE TESTS PASSED: ordinary stone, blocks, furnace smelting, tool recipes.")
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
	var inventory: Inventory = furnace["inventory"]
	inventory.add_item("copper_ore", 1)
	inventory.add_item("wood", 1)
	for index in 11:
		world._advance_furnaces(0.5)
	var output := inventory.get_slot(WorldObjects.FURNACE_SLOT_OUTPUT)
	_check(str(output.get("item_id", "")) == "copper_ingot", "furnace should smelt copper ore into copper ingot")
	_check(int(output.get("count", 0)) == 1, "furnace should produce exactly one ingot")
	_check(inventory.get_slot(WorldObjects.FURNACE_SLOT_INPUT).is_empty(), "furnace should consume one ore")
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


func _find_recipe(recipe_id: String) -> Dictionary:
	for recipe in Crafting.RECIPES:
		if str(recipe.get("id", "")) == recipe_id:
			return recipe
	return {}


func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
