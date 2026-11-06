# Native audio reuse and notices

The exact revisions below are in `Package.swift` / `Package.resolved`. The current native implementation uses AudioKit node utilities/AppleSequencer, AudioKitEX Fader and Soundpipe DynamicOscillator/AmplitudeEnvelope. Pinning or compiling the other upstream APIs does not mean those features are implemented in Floe.

| Component | Pinned revision | Upstream terms retained here |
| --- | --- | --- |
| [AudioKit](https://github.com/AudioKit/AudioKit) 5.7.2 | `97a35fe04cd8e3d13b8744e1216b8673f825bef6` | [MIT](ThirdPartyNotices/AudioKit.md) |
| [AudioKitEX](https://github.com/AudioKit/AudioKitEX) 5.7.0 | `c33dac0f581e4ef5bf179e550394f3152aafabfd` | [MIT](ThirdPartyNotices/AudioKitEX.md) |
| [SoundpipeAudioKit](https://github.com/AudioKit/SoundpipeAudioKit) 5.7.4 | `d8afd31b3710a0efd5f9ecb11f1169ca493795e9` | [MIT](ThirdPartyNotices/SoundpipeAudioKit.md), bundled [inih BSD-3](ThirdPartyNotices/inih.md) |
| [Tonic](https://github.com/AudioKit/Tonic) | `8f103c6765af93bc1d2c3e18eb35f02718b0613d` | [MIT](ThirdPartyNotices/Tonic.md) |
| [KissFFT](https://github.com/AudioKit/KissFFT) 1.0.0 | `dd0636e151724b8ba2e0908eba4d99a6ff24d00c` | [BSD-3](ThirdPartyNotices/KissFFT.md) |
| [LAME](https://lame.sourceforge.io/) 3.101 | archive SHA-256 `7578af6eebd578b2bd64e468fac4ae1f03670a7e028166e67f855674b9b6aeac` | [Upstream license explanation](Vendor/LAME/LICENSE), [GNU Library GPL v2 text](Vendor/LAME/COPYING), [selected source/config hashes](Vendor/LAME/UPSTREAM.json) |

The keyboard package has its own [Keyboard/Tonic notices](../KeyboardUI/NOTICE.md). AVFoundation/AudioToolbox are Apple system frameworks, not vendored open-source implementations.

LAME is vendored as the encoder library's 19 C sources, private/public headers and a generated Darwin arm64 configuration. Upstream C/header behavior is unchanged. Native object builds compile this library; the qualification executable calls it directly. A host LAME CLI is used only to generate a test input, and FFmpeg only to independently inspect artifacts.

This predevelopment handoff does not settle App-distribution obligations. Before shipping a binary containing LAME, the integration/release owner must implement the applicable source/relinkability and notice requirements and confirm the actual store/package delivery route. Keeping these files in the repository alone does not complete that work. `MusicMP3Exporter` remains a replaceable service boundary. No commercial SDK purchase or publication is authorized here.

Signalsmith Stretch and PianoRoll remain research candidates, not runtime dependencies in this package. Signalsmith's isolated arm64 object check is not proof of implemented DJ keylock or listening quality. The older Soundpipe 5.2.2 header failure is retained as historical evidence; 5.7.4 is the selected graph and builds without a local DSPBase-header workaround.
