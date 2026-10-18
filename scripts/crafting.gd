class_name Crafting
extends RefCounted
## 合成配方与事务式合成逻辑。
##
## 木头 → 木板 → 木棍 / 箱子，木棍 → 木栅栏。配方按用户给定数量：
## 1 木头 = 4 木板，2 木板 = 4 木棍，8 木板 = 1 箱子，
## 2 木棍 + 4 木棍 = 1 木栅栏（共 6 木棍）。

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
