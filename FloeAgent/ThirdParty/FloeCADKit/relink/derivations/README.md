# Required OCCT source derivations

This directory carries the tracked source and tooling for the one OCCT source
change FloeCADKit applies above the pinned upstream base: the
`Standard_Type` registry lifetime backport in `src/Standard/Standard_Type.cxx`.

The base archives in `Vendor/OCCT.xcframework/` remain the exact upstream
OpenShape3D Git-LFS objects pinned by `DEPENDENCIES.json`. The installed
slices are **not** those bytes: they are reconstructed surgically from the
pinned base by replacing exactly one archive member and rebuilding its symbol
index. Every other object payload is verified byte-identical to the base.
This is not a full 47-toolkit source rebuild and makes no such claim.

## Layout

| Path | Purpose |
| --- | --- |
| `standard-type-lifetime.v1.json` | Recipe: OCCT commit, base/overlay/patch hashes, member + public-API pattern, per-slice base archive/member digests, build flags, qualified toolchain, limitations |
| `standard-type-lifetime/base/src/Standard/Standard_Type.cxx` | Exact upstream 7.8.1 base file |
| `standard-type-lifetime/overlay/src/Standard/Standard_Type.cxx` | Exact patched source compiled into the replacement object |
| `standard-type-lifetime/minimal.patch` | Unified diff from base to overlay |
| `occt_archive.py` | Strict BSD ar parsing, deterministic single-member splice, index/offset verification |
| `derivation_common.py` | Recipe/receipt contract shared by the producer and `bootstrap.py --check` |
| `derive_standard_type_slice.py` | Producer: compile one object, splice, verify and write a receipt; also `record`, `verify`, `inspect` |

## Contract

`DEPENDENCIES.json` (schema 2) declares, per slice:

- the upstream base size/SHA-256 and Git-LFS source (the integrity anchor);
- `derivation.id`, the tracked recipe path and recipe SHA-256, the receipt path;
- `expectedResult`: the qualified derived archive size/SHA-256. It is recorded
  from the actual Root-qualified artifact after `--release-check` can prove it,
  and is enforced by the release gate (and by normal preparation when the
  local toolchain equals the qualified one).

The receipt beside each installed slice records the base pin, recipe/source/
patch hashes, compiler/SDK/target/flags, the base and derived object hashes,
the actual 14-symbol `Standard_Type` class API/vtable/typeinfo set shared by
the base and derived objects, the symbol-index size/hash, the non-target
member aggregate digest and the resulting archive hash. It is a derivation
record, not a signature; release integrity additionally depends on the tracked
recipe/`expectedResult` and review.

`bootstrap.py` semantics:

```sh
python3 bootstrap.py                 # fetch/verify base + derive both slices
python3 bootstrap.py --check         # read-only: PREPD / UNPREP / STALE / UNDERI
python3 bootstrap.py --release-check # read-only release gate: qualified toolchain + expectedResult
```

The bare upstream base is reported `UNPREPARED` and fails; it is never
accepted as a usable slice. `--local-relink` remains an honest presence-only
opt-in for a developer's own rebuild, but cannot satisfy `--release-check`.

## Root workflow for an already-qualified artifact

If an actual qualified object/archive pair already exists (for example the
Root `occt-rtti-backport-2` two-slice result), bind it without recompiling:

```sh
python3 relink/derivations/derive_standard_type_slice.py record \
  --package-root . \
  --recipe relink/derivations/standard-type-lifetime.v1.json \
  --slice device \
  --base /path/to/original-libOCCT-OS64.a \
  --object /path/to/Standard_Type.cxx.o \
  --archive /path/to/libOCCT-OS64.a \
  --receipt Vendor/OCCT.xcframework/ios-arm64/libOCCT-OS64.a.derivation.json \
  --toolchain-json /path/to/qualified-toolchain.json
```

`record` does not compile or install. It proves that the tracked recipe
reproduces the supplied archive byte-for-byte from the pinned base plus the
supplied object, validates the object/ABI facts, and writes the same receipt
shape as a normal derivation. It refuses arbitrary bytes that the recipe does
not reproduce.

Toolchain metadata must include `xcodeVersion`, `xcodeBuild`, `sdkVersion`,
`sdkName`, `sdkPath`, `clangVersion`, `target` and `compileFlags`. The exact
qualified command used by Root is recorded in the private release artifact
record referenced by the handoff.

## Honest limits

- The base archive is the upstream artifact pin; the derived slice
  intentionally differs from it.
- Only `Standard_Type.cxx.o` changes. The recipe and verifier prove every
  other object payload and the member order are unchanged.
- The public-ABI check compares the actual 14-symbol class API/vtable/typeinfo
  set shared by the pinned base and the derived object; it does not hardcode a
  compiler-dependent total symbol count.
- Derivation does not prove a runtime outcome. The release owner must run the
  native normal-exit probe, the App/XCTest process-exit gate and the ordinary
  regression scope before release.
- OCCT remains LGPL-2.1 with the Open CASCADE exception; the base, patched
  source and diff are retained here for source availability and relinking.

## Closed-profile guide contact: second derivation stage

`guided-contact.v1.json` adds a single `GeomFill_LocationGuide.cxx.o` replacement after the required Standard_Type lifetime repair. The manifest retains the original upstream archive pins and declares the existing lifetime descriptor as `derivation.parent`; the child recipe binds its ID/hash and pins the exact parent outputs. The final receipt embeds the validated parent receipt. Both stages retain ordinary source, symbol, toolchain and expected-result checks; every non-target member of stage two, including Standard_Type, remains byte-identical.

A verified installed parent is reused, including offline. A fresh bootstrap derives the lifetime object first and the contact object second. `--check` validates both receipts and source hashes without writing; `--release-check` requires both qualified toolchains and tracked expected results. No LOCAL exemption is used. Full source and the minimal LGPL backport are retained in `guided-contact/{base,overlay,minimal.patch}`. The existing generic producer also supports `record` for already compiled, independently verified object/archive pairs; recording metadata never substitutes for native geometry tests.
