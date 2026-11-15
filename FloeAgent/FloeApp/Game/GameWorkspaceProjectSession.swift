// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeCore
import FloeGameCore
import FloeGameAuthoring
import FloeGameBuildKit
import FloeGameEditingCore
import FloeGameIDEBridge
import FloeGameWorkspaceHost
import FloeGameStarterKit
import FloeGameProjectFlow
import FloeWorkspace

/// Service-owned live project shared by overview, quick edit and the existing
/// IDE. Views never materialize another editable tree or create another Git UI.
@MainActor @Observable
final class GameWorkspaceProjectSession {
    let center: WorkspaceCenter
    let pin: GameIDEWorkspacePin
    let target: ExistingGameWorkspaceTarget
    let repository: FileGameProjectRepository
    let contexts: ExistingWorkspaceGameContexts
    let revisions: GameWorkspaceRevisionTracker
    let support: URL
    let selection: GameProjectSelectionCoordinator
    private(set) var project: GameStoredProject
    private(set) var selectionSnapshot: GameProjectSelectionSnapshot?
    private(set) var isClosed = false
    private(set) var operationInProgress = false
    private(set) var importSummary: String?
    private var importTask: Task<GameProjectSourceImportResult, Error>?
    private var starterTask: Task<GameProjectSeedResult, Error>?
    private var generation: UInt64 = 0
    private var ideHost: ExistingWorkspaceGameIDEHost?
    private var visualSession: GameEditingSession?
    private let importer: GameProjectSourceImporter
    private let importJobs: URL

    private init(center: WorkspaceCenter, pin: GameIDEWorkspacePin, target: ExistingGameWorkspaceTarget,
                 repository: FileGameProjectRepository, contexts: ExistingWorkspaceGameContexts,
                 revisions: GameWorkspaceRevisionTracker, support: URL, project: GameStoredProject,
                 importer: GameProjectSourceImporter, importJobs: URL, selection: GameProjectSelectionCoordinator) {
        self.center = center; self.pin = pin; self.target = target; self.repository = repository
        self.contexts = contexts; self.revisions = revisions; self.support = support; self.project = project
        self.importer = importer; self.importJobs = importJobs
        self.selection = selection
    }

    /// `center` is the existing center that owns this exact IDE root and scope.
    /// Chat supplies its actual conversation/workspace owner; Space supplies its
    /// library record owner. No global selected conversation or first environment.
    static func open(center: WorkspaceCenter, context: GameProjectContext,
                     history: URL, support: URL, title: String,
                     starterResources: GameStarterResources = .init(),
                     recommender: GameProjectSelectionRecommendationHandler? = nil,
                     capabilityProbe: (any GameProjectSelectionCapabilityProbe)? = nil) async throws -> GameWorkspaceProjectSession {
        guard let workspaceID = center.currentWorkspace?.id, let service = center.fileService,
              let root = center.currentRootURL,
              canonical(root) == canonical(context.rootURL) else { throw GameIDEBridgeError.workspaceChanged }
        let pin = try GameIDEWorkspacePin(workspaceID: workspaceID, context: context)
        let binding = try GameWorkingTreeBinding(workspaceID: workspaceID, context: context)
        let revisions = GameWorkspaceRevisionTracker(binding: pin)
        let target = try ExistingGameWorkspaceTarget(binding: binding, service: service, revisions: revisions)
        let files = try ExistingWorkspaceGameFiles(targets: [target], repositoryDirectory: history)
        let repository = try FileGameProjectRepository(directory: history, workingTree: files)
        let contexts = try ExistingWorkspaceGameContexts(repository: repository, targets: [target])
        let project: GameStoredProject
        do { project = try await repository.open(context.projectID, owner: context.owner) }
        catch GameProjectError.projectNotFound(let missing) where missing == context.projectID {
            // Adds game capability to a host-owned ordinary IDE project while
            // adopting, rather than replacing, all of its existing files and Git.
            project = try await repository.createProject(projectID: context.projectID, owner: context.owner, title: title)
        }
        try Task.checkCancellation()
        guard center.currentWorkspace?.id == workspaceID, let current = center.currentRootURL,
              canonical(current) == canonical(root) else { revisions.close(); throw GameIDEBridgeError.workspaceChanged }
        let importJobs = support.appendingPathComponent("ImportJobs", isDirectory: true)
        let originals = support.appendingPathComponent("OriginalArchives", isDirectory: true)
        for directory in [support, importJobs, originals] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let importer = GameProjectSourceImporter(originalStore: try GameArchiveOriginalStore(directory: originals))
        let catalog = try GameStarterCatalog.bundled()
        let scaffolder = GameStarterScaffolder(repository: repository, contexts: contexts,
            catalog: catalog, resources: starterResources,
            workRoot: support.appendingPathComponent("StarterJobs", isDirectory: true))
        let selection = try GameProjectSelectionCoordinator(scaffolder: scaffolder, contexts: contexts,
            store: FileGameProjectSelectionStore(directory: support.appendingPathComponent("Selection", isDirectory: true)),
            recommender: recommender, capabilityProbe: capabilityProbe)
        return .init(center: center, pin: pin, target: target, repository: repository, contexts: contexts,
            revisions: revisions, support: support, project: project, importer: importer, importJobs: importJobs,
            selection: selection)
    }

    var context: GameProjectContext {
        get throws {
            try requireCurrent()
            return try GameProjectContext(projectID: project.projectID, owner: project.owner,
                rootURL: pin.rootURL, savedRevision: project.revision, environmentID: pin.environmentID)
        }
    }

