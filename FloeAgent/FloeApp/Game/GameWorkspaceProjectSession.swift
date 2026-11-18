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
    private(set) var selectionSnapshot: GameProjectSelectionSnapshot? {
        didSet { if selectionSnapshot != nil { recognitionIssue = nil } }
    }
    private(set) var recognitionIssue: String?
    /// One assistant proposal for this live project. It is advisory only and
    /// is never written to the selection store until the user approves it in
    /// the project setup surface.
    private(set) var pendingSelectionProposal: GameProjectSelectionProposal?
    /// The most recent proposal the user actually accepted. It lets the
    /// assistant's confirm action report the already-persisted selection
    /// without granting it a new confirmation path.
    private(set) var lastConfirmedSelectionProposalID: UUID?
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

    func refresh(reloadFiles: Bool = true, allowRecognitionFailure: Bool = false) async throws {
        let epoch = generation
        try requireCurrent()
        let saved = reloadFiles ? try await repository.open(project.projectID, owner: project.owner) : project
        try Task.checkCancellation(); try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        project = saved
        let captured = try context
        let result: Result<GameProjectSelectionSnapshot, Error>
        do { result = .success(try await selection.refresh(project: saved, context: captured)) }
        catch { result = .failure(error) }
        try Task.checkCancellation(); try requireCurrent()
        guard generation == epoch, project.revision == saved.revision else { throw GameIDEBridgeError.superseded }
        switch result {
        case .success(let snapshot):
            selectionSnapshot = snapshot
        case .failure(let error):
            selectionSnapshot = nil
            pendingSelectionProposal = nil
            guard allowRecognitionFailure, !(error is CancellationError) else { throw error }
            recognitionIssue = error.localizedDescription
        }
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
        selectionSnapshot = nil
        pendingSelectionProposal = nil
        importSummary = IDELanguageRunText.t("已导入 \(result.importedFiles) 个文件", "Imported \(result.importedFiles) files")
        try await refresh(reloadFiles: false, allowRecognitionFailure: true)
    }

    func select(root: GameRelativePath?, engine: GameEngineID) async throws {
        try await prepareForSelection()
        let epoch = generation
        let snapshot = try await selection.select(root: root, engine: engine, context: context)
        try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        selectionSnapshot = snapshot
        pendingSelectionProposal = nil
    }

    /// The user explicitly chose an engine/root pair without deterministic
    /// marker evidence. The caller (UI) owns the acknowledgement prompt.
    func selectManual(root: GameRelativePath?, engine: GameEngineID,
                      acknowledgingUnverified: Bool) async throws {
        try await prepareForSelection()
        let epoch = generation
        let snapshot = try await selection.selectManual(
            root: root, engine: engine, context: context,
            acknowledgingUnverified: acknowledgingUnverified)
        try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        selectionSnapshot = snapshot
        pendingSelectionProposal = nil
    }

    /// Records one assistant proposal against the fresh revision. No selection
    /// is persisted and no run/build authority is created.
    @discardableResult
    func proposeSelection(root: GameRelativePath?, engine: GameEngineID,
                          evidencePaths: [GameRelativePath], rationale: String,
                          generatedBy: String) async throws
        -> GameProjectSelectionProposal {
        try await prepareForSelection()
        let epoch = generation
        let proposal = try await selection.proposeSelection(
            root: root, engine: engine, evidencePaths: evidencePaths,
            rationale: rationale, generatedBy: generatedBy, context: context)
        try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        pendingSelectionProposal = proposal
        return proposal
    }

    /// The user's explicit confirmation in the project setup surface. This is
    /// the only method that persists a proposal.
    @discardableResult
    func confirmSelectionProposal(_ proposal: GameProjectSelectionProposal)
        async throws -> GameProjectSelectionSnapshot {
        guard pendingSelectionProposal?.id == proposal.id else {
            throw GameProjectFlowError.proposalNotFound
        }
        let epoch = generation
        let snapshot = try await selection.confirmProposal(
            proposal, context: context, userConfirmed: true)
        try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        selectionSnapshot = snapshot
        pendingSelectionProposal = nil
        lastConfirmedSelectionProposalID = proposal.id
        return snapshot
    }

    /// Assistant status/confirmation surface. It can only report a selection
    /// the user already confirmed; otherwise it fails with
    /// `.proposalNotConfirmed` and changes nothing.
    func assistantConfirmSelectionProposal(id: UUID) async throws
        -> GameProjectSelectionSnapshot {
        if lastConfirmedSelectionProposalID == id,
           let snapshot = selectionSnapshot, snapshot.persisted {
            return snapshot
        }
        guard pendingSelectionProposal?.id == id else {
            throw GameProjectFlowError.proposalNotFound
        }
        throw GameProjectFlowError.proposalNotConfirmed
    }

    func discardSelectionProposal(id: UUID? = nil) {
        guard let pendingSelectionProposal else { return }
        guard id == nil || pendingSelectionProposal.id == id else { return }
        self.pendingSelectionProposal = nil
    }

    var isPendingSelectionProposalStale: Bool {
        guard let proposal = pendingSelectionProposal else { return false }
        return proposal.baseRevision != project.revision
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

    /// The selection coordinator performs its own fresh discovery and checks.
    /// Refresh only the saved project here, so a tap does not first perform a
    /// complete independent engine discovery and then repeat it for selection.
    private func prepareForSelection() async throws {
        try requireCurrent()
        guard !operationInProgress else { throw GameAuthoringError.busy }
        let epoch = generation
        if let visualSession { _ = try await visualSession.prepareForHandoff() }
        let saved = try await repository.open(project.projectID, owner: project.owner)
        try Task.checkCancellation(); try requireCurrent()
        guard generation == epoch else { throw GameIDEBridgeError.superseded }
        project = saved
    }

    /// Navigation into the existing IDE needs the owned workspace and any
    /// open visual draft, not another full-game inventory/engine discovery.
    /// The editor and later mutations retain their normal revision checks.
    func prepareForIDE() async throws {
        try requireCurrent()
        guard !operationInProgress else { throw GameAuthoringError.busy }
        let epoch = generation
        if let visualSession {
            let saved = try await visualSession.prepareForHandoff()
            try Task.checkCancellation()
            try requireCurrent()
            guard generation == epoch else { throw GameIDEBridgeError.superseded }
            project = saved
        }
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
