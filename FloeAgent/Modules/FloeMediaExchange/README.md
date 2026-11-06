# MediaExchange qualification package

Status: **source-ready qualification package**, not a production App feature,
App integration, device acceptance or release. It owns only format-neutral
exchange, geometry and project-package adapters.

## What is here

| Path | Purpose |
| --- | --- |
| `Sources/MediaExchangeBridge` | Canonical v2 projection: basic timeline/OTIO round-trip and raster image layer import/export. Unsupported effects refuse conversion; imports retain the original exchange timeline. No second store or implicit file access. |
| `Sources/MediaExchangeCore` | Straight-alpha RGBA/PNG bridge, PSD (ag-psd/JSCore) and ORA codecs copied from the qualified formats package, strict selection compositor, rational exchange model, OTIO adapter, packed/reference project manifest, editable Bezier geometry. |
| `Sources/MediaExchangeClipper` | Swift value-type adapter over the project-authored C ABI. Quantization and tessellation tolerance are explicit; no CAD or document state is owned. |
| `Sources/MediaExchangeFCPXML` | Native Foundation-XML FCPXML 1.10 adapter for the documented subset (resources, sequence/spine, asset-clip, gap, caption, marker, lane mapping). |
| `Tests/MediaExchangeCoreTests` | 36 tests: alpha=1 PNG exactness, ORA byte preservation, unsupported PSD/ORA, selection byte invariance, rational time, OTIO, project manifest, traversal/symlink checks. |
| `Tests/MediaExchangeClipperTests` | 4 tests: intersection/union/difference/xor, holes, offset, explicit tolerance, source immutability. |
| `Tests/MediaExchangeFCPXMLTests` | 6 tests: two video tracks + audio, 30000/1001 + mixed fps, captions, unsupported-effect report, missing media, traversal, unsafe XML. |
| `Tests/MediaExchangeOpenKitTests` | 4 macOS tests: pinned OpenFCPXMLKit parses the native export, native export passes the pinned FCPXML 1.10 DTD, full timeline passes the DTD, upstream exporter output is accepted by the native importer. |
| `Fixtures` | Synthetic PSD/ORA fixtures copied from the formats qualification plus authored FCPXML/OTIO test documents. `SHA256SUMS` uses package-relative paths and hashes that match the formats package manifest. |
| `FloeAgent/ThirdParty/Clipper2` | Source-only Clipper2 packaging + thin C ABI (separate scope; not in the main App manifest). |

## Pins

- ag-psd: `34.1.0`, commit `a74425db6584cc07b1cc135e370916cb4eccfb32`, MIT.
- ZIPFoundation: `0.9.20`, revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`, MIT.
- Clipper2: commit `b496b454df168a2280354857c1cd90bd6fa7b4dd`, BSL-1.0;
  see `FloeAgent/ThirdParty/Clipper2/PIN.txt`.
- OpenFCPXMLKit: commit `7f55583a3a5b4fecf336ca2ae4b77fb11f8db46d`, MIT;
  used only by the macOS independent qualification tests. `Package.resolved`
  pins the full dependency graph.

## Run

```sh
# First stage the exact canonical sources (required by MediaExchangeBridge).
python3 FloeAgent/Qualification/MediaCore/Scripts/stage_sources.py
env -u SDKROOT DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
xcrun swift test \
  --package-path FloeAgent/Qualification/MediaExchange \
  --scratch-path "$HOME/Library/Caches/CodexBuild/FloeMediaCorePrep/media-core-prep/xcode27.1/exchange" \
  --jobs 6
```

Executed on 2026-11-02 with Xcode 27.1 (27A9275), Swift 6.4, macOS 26
deployment: **52 tests, 0 failures** (36 Core + 4 Clipper + 6 FCPXML + 4
OpenKit + 2 canonical-document Bridge).

Generic iOS device object compilation (no simulator, no App build):

```sh
# Clear the host CommandLineTools SDKROOT; pass the Xcode iPhoneOS SDK explicitly.
IOS_SDK=$(DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
  xcrun --sdk iphoneos --show-sdk-path)
for target in MediaExchangeCore MediaExchangeClipper MediaExchangeFCPXML; do
  env -u SDKROOT DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
  xcrun swift build \
    --package-path FloeAgent/Qualification/MediaExchange \
    --target "$target" --triple arm64-apple-ios26.0 --sdk "$IOS_SDK" \
    --scratch-path "$HOME/Library/Caches/CodexBuild/FloeMediaCorePrep/media-core-prep/xcode27.1/ios" \
    --jobs 6
done
```

All three targets built; `vtool -show-build` reports `platform IOS`,
`minos 26.0`, `sdk 27.1` for the produced arm64 objects. Do not set `SDKROOT`
for the SwiftPM host/manifest invocation (it would compile the manifest against
the iPhoneOS SDK); clear it and pass `--sdk` to the target build. For an
`xcodebuild` App build, set `SDKROOT` to the selected Xcode platform SDK and
inspect `LC_BUILD_VERSION`/`vtool` rather than trusting the inherited value.

## Interfaces

- **Image exchange:** `PortableDocument` / `PortableLayer` plus
  `LayeredExchange.fromPSD/toORA/fromORA/toPSD`; unsupported features throw or
  return preserved-only compatibility.
- **PNG bridge:** `PNGCodec.decode` reads straight-alpha provider bytes for
  8-bit RGBA/RGB and preserves alpha=1 exactly; the premultiplied CGContext
  path remains a documented fallback for unknown layouts.
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

- The v2 bridge supports raster image layers and a basic video/audio track
  subset. It rejects crop, transforms, keyframes, fades, captions and effects
  that it cannot round-trip; the lower-level FCPXML adapter supports a broader
  caption/marker subset. Advanced editable PSD and general NLE interoperability
  remain pending. The host must stage imported PNGs, retain original exchange
  files/metadata, validate granted asset locations and save via the shared store.
- No App/UI, no renderer, no player, no simulator boot, no physical-device
  acceptance. Native compilation is not a UI or FCP-import result.
- PSD remains 8-bit RGB only. CMYK/16-bit/PSB/text/smart objects/effects are
  preserved-only and explicitly rejected for editable conversion.
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
