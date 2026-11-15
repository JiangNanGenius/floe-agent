# Third-party notices and provenance

This package ships **original Swift code and original synthetic fixture art**.
It contains no proprietary RPG Maker RTP/Enterbrain artwork, default scripts,
fonts or editor resources.

## RPG Maker MV CoreScript (MIT)

- Source: `ReferenceSources/corescript`
- Commit: `182e31449707ba7e406db0485c44c2a9d11e2dcd`
- Copyright: Copyright (c) 2015 KADOKAWA CORPORATION./YOJI OJIMA
- Files consulted: `dist/rpg_core.js`, `Tilemap` tile-id constants, sheet
  dimensions and the `FLOOR_AUTOTILE_TABLE`, `WALL_AUTOTILE_TABLE` and
  `WATERFALL_AUTOTILE_TABLE`.
- What was reused: the factual 4x6 mini-tile quarter-selection tables and
  documented tile-id/sheet layout facts. They are re-expressed as Swift tuple
  data in `Sources/FloeRPGTilesetKit/RPGAutotileTables.swift` by
  `Tools/generate_autotile_tables.py`. No JavaScript code was copied or
  translated line-for-line; the renderer, planner, cache and editor are
  original Swift.
- License: MIT. Full text retained below.

```
MIT License

Copyright (c) 2015 KADOKAWA CORPORATION./YOJI OJIMA

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## qnighy/tapir (Apache-2.0 OR MIT; MIT selected)

- Source: `ReferenceSources/tapir`
- Commit: `a56b1946b69a408db2ff5f79b48a6682cd7dd957`
- Copyright 2017 Masaki Hara, as retained in the actual `src/Tilemap.c` header; the broader project also retains contributor copyrights.
- Files consulted: `src/Tilemap.c` (`autotile_lookup` XP 6x8 quarter table and
  the A1 kind-placement formulas). No C code is compiled, copied or translated.
- What was reused: factual quarter-selection indices and A1 placement facts,
  re-expressed as Swift integer tables/formulas in
  `RPGAutotileTables.swift` and `RPGTileGeometry.swift`.
- License selected: MIT (the project is dual-licensed Apache-2.0 OR MIT). Full
  MIT text retained below. The exact source header and license also accompany
  the compiled package under Resources/.

```
Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

The compiled Swift module includes original full notices as resources; the
reference source files used to regenerate the tables are pinned and retained
in `ReferenceSources/`. No Ruby runtime is linked by this renderer.

## GPL research record (not part of this package)

During early format research, `pulsejet/mkxp-web` `tileatlasvx.cpp` /
`autotilesvx.cpp` were read to understand RTP sheet layouts. **No mkxp code,
table, constant or translated implementation was copied into this package.**
Those files are GPL-2.0-or-later and are deliberately excluded. All shipped
table/formula provenance is the MIT CoreScript and MIT/Apache Tapir sources
above. The package does not link or depend on mkxp or any GPL library.

## Vendored Floe packages

`Vendor/FloeGameKit`, `Vendor/FloeGameEditingKit` and
`Vendor/FloeRPGProjectKit` are private, reduced copies of the authoritative
Main modules (MPL-2.0) used only to build this independent package. Their
baseline hashes and the one intentionally changed UI file are listed in
`VENDORED.md` and `BASELINE-SOURCES.json`. Root owns the guarded merge back to
Main.

## Imported user assets

The renderer resolves only files declared by the current project. It never
downloads, copies or borrows an RTP installation or another project's images,
and it never relicenses imported user art. Missing/ambiguous assets are
reported; the original map data is retained.
