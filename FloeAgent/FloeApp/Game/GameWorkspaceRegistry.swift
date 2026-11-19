// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import CryptoKit
import FloeCore
import FloeModels
import FloePersistence
import FloeWorkspace
import FloeExecution
import FloeEnvironments
import FloeTools
import FloeGameAppIntegration
import FloeGameCore
import FloeGameAuthoring
import FloeGameBuildKit
import FloeGameEditingCore
import FloeGameIDEBridge
import FloeGamePortableKit
import FloeGameRuntime
import FloeGameRunKit
import FloeGameStarterKit
import FloeGameProjectFlow
import FloeGameProjectIntegration
import FloeGameWorkspaceHost
import FloeGameExecutionBridge
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeGameRGSSHostLinux

/// Scene-independent navigation for an IDE request produced by the game host.
/// It is a presentation request only; no file permission is carried.
@MainActor @Observable
final class GameIDENavigationCenter {
    var request: GameIDEOpenRequest?
    @ObservationIgnored var handler: ((GameIDEOpenRequest) -> Void)?
    func present(_ request: GameIDEOpenRequest) {
        self.request = request
        handler?(request)
    }
}

/// Stable identity for one live App-owned game project. The owner and root are
/// part of the key so a chat workspace and a Space record can never share a
/// file/edit session even when their UUIDs were copied.
struct GameWorkspaceKey: Hashable, Sendable {
    let projectID: UUID
    let owner: GameProjectOwner
    let rootPath: String

    init(projectID: UUID, owner: GameProjectOwner, rootURL: URL) {
        self.projectID = projectID
        self.owner = owner
        self.rootPath = Self.canonical(rootURL)
    }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

enum GameWorkspaceRegistryError: Error, Equatable, LocalizedError {
    case wrongProjectOwner
    case notGameRecord
    case notGameProject
    case assistantHasRuns
    case conversationBindingChanged
    case environmentRootMismatch
    case noSavedRun
    case runBindingMissing
    case runEnvironmentMismatch
    case runWorkspaceMismatch
    case editorBusy
    case engineChangeNeedsNewProject
    case copyDestinationInvalid
    case conversationNotWritable
    case ownerNotAvailable
    case ownerResolutionRequired
    case ambiguousGameProject
    case launchInProgress
    case stopUnconfirmed
    /// The game still owns a build, export or run-time CI job whose stop was
    /// not confirmed. The session and its leases are retained.
    case workStopUnconfirmed(String)

    var errorDescription: String? {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .wrongProjectOwner:
            return zh ? "这个游戏工程不属于当前作品。" : "This game project does not belong to the current work."
        case .notGameRecord, .notGameProject:
            return zh ? "这个作品不是游戏工程。" : "This work is not a game project."
        case .assistantHasRuns:
            return zh ? "该项目助手已有历史运行，不能静默更换运行位置。请新建一次游戏会话。" : "This assistant already has runs. Its execution location cannot be changed silently."
        case .conversationBindingChanged:
            return zh ? "项目助手绑定已改变，请重新打开游戏。" : "The project assistant binding changed. Reopen the game."
        case .environmentRootMismatch:
            return zh ? "所选环境的工作区不是这个游戏工程。请为本工程准备运行环境。" : "The selected environment belongs to another workspace. Prepare an environment for this game."
        case .noSavedRun:
            return zh ? "还没有可用于构建/运行的真实任务。先在游戏助手中发起一次任务，或打开项目助手。" : "No real saved task can be used. Start the project assistant task first."
        case .runBindingMissing:
            return zh ? "该任务的执行位置尚未绑定，请先在任务中确认运行位置。" : "The task has no execution binding. Confirm its location in the task first."
        case .runEnvironmentMismatch:
            return zh ? "任务使用的环境与当前游戏工程不一致。请重新确认任务运行位置。" : "The task environment no longer matches this game. Confirm its location again."
        case .runWorkspaceMismatch:
            return zh ? "任务环境映射的工作区与当前游戏工程根不一致。" : "The task's environment workspace does not match this game root."
        case .editorBusy:
            return zh ? "请先保存或处理当前编辑草稿/冲突。" : "Save or resolve the current draft/conflict first."
        case .engineChangeNeedsNewProject:
            return zh ? "切换引擎会创建新的转换工程；原工程保持不变。" : "Changing the engine creates a new conversion project; the original is unchanged."
        case .copyDestinationInvalid:
            return zh ? "目标副本已改变或不可用，请另存为新项目。" : "The destination copy changed or is unavailable. Save as a new project."
        case .conversationNotWritable:
            return zh ? "临时对话或非普通任务不能拥有游戏运行记录；请使用普通任务。" : "A temporary or non-ordinary conversation cannot own a game run. Use an ordinary task."
        case .ownerNotAvailable:
            return zh ? "所选任务不属于这个 IDE 工作区，不能借用其他聊天的运行位置。" : "The selected task does not own this IDE workspace; another chat's run location cannot be borrowed."
        case .ownerResolutionRequired:
            return zh ? "这个 IDE 工作区有多个聊天任务。请从拥有游戏的聊天打开，或传入实际 conversation id。" : "This IDE workspace has several chat tasks. Open the game from its owning task, or pass the actual conversation id."
        case .ambiguousGameProject:
            return zh ? "这个 IDE 根包含多个游戏工程/引擎，请先在游戏概览中选择工程根。" : "This IDE root contains more than one game project or engine. Choose the game root first."
        case .launchInProgress:
            return zh ? "另一个游戏启动仍在进行，请等待停止/完成后再启动。" : "Another game launch is still starting. Wait for it to finish or stop before launching again."
        case .stopUnconfirmed:
            return zh ? "上一个游戏运行未确认停止。请先重试停止，再启动新的运行。" : "The previous game run did not acknowledge stop. Retry Stop before launching another run."
        case .workStopUnconfirmed(let detail):
            let suffix = detail.isEmpty ? "" : "\n" + detail
            return (zh ? "游戏的构建/导出仍未确认停止。请重试关闭；完成前不会释放项目或运行环境。"
                       : "The game build/export has not confirmed stopping. Retry Close; the project and runtime environment stay owned until it does.") + suffix
        }
    }
}

/// One live project shared by overview, quick edit, IDE, AI tools and play.
/// It owns no file tree of its own: the project session and its repository are
/// created by Root's `GameWorkspaceProjectSession` over the existing IDE
/// workspace and the existing `FileGameProjectRepository`.
@MainActor @Observable
final class GameWorkspaceSession {
    let key: GameWorkspaceKey
    let record: PersonalContentRecord?
    let center: WorkspaceCenter
    let paths: SpaceGameOriginal.Location?
    let support: URL
    let history: URL
    let transfer: GameProjectTransferService
    private(set) var project: GameWorkspaceProjectSession
    private(set) var environmentID: String?
    private(set) var execution: GameWorkspaceExecutionSession?
    private(set) var rgssHost: RGSSAppHost?
    private(set) var executionConversationID: UUID?
    private(set) var closed = false
    /// Set before the first await of close(), so no new launch/build can start
    /// while an owned operation is still draining.
    private(set) var closing = false
    private(set) var closeFailure: String?
    private(set) var visualSession: GameEditingSession?
    private(set) var rgssPlay: RGSSGuestPlaySession?
    private(set) var webPresentation: GameProjectWebRunPresentation?
    private(set) var lastLaunchRequest: GameIDEProjectRunRequest?
    private(set) var lastStopReceipt: GameRunReceipt?
    private(set) var lastRGSSStop: RGSSGuestStopOutcome?
    var stopTask: Task<Void, Never>?
    private(set) var play: GamePlayCoordinator?
    private(set) var launchGate = GameLaunchSerialGate()
    private(set) var launchTask: Task<Void, Error>?
    @ObservationIgnored private var libraryUse: PersonalLibraryUsageLease?

    init(key: GameWorkspaceKey, record: PersonalContentRecord?, center: WorkspaceCenter,
         project: GameWorkspaceProjectSession, paths: SpaceGameOriginal.Location?,
         support: URL, history: URL, transfer: GameProjectTransferService,
         libraryUse: PersonalLibraryUsageLease? = nil) {
        self.key = key
        self.record = record
        self.center = center
        self.project = project
        self.paths = paths
        self.support = support
        self.history = history
        self.transfer = transfer
        self.libraryUse = libraryUse
    }

    var context: GameProjectContext {
        get throws { try project.context }
    }

    var selection: GameProjectSelectionSnapshot? { project.selectionSnapshot }
    var isSpace: Bool { record != nil }

    /// The actual live visual surface, if it is really running. Root's play
    /// screen can observe this directly; a pointer assigned before start does
    /// not satisfy it.
    var visualPresentation: GameWorkspaceVisualPresentation? {
        if let webPresentation, webPresentation.controller.phase == .running {
            return .web(webPresentation)
        }
        if let rgssPlay, rgssPlay.phase == .running {
            return .rgss(rgssPlay)
        }
        return nil
    }

    func attachVisual(_ session: GameEditingSession?) throws {
        try project.attachVisual(session)
        visualSession = session
    }

    /// Explicit close result. The project, library lease and source companion
    /// selection stay owned until every local task and remote job drained.
    @discardableResult
    func close() async -> GameWorkspaceCloseOutcome {
        guard !closed else { return .confirmed }
        if !closing {
            if let visualSession, visualSession.isBusy || visualSession.isDirty ||
                visualSession.pendingDraft != nil || visualSession.conflict != nil ||
                !visualSession.fileConflicts.isEmpty {
                return .unconfirmed(ids: ["editor"],
                    detail: "Save or resolve the open editor draft/conflict first.")
            }
            closing = true
        }
        // A launch in flight must not publish into a closing project. Cancel
        // the launch token/task and wait for its own cleanup before stopping
        // the retained live handle.
        if let launchTask {
            launchTask.cancel()
            let drained = await waitForDrain { self.launchTask == launchTask }
            guard drained else {
                let detail = "The game run preparation did not drain after cancellation."
                closeFailure = detail
                return .unconfirmed(ids: ["run:\(key.projectID.uuidString.lowercased())"],
                                    detail: detail)
            }
            self.launchTask = nil
        }
        launchGate.cancel()
        if let stopTask {
            let drained = await waitForDrain { self.stopTask == stopTask }
            guard drained else {
                let detail = "The previous game stop did not drain."
                closeFailure = detail
                return .unconfirmed(ids: ["run:\(key.projectID.uuidString.lowercased())"],
                                    detail: detail)
            }
            self.stopTask = nil
        }
        // Root's RGSS presenter owns the actual job/input capture. Prepare it
        // before a direct Registry/session close so held keys and the captured
        // sink are released without resolving a newer game.
        if let play {
            await play.rgssPresentation?.prepareForStop()
        }
        // A failing stop retains the owned guest job/scope instead of closing
        // the project underneath a process that may still write.
        if let rgssPlay {
            let outcome = await rgssPlay.stop()
            lastRGSSStop = outcome
            if outcome.status == .stopUnconfirmed {
                let detail = "The RGSS run did not confirm stopping."
                closeFailure = detail
                return .unconfirmed(ids: ["rgss:\(outcome.status.rawValue)"], detail: detail)
            }
            self.rgssPlay = nil
        }
        // Web stop performs the real automatic save, input release and owned
        // request cleanup; closing the execution session alone is not enough.
        if let webPresentation {
            let receipt = await webPresentation.stop()
            if !receipt.closeAcknowledged {
                lastStopReceipt = GameRunReceipt(projectID: key.projectID,
                    runID: webPresentation.request.id, action: "stop",
                    phase: "stopUnconfirmed", stopConfirmed: false,
                    automaticSave: String(describing: receipt.automaticSave),
                    screenshotSHA256: nil, logs: nil,
                    diagnostic: receipt.inputFailed ? "Input release failed." : nil)
                let detail = receipt.inputFailed
                    ? "The Web run's input release failed."
                    : "The Web run did not confirm stopping."
                closeFailure = detail
                return .unconfirmed(ids: ["web:\(webPresentation.request.id.uuidString.lowercased())"],
                                    detail: detail)
            }
            self.webPresentation = nil
        }
        if let execution {
            let outcome = await execution.close()
            guard outcome.isConfirmed else {
                closeFailure = outcome.detail
                return outcome
            }
            self.execution = nil
        }
        closed = true
        closing = false
        closeFailure = nil
        visualSession = nil
        play = nil
        rgssHost = nil
        await project.close()
        if isSpace { center.closeCurrentWorkspace() }
        libraryUse?.release()
        libraryUse = nil
        return .confirmed
    }

