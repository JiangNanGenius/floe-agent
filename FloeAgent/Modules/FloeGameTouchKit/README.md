# FloeGameTouchKit

Independent iOS/iPadOS 26+ **keyboard** touch controls for a game viewport. The
package is a predevelopment component; it is not yet wired into the Floe App.
`FloeGameTouch` supplies validated keyboard bindings, engine/template presets,
a service-owned input queue and per-project persisted settings.
`FloeGameTouchUI` supplies SwiftUI settings, native UIKit joystick tracking,
directional buttons and arbitrary remappable on-screen keys.

The controls send keyboard keys/chords, not gamepad ABXY actions. An RPG Maker
profile, for example, defaults to arrows + Z/X/Shift/Q/W. Old persisted
action-based profiles are migrated with the WebKit player's existing fixed
fallback keys; typed actions remain available only as an internal compatibility
path.

## Public core API

- `GameTouchButton.ID` is a validated string ID (`GameTouchButtonID` behind a
  nested type alias). Legacy `a`, `b`, `x`, `y`, `start`, `select` values decode
  unchanged; arbitrary user IDs are bounded to 1...64 ASCII identifier bytes and
  `GameTouchButton.ID.generated()` gives a stable unique ID.
- `GameTouchButton` keeps `id`, `binding`, `anchor`, `visible`, and adds `label`,
  optional `width`/`height` (44...320), and `mode` (`.hold`, `.tap`, `.toggle`).
  A profile holds up to 64 unique buttons and exposes `button(id:)`, `add`,
  `update`, `remove(id:)`, and `move(id:to:)` where the destination is the final
  index.
- `GameTouchBinding` supports `.key`, `.chord`, and a legacy `.action`.
  `.keyboardKeys` and `.keyCap` are available to the UI. `GameTouchChord`
  canonicalizes 1...8 unique keys modifiers-first.
- `GameTouchProfile` supports `.engineDefault`, `.arrows`, `.wasd`, and
  `.custom` movement. `directionBinding(for:)` resolves the effective chord;
  `setDirectionBinding(nil, for:)` explicitly unbinds and selects custom mode.
  `Stick.none` hides the direction controller independently of `enabled`.
- `GameTouchProfile.keyboardTransport` is `.browser` (default) or `.x11`. This
  selects the host's input encoding only; it is not another environment or
  permission system.
- `GameTouchProjectBindings(json:engine:)` validates a `floe-inputs.json`
  declaration without loading project code. The profile created through
  `standard(_:keyboardTransport:projectBindings:)` marks
  `.projectDeclaration` provenance.

## Defaults and provenance

`GameTouchDefaults.catalog(for:keyboardTransport:)` is read-only data, so a host
can distinguish a documented engine key map from a Floe template fallback.

| Engines | Source | Default |
| --- | --- | --- |
| RPG Maker XP/RGSS1 | engineDefault | Arrows; C confirm (Enter/Space alternatives), X cancel/menu, Shift action A, Q/W page; Z is also A |
| RPG Maker VX/Ace/MV/MZ | engineDefault | Arrows; Z confirm, X cancel/menu, Shift dash, Q/W page |
| TIC-80 | engineDefault | Arrows; Z/X/A/S for A/B/X/Y |
| WASM-4 | engineDefault | Arrows; X button 1, Z button 2 |
| Ren'Py | engineDefault | Space/Enter dismiss, Esc menu, Ctrl skip, Tab toggle skip, PageUp rollback, H hide windows; no d-pad |
| Ink, Twine | templateFallback | No d-pad or keys assumed; Floe narrative wrapper still needs runtime-owner verification |
| Phaser, KAPLAY, Godot, Babylon, PlayCanvas, LÖVE, GDevelop, Cocos Creator, microStudio, Unity | templateFallback | Arrows only and no action buttons; project-defined input must be declared |

Primary references recorded by the catalog include the RPG Maker MZ
`Input.keyMapper` (`88 escape`, `90 ok`, `16 shift`, `81 pageup`,
`87 pagedown`), the RPG Maker MV/VX-Ace official control tables, the TIC-80
button/key documentation, the WASM-4 player-1 keyboard layout, and the Ren'Py
default keymap. A project declaration always wins over a template fallback.

## Project declaration (`floe-inputs.json`)

```json
{
  "schemaVersion": 1,
  "engine": "phaser",
  "movement": {
    "left": ["left"],
    "right": ["right"],
    "up": ["up"],
    "down": ["down"]
  },
  "buttons": [
    { "id": "confirm", "label": "Z", "keys": ["z"] }
  ]
}
```

- Keys may be `GameKeyboardKey` raw values (`pageUp`, `rightShift`, `z`) or the
  fixed DOM `code` aliases used by the player (`PageUp`, `ShiftRight`, `KeyZ`,
  `ArrowLeft`, `Digit1`, `Numpad5`). Unknown names are rejected.
- A movement array is always one simultaneous chord. `[]` or a missing axis is
  explicitly unbound and never falls back to arrows. `movement: {}` is valid.
- `buttons: []` is meaningful for a movement-only game. Button IDs are bounded
  and unique; unknown fields, extra top-level commands/URLs, more than 64
  buttons, or more than 8 keys are rejected. Declarations are metadata only;
  project scripts are never parsed or executed.

