class_name InventoryTransfer
extends RefCounted
## 通用 Shift 转移。
##
## 背包和所有带槽设备（熔炉、箱子、猪窝、后续新设备）都走这里：
## - shift_to_inventory：把设备/箱子槽里的整堆转到背包（先合并半堆，再占空槽）；
## - shift_to_slot：把背包槽转到指定设备槽（用于输入/燃料等有角色限制的槽）；
## - find_target_slot：只读查询，不移动。


static func find_target_slot(
	target: Inventory,
	item_id: String,
	preferred_indices: Array = []
) -> int:
	if target == null or item_id.is_empty():
		return -1
	var max_stack := ItemDB.get_max_stack(item_id)
	for index_value in preferred_indices:
		var index := int(index_value)
		if index < 0 or index >= target.slot_count:
			continue
		var slot := target.get_slot(index)
		if slot.is_empty():
			return index
		if str(slot.get("item_id", "")) == item_id and int(slot.get("count", 0)) < max_stack:
			return index
	for index in target.slot_count:
		var slot := target.get_slot(index)
		if slot.is_empty():
			return index
		if str(slot.get("item_id", "")) == item_id and int(slot.get("count", 0)) < max_stack:
			return index
	return -1


## 把 source[source_index] 整堆转移到 target；返回是否至少移动了一次。
static func shift_to_inventory(
	source: Inventory,
	target: Inventory,
	source_index: int,
	preferred_indices: Array = []
) -> bool:
	if source == null or target == null or source == target:
		return false
	var moved_any := false
	# 目标槽可能先合并半堆，再继续占用空槽；最多 80 次防止异常循环。
	for _attempt in 80:
		var source_slot := source.get_slot(source_index)
		if source_slot.is_empty():
			break
		var item_id := str(source_slot.get("item_id", ""))
		var target_index := find_target_slot(target, item_id, preferred_indices)
		if target_index < 0:
			break
		if not source.move_stack_to(target, source_index, target_index):
			break
		moved_any = true
	return moved_any


## 把 source[source_index] 尽量转入 target 的某个固定槽；返回是否移动。
static func shift_to_slot(
	source: Inventory,
	target: Inventory,
	source_index: int,
	target_index: int
) -> bool:
	if source == null or target == null or source == target:
		return false
	if target_index < 0 or target_index >= target.slot_count:
		return false
	return source.move_stack_to(target, source_index, target_index)