    /// Launch and stop owners clear their handles after their own cleanup.
    /// Waiting on an unstructured task's value inside a task group can keep
    /// the group alive even after its timeout child has returned.
    private func waitForDrain(while isPending: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while isPending() {
            guard clock.now < deadline, !Task.isCancelled else { return false }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return false }
        }
        return true
    }

    func replaceProject(_ value: GameWorkspaceProjectSession) { project = value }
    func setWebPresentation(_ value: GameProjectWebRunPresentation?) { webPresentation = value }
    func setLastLaunchRequest(_ value: GameIDEProjectRunRequest?) { lastLaunchRequest = value }
    func setLastStopReceipt(_ value: GameRunReceipt?) { lastStopReceipt = value }
    func setLastRGSSStop(_ value: RGSSGuestStopOutcome?) { lastRGSSStop = value }
    func setRGSSPlay(_ value: RGSSGuestPlaySession?) { rgssPlay = value }
    func setPlay(_ value: GamePlayCoordinator?) { play = value }
    func setEnvironmentID(_ value: String?) { environmentID = value }
    func setExecution(_ value: GameWorkspaceExecutionSession?) { execution = value }
    func setRGSSHost(_ value: RGSSAppHost?) { rgssHost = value }
    func setExecutionConversation(_ value: UUID?) { executionConversationID = value }
    func beginLaunch() throws -> UInt64 { try launchGate.begin() }
    func launchIsCurrent(_ token: UInt64) -> Bool { launchGate.isCurrent(token) }
    func finishLaunch(_ token: UInt64) { launchGate.finish(token) }
    func cancelLaunch() { launchGate.cancel() }
    func setLaunchTask(_ value: Task<Void, Error>?) { launchTask = value }
}

/// The actual running visual surface for one game session. It is derived from
/// the live Web controller/RGSS session, never from a planned or catalog route.
@MainActor
enum GameWorkspaceVisualPresentation {
    case web(GameProjectWebRunPresentation)
    case rgss(RGSSGuestPlaySession)

    var isReady: Bool {
        switch self {
        case .web(let value): return value.controller.phase == .running
        case .rgss(let value): return value.phase == .running
        }
    }
}

/// App-owned registry. It is the single place that materializes the existing
/// workspace/repository binding for a Space record or an ordinary chat
/// workspace, and the single place that constructs execution/play objects.
/// Views and AI tools ask this registry; neither creates its own tracker.
@MainActor @Observable
final class GameWorkspaceRegistry {
    let environment: AppEnvironment
    let navigation = GameIDENavigationCenter()
    let library: GameEngineLibrary?
    let enginePacks: GameEnginePackStore?
    let runtimeResources: GameRuntimeResourceRegistry
    /// Per-owner exact source-companion selections. Views install/remove them;
    /// in-flight builds hold their own provider/use count.
    let sourceCompanions = GameSourceCompanionStore()
    var instrumentation: any GameInstrumentationConsuming = GameInstrumentationUnavailable()
    private let copyLinks: GameProjectCopyLinkStore?
    private var sessions: [GameWorkspaceKey: GameWorkspaceSession] = [:]
    private var opening: [GameWorkspaceKey: Task<GameWorkspaceSession, Error>] = [:]
    private let bindingStore: TaskExecutionBindingStore
    private let selectionStoreDirectory: URL
    private let supportRoot: URL

    /// `runtimeResourceBundleRoot` is a qualification/development injection
    /// point only. Production leaves it nil so the App never ships the 77 MB
    /// reviewed pack tree; users acquire only the selected engine's pack.
    init(environment: AppEnvironment, runtimeResourceBundleRoot: URL? = nil) {
        self.environment = environment
        self.bindingStore = TaskExecutionBindingStore(database: environment.database)
        self.library = try? GameEngineLibrary.bundled()
        let packs = try? GameEnginePackStore(directory: Self.enginePackDirectory())
        self.enginePacks = packs
        self.runtimeResources = GameRuntimeResourceRegistry(
            bundledRoot: runtimeResourceBundleRoot,
            enginePackRoot: Self.enginePackDirectory(), packStore: packs)
        self.supportRoot = Self.supportRoot()
        self.selectionStoreDirectory = supportRoot.appendingPathComponent("Selection", isDirectory: true)
        self.copyLinks = try? GameProjectCopyLinkStore()
        try? FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        self.instrumentation = GameInstrumentationAdapter(registry: self)
        let resources = self.runtimeResources
        Task { await resources.refresh() }
    }

    // MARK: - Opening

    func openSpaceGame(record: PersonalContentRecord) async throws -> GameWorkspaceSession {
        try await openSpaceGameSession(record: record).session
    }

    func openSpaceGameSession(record: PersonalContentRecord) async throws
        -> (session: GameWorkspaceSession, reused: Bool) {
        guard record.kind == .game else { throw GameWorkspaceRegistryError.notGameRecord }
        let resolved = try await PersonalContentService.shared.library().resolve(record.id)
        let (paths, storedProject) = try await SpaceGameOriginal.read(id: record.id, directory: resolved.url)
        let key = GameWorkspaceKey(projectID: record.id,
                                   owner: .space(recordID: record.id), rootURL: paths.files)
        if let existing = sessions[key], !existing.closed {
            guard !existing.closing else {
                throw GameWorkspaceRegistryError.workStopUnconfirmed(
                    existing.closeFailure ?? "")
            }
            return (existing, true)
        }
        if let pending = opening[key] { return (try await pending.value, false) }
        let task = Task { @MainActor [environment] in
            let libraryUse = try PersonalLibraryFileActions.acquireUse(id: record.id,
                                                                       directory: resolved.url)
            var retainedUse = false
            defer { if !retainedUse { libraryUse.release() } }
            let workspaceRecord = try await self.ensureOwnedWorkspace(
                projectID: record.id, title: record.title, rootURL: paths.files)
            let center = WorkspaceCenter(environment: environment, publishesSharedState: false)
            try await center.openAppOwnedWorkspace(id: workspaceRecord.id)
            let environmentID: String?
            do {
                environmentID = try await self.existingEnvironmentID(for: record.id,
                    conversationID: nil, rootURL: paths.files, requireSession: true)
            } catch GameWorkspaceRegistryError.environmentRootMismatch {
                // An update can relocate the App container while a saved Linux
                // binding still points at its former path. Open the verified
                // library files without attaching that execution environment.
                environmentID = nil
            }
            let context = try GameProjectContext(projectID: record.id,
                owner: .space(recordID: record.id), rootURL: paths.files,
                savedRevision: storedProject.revision, environmentID: environmentID)
            let session = try await GameWorkspaceProjectSession.open(
                center: center, context: context, history: paths.history,
                support: paths.support, title: record.title,
                starterResources: self.starterResources())
            try await session.refresh(reloadFiles: false, allowRecognitionFailure: true)
            let transfer = try GameProjectTransferService(stagingDirectory: paths.transferJobs)
            let value = GameWorkspaceSession(key: key, record: record, center: center,
                project: session, paths: paths, support: paths.support, history: paths.history,
                transfer: transfer, libraryUse: libraryUse)
            value.setEnvironmentID(environmentID)
            if environmentID != nil {
                value.setExecutionConversation(try? await self.environment.studioCoordinator.access.get()
                    .assistant(projectID: record.id))
            }
            self.sessions[key] = value
            retainedUse = true
            return value
        }
        opening[key] = task
        do {
            let value = try await task.value
            opening[key] = nil
            return (value, false)
        } catch {
            opening[key] = nil
            throw error
        }
    }

    /// Adds game capability to an existing ordinary chat IDE workspace. The
    /// chat keeps its own center/owner; no Space record or hidden copy is made.
    func openChatGame(center: WorkspaceCenter, conversationID: UUID,
                      title: String) async throws -> GameWorkspaceSession {
        guard let workspace = center.currentWorkspace, let root = center.currentRootURL else {
            throw GameIDEBridgeError.workspaceChanged
        }
        let projectID = workspace.id
        let key = GameWorkspaceKey(projectID: projectID,
            owner: .conversation(conversationID: conversationID, workspaceID: workspace.id),
            rootURL: root)
        if let existing = sessions[key], !existing.closed {
            guard !existing.closing else {
                throw GameWorkspaceRegistryError.workStopUnconfirmed(
                    existing.closeFailure ?? "")
            }
            return existing
        }
        // Owner-bound repositories: two real conversations can share one IDE
        // workspace/root but must never share a FileGameProjectRepository or
        // history/CAS store. Namespace by the actual owner AND project.
        let history = chatGameHistory(conversationID: conversationID, workspaceID: workspace.id)
        let support = history.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let repository = try FileGameProjectRepository(directory: history)
        let revision: String
        do {
            revision = try await repository.open(projectID, owner: key.owner).revision
        } catch GameProjectError.projectNotFound(let missing) where missing == projectID {
            revision = UUID().uuidString.lowercased()
        }
        let conversation: UUID?
        if case .conversation(let id, _) = key.owner { conversation = id } else { conversation = nil }
        let environmentID = try await existingEnvironmentID(for: projectID,
            conversationID: conversation, rootURL: root)
        let context = try GameProjectContext(projectID: projectID, owner: key.owner,
            rootURL: root, savedRevision: revision, environmentID: environmentID)
        let session = try await GameWorkspaceProjectSession.open(center: center, context: context,
            history: history, support: support, title: title,
            starterResources: starterResources())
        try await session.refresh(reloadFiles: false, allowRecognitionFailure: true)
        let transfer = try GameProjectTransferService(
            stagingDirectory: support.appendingPathComponent("TransferJobs", isDirectory: true))
        let value = GameWorkspaceSession(key: key, record: nil, center: center, project: session,
            paths: nil, support: support, history: history, transfer: transfer)
        value.setEnvironmentID(environmentID)
        if environmentID != nil, case .conversation(let id, _) = key.owner {
            value.setExecutionConversation(id)
        }
        sessions[key] = value
        return value
    }

