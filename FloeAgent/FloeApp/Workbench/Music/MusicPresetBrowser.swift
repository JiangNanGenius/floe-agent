// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeMusicCore
import FloeMusicNative

enum MusicInstrumentPresentation {
    static func name(_ patch: MusicPluginState?) -> String {
        guard let patch else { return WorkbenchText.t("尚未选择音色", "No preset selected") }
        guard patch.pluginID == MusicNativeBuiltins.synth else {
            return WorkbenchText.t("其他乐器", "Other instrument")
        }
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
        let selected = patch?.pluginID == MusicNativeBuiltins.synth && patch?.presetIndex == preset.index
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
#endif
