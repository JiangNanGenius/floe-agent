# TurningNative — attribution and provenance

## Vendored upstream: LibLathe (GPL-2.0)

- Repository: https://github.com/dubstar-04/LibLathe
- Pinned commit: `4bac3400813f40a15e0bf22e12998453e337d96e` (upstream HEAD as
  checked on 2026-11-04; commit date 2026-10-22)
- License: GNU General Public License v2.0 — see `Vendor/liblathe/LICENSE`
  (byte-identical to upstream LICENSE, sha256
  `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643`).
- Vendored files under `Vendor/liblathe/base/` (`point`, `segment`,
  `boundbox`, `segmentgroup`, `quadtree` `.h`/`.cpp`, `utils.h`) are verbatim,
  unmodified copies of the pinned upstream files; each was re-downloaded from
  the pinned ref and sha256-compared during this task (all MATCH). The
  upstream `*_py.cpp` pybind11 bindings are intentionally NOT vendored: this
  target has no Python/pybind11 runtime.

## Ported operation logic (kept under GPL-2.0)

`src/turn_ops.h/.cpp` is a mechanical C++ port of the pinned upstream Python:

- `liblathe/op/base.py` → `turning::BaseOP`, `turning::OpParams::apply`
- `liblathe/op/face.py` → `turning::FaceOP`
- `liblathe/op/rough.py` → `turning::RoughOP`
- `liblathe/op/profile.py` → `turning::ProfileOP`

`src/turn_tool.h/.cpp` (R4) is a mechanical C++ port of the pinned upstream
insert construction in `liblathe/tool/tool.py`:

- `get_segmentgroup_from_string_rectangle` (shapes C, D, S, V) →
  `turning::buildRectangle`
- `get_segmentgroup_from_string_round` (shape R) → `turning::buildRound`
- `get_segmentgroup_from_string_triangle` (shape T) → `turning::buildTriangle`
- `rotate_tool_shape` → `turning::rotateShape`
- `toolProfileOutline` is own code (no upstream equivalent): it exports the
  exact insert outline for the R4 `setupReceipt`; polygon shapes are exact,
  shape R is the exact circle sampled at a fixed 2-degree step.

Only the shapes the pinned upstream actually constructs (C, D, S, V, R, T)
are supported; every other shape character is refused explicitly. Like the
pinned upstream builders, all of them ignore the nose radius — no
nose-radius compensation is claimed or implemented.

Because the port is a derivative of GPL-2.0 sources, the whole
`TurningNative` target is GPL-2.0. Keep this attribution with any copy.

## Own code (no external dependency)

- `src/fmjson.h` — narrow finite JSON reader/writer written for this
  prototype (no third-party code).
- `src/turn_plan.cpp` — C ABI boundary, request validation (including the R4
  `turningSetup` schema) and result serialisation written for this prototype.
- R4 additions in `src/turn_plan.cpp` — `turningSetup` decode/validation, the
  per-segment directional-feed emission (pure X/pure Z/diagonal component
  limits) and the `setupReceipt` serialiser are own code implementing the
  local R4 contract on top of the ported operations.

## Tooling note

Without a `turningSetup` request the tool shape used for
defeature/rough/profile clearance checks is the fixed insert equivalent to
upstream's `DCMT070204R` (rhombic 55°, edge length 6.35 mm, no rotation),
matching what upstream examples use; `buildInsertShape('D', 6.35, 0)`
reproduces the exact pre-R4 geometry. With `turningSetup`, the configured
insert shape/edge length/rotation is built by the ported upstream builders
and used for defeature. Upstream's builders ignore the nose radius, so the
contract's `toolNoseRadiusMM` is validated and recorded but does not alter
the tool shape (faithful to the pinned upstream behaviour).