    /// Opens the conversation's own private task workspace in an isolated
    /// center and adopts its existing files as a game project. No Space record
    /// or copy is created; the ordinary chat IDE remains the owner.
    func openChatTaskGame(conversationID: UUID, title: String) async throws -> GameWorkspaceSession {
        let center = WorkspaceCenter(environment: environment, publishesSharedState: false)
        try await center.openTaskWorkspace(conversationID: conversationID)
        return try await openChatGame(center: center, conversationID: conversationID, title: title)
    }

    private func chatGameHistory(conversationID: UUID, workspaceID: UUID) -> URL {
        let workspace = workspaceID.uuidString.lowercased()
        let owner = "conversation-" + conversationID.uuidString.lowercased() + "-workspace-" + workspace
        return supportRoot.appendingPathComponent(owner + "/" + workspace + "/History", isDirectory: true)
    }

    func hasSavedChatGame(conversationID: UUID, workspaceID: UUID) -> Bool {
        let history = chatGameHistory(conversationID: conversationID, workspaceID: workspaceID)
        let head = history.appendingPathComponent(workspaceID.uuidString.lowercased() + "/HEAD.json")
        return FileManager.default.fileExists(atPath: head.path)
    }

    func restoreChatGame(conversationID: UUID, workspaceID: UUID, leasedRoot: URL?) async throws -> GameWorkspaceSession? {
        let owner = GameProjectOwner.conversation(conversationID: conversationID, workspaceID: workspaceID)
        if let existing = session(projectID: workspaceID, owner: owner) { return existing }
        guard let leasedRoot, hasSavedChatGame(conversationID: conversationID, workspaceID: workspaceID) else { return nil }
        let center = WorkspaceCenter(environment: environment, publishesSharedState: false)
        try await center.openTaskWorkspace(conversationID: conversationID)
        guard let workspace = center.currentWorkspace, workspace.id == workspaceID,
              let current = center.currentRootURL, Self.canonical(current) == Self.canonical(leasedRoot) else {
            throw GameIDEBridgeError.workspaceChanged
        }
        let key = GameWorkspaceKey(projectID: workspaceID, owner: owner, rootURL: current)
        if let pending = opening[key] { return try await pending.value }
        let task = Task { try await self.openChatGame(center: center, conversationID: conversationID, title: workspace.name) }
        opening[key] = task
        defer { opening[key] = nil }
        return try await task.value
    }

    func session(projectID: UUID, owner: GameProjectOwner) -> GameWorkspaceSession? {
        sessions.values.first {
            $0.key.projectID == projectID && $0.key.owner == owner
                && !$0.closed && !$0.closing
        }
    }

    func session(record: PersonalContentRecord) -> GameWorkspaceSession? {
        sessions.values.first {
            $0.record?.id == record.id && !$0.closed && !$0.closing
        }
    }

    /// Explicit close result propagated to callers and the library barrier.
    /// Source companions are retired only after a confirmed close; an
    /// unconfirmed build/CI keeps the selection and its in-flight use count.
    @discardableResult
    func close(_ session: GameWorkspaceSession) async -> GameWorkspaceCloseOutcome {
        let outcome = await session.close()
        if session.closed {
            sourceCompanions.retireAll(projectID: session.key.projectID,
                                       owner: session.key.owner)
            sessions.removeValue(forKey: session.key)
        }
        return outcome
    }

    @discardableResult
    func closeAll() async -> GameWorkspaceCloseOutcome {
        let values = Array(sessions.values)
        var failures: [GameWorkspaceCloseOutcome] = []
        for value in values {
            let outcome = await close(value)
            if !outcome.isConfirmed { failures.append(outcome) }
        }
        guard !failures.isEmpty else { return .confirmed }
        let ids = failures.flatMap(\.ownedOperations)
        let detail = failures.map(\.detail).filter { !$0.isEmpty }.joined(separator: "; ")
        return .unconfirmed(ids: ids, detail: detail)
    }

    /// Replacement paths (environment/GitHub/starter resources) must not drop
    /// an execution session while an owned build or run-time CI job can still
    /// write. An unconfirmed close keeps the old execution object.
    private func closeExecutionForReplacement(_ session: GameWorkspaceSession) async throws {
        guard let execution = session.execution else { return }
        let outcome = await execution.close()
        guard outcome.isConfirmed else {
            throw GameWorkspaceRegistryError.workStopUnconfirmed(outcome.detail)
        }
        session.setExecution(nil)
    }

    /// Called under the existing personal-library mutation barrier, including
    /// folder and assistant operations. A launch/open already in flight is
    /// drained before the lease is released. The barrier rejects new opens.
    func prepareForLibraryAction(record: PersonalContentRecord, directory: URL) async throws {
        guard record.kind == .game else { throw GameWorkspaceRegistryError.notGameRecord }
        try PersonalLibraryFileActions.requireHeldFileAction(record.id)
        let expected = GameWorkspaceKey.canonical(
            directory.appendingPathComponent("Game/Files", isDirectory: true))
        let pending = opening.filter { $0.key.projectID == record.id &&
            $0.key.owner == .space(recordID: record.id) }.map(\.value)
        for task in pending { _ = try? await task.value }
        let values = sessions.values.filter { $0.record?.id == record.id && !$0.closed }
        for value in values {
            guard value.key.owner == .space(recordID: record.id), value.key.rootPath == expected else {
                throw PersonalFileActionError.changed
            }
            if let visual = value.visualSession, visual.isBusy || visual.isDirty ||
                visual.pendingDraft != nil || visual.conflict != nil || !visual.fileConflicts.isEmpty {
                throw GameWorkspaceRegistryError.editorBusy
            }
            let outcome = await close(value)
            guard value.closed else {
                throw GameWorkspaceRegistryError.workStopUnconfirmed(outcome.detail)
            }
        }
    }

    /// Permanent deletion hook. It removes only the App-owned private
    /// workspace row; the caller still owns original file deletion.
    func forgetOwnedWorkspace(projectID: UUID) async {
        let store = SQLiteWorkspaceStore(database: environment.database)
        let id = Self.workspaceID(for: projectID)
        if let record = try? await store.workspace(id: id), record.kind == .privateTask {
            try? await store.deleteWorkspace(id: id)
        }
    }

    // MARK: - Assistant/environment binding

    /// Ensures a real visible assistant for this Space work. The assistant is
    /// created by the existing Studio lifecycle and bound by `document_access`.
    /// Its conversation uses the game's existing workspace once the assistant
    /// is idle. Historical private task files are retained during migration.
    func assistantConversation(for record: PersonalContentRecord) async throws -> UUID {
        let id = try await environment.studioCoordinator.assistant(for: record)
        guard try await environment.studioCoordinator.access.get().assistant(projectID: record.id) == id else {
            throw GameWorkspaceRegistryError.conversationBindingChanged
        }
        return id
    }

    /// Bind the next assistant run to the same root used by the game IDE.
    /// Never retarget an in-flight run or delete its former private workspace.
    func bindAssistantWorkspace(record: PersonalContentRecord, conversationID: UUID) async throws {
        guard record.kind == .game else { throw GameWorkspaceRegistryError.notGameRecord }
        let access = try environment.studioCoordinator.access.get()
        guard try await access.assistant(projectID: record.id) == conversationID else {
            throw GameWorkspaceRegistryError.conversationBindingChanged
        }
        let session = try await openSpaceGame(record: record)
        guard let workspaceID = session.center.currentWorkspace?.id,
              workspaceID == Self.workspaceID(for: record.id) else {
            throw GameWorkspaceRegistryError.environmentRootMismatch
        }
        let store = SQLiteWorkspaceStore(database: environment.database)
        let previous = try await store.workspaceID(conversationID: conversationID)
        guard previous != workspaceID else { return }
        // The current run owns its frozen root until completion. Opening the
        // assistant again after it finishes performs this idempotent migration.
        guard try await access.assistant(projectID: record.id) == conversationID else {
            throw GameWorkspaceRegistryError.conversationBindingChanged
        }
        if try await store.assignConversationIfIdle(workspaceID: workspaceID,
            conversationID: conversationID, expectedWorkspaceID: previous) {
            await environment.workspaceCenter.reload()
        }
    }

    /// Finds an already prepared environment without creating a conversation
    /// or running a task. Used only while reopening an existing project.
    func existingEnvironmentID(for projectID: UUID, conversationID: UUID?,
                               rootURL: URL, requireSession: Bool = false) async throws -> String? {
        let conversation: UUID?
        if let conversationID {
            conversation = conversationID
        } else if let bound = try? await environment.studioCoordinator.access.get()
            .assistant(projectID: projectID) {
            conversation = bound
        } else {
            conversation = nil
        }
        guard let conversation,
              let binding = try await bindingStore.binding(conversationID: conversation) else { return nil }
        // The persisted binding can be read before the in-memory container index is loaded.
        try await environment.environmentRegistry.prepare()
        guard let record = await environment.environmentRegistry.record(id: binding.target.environmentID),
              (record.kind == .session && record.ownerID == conversation.uuidString)
                || (!requireSession && record.kind == .project) else { return nil }
        guard let root = try await environment.environmentRegistry
            .workspaceRoot(for: binding.target.environmentID),
              Self.canonical(root) == Self.canonical(rootURL) else {
            guard requireSession,
                  try await environment.environmentRegistry.restoreSpaceGameRoot(
                    containerID: binding.target.environmentID, conversationID: conversation,
                    projectID: projectID, verifiedRoot: rootURL) else {
                throw GameWorkspaceRegistryError.environmentRootMismatch
            }
            return binding.target.environmentID
        }
        return binding.target.environmentID
    }

    private func executionConversationID(for session: GameWorkspaceSession) async throws -> UUID {
        if let record = session.record { return try await assistantConversation(for: record) }
        if case .conversation(let id, _) = session.key.owner { return id }
        throw GameWorkspaceRegistryError.notGameRecord
    }

