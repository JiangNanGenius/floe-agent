<!-- SPDX-License-Identifier: MPL-2.0 -->
# Native Score panels / 原生乐谱面板

`ScoreEditorView` supplies the shared native workbench with an outline, canvas toolbar, inspector and bottom bar from `ScoreNativePanels.swift`. Instruments, staff selection, measure selection, entry duration/dots/voice/staff/mode, note properties, notation actions, linked-part/concert view, page/continuous layout, transport, tempo/loop/metronome, part mix and piano keys use SwiftUI controls. The center remains the interactive bundled OSMD engraving surface. Compact hosts use the shared outline/inspector sheets; the entry strip and piano scroll horizontally. Engraved note buttons support pointer, accessibility click, Enter and Space activation. Native List row containers expose their actual selection Button as an accessibility child with an explicit label and identifier.

`ScoreEditorView` 向公共原生工作台提供列表、谱面工具栏、属性和底部播放／键盘面板。乐器、谱表、小节、输入状态、音符属性、记号操作、关联分谱、实音、排版和播放设置均使用 SwiftUI。中央保留 OSMD 谱面与音符点击／拖动。紧凑界面通过公共抽屉打开列表和属性，工具栏与键盘横向滚动。

All original 57 commands remain available through the shared native “All tools” menu and dynamic native parameter forms. Document edits use the original commands and original MusicXML/history; these panels introduce no second score store or audio session. `ScorePlaybackAdapter` and its owner-scoped stop callbacks are unchanged. This change does not connect or migrate the Main App's DAW state.

全部原有 57 条命令仍可从公共原生“全部工具”及动态参数表单调用。原件编辑仍走同一 MusicXML、修订和历史；面板没有另建乐谱或音频会话。`ScorePlaybackAdapter` 及其所属音频停止回调保持原合同。

## Music parent workspace

**Required App route:** `WorkbenchCenter.musicContext → MusicWorkbenchContextView → MusicWorkbenchView`; the existing personal-file `.music → MusicEditorView` route reaches that same workbench. Add a `score` editor choice beside the existing mixer/piano/drums/keyboard/DJ choices, expanding its editing area as needed. Do not add `.score` to `PersonalContentKind` or make an independent Space/Notes/result-card editor. External links open the parent `.music` project and select its Score view.

**正式入口：** 乐谱是现有音乐工作台内的编辑视图；个人文件仍为 `.music`，其他页面打开父音乐工程并选择乐谱视图。不得增加 Space／手记／结果卡中的独立乐谱工程。

The smallest host integration keeps the current two representations in one owned music workspace:

- `MusicProjectSession` retains the Score controller and a host-assigned child document ID under its fixed `Music/Notation` directory, with `HeavyEditorOwner.music(session.id)`. Complete Score `Document.json` content, including MusicXML, layout, archive resources and its notation history, remains the notation original. The music project owns lifecycle, library recency, return routes and project deletion. Active-view undo targets the corresponding existing history; it must not pretend the two stores already have one atomic revision.
- A host-owned link record pins the Score source revision/hash and any generated Music track/clip/note identities plus the target Music revision. `score.playback.compile` supplies performed events, tempo, meter and repeat routes directly. A deliberate “update arrangement” operation can apply generated tracks/clips through the existing `MusicProjectSession.apply(..., expectedRevision:)`; it must preserve unrelated tracks, instruments and effects and detect edits to previously generated material. Changing a view does not perform a conversion or overwrite either original.
- The App injects `ScorePlaybackAdapter` into its existing music owner/audio authority. MusicXML marks remain in MusicXML. Importing existing MIDI/notes into notation creates an explicit derived score; it must not silently replace an existing rich score. Complete music-project export includes the `Notation` original and link record as well as current Music repository/DJ files. Export freezes and checks both originals' revisions before publishing the package.

最小接线保留音乐工程中的完整 MusicXML 原件与既有音轨原件，通过宿主维护的版本／哈希及 ID 映射关联。乐谱更新编曲是明确的编辑操作，走既有事务；切换视图不执行转换。正式 App 使用音乐会话注入的播放桥，完整工程包必须包含记谱原件与关联记录。

Current source constraints: `MusicDocument` contains tempo/assets/tracks/mixer/automation, with no notation field. `MusicMIDINoteImport` intentionally imports only notes and tempo at PPQ 960 and currently supplies 4/4 signatures; it is unsuitable as a lossless MusicXML synchronization bridge. `MusicTempoMap` also has its own PPQ/tempo/meter limits. Keep any projection rounding or unsupported performance representation out of the MusicXML original. Do not put Score bytes into a generic audio asset path: the current asset library and waveform loader treat every non-MIDI asset as audio.

当前 `MusicDocument` 没有记谱字段，MIDI 导入也不是无损同步桥。派生数据的量化、表示范围或播放限制不得改写 MusicXML；现有素材库与波形加载把非 MIDI 素材视为音频，因此不能把乐谱直接混入该音频路径。

