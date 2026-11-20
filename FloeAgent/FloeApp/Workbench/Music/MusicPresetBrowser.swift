// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore
import FloeMusicNative
import UniformTypeIdentifiers

enum MusicInstrumentPresentation {
    static func name(_ patch: MusicPluginState?) -> String {
        guard let patch else { return WorkbenchText.t("尚未选择音色", "No preset selected") }
        guard patch.pluginID == MusicNativeBuiltins.synth else {
            return WorkbenchText.t("其他乐器", "Other instrument")
        }
        if let name = patch.timbreName { return name }
        return MusicPresetCatalog.preset(index: patch.presetIndex)?.displayName(isChinese: WorkbenchText.isChinese)
            ?? WorkbenchText.t("未知音色", "Unknown preset") + " #\(patch.presetIndex)"
    }
    static func isEditable(_ patch: MusicPluginState?) -> Bool {
        guard let patch, patch.pluginID == MusicNativeBuiltins.synth else { return false }
        return MusicPresetCatalog.preset(index: patch.presetIndex) != nil
    }
}

/// Both the keyboard and the asset library use this catalog. Browsing and
/// auditioning leave the project untouched; Apply is one store transaction.
struct MusicPresetBrowser: View {
    @Bindable var session: MusicProjectSession
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var category: MusicPresetCategory?

    @State private var draft: TimbreDraft?
    @State private var importing = false
    @State private var importTarget: TimbreTarget?
    private var target: TimbreTarget? {
        guard let track = session.currentTrack, track.kind == .midi else { return nil }
        return TimbreTarget(trackID: track.id, revision: session.document.revision)
    }

