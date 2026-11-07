# FloeScoreKit

离线、以 MusicXML 为原件的五线谱／总谱编辑器。SwiftUI 宿主通过 FloeHeavyEditorSupport 提供真实原件身份、修订、授权、保存和导出回执；UI 与 AI 使用同一注册命令。模块内含实际 OSMD 排版、结构化编辑、标准文件转换和可替换的播放接口，不依赖 CDN。

An offline MusicXML score editor. The native host owns identity, revision, authorization, persistence and managed export receipts. UI and AI share the same bundled command registry. This is an independent module; compiling or qualifying it does not establish full-App or physical iPad acceptance.

## Implemented scope

| Matrix | Source / actual behavior | Checks |
| --- | --- | --- |
| S01 | `Web/model.js`, `parts.js`: MusicXML DOM original, exact rational quarter durations, parts/staves/grand staff/voices, key/meter/clef/transposing instruments, metadata, revision-backed save/reopen and undo/redo | Piano and ensemble fixtures, divisions inheritance, mid-bar division/clef anchors, actual rename, staff add/remove, project reopen |
| S02 | `edit.js`, `notation.js`: rests/notes, dots, arbitrary tuplets, chords/polyphony, tie/slur/glissando, automatic beams, pitch/duration/onset edits, copy/cut/paste, measure insert/delete/duplicate/move, rest fill and tied rebar | Rational 4/7 and 1/3 timing; independent voices/staves; tuplets and ripple timing; tied rebar |
| S03 | `notation.js`: dynamics/wedges, articulations/ornaments, lyrics/syllables, text/rehearsal/harmony, fingering/TAB, pedal/octave directions, percussion, repeats/endings and D.C./D.S./Coda/Fine | Drum MIDI mapping, guitar string/fret pitch, lyrics and unknown-notation preservation, first/second endings and D.C. al Fine |
| S04 | `main.js`, `analysis.js`, OSMD/VexFlow: real music glyph paths, stems/beams/curves and collision/spacing, paper/margins, system/page breaks, zoom, continuous horizontal score, optional condensed rests, linked parts and concert-pitch display | Real WKWebView engraving and note hit targets; paged PDF; whole-score concert transposition |
| S05 | `formats.js`, `midi.js`: XML and compressed MXL read/write, partwise and timewise import, true SMF 0/1 PPQ import and format 1 export, tempo/meter/track/voice reconstruction, quantization, genuine multi-page SVG/PNG/PDF | Official MusicXML 4.0 schema; MXL unzip/rootfile and SMF semantic round-trip; real PDF/PNG decoders |
| S06 | `playback.js`, `ScorePlaybackService.swift`: performed repeat route, tempo map/inverse clock, ties/dynamics/wedges/staccato/pedal, play/pause/resume/stop/seek/loop, tempo/metronome, part solo/mute/volume, cursor; injectable existing music-service adapter or actual AVFoundation reference audio | Piecewise clock and routes; PCM WAV decoded by AVAudioFile with A4 frequency/energy check; fixed operation and owner-stop lifecycle |
| S07 | `analysis.js`: navigable rhythm/range/tie/slur diagnostics, notated duration checks, interval/chord analysis, duration-weighted key estimate, transposition, rhythmic repair, blank/piano/quartet/ensemble/orchestra/voice/guitar/drum templates | Real diagnostic-to-note targets and gap repair; musical fixture analysis |
| S08 | `main.js`, `score.css`: iPad outline/score/inspector, compact phone panels, keyboard and piano entry, touch/Pencil pointer selection/drag transposition, chord-head hit targets, selection, transport and linked-part switcher | WKWebView logical 1240×980 and 390×844 snapshots; click → transpose → selected glyph; all commands in grouped menus |
| S09 | Fixed OSMD 2.2.1 / VexFlow 1.2.93 offline bundle and Gonville/custom/microtonal path glyphs; no MuseScore/LilyPond code, no system font redistributed | `Web/bundle-inputs.json`, shared lock, third-party notices and original glyph terms |
| S10 | 57 bundled commands in `score.project.*`, `score.edit.*`, `score.parts.*`, `score.layout.*`, `score.playback.*`, `score.analyze.*`, `score.import.*`, `score.export`; generic `file.import`, `document.*`, `history.*`; native capability token only during authorized execution | Shared original and history; invalid explicit IDs reject; transport marked `sideEffecting`; `Integration/smoke-plan.json` for real host |

