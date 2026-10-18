class_name Inventory
extends RefCounted
## 通用背包数据模型。
##
## 背包只保存数据，不依赖 UI。槽位字典格式：
##   {}                                 空槽
##   {"item_id": "potato", "count": 12} 有物品的槽
##
## 每个槽的堆叠上限来自 ItemDB，普通物品默认 64；工具在 ItemDB 中设为 1。
## 除了增删物品，也支持把整堆物品移动到另一个 Inventory，用于背包/箱子拖拽。

signal changed
signal selection_changed(index: int)

const DEFAULT_SLOT_COUNT := 40

var slot_count: int
var slots: Array[Dictionary] = []
## 当前手持槽位；-1 表示空手。空手才可以用右键移动/收割。
var selected_index := -1


func _init(p_slot_count: int = DEFAULT_SLOT_COUNT) -> void:
	slot_count = maxi(1, p_slot_count)
	slots.resize(slot_count)
	for index in slot_count:
		slots[index] = {}


## 返回放不下的剩余数量。0 表示全部放入。
func add_item(item_id: String, amount: int = 1) -> int:
	if amount <= 0 or not ItemDB.has_item(item_id):
		return amount

	var max_stack := ItemDB.get_max_stack(item_id)
	var remaining := amount

	# 先补已有堆叠，避免背包里出现大量半空槽。
	for index in slot_count:
		if remaining <= 0:
			break
		var slot := slots[index]
		if slot.is_empty() or str(slot.get("item_id", "")) != item_id:
			continue
		var count := int(slot.get("count", 0))
		if count >= max_stack:
			continue
		var moved := mini(max_stack - count, remaining)
		slot["count"] = count + moved
		remaining -= moved

	# 再占用空槽。
	for index in slot_count:
		if remaining <= 0:
			break
		if not slots[index].is_empty():
			continue
		var moved := mini(max_stack, remaining)
		slots[index] = {"item_id": item_id, "count": moved}
		remaining -= moved

	if remaining != amount:
		changed.emit()
	return remaining


func get_slot(index: int) -> Dictionary:
	if index < 0 or index >= slot_count:
		return {}
	return slots[index]


## 放入一个完整堆叠（可带 metadata，例如猪的 RGB 和它自己的背包）。
## 只占用空槽，不合并，避免丢失 metadata。
func add_item_stack(stack: Dictionary) -> bool:
	if stack.is_empty():
		return false
	var item_id := str(stack.get("item_id", ""))
	var count := int(stack.get("count", 0))
	if not ItemDB.has_item(item_id) or count <= 0:
		return false
	if count > ItemDB.get_max_stack(item_id):
		return false
	for index in slot_count:
		if slots[index].is_empty():
			slots[index] = stack.duplicate()
			changed.emit()
			return true
	return false


## 从指定槽扣除数量，用于猪窝消耗食物等定向操作。
func remove_from_slot(index: int, amount: int = 1) -> bool:
	if index < 0 or index >= slot_count or amount <= 0:
		return false
	var slot := slots[index]
	if slot.is_empty() or int(slot.get("count", 0)) < amount:
		return false
	var count := int(slot.get("count", 0)) - amount
	var cleared := count <= 0
	if cleared:
		slots[index] = {}
	else:
		slot["count"] = count
	changed.emit()
	if cleared and selected_index == index:
		selected_index = -1
		selection_changed.emit(-1)
	return true


func get_used_slot_count() -> int:
	var used := 0
	for slot in slots:
		if not slot.is_empty():
			used += 1
	return used


func get_total_count(item_id: String) -> int:
	var total := 0
	for slot in slots:
		if str(slot.get("item_id", "")) == item_id:
			total += int(slot.get("count", 0))
	return total


func is_empty() -> bool:
	return get_used_slot_count() == 0


## 选中一个槽。空槽或越界索引都会变成空手。
func select_slot(index: int) -> void:
	var next_index := -1
	if index >= 0 and index < slot_count and not slots[index].is_empty():
		next_index = index
	if next_index == selected_index:
		return
	selected_index = next_index
	selection_changed.emit(selected_index)


func clear_selection() -> void:
	select_slot(-1)


func get_selected_slot() -> Dictionary:
	return get_slot(selected_index)


func get_held_item_id() -> String:
	return str(get_selected_slot().get("item_id", ""))


func get_held_count() -> int:
	return int(get_selected_slot().get("count", 0))