This is the required integration contract, not a claim that the formal App has already connected these paths. App owners implement the workbench/session, package export and audio bridge; Score owns the notation editor and its narrow adapter.

## Presentation contract

`configuration.nativeSnapshot(engine)` returns the following JSON DTO, surfaced as `controller.presentation`. It contains no original XML, archive bytes, history, host paths or authorization data.

| Field | Value |
| --- | --- |
| `schemaVersion`, `kind`, `title`, `revision` | `1`, `"score"`, title and current revision |
| `selection` | `part`, `measure`, primary `note` or null, selected `notes` IDs (first 512), full `count` |
| `parts[]` | Opaque `id`, `name`, `staves`, `measureCount`, `mix {solo,mute,volume}` |
| `measures[]` | Current part only: opaque `id`, printed `number`, 1-based `index`, `beats`, `beatType`, `notesCount` |
| `current` | Current part/measure IDs and index, name, meter/key/staves/clefs, current measure's `notes`, primary `note`, `marks` |
| `current.notes[]` | ID, MIDI `pitch` or null, `pitchName`, exact `onset`/`duration {n,d}` and display text, `type`, `dots`, string `voice`, numeric `staff`, `rest`, `grace`, `selected`, tuplet `actual`/`normal` |
| `current.marks[]` | Opaque `id`, `kind` (`direction` or `harmony`), user-facing `label` |
| `input` | `type`, `dots`, numeric `voice`, `staff`, central `octave`, `mode`, `rest` |
| `layout` | Existing document layout settings |
| `view` | Linked `part` or empty string for full score, `concert`, `keyboardVisible` |
| `playback` | Existing tempo, loop, metronome and part mix settings |
| `transport` | `playing`, seconds `position`, `duration`, Unix milliseconds `sampledAt`, `referenceTimbres` |
| `diagnostics[]` | First 100 existing diagnostics plus a 1-based `index` for `score.analyze.navigate` |

Empty/unbuilt projects return valid empty arrays and default input/playback/view state. Selection and controls refer to opaque IDs from this DTO. Replacing a score clears a stale linked-part view and clamps transient input staff to the new context. These changes do not alter document data.

Transport samples are derived from the existing playback response and monotonic elapsed time. The native `TimelineView` interpolates from `sampledAt`; engraving highlights continue in WebKit. While playing, the canvas sends a presentation-change notification at most once per second and on completion. The shared controller also refreshes presentation after every command.

## Hidden UI commands

The registry now contains 61 entries: the original 57 plus these four. All four descriptors have `access: "read"`, `sideEffecting: true`, `hidden: true`, `fields: []`. They are transient UI operations, excluded from the native tool menu and read-only query tool path. They do not change MusicXML, project revision or undo history. They accept no owner, token or path arguments.

| Command | Arguments | Result |
| --- | --- | --- |
| `score.ui.input` | Any subset of `type` (supported note type), `dots` 0–3, `voice` 1–64, `staff` 1–current staff count, `octave` 0–8, `mode` (`replace`, `append`, `insert`), `rest` bool | Updated transient input |
| `score.ui.select` | `note` ID and optional `extend` bool; or optional `part`/`measure` IDs and `staff` number | `{part,measure,note,selected}`; note click and native note/staff rows share this selection |
| `score.ui.view` | Any subset of `part` (valid part ID or `""`), `concert` bool, `keyboardVisible` bool | Updated transient view |
| `score.ui.transport` | None | Current derived transport clock; does not invoke audio |

Actual note entry uses `score.edit.insert`. Partial native duration/voice/staff changes use `score.edit.update` without sending a pitch, so editing a selected chord does not collapse its tones. Native layout/mix/playback controls send current settings plus the chosen change, preserving unrelated settings. Forms use `controller.showCommand`; edits use `controller.runCommand`, keeping execution service-owned.

## Focused verification

```sh
node FloeAgent/Modules/FloeScoreKit/Tests/run-native-panels.mjs <task-evidence-directory>
node FloeAgent/Qualification/HeavyEditors/WebBuild/build.mjs score
```

The focused test runs the actual dispatcher, MusicXML and timing compiler. Its 17 checks cover empty presentation, piano/staff/measure IDs, staff-row selection, real SVG click/Enter/Space activation and gesture deduplication, correct MusicXML identity/reference diagnostics, transient state/history isolation, real dotted-note entry, full chord selection, partial properties and D4/F#4/A4 compiled events, view state, real mix/mark data, invalid IDs/staff, audio-free transport status, all original commands, and new-score context synchronization. The representative DTO is about 3.4 KB. Node checks and bundle generation do not establish native Swift compilation or visible native UI acceptance; the integration owner performs those separately. Previous notation/format/native-audio evidence is retained and was not rerun for this UI batch.
