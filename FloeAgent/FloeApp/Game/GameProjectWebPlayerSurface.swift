// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGameWebKit
import FloeGameTouch
import FloeGameTouchUI
import FloeGameDeveloperUI

/// Native presentation only. Closing an inspector never ends the run. Every
/// final exit passes through the service's input/save/owned-request stop path.
@MainActor
struct GameProjectWebPlayerSurface: View {
    @Bindable var presentation: GameProjectWebRunPresentation
    let title: String
    let onClosed: @MainActor (GameProjectWebRunPresentation.StopReceipt) -> Void
    @ObservedObject private var player: GameWebPlayer
    @Environment(\.scenePhase) private var scenePhase
    @State private var panel: Panel?
    @State private var closeIntent: CloseIntent?

    private enum Panel: Equatable { case controls, saves, developer }
    private enum CloseIntent { case panel(Panel?), playback(GameProjectWebRunPresentation.StopReceipt) }
    private var wantsInput: Bool { scenePhase == .active && panel == nil && !presentation.editingLayout }

    init(presentation: GameProjectWebRunPresentation, title: String,
         onClosed: @escaping @MainActor (GameProjectWebRunPresentation.StopReceipt) -> Void) {
        self.presentation = presentation; self.title = title; self.onClosed = onClosed
        _player = ObservedObject(wrappedValue: presentation.player)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                viewport
                GameWebInputStatus(service: presentation.input)
                if let error = presentation.controlsError {
                    Text(error).font(.callout).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .accessibilityIdentifier("game.play.controls.error")
                }
                if let receipt = presentation.stopReceipt, !receipt.closeAcknowledged {
                    Text(copy("未能确认运行已关闭，请查看运行记录。", "The game close was not confirmed. Check its run record."))
                        .font(.callout).foregroundStyle(.red).padding(10)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { playToolbar }
            .inspector(isPresented: inspectorPresented) {
                inspector.inspectorColumnWidth(min: 340, ideal: 390, max: 520)
            }
            .confirmationDialog(copy("保存键位修改？", "Save control changes?"),
                isPresented: Binding(get: { closeIntent != nil }, set: { if !$0 { closeIntent = nil } }),
                titleVisibility: .visible) {
                    Button(copy("保存修改", "Save changes")) {
                        let intent = closeIntent
                        Task {
                            if await presentation.saveControls() { finishClose(intent) }
                        }
                    }
                    Button(copy("放弃键位修改", "Discard control changes"), role: .destructive) {
                        let intent = closeIntent
                        Task { await presentation.discardControlChanges(); finishClose(intent) }
                    }
                    Button(copy("取消", "Cancel"), role: .cancel) { closeIntent = nil }
                }
        }
        .interactiveDismissDisabled()
        .onAppear { presentation.requestInputEnabled(wantsInput) }
        .onChange(of: scenePhase) { _, _ in refreshInput() }
        .onChange(of: player.loaded) { _, _ in refreshInput() }
        .onChange(of: player.gameReady) { _, _ in refreshInput() }
        .onChange(of: panel) { _, _ in refreshInput() }
        .onChange(of: presentation.editingLayout) { _, _ in refreshInput() }
        .onChange(of: presentation.draftProfile) { _, profile in
            guard !presentation.editingLayout else { return }
            Task { await presentation.previewControls(profile) }
        }
        .onDisappear {
            // A covering panel suspends input. The run service retains the
            // player and saves until its explicit, request-specific stop.
            presentation.requestInputEnabled(false)
        }
    }

