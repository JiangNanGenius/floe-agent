// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeGameCore
import FloeGameIDEBridge
import FloeGameProjectSelectionUI

struct ChatGamePlayLink: Identifiable {
    let conversationID: UUID
    let projectID: UUID
    var id: String { "\(conversationID)/\(projectID)" }

    static func receipt(from payload: String) -> UUID? {
        struct Result: Decodable {
            let tool: String
            let status: String
            let summary: String
            let workspaceID: UUID?
        }
        struct Game: Decodable {
            let projectID: UUID
            let hasFiles: Bool
        }
        let decoder = JSONDecoder()
        guard let result = try? decoder.decode(Result.self, from: Data(payload.utf8)),
              result.tool == "game.create", result.status == "ok",
              let game = try? decoder.decode(Game.self, from: Data(result.summary.utf8)),
              game.hasFiles, result.workspaceID == nil || result.workspaceID == game.projectID else { return nil }
        return game.projectID
    }
}

struct ChatGamePlayScreen: View {
    let link: ChatGamePlayLink
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var request: GameIDEGameRunRequest?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let request {
                GameIDEGameRunScreen(request: request, registry: environment.gameWorkspaces)
            } else {
                NavigationStack {
                    Group {
                        if let error {
                            ContentUnavailableView {
                                Label(IDELanguageRunText.t("无法打开游戏", "Couldn’t open game"), systemImage: "gamecontroller")
                            } description: { Text(error) } actions: {
                                Button("action.retry") { attempt += 1 }
                            }
                        } else { ProgressView() }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("action.close") { dismiss() } }
                    }
                }
            }
        }
        .task(id: attempt) {
            error = nil
            do {
                let center = WorkspaceCenter(environment: environment, publishesSharedState: false)
                try await center.openTaskWorkspace(conversationID: link.conversationID)
                guard center.currentWorkspace?.id == link.projectID, let root = center.currentRootURL,
                      let session = try await environment.gameWorkspaces.restoreChatGame(
                        conversationID: link.conversationID, workspaceID: link.projectID, leasedRoot: root, openedCenter: center) else {
                    throw GameWorkspaceRegistryError.ownerNotAvailable
                }
                try await session.project.refresh()
                try Task.checkCancellation()
                request = GameIDEGameRunRequest(session: session, extensionOverride: nil, saveAllSurfaces: { true })
            } catch is CancellationError {
                return
            } catch { self.error = error.localizedDescription }
        }
    }
}

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
                        } else if let snapshot = request.session.project.selectionSnapshot,
                                  snapshot.runSelection == nil {
                            // Unresolved, empty or a manual/unverified choice.
                            // Never auto-launch arbitrary files and never
                            // substitute the recorded creation hint.
                            ContentUnavailableView {
                                Label(copy("还不能试玩", "Not ready to play"),
                                      systemImage: "gamecontroller")
                            } description: {
                                Text(snapshot.isManualUnverified
                                    ? copy("当前引擎是手动选择，没有识别依据。请在工程设置中确认识别到的引擎后再试玩。",
                                           "The engine is a manual choice without recognized evidence. Confirm a recognized engine in project setup before playing.")
                                    : copy("还没有确认可运行的游戏目录和引擎。请在工程设置中选择或导入后再试玩。",
                                           "No runnable game folder and engine are confirmed. Choose or import one in project setup before playing."))
                            } actions: {
                                Button(copy("返回工程设置", "Back to project setup")) {
                                    Task { await close() }
                                }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("game.ide.run.backToSetup")
                            }
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
            if request.session.visualPresentation != nil {
                started = true
                return
            }
            guard let snapshot = request.session.project.selectionSnapshot else { return }
            if !snapshot.requiresExplicitChoice, snapshot.runSelection != nil { begin() }
        }
    }

    private func copy(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }

    private func begin(selection: (GameRelativePath?, GameEngineID)? = nil) {
        guard launchTask == nil, !closing else { return }
        guard selection != nil
                || request.session.project.selectionSnapshot?.runSelection != nil else {
            error = copy("请先在工程设置中确认游戏目录和引擎。",
                         "Confirm a game folder and engine in project setup first.")
            return
        }
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
