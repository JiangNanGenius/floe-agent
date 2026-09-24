# Build 226 dev-document template — PyPI corresponding-source closure (D5)

Status: **gap closed** — sources-only CI run (see `Collector evidence` below)
produced a complete, verified corresponding-source bundle for all four PyPI
wheels pinned by the dev-document template, including the bundled native
PDFium binary of the riscv64 `pypdfium2` wheel. The dev-document image
candidate from image/templates run
[35928029851](https://github.com/JiangNanGenius/floe-agent/actions/runs/35928029851)
(source `706413fd`) is unchanged; this document closes its source-distribution
gate. The basic template and the D4 basic distribution workflow are untouched.

## What was the gap

`collect-corresponding-sources.sh` historically covered kernel/bbl, the
runner relink material, the cross toolchain and the Debian userland only. The
dev-document recipe additionally pins four PyPI wheels
(`FloeAgent/LinuxGuest/image/templates/dev-document.json`), and the riscv64
`pypdfium2` wheel bundles a compiled `pypdfium2_raw/libpdfium.so`. An upstream
source URL alone is not corresponding source: the exact source of the bundled
binary had to be identified, fetched and verifiably linked to the shipped
bytes.

## How the bundled pdfium binary was traced (build provenance)

1. The wheel's own metadata: `pypdfium2_raw/version.json` reports
   `151.0.7913`, `origin: sourcebuild-native` — the binary was built from
   source by pypdfium2's own build system, not taken from
   `bblanchon/pdfium-binaries` (that project publishes no riscv64 builds).
2. pypdfium2 5.13.0 sdist, `setupsrc/base.py`: `SBUILD_NATIVE_PIN = 7913` —
   the hard-coded sourcebuild pin at the 5.13.0 tag (the CI manylinux
   environment in `pyproject.toml` selects `PDFIUM_PLATFORM=sourcebuild-native`
   and passes no `--version`, so this pin applies). Cross-check against the
   wheel metadata: identical build number.
3. `setupsrc/build_native.py` resolves that pin to the pdfium git branch
   `chromium/7913` and clones it (`git clone --depth=1 --revision
   chromium/7913`), i.e. the branch **tip at build time**.
4. Frozen-branch proof: the tip of `chromium/7913` is commit
   `5e6d1de5071fb1d0730e45604a6885eed7f2d6b1` (committer 2026-06-24), while the
   wheel was uploaded 2026-08-13. The branch had not moved between the source
   checkout and today, so the tip commit is exactly the source the CI built.
5. pdfium's `DEPS` at that commit pins 40 further dependency revisions
   (`build`, `abseil-cpp`, `fast_float`, `simdutf`, `icu`, `freetype`,
   `libjpeg_turbo`, `libpng`, `zlib`, `harfbuzz`, …), which
   `build_native.py`'s `DepsFetcher` clones verbatim; pypdfium2's own patches
   (in the sdist) are applied on top. Recorded in `deps-revisions.tsv`.
6. Note: pypdfium2's `autorelease/record.json` in the same sdist names
   pdfium-binaries build `7999`; that is the prebuilt-binary path for arches
   pdfium-binaries covers. The riscv64 wheel provably did not use it
   (`origin: sourcebuild-native`, build 7913). Both numbers are recorded in
   the bundle so the discrepancy is explained, not hidden.

## What the bundle contains (per wheel)

- the wheel bytes themselves, SHA-256-checked against the recipe pin — the
  recipe pin is what the image build downloaded and installed, so this ties
  the bundle to the qualified image;
- the matching PyPI sdist, SHA-256-checked against the PyPI JSON API digest;
- a file-level correspondence proof (every non-generated payload `.py` of the
  wheel is byte-identical in the sdist; console-script wrappers match after
  shebang normalization): python-pptx 101 files, pdfplumber 20, pdfminer.six
  34, pypdfium2 44;
- for pypdfium2 additionally: the pdfium source archive at
  `5e6d1de5071fb1d0730e45604a6885eed7f2d6b1`, the `DEPS` file,
  `deps-revisions.tsv`, and `TREE.sha256` (per-file hashes of all 5293 files —
  gitiles regenerates the gzip bytes per request, so the tree is verified per
  file, not by the archive digest);
- licenses: python-pptx MIT, pdfplumber MIT, pdfminer.six MIT, pypdfium2
  Apache-2.0 OR BSD-3-Clause, pdfium BSD-3-Clause (pdfium itself carries no
  copyleft; this bundle satisfies the project's stricter "verifiable
  corresponding source for every binary" gate, which is stricter than the
  licenses require).

Rebuild recipe (from the collected sdist, manylinux riscv64 container):

```sh
tar -xzf pypdfium2-5.13.0.tar.gz && cd pypdfium2-5.13.0
PDFIUM_PLATFORM=sourcebuild-native BUILD_PARAMS="--vendor all --no-vendor libc++" \
  PDFIUM_VER=7913 python3 setup.py bdist_wheel
```

## Tooling

- `FloeAgent/LinuxGuest/image/collect-pypi-sources.py` — stdlib-only
  collector; `--self-test` (6 offline checks: correspondence rules, DEPS
  parsing, frozen-branch check). Exit 0 = no gaps, 3 = gaps recorded in
  `pypi-source-gaps.tsv` (same contract as `debian-source-map.py`).
- `collect-corresponding-sources.sh` part 5 (`--pypi-recipe`) — invoked by
  the component-image-ci `sources` job with the image evidence's
  `template-recipe.json`; gaps surface in `SOURCES-MANIFEST.md` exactly like
  the Debian gap list.
- The `sources` job uploads `linux-guest-sources-pypi-<run>` (wheels, sdists,
  pdfium source) and extends `linux-guest-source-evidence-<run>` with the
  PyPI manifests.

## Collector evidence

Sources-only collection against the unchanged image run 35928029851:

- Collector run: [35939078878](https://github.com/JiangNanGenius/floe-agent/actions/runs/35939078878), succeeded.
- `linux-guest-sources-pypi-35939078878`: wheels/ + sdists/ + pdfium-source/; artifact 10784198490, 42,540,124 bytes.
- `pypi-source-gaps.tsv`: header only.
- `SOURCES-MANIFEST.md` section 5 `gap_packages=0`.

Local verification before dispatch (2026-09-24, this Mac):
`collect-pypi-sources.py --self-test` 6/6; full run against
`templates/dev-document.json` rc=0, header-only gap file, per-file tree hash
cross-check of two independently generated gitiles archives identical
(5293/5293 files).

## Boundaries

- The image candidate, its manifest, boot files and IDs are unchanged; no
  rebuild, no repin. The basic template artifact and the D4 basic
  distribution workflow were not modified.
- The pdfium *build closure* (chromium `build/` tooling, clang, sysroot) is
  identified by `deps-revisions.tsv` + the recorded CI environment and is
  re-fetched by the rebuild recipe; it is toolchain material, not source of
  the distributed binary, and is not mirrored into the bundle.
- Distribution remains gated by the primary release decision; this bundle is
  material for the source offer, not the offer.
