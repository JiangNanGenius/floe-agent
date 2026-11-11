# MediaExchange qualification package

Status: format-neutral exchange, geometry and project-package adapters. The
image bridge is wired into the native MediaV2 editor. Current source integration
and component qualification do not imply full-App or physical-device acceptance.

## What is here

| Path | Purpose |
| --- | --- |
| `Sources/MediaExchangeBridge` | Canonical v2 projection: basic timeline/OTIO round-trip and image layer/group/mask/plain-text import/export. Unsupported effects refuse conversion; imports retain the original exchange timeline. No second store or implicit file access. |
| `Sources/MediaExchangeCore` | Straight-alpha RGBA/PNG bridge, PSD (ag-psd/JSCore) and ORA codecs copied from the qualified formats package, strict selection compositor, rational exchange model, OTIO adapter, packed/reference project manifest, editable Bezier geometry. |
| `Sources/MediaExchangeClipper` | Swift value-type adapter over the project-authored C ABI. Quantization and tessellation tolerance are explicit; no CAD or document state is owned. |
| `Sources/MediaExchangeFCPXML` | Native Foundation-XML FCPXML 1.10 adapter for the documented subset (resources, sequence/spine, asset-clip, gap, caption, marker, lane mapping). |
| `Tests/MediaExchangeCoreTests` | Tests: alpha=1 PNG exactness, ORA byte preservation, unsupported PSD/ORA, selection byte invariance, rational time, OTIO, project manifest, traversal/symlink checks. |
| `Tests/MediaExchangeClipperTests` | 4 tests: intersection/union/difference/xor, holes, offset, explicit tolerance, source immutability. |
| `Tests/MediaExchangeFCPXMLTests` | 6 tests: two video tracks + audio, 30000/1001 + mixed fps, captions, unsupported-effect report, missing media, traversal, unsafe XML. |
| `Tests/MediaExchangeOpenKitTests` | 4 macOS tests: pinned OpenFCPXMLKit parses the native export, native export passes the pinned FCPXML 1.10 DTD, full timeline passes the DTD, upstream exporter output is accepted by the native importer. |
| `Fixtures` | Synthetic PSD/ORA fixtures copied from the formats qualification plus authored FCPXML/OTIO test documents. `SHA256SUMS` uses package-relative paths and hashes that match the formats package manifest. |
| `FloeAgent/ThirdParty/Clipper2` | Source-only Clipper2 packaging + thin C ABI (separate scope; not in the main App manifest). |

## Pins

- ag-psd: `34.1.0`, commit `a74425db6584cc07b1cc135e370916cb4eccfb32`, MIT.
- Swift PNG: `4.5.1`, revision `8a0bcd4df5e4b307c804937776a56dd6ecdf6396`, Apache-2.0.
- h: `1.0.1`, revision `aa3626829160917d4378330617971977cbd78f5b`, Apache-2.0.
- ZIPFoundation: `0.9.20`, revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`, MIT.
- Clipper2: commit `b496b454df168a2280354857c1cd90bd6fa7b4dd`, BSL-1.0;
  see `FloeAgent/ThirdParty/Clipper2/PIN.txt`.
- OpenFCPXMLKit: commit `7f55583a3a5b4fecf336ca2ae4b77fb11f8db46d`, MIT;
  used only by the macOS independent qualification tests. `Package.resolved`
  pins the full dependency graph.

## Run

```sh
env -u SDKROOT DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun swift test \
  --package-path FloeAgent/Modules/FloeMediaExchange \
  --scratch-path "$HOME/Library/Caches/CodexBuild/FloeAgent/media-exchange/macos" \
  --jobs 6 --filter 'PNGAlphaTests|PSDORACompatibilityTests|BridgeTests'
