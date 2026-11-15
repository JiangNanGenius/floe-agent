#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Independent source-only bounds check for the generated quarter tables.

It re-reads RPGAutotileTables.swift and verifies that every A1/A2/A3/A4 shape
and every A5/B..E cell fits the standard XP/VX/Ace/MV/MZ sheet dimensions.
This is not a substitute for compiling or rendering.
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT / "Sources/FloeRPGTilesetKit/RPGAutotileTables.swift").read_text()


def pairs(name):
    match = re.search(r"static let " + name + r": \[\[\(Int, Int\)\]\] = \[\n(.*?)\n\]", SRC, re.S)
    return [[(int(a), int(b)) for a, b in re.findall(r"\((\d+), (\d+)\)", line)]
            for line in match.group(1).splitlines() if line.strip()]


def ints(name):
    match = re.search(r"static let " + name + r": \[\[Int\]\] = \[\n(.*?)\n\]", SRC, re.S)
    return [[int(v) for v in re.findall(r"\d+", line)]
            for line in match.group(1).splitlines() if line.strip()]


FLOOR, WALL, WATER, XP = pairs("floor"), pairs("wall"), pairs("waterfall"), ints("xp")


def check(engine, tile, sizes):
    half = tile // 2
    errors = []

    def fits(rects, label, size):
        for x, y, w, h in rects:
            if x < 0 or y < 0 or x + w > size[0] or y + h > size[1]:
                errors.append((label, x, y, w, h, size))

    for kind in range(16):
        for frame in range(3):
            if engine in ("mv", "mz"):
                water = [0, 1, 2, 1][frame % 4]
                waterfall = frame % 3
                tx, ty = kind % 8, kind // 8
                bx = by = 0
                table = FLOOR
                if kind == 0:
                    bx = water * 2
                elif kind == 1:
                    bx = water * 2
                    by = 3
                elif kind == 2:
                    bx = 6
                elif kind == 3:
                    bx = 6
                    by = 3
                else:
                    bx = (tx // 4) * 8
                    by = ty * 6 + ((tx // 2) % 2) * 3
                    if kind % 2 == 0:
                        bx += water * 2
                    else:
                        bx += 6
                        table = WATER
                        by += waterfall
            else:
                ident = kind
                if ident in (1, 2):
                    ident ^= 3
                id0, id1 = ident % 2, (ident // 2) % 2
                id2, id3 = (ident // 4) % 2, ident // 8
                bx = id2 * 8 + (frame % 3 * 2 if id0 == 0 else 6)
                by = (id1 + id3 * 2) * 3
                table = FLOOR
            for shape in range(len(table)):
                rects = [((bx * 2 + qsx) * half, (by * 2 + qsy) * half, half, half)
                         for qsx, qsy in table[shape]]
                fits(rects, f"A1 k{kind} f{frame} s{shape}", sizes["A1"])
    for kind in range(16, 128):
        if kind < 48:
            key, tx, ty = "A2", kind % 8, kind // 8 - 2
            bx, by, table = tx * 2, ty * 3, FLOOR
        elif kind < 80:
            key, tx, ty = "A3", kind % 8, kind // 8 - 6
            bx, by, table = tx * 2, ty * 2, WALL
        else:
            key, tx, ty = "A4", kind % 8, kind // 8
            wall = ty % 2 == 1
            bx, by = tx * 2, int(((ty - 10) * 5) // 2 + (0.5 if wall else 0))
            table = WALL if wall else FLOOR
        for shape in range(len(table)):
            rects = [((bx * 2 + qsx) * half, (by * 2 + qsy) * half, half, half)
                     for qsx, qsy in table[shape]]
            fits(rects, f"{key} k{kind} s{shape}", sizes[key])
    for local in range(128):
        fits([((local % 8) * tile, (local // 8) * tile, tile, tile)], f"A5 {local}", sizes["A5"])
    for local in range(256):
        fits([((local % 16) * tile, (local // 16) * tile, tile, tile)], f"B {local}", sizes["B"])
    return errors


def main():
    configurations = {
        "vx": (32, {"A1": (512, 384), "A2": (512, 384), "A3": (512, 256),
                    "A4": (512, 480), "A5": (256, 512), "B": (512, 512)}),
        "ace": (32, {"A1": (512, 384), "A2": (512, 384), "A3": (512, 256),
                     "A4": (512, 480), "A5": (256, 512), "B": (512, 512)}),
        "mv": (48, {"A1": (768, 576), "A2": (768, 576), "A3": (768, 384),
                    "A4": (768, 720), "A5": (384, 768), "B": (768, 768)}),
        "mz": (48, {"A1": (768, 576), "A2": (768, 576), "A3": (768, 384),
                    "A4": (768, 720), "A5": (384, 768), "B": (768, 768)}),
    }
    total = 0
    for engine, (tile, sizes) in configurations.items():
        errors = check(engine, tile, sizes)
        total += len(errors)
        print(f"{engine}: {len(errors)} out-of-bounds source rects")
    xp_errors = 0
    for autotile in range(7):
        for shape in range(48):
            for quarter in range(4):
                index = XP[quarter][shape]
                x, y = (index % 6) * 16, (index // 6) * 16
                if x + 16 > 96 or y + 16 > 128:
                    xp_errors += 1
    total += xp_errors
    print(f"xp: {xp_errors} out-of-bounds autotile quarter rects")
    print("TOTAL", total)
    raise SystemExit(0 if total == 0 else 1)


if __name__ == "__main__":
    main()
