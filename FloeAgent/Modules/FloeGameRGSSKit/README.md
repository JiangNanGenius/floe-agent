# FloeGameRGSSKit

Independent Swift 6 package for **real RPG Maker XP / VX / VX Ace runtime
integration** over the existing FloeGameKit repository and Web run contract.
Source/data import and Ruby Marshal codecs remain in `FloeRPGProjectKit`; this
package does not duplicate them, does not execute Ruby on the native host, and
does not claim that editing data proves play.

App/UI integration is coordinator-owned and deliberately absent.

## What is implemented

| Area | Behavior |
| --- | --- |
| Engine profiles | XP/RGSS1, VX/RGSS2 and VX Ace/RGSS3 markers, script paths, data extensions and screen sizes; unknown files are never pruned |
| Source import | create repository project first, then import the entire original tree through `FileGameProjectRepository`; hidden/unknown/plugin/native files retained |
| Templates | original XP/VX/VX Ace project files plus real keyboard declaration; no RTP, Enterbrain script, engine DLL, proprietary font or third-party game |
| Runtime pack pins | reviewed mkxp-web Asyncify RGSS1 engine pack (GPL-2.0-or-later), fixed source commit, binary provenance commit, file hashes, complete source archive and source offer |
| Web artifact | source-bound `GameWebArtifactPackage` sealed from a prepared content root; engine files, harness, manifest, licenses and `floe-inputs.json` are hashed; native EXE/DLL/encrypted archives are omitted from the Web artifact but preserved in the repository |
| Web harness | same-origin package fetch only, Emscripten MEMFS, no NODEFS/NODERAWFS, no host bridge, no IndexedDB/localStorage/service worker, no general evaluator; optional `window.FloeGame.key(eventObject)`, `input`, `pointer`, `snapshot`, `restore` |
| Keyboard declaration | `floe-inputs.json` schemaVersion 1 with movement keys and labelled buttons; actual pinned keybindings are documented and validated |
| Save bridge | virtual `Save*.rxdata/rvdata/rvdata2` preservation through the host snapshot/restore JSON, capped at the host 1 MiB state limit; not a live VM snapshot |
| Compatibility inspection | read-only detection of markers, scripts, encrypted archives, native DLL/EXE, RTP/library references, unsupported audio, fonts, plugins and unknown root entries; concrete warnings, no silent translation |
| Linux guest integration | typed `RGSSGuestRuntimePort` / `RGSSGuestContextHost` adapter with explicit environmentID, owner, root, revision and owned job stop; no process, VM, display service or credential handling in this package |
| Run host | `RGSSWebRunPreparer: GameWebRunPreparationHost` seals the Web artifact and returns the existing `GamePreparedWebRun`; it fails closed until root enables WebAssembly for RGSS IDs |

## Engine support (truthful)

- **XP (RGSS1) Web**: real mkxp-web Asyncify WASM engine from
  `pulsejet/mkxp-web@e0437fdc5be29507e78d148a2b3f02d26ee1c779`. The upstream
  Asyncify build requires a project `main_update_loop`; an arbitrary imported
  XP game with a blocking `loop { Graphics.update }` needs an explicit port.
  Imported games can also use MRI-only syntax, Win32API, DLLs, RTP or fonts.
  "Import succeeded" or "data edited" is not a play claim.
- **VX (RGSS2) Web**: a concrete source recipe is pinned for
  `Dim145/mkxp-web-jspi@65a31be926b1f6b01cee9b6ebde229f288c421af`
  (GPL-2.0-or-later, RGSS1/RGSS2, JSPI). The complete source archive, NOTICE,
  CHANGES and Docker build recipe are retained privately, but **no JSPI engine
  binary was built or executed by this lane**. WebKit Safari 27 beta adds
  WebAssembly JSPI and Root's actual iPad probe reports WASM/JSPI present; API
  presence is not engine acceptance, so VX is marked `sourceRecipeOnly`, not
  supported/verified Web gameplay. The typed Linux adapter remains the executed
  fallback path (not launched here).
- **VX Ace (RGSS3) Web**: no reviewed iOS-compatible Web engine resource is
  pinned. The typed Linux adapter is provided for mkxp-z, but this lane did not
  build, launch or qualify it.
- **Not supported/claimed**: native host Ruby or mkxp execution, automatic
  RGSS1⇄RGSS2⇄RGSS3 conversion, RGSSAD decryption, video, WMA/MIDI decoding in
  the Web adapter, general Win32API emulation, arbitrary-game snapshot/restore,
  and any JSPI VX engine run (source recipe only).

## Actual execution evidence

A private headless Edge/Chromium (Chromium 157) qualification ran the sealed
artifact with the original XP fixture:

- engine booted and rendered 30 frames (`FLOE_FRAME 30`);
- real `Graphics`/`Sprite` output produced a 240×120 non-black blue region in
  the screenshot;
- `FloeGame.key` generated confirm/cancel/action1/page-up/page-down triggers;
- `File.open` + `Marshal.dump` produced a real 104-byte `Save1.rxdata`, the
  bridge exposed it through `snapshot()`, and `restore()` on a reload produced
  `FLOE_RESTORE_OK` with the previous nonce;
- no host filesystem mount, IndexedDB, worker or native bridge was used.