## Input service semantics

The host may also call `GameProjectKeyboardDiscovery.discover(engine:sources:)`
with bytes read from its captured project revision. Besides `floe-inputs.json`,
it reads Godot 3/4 `project.godot` InputMap data and Unity `.inputactions`
(action maps, keyboard composites and modifier bindings) or legacy
`ProjectSettings/InputManager.asset`. It never opens files or executes a
project. Input is bounded to 128 files, 2 MiB per file and 8 MiB total.
Multiple project roots/action maps remain separate candidates; unsupported or
ambiguous mappings carry warnings. A host selects the candidate explicitly
before creating the profile. Five additional behavioral tests cover these
formats, independent alternatives, malformed data and bounds.

Bindings are flattened to physical keys before delivery. Reference counting is
per physical key, so Ctrl+Z and Ctrl+X, or a separate held Ctrl, cannot release
each other's Ctrl. Modifiers press first and release last; ordinary keys release
before modifiers; ordering is deterministic. Releasing one of two buttons mapped
to the same key cannot release the other. Old attachment callbacks are fenced,
the queue coalesces toward the desired state, and failures are observable
through `lastError` with a best-effort release of delivered keys/actions.

`.tap` pulses for a bounded time owned by the service. `.toggle` latches until
pressed again. `activeButtonIDs` is read-only published state for sticky visual
feedback. Detach, profile change, `releaseAll`, and App scene handoff cancel
timers and release every held key. A profile change also advances the service
generation and publishes a fresh attachment ID after old releases drain, so a
finger callback captured under the previous mapping cannot press, release, or
move the remapped controls.

## Settings

`GameTouchProfileStore` uses the existing bounded `FileGameSaveRepository` CAS
component. Each project owner/engine/keyboard-transport pair is an independent
slot. `load(engine:keyboardTransport:defaults:)` keeps the old
`load(engine:)` call valid and returns caller-supplied project defaults only
when no user slot exists; `save` infers the engine/transport and never mutates
source files or game progress. The old single-file settings are read as a
migration source (browser transport only) and are never deleted or overwritten.
There is no workspace/global first-project fallback.

## Host flow

1. Resolve the actual project ID and owner, then load `GameTouchProfileStore`
   with the engine and transport.
2. Create and retain `GameTouchInputService`; attach the active kernel/player
   after it can accept input.
3. Put `GameTouchControlsView` over the game viewport. Keep App navigation
   outside that viewport. Capture its attachment ID for delayed callbacks.
4. Present `GameTouchSettingsView` for movement mode, custom direction chords,
   keys/chords, labels, sizes, behavior, handedness, opacity and dead zone.
5. Save with the expected revision, then call `updateProfile`. Detach before
   closing.

## Reused component and license

The joystick reuses the UIKit implementation from
[bradhowes/Joystick](https://github.com/bradhowes/Joystick) at
`c240bb6e5a84fb00f01862d2a6dca28a43504679` under MIT. The five original files
and full notice are in `ThirdParty/JoyStickView`; original blob identities and
the sole `canImport(UIKit)` portability patch are recorded in
`ThirdParty/Joystick-PIN.json`. Joystick artwork is drawn locally with UIKit;
upstream image assets and build plugins are not included. Floe code is MPL-2.0.

The public control SDK code is compiled and signed with the App. There is no
downloadable native control plugin. Browser execution and the final App's Apple
review remain the responsibility of the host integration.

## Verification

`TouchTests` covers all 20 engine presets and keyboard-only defaults, legacy ID
and action migration, arbitrary/custom button counts with bounds and duplicate
rejection, project declarations (aliases, empty/partial movement, unknown
content), physical modifier reference counts, custom/unbound directions,
tap/toggle lifecycle, profile-change attachment fencing, per-engine/transport
CAS slots, caller defaults, owner isolation, and legacy single-file migration.

Verified on 2026-11-12 in this private package through
a guarded host run recorded **18 tests passed,
0 failures**, and a real arm64 iOS build compiled `FloeGameTouch`,
`FloeGameTouchUI` and the MIT joystick against the iPhoneOS 27.2 SDK with
`arm64-apple-ios26.0`; the resulting objects are Mach-O arm64 with
`LC_BUILD_VERSION platform 2 (iOS), minos 26.0, sdk 27.2`. Actual iPad
interaction, WebKit keyboard delivery and final SwiftUI acceptance remain with
the Root qualification host; a test-host and object result is not a touch or
device acceptance claim.

Root qualification on 2026-11-12 additionally passed 23 Touch/discovery tests
and two keyboard descriptor tests, then built and ran the independent iPad
Simulator host. UI13 passed the actual flow: create before full ZIP import,
move the real Phaser game with a held key and joystick, add a named Ctrl+Right
chord through native settings, save, close and reopen, then move with that
persisted chord. Layout drag recognizers are installed only while arranging
controls so they cannot cancel UIKit joystick tracking during play. The
canonical iPad was shut down afterwards. Exact source hashes, built host/runner
ZIP and commands are recorded under
a host qualification artifact directory,
with test results in `ui-13`. This remains component-host evidence; the full App
and physical-device flows have not been accepted.
