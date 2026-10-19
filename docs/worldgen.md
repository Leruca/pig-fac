# 世界生成系统（WorldGen）

种子驱动的确定性 2D 格子世界：地形 / 生态 / 障碍 / 矿脉，按区块（255×255 格）纯函数生成、
按需分帧物化、按差分增量存档。本文是这套系统的**唯一事实来源**。

> 视觉示例：`docs/worldgen-map.png`（种子 `12345`，3×3 区块，红色网格线为 REGION 边界）

---

## 1. 种子格式

内部一律 64 位有符号整数（GDScript `int`）。**存档里必须以字符串存储**：
JSON 的数字是 double，`9223372036854775807` 存进去读回会变成 `9223372036854775808.0`
（`tests/worldgen/test_seed_serialization.gd` 里有一条专门的断言证明这件事）。

解析分支（`SeedSystem.parse_seed`）：

| 输入形态 | 规则 | 例 |
| --- | --- | --- |
| `^-?[0-9]+$` 且 `str(to_int)==原文` | 十进制原样 | `123` → `123`，`-1` → `-1` |
| `^0[xX][0-9a-fA-F]{1,16}$` | **手工按位累积**十六进制 | `0x10` → `16`，`0xFFFFFFFFFFFFFFFF` → `-1` |
| 其它（含中文、超精度数字） | FNV-1a 64（utf8 字节） | `hello猪` → `3505143883185990518` |

为何不用 `String.hex_to_int()`：它遇到大于 2^63 的输入会**报错并返回 INT64_MAX**，
位模式被悄悄改掉。手动累积不会。

新档：`PIGFAC_SEED` 环境变量 → 否则用系统时间派生一次；种子会**立刻写入 `user://saves/main/seed.txt`**，下次启动沿用。正式保存后同时写入 `global.json` 的 `seed` 字段。Esc 菜单可以查看/复制种子，也可以用输入框指定种子开新游戏。

---

## 2. 确定性随机（SeedSystem）

```gdscript
splitmix64(x)              # 状态推进一次的输出
hash2(seed, salt, x, y)    # 坐标哈希：三次 splitmix64，负坐标先与 0xFFFFFFFF 相与
u01(h)                     # 唯一的整数 -> [0,1)：低 53 位 / 2^53
quick32(seed, salt, x, y)  # 便宜的 32 位哈希，只用于粗筛（候选点抽样/装饰抖动）
rng_at(seed, salt, x, y)   # 由 hash2 派生的 splitmix64 流
```

三条实现纪律（都由实测决定；与 `zhuzhu/tools/splitmix_ref.py` 逐位对拍）：

1. **逻辑右移必须手工实现**：GDScript 的 `>>` 是算术右移（`-1 >> 1 == -1`），
   splitmix64 里的 `z >> 30` 必须写成 `SeedSystem.ushr(z, 30)`。
2. **大于 2^63 的十六进制字面量会解析失败**，所以 `C1/C2/C3` 写成等价的有符号十进制：
   `-7046029254386353131` 就是 `0x9E3779B97F4A7C15`。
3. **整数溢出静默回绕**（`9223372036854775807 + 1 == -9223372036854775808`），
   因此不需要分段乘法。

---

## 3. 坐标系

```
chunk_of_cell(cell)         = floor((cell + 127) / 255)      # 区块原点 = chunk * 255 - 127
chunk_origin(chunk)         = chunk * 255 - Vector2i(127,127)
local_of_cell(cell, chunk)  = cell - chunk_origin(chunk)      # 属于 [0, 255)
region_of_chunk(chunk)      = floor_div(chunk, 4)            # REGION = 4x4 区块
```

| cell | chunk | local |
| --- | --- | --- |
| `(-128, y)` | `(-1, .)` | `(254, .)` |
| `(-127, y)` | `(0, .)` | `(0, .)` |
| `(0, 0)` | `(0, 0)` | `(127, 127)` |
| `(128, y)` | `(1, .)` | `(0, .)` |

