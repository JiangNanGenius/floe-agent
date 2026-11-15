# FloeGameSpriteKit

Native PNG pixel, sprite-sheet and frame-animation editing for the auxiliary
game editors (predevelopment, independent package; App/host integration is
coordinator-owned).

- `FloeGameSpriteCore`: bounded exact-RGBA pixel model, safe ImageIO PNG
  decode/encode, validated frame grids and RPG Maker presets, brush/eraser/
  fill/eyedropper operations, flip/rotate, animation sequences and the
  `SpriteEditorDocument` session-bound editing model.
- `FloeGameSpriteUI`: iPad-first SwiftUI editor with a dense frame list, a
  nearest-neighbour canvas with checkerboard/zoom/pan, compact tools and
  attributes, animation preview, EN/zh-Hans copy and 44 pt targets.
- `GameSpriteEditorView(session:path:)`: the public surface injected through
  `GameVisualEditorPanel` / `GameVisualEditingSurface` as an optional
  `imageEditorFactory`.

The package has no third-party dependency. It uses SwiftUI, UIKit (gesture
layer, iOS only), CoreGraphics and ImageIO. New source is MPL-2.0.

## Session contract

`GameSpriteEditorView` is an auxiliary editor, not a second IDE or repository:

- All reads use `GameEditingSession.documentBytes(at:)`.
- Every committed gesture is exactly one `session.editDocument(...)` call. One
  brush stroke, one fill, or one whole-image transform produces one existing
  session edit, so the shared undo/redo stack, history, drafts, conflicts and
  atomic save apply unchanged.
- The gesture commit decodes the session's fresh bytes, applies the recorded
  operation and clips it to the selected frame. A concurrent edit elsewhere in
  the sheet is therefore preserved instead of being overwritten by a stale
  full-sheet copy.
- The model reloads after undo, draft recovery and external conflict from the
  session's current bytes. Reloads are debounced and skipped while a gesture is
  active; an in-flight gesture is never clobbered.
- Unsupported or invalid PNGs leave the original file untouched and report a
  readable issue. There is no detached save, hidden repository or private undo
  stack.
- The outer `GameVisualEditingSurface` toolbar remains the Save/Undo/Redo/
  handoff authority. The factory is backward compatible (`nil` keeps the
  original `AssetPreviewView`).

## Frame grids and presets

Presets only select an integer grid; they never resize, crop or resample the
PNG. A sheet whose width/height does not divide exactly is rejected with a
readable message.

| Preset | Character sheet | Full sheet |
| --- | --- | --- |
| RPG Maker XP | 4 x 4 | not a separate layout (one character per file) |
| RPG Maker VX | 3 x 4 | 12 x 8 |
| RPG Maker VX Ace | 3 x 4 | 12 x 8 |
| RPG Maker MV | 3 x 4 | 12 x 8 |
| RPG Maker MZ | 3 x 4 | 12 x 8 |

Character frames use the conventional down/left/right/up row order. A full
sheet groups 12 frames per character block (4 blocks across x 2 down for
VX/Ace/MV/MZ). Animation preview cycles the selected frame's direction row
inside its character block; custom grids cycle the selected row. The animation
loop runs only while its view is visible, and the frame rate is bounded to
1-30 fps.

Common sheets are auto-detected conservatively from exact dimensions and square
frames of at least 8 px: 12 x 8 full sheet, 4 x 4 XP, then 3 x 4 single
character. Users can always choose a preset or custom columns/rows. For example
`img/characters/FloeHero.png` at 576 x 384 detects as a 12 x 8 MV/MZ full
sheet with 48 x 48 frames.

## PNG safety and exactness

- Encoded size, pixel dimensions and pixel count are checked from ImageIO
  metadata before a decoded bitmap is allocated.
- Limits: 8192 px per dimension, 16,777,216 pixels, 64 MiB encoded and 64 MiB
  decoded by default (`SpritePNGLimits`). Invalid/truncated PNGs are rejected.
- RGBA is stored as straight alpha. Opaque and transparent pixels are copied
  directly from ImageIO's straight-alpha provider when available; the
  premultiplied drawing path is a documented fallback. Encoding verifies the
  exact pixel roundtrip by default.
- Sprite size is bounded and frame crops share the decoded CGImage, so SwiftUI
  bodies do not decode the PNG or allocate per-pixel images.

## Host integration

The host owns the session and the outer toolbar. Inject the view as an optional
factory; no change is required when it is absent:

```swift
GameVisualEditingSurface(
    session: session,
    path: path,
    tileMapEditorFactory: { session, path in
        AnyView(MyTileMapEditor(session: session, path: path))
    },
    imageEditorFactory: { session, path in
        AnyView(GameSpriteEditorView(session: session, path: path))
    },
    onOpenIDE: { try openIDE($0) }
)
```

The PNG factory is invoked for `.png` paths even when a generic engine adapter
does not classify the file as an image; the PNG decoder validates the bytes.
Non-PNG visual assets and a missing factory keep the existing
`AssetPreviewView`.

## Checks

Source-only handoff under the Main native hold. The prepared package tests
cover PNG roundtrip/limits, preset validation, non-square frame crops, tool and
fill boundaries, session edit/undo/redo/save/reopen, draft recovery, conflict
resolution, animation stepping and the public UI surface signature.

Suggested commands on a host with the selected toolchain (do not run them while
Main holds the native build resource):

```bash
cd "FloeAgent/Modules/FloeGameSpriteKit"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path "$HOME/Library/Caches/CodexBuild/game-predevelopment-sprite"
```

For the iOS UI target, use the same selected Xcode and an explicit iOS
destination in the coordinator-owned native window. A SwiftPM test run proves
the core behavior on the host platform, not full-App or physical-device
acceptance.
