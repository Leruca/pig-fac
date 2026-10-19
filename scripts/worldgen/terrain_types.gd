class_name TerrainTypes
extends RefCounted
## 地形枚举与配色。数值写进 ChunkData.terrain（PackedByteArray），并参与黄金哈希，
## 因此顺序与数值一旦发布就不可更改。

enum Type { GRASS = 0, DIRT = 1, SAND = 2, WATER = 3 }

const GRASS := 0
const DIRT := 1
const SAND := 2
const WATER := 3
const COUNT := 4

const NAMES := ["grass", "dirt", "sand", "water"]

## 可通行判定：只有 WATER 不可通行。
static func is_walkable(terrain_type: int) -> bool:
	return terrain_type != WATER


static func type_name(terrain_type: int) -> String:
	if terrain_type < 0 or terrain_type >= NAMES.size():
		return "unknown"
	return NAMES[terrain_type]


static func color_of(terrain_type: int) -> Color:
	match terrain_type:
		GRASS:
			return Color("#9BC57A")
		DIRT:
			return Color("#B08A5B")
		SAND:
			return Color("#E3D3A0")
		WATER:
			return Color("#5C97C7")
		_:
			return Color("#9BC57A")