区块 0 覆盖 `[-127, 127]`，因此**世界原点 (0,0) 是区块 (0,0) 的正中心**；
出生半径 24 完全落在区块 (0,0) 内，与旧的 `BIG_BLOCK_SIZE=255 / BIG_BLOCK_RADIUS=127` 零迁移成本。

> 注意：PLAN §3.1 的 1 维示例把 `cell -128` 的局部坐标写成 `127`，与它自己给出的
> `chunk_origin` 公式矛盾（算出来是 254）。实现与测试以公式为准。

`region` 必须用 **floor 除法**：`region_of_chunk(-1) == -1`，不能是 0。

---

## 4. 分层管线

```
TerrainLayer  -> 地形字节数组（GRASS/DIRT/SAND/WATER）
ObstacleLayer -> 3x3 树 + 1 格普通石头（同一遍扫描里顺带放灌木）
EcoLayer      -> 可交互灌木；视觉装饰不物化
OreLayer      -> REGION 级矿脉（随机游走）
SpawnGuard    -> 出生保护区逐格覆写（最后执行，优先级最高）
```

依赖图无环：后三层只调用 Terrain 的**同坐标纯函数查询**。

### 4.1 地形（定点噪声）

* 自实现格点值噪声，**全程整数**：格点值 `[0,65535]`，smoothstep 用 4096 项 16.16 定点表，
  插值 `(a*(65536-w) + b*w) >> 16`。零浮点 → 跨平台结果与 IEEE 细节无关。
* 只在**格点**上算哈希（scale≈0.023 时一块 255×255 只有约 10×10 个格点），
  格点表存 `PackedInt32Array`，用 `gy*nx+gx` 整数下标，绝不用 `Dictionary`/`Vector2i` 做键。
* 每 octave 的"列格点下标 + 权重"与行无关，预计算一次；每行先垂直混合两行格点，
  再逐格一次水平插值；多 octave 在**同一个逐格循环**里合并（GDScript 逐格循环地板约 0.26µs/格）。
* 性能：单块地形约 16ms（2 octave，255×255）。朴素"每格调一次 hash2"实测 >3s，已废弃。

### 4.2 障碍（树 / 石头 / 灌木）

* 候选点是**全局粗网格**（`step = obstacle.cell_chunk_cells`，默认 8）加确定性抖动；
  每候选点最多产出 1 棵树 / 1 块普通石头 / 1 丛灌木。普通石头现在是
  6–10 耐久、每块 16–30 石头；视觉为 2×2 小山。
  抖动是必要的：没有它树根只能落在 step 的整数倍上，3×3 footprint 永远无法跨越区块接缝
  （边界带逻辑会变成死代码），而且地图上能看到网格。
* 树的 3×3 里任何一格是 WATER 就不种；非 SAND 占比低于 `tree_ground_pad_millis` 也不种。
* 树耐久由 `hash2(seed, obstacle_salt + 7919, root)` 派生，替代 `randi_range(3,5)`；
  手动种下的树苗成熟时用的是同一个函数。
* 本块 ChunkData 收录的树 = 根格落在 `[origin-(footprint-1), origin+size-1]` 范围内的树，
  这就是**边界带**：邻区块重算时结果完全一致，物化时按引用计数去重。

### 4.3 生态

灌木进 `ChunkData.obstacles`（可交互、阻挡）。草丛/小花**不进 ChunkData、不物化**：
`WorldGrid` 绘制时调 `EcoLayer.visual_decor(seed, config, cell)` 即时求值。
0.14 密度若物化 9 块约 32MB，绘制时求值内存为 0。

### 4.4 矿脉（OreLayer）

1. REGION = `region_chunks x region_chunks`（默认 4×4）个区块。某区块的矿脉来源 =
   本 REGION + 相邻 8 个 REGION（3×3 邻域），否则 REGION 边界会系统性漏脉。
   脉长不超过 `vein_size_max`(14)，远小于 REGION 边长(1020)，一圈足够。
   > 但密度很稀：一个 REGION 只有 32~64 条脉散布在 1020×1020 格上。因此"某一个区块恰好没有矿"
   > 是正常结果，**不能**拿"区块是否有矿"当漏脉判据；测试用的是
   > "区块切片结果 == 5×5 邻域参考实现结果"。
