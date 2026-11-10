// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeHeavyEditorSupport
import FloeMusicCore

@MainActor struct MusicNotationPerformanceControls: View {
    let parent: MusicProjectSession
    @Bindable var notation: MusicNotationSession
    let controller: HeavyEditorController
    let onAdded: () -> Void
    @State private var showsSounds = false
    @State private var failure: String?
    @State private var visible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button { showsSounds = true } label: {
                    Label(WorkbenchText.t("演奏音色", "Performance sounds"), systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .disabled(notation.arrangement.isBusy)
                .accessibilityIdentifier("music.notation.sounds")
                Spacer(minLength: 8)
                if notation.arrangement.isBusy {
                    ProgressView(value: notation.arrangement.progress)
                        .frame(maxWidth: 120)
                        .accessibilityLabel(WorkbenchText.t("正在生成演奏音频", "Rendering performed audio"))
                    Button(WorkbenchText.t("取消", "Cancel"), role: .cancel) { notation.arrangement.cancel() }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("music.notation.arrange.cancel")
                } else {
                    Button(action: perform) {
                        Label(WorkbenchText.t("演奏并加入编曲", "Perform & add"), systemImage: "waveform.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .disabled(!controller.isReady || controller.isWorking || parent.saving || parent.notationRestoring)
                    .accessibilityIdentifier("music.notation.arrange")
                }
            }
            if let url = notation.arrangement.recoverableWAV {
                HStack(alignment: .firstTextBaseline) {
                    Text(notation.arrangement.message ?? WorkbenchText.t("演奏音频已保留。", "The performed audio is kept."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    ShareLink(item: url) { Label(WorkbenchText.t("保留的音频", "Kept audio"), systemImage: "waveform") }
                }
            } else if let message = notation.arrangement.message ?? failure {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(notation.arrangement.isBusy
                     ? WorkbenchText.t("正在生成音频，完成后以新音轨加入。", "Rendering audio to add as a new track.")
                     : WorkbenchText.t("使用各声部的音色，在当前播放头位置加入新音轨。", "Use each part's sound and add a new track at the playhead."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .onAppear { visible = true }
        .onDisappear { visible = false } // The service retains its own render.
        .sheet(isPresented: $showsSounds) { NavigationStack { sounds } }
    }
    private func perform() {
        let revision = controller.document.revision, musicRevision = parent.document.revision
        failure = nil
        Task { @MainActor in
            do {
                let result = try await controller.execute("score.playback.arrange",
                    arguments: .object(["musicRevision": .number(Double(musicRevision))]), expectedRevision: revision)
                guard visible, parent.notation === notation, notation.controller === controller,
                      let operation = result["result"]["operationID"].string.flatMap(UUID.init(uuidString:)),
                      notation.arrangement.lastReceipt?.operationID == operation else { return }
                onAdded()
            } catch is CancellationError {} catch {
                guard visible else { return }
                failure = notation.arrangement.message ?? error.localizedDescription
            }
        }
    }

    @ViewBuilder private var sounds: some View {
        MusicNotationSoundPicker(controller: controller)
            .navigationTitle(WorkbenchText.t("演奏音色", "Performance sounds"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { showsSounds = false } } }
    }
}

@MainActor private struct MusicNotationSoundPicker: View {
    let controller: HeavyEditorController
    @State private var parts: [Part] = []
    @State private var failure: String?
    private struct Part: Identifiable {
        let id: String
        let name: String
        let preset: Int?
        let defaultPreset: Int
    }
    var body: some View {
        List {
            Section {
                ForEach(parts) { part in
                    HStack(alignment: .firstTextBaseline) {
                        Text(part.name)
                        Spacer(minLength: 8)
                        Menu {
                            Button(WorkbenchText.t("跟随乐器", "Instrument default")) { select(part, preset: -1) }
                            ForEach(MusicPresetCategory.allCases, id: \.self) { category in
                                Menu(category.displayName(isChinese: IDELanguageRunText.isChinese)) {
                                    ForEach(MusicPresetCatalog.all.filter { $0.category == category }) { preset in
                                        Button { select(part, preset: preset.index) } label: {
                                            if part.preset == preset.index { Label(preset.displayName(isChinese: IDELanguageRunText.isChinese), systemImage: "checkmark") }
                                            else { Text(preset.displayName(isChinese: IDELanguageRunText.isChinese)) }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(MusicPresetCatalog.preset(index: part.preset ?? part.defaultPreset)?.displayName(isChinese: IDELanguageRunText.isChinese)
                                 ?? WorkbenchText.t("跟随乐器", "Instrument default"))
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("music.notation.sound." + part.id)
                    }
                }
            } footer: {
                Text(WorkbenchText.t("音色保存在此乐谱中，普通播放和加入编曲使用相同音色。内置音色为合成音色。", "Sounds are saved in this score and used for both playback and arrangement audio. Built-in sounds are synthesized."))
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if parts.isEmpty && failure == nil { ProgressView(WorkbenchText.t("正在读取声部…", "Loading parts…")) }
        }
        .task(id: controller.document.revision) { await refresh() }
    }
    private func refresh() async {
        do {
            let result = try await controller.execute("score.playback.compile", expectedRevision: controller.document.revision)
            let compiled = result["result"]
            let rows = compiled["parts"].array
            parts = rows.compactMap { row in
                guard let id = row["id"].string, let name = row["name"].string else { return nil }
                let program = Int(row["program"].number ?? 0), percussion = row["percussion"].bool ?? false
                return Part(id: id, name: name, preset: row["nativePreset"].number.map(Int.init),
                    defaultPreset: MusicNotationPerformance.presetIndex(program: program, percussion: percussion))
            }
            failure = nil
        } catch is CancellationError {} catch { failure = error.localizedDescription }
    }
    private func select(_ part: Part, preset: Int) {
        let revision = controller.document.revision
        Task { @MainActor in
            do {
                _ = try await controller.execute("score.playback.timbre", arguments: .object(["part": .string(part.id), "preset": .number(Double(preset))]), expectedRevision: revision)
                await refresh()
            } catch is CancellationError {} catch { failure = error.localizedDescription }
        }
    }
}
#endif
