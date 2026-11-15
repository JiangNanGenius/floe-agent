# FloeGameDeveloperKit

Development-only, bounded game controls for the Floe owned play session.

- `FloeGameDeveloperCore` — typed session, capability/state models, strict wire
  validation, 20-engine catalog and the RGSS binary file-RPC transport.
- `FloeGameDeveloperWebKit` — `GameWebPlayerDeveloperTransport` over the
  host-owned `FloeGameWebKit` bridge.
- `FloeGameDeveloperUI` — compact SwiftUI menu/view model in English and
  Simplified Chinese.
- `floe-game-developer-matrix` — prints the 20-engine capability matrix.

No JavaScript/Ruby/shell evaluator is exposed to the model or user. The host
attaches the bridge; ordinary exported games do not include it. Project files,
Git, environments and saves remain owned by their existing services.

## Self-tests

```sh
# macOS package tests (host toolchain; use the shared native-window wrapper
# when the host requires serialization)
swift test --package-path . --jobs 6

# iOS arm64 simulator objects (resource bundles need SwiftPM's native build
# system, not the Xcode build system's bundle CodeSign step)
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
swift build --build-system native --package-path . \
  --scratch-path ~/Library/Caches/CodexBuild/FloeGame/predevelopment-next/Xcode27.2/developer-kit-ios \
  --triple arm64-apple-ios26.0-simulator --sdk "$SDK" \
  --target FloeGameDeveloperUI --jobs 6

# JS helper/hooks and real-engine data-model checks
node Scripts/verify_developer_js.mjs
FLOE_TEST_ENGINE=rpgMakerXP /usr/bin/ruby Scripts/verify_rgss_overlay.rb
FLOE_TEST_ENGINE=rpgMakerVX /usr/bin/ruby Scripts/verify_rgss_overlay.rb
FLOE_TEST_ENGINE=rpgMakerVXAce /usr/bin/ruby Scripts/verify_rgss_overlay.rb
```

`Scripts/verify_developer_js.mjs` covers the helper, push bridge, imported
`FloeNativeWeb/game.js` scalar fallback, microStudio named state, WASM-4 saved
globals, LÖVE/TIC-80 main-loop pause/resume/step, actual inkjs 2.4.0 and actual
Babylon.js 9.35.0 NullEngine. The Ruby script executes the real overlay with
distinct standard-shaped XP/VX/VX Ace stubs. These are component checks, not
WebKit/App/device or real Tapir/RGSS acceptance.
