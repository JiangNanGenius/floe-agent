#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Deterministic CupertinoIcons.ttf -> ImageVector pathData generator.
#
# Regenerates core/designsystem/src/main/kotlin/com/floe/android/design/FloeGlyphs.kt
# from the pinned upstream inputs in licenses/cupertino-icons/upstream/.
#
#   python3 FloeAndroid/tools/icons/generate_floe_glyphs.py [--check]
#     FONTTOOLS_WHEEL=/path/to/fonttools-4.60.1-py3-none-any.whl (sys.path only, no install)
#     --check: regenerate in memory and fail unless the committed file is byte-identical.
#
# Inputs (SHA-256 enforced, mirrored in licenses/cupertino-icons/PROVENANCE.json):
#   CupertinoIcons.ttf          assets from cupertino_icons 2.0.0 pub archive b7cc2390...
#   flutter-3.35.0-icons.dart   pinned codepoint-name table 903e47d2...
#   fonttools 4.60.1 wheel      generation-time only        906306ac...
#
# Transform (global uniform; relative optical sizes preserved between glyphs):
#   K = min(20.0/(median_ink_h_em*24), 22.0/(max_ink_w_em*24)) floored to 3dp
#   s = K * 24 / unitsPerEm ; x' = (x-cx_ink)*s+12 ; y' = (cy_ink-y)*s+12
import argparse, hashlib, json, math, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))  # FloeAndroid/
UP = os.path.join(ROOT, "licenses", "cupertino-icons", "upstream")
OUT_KT = os.path.join(ROOT, "core", "designsystem", "src", "main", "kotlin",
                      "com", "floe", "android", "design", "FloeGlyphs.kt")
EXPECTED = {
    "CupertinoIcons.ttf": "67c44fe9183b002e79dde7f6977e2988661c9a3e4a3c5fce968787efdbed823c",
    "flutter-3.35.0-icons.dart": "903e47d2459d68350a5298a57c35a122c43bf07f116e5faba562e1a384cb90a2",
}
WHEEL_EXPECTED = "906306ac7afe2156fcf0042173d6ebbb05416af70f6b370967b47f8f00103bbb"
PUB_ARCHIVE_SHA = "b7cc2390aac296c083bea762859413eb1cf5b630c70e0c7e4d831018f762a8b2"