2. 每 REGION 脉数 = 区间内**纯整数均匀**取样（不用浮点泊松）。
3. `vein_id = hash2(seed, salt, region 索引组合)`，全局唯一、数值稳定，用作重叠 tie-break。
4. 形状：锚点出发的 8 方向随机游走，1/4 概率原地不动（更紧凑），撞自己就跳过（步数不减）。
5. 地形过滤：落在 WATER 的格剔除；剔除后**整条脉**剩余格数 < `min_vein_cells` 才丢弃
   （不是按本区块交集后的碎片计数）。
6. 每格 amount 由**本脉独立派生流**给出；当 `vein_total_amount_min > 0` 时，先取样整条脉总矿量（当前至少 50,000），再按过滤后的格子均分（余数给前几格），因此整条脉在任何区块里重算都一致。
7. 类型权重受 `depth_bias_millis` 影响：离出生点越远，金矿/铁矿权重越高（定点，无浮点随机）。
8. 当前矿种：铜(1)、铁(2)、金(3)、煤(4)、石头(5)；石头矿脉与其他矿脉共用随机游走与总矿量规则。

REGION 级缓存只按 `(seed, version, region)` 索引，是纯函数结果的记忆化，不引入顺序依赖；
构建过程是**可切片状态机**（`OreLayer.RegionBuilder`），可以分帧推进。

### 4.5 出生保护区（SpawnGuard）

* 切比雪夫距离不超过 `spawn_safe_radius_cells`（默认 24）的格子强制 GRASS；
* 删除任何 **footprint 覆盖这些格子**的障碍（不是只看根格）与保护区内的矿；
* `spawn_reserved_cells`（初始猪位 `(0,0)/(4,0)/(8,0)`）与 `spawn_reserved_footprints`
  （教学树 `(5,-2)` 的 9 格）显式豁免"清结构"，地形仍是 GRASS；
* footprint 只向 `+x/+y` 铺开，所以"根格在 R+1、树冠伸进 R"只能从负方向发生，
  测试里专门构造了这种用例。

> 出生点 = 世界原点 = 区块 (0,0) 的中心。

---

## 5. 公开 API

### WorldGenerator（纯逻辑，无场景依赖）
```gdscript
var generator := WorldGenerator.new(config, seed_value)
var data: ChunkData = generator.generate_chunk(chunk)   # 一次性生成
var job := generator.make_job(chunk)                     # 可切片生成
job.step(rows_per_slice, ms_budget)                      # 返回 true = 完成
var data: ChunkData = job.finish()
generator.terrain_type_at(cell) / is_water_at(cell)      # 跨块地形查询（带窗口缓存）
```

### ChunkManager（Node，缓存 / 分帧 / 卸载）
```gdscript
chunk_manager.setup(config, seed_value, world_objects, pig_cells_callable)
chunk_manager.ensure_radius(center_cell)   # 中心块变化时先同步生成中心块，再排队周围 5×5
chunk_manager.ensure_chunk_now(chunk)      # 同步生成 + 物化（读档/交互落点用）
chunk_manager.get_cell_terrain(cell)       # 未加载返回 -1（不同步生成！）
chunk_manager.is_terrain_blocked(cell)     # 只挡"已加载且是水"
chunk_manager.mark_cell_dirty(cell)        # 通常不用手调（脏信号驱动）
chunk_manager.flush_chunk(chunk, farm_plots, pigs)  # 落盘；空 overrides -> 删文件
chunk_manager.unload_chunk(chunk)          # 先落盘再 dematerialize
chunk_manager.prime_restore(payloads) / resume_load(center_cell)  # 读档分帧恢复
```

### WorldObjects（物化契约）
```gdscript
world_objects.materialize_chunk(chunk, size, radius, trees, ores, blocks)
world_objects.dematerialize_chunk(chunk)
```
* **物化集合 = 本区块物体 ∪ 边界带内他区物体**：边界带内根格由确定性哈希重建，
  不需要邻区块已生成，所以"根格在未生成区块、占地在已生成区块"对 `is_blocked` 可见。
