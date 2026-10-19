#!/usr/bin/env bash
# 世界生成全套测试（含既有基线）。
# 用法：bash tests/run_worldgen_tests.sh [--with-baseline]
#
# 注意：SceneTree 系列（-s）与场景系列（.tscn）启动方式不同，脚本里已区分。

set -uo pipefail

GODOT="${GODOT:-$HOME/apps/godot/godot}"
if [ ! -x "$GODOT" ]; then
  echo "找不到 Godot：$GODOT（用环境变量 GODOT 指定）" >&2
  exit 2
fi

cd "$(dirname "$0")/.." || exit 2

# 测试存档与玩家 user://saves/main 完全隔离。
export PIGFAC_TEST_SAVE_ROOT="${PIGFAC_TEST_SAVE_ROOT:-user://saves/worldgen_test_run}"

pass=0
fail=0
failed_names=()

run_script() {
  local name="$1"
  local path="$2"
  local out
  out=$("$GODOT" --headless --path . -s "$path" 2>&1)
  local code=$?
  if [ $code -eq 0 ] && ! echo "$out" | grep -q "FAILED"; then
    echo "  ok   $name :: $(echo "$out" | grep -E "PASSED" | tail -1)"
    pass=$((pass + 1))
  else
    echo "  FAIL $name"
    echo "$out" | grep -E "SCRIPT ERROR|ERROR:|FAILED" | head -8 | sed "s/^/       /"
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
}

run_scene() {
  local name="$1"
  local path="$2"
  local out
  out=$("$GODOT" --headless --path . "$path" 2>&1)
  local code=$?
  if [ $code -eq 0 ] && ! echo "$out" | grep -q "FAILED"; then
    echo "  ok   $name :: $(echo "$out" | grep -E "PASSED" | tail -1)"
    pass=$((pass + 1))
  else
    echo "  FAIL $name"
    echo "$out" | grep -E "SCRIPT ERROR|ERROR:|FAILED" | head -8 | sed "s/^/       /"
    fail=$((fail + 1))
    failed_names+=("$name")
  fi
}

echo "== 编译自检"
run_script compile_check res://tests/tool_compile_check.gd

echo "== 世界生成：确定性 / 坐标 / 生成"
run_script seed_determinism res://tests/worldgen/test_seed_determinism.gd
run_script seed_serialization res://tests/worldgen/test_seed_serialization.gd
run_script order_invariance res://tests/worldgen/test_generation_order_invariance.gd
run_script negative_coords res://tests/worldgen/test_negative_coords.gd
run_script spawn_guard res://tests/worldgen/test_spawn_guard.gd
run_script band_ownership res://tests/worldgen/test_band_ownership.gd
run_script terrain_single_truth res://tests/worldgen/test_terrain_single_truth.gd
run_script slice_and_config_guards res://tests/worldgen/test_slice_and_config_guards.gd
run_script vein_continuity res://tests/worldgen/test_vein_continuity.gd
run_script ore_distribution res://tests/worldgen/test_ore_distribution.gd
run_script golden_hashes res://tests/worldgen/test_golden_hashes.gd
run_script cross_language_hash res://tests/worldgen/test_cross_language_hash.gd

echo "== 世界生成：存档 / 卸载 / 寻路（需要节点树）"
run_scene save_roundtrip res://tests/worldgen/test_save_roundtrip.tscn
run_scene unload_consistency res://tests/worldgen/test_unload_consistency.tscn
run_scene pathfinding_no_gen_storm res://tests/worldgen/test_pathfinding_no_gen_storm.tscn
run_scene version_migration res://tests/worldgen/test_version_migration.tscn
run_scene save_regressions res://tests/worldgen/test_save_regressions.tscn

echo "== 游戏冒烟（真实 main.tscn）"
run_scene boot_smoke res://tests/tool_boot_smoke.tscn

echo "== 基准"
run_script bench_chunk_gen res://tests/bench_chunk_gen.gd

if [ "${1:-}" = "--with-baseline" ]; then
  echo "== 既有基线测试"
  run_scene runtime res://tests/test_runtime.tscn
  run_scene farm res://tests/test_farm.tscn
  run_scene inventory res://tests/test_inventory.tscn
  run_scene features res://tests/test_features.tscn
fi

echo
echo "SUMMARY: pass=$pass fail=$fail"
if [ $fail -ne 0 ]; then
  printf "  失败项：%s\n" "${failed_names[*]}"
  exit 1
fi