def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--wheel", default=os.environ.get("FONTTOOLS_WHEEL", ""))
    args = ap.parse_args()
    for fname, want in EXPECTED.items():
        got = sha256(os.path.join(UP, fname))
        assert got == want, f"pinned input hash mismatch for {fname}: {got}"
    wheel = args.wheel
    assert wheel and os.path.exists(wheel), "set FONTTOOLS_WHEEL to the fonttools 4.60.1 wheel"
    assert sha256(wheel) == WHEEL_EXPECTED, "fonttools wheel hash mismatch"
    sys.path.insert(0, wheel)
    from fontTools.ttLib import TTFont
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.boundsPen import BoundsPen

    src = open(os.path.join(UP, "flutter-3.35.0-icons.dart")).read()
    name2cp = {n: int(c, 16) for n, c in
               re.findall(r"static const IconData (\w+) = IconData\(\s*0x([0-9a-fA-F]+),", src)}
    roles = json.load(open(os.path.join(ROOT, "tools", "icons", "roles.json")))

    f = TTFont(os.path.join(UP, "CupertinoIcons.ttf"))
    upem = f["head"].unitsPerEm
    cmap = f.getBestCmap()
    glyphSet = f.getGlyphSet()

    NUM_RE = re.compile(r"-?\d*\.?\d+")
    SEG_RE = re.compile(r"([MLQHVZ])([^MLQHVZ]*)")

    def expand(d):
        out, cur, start = [], None, None
        for cmd, rest in SEG_RE.findall(d):
            nums = [float(t) for t in NUM_RE.findall(rest)]
            if cmd in ("M", "L"):
                for j, p in enumerate(zip(nums[0::2], nums[1::2])):
                    if cmd == "M" and j == 0:
                        out.append(("M", p)); start = p
                    else:
                        out.append(("L", p))
                    cur = p
            elif cmd == "H":
                for x in nums:
                    p = (x, cur[1]); out.append(("L", p)); cur = p
            elif cmd == "V":
                for y in nums:
                    p = (cur[0], y); out.append(("L", p)); cur = p
            elif cmd == "Q":
                for i in range(0, len(nums), 4):
                    c = (nums[i], nums[i + 1]); e = (nums[i + 2], nums[i + 3])
                    out.append(("Q", c, e)); cur = e
            elif cmd == "Z":
                out.append(("Z", None)); cur = start
        return out

    entries = []
    for r in roles["converted"]:
        key = r["key"]
        cp = name2cp[key]
        assert cp in cmap, f"codepoint {hex(cp)} for {key} absent from pinned font"
        gname = cmap[cp]
        pen = SVGPathPen(glyphSet); glyphSet[gname].draw(pen)
        bp = BoundsPen(glyphSet); glyphSet[gname].draw(bp)
        x0, y0, x1, y1 = bp.bounds or (0, 0, 0, 0)
        entries.append(dict(r, cp=cp, gname=gname, d=pen.getCommands() or "",
                            bbox=(x0, y0, x1, y1),
                            h=(y1 - y0) / upem, w=(x1 - x0) / upem))

    hs = sorted(e["h"] for e in entries)
    median_h = hs[len(hs) // 2]
    max_w = max(e["w"] for e in entries)
    k = min(20.0 / (median_h * 24.0), 22.0 / (max_w * 24.0))
    k = math.floor(k * 1000) / 1000.0
    s = k * 24.0 / upem

    def fmt(v):
        t = f"{v:.2f}".rstrip("0").rstrip(".")
        return "0" if t in ("-0", "") else t

    def transform(e):
        x0, y0, x1, y1 = e["bbox"]
        cx, cy = (x0 + x1) / 2.0, (y0 + y1) / 2.0
        def T(p):
            return (fmt((p[0] - cx) * s + 12.0), fmt((cy - p[1]) * s + 12.0))
        parts = []
        for seg in expand(e["d"]):
            if seg[0] == "Z":
                parts.append("Z")
            elif seg[0] == "Q":
                a, b = T(seg[1]), T(seg[2])
                parts.append(f"Q{a[0]} {a[1]} {b[0]} {b[1]}")
            else:
                a = T(seg[1])
                parts.append(f"{seg[0]}{a[0]} {a[1]}")
        return " ".join(parts)

    for e in entries:
        e["pathData"] = transform(e)
        xs = [float(v) for v in NUM_RE.findall(e["pathData"])]
        assert -1.5 <= min(xs) and max(xs) <= 25.5, f"{e['key']} coord outlier"

    header = (
        "// SPDX-License-Identifier: MPL-2.0\n"
        "// Generated file - DO NOT EDIT BY HAND.\n"
        "//\n"
        "// Glyph outlines converted from CupertinoIcons.ttf (Flutter third_party package\n"
        "// `cupertino_icons` 2.0.0, MIT License, Copyright (c) 2016 Vladimir Kharlampidi).\n"
        "// The font binary is NOT shipped or depended on at runtime; only these\n"
        "// source-generated vector path strings are compiled into the app.\n"
        "//\n"
        "// Upstream MIT text ships at app/src/main/assets/legal/cupertino-icons/LICENSE\n"
        "// and FloeAndroid/licenses/cupertino-icons/LICENSE. Pins and generator:\n"
        "//   pub archive cupertino_icons-2.0.0.tar.gz sha256 " + PUB_ARCHIVE_SHA + "\n"
        "//   assets/CupertinoIcons.ttf sha256 " + EXPECTED["CupertinoIcons.ttf"] + "\n"
        "//   codepoint names: flutter 3.35.0 packages/flutter/lib/src/cupertino/icons.dart\n"
        "//              (BSD-3-Clause, The Flutter Authors; text at licenses/cupertino-icons/upstream/Flutter-BSD-LICENSE)\n"
        "//              sha256 " + EXPECTED["flutter-3.35.0-icons.dart"] + "\n"
        "//   converter: FloeAndroid/tools/icons/generate_floe_glyphs.py + roles.json\n"
        "//              (fontTools 4.60.1 wheel sha256 " + WHEEL_EXPECTED + ", sys.path only)\n"
        f"//   transform: uniform scale K={k} x (24/{upem}), Y-flip, per-glyph ink centering at (12,12)\n"
        "//\n"
        "// These paths carry iOS shell semantics for the Floe Android design system.\n"
        "package com.floe.android.design\n\n"
        "internal object FloeGlyphPaths {\n    val all: Map<String, String> = mapOf(\n"
    )
    body = "".join(f'        "{e["key"]}" to\n            "{e["pathData"]}",\n' for e in entries)
    text = header + body + "    )\n}\n"

    if args.check:
        committed = open(OUT_KT).read()
        if committed != text:
            print("DRIFT: regenerate without --check", file=sys.stderr)
            sys.exit(1)
        print("check OK:", OUT_KT)
    else:
        open(OUT_KT, "w").write(text)
        print("generated:", len(entries), "glyphs, K:", k, "->", OUT_KT)

if __name__ == "__main__":
    main()