* **卸载按引用计数**：每个树根记录被多少个已加载区块引用，减到 0 才真正移除。
  所以卸载 A 不会删掉相邻 B 还要的跨区树碰撞（不穿树）。
* `_next_born_pig_index`（全局计数器）与 `_visited_blocks`（战争迷雾）**不归本类**，
  卸载不会碰它们。
* 空间索引：树/窝/矿按 32×32 格分桶，`is_blocked` / `find_tree_root` 只查所在桶；
  `_draw` 按可视区域裁剪。

### 脏标记（信号驱动）

`WorldObjects` 的**所有** mutator（放/拆木头、木板、栅栏、箱子、猪窝、种树苗、浇水、
锤树、锤矿、锤石头/灌木、树苗成熟、猪窝产出）都会发 `chunk_dirty(cell)`，
`ChunkManager` 订阅后转成"区块待落盘"。新增 mutator 只要走这些函数就自动覆盖。

**计时豁免**：作物 `elapsed`、树苗 `elapsed`、猪窝 `progress` 的每帧推进**不标脏**，
只在落盘瞬间快照。否则任何有作物/树苗的块每帧都脏，增量存档会退化成全量。
卸载即冻结（写盘固化 `stage/elapsed`），不是重载后按真实时间快进。

---

## 6. 配置（`config/worldgen.json`）

| 键 | 含义 |
| --- | --- |
| `worldgen_version` | 生成器版本，参与黄金哈希与存档 |
| `chunk_size` / `chunk_radius` | 255 / 127（与旧存档的 `BIG_BLOCK_SIZE` 一致）|
| `spawn_safe_radius_cells` | 出生保护区半径（切比雪夫）|
| `spawn_reserved_cells` | 不被占位的格子（初始猪位）|
| `spawn_reserved_footprints` | 整块豁免的 footprint（教学树）|
| `budgets.gen_ms_per_frame` / `gen_rows_per_slice` | 分帧双闸门 |
| `budgets.ensure_radius_chunks` / `keep_radius_chunks` | 预生成半径 / 卸载半径（当前 2 / 2 → 镜头周围 5×5）|
| `budgets.materialize_radius_chunks` | 真正物化到 `WorldObjects` 的半径（当前 1 → 实际活跃 3×3）|
| `budgets.*` 运行时行为 | 中心块同步生成避免整屏空白，周围区块继续分帧预生成；物化也分帧 |
| `budgets.pig_residency_radius_chunks` | 猪周围强制常驻的圈数 |
| `budgets.unload_eval_seconds` | 卸载评估周期（不是每帧）|
| `budgets.eager_load_radius_chunks` | 读档时**急切**恢复的半径，其余惰性 |
| `bench.avg_ms_max` / `p99_ms_max` | `tests/bench_chunk_gen.gd` 的断言阈值（当前 90ms / 250ms；高负载 CI 留余量）|
| `layers.terrain.*` | `salt`、`noise_scale_q16`、`octaves`、三档阈值 |
| `layers.eco.*` | `bush_chance_millis`、`tuft_chance_millis`、`flower_chance_millis` |
| `layers.obstacle.*` | `cell_chunk_cells`、`tree_chance_millis`、`rock_chance_millis`、`rock_hp`、`rock_amount`、`tree_footprint` |
| `layers.ore.*` | `region_chunks`、`vein_count_per_region`、`min_vein_cells`、`vein_total_amount_min/max`、`types[]` |

**所有概率/密度都是"每候选点"的千单位整数**（`*_chance_millis`），折算到每格概率
约为 `chance_millis / 1000 / step^2`。改 `cell_chunk_cells` 时记得同步换算，否则密度会变。

---

## 7. 存档（ChunkStore + SaveManager）

```
user://saves/main/global.json       # 全局态：seed(字符串) / worldgen_version / 相机 / 迷雾 / 猪列表
user://saves/main/seed.txt          # 首次启动的种子；未正式保存时也能复现地图
user://saves/main/blocks/x_y.json   # 区块差分：{chunk, worldgen_version, overrides}
```

