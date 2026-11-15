# FloeGameEditingKit

Native auxiliary game-authoring components for FloeAgent (predevelopment,
independent package; App integration is coordinator-owned).

- `FloeGameEditingCore`: project-bound editing session on top of
  `FloeGameCore.FileGameProjectRepository` — one expected revision, one
  undo/redo stack, one diff history shared by AI and manual edits; atomic
  save with conflict + per-file rebase; unsaved-draft recovery; asset
  operations with reference-safe diagnostics; schema-driven parameter forms
  with an engine codec hook; a 2D tile-map DTO (paint/erase/fill, objects,
  selection, snapping); a narrative/event DTO (reordering, branch links,
  validation, read-only preservation of unsupported commands).
- `FloeGameEditingUI`: SwiftUI editors for the four families, iPad-first,
  iPhone/fullscreen usable, 44pt targets, bilingual en/zh copy.
- `GameEditingSample`: launchable macOS sample host with original synthetic
  assets (`floe-game-editing-sample`, `--cli` for a scripted behavior smoke).

## Host entry and iPad layout

Use `GameVisualEditingSurface(session:path:onOpenIDE:onClose:onSaved:)` for
the selected file inside the existing game shell. The host retains the live
workspace lease and supplies the existing IDE callback. File browsing, source
editing and Git stay in that IDE. `GameEditingSessionView` and the macOS sample
are demonstration hosts, not a second production IDE or project navigator.

Wide regular windows show a searchable record list beside two or three compact
property columns. Long text uses the detail width. The layout responds to the
actual available width; narrow windows and accessibility text sizes use one
reading column. Editable rows provide a 44pt focus area, and numeric entry keeps
temporary input separately from committed numeric values. Narrative pages add
command search and branch filtering; RPG map atlases live in the engine-specific
`FloeRPGTilesetUI` sidebar while the host retains the existing layer inspector.

`prepareForHandoff()` is the save boundary before opening the IDE or leaving the
editor. Keep the same session/revision for AI and visual edits to this owned
copy. Ordinary chat and Space projects retain separate owned copies.

## Product order: create → import → organize → edit/play

The session never creates or imports a second project behind the UI. An
empty project shows an import entry; full project/archive import is delegated
to an injected host (`GameProjectImportHost`) with the existing project ID,
owner and base revision. The component's own `importAssets` only adds
individual asset files (bounded, off the MainActor, unreadable selections are
reported, not skipped). Archives are stored verbatim by `importAssets` and
are never pretended to be unpacked. Unknown/encrypted/unsupported files are
preserved and shown honestly (unknown kind, read-only rows).

## Adapter contract (for engine owners, e.g. FloeRPGProjectKit)

Implement `GameEditingAdapter` (see `Sources/FloeGameEditingCore/EditingAdapter.swift`)
and register it in a `GameEditingAdapterRegistry`:

```swift
public protocol GameEditingAdapter: Sendable {
    var engine: GameEngineID { get }
    func assetKind(for path: GameRelativePath, in project: GameStoredProject) -> GameAssetKind?
    func parameterSchemas(in project: GameStoredProject) -> [GameParameterSchema]
    func tileMapBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameTileMapBinding?
    func narrativeBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameNarrativeBinding?
    // Default implementation returns nil (plain JSON bytes).
    func parameterBinding(for path: GameRelativePath, in project: GameStoredProject) -> GameParameterBinding?
}
```

- `GameParameterBinding` carries `decodeDataToJSON` / `encodeJSONToData`.
  Use it for engine-native parameter files (e.g. RPG `rxdata`/`rvdata`
  binaries): the form edits JSON, the session stores the engine-native bytes,
  undo/history compare the original and re-encoded bytes, and unknown
  records/fields must survive `encodeJSONToData`.
- `GameTileMapBinding` is a byte-level codec between your engine-native map
  file and `EditableTileMap`.
- `GameNarrativeBinding` carries your known command specs plus byte-level
  codecs for `NarrativeDocument`. Unknown codes are kept read-only with
  original payloads preserved; do not drop them in `encode`.
- `GameParameterSchema` fields bind form rows to concrete JSON paths. Keep
  schemas narrow: unknown fields round-trip untouched.
- Tile editors commit through the mutating `EditableTileMap.apply(_:)`
  command API (`TileMapEditorCommand`) so no edit result can be dropped.

Without an adapter the editors still work: files remain visible in the asset
browser and tile/narrative documents persist as clearly namespaced editor
staging formats (`floe-editing-tilemap` / `floe-editing-narrative`).

## Editing semantics

- Every edit (AI or manual) is a byte-level `SessionEdit` recorded against the
  session's expected revision; save is one atomic repository commit.
- An external commit makes save fail closed with `GameProjectError.conflict`;
  `reloadForRebase()` carries non-conflicting work forward and isolates
  per-file conflicts for explicit keep-mine/keep-theirs resolution.
- Unsaved drafts (current bytes + undo/redo stacks + history) persist under
  the repository's `EditingDrafts/` area and can be recovered or discarded on
  reopen. External changes retain the draft and its base bytes for rebase;
  deletion and same-file conflicts require an explicit resolution.

## Checks

Run this bundle's `FloeGameEditingKit` package tests for byte/session changes.
Run the focused `NativeUIHost` cases for edited forms, map/events and handoffs;
the host verifies saved/reopened live bytes. Use the host project's selected
Xcode, explicit scratch directory and shared native/device locks. Package tests
and a native host are component evidence; full-App integration is a separate
acceptance step.