    private var canApply: Bool {
        session.currentTrack?.kind == .midi && !session.saving && !session.isRecording && !session.isMIDIRecording
    }
    private var presets: [MusicInstrumentPreset] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return MusicPresetCatalog.all.filter { preset in
            (category == nil || preset.category == category) && (text.isEmpty
                || preset.nameEN.localizedCaseInsensitiveContains(text)
                || preset.nameZH.localizedCaseInsensitiveContains(text)
                || preset.category.displayName(isChinese: WorkbenchText.isChinese).localizedCaseInsensitiveContains(text))
        }
    }
    var body: some View {
        List {
            Section(WorkbenchText.t("应用到", "Apply to")) {
                targetPicker
                if session.currentTrack?.kind == .midi {
                    LabeledContent(WorkbenchText.t("当前音色", "Current preset"),
                        value: MusicInstrumentPresentation.name(session.currentTrack?.instrument))
                } else {
                    Text(WorkbenchText.t("选择或添加乐器轨，再应用音色。", "Select or add an instrument track to apply a preset."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section(WorkbenchText.t("自定义音色", "Custom timbres")) {
                Button(WorkbenchText.t("设计音色", "Design timbre"), systemImage: "slider.horizontal.3") {
                    guard let target else { return }
                    let patch = session.currentTrack?.instrument
                    let base = MusicInstrumentPresentation.isEditable(patch) ? patch : nil
                    draft = TimbreDraft(target: target, name: base?.timbreName ?? WorkbenchText.t("我的音色", "My timbre"),
                                        index: base?.presetIndex ?? 0, parameters: base?.parameters ?? [:])
                }
                Button(WorkbenchText.t("导入音色文件", "Import timbre file"), systemImage: "square.and.arrow.down") {
                    importTarget = target
                    importing = true
                }
                ForEach(session.document.timbres.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }, id: \.name) { timbre in
                    Button {
                        guard let target else { return }
                        draft = TimbreDraft(target: target, name: timbre.name, index: timbre.presetIndex, parameters: timbre.parameters)
                    } label: {
                        Label(timbre.name, systemImage: "waveform")
                    }
                    .swipeActions {
                        Button(WorkbenchText.t("从音色库删除", "Remove from library"), role: .destructive) {
                            session.edit([.removeTimbre(timbre.name)])
                        }
                    }
                }
            }.disabled(!canApply)
            Section {
                Picker(WorkbenchText.t("分类", "Category"), selection: $category) {
                    Text(WorkbenchText.t("全部音色", "All presets")).tag(Optional<MusicPresetCategory>.none)
                    ForEach(MusicPresetCategory.allCases, id: \.self) { value in
                        Text(value.displayName(isChinese: WorkbenchText.isChinese)).tag(Optional(value))
                    }
                }.accessibilityIdentifier("music.presets.category")
                ForEach(presets) { preset in presetRow(preset) }
                if presets.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            } header: {
                HStack { Text(WorkbenchText.t("合成音色", "Synthesized presets")); Spacer(); Text("\(presets.count)") }
            } footer: {
                Text(WorkbenchText.t("试听不会更改工程。应用音色后自动保存，可撤销。", "Auditioning does not change the project. Applying a preset saves automatically and can be undone."))
            }
            MusicActionNotice(diagnostic: session.diagnostic)
        }
        .navigationTitle(WorkbenchText.t("音色库", "Preset library"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: WorkbenchText.t("搜索音色", "Search presets"))
        .accessibilityIdentifier("music.presets")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result, let target = importTarget else {
                if case .failure(let error) = result, (error as NSError).code != NSUserCancelledError {
                    session.diagnostic = error.localizedDescription
                }
                return
            }
            Task {
                do {
                    let patch = try await Task.detached(priority: .userInitiated) { try TimbreFile.read(from: url) }.value
                    guard session.selectedTrack == target.trackID else { return }
                    draft = TimbreDraft(target: target, name: patch.name, index: patch.presetIndex, parameters: patch.parameters)
                } catch {
                    session.diagnostic = WorkbenchText.t("无法读取音色，请选择导出的音色 JSON 文件。", "Choose a valid exported timbre JSON file.")
                }
            }
        }
        .sheet(item: $draft) { item in MusicTimbreEditor(session: session, draft: item) }
        .onDisappear { session.stopPresetPreview() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.stopPresetPreview() } }
    }
    private var targetPicker: some View {
        Menu {
            ForEach(session.document.tracks.filter { $0.kind == .midi }) { track in
                Button { session.selectTrack(track.id) } label: {
                    if session.selectedTrack == track.id { Label(track.name, systemImage: "checkmark") }
                    else { Text(track.name) }
                }
            }
            Divider()
            Button(WorkbenchText.t("添加乐器轨", "Add instrument track"), systemImage: "plus") {
                Task { await session.addTrack() }
            }
        } label: {
            Label(session.currentTrack.flatMap { $0.kind == .midi ? $0.name : nil } ?? WorkbenchText.t("选择乐器轨", "Select instrument track"),
                systemImage: "pianokeys").frame(minHeight: 44)
        }
        .disabled(session.saving || session.isRecording || session.isMIDIRecording)
        .accessibilityIdentifier("music.presets.target")
    }
    private func presetRow(_ preset: MusicInstrumentPreset) -> some View {
        let patch = session.currentTrack?.instrument
        let selected = patch?.pluginID == MusicNativeBuiltins.synth && patch?.presetIndex == preset.index && patch?.timbreName == nil && patch?.parameters.isEmpty == true
        let previewing = session.previewPresetIndex == preset.index
        return HStack(spacing: 8) {
            Button {
                guard let track = session.currentTrack, track.kind == .midi else { return }
                let revision = session.document.revision
                Task {
                    do {
                        try await session.applyPreset(index: preset.index, trackID: track.id, expectedRevision: revision)
                        session.diagnostic = nil
                    } catch { session.diagnostic = error.localizedDescription }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "pianokeys")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preset.displayName(isChinese: WorkbenchText.isChinese)).foregroundStyle(.primary)
                        Text(preset.category.displayName(isChinese: WorkbenchText.isChinese)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
            }.disabled(!canApply).accessibilityIdentifier("music.preset.apply.\(preset.index)")
                .accessibilityValue(selected ? WorkbenchText.t("当前音色", "Current preset") : "")
            Button {
                if previewing { session.stopPresetPreview() } else { session.previewPreset(preset.index) }
            } label: {
                Image(systemName: previewing ? "stop.fill" : "play.fill").frame(width: 44, height: 44)
            }
            .disabled(session.saving || session.isRendering || session.isRecording || session.isMIDIRecording)
            .accessibilityLabel((previewing ? WorkbenchText.t("停止试听", "Stop audition") : WorkbenchText.t("试听", "Audition"))
                + " " + preset.displayName(isChinese: WorkbenchText.isChinese))
            .accessibilityIdentifier("music.preset.preview.\(preset.index)")
        }.buttonStyle(.borderless)
    }
}

struct MusicPresetPickerButton: View {
    @Bindable var session: MusicProjectSession
    @State private var presented = false
    var body: some View {
        Button { presented = true } label: {
            Label(WorkbenchText.t("音色库", "Presets"), systemImage: "pianokeys").frame(minHeight: 44)
        }
        .accessibilityIdentifier("music.presets.open")
        .sheet(isPresented: $presented) {
            MusicPresetBrowserSheet(session: session)
        }
    }
}

private struct MusicPresetBrowserSheet: View {
    let session: MusicProjectSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            MusicPresetBrowser(session: session)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { dismiss() } } }
        }.presentationDetents([.large])
    }
}