`overrides` 字段：

| 字段 | 含义 |
| --- | --- |
| `mined: {cell: 已采量}` | 部分采集；重建时 `amount = max(0, 生成量 - mined)` |
| `removed_ores` | 采空 |
| `chopped_trees` | 砍倒（根格）|
| `tree_hits: {root: remaining}` | 锤了没倒的部分损伤 |
| `planted_trees` | 玩家种下/树苗长成的树（含耐久）|
| `removed_naturals` | 敲掉的普通石头/灌木 |
| `natural_hits` / `natural_stones` | 自然物剩余耐久 / 普通石头剩余石量 |
| `placed_blocks` / `furnaces` | 玩家放置的石方块/石砖方块；熔炉库存与燃烧/熔炼进度 |
| `saplings` | `{cell, stage, elapsed, mature_root, mature_hp}` |
| `logs` / `planks` / `fences` / `chests` / `nests` | 建造物 |
| `farm` | 地块 `{cell, crop_id, stage, elapsed}` |
| `pigs` | 仅用于 v1 迁移兼容；v2 正常存档把猪放 `global.json` |

**差分是"活体状态 vs 重生成基底"做差**得来的，不是按操作枚举记录。三个直接好处：

1. 玩家撤销全部改动 → 差分为空 → **删掉块文件**（脏→净回归），旧改动不会复活；
2. 行为系统/自动操作走同一份物化表 → 天然全覆盖，不会漏某个 mutator；
3. 差分与生成顺序无关，读档不需要重放操作日志。

保存流程：遍历 dirty 集合（加有猪的块）→ 算 overrides → 非空写文件 / 空则删文件；
然后全量重写 `global.json`（全局态无法增量）。**已移除**旧版的 `_clear_block_files()` 全删步骤。
所有区块/全局写入都走 `SavePaths.atomic_write_text()`：先写 `.tmp`，再 rename；中断不会留下半截 JSON。

读档流程：全部解析成功 → 清空运行时 → 急切恢复相机附近 N 块 → 其余登记为"待惰性恢复"，
走与运行时同一套 `ensure_radius` 分片管线。先解析后重建的安全性保持不变。

### v1 存档迁移

`version=1` 的旧档会在读档时转换：`ChunkStore.read_all_blocks(true)` 用文件名/旧 `block`
推断区块，把旧顶层 `pigs/trees/farm/chests/nests/...` 包装成 overrides；旧树按
`planted_trees` 保留，旧对象占用的格子登记 `removed_naturals/removed_ores`；猪汇总进
`global.json`。旧档没有 seed，迁移使用固定的 `legacy-v1` 派生种子，并把新格式立刻写回，
避免下次启动再迁移到另一张地图。

### 测试隔离

测试不再使用玩家目录。`tests/run_worldgen_tests.sh` 设置 `PIGFAC_TEST_SAVE_ROOT`，
各存档测试再用 `SavePaths.set_root("user://saves/test_...")` 隔离；`boot_smoke` 也用
独立目录。运行测试不会改动 `user://saves/main`。

树苗跨块成熟：`sapling` 存 `mature_root` / `mature_hp`（种下即用 `hash2` 派生），
成熟时**同时**标脏树苗所在块与根格所在块（可能不同块）。

### 版本升级（迁移式烘焙，已实现于 `ChunkMigration`）

`worldgen_version` 变更时读档会先做一次迁移：用**新版生成器**重算每块基底，把旧 overrides
重新落到新基底上，然后立刻写盘，之后一律按新版走。**不**永久维护 N 份历史生成器，也**不**拒绝旧档。

能这么做的前提：overrides 里绝大多数是**玩家意图的绝对值**，与生成基底无关。分成两类处理：

| 类别 | 字段 | 迁移策略 |
| --- | --- | --- |
| 绝对值 | `logs` `planks` `fences` `chests` `nests` `farm` `saplings` `planted_trees` `pigs` | 原样保留（一条不丢）|
| 相对值 | `mined` | 夹到 `0..新基底量`；`<= 0` 丢弃，`>= 新基底量` 转成 `removed_ores` |
| 相对值 | `tree_hits` | 剩余次数 `<= 0` 转成 `chopped_trees`；`>= 新基底耐久` 视为没受过伤，丢弃 |
| 相对值 | `removed_ores` / `chopped_trees` / `removed_naturals` | 只保留「新基底里确实还存在该物」的条目 |

