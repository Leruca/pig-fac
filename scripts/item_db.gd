extends Node
## 全局物品定义。
##
## 物品只在这里登记一次，背包、UI、农田和后续的掉落/合成系统都通过它读取数据。
## 新物品只需要补充一条定义与一个图标文件。

const DEFAULT_MAX_STACK := 64

const ITEMS: Dictionary = {
	"hoe": {
		"name": "锄头",
		"description": "把普通草地锄成可以种植的耕地。",
		"icon_path": "res://assets/hoe.svg",
		"max_stack": 1,
		"kind": "tool",
		"tool_action": "till",
	},
	"super_watering_can": {
		"name": "超级水壶",
		"description": "对着作物使用，立刻催熟一个生长阶段。",
		"icon_path": "res://assets/watering_can.svg",
		"max_stack": 1,
		"kind": "tool",
		"tool_action": "water",
	},
	"shovel": {
		"name": "铲子",
		"description": "把耕地铲平，恢复成普通草地。",
		"icon_path": "res://assets/shovel.svg",
		"max_stack": 1,
		"kind": "tool",
		"tool_action": "flatten",
	},
	"hammer": {
		"name": "锤子",
		"description": "敲倒树木获取木头，也能把地上的木头收回背包。",
		"icon_path": "res://assets/hammer.svg",
		"max_stack": 1,
		"kind": "tool",
		"tool_action": "hammer",
	},
	"wood": {
		"name": "木头",
		"description": "可以放在地上占据一整格，也能用锤子收回。",
		"icon_path": "res://assets/wood.svg",
		"max_stack": 64,
		"kind": "material",
	},
	"sapling": {
		"name": "树苗",
		"description": "种在平地上，约 90 秒后长成 3×3 大树，可以用超级水壶催熟。",
		"icon_path": "res://assets/sapling.svg",
		"max_stack": 64,
		"kind": "sapling",
	},
	"planks": {
		"name": "木板",
		"description": "由木头加工得到的基础建材。",
		"icon_path": "res://assets/planks.svg",
		"max_stack": 64,
		"kind": "material",
	},
	"stick": {
		"name": "木棍",
		"description": "细长的木棍，可以继续加工成栅栏。",
		"icon_path": "res://assets/stick.svg",
		"max_stack": 64,
		"kind": "material",
	},
	"chest": {
		"name": "箱子",
		"description": "放在地上的 40 格储物箱，右键打开。",
		"icon_path": "res://assets/chest.svg",
		"max_stack": 64,
		"kind": "chest",
	},
	"fence": {
		"name": "木栅栏",
		"description": "占满一格的木栅栏，会自动连接相邻的栅栏和方块。",
		"icon_path": "res://assets/fence.svg",
		"max_stack": 64,
		"kind": "fence",
	},
	"pig": {
		"name": "猪",
		"description": "被捡起的猪。右键平地放下，它会醒来，原来的背包也会保留。",
		"icon_path": "res://assets/pig.svg",
		"max_stack": 1,
		"kind": "pig",
	},
	"pig_nest": {
		"name": "猪窝",
		"description": "3×3 的繁育猪窝：两只亲代猪 + 10 食物 → 10 秒后产出新猪。",
		"icon_path": "res://assets/pig_nest.svg",
		"max_stack": 64,
		"kind": "nest",
	},
	"potato": {
		"name": "土豆",
		"description": "圆滚滚的土豆，也是可以种下的种薯。",
		"icon_path": "res://assets/potato.svg",
		"max_stack": 64,
		"kind": "crop",
		"growth_stage_seconds": 30.0,
		"mature_stage": 3,
		"yield_min": 2,
		"yield_max": 3,
	},
	"carrot": {
		"name": "胡萝卜",
		"description": "脆生生的胡萝卜，成熟后会从土里露出橙色肩膀。",
		"icon_path": "res://assets/carrot.svg",
		"max_stack": 64,
		"kind": "crop",
		"growth_stage_seconds": 30.0,
		"mature_stage": 3,
		"yield_min": 2,
		"yield_max": 3,
	},
}

var _icon_cache: Dictionary = {}


func get_item(item_id: String) -> Dictionary:
	return ITEMS.get(item_id, {})


func has_item(item_id: String) -> bool:
	return ITEMS.has(item_id)


func get_display_name(item_id: String) -> String:
	var item := get_item(item_id)
	return str(item.get("name", item_id))


func get_description(item_id: String) -> String:
	var item := get_item(item_id)
	return str(item.get("description", ""))


func get_max_stack(item_id: String) -> int:
	var item := get_item(item_id)
	return maxi(1, int(item.get("max_stack", DEFAULT_MAX_STACK)))


func get_kind(item_id: String) -> String:
	return str(get_item(item_id).get("kind", "misc"))


func is_crop(item_id: String) -> bool:
	return get_kind(item_id) == "crop"


func is_tool(item_id: String) -> bool:
	return get_kind(item_id) == "tool"


func get_tool_action(item_id: String) -> String:
	return str(get_item(item_id).get("tool_action", ""))


func get_growth_stage_seconds(item_id: String) -> float:
	return maxf(0.1, float(get_item(item_id).get("growth_stage_seconds", 30.0)))


func get_mature_stage(item_id: String) -> int:
	return maxi(1, int(get_item(item_id).get("mature_stage", 3)))


func get_yield_range(item_id: String) -> Vector2i:
	var item := get_item(item_id)
	return Vector2i(
		maxi(0, int(item.get("yield_min", 2))),
		maxi(0, int(item.get("yield_max", 3)))
	)


func get_icon(item_id: String) -> Texture2D:
	var item := get_item(item_id)
	var path := str(item.get("icon_path", ""))
	if path.is_empty():
		return null
	if not _icon_cache.has(path):
		var loaded := load(path)
		_icon_cache[path] = loaded as Texture2D
	return _icon_cache[path] as Texture2D
