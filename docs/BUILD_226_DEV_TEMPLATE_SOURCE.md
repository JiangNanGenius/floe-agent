# Build 226 dev-document template — PyPI corresponding-source closure (D5)

Status: **gap closed and distributed** — sources-only CI run (see `Collector
evidence` below) produced a complete, verified corresponding-source bundle for
all four PyPI wheels pinned by the dev-document template, including the
bundled native PDFium binary of the riscv64 `pypdfium2` wheel; the unchanged
candidate was then published as the
`floe-linux-template-dev-document-20260924.1` component prerelease with the
full source bundle (see `Distribution record` below). The dev-document image
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

## Distribution (D6)

`.github/workflows/linux-template-distribute-dev.yml` turns the unchanged image
candidate and this closed source bundle into one published GitHub component
prerelease (`floe-linux-template-dev-document-20260924.1`), then the App pins
the exact released archive. The workflow pins two retained runs, re-verifies
every artifact id/byte size and digest through the GitHub API before
downloading, and fails closed on any gap:

- image/templates run 35928029851 (`706413fd…`): image candidate
  `10780911713`, image evidence `10781270686`, template qualification
  `10781380423`;
- corresponding-sources run 35939078878 (`2f4bd52d…`): upstream/relink/
  toolchain `10784446321`, Debian shards `10783544157` + `10783873015`,
  source evidence `10783618931`, PyPI sources `10784198490`.

The distribute job re-checks the candidate archive sha512 and every member
digest, rewrites only the manifest provenance, verifies the complete source
tree (including the PyPI payload against the recipe pins and
`PYPI-SOURCES.sha256`), and only then creates the prerelease.

### Distribution record (D6)

- Release:
  [floe-linux-template-dev-document-20260924.1](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-template-dev-document-20260924.1)
  — published prerelease (not a draft, not `latest`), tag target
  `3680d77a`; published 2026-09-24T01:18:06Z by distribution run
  [35941775534](https://github.com/JiangNanGenius/floe-agent/actions/runs/35941775534)
  (preflight + distribute both succeeded).
- 16 assets; every `SHA256SUMS` entry was re-checked against the platform-side
  sha256 digest at upload, and the two files not in that list
  (`SHA256SUMS`, `distribution.json`) are covered by `distribution.json`.
  Image archive: `floe-linux-guest-…-dev-document-…zip`, 1,077,342,227 bytes,
  sha512 `47f08bada3…c70aa13`, sha256 `456b48a3…` (repacked with the
  provenance-only manifest change; input candidate 1,078,159,186 bytes, sha512
  `0a37a282…`). Sources: Debian shards 1–2, upstream/relink/toolchain, PyPI
  wheel sources (43,714,560 bytes, 15/15 files verified, PDFium tree 5293
  files), image evidence, template qualification, source index and the
  manifest/sums/notes.
- Release-content audit: Debian gaps 0 (3508 mapped rows, 2528/2528 files
  verified, 777/777 installed packages mapped with matching source versions),
  PyPI gaps 0 (all four wheel sha256 equal the recipe pins), template
  `dev-document` qualified (49/49), manifest `qualified: true`,
  `distributionAllowed: true`, disk sha512 `fa969a4a…` unchanged,
  recipe sha512 `99016057…` == the repository recipe digest.
- App pin: `RuntimeV2OfficialTemplatePinnedArtifacts` `dev-document` v1 with
  the archive URL/sha512/bytes above, disk sha512, recipe sha512 and
  `sourceRef` `3680d77a`; contract covered by
  `RuntimeV2OfficialTemplateWiringTests.testPinnedArtifactsMatchTheRepositoryRecipes`.
  This is host-level module evidence only — no App installation or iPad
  behavior is claimed.

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
