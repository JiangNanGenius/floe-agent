# Floe Android synthetic fixtures (G02 revision)

Versioned, deterministic, **fully synthetic** test material for the Android
operation baseline in `../planning/feature-baseline.json`, candidate revision
`g02.2026-10-19.1` (182 operations, 36 families, 85 work packages, 33
fixtures). The live tree remains 172/30/26/36/85 until Main publishes the
candidate; the frozen G01 170/24 and prior G02 172/26 declarations are kept as
historical records. Nothing here is customer data, downloaded private data, credential
material or a copy of an iOS binary store format; the notes/canvas/attachment
JSON files define planned Android-side sample schemas only.

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
                                    # structures, attachment scenario contracts,
                                    # baseline history/mappings, plan authority,
                                    # family-level section-2 coverage, ledger links
```

`--check` modes are strictly read-only: they compare bytes, metadata and
recorded mappings and never rewrite fixtures, inventory, hashes or the
baseline.

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
device run actually happened. The candidate baseline records 182 operations:
3 FND foundation operations are `component_verified` for G01 and 179 remain
`planned`, including the two G02 attachment contract operations and the ten
additive Settings-domain G02 operations. The live tree still records 172. The 85 work packages remain 15 G01 `component_verified` and 70 `planned`; this
reconciliation changed no status. The frozen G01 receipt still declares its
own 170-operation/24-fixture snapshot and is not rewritten.

Coverage is checked at family level only: the 35 section-2 rows are claimed by
exactly one family, `FND` is the only family without a section-2 row and must
appear exactly once, and every `family.workPackages` ID must exist in the
85-package ledger. Original operations keep the family-level mapping; the two
G02 attachment operations additionally declare their existing plan work-package
IDs (`P2.2`, `P2.3`, `P2.7`), checked against the same ledger.

## Inventory

| fixture | format | bytes | sha256 (first 16) | determinism |
| --- | --- | --- | --- | --- |
| `attachments/ingest-scenarios.json` | attachment-ingest-scenarios | 3205 | `8f31c9241a3398d8…` | stdlib |
| `attachments/lifecycle-scenarios.json` | attachment-lifecycle-scenarios | 3781 | `5ac5fe4325b94c44…` | stdlib |
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

The Settings-domain P0 candidate adds seven declarative synthetic groups (all
`planned`, no execution evidence):

| fixture | format | operations | purpose |
| --- | --- | --- | --- |
| `settings/defaults-cas.json` | settings-defaults-cas | SET-DEFAULTS-TYPED | typed defaults, CAS and canonical digest vectors |
| `memory/inventory.json` | memory-inventory | SET-MEMORY-INVENTORY, SET-MEMORY-SEARCH | 23-column rows, paging, owner detach, ranking-only handle + per-page fresh rows |
| `memory/candidates.json` | memory-candidates | SET-MEMORY-CANDIDATE-REVIEW | pending/expired rows, redacted evidence, resolve races |
| `memory/organizer-model-output.json` | organizer-model-output | SET-MEMORY-ORGANIZE | closed suggestion kinds, invented-ID rejection, stale apply |
| `personalization/documents.json` | personalization-documents | SET-PERSONALIZATION-DOCUMENTS, SET-PERSONALIZATION-GENERATE | active slot/drafts, cursor CAS, complete-response 48KiB inline-or-handle, generate outcome |
| `usage/aggregates.json` | usage-aggregates | SET-USAGE-AGGREGATE | NULL-not-zero metrics, legacy fallbacks, bounded 5k paging |
| `privacy/identity-streams.json` | privacy-identity-streams | SET-HISTORY-CLEAR, SET-MODELCFG-CLEAR | exact identity/state streams, archived exclusion, gateway-unregistered |

These files contain no credentials, real URIs, user paths or claim that a case
ran. `check-fixtures.py` rejects execution/status claims and verifies the
declared vector/case ids, closed schemas, inventory hashes and both-way
operation mappings.

`inventory.json` records for every entry: path, byte size, SHA-256, format,
determinism class, structural expectations (`expect`) and the baseline
operation IDs it serves (`operations`), plus the G02 artifact/baseline/
fixture versions and the previous 24-fixture declaration. `check-fixtures.py`
verifies integrity (SHA-256 + size), metadata, the recorded basic structures,
the attachment scenario semantics, and that baseline fixture references and
inventory operation references resolve both ways.

## Reproducibility

- ZIP-based Office fixtures use `ZIP_STORED`, fixed member order and a fixed
  1980-01-01 timestamp, so bytes depend only on the source content — not on
  zlib versions or clocks.
- The PNG uses deflate *stored* blocks (zlib level 0) with CRC32 chunks:
  byte-stable across environments.
- The PDF is written byte-by-byte with computed xref offsets and a literal
  `%%EOF`; validated by macOS QuickLook/Spotlight (2 pages) when generated.
- The WAV is a stdlib 440 Hz sine (44100 Hz, 16-bit mono, 0.5 s).
- The notes/canvas/attachment JSON fixtures use `json.dumps` with sorted keys,
  fixed indentation and a trailing newline; no clock or environment value is
  embedded.
- `media/video/floe-test.mp4` is generated by ffmpeg with the exact argv
  recorded in `inventory.json` (`recipe`). Its bytes are reproducible with
  the **same ffmpeg build** (recorded above); on another ffmpeg version
  `--verify-ffmpeg` may legitimately report drift. Treat the pinned SHA as
  the recorded fixture bytes; regenerate explicitly if the toolchain is
  upgraded.
- `generate.py --check` and `check-fixtures.py --check` never write. Full
  regeneration is the only mode that touches `fixtures/`; the G02 revision
  regenerated its 26 fixtures once, and `--check` then verified the bytes and
  metadata without changing any file.

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
- **G02 Settings-domain**: typed defaults, memory inventory/search/candidates/
  organizer, personalization documents/generation, usage aggregates and privacy
  identity streams. All are declarative vectors; no handler, database or
  device behavior is asserted.
- **G02 attachments**: declarative ingest/lifecycle scenarios reuse existing
  synthetic payloads. The ingest contract covers a bounded commit, an
  oversized payload, a declared-text/actual-PNG MIME spoof and a revoked
  content URI; it also pins RAM-only temporary mode with the unchanged
  text/public-web ceiling. The lifecycle contract covers mid-transfer cancel
  with no orphan, cancel preserving a prior commit, idempotent retry with the
  same digest, a stale callback from another task/epoch, and monotonic
  read-only-stream progress. Both keep auto-send/auto-execute false.

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
- **Attachment JSON fixtures are declarative scenario contracts**, not an
  Android SAF/content-URI implementation or a device test. They pin the
  validation/ownership/cleanup facts a later G02 implementation must satisfy;
  they do not prove an attach flow works on a device.
- Small size on purpose: no codec/HDR/font matrices, no large-file
  performance fixtures; those belong to G12/G13 device work.
- Media/Office samples exercise structure and semantics only; rendering
  fidelity acceptance remains with full-App and device verification
  (main-agent owned).

No references to private servers, credentials or repository-internal
operations appear in these fixtures or in `inventory.json`.
