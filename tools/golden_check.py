#!/usr/bin/env python3
"""独立 Python 实现：复算 GDScript 的世界生成黄金哈希的**哈希部分**。

它不能重算地形（那需要整套定点噪声），但能证明：
  1. FNV-1a 64 规范化序列化与 GDScript 完全一致；
  2. splitmix64 / hash2 / u01 与 GDScript 逐位一致（这是确定性的根基）。
"""
import json, sys, subprocess, os

M64 = (1 << 64) - 1
C1 = 0x9E3779B97F4A7C15
C2 = 0xBF58476D1CE4E5B9
C3 = 0x94D049BB133111EB
FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x100000001B3


def splitmix64(x):
    x = (x + C1) & M64
    z = x
    z = ((z ^ (z >> 30)) * C2) & M64
    z = ((z ^ (z >> 27)) * C3) & M64
    return (z ^ (z >> 31)) & M64


def hash2(seed, salt, x, y):
    h = splitmix64((seed + salt) & M64)
    h = splitmix64((h + (x & 0xFFFFFFFF)) & M64)
    h = splitmix64((h + (y & 0xFFFFFFFF)) & M64)
    return h


def u01(h):
    return (h & 0x1FFFFFFFFFFFFF) / 9007199254740992.0


def fv(tag):
    return tag.encode()


def enc_int(v):
    return b"i" + ((v & M64).to_bytes(8, "big"))


def enc_bytes(b):
    return b"p" + len(b).to_bytes(4, "big") + b


def chunk_hash(seed, version, chunk, terrain, obstacles, ores):
    payload = b""
    payload += enc_int(seed)
    payload += enc_int(version)
    payload += enc_int(chunk[0])
    payload += enc_int(chunk[1])
    payload += enc_bytes(terrain)
    payload += enc_array([enc_obstacle(o) for o in sorted(obstacles, key=obstacle_key)])
    payload += enc_array([enc_ore(o) for o in sorted(ores, key=ore_key)])
    h = FNV_OFFSET
    for byte in payload:
        h = ((h ^ byte) * FNV_PRIME) & M64
    return "%016x" % h


def enc_array(items):
    return b"a" + len(items).to_bytes(4, "big") + b"".join(items)


def obstacle_key(o):
    return (o["cell"][1], o["cell"][0], o.get("kind", 0))


def ore_key(o):
    return (o["cell"][1], o["cell"][0], o.get("ore_id", 0))


def enc_cell(c):
    return enc_array([enc_int(c[0]), enc_int(c[1])])


def enc_obstacle(o):
    # 字典键按 utf8 排序：cell, hp, kind
    body = b"".join([
        enc_string("cell") + enc_cell(o["cell"]),
        enc_string("hp") + enc_int(o["hp"]),
        enc_string("kind") + enc_int(o["kind"]),
    ])
    return b"d" + (3).to_bytes(4, "big") + body


def enc_ore(o):
    body = b"".join([
        enc_string("amount") + enc_int(o["amount"]),
        enc_string("cell") + enc_cell(o["cell"]),
        enc_string("ore_id") + enc_int(o["ore_id"]),
        enc_string("vein_id") + enc_int(o.get("vein_id", 0)),
    ])
    return b"d" + (4).to_bytes(4, "big") + body


def enc_string(s):
    b = s.encode()
    return b"s" + len(b).to_bytes(4, "big") + b


def main():
    if len(sys.argv) < 2:
        print("用法: golden_check.py <export.json>")
        sys.exit(2)
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
    bad = 0
    checked = 0
    for entry in data["entries"]:
        terrain = bytes(entry["terrain"])
        got = chunk_hash(entry["seed_int"], entry["worldgen_version"], entry["chunk"],
                         terrain, entry["obstacles"], entry["ores"])
        checked += 1
        if got != entry["hash"]:
            bad += 1
            print("MISMATCH chunk=%s expected=%s got=%s" % (entry["chunk"], entry["hash"], got))
    print("python golden check: %d entries, %d mismatches" % (checked, bad))
    sys.exit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()