重基后为空的 overrides 会**删文件**（与脏→净同一条规则），不会留下空壳。

也就是说：玩家建的房子、装的箱子、种的庄稼和树苗一定保住；指向「旧地图上那棵特定位置的树 /
那格矿」的损伤记录，如果新地图那里已经没有东西了，就安静丢弃。

---

## 8. 黄金哈希

规范化序列化（`ChunkHasher`），FNV-1a 64（乘法同样走回绕语义）：

```
int             -> "i" + big_endian_8bytes(位模式)
string          -> "s" + u32_len + utf8_bytes
bool            -> "b" + (0|1)
PackedByteArray -> "p" + u32_len + raw_bytes
array           -> "a" + u32_count + concat(canonical(e))
dict            -> "d" + u32_count + concat(canonical(k) + canonical(v))   # 键按 utf8 字节序
Vector2i        -> "a" + 2 个 int                                          # 即 [x, y]
float           -> 禁止（ChunkData 内不允许 float）
```

数组元素固定按 `(cell.y, cell.x, kind/id)` 排序，绝不保留生成/遍历顺序。
哈希输入含 `seed + worldgen_version + chunk`；**overrides 不参与**黄金哈希。

更新流程：确认 worldgen 变更是**有意**的 →
`godot --headless --path . -s res://tools/seed_compare.gd -- --update-golden

# 跨语言对拍（导出完整序列化输入，交给纯 Python 复算）
godot --headless --path . -s res://tools/seed_compare.gd -- --export-json user://golden_export.json
python3 tools/golden_check.py ~/.local/share/godot/app_userdata/PigFac/golden_export.json` → Review diff。

---

## 9. 确定性承诺与限制

**承诺**（同种子 + 同版本 + 同配置 → 同世界，与遍历/生成顺序、机器、进程无关）：
地形、可交互生态（灌木）、障碍（树/石头及耐久）、矿脉（位置/类型/数量）。
跨语言对拍：`zhuzhu/tools/splitmix_ref.py` 与 `SeedSystem` 逐位一致。

**不承诺**（玩法随机或纯视听，不属于世界生成）：
繁育 RGB 变异、砍树掉落数量、作物产量、音效 pitch、选中圈脉冲等视觉计时。

**浮点**：世界生成内部零浮点（`elapsed` / `progress` 这类挂钟进度是存档快照，不参与哈希与断言）。

---

## 10. 工具与测试

```bash
# 黄金哈希 / 双跑对拍
godot --headless --path . -s res://tools/seed_compare.gd -- --seed 12345 --chunks 0,0 1,0 -2,3
godot --headless --path . -s res://tools/seed_compare.gd -- --update-golden

# 地图可视化（PNG + 可选矿点 JSON）
godot --headless --path . -s res://tools/map_viewer.gd -- --seed 12345 --radius 1 --out /tmp/map.png --veins /tmp/veins.json

# 分相 / 整块基准
godot --headless --path . -s res://tools/bench_phases.gd
godot --headless --path . -s res://tests/bench_chunk_gen.gd
```