This is browser/headless evidence, not App WebKit, Simulator, device or pixel
acceptance. Root owns final AppKit/WebKit/Simulator/device acceptance.

## Required host Web policy (root-owned)

`GameWebRuntimePolicy(engine: .rpgMakerXP)` currently has
`allowsWebAssembly == false`. The sealed RGSS harness needs:

- `script-src` including `'wasm-unsafe-eval'`;
- `connect-src 'self'` for on-demand same-origin artifact fetch;
- `.wasm` served as `application/wasm`;
- no COOP/COEP, SharedArrayBuffer, worker, service worker or cross-origin
  network;
- a 1 MiB state limit (the current non-listed engine limit). Larger RGSS saves
  need a root policy increase; the harness caps at the host limit.

The exact CSP is emitted in `RGSSWebRuntimeRequirements.requiredContentSecurityPolicy`
and in each sealed `floe-runtime-manifest.json`. `RGSSWebRunPreparer` throws
`hostPolicyRequiresWebAssembly` until root updates the policy. This package does
not edit `FloeGameKit` or the App.

## Keyboard declaration

`floe-inputs.json` (schemaVersion 1) uses real keyboard keys, never gamepad
labels or commands. The table below is the **mkxp-web** pack mapping; it is not
the Tapir native mapping. The standard declaration now follows the native
Tapir engine per generation (see the private `KEYBOARD-MAPPING.md`).

| Declared key | Engine button |
| --- | --- |
| Z, Left/Right Shift | RGSS `A` (dash) |
| X, Escape | RGSS `B` (cancel) |
| C, Enter, Space | RGSS `C` (confirm) |
| Q | RGSS `L` (page up) |
| W | RGSS `R` (page down) |
| Arrows | directions |

For Tapir native: XP labels are `C`, `X`, `Z/Shift`, `Q`, `W`; VX/VX Ace labels
are `Z`, `X`, `Shift`, `Q`, `W` (physical `C` is unbound and must not be declared
as confirm). A project may provide its own declaration with user-defined
keys/chords. The App's Touch
layer may present any declared key as a virtual button; it must send a real
`window.FloeGame.key({key,code,keyCode,which,location,shiftKey,...,pressed})`
event or the fixed DOM KeyboardEvent path. This package does not add a gamepad
ABXY mapping.

The headless run showed that action triggers work; the evaluated upstream
Asyncify build kept the direction state latched after a synthetic keyup.
Movement is therefore declared but **direction release is not claimed** until
App/device input acceptance confirms it. Do not treat this as a full input pass.
Root's actual iPad WebKit probe (UI14) confirms WASM/JSPI presence in the fixed
defaultClient content world; it is an API capability, not evidence that the VX
JSPI engine runs. The VX fork remains a pinned source/build recipe only.

## Repository and artifact use

```swift
let repository = try FileGameProjectRepository(directory: repositoryURL)
let imported = try await RGSSProjectImporter().createAndImport(
    from: unpackedGameURL, projectID: id, owner: owner,
    title: "Game", repository: repository)

let pack = try RGSSRuntimePack(directory: runtimePackURL)
let artifact = try RGSSArtifactBuilder().build(
    source: context, engine: .rpgMakerXP, pack: pack,
    mode: .importedRequiresReview, to: artifactURL)
```

The pack must contain the pinned `mkxp.js`, `mkxp.wasm`, `rgss.rb`, `COPYING`
and the source archive. It is separately distributed; no GPL binary is placed
in the App target by this module.

## Tests and limits

Host tests cover input declaration validation, save envelope validation, core
templates, template project creation, create-then-import preservation, pack hash
verification, artifact layout/exclusions, compatibility findings, guest context
and ownership, policy requirements and harness static contract. The headless
browser qualification is a separate private Node/browser run; it is not an App
UI test.

See `THIRD-PARTY-NOTICES.md` for license boundaries.

## Native Tapir guest route (private predevelopment)

This copy is the private `rgss-guest-mpl` working tree. It adds
`Sources/FloeGameRGSS/RGSSLinuxGuestHost.swift` and
`Tests/FloeGameRGSSKitTests/RGSSGuestLinuxBindingTests.swift`:

- a concrete `RGSSGuestTargetResolver` / `RGSSGuestJobService` /
  `RGSSLinuxGuestRuntimePort` seam over existing resolved Linux
  environment/jobs/display services;
- fixed argv launch plans (`tapir-x`, `tapir-v`, `tapir-a`), never a shell
  string;
- a physical-key `RGSSGuestInputProfile` for XP versus VX/VX Ace, including
  simultaneous chords, held down/up, and release-all;
- a session controller with new-run fencing, detach-versus-stop separation and
  stale-close rejection;
- a run/save layout that rejects staging inside the immutable source root.

The engine source pins are Tapir `a56b1946...` with Ruby 1.8.1
`053f785...` (XP/VX) and Ruby 1.9.2p0 `572cbb9...` (VX Ace). No engine binary is
bundled in the Swift package. The aarch64 build, fixtures, license/source
offer and qualification harness live in the private `rgss-guest-mpl` package,
not in this Swift package.

Key mapping is documented in the private package's `KEYBOARD-MAPPING.md`;
the older mkxp-web static table is not evidence for this native engine. The
host remains responsible for the existing display service and for the minimal
`VNCSession` held-key phase methods; see `HOST-INTEGRATION.md`.