    /// Prepares or reuses a real execution location for the game root. It does
    /// not choose a global default: the caller passes a user-visible backend
    /// choice and the environment's workspace root is revalidated.
    func prepareEnvironment(for session: GameWorkspaceSession,
                            backend: EnvironmentExecutionBackend) async throws -> String {
        let conversationID = try await executionConversationID(for: session)
        if let existing = try await bindingStore.binding(conversationID: conversationID) {
            try await environment.environmentRegistry.prepare()
            let requireSession = session.record != nil
            guard let container = await environment.environmentRegistry.record(id: existing.target.environmentID),
                  (container.kind == .session && container.ownerID == conversationID.uuidString)
                    || (!requireSession && container.kind == .project),
                  let root = try await environment.environmentRegistry
                    .workspaceRoot(for: existing.target.environmentID),
                  Self.canonical(root) == Self.canonical(session.key.rootPathURL) else {
                throw GameWorkspaceRegistryError.environmentRootMismatch
            }
            session.setEnvironmentID(existing.target.environmentID)
            session.setExecutionConversation(conversationID)
            return existing.target.environmentID
        }
        // Only a persisted host-created native archive marker may exempt an
        // ended/unbound run from the no-run rebind rule. Goal text alone is
        // ordinary run data and is never trusted; the marker carries the exact
        // run/conversation/project/root/target identity and survives restart.
        let runs = try await environment.runStore.runs(conversationID: conversationID)
        var hasBlockingRun = false
        for run in runs {
            if run.endedAt != nil, run.executionBinding == nil,
               (try? await isTrustedNativeArchiveRun(run,
                    conversationID: conversationID,
                    projectID: session.key.projectID,
                    rootPath: session.key.rootPathURL)) == true {
                continue
            }
            hasBlockingRun = true
            break
        }
        guard !hasBlockingRun else { throw GameWorkspaceRegistryError.assistantHasRuns }
        let choice: TaskExecutionEnvironmentCenter.Choice
        switch backend {
        case .linuxVM: choice = .init(id: "local", name: "Linux", kind: .linux)
        case .macBridge: choice = .init(id: "mac", name: "Mac", kind: .mac)
        case .remoteSSH: throw GameWorkspaceRegistryError.environmentRootMismatch
        case .native: throw GameWorkspaceRegistryError.environmentRootMismatch
        }
        let target = try await environment.taskExecutionEnvironments.prepareTarget(
            choice, conversationID: conversationID, root: session.key.rootPathURL, fresh: true)
        let proposed = TaskExecutionBinding(conversationID: conversationID, target: target)
        let saved = try await bindingStore.bindInitial(proposed)
        // `bindInitial` is first-writer-wins and round-trips the body through
        // the store's millisecond date encoding, so a full synthesized
        // equality against `proposed` would always fail on `updatedAt` even
        // when this call installed the binding. Compare the real identity
        // (conversation, target facts, generation) instead; a genuine
        // concurrent bind is still rejected.
        guard saved.conversationID == proposed.conversationID,
              saved.target == proposed.target,
              saved.generation == proposed.generation else {
            throw GameWorkspaceRegistryError.assistantHasRuns
        }
        guard let container = await environment.environmentRegistry.record(id: saved.target.environmentID),
              container.kind == .session, container.ownerID == conversationID.uuidString,
              let root = try await environment.environmentRegistry
                .workspaceRoot(for: saved.target.environmentID),
              Self.canonical(root) == Self.canonical(session.key.rootPathURL) else {
            throw GameWorkspaceRegistryError.environmentRootMismatch
        }
        session.setEnvironmentID(saved.target.environmentID)
        session.setExecutionConversation(conversationID)
        return saved.target.environmentID
    }

    /// Reopens the Root project session with the resolved environment so its
    /// pin, contexts and IDE host all carry the same environment. A visual
    /// draft blocks this instead of being silently discarded.
    @discardableResult
    func ensurePlayableSession(for session: GameWorkspaceSession,
                               backend: EnvironmentExecutionBackend = .linuxVM) async throws -> GameWorkspaceSession {
        if session.environmentID == nil {
            _ = try await prepareEnvironment(for: session, backend: backend)
        }
        guard let environmentID = session.environmentID else {
            throw GameWorkspaceRegistryError.environmentRootMismatch
        }
        if try session.project.context.environmentID == environmentID { return session }
        if session.webPresentation != nil || session.rgssPlay != nil {
            throw GameWorkspaceRegistryError.editorBusy
        }
        if let visual = session.visualSession,
           visual.isDirty || visual.isBusy || visual.pendingDraft != nil
            || visual.conflict != nil || !visual.fileConflicts.isEmpty {
            throw GameWorkspaceRegistryError.editorBusy
        }
        try await session.project.prepareForIDE()
        try await closeExecutionForReplacement(session)
        session.setRGSSHost(nil)
        let title = session.record?.title ?? session.center.currentWorkspace?.name ?? "Game"
        let old = session.project
        let context = try GameProjectContext(projectID: session.key.projectID,
            owner: session.key.owner, rootURL: session.key.rootPathURL,
            savedRevision: old.project.revision, environmentID: environmentID)
        let reopened = try await GameWorkspaceProjectSession.open(center: session.center,
            context: context, history: session.history, support: session.support,
            title: title, starterResources: starterResources())
        try await reopened.refresh(reloadFiles: false)
        // Selection records include the environment ID, so the reopened
        // session cannot see the editor-session record and re-resolves from
        // discovery alone. Attaching the runtime also reopens the repository
        // at a new revision even when no file was edited, so a saved-revision
        // equality gate would drop a still-valid explicit choice here. Carry
        // the editor choice over whenever fresh discovery still recognizes
        // the same engine at the same root; `select` revalidates everything.
        if let selected = old.selectionSnapshot?.runSelection,
           let snapshot = reopened.selectionSnapshot,
           snapshot.engines(forRoot: selected.gameRoot).contains(where: { $0.engine == selected.engine }),
           snapshot.runSelection?.engine != selected.engine || snapshot.runSelection?.gameRoot != selected.gameRoot {
            try await reopened.select(root: selected.gameRoot, engine: selected.engine)
        }
        try requireOpen(session)
        guard session.project === old else { throw GameIDEBridgeError.superseded }
        await old.close()
        session.replaceProject(reopened)
        return session
    }

    private func currentRevision(_ session: GameWorkspaceSession,
                                 expected: String?) async throws -> String {
        let opened = try await session.project.repository.open(session.key.projectID, owner: session.key.owner)
        if let expected, expected != opened.revision {
            throw GameDocumentError.staleRevision(expected: expected, actual: opened.revision)
        }
        return opened.revision
    }

    /// Strict authority resolution used by build and guest execution. It
    /// requires the actual conversation AND the canonical environment
    /// workspace root to be this game session, not merely a real run from the
    /// same environment. When the fresh project has no usable assistant run,
    /// it creates one REAL saved native-service run through the existing
    /// run/task store instead of forcing the user to open AI first. Historical
    /// runs are reused only when their exact binding matches; they are never
    /// rebound.
    func resolveAuthority(context: GameProjectContext,
                          conversationID: UUID) async throws -> GameExecutionAuthority {
        guard context.environmentID != nil else { throw GameExecutionError.prerequisite(
            "Prepare this game's execution environment first.") }
        guard let binding = try await bindingStore.binding(conversationID: conversationID),
              binding.conversationID == conversationID else {
            throw GameWorkspaceRegistryError.runBindingMissing
        }
        guard binding.target.environmentID == context.environmentID else {
            throw GameWorkspaceRegistryError.runEnvironmentMismatch
        }
        guard let workspaceRoot = try await environment.environmentRegistry
            .workspaceRoot(for: binding.target.environmentID),
              Self.canonical(workspaceRoot) == Self.canonical(context.rootURL) else {
            throw GameWorkspaceRegistryError.runWorkspaceMismatch
        }
        let run = try await ensureRuntimeServiceRun(conversationID: conversationID,
                                                    binding: binding,
                                                    projectID: context.projectID,
                                                    rootURL: context.rootURL)
        guard run.conversationID == conversationID,
              run.executionBinding == binding else {
            throw GameWorkspaceRegistryError.runBindingMissing
        }
        return GameExecutionAuthority(runID: run.id, conversationID: conversationID,
            environmentID: binding.target.environmentID,
            executionBindingGeneration: binding.generation)
    }

    /// Real saved-native-service authority for host-only archive work. It does
    /// not start the Linux guest: a matching execution run is preferred, but an
    /// ordinary import may use a completed native run with no environment.
    private func archiveAuthority(for session: GameWorkspaceSession) async throws -> GameArchiveRunAuthority {
        let conversationID = try await executionConversationID(for: session)
        if let environmentID = session.environmentID,
           let binding = try? await bindingStore.binding(conversationID: conversationID),
           binding.conversationID == conversationID,
           binding.target.environmentID == environmentID,
           let root = try? await environment.environmentRegistry.workspaceRoot(for: environmentID),
           Self.canonical(root) == session.key.rootPath,
           let run = try? await reusableRun(conversationID: conversationID, binding: binding) {
            return GameArchiveRunAuthority(runID: run.id, conversationID: conversationID,
                environmentID: environmentID,
                executionBindingGeneration: binding.generation)
        }
        let run = try await ensureArchiveServiceRun(conversationID: conversationID,
            projectID: session.key.projectID, rootURL: session.key.rootPathURL)
        return GameArchiveRunAuthority(runID: run.id, conversationID: conversationID,
            environmentID: nil, executionBindingGeneration: nil)
    }

    /// Returns the actual saved run used by execution. An active run with a
    /// different binding is never bypassed; a completed run with the exact
    /// binding is reused so old assistant work is preserved but not rewritten.
    private func ensureRuntimeServiceRun(conversationID: UUID,
                                         binding: TaskExecutionBinding,
                                         projectID: UUID,
                                         rootURL: URL) async throws -> RunRecord {
        try await requireWritableConversation(conversationID)
        let runs = try await environment.runStore.runs(conversationID: conversationID)
        if let active = runs.first(where: { $0.endedAt == nil }) {
            guard let activeBinding = active.executionBinding else {
                throw GameWorkspaceRegistryError.runBindingMissing
            }
            guard activeBinding == binding else {
                throw GameWorkspaceRegistryError.runEnvironmentMismatch
            }
            return active
        }
        if let reusable = runs.first(where: {
            $0.endedAt != nil && $0.executionBinding == binding
        }) {
            return reusable
        }
        return try await createNativeServiceRun(conversationID: conversationID,
            goal: Self.runtimeServiceGoal, binding: binding, targetTool: "game.runtime",
            projectID: projectID, rootURL: rootURL)
    }

    private func reusableRun(conversationID: UUID,
                             binding: TaskExecutionBinding) async throws -> RunRecord? {
        let runs = try await environment.runStore.runs(conversationID: conversationID)
        return runs.first { $0.endedAt != nil && $0.executionBinding == binding }
    }

