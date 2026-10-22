# Media-enhancement model conversion (T2)

These scripts reproduce the pinned on-device models used by the Floe media
enhancement pipeline. They are **host tooling only**: nothing here runs inside
the app, and nothing here publishes an official catalog. Converted artifacts
stay under `Local/Artifacts/capability-closure-20261014/media/`; the Git tree
contains scripts, notices and metadata, never weights.

Every reviewed input has a pinned SHA-256; there is no "record the hash after
the first fetch" path. A missing/mismatching hash fails closed. `--check`
verifies an existing fetch read-only.

## Pinned inputs

| Model | Source (immutable revision) | Weights | License |
| --- | --- | --- | --- |
| RIFE 4.25 Lite | `hzwer/Practical-RIFE` @ `bbfd2ea90910789a860ea3e2b32a240cd577b75e` (architecture + `model/warplayer.py`), weights archive from the README 4.25.lite link (Google Drive `1zlKblGuKNatulJNFf5jdB-emp9AqGK05`) | `train_log/flownet.pkl` sha256 `81cdba22…f96b8b1` | MIT (README: the trained-model links are under the same MIT license) |
| Real-ESRGAN x4plus | `xinntao/Real-ESRGAN` @ `a4abfb2979a7bbff3f69f58f58ae324608821e27`; `RRDBNet` from `XPixelGroup/BasicSR` tag `v1.4.2` commit `651835a1b9d38dbbdaf45750f56906be2364f01a` | `RealESRGAN_x4plus.pth` sha256 `4fa0d389…d682f1` | BSD-3-Clause (repository license; no separate weights grant upstream — see notice limitation) |
| Real-ESRGAN x2plus | same BasicSR commit | `RealESRGAN_x2plus.pth` sha256 `49fafd45…266abb` | same |

The exact file hashes, commit ids and license-evidence hashes live in
`fetch_assets.py` and are re-verified by the commands below. The vendored
architecture is checked by `verify_rrdbnet_source.py`; see
`THIRD-PARTY-NOTICES.md` for the full attribution and
`rrdbnet_arch.LICENSE.txt` for the BasicSR Apache-2.0 text.

No third-party pre-converted Core ML model is used; every `.mlpackage` here is
built from the pinned checkpoint and the pinned architecture source.

## Environment

The task-owned venv is kept at `Local/Scratch/media-enhancement/venv` and is
already provisioned; recreate it only if it is missing. All commands run from
the repository root (no machine-specific absolute path is required):

```sh
cd "$(git rev-parse --show-toplevel)"
uv venv --python 3.12 Local/Scratch/media-enhancement/venv
uv pip install --python Local/Scratch/media-enhancement/venv/bin/python \
  "torch==2.8.0" "numpy==2.2.6" "pillow==12.3.0" "coremltools==9.0"
```

Python dependencies stay inside this task-owned venv (no global pip changes).
`coremltools 9.0` warns that torch 2.8 was not tested; all conversions and
reference comparisons in this lane ran successfully with that pair.

## Pipeline (complete, executable)

