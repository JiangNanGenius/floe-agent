# Floe Android G01 synthetic fixtures

Versioned, deterministic, **fully synthetic** test material for the Android
operation baseline in `../planning/feature-baseline.json`. Nothing here is
customer data, downloaded private data, credential material or a copy of an
iOS binary store format; the notes/canvas JSON files define a planned,
Android-side sample schema only.

Generation is stdlib-only except one pinned `ffmpeg` recipe (see below).
No file in this directory is ever rewritten by a read-only check.

## Commands

```bash
python3 generate.py                 # (re)generate all fixtures + inventory.json
python3 generate.py --check         # read-only: stdlib fixtures must regenerate
                                    # byte-identically; never writes anything
python3 generate.py --verify-ffmpeg # read-only check + re-run ffmpeg into
                                    # Local/Scratch/android-g01-fixtures and
                                    # compare; never writes fixtures/
python3 ../scripts/check-fixtures.py --check  # read-only validator: integrity,
                                    # structures, baseline cross-references,
                                    # family-level section-2 coverage, ledger links
```

Checked with Python 3.9.6 (system), ffmpeg: `ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers`.

## Status and evidence checks (structural only)

`../scripts/check-fixtures.py` and `../scripts/check-plan.py` accept the six
completion states defined in plan section 11.1: `planned` (待开始),
`implementing` (实现中), `component_verified` (组件验证通过), `app_verified`
(完整 App 验证通过), `samsung_verified` (三星验证通过) and `delivered`
(已交付). The four verified states require a nonempty `evidence` list of
nonempty references on the operation or work package.

This is a structural guard, not qualification proof. A reference is not
checked for existence here and is not evidence that the command, test or
device run actually happened. The current baseline keeps all 170 operations
`planned` and all 85 work packages `planned`; advancing a state later requires
real code/test/device evidence and a separate review.

Coverage is checked at family level only: the 35 section-2 rows are claimed by
exactly one family, `FND` is the only family without a section-2 row and must
appear exactly once, and every `family.workPackages` ID must exist in the
85-package ledger. The baseline does not invent an operation-to-work-package
mapping.

## Inventory

| fixture | format | bytes | sha256 (first 16) | determinism |
| --- | --- | --- | --- | --- |
| `assets/png/gradient-8.png` | png | 268 | `6a8546b0a4a0b47a…` | stdlib |
| `assets/svg/marker.svg` | svg | 190 | `829f04c49a3ea0f0…` | stdlib |
| `cad/dxf/lines-text-layers.dxf` | dxf | 421 | `d57ce726e448f408…` | stdlib |
| `cad/obj/cube.obj` | obj | 191 | `1642d977e1b95290…` | stdlib |
| `canvas/canvas-with-assets.json` | canvas-json | 636 | `3c7121e94cffcf5b…` | stdlib |
| `media/audio/tone-440.wav` | wav | 44144 | `c250d87551c85fb9…` | stdlib |
| `media/subtitles/captions.srt` | srt | 149 | `41e845e0d829f94e…` | stdlib |
| `media/subtitles/captions.vtt` | vtt | 91 | `19843d7f22fd4dac…` | stdlib |
| `notes/note-basic.json` | notes-json | 598 | `ebe9530258252aad…` | stdlib |
| `office/docx/corrupt-missing-content-types.docx` | docx-corrupt | 3088 | `81221c408dc6a83d…` | stdlib |
| `office/docx/paragraphs-unicode.docx` | docx | 3892 | `a289f91545a495b9…` | stdlib |
| `office/pptx/two-slides.pptx` | pptx | 10035 | `ec49379444bf85e6…` | stdlib |
| `office/xlsx/formula-basic.xlsx` | xlsx | 3908 | `0f8229c15f690142…` | stdlib |
| `office/xlsx/formula-error-and-injection.xlsx` | xlsx | 4047 | `d91cecd8af812095…` | stdlib |
| `pdf/truncated.pdf` | pdf-corrupt | 442 | `10c87bfaa395a74a…` | stdlib |
| `pdf/two-page-basic.pdf` | pdf | 884 | `7563af5cd427641c…` | stdlib |
| `text/code/sample.kt` | kotlin | 177 | `29f818d11572fd09…` | stdlib |
| `text/code/sample.py` | python | 251 | `0cc0644f36c56e0c…` | stdlib |
| `text/code/sample.ts` | typescript | 166 | `07cdb9bd3dfd7241…` | stdlib |
| `text/csv/formula-injection.csv` | csv | 133 | `c4396e5d125d6641…` | stdlib |
| `text/encoding/crlf.txt` | text | 40 | `ec6ae42e2038d991…` | stdlib |
| `text/encoding/long-line.txt` | text | 4097 | `5d05023e33a88151…` | stdlib |
| `text/encoding/utf8-bom.txt` | text | 18 | `8c161c74111f2720…` | stdlib |
| `media/video/floe-test.mp4` | mp4 | 25125 | `ac1d2de41e7f652a…` | ffmpeg-version-pinned |