    private func ensureArchiveServiceRun(conversationID: UUID, projectID: UUID,
                                         rootURL: URL) async throws -> RunRecord {
        try await requireWritableConversation(conversationID)
        let runs = try await environment.runStore.runs(conversationID: conversationID)
        for run in runs where run.endedAt != nil && run.executionBinding == nil
            && run.goal == Self.archiveServiceGoal {
            if try await isTrustedNativeArchiveRun(run, conversationID: conversationID,
                projectID: projectID, rootPath: rootURL) {
                return run
            }
        }
        return try await createNativeServiceRun(conversationID: conversationID,
            goal: Self.archiveServiceGoal, binding: nil, targetTool: "game.archive",
            projectID: projectID, rootURL: rootURL)
    }

    private func createNativeServiceRun(conversationID: UUID, goal: String,
                                        binding: TaskExecutionBinding?,
                                        targetTool: String,
                                        projectID: UUID,
                                        rootURL: URL) async throws -> RunRecord {
        try await requireWritableConversation(conversationID)
        let now = Date()
        let run = RunRecord(id: UUID(), conversationID: conversationID, state: "completed",
            goal: goal, startedAt: now, endedAt: now,
            executionBinding: binding)
        try await environment.runStore.saveRun(run)
        let metadata = GameNativeServiceRunMetadata(runID: run.id,
            conversationID: conversationID, targetTool: targetTool,
            projectID: projectID, workspaceRootPath: Self.canonical(rootURL))
        if let payload = try? metadata.payloadJSON() {
            try await environment.runStore.appendEvent(runID: run.id, kind: .status,
                                                       payloadJSON: payload)
        }
        return run
    }

    /// Temporary chat is RAM-only and must never receive a durable game run.
    /// Notes assistants are also rejected: a game task needs an ordinary,
    /// model-configurable conversation that can carry its own binding.
    private func requireWritableConversation(_ conversationID: UUID) async throws {
        guard let conversation = try await environment.conversationStore.conversation(id: conversationID),
              conversation.purpose == .ordinary else {
            throw GameWorkspaceRegistryError.conversationNotWritable
        }
    }

    /// A run is a trusted pre-environment archive service only when the
    /// persisted host-written status marker matches this exact run,
    /// conversation, project, canonical root and target tool. Goal text and
    /// imported project content are never classification inputs.
    private func isTrustedNativeArchiveRun(_ run: RunRecord, conversationID: UUID,
                                           projectID: UUID, rootPath: URL) async throws -> Bool {
        guard run.conversationID == conversationID, run.endedAt != nil,
              run.executionBinding == nil else { return false }
        guard let events = try? await environment.runStore.events(runID: run.id) else {
            return false
        }
        return Self.isTrustedNativeArchiveMarker(run, events: events,
            conversationID: conversationID, projectID: projectID, rootPath: rootPath)
    }

    /// Pure persisted-marker classifier. It is intentionally independent of
    /// goal text, imported project JSON and in-memory IDs so tests can prove
    /// same-goal/forged/owner-mismatch runs are rejected and a real persisted
    /// archive marker survives an App restart.
    nonisolated static func isTrustedNativeArchiveMarker(_ run: RunRecord,
                                             events: [RunEventRecord],
                                             conversationID: UUID,
                                             projectID: UUID,
                                             rootPath: URL) -> Bool {
        guard run.conversationID == conversationID, run.endedAt != nil,
              run.executionBinding == nil else { return false }
        let expectedRoot = GameWorkspaceKey.canonical(rootPath)
        let decoder = JSONDecoder()
        return events.contains { event in
            guard event.runID == run.id, event.kind == .status,
                  let data = event.payloadJSON.data(using: .utf8),
                  let metadata = try? decoder.decode(GameNativeServiceRunMetadata.self,
                                                      from: data) else { return false }
            return metadata.activity == "gameProjectService"
                && metadata.version == 1
                && metadata.source == "nativeService"
                && metadata.targetTool == "game.archive"
                && metadata.runID == run.id
                && metadata.conversationID == conversationID
                && metadata.projectID == projectID
                && metadata.workspaceRootPath == expectedRoot
        }
    }

    private static let runtimeServiceGoal = "Game project runtime service"
    private static let archiveServiceGoal = "Game project archive service"

    // MARK: - Execution/play composition

    func executionSession(for session: GameWorkspaceSession,
                          gitHub: GameGitHubExecutionConfiguration? = nil) async throws -> GameWorkspaceExecutionSession {
        try requireOpen(session)
        try await ensurePlayableSession(for: session)
        if let existing = session.execution { return existing }
        let candidateGitHub = gitHub ?? GameBuildRepositorySettings.configuration()
        // A selected repository without the existing GitHub credential is not
        // a usable CI route. Keep local/source routes instead of presenting a
        // configured route that must fail later.
        let resolvedGitHub = candidateGitHub.flatMap(GameBuildRepositorySettings.validated)
        guard let environmentID = session.environmentID else {
            throw GameWorkspaceRegistryError.noSavedRun
        }
        let conversationID: UUID
        if let existing = session.executionConversationID {
            conversationID = existing
        } else {
            // Reopening an existing bound project can resolve its environment
            // without a cached assistant id. Resolve/create the real assistant
            // conversation now; a play/build never requires the user to open
            // the AI surface first.
            conversationID = try await executionConversationID(for: session)
            session.setExecutionConversation(conversationID)
        }
        let contexts = session.project.contexts
        let repository = session.project.repository
        let support = session.support
        let registry = self
        await runtimeResources.refresh()
        let resources = runtimeResources.executionResources()
        let readiness = await buildToolReadiness()
        let execution = try GameWorkspaceExecutionSession(configuration: .init(
            projectID: session.key.projectID,
            owner: session.key.owner,
            rootURL: session.key.rootPathURL,
            environmentID: environmentID,
            supportDirectory: support,
            contexts: contexts,
            repository: repository,
            currentContext: {
                guard let current = registry.session(projectID: session.key.projectID,
                                                     owner: session.key.owner) else {
                    throw GameIDEBridgeError.workspaceChanged
                }
                return try current.project.context
            },
            authority: { context in
                try await registry.resolveAuthority(context: context, conversationID: conversationID)
            },
            shell: MainLocalShellRunner(shell: environment.localShellService, runs: environment.runStore),
            gitHub: resolvedGitHub,
            portableResources: resources.portableResources,
            preparePortableResource: { [runtimeResources] engine in
                try await runtimeResources.prepare(for: engine)
                return await runtimeResources.portableResources()[engine]
            },
            renpySDK: resources.renpySDK,
            narrativeResources: resources.narrativeResources,
            runtimePacks: resources.runtimePacks,
            gdevelopSDKRoot: resources.gdevelopSDKRoot,
            gdevelopExportScript: resources.gdevelopExportScript,
            licensedDeployment: nil,
            providedTools: readiness.provided,
            developerBridge: { request in
                // Host-owned Web development bridge. It is enabled before
                // GameProjectRunController starts the player and is never
                // decoded from project metadata or an exported game.
                try GameDeveloperBridgeFactory.configuration(for: request)
            }))
        try requireOpen(session)
        session.setExecution(execution)
        return execution
    }

    // MARK: - Project developer hooks

    /// Real scene choices for the one engine that has scenes. This never
    /// writes the project or invents a "first scene".
    func developerHookScenes(for session: GameWorkspaceSession,
                             engine: GameEngineID) async throws -> [GameInstrumentationSceneChoice] {
        let context = try session.project.context
        let gameRoot = session.project.selectionSnapshot?.selectedRoot
        return try await instrumentation.scenes(context: context, engine: engine,
                                                gameRoot: gameRoot)
    }

    /// Preview over the shared project repository. The preview ID is stable for
    /// the exact revision/files, so apply can verify the same effects.
    func developerHookPlan(for session: GameWorkspaceSession, engine: GameEngineID,
                           sceneID: String?) async throws -> GameInstrumentationPlanSummary {
        let context = try session.project.context
        let gameRoot = session.project.selectionSnapshot?.selectedRoot
        return try await instrumentation.plan(context: context, engine: engine,
                                              gameRoot: gameRoot, sceneID: sceneID)
    }

    /// Install exactly the previewed effects through the repository CAS, then
    /// refresh the session's saved revision. The project stays open.
    func developerHookApply(for session: GameWorkspaceSession,
                            plan: GameInstrumentationPlanSummary) async throws
        -> GameInstrumentationApplyReceipt {
        let context = try session.project.context
        let receipt = try await instrumentation.apply(context: context, plan: plan,
            expectedRevision: context.savedRevision)
        try await session.project.refresh()
        return receipt
    }

    /// The existing Linux display/environment/owned-job adapters for RGSS.
    /// The host object is constructed once per project; the play session is
    /// owned by the project service and stops only its own request.
    func rgssHost(for session: GameWorkspaceSession) async throws -> RGSSAppHost {
        try await ensurePlayableSession(for: session)
        guard let environmentID = session.environmentID, let guests = environment.linuxGuestService,
              await guests.ownsLinuxEnvironment(environmentID: environmentID),
              let mapping = await guests.linuxGuestPathMap(environmentID: environmentID),
              let layer = mapping.hostPath(forGuestPath: LinuxGuestMountPoint.environment) else {
            throw RGSSGuestRunError.missingEnvironment
        }
        try requireOpen(session)
        if let existing = session.rgssHost, existing.baseDirectory == layer { return existing }
        let targets = RGSSGuestLinuxEnvironmentPort(descriptor: { id in
            await guests.guestDescriptor(environmentID: id)
        }, pathMap: { id in
            await guests.linuxGuestPathMap(environmentID: id)
        }, activate: { id in
            if await guests.guestIsRunning(environmentID: id) { return }
            guard try await guests.startGuest(environmentID: id, taskID: nil) else {
                throw RGSSGuestRunError.missingEnvironment
            }
        }, isOwned: { id in
            await guests.ownsLinuxEnvironment(environmentID: id)
        })
        let jobs = RGSSLinuxGuestLocalServiceJobService(services: guests,
            pathMap: { await guests.linuxGuestPathMap(environmentID: $0) })
        let host = try RGSSAppHost(baseDirectory: layer,
            displayCenter: environment.localLinuxDisplays,
            environment: targets,
            jobService: jobs,
            contexts: session.project.contexts)
        try requireOpen(session)
        session.setRGSSHost(host)
        return host
    }

    /// The user chooses an existing configured repository; the store holds no
    /// token and the GItHub clients read the existing credential store.
    func configureGitHub(session: GameWorkspaceSession,
                         selection: GameBuildRepositorySelection?) async throws {
        // Fence the current execution session before changing the repository
        // settings. If its builds did not drain, the old configuration stays
        // active and the caller sees an actionable error.
        try await closeExecutionForReplacement(session)
        if let selection { try GameBuildRepositorySettings.save(selection) }
        else { GameBuildRepositorySettings.clear() }
    }

    func playCoordinator(for session: GameWorkspaceSession) -> GamePlayCoordinator {
        if let existing = session.play { return existing }
        let value = GamePlayCoordinator(session: session, registry: self)
        session.setPlay(value)
        return value
    }