    func refresh() async throws {
        let epoch = generation
        try requireCurrent()
        let saved = try await repository.open(project.projectID, owner: project.owner)
        try Task.checkCancellation(); try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        project = saved
        let snapshot = try await selection.refresh(project: saved, context: context)
        try Task.checkCancellation(); try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        selectionSnapshot = snapshot
        // Native drafts retain their base bytes; a repository refresh cannot
        // silently discard them or replace their undo/conflict state.
    }

    /// The project already exists. Files/folders/archives all use the complete
    /// source importer, retain their original archive, and recognize only afterwards.
    func importSource(_ source: URL, archiveHost: (any GameExternalArchiveHostPort)? = nil) async throws {
        try requireCurrent()
        guard !operationInProgress else { throw GameAuthoringError.busy }
        guard visualSession == nil else { throw GameIDEBridgeError.unsavedChanges }
        operationInProgress = true
        defer { operationInProgress = false }
        let epoch = generation
        let captured = try context
        try captured.validate(current: await contexts.currentContext(for: captured))
        let importer = self.importer, baseProject = self.project
        let repository = self.repository, importJobs = self.importJobs
        let task = Task.detached {
            try await importer.importSource(source, into: baseProject, repository: repository,
                workspace: importJobs, hostPort: archiveHost)
        }
        importTask = task
        defer { importTask = nil }
        let result = try await withTaskCancellationHandler(operation: { try await task.value },
                                                          onCancel: { task.cancel() })
        // A committed import stays in its owned repository if navigation changed;
        // a late completion cannot publish UI into a different project session.
        guard !isClosed, generation == epoch else { return }
        try requireCurrent()
        project = result.project
        selectionSnapshot = try await selection.refresh(project: result.project, context: context)
        importSummary = IDELanguageRunText.t("已导入 \(result.importedFiles) 个文件", "Imported \(result.importedFiles) files")
    }

    func select(root: GameRelativePath?, engine: GameEngineID) async throws {
        try await prepareForHandoff()
        let epoch = generation
        let snapshot = try await selection.select(root: root, engine: engine, context: context)
        try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        selectionSnapshot = snapshot
    }

    func initializeStarter(engine: GameEngineID) async throws {
        try requireCurrent()
        guard !operationInProgress, visualSession == nil else { throw GameAuthoringError.busy }
        operationInProgress = true; defer { operationInProgress = false }
        let epoch = generation
        let captured = try context, baseProject = self.project, selection = self.selection
        let task = Task.detached {
            try await selection.createEngineProject(emptyProject: baseProject, context: captured, engine: engine)
        }
        starterTask = task
        defer { starterTask = nil }
        let result = try await withTaskCancellationHandler(operation: { try await task.value },
                                                          onCancel: { task.cancel() })
        guard !isClosed, generation == epoch else { return }
        try requireCurrent()
        project = result.initialization.project
        selectionSnapshot = result.snapshot
    }

    func makeRunExtension() async throws -> IDEProjectRunExtension {
        try await prepareForHandoff()
        let selected = try await selection.currentRunSelection(project: project, context: context)
        guard let ideHost else { throw GameIDEBridgeError.workspaceChanged }
        return ideHost.ideRunExtension(engine: selected.engine, gameRoot: selected.gameRoot)
    }

    func bindIDE(actions: ExistingWorkspaceGameIDEActions) throws -> ExistingWorkspaceGameIDEHost {
        try requireCurrent()
        if let ideHost { return ideHost }
        let host = try ExistingWorkspaceGameIDEHost(workspace: pin, target: target, repository: repository,
            actions: actions, visualSession: visualSession)
        ideHost = host
        return host
    }

    func attachVisual(_ session: GameEditingSession?) throws {
        try requireCurrent()
        if let current = visualSession, current !== session,
           current.isBusy || current.isDirty || current.pendingDraft != nil || current.conflict != nil || !current.fileConflicts.isEmpty {
            throw GameIDEBridgeError.unsavedChanges
        }
        if let session {
            guard session.projectID == project.projectID, session.owner == project.owner,
                  session.repository === repository else { throw GameIDEBridgeError.workspaceChanged }
        }
        try ideHost?.attachVisualSession(session)
        visualSession = session
    }

    func prepareForHandoff() async throws {
        try requireCurrent()
        if let visualSession { _ = try await visualSession.prepareForHandoff() }
        try await refresh()
    }

    /// Called by the center's actual workspace/navigation observer, not by a
    /// SwiftUI body reconstruction or an internal preview covering the editor.
    func workspaceDidChange() {
        revisions.noteWorkspaceChanged(to: currentPin)
        if currentPin == nil { generation &+= 1 }
    }

    var currentPin: GameIDEWorkspacePin? {
        guard !isClosed, center.currentWorkspace?.id == pin.workspaceID,
              let root = center.currentRootURL, Self.canonical(root) == Self.canonical(pin.rootURL) else { return nil }
        return pin
    }

    /// The caller first resolves draft/assistant departure. Close waits for owned
    /// operations so security scopes/leases cannot be released during file IO.
    func close() async {
        guard !isClosed else { return }
        isClosed = true; generation &+= 1
        importTask?.cancel()
        starterTask?.cancel()
        if let importTask { _ = try? await importTask.value }
        if let starterTask { _ = try? await starterTask.value }
        importTask = nil
        starterTask = nil
        await ideHost?.close()
        revisions.close()
        // WorkspaceCenter remains owned by its caller; a chat's center must
        // never be closed by the game extension. Space releases its own center.
    }

    private func requireCurrent() throws {
        guard currentPin != nil else { throw GameIDEBridgeError.workspaceChanged }
    }
    private static func canonical(_ url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }
}
#endif
