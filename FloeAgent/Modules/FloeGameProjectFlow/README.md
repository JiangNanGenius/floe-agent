# FloeGameProjectFlow

Isolated Swift package for the 20-engine game project selection and lifecycle
flow. It composes the frozen predevelopment SDK instead of copying it:

- `FloeGameCore` repository, project context, revision and digest services
- `FloeGameRunKit` nested game-root discovery
- `FloeGameStarterKit` exact 20-engine catalog and real starter scaffolder
- `FloeGameAuthoring` context handoff
- `FloeGameWebKit` run context port
- `FloeGameIDEBridge` workspace pin validation

It does **not** run, build, install, download or translate an engine, and it owns
no Main App UI, IDE, Git service, provider configuration or cross-repository
transfer. `FloeGameProjectSelectionUI` is an optional reference picker only.

## Products

- `FloeGameProjectFlow`: coordinator, immutable snapshot, persisted selection,
  create/import/fork preparation, `currentRunSelection`.
- `FloeGameProjectSelectionUI`: small SwiftUI reference list for an iPad
  dense selector. Root owns final visual direction.

## Source-only status

This checkout was produced under Main's native/Simulator/engine execution HOLD.
No Swift compiler or XCTest was run. The only executed checks are the static
Python checks in `../checks/`. Swift tests are included and ready for Root's
serialized native window:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path "FloeAgent/Modules/FloeGameProjectFlow" \
  --scratch-path "$HOME/Library/Caches/CodexBuild/FloeAgent/game-selection-20261114" \
  --jobs 4
```

See `../API-HANDOFF.zh-CN.md` for the stable integration API and
`../HANDOFF.zh-CN.md` for scope, checks and limitations.

## License

MPL-2.0. See `LICENSE`.
