# FloeMusicKeyboard API handoff

Updated 2026-11-04 by the coordinator after qualification. This is the nested
`KeyboardUI` SwiftPM package; its product is `FloeMusicKeyboard`. The folder
was renamed from `Keyboard` to avoid a SwiftPM identity collision with upstream.
The original worker handoff is preserved in task-private evidence.

## Verified status

- 26 macOS controller tests pass, including integer/range handling, owner/sink
  replacement, pedal-held voices, wheel resets and late key releases.
- arm64 iOS 26 object compilation passes with Xcode 27.1 / Swift 6.4.
- The separate `Qualification/Music` iOS App compiles and links this panel to
  `MusicLiveInstrument`; its two UI tests also compile.
- The UI run was blocked by the occupied canonical iPad Simulator lock.
  Rendering, real multitouch and physical-device listening remain unverified.
- The companion native synth produces actual MIDI-note audio in the separate
  macOS offline scenario. That does not prove UIKit touch-to-sound latency.

## Pins and API

AudioKit/Keyboard `3b1a7bfd6f2e49f23ee9fb317a8fde2c3152f371` and Tonic
`8f103c6765af93bc1d2c3e18eb35f02718b0613d` are fixed in the manifest and lock.
MIT notices are retained in `NOTICE.md`. The adapter uses `Pitch(intValue:)`.

| Type | Host responsibility |
| --- | --- |
| `KeyboardOwnerToken` | Stable instrument/session identity on every event |
| `KeyboardPerformanceController` | Main-actor owner/sink, octave/transpose, sustain/bend/modulation; `keyDown`, `keyUp`, `noteRangeDidChange`, `presetDidChange`, `releaseAll(reason:)` |
| `KeyboardPerformanceSink` | Receive owner-tagged note/controller/all-off events on the main actor; keep this path cheap |
| `ElectronicKeyboardPanel` | Compose the panel; default 25 keys from MIDI 48; inject configuration and expansion handlers |
| `KeyboardToneControlSurface` | Inject real presets/parameter bindings; absent controls stay hidden |

Owner/sink replacement releases the original context before installing the new
one. Releases use the pitch that originally sounded. Partial all-off resets
host controllers and restores still-selected pedal/wheel state consistently.
Scene inactivity/panel disappearance releases performance; reopening does not
replay notes. Range and preset changes must be announced by the host.

This package owns UI/events only. Audio/session/recording/storage belong to the
host. Touch position is a velocity policy, not physical key velocity. Preset
labels do not ship a sampled soundbank. The `#Preview` fixture remains silent.
See the [complete handoff](../../../../docs/FLOE_MUSIC_WORKBENCH_PREDEVELOPMENT_HANDOFF.zh-CN.md)
and [core contract](../CORE_CONTRACT.md) before mainline intake.