    /// Coalesces stop per request and retains an unconfirmed RGSS stop so the
    /// same owned session can be retried. A late stop never touches a newer
    /// request. Web saves/input cleanup use the real presentation receipt.
    func stopPlay(_ session: GameWorkspaceSession, requestID: UUID? = nil,
                  cancelLaunch: Bool = true) async {
        if cancelLaunch {
            // A user/IDE Stop fences any in-flight launch. The launch task
            // checks the token after every await and stops only its own
            // request; it is never awaited here to avoid self-deadlock when
            // the launch itself is stopping its predecessor.
            session.cancelLaunch()
            session.launchTask?.cancel()
        }
        if let existing = session.stopTask { _ = await existing.value; return }
        let task = Task { @MainActor [weak session] in
            guard let session else { return }
            var unconfirmed = false
            if let presentation = session.webPresentation,
               requestID == nil || presentation.request.id == requestID {
                let receipt = await presentation.stop()
                session.setLastStopReceipt(GameRunReceipt(projectID: session.key.projectID,
                    runID: presentation.request.id, action: "stop",
                    phase: receipt.closeAcknowledged ? "stopped" : "stopUnconfirmed",
                    stopConfirmed: receipt.closeAcknowledged,
                    automaticSave: String(describing: receipt.automaticSave),
                    screenshotSHA256: nil, logs: nil,
                    diagnostic: receipt.inputFailed ? "Input release failed; inspect the play screen." : nil))
                if receipt.closeAcknowledged {
                    session.setWebPresentation(nil)
                } else {
                    unconfirmed = true
                }
            }
            if let play = session.rgssPlay,
               requestID == nil || play.request.id == requestID {
                let outcome = await play.stop()
                session.setLastRGSSStop(outcome)
                session.setLastStopReceipt(GameRunReceipt(projectID: session.key.projectID,
                    runID: play.request.id, action: "stop",
                    phase: outcome.status.rawValue, stopConfirmed: outcome.status != .stopUnconfirmed,
                    automaticSave: nil, screenshotSHA256: nil, logs: nil,
                    diagnostic: outcome.error))
                if outcome.status != .stopUnconfirmed {
                    session.setRGSSPlay(nil)
                } else {
                    unconfirmed = true
                }
            }
            // An unacknowledged stop still owns its player/records/lease.
            // Tearing the execution request down here would delete the very
            // scope the retry path needs; wait for a confirmed stop instead.
            if !unconfirmed, let execution = session.execution, let requestID {
                await execution.stop(requestID)
            }
        }
        session.stopTask = task
        await task.value
        session.stopTask = nil
    }

    func makeRunExtension(for session: GameWorkspaceSession) async throws -> IDEProjectRunExtension {
        try await ensurePlayableSession(for: session)
        try ensureIDEHost(session)
        return try await session.project.makeRunExtension()
    }

    /// Serializes one project's launch slot. A replacement launch must first
    /// stop/drain the prior captured request and require an acknowledged stop;
    /// it never overwrites a live pointer. A late completion stops only its own
    /// request instead of publishing over a newer slot.
    private func launchProjectRun(session: GameWorkspaceSession,
                                  request: GameIDEProjectRunRequest) async throws {
        try requireOpen(session)
        guard session.launchTask == nil else {
            throw GameWorkspaceRegistryError.launchInProgress
        }
        let token = try session.beginLaunch()
        let task = Task { @MainActor in
            try await self.performLaunch(session: session, request: request, token: token)
        }
        session.setLaunchTask(task)
        defer { session.setLaunchTask(nil) }
        do {
            try await withTaskCancellationHandler(operation: { try await task.value },
                onCancel: { task.cancel() })
            session.finishLaunch(token)
        } catch {
            session.finishLaunch(token)
            throw error
        }
    }

    private func performLaunch(session: GameWorkspaceSession,
                               request: GameIDEProjectRunRequest,
                               token: UInt64) async throws {
        try Task.checkCancellation()
        guard session.launchIsCurrent(token) else { throw GameIDEBridgeError.superseded }
        if let priorID = session.lastLaunchRequest?.id {
            // Stop the prior captured request before touching the new slot.
            // `cancelLaunch: false` is essential: this launch is the caller,
            // not a user Stop, and must not cancel itself.
            await stopPlay(session, requestID: priorID, cancelLaunch: false)
            try Task.checkCancellation()
            guard session.launchIsCurrent(token) else { throw GameIDEBridgeError.superseded }
            if session.webPresentation != nil || session.rgssPlay != nil {
                throw GameWorkspaceRegistryError.stopUnconfirmed
            }
            if let receipt = session.lastStopReceipt, receipt.runID == priorID,
               receipt.stopConfirmed == false {
                throw GameWorkspaceRegistryError.stopUnconfirmed
            }
            // Drain a per-request execution handle that had no presentation
            // object (for example a failed UI creation after start).
            await session.execution?.stop(priorID)
            try Task.checkCancellation()
            guard session.launchIsCurrent(token) else { throw GameIDEBridgeError.superseded }
        }
        session.setLastLaunchRequest(request)
        if RGSSEngineProfiles.isRGSS(request.engine) {
            try await performRGSSLaunch(session: session, request: request, token: token)
        } else {
            try await performWebLaunch(session: session, request: request, token: token)
        }
        try Task.checkCancellation()
        guard session.launchIsCurrent(token) else {
            try await cleanupOwnedRequest(session: session, request: request)
            throw GameIDEBridgeError.superseded
        }
    }

    private func performRGSSLaunch(session: GameWorkspaceSession,
                                   request: GameIDEProjectRunRequest,
                                   token: UInt64) async throws {
        let host = try await rgssHost(for: session)
        let play = try host.makeSession(for: request)
        session.setRGSSPlay(play)
        do {
            try await play.start()
            try Task.checkCancellation()
            guard session.launchIsCurrent(token) else {
                throw GameIDEBridgeError.superseded
            }
        } catch {
            let outcome = await play.stop()
            if outcome.status == .stopUnconfirmed {
                // Retain the concrete owned session for the existing retry
                // path; never nil a process whose stop was not acknowledged.
                throw GameWorkspaceRegistryError.stopUnconfirmed
            }
            session.setRGSSPlay(nil)
            throw error
        }
    }

    private func performWebLaunch(session: GameWorkspaceSession,
                                  request: GameIDEProjectRunRequest,
                                  token: UInt64) async throws {
        let execution = try await executionSession(for: session)
        do {
            try await execution.launch(request)
            try Task.checkCancellation()
            guard session.launchIsCurrent(token) else {
                throw GameIDEBridgeError.superseded
            }
            guard let controller = execution.controller(for: request.id) else {
                throw GameWorkspaceRegistryError.noSavedRun
            }
            let presentation = try await GameProjectWebRunPresentation.make(
                request: request, controller: controller,
                repository: session.project.repository,
                supportDirectory: session.support,
                cleanupOwnedRequest: { [weak execution] id in
                    await execution?.stop(id)
                })
            session.setWebPresentation(presentation)
            try Task.checkCancellation()
            guard session.launchIsCurrent(token) else {
                throw GameIDEBridgeError.superseded
            }
        } catch {
            // Any post-start failure, cancellation or stale token stops the
            // request this launch actually started. A presentation created
            // before the stale check is cleaned by cleanupOwnedRequest.
            if session.webPresentation?.request.id == request.id {
                do { try await cleanupOwnedRequest(session: session, request: request) }
                catch { throw error }
            } else {
                await execution.stop(request.id)
            }
            throw error
        }
    }

    private func cleanupOwnedRequest(session: GameWorkspaceSession,
                                     request: GameIDEProjectRunRequest) async throws {
        var unconfirmed = false
        if let presentation = session.webPresentation,
           presentation.request.id == request.id {
            let receipt = await presentation.stop()
            if receipt.closeAcknowledged {
                session.setWebPresentation(nil)
            } else {
                unconfirmed = true
            }
        }
        if let play = session.rgssPlay, play.request.id == request.id {
            let outcome = await play.stop()
            if outcome.status == .stopUnconfirmed {
                unconfirmed = true
            } else {
                session.setRGSSPlay(nil)
            }
        }
        // Never tear down the execution request under an unconfirmed stop; the
        // retained presentation/session still owns that scope for retry.
        if !unconfirmed {
            await session.execution?.stop(request.id)
        }
        if unconfirmed { throw GameWorkspaceRegistryError.stopUnconfirmed }
    }

    private func ensureIDEHost(_ session: GameWorkspaceSession) throws {
        let actions = ExistingWorkspaceGameIDEActions(
            currentWorkspace: { session.project.currentPin },
            open: { [weak self] request in self?.navigation.present(request) },
            launch: { [weak session, weak self] request in
                guard let session, let self else { throw GameIDEBridgeError.workspaceChanged }
                try await self.launchProjectRun(session: session, request: request)
            },
            stop: { [weak session, weak self] id in
                guard let session, let self else { return }
                await self.stopPlay(session, requestID: id)
            })
        _ = try session.project.bindIDE(actions: actions)
    }

    /// Reads an already-open game session for this exact center/root/workspace
    /// and, when a conversation id is supplied, its exact owner. It never
    /// borrows a first chat from a multi-owner workspace. A Space game session
    /// is returned when it is the single matching session (conversation nil).
    func ownedSession(for center: WorkspaceCenter,
                      conversationID: UUID?) -> GameWorkspaceSession? {
        guard let workspace = center.currentWorkspace,
              let root = center.currentRootURL else { return nil }
        let rootPath = Self.canonical(root)
        let matching = sessions.values.filter { session in
            !session.closed && session.center === center
                && session.key.rootPath == rootPath
                && session.center.currentWorkspace?.id == workspace.id
        }
        if let conversationID {
            return matching.first { session in
                guard case .conversation(let id, let workspaceID) = session.key.owner else {
                    return false
                }
                return id == conversationID && workspaceID == workspace.id
            }
        }
        return matching.count == 1 ? matching.first : nil
    }

    /// Actual visual readiness, not a catalog entry or a pre-start placeholder.
    /// Web becomes ready only after GameProjectRunController has started the
    /// real player; RGSS becomes ready only when the guest session is running.
    func visualPresentation(for session: GameWorkspaceSession)
        -> GameWorkspaceVisualPresentation? {
        session.visualPresentation
    }

    /// Compatibility entry for the base provider and existing callers. A
    /// recognized ambiguous/owner error is surfaced as a failing extension so
    /// the IDE can show it instead of silently falling back to language Run.
    func ideRunExtension(for center: WorkspaceCenter) async -> IDEProjectRunExtension? {
        do {
            return try await ideRunExtension(for: center,
                                             conversationID: Optional<UUID>.none)
        } catch {
            let message = error.localizedDescription
            return IDEProjectRunExtension(run: { _ in
                throw FloeError.validationFailed(message)
            })
        }
    }

