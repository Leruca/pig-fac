class_name ChunkData
extends RefCounted
## 一个区块的生成结果（**仅内存态**，绝不直接序列化到磁盘）。
##
## 落盘只走 overrides 差分（见 ChunkStore）：程序化生成部分是 (seed, version, chunk)
## 的纯函数，读档时重算即可，不需要存。
##
## 字段：
##   terrain   PackedByteArray(255*255)，下标 y*255+x，值为 TerrainTypes 枚举
##   obstacles Array[Dictionary]，{cell: Vector2i, kind: int, hp: int}
##             —— 含边界带内"根格在邻块、footprint 伸进本块"的树（物化需要）
##   ores      Array[Dictionary]，{cell: Vector2i, ore_id: int, amount: int}
##   hash      黄金哈希（仅调试/对拍用，不参与存档）

enum ObstacleKind { TREE = 1, ROCK = 2, BUSH = 3, STONE = 4 }

const KIND_TREE := 1
const KIND_ROCK := 2
const KIND_BUSH := 3
const KIND_STONE := 4

var chunk: Vector2i = Vector2i.ZERO
var worldgen_version: int = 1
var terrain: PackedByteArray = PackedByteArray()
var obstacles: Array[Dictionary] = []
var ores: Array[Dictionary] = []
## 黄金哈希是**惰性**计算的：只在测试/对拍/工具里需要时才序列化整块。
## 生成热路径不做（65025 字节的规范化序列化本身要 ~20ms）。
var hash: String = ""
var seed_value: int = 0


func terrain_at_local(local_x: int, local_y: int, chunk_size: int) -> int:
	if local_x < 0 or local_y < 0 or local_x >= chunk_size or local_y >= chunk_size:
		return -1
	return terrain[local_y * chunk_size + local_x]


func is_water_local(local_x: int, local_y: int, chunk_size: int) -> bool:
	var value := terrain_at_local(local_x, local_y, chunk_size)
	return value == TerrainTypes.WATER or value == -1


func compute_hash() -> String:
	hash = ChunkHasher.chunk_hash(seed_value, worldgen_version, chunk, terrain, obstacles, ores)
	return hash


func duplicate_shallow() -> ChunkData:
	var copy := ChunkData.new()
	copy.chunk = chunk
	copy.worldgen_version = worldgen_version
	copy.terrain = terrain.duplicate()
	copy.obstacles = obstacles.duplicate(true)
	copy.ores = ores.duplicate(true)
	copy.hash = hash
	copy.seed_value = seed_value
	return copy