```sh
cd "$(git rev-parse --show-toplevel)"
SCRATCH="$PWD/Local/Scratch/media-enhancement"
ART="$PWD/Local/Artifacts/capability-closure-20261014/media"
PY="$SCRATCH/venv/bin/python"
LICENSE_DIR="$SCRATCH/licenses"
BASICSR_COMMIT=651835a1b9d38dbbdaf45750f56906be2364f01a

# 1. fetch + hash-verify pinned inputs AND stage the bundle notice files.
#    (Fresh machines: this downloads ~157 MB of weights; --sources-only does
#    the same source/license checks without the weights.)
"$PY" FloeAgent/scripts/media-enhancement/fetch_assets.py \
  --destination "$SCRATCH/downloads" --work "$SCRATCH/work" --licenses "$LICENSE_DIR"

# 1b. read-only re-verification of the fetch (no writes, fail closed):
"$PY" FloeAgent/scripts/media-enhancement/fetch_assets.py \
  --destination "$SCRATCH/downloads" --work "$SCRATCH/work" --licenses "$LICENSE_DIR" --check

# 2. convert (fixed 256 px tiles, FLOAT32 compute precision; RIFE needs fp32).
"$PY" FloeAgent/scripts/media-enhancement/convert_rife.py \
  --work "$SCRATCH/work" --tile 256 --phase 0.5 \
  --fixture0 "$SCRATCH/work/upstream-practical-rife/demo/i0.png" \
  --fixture1 "$SCRATCH/work/upstream-practical-rife/demo/i1.png" \
  --output "$ART/models/floe-model-rife-v4" \
  --id floe/model-rife-v4 --version 4.25.0-lite --license MIT \
  --source https://github.com/hzwer/Practical-RIFE \
  --source-commit bbfd2ea90910789a860ea3e2b32a240cd577b75e \
  --license-evidence "https://github.com/hzwer/Practical-RIFE/blob/bbfd2ea90910789a860ea3e2b32a240cd577b75e/LICENSE"

"$PY" FloeAgent/scripts/media-enhancement/convert_realesrgan.py \
  --weights "$SCRATCH/downloads/RealESRGAN_x4plus.pth" --scale 4 --tile 256 \
  --fixture "$SCRATCH/work/upstream-practical-rife/demo/i0.png" \
  --output "$ART/models/floe-model-realesrgan-x4plus" \
  --id floe/model-realesrgan-x4plus --version 1.0.0 --license BSD-3-Clause \
  --source https://github.com/xinntao/Real-ESRGAN \
  --source-commit a4abfb2979a7bbff3f69f58f58ae324608821e27 \
  --license-evidence "https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/LICENSE"

"$PY" FloeAgent/scripts/media-enhancement/convert_realesrgan.py \
  --weights "$SCRATCH/downloads/RealESRGAN_x2plus.pth" --scale 2 --tile 256 \
  --fixture "$SCRATCH/work/upstream-practical-rife/demo/i0.png" \
  --output "$ART/models/floe-model-realesrgan-x2plus" \
  --id floe/model-realesrgan-x2plus --version 1.0.0 --license BSD-3-Clause \
  --source https://github.com/xinntao/Real-ESRGAN \
  --source-commit a4abfb2979a7bbff3f69f58f58ae324608821e27 \
  --license-evidence "https://github.com/xinntao/Real-ESRGAN/blob/a4abfb2979a7bbff3f69f58f58ae324608821e27/LICENSE"

# 3. compile to .mlmodelc and build installable bundles + manifests + notices.
#    --licenses is required and fail-closed: a missing/empty/unnoticed license
#    aborts instead of writing `licenseFile: null`. --provenance proves the
#    notice bytes came from step 1.
"$PY" FloeAgent/scripts/media-enhancement/package_models.py \
  --models "$ART/models" --bundles "$ART/bundles" \
  --licenses "$LICENSE_DIR" --provenance "$SCRATCH/downloads/provenance.json"

# 4. notice-only regeneration (no recompilation; keeps model/fixture bytes).
"$PY" FloeAgent/scripts/media-enhancement/package_models.py \
  --models "$ART/models" --bundles "$ART/bundles" \
  --licenses "$LICENSE_DIR" --provenance "$SCRATCH/downloads/provenance.json" \
  --reuse-compiled --reuse-report "$ART/evidence/bundle-notice-regeneration.json"
```

## Verification

```sh
cd "$(git rev-parse --show-toplevel)"
VENV="$PWD/Local/Scratch/media-enhancement/venv/bin/python"

# deterministic offline tests (mocked transport, hash corruption, fail-closed
# notices, notice-only bundle regeneration)
"$VENV" -m unittest discover -s FloeAgent/scripts/media-enhancement/tests \
  -t FloeAgent/scripts/media-enhancement/tests -v

# real small upstream fetch without touching the 157 MB weights
"$VENV" FloeAgent/scripts/media-enhancement/fetch_assets.py \
  --destination "$PWD/Local/Scratch/media-enhancement/probe-run/downloads" \
  --work "$PWD/Local/Scratch/media-enhancement/probe-run/work" \
  --licenses "$PWD/Local/Scratch/media-enhancement/probe-run/licenses" --sources-only

# upstream source/AST/math equivalence of the vendored RRDBNet
"$VENV" FloeAgent/scripts/media-enhancement/verify_rrdbnet_source.py \
  --fetch-dir "$PWD/Local/Scratch/media-enhancement/probe-run/rrdbnet-upstream" \
  --vendored FloeAgent/scripts/media-enhancement/rrdbnet_arch.py \
  --converted-copy "$PWD/Local/Scratch/media-enhancement/work/basicsr/rrdbnet_arch.py" \
  --expect-converted-copy-same \
  --output "$PWD/Local/Private/capability-closure-20261014/media/evidence/rrdbnet-source-verification.json"
```