    /// Ordinary chat/generic IDE's Run extension. The caller passes the actual
    /// conversation id from its initializer/provider. A normal non-game root
    /// returns nil. A recognized ambiguous game throws; a workspace with no
    /// chat owner gets a real persisted ordinary owner linked to that exact
    /// workspace, never another chat's first entry.
    /// Recognition only; selection ambiguity belongs in the IDE's native
    /// chooser. No execution environment is borrowed from another chat.
    func prepareIDEGameSession(for center: WorkspaceCenter,
                               conversationID: UUID?) async throws -> GameWorkspaceSession? {
        guard let workspace = center.currentWorkspace, let root = center.currentRootURL else {
            throw GameIDEBridgeError.workspaceChanged
        }
        if let existing = ownedSession(for: center, conversationID: conversationID) {
            try await existing.project.refresh()
            return existing
        }
        let recognized = try await Task.detached {
            try GameProjectInspector.hasGameCandidate(rootURL: root)
        }.value
        try Task.checkCancellation()
        guard center.currentWorkspace?.id == workspace.id,
              center.currentRootURL?.standardizedFileURL.resolvingSymlinksInPath()
                == root.standardizedFileURL.resolvingSymlinksInPath() else {
            throw GameIDEBridgeError.workspaceChanged
        }
        guard recognized else { return nil }
        let owner = try await resolveWorkspaceOwner(center: center,
            workspace: workspace, conversationID: conversationID)
        let session = try await openChatGame(center: center, conversationID: owner,
                                             title: workspace.name)
        try await session.project.refresh()
        return session
    }

    func ideRunExtension(for center: WorkspaceCenter,
                         conversationID: UUID?) async throws -> IDEProjectRunExtension? {
        guard let session = try await prepareIDEGameSession(
            for: center, conversationID: conversationID) else { return nil }
        try await ensureResolvedSelection(session)
        return try await makeRunExtension(for: session)
    }

    /// Explicit typed overload retained for Root callers that already have a
    /// non-optional conversation id.
    func ideRunExtension(for center: WorkspaceCenter,
                         conversationID: UUID) async throws -> IDEProjectRunExtension? {
        let value: UUID? = conversationID
        return try await ideRunExtension(for: center, conversationID: value)
    }

    private func ensureResolvedSelection(_ session: GameWorkspaceSession) async throws {
        try await session.project.refresh()
        if session.project.selectionSnapshot?.requiresExplicitChoice == true {
            throw GameWorkspaceRegistryError.ambiguousGameProject
        }
    }

    private func resolveWorkspaceOwner(center: WorkspaceCenter,
                                       workspace: WorkspaceRecord,
                                       conversationID: UUID?) async throws -> UUID {
        let store = SQLiteWorkspaceStore(database: environment.database)
        if let conversationID {
            guard try await store.workspaceID(conversationID: conversationID) == workspace.id else {
                throw GameWorkspaceRegistryError.ownerNotAvailable
            }
            guard let conversation = try await environment.conversationStore
                .conversation(id: conversationID),
                  conversation.purpose == .ordinary else {
                throw GameWorkspaceRegistryError.conversationNotWritable
            }
            return conversationID
        }
        let ids = try await store.conversations(workspaceID: workspace.id)
        var ordinary: [UUID] = []
        for id in ids {
            guard let conversation = try? await environment.conversationStore
                .conversation(id: id), conversation.purpose == .ordinary else { continue }
            ordinary.append(id)
        }
        if ordinary.count == 1 { return ordinary[0] }
        if ordinary.count > 1 { throw GameWorkspaceRegistryError.ownerResolutionRequired }
        // No chat task owns this generic IDE workspace. Create a real ordinary
        // owner and link it to this exact workspace. The workspace root/Git and
        // file tree stay the same; only a durable owner is added.
        let record = try await environment.conversationCenter.createConversation(
            title: "Game run · " + workspace.name)
        _ = try await center.ensureReviewConversationWorkspace(
            conversationID: record.id, workspaceID: workspace.id, title: record.title)
        return record.id
    }

    /// Build/create a new conversion copy. The destination is created and
    /// bound by the host first; the transfer service copies from the source.
    /// `GameProjectSelectionCoordinator.prepareEngineChangeFork` is NOT used
    /// for a live project because it performs a standalone repository copy.
    func makeEngineConversionCopy(source: GameWorkspaceSession, title: String,
                                  engine: GameEngineID) async throws -> GameWorkspaceSession {
        guard let record = source.record else { throw GameWorkspaceRegistryError.engineChangeNeedsNewProject }
        let destinationID = UUID()
        let destinationTitle = (title.isEmpty ? record.title : title) + " (" + engine.rawValue + ")"
        _ = try await PersonalContentService.shared.createGame(title: destinationTitle,
                                                               engine: engine, folders: record.folders, id: destinationID)
        let resolved = try await PersonalContentService.shared.library().resolve(destinationID)
        _ = try await SpaceGameOriginal.read(id: destinationID, directory: resolved.url)
        let destination = try await openSpaceGame(record: resolved.record)
        let sourceEndpoint = GameProjectTransferEndpoint(context: try source.context,
            repository: source.project.repository, contexts: source.project.contexts)
        let destinationEndpoint = GameProjectTransferEndpoint(context: try destination.context,
            repository: destination.project.repository, contexts: destination.project.contexts)
        let preview = try await source.transfer.prepare(from: sourceEndpoint, to: destinationEndpoint,
            mode: .importIntoEmptyProject)
        _ = try await source.transfer.commit(preview.id)
        // The destination records the selected target engine, but its files
        // remain the original source; the user still performs the explicit
        // manual conversion. Nothing here claims lossless translation.
        _ = try await destination.project.refresh()
        return destination
    }

    // MARK: - Runtime resources / archive / build

    /// The App's real native archive adapter. ZIP/TAR variants use ArchiveEngine;
    /// 7z uses WorkspaceArchiveTool; RAR uses the existing signed CArchive
    /// handler. The authority is a real saved run, created lazily only when a
    /// host-decoded container is actually imported.
    func archiveHost(for session: GameWorkspaceSession) -> any GameExternalArchiveHostPort {
        let registry = self
        return MainGameExternalArchiveHost(root: session.support, authority: {
            try await registry.archiveAuthority(for: session)
        })
    }

    func importSource(_ source: URL, into session: GameWorkspaceSession) async throws {
        try await session.project.importSource(source, archiveHost: archiveHost(for: session))
    }

    /// Downloads a reviewed runtime pack on explicit user action and reopens
    /// the project session so the starter scaffolder receives the verified
    /// directories. It never starts an engine, compiler or Linux guest.
    func initializeStarter(for engine: GameEngineID, session: GameWorkspaceSession) async throws {
        if [GameEngineID.phaser, .kaplay, .babylon, .playcanvas].contains(engine) {
            try await prepareRuntimeResource(for: engine, session: session)
        }
        try await session.project.initializeStarter(engine: engine)
    }

    func prepareRuntimeResource(for engine: GameEngineID,
                                session: GameWorkspaceSession? = nil) async throws {
        _ = try await runtimeResources.prepare(for: engine)
        if let session { try await reloadStarterResources(for: session) }
    }

    func cancelRuntimeResourcePreparation(for engine: GameEngineID) async {
        await runtimeResources.cancelPreparation(for: engine)
    }

    private func reloadStarterResources(for session: GameWorkspaceSession) async throws {
        if session.webPresentation != nil || session.rgssPlay != nil {
            throw GameWorkspaceRegistryError.editorBusy
        }
        if let visual = session.visualSession,
           visual.isDirty || visual.isBusy || visual.pendingDraft != nil
            || visual.conflict != nil || !visual.fileConflicts.isEmpty {
            throw GameWorkspaceRegistryError.editorBusy
        }
        let title = session.record?.title ?? session.center.currentWorkspace?.name ?? "Game"
        let old = session.project
        let revision = try await currentRevision(session, expected: nil)
        let context = try GameProjectContext(projectID: session.key.projectID,
            owner: session.key.owner, rootURL: session.key.rootPathURL,
            savedRevision: revision, environmentID: session.environmentID)
        try await closeExecutionForReplacement(session)
        let reopened = try await GameWorkspaceProjectSession.open(center: session.center,
            context: context, history: session.history, support: session.support,
            title: title, starterResources: starterResources())
        try await reopened.refresh()
        session.setRGSSHost(nil)
        await old.close()
        session.replaceProject(reopened)
    }

    /// The exact tools that are genuinely available through reviewed resources
    /// or a real user-configured CI repository and credential. It never probes
    /// a developer subscription or funding state.
    func buildToolReadiness() async -> GameBuildToolReadiness {
        let ciConfigured = GameBuildRepositorySettings.validatedConfiguration() != nil
        var provided = runtimeResources.providedToolIDs()
        if ciConfigured { provided.formUnion(GameBuildToolReadiness.ciProvidedToolIDs) }
        // No implemented script-web host route executes project npm, and the
        // reviewed CI template supplies its own Node. The catalog marks
        // node-lts conditional; treating it as satisfied here prevents a
        // false gate while never claiming that Node is installed locally.
        provided.insert("node-lts")
        return .init(provided: provided, ciConfigured: ciConfigured, notes: [
            ciConfigured
                ? "GitHub Actions repository and credential are configured; reviewed CI tool prerequisites are available."
                : "No GitHub Actions repository is configured; CI-only routes report their real missing prerequisite.",
            "Local runtime resources are verified by GameRuntimeResourceRegistry; only installed packs contribute tool IDs.",
        ])
    }

    /// Plan-aware build wrapper shared by the Space Build screen and the
    /// `game.build` tool. It narrows a host route to its real CI equivalent
    /// when the local SDK is absent, computes missing prerequisites from the
    /// actual selected routes, and passes the same `providedTools` set into
    /// the coordinator gate.
    /// One freshly saved root/engine choice is shared by preview and build.
    private func buildSelection(session: GameWorkspaceSession,
                                engine: GameEngineID) async throws -> GameBuildProjectSelection {
        try await session.project.prepareForHandoff()
        guard let snapshot = session.project.selectionSnapshot else {
            throw GameWorkspaceRegistryError.ambiguousGameProject
        }
        let selected = try snapshot.requireRunSelection()
        let context = try session.project.context
        try selected.validate(context: context)
        guard selected.engine == engine else {
            throw FloeError.validationFailed(IDELanguageRunText.t(
                "请先在工程选择中确认要构建的引擎。", "Choose this engine in the project selection before building."))
        }
        // A changed owner/project/root/environment/engine fences an older
        // exact-source selection. An in-flight build keeps its own provider
        // reference; a new build can never borrow stale bytes silently.
        sourceCompanions.retireStale(
            projectID: context.projectID, owner: context.owner,
            rootPath: GameWorkspaceKey.canonical(context.rootURL),
            keepingEngine: engine, environmentID: context.environmentID)
        return try GameBuildProjectSelection(context: context, engine: selected.engine,
                                              gameRoot: selected.gameRoot)
    }