## 从当前手持槽消耗物品。工具不会被消耗；种子类物品由调用者决定何时消耗。
func consume_selected(amount: int = 1) -> bool:
	if selected_index < 0 or amount <= 0:
		return false
	var slot := slots[selected_index]
	if slot.is_empty():
		clear_selection()
		return false
	if int(slot.get("count", 0)) < amount:
		return false

	var remaining := int(slot.get("count", 0)) - amount
	var cleared := remaining <= 0
	if cleared:
		slots[selected_index] = {}
		selected_index = -1
	else:
		slot["count"] = remaining

	changed.emit()
	if cleared:
		selection_changed.emit(-1)
	return true


## 还能再容纳多少个指定物品，用于收割前判断背包空间。
func get_free_capacity(item_id: String) -> int:
	if not ItemDB.has_item(item_id):
		return 0
	var max_stack := ItemDB.get_max_stack(item_id)
	var capacity := 0
	for slot in slots:
		if slot.is_empty():
			capacity += max_stack
		elif str(slot.get("item_id", "")) == item_id:
			capacity += maxi(0, max_stack - int(slot.get("count", 0)))
	return capacity


func can_add_item(item_id: String, amount: int) -> bool:
	return amount > 0 and get_free_capacity(item_id) >= amount


func can_remove_item(item_id: String, amount: int) -> bool:
	return amount > 0 and get_total_count(item_id) >= amount


func can_remove_items(requirements: Dictionary) -> bool:
	for item_id in requirements.keys():
		if not can_remove_item(str(item_id), int(requirements[item_id])):
			return false
	return true


## 从整个背包扣除指定物品；数量不足时返回 false 且不修改任何槽。
func remove_item(item_id: String, amount: int) -> bool:
	if amount <= 0 or get_total_count(item_id) < amount:
		return false

	var remaining := amount
	var cleared_selection := false
	for index in slot_count:
		if remaining <= 0:
			break
		var slot := slots[index]
		if slot.is_empty() or str(slot.get("item_id", "")) != item_id:
			continue
		var count := int(slot.get("count", 0))
		var removed := mini(count, remaining)
		count -= removed
		remaining -= removed
		if count <= 0:
			slots[index] = {}
			if selected_index == index:
				selected_index = -1
				cleared_selection = true
		else:
			slot["count"] = count

	changed.emit()
	if cleared_selection:
		selection_changed.emit(-1)
	return true


func remove_items(requirements: Dictionary) -> bool:
	if not can_remove_items(requirements):
		return false
	for item_id in requirements.keys():
		remove_item(str(item_id), int(requirements[item_id]))
	return true


## 把一个槽里的整堆物品移动到另一个背包（或同一背包的另一个槽）。
## 空槽直接移动；同类物品优先合并；不同物品则交换。
func move_stack_to(target: Inventory, from_index: int, to_index: int) -> bool:
	if target == null:
		return false
	if from_index < 0 or from_index >= slot_count:
		return false
	if to_index < 0 or to_index >= target.slot_count:
		return false
	if target == self and from_index == to_index:
		return false

	var source: Dictionary = slots[from_index].duplicate()
	if source.is_empty():
		return false

	var dest: Dictionary = target.slots[to_index].duplicate()
	var source_item := str(source.get("item_id", ""))
	var source_count := int(source.get("count", 0))
	var source_emptied := false
	var selection_to_target := false

	if dest.is_empty():
		target.slots[to_index] = source.duplicate()
		slots[from_index] = {}
		source_emptied = true
		selection_to_target = true
	elif str(dest.get("item_id", "")) == source_item:
		var max_stack := ItemDB.get_max_stack(source_item)
		var space := max_stack - int(dest.get("count", 0))
		if space <= 0:
			return false
		var moved := mini(space, source_count)
		dest["count"] = int(dest.get("count", 0)) + moved
		target.slots[to_index] = dest
		source["count"] = source_count - moved
		if int(source["count"]) <= 0:
			slots[from_index] = {}
			source_emptied = true
			selection_to_target = true
		else:
			slots[from_index] = source
	else:
		target.slots[to_index] = source.duplicate()
		slots[from_index] = dest.duplicate()

	if source_emptied and selected_index == from_index:
		selected_index = to_index if (target == self and selection_to_target) else -1
		selection_changed.emit(selected_index)

	changed.emit()
	if target != self:
		target.changed.emit()
	return true
