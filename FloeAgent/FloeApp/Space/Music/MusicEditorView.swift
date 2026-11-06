// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import FloeMusicCore
import FloeMusicKeyboard

struct MusicEditorView: View {
    @Bindable var session: MusicProjectSession
    @State private var importing = false
    @State private var editor: ClipEditorRequest?
    @State private var keyboardExpanded = true
    @State private var bpm = 120.0
    private struct ClipEditorRequest: Identifiable {
        var id: MusicClipID { clip.id }
        var clip: MusicClip
        var revision: Int64
    }
    var body: some View {
        VStack(spacing: 0) {
            transport.padding(.horizontal).padding(.vertical, 8)
            Divider()
            List {
                Section {
                    HStack {
                        Text(IDELanguageRunText.t("速度", "Tempo"))
                        TextField("BPM", value: $bpm, format: .number)
                            .keyboardType(.decimalPad).frame(maxWidth: 100)
                        Button(IDELanguageRunText.t("应用", "Apply")) {
                            Task {
                                do { try await session.apply([.setTempo(atTick: .init(0), bpm: bpm, beatsPerBar: 4, beatUnit: 4)]) }
                                catch { session.diagnostic = error.localizedDescription }
                            }
                        }
                    }
                }
                Section(IDELanguageRunText.t("音轨与片段", "Tracks and clips")) {
                    if session.document.tracks.isEmpty {
                        ContentUnavailableView(IDELanguageRunText.t("开始一段音乐", "Start a piece"),
                            systemImage: "music.note", description: Text(IDELanguageRunText.t("添加乐器轨、弹奏录制，或导入音频与 MIDI。", "Add an instrument, record a performance, or import audio and MIDI.")))
                    }
                    ForEach(session.document.tracks) { track in
                        trackRow(track)
                    }
                    Button(IDELanguageRunText.t("添加乐器轨", "Add instrument track"), systemImage: "plus") {
                        Task { await session.addTrack() }
                    }.accessibilityIdentifier("music.addTrack")
                    Button(IDELanguageRunText.t("导入音频或 MIDI", "Import audio or MIDI"), systemImage: "square.and.arrow.down") { importing = true }
                        .accessibilityIdentifier("music.import")
                }
                if let file = session.exportedFile {
                    Section(IDELanguageRunText.t("已保存的混音", "Saved mix")) {
                        ShareLink(item: file) { Label(IDELanguageRunText.t("导出文件", "Export file"), systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("music.export")
                    }
                }
                if let diagnostic = session.diagnostic {
                    Section {
                        Label(IDELanguageRunText.t("操作未完成", "Unable to finish"), systemImage: "exclamationmark.triangle")
                        DisclosureGroup(IDELanguageRunText.t("详情", "Details")) { Text(diagnostic).textSelection(.enabled) }
                    }
                }
            }
            if keyboardExpanded {
                Divider()
                ElectronicKeyboardPanel(controller: session.keyboard, configuration: .init(keyCount: 25),
                    toneSurface: .init(presets: [
                        .init(id: "0", displayName: IDELanguageRunText.t("纯音", "Pure tone")),
                        .init(id: "1", displayName: IDELanguageRunText.t("锯齿波", "Sawtooth"))
                    ], selectedPresetID: Binding(get: { session.preset }, set: { session.changePreset($0) })))
                    .frame(height: 250).padding(.horizontal)
                    .disabled(!session.isLive)
            }
        }
        .onAppear { bpm = session.document.tempoMap.segments.first?.bpm ?? 120 }
        .onDisappear {
            session.stopLive()
            session.stopPlayback()
            if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            session.stopLive(); session.stopPlayback()
            if session.isRecording { Task { await session.stopMicrophone() } }
            if session.isMIDIRecording { Task { await session.stopMIDIRecording() } }
        }
        .sheet(item: $editor) { request in
            MusicClipEditor(session: session, draft: request.clip, revision: request.revision)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, UTType(filenameExtension: "mid") ?? .data]) { result in
            switch result {
            case .success(let url): Task { await session.importFile(url) }
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
    }
    private var transport: some View {
        ViewThatFits(in: .horizontal) {
            HStack { transportButtons }
            VStack(alignment: .leading) { transportButtons }
        }
    }
    @ViewBuilder private var transportButtons: some View {
        Button(session.isPlaying ? IDELanguageRunText.t("停止", "Stop") : IDELanguageRunText.t("播放", "Play"),
               systemImage: session.isPlaying ? "stop.fill" : "play.fill") {
            if session.isPlaying { session.stopPlayback() } else { session.render(asMP3: false, play: true) }
        }.disabled(session.isRendering || session.isRecording)
        Button(session.isLive ? IDELanguageRunText.t("关闭琴声", "Mute keyboard") : IDELanguageRunText.t("启用琴声", "Enable keyboard"),
               systemImage: "pianokeys") {
            if session.isLive { session.stopLive() } else { session.startLive() }
        }.disabled(session.isRecording)
        Button(session.isMIDIRecording ? IDELanguageRunText.t("结束演奏录制", "Finish performance") : IDELanguageRunText.t("录制演奏", "Record performance"),
               systemImage: session.isMIDIRecording ? "stop.circle" : "record.circle") {
            if session.isMIDIRecording { Task { await session.stopMIDIRecording() } } else { session.startMIDIRecording() }
        }.disabled(session.isRecording)
        Menu {
            Button(session.isRecording ? IDELanguageRunText.t("结束麦克风录音", "Finish microphone recording") : IDELanguageRunText.t("麦克风录音", "Record microphone")) {
                Task { if session.isRecording { await session.stopMicrophone() } else { await session.startMicrophone() } }
            }
            Button(IDELanguageRunText.t("导出 WAV", "Export WAV")) { session.render(asMP3: false) }
            Button(IDELanguageRunText.t("导出 MP3", "Export MP3")) { session.render(asMP3: true) }
            Button(IDELanguageRunText.t("撤销", "Undo")) { Task { await session.undo() } }
            Button(IDELanguageRunText.t("重做", "Redo")) { Task { await session.undo(redo: true) } }
            Toggle(IDELanguageRunText.t("显示键盘", "Show keyboard"), isOn: $keyboardExpanded)
        } label: { Label(IDELanguageRunText.t("更多", "More"), systemImage: "ellipsis.circle") }
        if session.isRendering {
            ProgressView()
            Button(IDELanguageRunText.t("取消导出", "Cancel export")) { session.cancelRender() }
        }
    }
    private func trackRow(_ track: FloeMusicCore.MusicTrack) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { session.selectedTrack = track.id } label: {
                    Label(track.name, systemImage: track.kind == .midi ? "pianokeys" : "waveform")
                        .font(.headline)
                }
                Spacer()
                Toggle(IDELanguageRunText.t("静音", "Mute"), isOn: Binding(get: { track.strip.muted }, set: { value in
                    var strip = track.strip; strip.muted = value
                    Task { do { try await session.apply([.setStrip(track.id, strip)]) } catch { session.diagnostic = error.localizedDescription } }
                })).toggleStyle(.button)
                Toggle(IDELanguageRunText.t("独奏", "Solo"), isOn: Binding(get: { track.strip.soloed }, set: { value in
                    var strip = track.strip; strip.soloed = value
                    Task { do { try await session.apply([.setStrip(track.id, strip)]) } catch { session.diagnostic = error.localizedDescription } }
                })).toggleStyle(.button)
            }
            if track.kind == .midi {
                Button(IDELanguageRunText.t("添加 MIDI 片段", "Add MIDI clip"), systemImage: "plus.rectangle") {
                    Task {
                        do {
                            let clip = try await session.addMIDIClip(to: track.id)
                            editor = .init(clip: clip, revision: session.document.revision)
                        } catch { session.diagnostic = error.localizedDescription }
                    }
                }.accessibilityIdentifier("music.addMIDIClip")
            }
            ForEach(track.clips) { clip in
                Button { editor = .init(clip: clip, revision: session.document.revision) } label: {
                    HStack {
                        Image(systemName: track.kind == .midi ? "music.note.list" : "waveform")
                        Text(clip.name.isEmpty ? IDELanguageRunText.t("片段", "Clip") : clip.name)
                        Spacer()
                        Text("\(Double(clip.offset.value) / Double(session.document.tempoMap.sampleRate), format: .number.precision(.fractionLength(2))) s")
                            .font(.caption.monospacedDigit())
                    }.padding(10).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityIdentifier("music.clip." + clip.id.rawValue)
            }
        }.padding(.vertical, 8)
    }
}

private struct MusicClipEditor: View {
    let session: MusicProjectSession
    @State var draft: MusicClip
    let revision: Int64
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField(IDELanguageRunText.t("名称", "Name"), text: $draft.name)
                TextField(IDELanguageRunText.t("开始采样位置", "Start sample"), value: Binding(
                    get: { draft.offset.value }, set: { draft.offset = .init($0) }), format: .number)
                switch draft.body {
                case .audio(let audio):
                    TextField(IDELanguageRunText.t("长度（采样）", "Length (samples)"), value: Binding(
                        get: { audio.durationSamples }, set: { var next = audio; next.durationSamples = $0; draft.body = .audio(next) }), format: .number)
                    TextField(IDELanguageRunText.t("素材起点（采样）", "Source start (samples)"), value: Binding(
                        get: { audio.trimStartSamples }, set: { var next = audio; next.trimStartSamples = $0; draft.body = .audio(next) }), format: .number)
                case .midi(let midi):
                    TextField(IDELanguageRunText.t("长度（tick）", "Length (ticks)"), value: Binding(
                        get: { midi.durationTicks }, set: { var next = midi; next.durationTicks = $0; draft.body = .midi(next) }), format: .number)
                    ForEach(Array(midi.notes.enumerated()), id: \.element.id) { index, note in
                        HStack {
                            ForEach([IDELanguageRunText.t("音高", "Pitch"), IDELanguageRunText.t("起点", "Start"),
                                     IDELanguageRunText.t("时长", "Duration"), IDELanguageRunText.t("力度", "Velocity")], id: \.self) { title in
                                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            Color.clear.frame(width: 28, height: 1).accessibilityHidden(true)
                        }.font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField(IDELanguageRunText.t("音高", "Pitch"), value: noteBinding(note.id, keyPath: \.pitch, fallback: note.pitch), format: .number)
                                .accessibilityLabel(IDELanguageRunText.t("音高", "Pitch"))
                            TextField(IDELanguageRunText.t("起点", "Start"), value: tickBinding(note.id), format: .number)
                                .accessibilityLabel(IDELanguageRunText.t("起点（tick）", "Start (ticks)"))
                            TextField(IDELanguageRunText.t("时长", "Duration"), value: noteBinding(note.id, keyPath: \.durationTicks, fallback: note.durationTicks), format: .number)
                                .accessibilityLabel(IDELanguageRunText.t("时长（tick）", "Duration (ticks)"))
                            TextField(IDELanguageRunText.t("力度", "Velocity"), value: noteBinding(note.id, keyPath: \.velocity, fallback: note.velocity), format: .number)
                                .accessibilityLabel(IDELanguageRunText.t("力度", "Velocity"))
                            Button(role: .destructive) {
                                var next = midi; next.notes.remove(at: index); draft.body = .midi(next)
                            } label: { Image(systemName: "minus.circle") }
                        }.accessibilityElement(children: .contain)
                    }
                    Button(IDELanguageRunText.t("添加音符", "Add note")) {
                        do {
                            var next = midi
                            next.notes.append(try .init(pitch: 60, startTick: .init(0), durationTicks: min(960, midi.durationTicks), velocity: 100))
                            draft.body = .midi(next)
                        } catch { self.error = error.localizedDescription }
                    }
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button(IDELanguageRunText.t("删除片段", "Delete clip"), role: .destructive) {
                    Task { do { try await session.apply([.removeClip(draft.id)], expectedRevision: revision); dismiss() } catch { self.error = error.localizedDescription } }
                }
            }
            .navigationTitle(IDELanguageRunText.t("编辑片段", "Edit clip"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("保存", "Save")) {
                        Task { do { try await session.apply([.updateClip(draft)], expectedRevision: revision); dismiss() } catch { self.error = error.localizedDescription } }
                    }
                }
            }
        }
    }
    private func noteBinding<T>(_ id: String, keyPath: WritableKeyPath<MusicMIDINote, T>, fallback: T) -> Binding<T> {
        Binding(get: {
            guard case .midi(let midi) = draft.body, let note = midi.notes.first(where: { $0.id == id }) else { return fallback }
            return note[keyPath: keyPath]
        }, set: { value in
            guard case .midi(var midi) = draft.body, let index = midi.notes.firstIndex(where: { $0.id == id }) else { return }
            midi.notes[index][keyPath: keyPath] = value; draft.body = .midi(midi)
        })
    }
    private func tickBinding(_ id: String) -> Binding<Int64> {
        Binding(get: {
            guard case .midi(let midi) = draft.body else { return 0 }
            return midi.notes.first(where: { $0.id == id })?.startTick.value ?? 0
        }, set: { value in
            guard case .midi(var midi) = draft.body, let index = midi.notes.firstIndex(where: { $0.id == id }) else { return }
            midi.notes[index].startTick = .init(value); draft.body = .midi(midi)
        })
    }
}
#endif
