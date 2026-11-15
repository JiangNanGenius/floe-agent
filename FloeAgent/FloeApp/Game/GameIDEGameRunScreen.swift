// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGameCore
import FloeGameIDEBridge
import FloeGameProjectSelectionUI

@MainActor
struct GameIDEGameRunRequest: Identifiable {
    let id = UUID()
    let session: GameWorkspaceSession
    let extensionOverride: IDEProjectRunExtension?
    let saveAllSurfaces: @MainActor () async -> Bool
}

/// Feature-local presentation over the existing IDE. It owns no files or Git.
/// Selection, resource preparation and the actual player share the same session.
struct GameIDEGameRunScreen: View {
    let request: GameIDEGameRunRequest
    let registry: GameWorkspaceRegistry
    @Environment(\.dismiss) private var dismiss
    @State private var launchTask: Task<Void, Never>?
    @State private var started = false
    @State private var closing = false
    @State private var error: String?

    var body: some View {
        Group {
            if started {
                GameProjectPlayScreen(session: request.session)
            } else {
                NavigationStack {
                    VStack(spacing: 0) {
                        if let error {
                            Text(error).font(.callout).foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                .accessibilityIdentifier("game.ide.run.error")
                        }
                        if let snapshot = request.session.project.selectionSnapshot,
                           snapshot.requiresExplicitChoice {
                            GameProjectSelectionPicker(snapshot: snapshot) { root, engine in
                                begin(selection: (root, engine))
                            }
                            .disabled(launchTask != nil)
                        } else if launchTask != nil {
                            Spacer()
                            ProgressView(copy("正在准备试玩", "Preparing play"))
                            Spacer()
                        } else {
                            ContentUnavailableView {
                                Label(copy("准备游戏", "Prepare game"), systemImage: "gamecontroller")
                            } description: {
                                Text(copy("确认工程和运行资源后即可试玩。", "Confirm the project and runtime resources to play."))
                            } actions: {
                                Button(copy("重试运行", "Retry run")) { begin() }
                                    .buttonStyle(.borderedProminent)
                                    .accessibilityIdentifier("game.ide.run.retry")
                                if let engine = request.session.project.selectionSnapshot?.selectedEngine {
                                    Button(copy("准备运行资源", "Prepare runtime resources")) {
                                        prepareResources(engine)
                                    }
                                }
                            }
                        }
                    }
                    .navigationTitle(copy("运行游戏", "Run game"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(copy("关闭", "Close")) { Task { await close() } }
                                .disabled(closing)
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled(true)
        .task {
            guard !started, launchTask == nil else { return }
            if request.session.project.selectionSnapshot?.requiresExplicitChoice != true { begin() }
        }
    }

    private func copy(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }

    private func begin(selection: (GameRelativePath?, GameEngineID)? = nil) {
        guard launchTask == nil, !closing else { return }
        error = nil
        launchTask = Task { @MainActor in
            defer { launchTask = nil }
            do {
                if let selection {
                    try await request.session.project.select(root: selection.0, engine: selection.1)
                }
                try Task.checkCancellation()
                // Make a fresh extension after the user resolves the root. A
                // prior extension may have captured a different root/revision.
                let value = selection == nil ? request.extensionOverride : nil
                let executable: IDEProjectRunExtension
                if let value { executable = value }
                else { executable = try await registry.makeRunExtension(for: request.session) }
                try await executable.run(request.saveAllSurfaces)
                try Task.checkCancellation()
                guard !closing else { return }
                started = true
            } catch is CancellationError {
                return
            } catch {
                // Failed starts can retain an owned handle when Stop did not
                // acknowledge. Keep this screen and its Close/retry available.
                self.error = error.localizedDescription
            }
        }
    }

    private func prepareResources(_ engine: GameEngineID) {
        guard launchTask == nil, !closing else { return }
        launchTask = Task { @MainActor in
            defer { launchTask = nil }
            do { try await registry.prepareRuntimeResource(for: engine, session: request.session) }
            catch is CancellationError { return }
            catch { self.error = error.localizedDescription }
        }
    }

    private func close() async {
        guard !closing else { return }
        closing = true
        if let launchTask {
            launchTask.cancel()
            // The registry owns the child launch task and its concrete job.
            // Fence/cancel it before waiting on this view's caller task.
            await registry.stopPlay(request.session)
            await launchTask.value
        }
        let play = registry.playCoordinator(for: request.session)
        let receipt = await play.stop()
        guard receipt.stopConfirmed == true || (receipt.runID == nil && !play.isRunning) else {
            closing = false
            error = copy("尚未确认游戏停止，请重试关闭。", "The game has not confirmed stopping. Retry Close.")
            return
        }
        dismiss()
    }
}
#endif