    func capabilityPlan(session: GameWorkspaceSession,
                        engine: GameEngineID) async throws -> GameBuildCapabilityPlan {
        try requireOpen(session)
        try await ensurePlayableSession(for: session)
        let selection = try await buildSelection(session: session, engine: engine)
        let execution = try await executionSession(for: session)
        return try await execution.capabilityPlan(engine: engine, selection: selection)
    }

    func build(session: GameWorkspaceSession, engine: GameEngineID,
               output: GameBuildArguments.Output, routeIDs: Set<String>?,
               distributionProfileID: String?) async throws -> GameBuildRunResult {
        try requireOpen(session)
        try await ensurePlayableSession(for: session)
        let selection = try await buildSelection(session: session, engine: engine)
        let execution = try await executionSession(for: session)
        let plan = try await execution.capabilityPlan(engine: engine, selection: selection)
        let matching = Set(plan.outputs.filter { Self.output($0.kind, matches: output) }.map(\.routeID))
        let requested = routeIDs ?? matching
        guard !requested.isEmpty, requested.isSubset(of: matching) else {
            throw FloeError.validationFailed(
                "The selected output is not available for this engine and revision")
        }
        let resources = runtimeResources.executionResources()
        let viable = self.viableRouteIDs(plan: plan, requested: requested, resources: resources)
        guard !viable.isEmpty else {
            throw FloeError.validationFailed("No viable build route remains for this engine")
        }
        let readiness = await buildToolReadiness()
        let ciRoutes = plan.routes.filter {
            viable.contains($0.id) && $0.producer == .ci
        }
        if !ciRoutes.isEmpty && !readiness.ciConfigured {
            throw FloeError.validationFailed(
                "This CI route needs an existing GitHub Actions repository and credential. Configure one in Build / export, or choose a local/source route.")
        }
        if !ciRoutes.isEmpty && !GameBuildRepositorySettings.sourceUploadConsent() {
            throw FloeError.validationFailed(
                "Allow uploading this project's saved source snapshot to the selected CI repository, or choose a local/source route.")
        }
        let missing = output == .source ? [] : readiness.missingPrerequisites(in: plan, selectedRouteIDs: viable)
        let pairedProvider: (any GameDistributionPairedSourceProvider)?
        if distributionProfileID != nil, runtimeResources.requiresPairedSource(for: engine) {
            let identity = GameSourceCompanionIdentity(
                projectID: selection.projectID, owner: selection.owner,
                rootPath: GameWorkspaceKey.canonical(selection.projectRootURL),
                engine: selection.engine, environmentID: selection.environmentID)
            guard let provider = sourceCompanions.provider(for: identity) else {
                throw GameSourceCompanionError.selectionRequired
            }
            pairedProvider = provider
        } else {
            pairedProvider = nil
        }
        let outcome = try await execution.build(.init(engine: engine,
            selectedRouteIDs: viable, distributionProfileID: distributionProfileID,
            providedTools: readiness.provided, selection: selection),
            pairedProvider: pairedProvider)
        return .init(outcome: outcome, selectedRouteIDs: viable,
            missingPrerequisites: missing.map { $0.tool.id + "@" + $0.tool.version })
    }

    // MARK: - Exact source companion

    private func sourceCompanionIdentity(context: GameProjectContext,
                                         engine: GameEngineID) -> GameSourceCompanionIdentity {
        .init(projectID: context.projectID, owner: context.owner,
              rootPath: GameWorkspaceKey.canonical(context.rootURL),
              engine: engine, environmentID: context.environmentID)
    }

    func sourceCompanionIdentity(session: GameWorkspaceSession,
                                 engine: GameEngineID) throws -> GameSourceCompanionIdentity {
        sourceCompanionIdentity(context: try session.project.context, engine: engine)
    }

    func sourceCompanionSnapshot(session: GameWorkspaceSession,
                                 engine: GameEngineID) -> GameSourceCompanionSnapshot? {
        guard let identity = try? sourceCompanionIdentity(session: session, engine: engine) else {
            return nil
        }
        return sourceCompanions.snapshot(for: identity)
    }

    /// Resolves and validates the user's exact source offer off the main actor.
    /// The returned selection owns the security scope; the view only displays a
    /// snapshot and can disappear without releasing access used by a build.
    func importSourceCompanion(url: URL, session: GameWorkspaceSession,
                               engine: GameEngineID) async throws -> GameSourceCompanionSnapshot {
        let identity = try sourceCompanionIdentity(session: session, engine: engine)
        guard runtimeResources.sourceAccompanimentCatalog() != nil else {
            throw GameSourceCompanionError.missingCatalog
        }
        guard let pack = runtimeResources.sourceAccompanimentPack(for: engine),
              pack.pairedSourceID != nil, pack.sourceBundle != nil else {
            throw GameSourceCompanionError.unsupportedEngine
        }
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let resolution = try await Task.detached(priority: .userInitiated) {
                try GamePortableSourceOfferResolver.resolve(pack: pack, root: url)
            }.value
            let selection = try GameSourceCompanionSelection(
                identity: identity, pack: pack, resolution: resolution,
                rootURL: url, didAccess: accessing)
            return sourceCompanions.install(selection)
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    func removeSourceCompanion(session: GameWorkspaceSession,
                               engine: GameEngineID) throws {
        sourceCompanions.remove(try sourceCompanionIdentity(session: session, engine: engine))
    }

    /// Materializes the exact local companion in the explicit engineering mode.
    /// The catalog's unpublished public state is recorded unchanged; this does
    /// not publish, create a written offer or claim distribution readiness.
    func exportSourceCompanion(session: GameWorkspaceSession,
                               engine: GameEngineID) async throws -> GameSourceCompanionExport {
        let identity = try sourceCompanionIdentity(session: session, engine: engine)
        guard let selection = sourceCompanions.selection(for: identity) else {
            throw GameSourceCompanionError.selectionRequired
        }
        // Hold the scope across the detached materialization so replacing or
        // removing the selection cannot release it under running IO.
        try selection.beginUse()
        defer { selection.endUse() }
        guard let catalog = runtimeResources.sourceAccompanimentCatalog() else {
            throw GameSourceCompanionError.missingCatalog
        }
        guard let pack = runtimeResources.sourceAccompanimentPack(for: engine),
              pack.packID == selection.packID else {
            throw GameSourceCompanionError.unsupportedEngine
        }
        let base = session.support.appendingPathComponent("SourceCompanions", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let destination = base.appendingPathComponent(
            "\(engine.rawValue)-\(selection.bundleID)-\(UUID().uuidString.lowercased())",
            isDirectory: true)
        let roots = selection.companionRoots
        let receipt = try await Task.detached(priority: .userInitiated) {
            try GamePortableSourceOfferMaterializer.materialize(
                catalog: catalog, packID: selection.packID, roots: roots,
                to: destination, mode: .sourceAccompaniedExport)
        }.value
        return .init(directory: destination, receipt: receipt)
    }

    private func requireOpen(_ session: GameWorkspaceSession) throws {
        guard !session.closed, !session.closing else {
            throw GameWorkspaceRegistryError.workStopUnconfirmed(session.closeFailure ?? "")
        }
    }

    /// Explicit Build-sheet Cancel. It does not close the game session; the
    /// returned outcome tells the view whether it may dismiss.
    func cancelBuilds(session: GameWorkspaceSession) async -> GameWorkspaceCloseOutcome {
        guard let execution = session.execution else { return .confirmed }
        return await execution.cancelAllBuilds()
    }

    private func viableRouteIDs(plan: GameBuildCapabilityPlan, requested: Set<String>,
                                resources: GameExecutionResources) -> Set<String> {
        var values = requested
        if plan.engine == .gdevelop,
           resources.gdevelopSDKRoot == nil || resources.gdevelopExportScript == nil {
            // The plan declares both a host exporter and a CI exporter for the
            // same Web artifact. Without the pinned local SDK, only the CI
            // route is real; leaving the host route selected would fail inside
            // the exporter instead of using the configured CI route.
            if values.remove("gdevelop-web") != nil {
                values.insert("gdevelop-ci-web")
            }
        }
        return values
    }

    private static func output(_ kind: GameBuildOutputKind,
                               matches output: GameBuildArguments.Output) -> Bool {
        switch output {
        case .web: return kind == .webBundle
        case .source: return kind == .sourceArchive
        case .nativeProject: return kind == .nativeProject
        case .nativeInstaller: return kind == .nativeInstaller
        }
    }

    // MARK: - Helpers

    func starterResources() -> GameStarterResources {
        runtimeResources.starterResources()
    }

    func runtimePackProvider() throws -> (any GameRunRuntimePackProviding)? {
        runtimeResources.runtimePackProvider()
    }

    private func ensureOwnedWorkspace(projectID: UUID, title: String, rootURL: URL) async throws -> WorkspaceRecord {
        let store = SQLiteWorkspaceStore(database: environment.database)
        let id = Self.workspaceID(for: projectID)
        let applicationSupport = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent", isDirectory: true)
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let base = applicationSupport.standardizedFileURL.resolvingSymlinksInPath()
        guard root.path.hasPrefix(base.path + "/") else {
            throw PersonalContentError.outsideLibrary
        }
        let relative = String(root.path.dropFirst(base.path.count + 1))
        if var existing = try await store.workspace(id: id) {
            // The library can move the .floeproject folder. The workspace row is
            // App-owned metadata, so update only its relative root/name; the
            // repository and original bytes are not changed here.
            guard existing.kind == .privateTask else { throw PersonalContentError.changedDocument }
            if existing.internalRelativePath != relative || existing.name != title {
                existing.internalRelativePath = relative
                existing.name = title
                existing.updatedAt = Date()
                try await store.saveWorkspace(existing)
            }
            return existing
        }
        let record = WorkspaceRecord(id: id, name: title, rootBookmark: Data(),
            kind: .privateTask, internalRelativePath: relative)
        try await store.saveWorkspace(record)
        return record
    }

    static func workspaceID(for projectID: UUID) -> UUID {
        let digest = SHA256.hash(data: Data(("floe.game.workspace." + projectID.uuidString.lowercased()).utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func supportRoot() -> URL {
        // Chat-owned game projects are durable. A temporary fallback would
        // make them disappear on relaunch, so use the App container.
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL.applicationSupportDirectory
        return support.appendingPathComponent("FloeAgent/GameProjects", isDirectory: true)
    }

    private static func enginePackDirectory() -> URL {
        // Engine packs are installed user resources, not throwaway cache.
        let base = (try? FloeArtifactStore.root())
            ?? URL.applicationSupportDirectory.appendingPathComponent("FloeAgent", isDirectory: true)
        return base.appendingPathComponent("GameEnginePacks", isDirectory: true)
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

extension GameWorkspaceKey {
    var rootPathURL: URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
    }
}

#endif