    private var viewport: some View {
        ZStack {
            Color.black
            GamePlayerView(player: player, arrangingControls: presentation.editingLayout)
                .allowsHitTesting(!presentation.editingLayout)
            GameTouchControlsView(service: presentation.input, editingLayout: presentation.editingLayout,
                layoutProfile: presentation.draftProfile,
                onMove: { id, anchor in presentation.moveControl(id, to: anchor) },
                onFinishLayout: {
                    Task {
                        if await presentation.saveControls() { presentation.editingLayout = false }
                    }
                })
                .allowsHitTesting(!presentation.stopping && !presentation.stopped)
            if !player.loaded && !presentation.stopped {
                ProgressView(copy("正在启动", "Starting"))
                    .padding(16).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityIdentifier("game.play.viewport")
    }

    @ToolbarContentBuilder private var playToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                Task {
                    let receipt = await presentation.stop()
                    if presentation.hasControlChanges { closeIntent = .playback(receipt) }
                    else { onClosed(receipt) }
                }
            } label: {
                Label(presentation.stopped ? copy("完成", "Done") : copy("停止", "Stop"),
                    systemImage: presentation.stopped ? "checkmark" : "stop.fill")
                    .frame(minWidth: 44, minHeight: 44)
            }.disabled(presentation.stopping).accessibilityIdentifier("game.play.stop")
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { choosePanel(.controls) } label: {
                Label(copy("键位", "Controls"), systemImage: "keyboard")
                    .frame(minWidth: 44, minHeight: 44)
            }.accessibilityIdentifier("game.play.controls")
            Button { choosePanel(.saves) } label: {
                Label(copy("存档", "Saves"), systemImage: "internaldrive")
                    .frame(minWidth: 44, minHeight: 44)
            }.disabled(presentation.stopped).accessibilityIdentifier("game.play.saves")
            Button { choosePanel(.developer) } label: {
                Label(copy("调试／作弊", "Debug / cheats"), systemImage: "slider.horizontal.3")
                    .frame(minWidth: 44, minHeight: 44)
            }.disabled(presentation.stopped).accessibilityIdentifier("game.play.developer")
        }
    }

    private var inspectorPresented: Binding<Bool> {
        .init(get: { panel != nil }, set: { value in if !value { requestClosePanel() } })
    }

    @ViewBuilder private var inspector: some View {
        NavigationStack {
            Group {
                switch panel {
                case .controls:
                    controlsPanel
                case .saves:
                    GameSaveManagerView(session: presentation.saves, showsTitle: false)
                        .navigationTitle(copy("存档", "Saves"))
                case .developer:
                    GameDeveloperMenuPanel(session: presentation.developer,
                        locale: .automatic)
                        .navigationTitle(copy("调试／作弊", "Debug / cheats"))
                case nil: EmptyView()
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(copy("关闭", "Close")) { requestClosePanel() }
            } }
        }
    }

    private var controlsPanel: some View {
        VStack(spacing: 0) {
            if let diagnostic = presentation.inputDiagnostic {
                Text(diagnostic).font(.callout).foregroundStyle(.secondary).padding(10)
            }
            if presentation.keyboardCandidates.count > 1 {
                Menu {
                    ForEach(presentation.keyboardCandidates) { source in
                        Button(source.name) { Task { await presentation.useKeyboardSource(source.id) } }
                    }
                } label: { Label(copy("使用工程键位方案", "Use a project key map"), systemImage: "keyboard.badge.ellipsis") }
                    .padding(.horizontal, 12).frame(minHeight: 44)
            }
            GameTouchSettingsView(profile: $presentation.draftProfile, editingLayout: $presentation.editingLayout,
                saving: presentation.savingControls, defaults: presentation.defaultProfile,
                onArrange: { panel = nil }, onSave: { _ in Task { _ = await presentation.saveControls() } })
        }
    }

    private func choosePanel(_ next: Panel) {
        let destination = panel == next ? nil : next
        if panel == .controls, destination != .controls, presentation.hasControlChanges {
            // Keep the draft visible until the explicit close decision is made.
            closeIntent = .panel(destination)
        } else { panel = destination }
    }
    private func requestClosePanel() {
        if panel == .controls, presentation.hasControlChanges { closeIntent = .panel(nil) }
        else { panel = nil }
    }
    private func finishClose(_ intent: CloseIntent?) {
        closeIntent = nil
        switch intent {
        case .panel(let next): panel = next
        case .playback(let receipt): onClosed(receipt)
        case nil: break
        }
    }
    private func refreshInput() { presentation.requestInputEnabled(wantsInput) }
    private func copy(_ zh: String, _ en: String) -> String { FloeL10n.bilingual(chinese: zh, english: en) }
}

private struct GameWebInputStatus: View {
    @ObservedObject var service: GameTouchInputService
    var body: some View {
        if service.lastError != nil {
            Text(FloeL10n.l("game.play.controls_disconnected"))
                .font(.callout).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .accessibilityIdentifier("game.play.input.error")
        }
    }
}
#endif
