class_name Crafting
extends RefCounted
## 合成配方与事务式合成逻辑。
##
## 木头 → 木板 → 木棍 / 箱子，木棍 → 木栅栏；木棍 + 石头可合成基础工具。
## 1 木头 = 4 木板，2 木板 = 4 木棍，8 木板 = 1 箱子，
## 2 木棍 + 4 木棍 = 1 木栅栏（共 6 木棍）。
## 锄头/铲子/锤子用木棍 + 石头；超级水壶需要铜锭。
## 辊压机/冲压机/装配台也在这里合成；最终发电机和肉肉仓在装配台加工。

const RECIPES: Array[Dictionary] = [
	{
		"id": "planks",
		"output": "planks",
		"output_amount": 4,
		"ingredients": {"wood": 1},
	},
	{
		"id": "sticks",
		"output": "stick",
		"output_amount": 4,
		"ingredients": {"planks": 2},
	},
	{
		"id": "chest",
		"output": "chest",
		"output_amount": 1,
		"ingredients": {"planks": 8},
	},
	{
		"id": "fence",
		"output": "fence",
		"output_amount": 1,
		"ingredients": {"stick": 6},
	},
	{
		"id": "pig_nest",
		"output": "pig_nest",
		"output_amount": 1,
		"ingredients": {"wood": 4, "planks": 4, "chest": 1},
	},
	{
		"id": "hoe",
		"output": "hoe",
		"output_amount": 1,
		"ingredients": {"stick": 2, "stone": 2},
	},
	{
		"id": "shovel",
		"output": "shovel",
		"output_amount": 1,
		"ingredients": {"stick": 2, "stone": 3},
	},
	{
		"id": "hammer",
		"output": "hammer",
		"output_amount": 1,
		"ingredients": {"stick": 3, "stone": 4},
	},
	{
		"id": "super_watering_can",
		"output": "super_watering_can",
		"output_amount": 1,
		"ingredients": {"copper_ingot": 4, "stick": 2},
	},
	{
		"id": "roller",
		"output": "roller",
		"output_amount": 1,
		"ingredients": {"iron_ingot": 2, "stick": 2, "stone": 4},
	},
	{
		"id": "press",
		"output": "press",
		"output_amount": 1,
		"ingredients": {"iron_ingot": 2, "copper_ingot": 2, "stick": 2, "stone": 2},
	},
	{
		"id": "assembler",
		"output": "assembler",
		"output_amount": 1,
		"ingredients": {"planks": 8, "iron_ingot": 2, "stone": 2},
	},
	{
		"id": "stone_brick",
		"output": "stone_brick",
		"output_amount": 2,
		"ingredients": {"stone": 4},
	},
	{
		"id": "furnace",
		"output": "furnace",
		"output_amount": 1,
		"ingredients": {"stone_brick": 4},
	},
]


static func can_craft(inventory: Inventory, recipe: Dictionary) -> bool:
	if inventory == null:
		return false
	return inventory.can_remove_items(recipe.get("ingredients", {}))


static func craft(inventory: Inventory, recipe: Dictionary) -> bool:
	if not can_craft(inventory, recipe):
		return false
	var ingredients: Dictionary = recipe.get("ingredients", {})
	if not inventory.remove_items(ingredients):
		return false

	var output_id := str(recipe.get("output", ""))
	var output_amount := int(recipe.get("output_amount", 1))
	if not inventory.can_add_item(output_id, output_amount):
		# 输出放不下时退还材料，避免凭空损失。
		for item_id in ingredients.keys():
			inventory.add_item(str(item_id), int(ingredients[item_id]))
		return false

	inventory.add_item(output_id, output_amount)
	return true
