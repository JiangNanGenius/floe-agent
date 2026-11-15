# Vendored source record

Reduced private copies of three authoritative Main modules were made solely to
build and test this independent package without touching Main. App wiring,
project.yml, the root Package graph and Git belong to the App integration owner.

| Copy | Source | Copied targets | Removed from copy |
| --- | --- | --- | --- |
| `Vendor/FloeGameKit` | `FloeAgent/Modules/FloeGameKit` | `FloeGameCore` | WebKit, executables, tests |
| `Vendor/FloeGameEditingKit` | `FloeAgent/Modules/FloeGameEditingKit` | `FloeGameEditingCore`, `FloeGameEditingUI` | sample executable, tests |
| `Vendor/FloeRPGProjectKit` | `FloeAgent/Modules/FloeRPGProjectKit` | `FloeRPGCore` | tests/fixtures |

The reduced `Package.swift` files are new packaging files, not edits to Main.
`BASELINE-SOURCES.json` records SHA-256 for every copied source file.

## Intentionally changed vendor file

`FloeGameEditingKit/Sources/FloeGameEditingUI/GameEditingSessionView.swift`:
adds an optional `@MainActor (GameEditingSession, GameRelativePath) -> AnyView`
factory so an App host can use `RPGTileMapEditorView` for RPG maps without a
package dependency cycle. Nothing else in the generic editor is changed; the
color-GID `TileMapEditorView` remains the fallback.

`FloeRPGProjectKit/Sources/FloeRPGCore/Engine/RPGMapDocuments.swift` and
`Project/RPGEditingAdapters.swift`: add `removeEvent(id:)` and apply the DTO's
kept event-id set so deleting an object in the visual map editor actually
removes the event on JSON and binary maps. This is additive; all other codec
paths and unknown fields are untouched. See `PATCH-RPGMapDocuments.diff` and
`PATCH-RPGEditingAdapters.diff`. The App host should review this behavior change with
the guarded merge.

The matching Main file at task start: `40539510640707b07610f8f774cc8d1648e4d5189b2043f9bdcf301ae5f21208`.

## Main read-only inputs

- `TileMapEditorView.swift`
- `TileMapDocument.swift`
- `EditingAdapter.swift`, `EditingSession.swift`, `StructuredEditing.swift`
- `RPGMapDocuments.swift`, `RPGEditingAdapters.swift`, `RPGProjectSession.swift`

No Main file was written. No Main module directory was created.