## Licenses and notices

- `fetch_assets.py --licenses <dir>` writes `floe-model-*.LICENSE` notices
  composed from the pinned upstream texts (RIFE MIT; Real-ESRGAN BSD-3-Clause
  plus the BasicSR Apache-2.0 architecture text) and records their hashes in
  `provenance.json`.
- `package_models.py --licenses <dir> --provenance <provenance.json>` refuses
  to build a bundle without them; the bundle gets `LICENSE.txt`, and
  `PROVENANCE.json` records weights and architecture licenses separately.
- Honest limitation: upstream Real-ESRGAN publishes no weights-specific
  license grant (only the repository BSD-3-Clause license), so the generated
  bundles are internal/local until the rights are clarified; the official
  catalog stays `pending-assets`.
- The vendored `rrdbnet_arch.py` ships with the full Apache-2.0 text
  (`rrdbnet_arch.LICENSE.txt`) and `THIRD-PARTY-NOTICES.md`.

## Conversion contracts

- **RIFE 4.25 Lite** — inputs `frame0`,`frame1` (ImageType RGB 256x256, scale
  1/255) and `timestep` (tensor `[1,1]`, 0…1); output `frame` (ImageType RGB,
  clamped 0…1 scaled to 255). Scale list `[32,16,8,4,1]`, upstream
  `Model.inference` semantics. FLOAT16 compute precision was measured unusable
  (max abs diff 0.95); fp32 gives max abs diff 0.00197 / PSNR 59.19 dB against
  the PyTorch reference.
- **Real-ESRGAN x2plus/x4plus** — input `image` (ImageType RGB 256x256, scale
  1/255), output `image_out` (ImageType RGB, 2x/4x size, clamped). Max abs diff
  0.00196 / PSNR 59.0–59.04 dB against the PyTorch reference.

Reference inputs are the pinned upstream demo images (`demo/i0.png`,
`demo/i1.png`); outputs are stored as `.npy` plus the conversion-time Core ML
result so the app can re-qualify the installed bytes (`fixtures/expected.png`).

## Readiness

`package_models.py` also renders fixture PNGs and writes `manifest.json` with a
sha256 for every bundled file. `MediaModelReadiness` (FloeMedia) verifies those
hashes, runs one bounded inference and compares it with `fixtures/expected.png`;
the result is persisted as `.floe-readiness.json` and invalidated by any
byte/version change. A notice/metadata change therefore invalidates only the
cached readiness record; the model and fixture bytes are unchanged and are
proven so by the `--reuse-compiled --reuse-report` mapping.

## Exact retained distribution candidates

`stage_retained_models.py --retained <read-only-bundles> --output <new-directory>`
verifies the pinned original manifests and every retained byte without compiling,
converting, downloading or inferring. It preserves original provenance/notices,
adds a clearly labelled distribution decision and RGB8 runtime contract, then
writes flat release `assets/`, hard-linked qualification `bundles/` and
`CANDIDATE.json`. This is preparation, not current qualification or availability.

`promote_retained_models.py --candidate <CANDIDATE.json> --qualification <reviewed-evidence.json> --models skill-hub/models.json --release-base <immutable-github-release-download-url> --output <models-candidate.json>`
requires the exact candidate manifest digest and host/device evidence per model,
then independently reads and hashes every published asset. It only produces a
staged `models.json` candidate. The normal hub build/sign/publication procedure
must generate `catalog.json` and its matching signature; never hand-edit them.
The existing installer downloads individual files into the declared model
layout, verifies all bytes and the manifest/contract identity before registering
an install. Runtime readiness still requires actual fixture inference.
