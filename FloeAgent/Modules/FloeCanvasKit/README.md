# FloeCanvasKit

Independent Swift 6 package for a native infinite canvas combining research
materials and programmable AI workflows on the same page. iOS 26 / macOS 15,
swift-tools 6.2, MPL-2.0.

| Product | Responsibility |
| --- | --- |
| FloeCanvasCore | Stable snapshots, rich content, atomic edit batches, identity copying and typed flow data |
| FloeCanvasLayout | Public DiagramKit routing/spatial indexes, folding, local arrangement and viewport queries |
| FloeCanvasUI | SwiftUI panels, UIKit/CoreGraphics board, focused editors, Pencil and debugger |
| FloeCanvasFlow | Typed compilation, structured conditions/loops, templates, variables, checkpoints and debugging |
| FloeCanvasExchange | Complete experimental archive, JSON Canvas, Excalidraw, draw.io and PDF/SVG/PNG |
| FloeCanvasIntegration | Host contracts, qualification repositories, source refresh, resource and execution boundaries |

The package does not depend on FloeCore/FloeApp or own production credentials,
storage, permissions or execution environments. Scripts/API steps use injected
host services; there is no host-interpreter fallback. Ordinary relation edges
never execute. Document commits use expected revisions and stable request IDs;
the authoritative host repository owns save and undo.

The independent iPad host and the adapter compiling against actual production
APIs live in [Qualification/InfiniteCanvas](../../Qualification/InfiniteCanvas/README.md).
They do not register a production App entry or upgrade production storage.

## Contracts

- [Core and host boundary](CONTRACT.md)
- [Native editor](UI_CONTRACT.md)
- [Layout](LAYOUT_CONTRACT.md)
- [Flow runtime](FLOW_CONTRACT.md)
- [Format support and conversion losses](FORMAT_SUPPORT.md)

Native .floecanvaslab archives retain complete supported project data, assets,
child project payloads, original unknown payloads and reachable reusable flow
definitions. Open formats carry editable projections within their documented
scope. Always inspect returned conversion issues.

## Verification and examples

Run builds sharing one scratch directory sequentially. Native UI requires the
independent iOS qualification host; macOS package tests alone do not exercise
UIKit or physical Pencil behavior.

Example from the repository root:

~~~sh
DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
swift test --package-path FloeAgent/Modules/FloeCanvasKit \
  --scratch-path ~/Library/Caches/CodexBuild/FloeCanvasKit/local/swiftpm --jobs 6
~~~

The original compatibility example is preserved. The extended offline harness
creates fresh evidence beneath repository-owned Local/Private or Local/Artifacts:

~~~sh
DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
swift run --package-path FloeAgent/Modules/FloeCanvasKit \
  --scratch-path ~/Library/Caches/CodexBuild/FloeCanvasKit/local/swiftpm --jobs 6 \
  floe-canvas-examples qualify --output /absolute/repository/Local/Artifacts/canvas-run
~~~

Independent qualification has recorded component and native-host results. Core/Integration/Flow/Layout/Exchange have
396 passing behavior tests; the offline examples pass all 50 checks. Native UI
and actual iPad-host results must be
read separately in the [delivery record](../../../docs/FLOE_INFINITE_CANVAS_PREDEVELOPMENT_HANDOFF.zh-CN.md).
This is independent predevelopment: production App integration, real model/Linux
jobs, physical Pencil and two-device synchronization have separate acceptance gates.
