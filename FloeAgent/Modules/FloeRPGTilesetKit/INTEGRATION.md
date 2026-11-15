# Integration plan (App host)

This component is source-complete and private. It does not edit the App,
`project.yml`, the root `Package.swift`, Git, versions or distribution.

## 1. Module registration

Keep the dependency direction:

```
FloeRPGTilesetUI
  -> FloeRPGTilesetKit
     -> FloeRPGProjectKit (FloeRPGCore)
        -> FloeGameEditingKit (FloeGameEditingCore)
           -> FloeGameKit (FloeGameCore)
```

The App host chooses whether to move:

- `Sources/FloeRPGTilesetKit` -> `FloeAgent/Modules/FloeRPGTilesetKit/Sources/FloeRPGTilesetKit`
- `Sources/FloeRPGTilesetUI` -> the same module/package or an App-host target
- `Tests/FloeRPGTilesetKitTests` and `Tools/` can stay private (fixtures are
  not App resources).

The package manifests and vendored copies in this directory are for isolated
qualification; the guarded Main merge should use the authoritative Main
packages, not the private `Vendor/` copies.

## 2. Editor factory

Apply `PATCH-GameEditingSessionView.diff` to
`FloeAgent/Modules/FloeGameEditingKit/Sources/FloeGameEditingUI/GameEditingSessionView.swift`.
It adds only an optional factory and keeps the generic editor fallback.

At the RPG editor host, where the `RPGEngine` is already resolved from the
explicit project/adapter (never from the first/global project):

```swift
GameEditingSessionView(
    session: editorSession,
    onClose: onClose,
    tileMapEditorFactory: { session, path in
        AnyView(RPGTileMapEditorView(session: session,
                                     path: path,
                                     engine: rpgEngine))
    })
```

The factory must be for the **current explicit owner/project/revision**
session. Do not construct it from a global list of projects. The view uses the
session's own `projectID`, `expectedRevision`, repository, `baseProject` and
adapter for every byte read and every save.

## 3. Integration acceptance (App host)

- Build the App with the new module and factory.
- On the canonical reused iPad, open an RPG project/map through the normal
  Space project path.
- Verify palette images (A1..E / XP autotiles), paint/erase/fill, layer
  visibility, selection, a shape variant, save, close/reopen and same tile
  ids/pixels.
- Verify missing-image fallback with a deliberately removed image; the map
  must remain open and all tile data retained.
- Touch/visual judgment and device acceptance belong to the App host.

## 4. Native/source status

Native host tests, iOS object compile and iPad UI acceptance are **pending the
App native window**. The package must not be described as compiled or
qualified until those commands have actually run.

## 5. Merge guard

- Returned baseline hashes: `BASELINE-SOURCES.json`.
- Changed vendor file: only
  `FloeGameEditingKit/Sources/FloeGameEditingUI/GameEditingSessionView.swift`.
- No Main/App/project.yml/root Package/Git/version/upload writes by this
  component.