| 测试 | 覆盖 |
| --- | --- |
| `test_seed_determinism` | 同种子同块一致；不同种子不同；int64 极值种子不崩且地形不退化 |
| `test_seed_serialization` | 解析分支；JSON 大整数丢精度 |
| `test_generation_order_invariance` | 随机置换 / 交错生成器 / 冷热矿脉缓存 → 哈希一致 |
| `test_negative_coords` | chunk/local/region 公式；±1 区块接缝连续；3×3 树边界带不重不漏 |
| `test_vein_continuity` | 区块切片 == 5×5 邻域参考；无单格脉；水中无矿；tie-break 稳定 |
| `test_spawn_guard` | 半径内全 GRASS/无障碍/无矿；footprint 粒度清除；猪位与教学树 9 格 |
| `test_ore_distribution` | 64 区块矿型比例/密度；无单格碎矿；出生区为 0 |
| `test_save_roundtrip` | 部分/采空、锤树、砍树、建造、脏→净删文件、树苗跨块成熟 |
| `test_unload_consistency` | 卸载 A 后 B 的跨区树仍阻塞；引用计数无泄漏；猪驻留；全局态不受影响 |
| `test_pathfinding_no_gen_storm` | 寻路不触发生成；未生成地形可通过；已生成的水阻挡 |
| `test_golden_hashes` | 对拍 `tests/golden/hashes.json` |
| `test_band_ownership` | 跨块 3×3 树在**每一个**相交区块都被收录（81k 断言，多区块原点/多种子）；不得出现互相重叠的树；跨块树可被砍且可落盘 |
| `test_terrain_single_truth` | 全量比对（6 种子 × 4 区块 × 65025 格）「存储地形」与「点查询地形」逐格一致；窗口内外取值逐位一致 |
| `test_slice_and_config_guards` | 行预算是真闸门；任意切片粒度哈希一致；`chunk_radius` 由 `chunk_size` 推导 |
| `test_save_regressions` | 读档→卸载→重载后损伤不回退；普通石头/灌木耐久与石量落盘；未加载脏块不静默跳过；原子写先落 `.tmp` 且不留残留 |
| `test_features` | 普通石头 6–10 下 × 16–30 石头、可放置方块、熔炉冶炼、石砖/熔炉配方 |
| `test_cross_language_hash` | 导出完整序列化输入，交给纯 Python 实现复算；找不到 Python 时明确 SKIP |
| `test_version_migration` | 迁移式烘焙：绝对值字段一条不丢、相对值字段按新基底夹取、重基为空则删文件 |
| `bench_chunk_gen` | 100 块 avg/p99 对预算断言（验收 11）|

运行方式：SceneTree 系列用 `godot --headless --path . -s <path>.gd`；
需要 autoload / 节点树的（`test_save_roundtrip` / `test_unload_consistency` / `test_pathfinding_no_gen_storm`）
用同名 `.tscn`：`godot --headless --path . res://tests/worldgen/<name>.tscn`。
`cross_language_hash` 在 Windows 可设置 `PYTHON` 指向 Python 可执行文件；没有 Python 时会跳过而不是失败。

一键全跑：`bash tests/run_worldgen_tests.sh`。
---

## 11. 三条必须守住的不变式（对抗复审的落点）

这三条一旦被破坏，症状都很隐蔽（不报错、测试可能仍然绿），因此单独立文档 + 专测：

### 不变式 1：冲突消解与「正在生成哪个区块」无关

`ObstacleLayer.generate` 在**扩展窗口**内按全局网格下标升序扫描，并**无条件**维护 `occupied`；
只有 footprint 与本块相交的才 append。任何「本块自己的占位集合」写法都会让边界带候选
被邻块不对称地否决 → 同一棵树只有一个区块收录 → 砍伐无法落盘、遮挡随加载顺序变化。
守护测试：`test_band_ownership`。

### 不变式 2：地形只有一个事实来源

`fill_rows` 写字节、`raw_value_at` 参与判类，两者必须用**同一个整数比较**
（`(s0*2+s1) < threshold*3`），并且**同一套混合顺序**（先垂直后水平）。
曾经点查询用 `(raw*21846)>>16` 近似 `/3`，与 `fill_rows` 在约 0.7% 的格子上差 1；
更隐蔽的是混合顺序不同也会差 1。守护测试：`test_terrain_single_truth`。

### 不变式 3：差分必须能经受「卸载 → 重载」

块被卸载后重新物化是从**生成基底**重建的。因此任何已经生效过的差分都必须留在
`ChunkManager._live_overrides` 里，物化后重放一次；否则玩家挖掉/敲掉的进度会在
走开再回来时回退，而且下一次落盘会以新基底重算差分，把损伤越写越少。
守护测试：`test_save_regressions` / `test_unload_consistency`。
