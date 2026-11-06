# MediaExchange source-ready handoff

Historical lane checkpoint. The consolidated core/bridge verification in
`docs/FLOE_MEDIA_CORE_PREPARATION.md` supersedes the integration status below.

Status: qualification source ready. No App/UI, device, Simulator, FCP
application-import, release or shared `MediaProject` v2 wiring is claimed.
Coordinator owns integration and final acceptance.

## Scope written

- `FloeAgent/Qualification/MediaExchange/*`
- `FloeAgent/ThirdParty/Clipper2/*`

No root package manifest, App source, version or other lane was edited.

## Executed

Toolchain: Xcode 27.1 (27A9275), Swift 6.4, iPhoneOS SDK 27.1, macOS arm64.

```sh
env -u SDKROOT DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
xcrun swift test \
  --package-path FloeAgent/Qualification/MediaExchange \
  --scratch-path "$HOME/Library/Caches/CodexBuild/FloeMediaCorePrep/media-core-prep/xcode27.1/exchange-clean-sdk" \
  --jobs 6
```

Result: 50 tests, 0 failures (36 core, 4 Clipper2, 6 FCPXML, 4 OpenKit).
Key checks: alpha=1 RGBA PNG exact round-trip; untouched ORA layer bytes;
unsupported PSD/ORA fail closed; strict selection 527 changed / 65,009 outside
bytes identical; OTIO two video tracks + audio + 30000/1001 + mixed 25/1 media;
FCPXML same fixture passes the pinned FCPXML 1.10 DTD; captions and unsupported
effects are preserved/reported; packed/reference manifests, missing/relink,
digest, bookmarks and traversal/symlink rejection.

Generic iOS device objects (no Simulator, no App build):

```sh
IOS_SDK=$(DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
  xcrun --sdk iphoneos --show-sdk-path)
for target in MediaExchangeCore MediaExchangeClipper MediaExchangeFCPXML; do
  env -u SDKROOT DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
  xcrun swift build \
    --package-path FloeAgent/Qualification/MediaExchange \
    --target "$target" --triple arm64-apple-ios26.0 --sdk "$IOS_SDK" \
    --scratch-path "$HOME/Library/Caches/CodexBuild/FloeMediaCorePrep/media-core-prep/xcode27.1/ios-clean-sdk" \
    --jobs 6
done
```

All targets built; `vtool -show-build` reported `platform IOS`, `minos 26.0`,
`sdk 27.1` and `file` reported arm64 Mach-O objects.

## Pins

- ag-psd 34.1.0, commit `a74425db6584cc07b1cc135e370916cb4eccfb32`, MIT.
- ZIPFoundation 0.9.20, revision `22787ffb59de99e5dc1fbfe80b19c97a904ad48d`, MIT.
- Clipper2 commit `b496b454df168a2280354857c1cd90bd6fa7b4dd`, 2.0.1, BSL-1.0;
  `FloeAgent/ThirdParty/Clipper2/PIN.txt`.
- OpenFCPXMLKit commit `7f55583a3a5b4fecf336ca2ae4b77fb11f8db46d`, MIT; independent
  macOS parser/DTD qualification only; full graph in `Package.resolved`.

## Pending coordinator checks

- Wire `ExchangeTimeline`/media/project types to the shared `MediaProject` v2
  transaction/ownership/revision service; keep the v2 writer authoritative.
- Add/bundle only the needed targets/resources in the App scheme; do not add the
  Clipper2 or OpenFCPXMLKit packages to the App unless deliberately required.
- Run the coordinator's serialized App build and Simulator/device/UI acceptance
  after integration. Inspect `LC_BUILD_VERSION`; the host inherits
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk`, so clear it for
  SwiftPM and set the Xcode platform SDK explicitly for xcodebuild.
- Validate real FCP application import, larger/real media, low-alpha PNG on an
  actual iPad, and shared-v2 concurrency/undo. These are not claimed here.

## Adapter limitations

- PSD baseline: 8-bit RGB only; CMYK/16-bit/PSB/text/smart objects/effects are
  preserved-only. ORA baseline: 0.0.3 raster, no masks/clipping/nested
  stacks/text.
- FCPXML: documented subset; non-1x retimes/effects/transitions/titles/compound/
  subtitle tracks are rejected or reported; DTD pass is not FCP app import.
- OTIO: documented JSON subset; captions are rejected; unknown effects are
  retained/reported, no Python.
- Geometry: quantized tessellation; explicit `flatteningTolerance` and
  `quantizationScale` are part of the result contract.