`inventory.json` records for every entry: path, byte size, SHA-256, format,
determinism class, structural expectations (`expect`) and the baseline
operation IDs it serves (`operations`). `check-fixtures.py` verifies
integrity (SHA-256 + size), the recorded basic structures, and that baseline
fixture references and inventory operation references resolve both ways.

## Reproducibility

- ZIP-based Office fixtures use `ZIP_STORED`, fixed member order and a fixed
  1980-01-01 timestamp, so bytes depend only on the source content — not on
  zlib versions or clocks.
- The PNG uses deflate *stored* blocks (zlib level 0) with CRC32 chunks:
  byte-stable across environments.
- The PDF is written byte-by-byte with computed xref offsets and a literal
  `%%EOF`; validated by macOS QuickLook/Spotlight (2 pages) when generated.
- The WAV is a stdlib 440 Hz sine (44100 Hz, 16-bit mono, 0.5 s).
- `media/video/floe-test.mp4` is generated by ffmpeg with the exact argv
  recorded in `inventory.json` (`recipe`). Its bytes are reproducible with
  the **same ffmpeg build** (recorded above); on another ffmpeg version
  `--verify-ffmpeg` may legitimately report drift. Treat the pinned SHA as
  the G01 record; regenerate explicitly if the toolchain is upgraded.
- `generate.py --check` and `check-fixtures.py --check` never write. Full
  regeneration is the only mode that touches `fixtures/`.

## Coverage intent (representative, not combinatorial)

- **Office**: valid DOCX/XLSX/PPTX with heading, numbered list, bold/italic,
  CJK+emoji+RTL text, formula (`SUM`), cached value, error formula
  (`#DIV/0!`), and formula-like injection literals (XLSX/CSV) that must stay
  inert text. A corrupt DOCX (missing `[Content_Types].xml`) exercises the
  rejection path.
- **PDF**: valid 2-page text PDF plus a truncated copy for failure handling.
- **CAD**: minimal valid ASCII DXF (R12, 3 layers incl. a CJK layer name,
  LINE/CIRCLE/TEXT with unicode) and an OBJ cube (8 vertices / 6 faces,
  group `cube § main`).
- **Notes / Canvas**: JSON samples carrying the semantic expectations used by
  the baseline (3 blocks, chat-decoupling field null, unicode title; canvas
  with 1 known and 1 intentionally dangling asset reference, revision and
  owner fields).
- **Media**: tone WAV, 1 s H.264+AAC MP4, SRT/VTT subtitles (unicode cues).
- **Text/IDE**: python/kotlin/typescript samples with symbols and unicode,
  CRLF / UTF-8-BOM / 4096-char single-line files, formula-injection CSV.
- **Assets**: 8x8 PNG and a small SVG for canvas/asset-ownership and
  preview flows (PNG is also referenced by the notes attachment field).

## Recorded gaps (explicit, never faked)

- **No encrypted/protected PDF fixture**: no stdlib-safe generator for a
  valid password-protected PDF; the protected-PDF gated path
  (`PDFKitGate`/`PDFUnlockTool` iOS evidence, `PDF-PROTECTED-GATE`) stays a
  `pending-gap` until a verified generator exists. Not approximated here.
- **No DWG fixture**: proprietary binary format; DXF/OBJ cover the parseable
  paths and `CAD-UNKNOWN-PRESERVE` documents the DWG conversion gap.
- **No speech audio**: only a synthetic tone WAV, so `VOI-FILE-TRANSCRIBE`
  flows can test plumbing/formats but not real transcription accuracy.
- **Notes/canvas JSON are Android-planning synthetic schemas**
  (`floe-android.*.sample.v0`), deliberately decoupled from iOS binary
  storage formats; they define expected semantic properties, not iOS parity
  of file bytes.
- Small size on purpose: no codec/HDR/font matrices, no large-file
  performance fixtures; those belong to G12/G13 device work.
- Media/Office samples exercise structure and semantics only; rendering
  fidelity acceptance remains with full-App and device verification
  (main-agent owned).

No references to private servers, credentials or repository-internal
operations appear in these fixtures or in `inventory.json`.