```

The bridge consumes the canonical `FloeWorkbench` package directly. Use a
separate scratch directory for each checkout. Simulator runs must follow the
repository's canonical reused-iPad selection and device lock policy.

Historical 2026-11-02 qualification covered 52 tests and generic iOS object
compilation under Xcode 27.1; it is not evidence for subsequent source changes.
Current targeted evidence is recorded separately by the integration owner.

## Interfaces

- **Image exchange:** `PortableDocument` / `PortableLayer` plus
  `LayeredExchange.fromPSD/toORA/fromORA/toPSD`; unsupported features throw or
  return preserved-only compatibility.
- **PNG bridge:** file bytes use the pinned Swift PNG codec to preserve straight
  8-bit RGBA values, including alpha=1, on iOS and macOS. CGImage inspection
  retains a provider fast path and a premultiplied fallback for unknown layouts.
- **Selection:** `StrictSelectionCompositor.composite(base:patch:mask:opacity:)`;
  zero-coverage pixels are copied byte-for-byte and verified by
  `verifyOutsideUnchanged`.
- **Timeline:** `ExchangeTime`, `ExchangeFrameRate`, `ExchangeTimeline`,
  `ExchangeTrack`, `ExchangeTimelineItem`, `ExchangeClip`, `ExchangeGap`,
  `ExchangeMarker`, `ExchangeCaption`, `ExchangeEffect`,
  `ExchangeImportReport`. `ExchangeTimeline.validate()` is the common
  structural gate.
- **OTIO:** `OTIOAdapter.export/importTimeline` for the documented subset;
  unknown effects are retained in `rawRepresentation` and reported; captions
  are rejected rather than silently converted.
- **FCPXML:** `FCPXMLAdapter.export/importTimeline`; unsupported effects are
  reported on import and make export throw; captions and timeline markers are
  preserved. The exported full fixture passes OpenFCPXMLKit's FCPXML 1.10 DTD.
- **Project package:** `ExchangeProjectManifest.makePacked/makeReferenced`,
  `write/load`, `resolveMedia`, `relink`. Packed media is package-owned;
  reference media stays external with an optional security-scoped bookmark.
  Missing media is reported, never recreated. Digests and relink history are
  revisioned.
- **Geometry:** `BezierPath` is the editable source; `ClipperGeometryAdapter`
  flattens with explicit tolerance, quantizes with an explicit scale, and
  returns `TessellatedPolygon` plus `GeometryQueryMetadata`. It does not own
  document state and does not import FloeCADKit.

## Deliberate limitations

- The image bridge supports raster layers, isolated groups, normal/multiply/
  screen/overlay/darken/lighten/difference/exclusion blending, alpha clipping,
  masks within the canonical lossless coverage budget (2048 pixels per edge),
  and single-style point text with cached geometry. The host renders transformed
  raster geometry for export. Live adjustments, complex text, non-adjacent
  clipping and pass-through groups whose appearance cannot be preserved are
  refused. Imports stage PNGs and retain the original container through the
  shared transactional store. Missing fonts can affect editable text layout.
- The basic video/audio bridge still rejects effects, transforms, keyframes,
  fades and captions that it cannot round-trip. The lower-level FCPXML adapter
  supports a broader caption/marker subset.
- This package owns no App UI, renderer or player. Native compilation and
  simulator component tests do not establish full-App or physical acceptance.
- PSD remains 8-bit RGB only. CMYK/16-bit/PSB/complex text/smart objects/effects
  stay preserved-only and are explicitly rejected for editable conversion.
- ORA remains the 0.0.3 raster baseline; masks/clipping/nested stacks/text are
  rejected. Untouched layer PNG bytes are preserved.
- FCPXML is a documented subset, not a complete FCP interchange implementation.
  Retimes other than 1x, effects, transitions, titles, compound clips and
  subtitle tracks are rejected/reported. FCPXML DTD validation is not an FCP
  application import test.
- OTIO is a documented JSON subset; captions and unknown schemas are rejected
  or reported, never guessed.
- Clipper2 is qualification-only and not linked into the App. Boolean output is
  quantized; callers must treat `flatteningTolerance` and
  `quantizationScale` as part of the result contract.