struct MusicActionNotice: View {
    let diagnostic: String?
    var body: some View {
        if let diagnostic {
            Section {
                Label(WorkbenchText.t("操作未完成", "Action unfinished"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                DisclosureGroup(WorkbenchText.t("详情", "Details")) { Text(diagnostic).textSelection(.enabled) }
            }
        }
    }
}
private struct TimbreTarget {
    let trackID: MusicTrackID
    let revision: Int64
}

private struct TimbreDraft: Identifiable {
    let id = UUID()
    let target: TimbreTarget
    var name: String
    let index: Int
    var parameters: [String: Double]
}

private struct TimbreFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let timbre: MusicTimbre

    nonisolated static func read(from url: URL) throws -> MusicTimbre {
        let scope = url.startAccessingSecurityScopedResource()
        defer { if scope { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        while bytes.count <= MusicTimbre.maximumFileBytes {
            let next = try handle.read(upToCount: MusicTimbre.maximumFileBytes + 1 - bytes.count)
            guard let next, !next.isEmpty else { return try JSONDecoder().decode(MusicTimbre.self, from: bytes) }
            bytes.append(next)
        }
        throw CocoaError(.fileReadTooLarge)
    }

    init(_ timbre: MusicTimbre) { self.timbre = timbre }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= MusicTimbre.maximumFileBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        timbre = try JSONDecoder().decode(MusicTimbre.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(timbre))
    }
}

private struct MusicTimbreEditor: View {
    @Bindable var session: MusicProjectSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: TimbreDraft
    @State private var exportFile: TimbreFile?
    @State private var exporting = false
    @State private var waveformURL: URL?
    @State private var saving = false
    @State private var errorMessage: String?

    init(session: MusicProjectSession, draft: TimbreDraft) {
        self.session = session
        _draft = State(initialValue: draft)
    }

    private var base: [String: Double] { MusicPresetCatalog.preset(index: draft.index)?.parameters ?? [:] }
    private var waveform: Int { Int(value("waveform", fallback: 0)) }
    private func value(_ key: String, fallback: Double) -> Double {
        draft.parameters[key] ?? base[key] ?? fallback
    }
    private func timbre() throws -> MusicTimbre {
        try MusicTimbre(name: draft.name, presetIndex: draft.index, parameters: draft.parameters)
    }
    private func slider(_ label: String, _ key: String, range: ClosedRange<Double>, fallback: Double = 0) -> some View {
        let current = value(key, fallback: fallback)
        // Imported envelopes can be longer than the usual editing range.
        let bounds = min(range.lowerBound, current)...max(range.upperBound, current)
        return VStack(alignment: .leading) {
            LabeledContent(label) { Text(current.formatted(.number.precision(.fractionLength(0...3)))).monospacedDigit() }
            Slider(value: Binding(get: { value(key, fallback: fallback) }, set: { draft.parameters[key] = $0 }), in: bounds)
                .accessibilityLabel(label)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(WorkbenchText.t("音色名称", "Timbre name"), text: $draft.name)
                    if waveform != 8 {
                        Picker(WorkbenchText.t("波形", "Waveform"), selection: Binding(get: { waveform }, set: { draft.parameters["waveform"] = Double($0) })) {
                            let names = WorkbenchText.isChinese ? ["正弦", "锯齿", "三角", "方波", "脉冲", "泛音", "调频", "噪声"] :
                                ["Sine", "Saw", "Triangle", "Square", "Pulse", "Harmonics", "FM", "Noise"]
                            ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
                        }
                    }
                    if waveform == 4 { slider(WorkbenchText.t("脉宽", "Pulse width"), "pulseWidth", range: 0.05...0.95, fallback: 0.25) }
                    if waveform == 6 {
                        slider(WorkbenchText.t("调频比", "FM ratio"), "fmRatio", range: 0.1...16, fallback: 2)
                        slider(WorkbenchText.t("调制指数", "FM index"), "fmIndex", range: 0...12, fallback: 1)
                    }
                    if waveform == 5 {
                        DisclosureGroup(WorkbenchText.t("泛音", "Harmonics")) {
                            ForEach(2...8, id: \.self) { n in slider("\(n)", "harmonic\(n)", range: 0...1) }
                        }
                    }
                    if waveform != 8 { slider(WorkbenchText.t("低通频率 (Hz)", "Low-pass frequency (Hz)"), "lowpass", range: 20...20_000, fallback: 20_000) }
                }
                Section(WorkbenchText.t("音量包络", "Amplitude envelope")) {
                    slider(WorkbenchText.t("起音 (秒)", "Attack (s)"), "attack", range: 0...4)
                    slider(WorkbenchText.t("衰减 (秒)", "Decay (s)"), "decay", range: 0...4)
                    slider(WorkbenchText.t("延音", "Sustain"), "sustain", range: 0...1)
                    slider(WorkbenchText.t("释音 (秒)", "Release (s)"), "release", range: 0...6)
                    slider(WorkbenchText.t("音量", "Gain"), "gain", range: 0...1, fallback: 1)
                }
                Section {
                    Button(session.previewPresetIndex == nil ? WorkbenchText.t("试听", "Audition") : WorkbenchText.t("停止试听", "Stop audition"),
                           systemImage: session.previewPresetIndex == nil ? "speaker.wave.2" : "stop.fill") {
                        if session.previewPresetIndex != nil { session.stopPresetPreview() }
                        else { session.previewPreset(draft.index, parameters: draft.parameters) }
                    }
                    Button(WorkbenchText.t("生成音色波形图", "Render timbre waveform"), systemImage: "waveform") {
                        Task {
                            do {
                                let patch = try timbre()
                                let url = try await session.renderAndWait(.waveform(patch.instrument()))
                                if try timbre() == patch { waveformURL = url }
                            }
                            catch { errorMessage = message(error) }
                        }
                    }.disabled(session.isRendering)
                    if let waveformURL {
                        MusicWaveformPreview(file: waveformURL)
                        ShareLink(item: waveformURL) { Label(WorkbenchText.t("分享波形 PNG", "Share waveform PNG"), systemImage: "square.and.arrow.up") }
                    }
                    Button(WorkbenchText.t("导出音色文件", "Export timbre file"), systemImage: "square.and.arrow.up") {
                        do { exportFile = try TimbreFile(timbre()); exporting = true }
                        catch { errorMessage = message(error) }
                    }
                }
                MusicActionNotice(diagnostic: errorMessage ?? session.diagnostic)
            }
            .onChange(of: draft.parameters) { waveformURL = nil }
            .onChange(of: draft.name) { waveformURL = nil }
            .navigationTitle(WorkbenchText.t("设计音色", "Design timbre"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(WorkbenchText.t("取消", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkbenchText.t("保存并应用", "Save and apply")) {
                        saving = true
                        Task { @MainActor in
                            defer { saving = false }
                            do {
                                let design = try timbre()
                                try await session.apply([.saveTimbre(design), .setInstrument(draft.target.trackID, try design.instrument())],
                                                        expectedRevision: draft.target.revision)
                                dismiss()
                            } catch { errorMessage = message(error) }
                        }
                    }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .disabled(saving)
        }
        .interactiveDismissDisabled(saving)
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json, defaultFilename: "timbre") { result in
            if case .failure(let error) = result { errorMessage = message(error) }
        }
        .onDisappear { session.stopPresetPreview() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.stopPresetPreview() } }
    }
    private func message(_ error: Error) -> String {
        if case MusicError.staleRevision = error {
            return WorkbenchText.t("工程已更改，请重新打开音色编辑器。", "The project changed. Reopen the timbre editor.")
        }
        return (error as? MusicError)?.description ?? error.localizedDescription
    }
}
#endif
