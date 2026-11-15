#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Regenerate Sources/FloeRPGTilesetKit/RPGAutotileTables.swift from the
permitted MIT/Apache layout sources. This script never reads mkxp/GPL code.

Sources (private, read-only):
  - RPG Maker MV CoreScript 1.3b, commit 182e31449707ba7e406db0485c44c2a9d11e2dcd (MIT)
  - qnighy/tapir, commit a56b1946b69a408db2ff5f79b48a6682cd7dd957 (Apache-2.0 OR MIT)
"""
import re
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "ReferenceSources/corescript/dist/rpg_core.js"
TAPIR = ROOT / "ReferenceSources/tapir/src/Tilemap.c"
OUT = ROOT / "Sources/FloeRPGTilesetKit/RPGAutotileTables.swift"



def js_table(core_text: str, name: str):
    match = re.search(r"Tilemap\." + name + r" = \[(.*?)\n\];", core_text, re.S)
    body = match.group(1)
    rows = re.findall(r"\[((?:\[[^\]]*\]\s*,?\s*)+)\]", body)
    return [[(int(a), int(b)) for a, b in re.findall(r"\[(\d+),(\d+)\]", row)] for row in rows]


def swift_pairs(name: str, table):
    lines = [f"static let {name}: [[(Int, Int)]] = ["]
    for row in table:
        lines.append("    [" + ", ".join(f"({a}, {b})" for a, b in row) + "],")
    lines.append("]")
    return "\n".join(lines)


def swift_ints(name: str, table):
    lines = [f"static let {name}: [[Int]] = ["]
    for row in table:
        lines.append("    [" + ", ".join(str(v) for v in row) + "],")
    lines.append("]")
    return "\n".join(lines)


def main():
    pins = json.loads((ROOT / "ReferenceSources/PINS.json").read_text())
    for item in pins["files"]:
        assert hashlib.sha256((ROOT / item["path"]).read_bytes()).hexdigest() == item["sha256"], item["path"]
    core_text = CORE.read_text()
    floor = js_table(core_text, "FLOOR_AUTOTILE_TABLE")
    wall = js_table(core_text, "WALL_AUTOTILE_TABLE")
    waterfall = js_table(core_text, "WATERFALL_AUTOTILE_TABLE")
    tapir_text = TAPIR.read_text()
    start = tapir_text.index("static const int autotile_lookup[4][48] = {")
    end = tapir_text.index("};", start)
    body = tapir_text[start + len("static const int autotile_lookup[4][48] = {"):end]
    xp = [[int(v) for v in re.findall(r"-?\d+", row)]
          for row in re.findall(r"\{([^{}]*)\}", body)]
    output = f'''// SPDX-License-Identifier: MPL-2.0
// Generated quarter-selection tables. Do not hand-edit; see
// Tools/generate_autotile_tables.py and THIRD_PARTY_NOTICES.md.
//
// MV/MZ FLOOR/WALL/WATERFALL rows are adapted from the official RPG Maker MV
// CoreScript (MIT), commit 182e31449707ba7e406db0485c44c2a9d11e2dcd,
// Copyright (c) 2015 KADOKAWA CORPORATION./YOJI OJIMA. The tables are factual
// quarter-selection geometry; the Swift representation is original.
//
// The XP 6x8 lookup is adapted from qnighy/tapir, commit
// a56b1946b69a408db2ff5f79b48a6682cd7dd957, licensed Apache-2.0 OR MIT
// (MIT selected). Copyright 2017 Masaki Hara; actual source notice retained
// in Resources/Tapir-Tilemap-MIT.txt and THIRD_PARTY_NOTICES.md.
enum RPGAutotileTables {{
    /// 48 floor/ground shapes. Each entry is four (qsx, qsy) pairs for
    /// top-left, top-right, bottom-left, bottom-right destination quarters.
{swift_pairs("floor", floor)}
    /// 16 wall/roof shapes, addressed by shape % 16.
{swift_pairs("wall", wall)}
    /// Four waterfall shapes.
{swift_pairs("waterfall", waterfall)}
    /// XP's 96x128 autotile layout: four source-quarter indices per shape,
    /// indexed as sourceIndex % 6 (column) and / 6 (row) in 16px units.
{swift_ints("xp", xp)}
}}
'''
    OUT.write_text(output)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
