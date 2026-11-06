# FloeMusicKeyboard

Reusable electronic-keyboard performance panel for the Floe music workbench.
UI only: this package renders the open-source AudioKit `Keyboard` keys plus a
pitch-bend / modulation rail and an optional tone-control surface, and turns
touches into owner-tagged performance events for a host-injected sink. It owns
**no** audio engine, **no** audio session and **no** storage — the host keeps
instrument voices, mixing, recording and persistence.

- iPad first; usable on iPhone. iOS 26 / macOS 15, Swift 6.
- Key rendering: [AudioKit/Keyboard](https://github.com/AudioKit/Keyboard) pinned at `3b1a7bfd6f2e49f23ee9fb317a8fde2c3152f371` (MIT, see `NOTICE.md`). [AudioKit/Tonic](https://github.com/AudioKit/Tonic) pinned at `8f103c6765af93bc1d2c3e18eb35f02718b0613d` (MIT). No dependency float.
- Keyboard UI alone produces no sound.

## Integration

```swift
import FloeMusicKeyboard
import SwiftUI

struct KeyboardDetail: View {
    // Host-side: one controller per instrument track.
    @State private var controller = KeyboardPerformanceController(
        owner: KeyboardOwnerToken("track-42"),
        sink: MyInstrumentTrackSink.shared   // conforms to KeyboardPerformanceSink
    )
    @State private var selectedPreset: String? = "grand"
    @State private var volume: Float = 0.8

    var body: some View {
        ElectronicKeyboardPanel(
            controller: controller,
            configuration: .default,            // 25 keys, C3 start, wheels + sustain
            toneSurface: KeyboardToneControlSurface(
                presets: hostPresets,           // host-licensed descriptors only
                selectedPresetID: $selectedPreset,
                volume: KeyboardParameterControl(value: $volume)
            ),
            onExpand: { /* host presents fullscreen */ }
        )
        .onChange(of: selectedPreset) { _, _ in
            controller.presetDidChange()        // release sounding pitches on voice change
        }
    }
}
```

The sink receives `KeyboardPerformanceEvent` on the main actor:

- `.noteOn(owner, PerformanceNote)` / `.noteOff(owner, note, channel)` — note
  values are post octave/transpose; releases always match the sounded note.
- `.sustain(owner, Bool)`, `.pitchBend(owner, -1...1)`, `.modulation(owner, 0...1)`.
- `.allNotesOff(owner)` — explicit fence after every full/partial release.

### Ownership and lifecycle guarantees

- Changing `controller.owner` or `controller.sink` first releases every held
  note, pedal and wheel state to the **previous** owner/sink — a replacement
  owner can never receive a stale note-off.
- Octave/transpose/range/preset changes release the originally sounding
  pitches; releasing a finger afterwards cannot turn off a newly shifted note.
- `releaseAll(reason:)` is called by the panel on scene inactive and on
  disappear; hosts can also call it on disconnect. There is no autoplay on
  restore.
- The keyboard records and plays through the host's instrument track; MIDI
  recording belongs to the host engine.

## Known limits

- Touch surfaces report position, not true velocity. Default policy derives
  velocity from the vertical touch position inside the key; inject
  `KeyVelocityPolicy.fixed(_:)` or post-process `.noteOn` for anything else.
- Sustain pedal semantics (voices held under the pedal) live in the host
  instrument; the panel forwards pedal state and immediate key releases.
- Pitch-bend is normalized −1...1; the host maps it to its bend range.
- Preset descriptors name host-supplied voices only; this package ships no
  sounds and no preset assets.
- The upstream `Keyboard` component draws and hit-tests the keys; touch
  cancel is handled upstream. Simultaneous multi-touch is supported.
- Latching key mode is intentionally not exposed for the performance panel.
- Localization ships in `en` and `zh-Hans` via the package bundle.

## Development status

26 controller tests and arm64 iOS object compilation pass. The independent
iOS component App and its UI tests compile and link to the native synth. The
UI run was blocked by the occupied canonical iPad Simulator lock; rendered
layout, real multitouch and touch-to-sound/device quality are still unverified.
See `API_HANDOFF.md` for exact boundaries.