## Build and focused qualification

Run from the repository root, after the shared pinned WebBuild toolchain is installed:

```sh
node FloeAgent/Qualification/HeavyEditors/WebBuild/build.mjs score
node FloeAgent/Modules/FloeScoreKit/Tests/run.mjs
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path FloeAgent/Modules/FloeScoreKit --scratch-path "$HOME/Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/xcode-27B52/score/swift-tests" --jobs 2
```

`Tests/run.mjs` bundles the real engine code and uses the shared pinned jsdom, rather than a duplicate implementation. It emits representative real XML/MXL/MIDI files into the task's scratch directory. `Tests/Fixtures/ensemble.musicxml` is an original CC0 test fixture containing two instruments, a grand staff, tuplets, chord, tied repeat, lyrics, dynamics and unknown notation.

`ScoreWebQualification` is a macOS-only bounded WKWebView executable. Pass the fixture and a task-owned evidence output directory. It loads the actual resource bundle, renders and edits the score, exports all formats, captures iPad/phone layouts, and creates a multipage PDF. It is not the formal App or an iOS Simulator run. Its inactive test window closes at completion.

For iOS object compilation use the `FloeScoreKit` package scheme, generic iOS Simulator destination, explicit internal-SSD DerivedData, `-jobs 2 OTHER_SWIFT_FLAGS=-j2 CODE_SIGNING_ALLOWED=NO`. No Simulator is created or booted.

## Format and playback boundaries

- XML import removes an external DOCTYPE declaration without fetching it; entity/internal-subset declarations are rejected. Unknown XML elements and attributes stay in the DOM. Export strips only Floe internal IDs/markers and canonicalizes known child order.
- MXL supports ordinary unencrypted ZIP containers and retains ancillary files on replace/import/export. ZIP64/encrypted archives are not accepted. Appending scores merges their MusicXML parts with remapped identifiers; ancillary image assets from appended archives are not remapped. Keep original source files through the host import service.
- SMF supports metric PPQ Format 0/1; asynchronous Format 2 and SMPTE timing are rejected with a specific conversion message. MIDI cannot preserve every engraving element. Import reconstructs quantized or original PPQ note timing, independent rhythmic voices, ties over barlines, instruments, tempo, key and meter. Export unfolds repeats/navigation; true tuplets remain exact where a legal MIDI PPQ can represent them.
- PDF uses actual SVG vectors for Latin-text pages. Pages containing other Unicode text are rasterized at 3× into the PDF so CJK titles/lyrics retain visible glyphs without distributing a system font or substituting missing jsPDF glyphs. SVG text uses viewer fonts; music glyphs are paths. PNG is genuine rasterized page output, one file per page.
- The reference audio is real mono PCM16/22.05 kHz AVFoundation playback with synthetic reference timbres; it is not a General MIDI sample library. It supports up to 15 minutes / 50,000 events. Longer scores can export MIDI or use an injected host music service. Acoustic interpretation of ornaments is currently the notated main pitch; editorial ornament glyphs remain intact. Host music timbres and full-App audio integration require the host adapter.
- Changing notation during playback pauses the current performance before replacing its score. Mix changes recompile at the current playback position; tempo/loop settings restart at the loop start. Cancel or presentation close stops only the injected score owner's audio. Physical listening, Pencil feel and the formal App route are separate acceptance tasks.
