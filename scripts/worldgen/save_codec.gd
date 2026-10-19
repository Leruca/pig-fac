class_name SaveCodec
extends RefCounted
## 存档值编解码（Vector2/Vector2i/Vector3i/Color/Rect2i/Dictionary/Array/Inventory）。
## 与旧 SaveManager 的 $vec2/$vec2i/... 标记保持兼容，老存档仍可读。

const TAG_VEC2 := "$vec2"
const TAG_VEC2I := "$vec2i"
const TAG_VEC3I := "$vec3i"
const TAG_RECT2I := "$rect2i"
const TAG_COLOR := "$color"
const TAG_LARGE_INT := "$i64"


static func encode(value: Variant) -> Variant:
	match typeof(value):
		TYPE_VECTOR2:
			return {TAG_VEC2: [value.x, value.y]}
		TYPE_VECTOR2I:
			return {TAG_VEC2I: [value.x, value.y]}
		TYPE_VECTOR3I:
			return {TAG_VEC3I: [value.x, value.y, value.z]}
		TYPE_RECT2I:
			return {TAG_RECT2I: [value.position.x, value.position.y, value.size.x, value.size.y]}
		TYPE_COLOR:
			return {TAG_COLOR: [value.r, value.g, value.b, value.a]}
		TYPE_DICTIONARY:
			var out := {}
			for key in value.keys():
				out[str(key)] = encode(value[key])
			return out
		TYPE_ARRAY:
			var out_array := []
			for item in value:
				out_array.append(encode(item))
			return out_array
		_:
			return value


static func decode(value: Variant) -> Variant:
	if value is Dictionary:
		var dict: Dictionary = value
		if dict.has(TAG_VEC2):
			var pair: Array = dict[TAG_VEC2]
			return Vector2(float(pair[0]), float(pair[1]))
		if dict.has(TAG_VEC2I):
			var pair_i: Array = dict[TAG_VEC2I]
			return Vector2i(int(pair_i[0]), int(pair_i[1]))
		if dict.has(TAG_VEC3I):
			var triple: Array = dict[TAG_VEC3I]
			return Vector3i(int(triple[0]), int(triple[1]), int(triple[2]))
		if dict.has(TAG_RECT2I):
			var rect: Array = dict[TAG_RECT2I]
			return Rect2i(int(rect[0]), int(rect[1]), int(rect[2]), int(rect[3]))
		if dict.has(TAG_COLOR):
			var rgba: Array = dict[TAG_COLOR]
			return Color(float(rgba[0]), float(rgba[1]), float(rgba[2]), float(rgba[3]))
		var out := {}
		for key in dict.keys():
			out[key] = decode(dict[key])
		return out
	if value is Array:
		var out_array := []
		for item in value:
			out_array.append(decode(item))
		return out_array
	return value


static func encode_inventory(inventory: Inventory) -> Dictionary:
	if inventory == null:
		return {"slot_count": Inventory.DEFAULT_SLOT_COUNT, "slots": []}
	var slots: Array = []
	for index in inventory.slot_count:
		var slot := inventory.get_slot(index)
		if slot.is_empty():
			slots.append({})
			continue
		var encoded := {}
		for key in slot.keys():
			var value: Variant = slot[key]
			if value is Inventory:
				encoded[key] = encode_inventory(value)
			else:
				encoded[key] = encode(value)
		slots.append(encoded)
	return {"slot_count": inventory.slot_count, "slots": slots}


static func decode_inventory(value: Variant, default_slots: int = Inventory.DEFAULT_SLOT_COUNT) -> Inventory:
	var data: Dictionary = value if value is Dictionary else {}
	var slot_count := int(data.get("slot_count", default_slots))
	var inventory := Inventory.new(slot_count)
	var slots: Array = data.get("slots", [])
	for index in mini(slots.size(), inventory.slot_count):
		var source: Variant = slots[index]
		if not (source is Dictionary) or source.is_empty():
			continue
		var decoded := {}
		for key in source.keys():
			var item: Variant = source[key]
			if str(key) == "pig_inventory" and item is Dictionary:
				decoded[key] = decode_inventory(item)
			else:
				decoded[key] = decode(item)
		inventory.slots[index] = decoded
	return inventory
