class_name TerrainLayer
extends RefCounted
## 地表层：纯整数定点分频值噪声 -> GRASS / DIRT / SAND / WATER。
##
## 实测依据（docs/worldgen.md §性能定标）：
## - 每格调用 hash2 的朴素实现是 65025×3×4~8 次 splitmix，实测 >3s/块，不可接受。
## - GDScript 逐格循环的硬地板约 0.26µs/格，因此**多 octave 必须在同一个逐格循环里
##   合并**；每 octave 的列格点下标/smoothstep 权重与行无关，预计算一次；每行先做
##   垂直混合（把两行格点混成一行），再逐格做一次水平插值。
## - 全程整数：格点值 [0,65535]、权重 16.16、lerp 用 a*(65536-w)+b*w >>16。
##   全层零浮点，跨平台一致性与 IEEE 细节无关。
##
## 噪声的唯一定义在 NoiseField（窗口缓存 + 逐行填充）；本层只负责"造窗口 + 调它"，
## 避免出现第二套插值实现导致 sample_point 与 generate 不一致。

const MAX_OCTAVES := 4
const WEIGHT_SCALE := 65536


## 生成一块地形（整块，不分帧）。返回 PackedByteArray(255*255)，下标 y*255+x。
func generate(seed_value: int, config: WorldGenConfig, chunk: Vector2i) -> PackedByteArray:
	var field := make_field(seed_value, config, chunk)
	var cells := config.chunk_size * config.chunk_size
	var out := PackedByteArray()
	out.resize(cells)
	field.fill_rows(out, 0, config.chunk_size)
	return out


## 为一个区块建立噪声窗口（ChunkManager 分帧生成时复用它逐行填充）。
func make_field(seed_value: int, config: WorldGenConfig, chunk: Vector2i) -> NoiseField:
	var size := config.chunk_size
	var field := NoiseField.new()
	field.build(seed_value, config, Rect2i(
		chunk.x * size - config.chunk_radius,
		chunk.y * size - config.chunk_radius,
		size,
		size
	))
	return field


## 单点查询（矿脉/障碍/生态层判定水域用）。与 generate 逐位一致。
func terrain_at(seed_value: int, config: WorldGenConfig, cell: Vector2i) -> int:
	var field := make_field(seed_value, config, GridMath.chunk_of_cell(cell, config.chunk_size))
	return field.terrain_at(cell.x, cell.y)
