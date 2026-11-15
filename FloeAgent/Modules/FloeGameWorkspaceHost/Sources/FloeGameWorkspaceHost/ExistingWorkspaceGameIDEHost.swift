// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore
import FloeGameIDEBridge

/// Existing App navigation and jobs are injected, including the authoritative
/// active workspace getter. These callbacks never select a workspace from an
/// imported project, create an editor or execute a language on the native host.
@MainActor public struct ExistingWorkspaceGameIDEActions {
    public let currentWorkspace: @MainActor () -> GameIDEWorkspacePin?
    public let open: @MainActor (GameIDEOpenRequest) throws -> Void
    public let launch: @MainActor (GameIDEProjectRunRequest) async throws -> Void
    public let stop: @MainActor (UUID) async -> Void

    public init(currentWorkspace: @escaping @MainActor () -> GameIDEWorkspacePin?,
                open: @escaping @MainActor (GameIDEOpenRequest) throws -> Void,
                launch: @escaping @MainActor (GameIDEProjectRunRequest) async throws -> Void,
                stop: @escaping @MainActor (UUID) async -> Void) {
        self.currentWorkspace = currentWorkspace; self.open = open
        self.launch = launch; self.stop = stop
    }
}

/// Concrete extension host over the SAME live repository and revision tracker
/// as the native editor and AI. The App retains its existing scope/job lease
/// until close() and in-flight launch cleanup have finished.
@MainActor public final class ExistingWorkspaceGameIDEHost: GameIDEProjectHost {
    public let workspace: GameIDEWorkspacePin
    private let target: ExistingGameWorkspaceTarget
    private let repository: FileGameProjectRepository
    private let actions: ExistingWorkspaceGameIDEActions
    private var visualSession: GameEditingSession?
    private enum RunState: Equatable { case preparing, active, cancelled }
    private var runs: [UUID: RunState] = [:]
    public private(set) var isClosed = false

    public init(workspace: GameIDEWorkspacePin, target: ExistingGameWorkspaceTarget,
                repository: FileGameProjectRepository, actions: ExistingWorkspaceGameIDEActions,
                visualSession: GameEditingSession? = nil) throws {
        guard workspace == target.revisions.binding,
              workspace.projectID == target.binding.projectID,
              workspace.workspaceID == target.binding.workspaceID,
              workspace.owner == target.binding.owner,
              workspace.rootURL == target.binding.rootURL,
              workspace.environmentID == target.binding.environmentID else { throw GameIDEBridgeError.workspaceChanged }
        self.workspace = workspace; self.target = target
        self.repository = repository; self.actions = actions
        try attachVisualSession(visualSession)
    }

    /// Replacing a dirty/busy session is never an implicit discard. The caller
    /// saves or explicitly resolves its draft/conflicts before replacing it.
    public func attachVisualSession(_ session: GameEditingSession?) throws {
        guard !isClosed else { throw GameIDEBridgeError.workspaceChanged }
        if let current = visualSession, current !== session, hasPendingEdits(current) {
            throw GameIDEBridgeError.unsavedChanges
        }
        if let session {
            guard session.projectID == workspace.projectID, session.owner == workspace.owner,
                  session.repository === repository else { throw GameIDEBridgeError.workspaceChanged }
        }
        visualSession = session
    }

    public func currentWorkspace() -> GameIDEWorkspacePin? {
        guard !isClosed else { return nil }
        let actual = actions.currentWorkspace()
        target.revisions.noteWorkspaceChanged(to: actual)
        return actual
    }

    public func open(_ request: GameIDEOpenRequest) throws {
        try ensureCurrent()
        guard request.workspace == workspace else { throw GameIDEBridgeError.workspaceChanged }
        try ensureVisualSaved()
        try actions.open(request)
        try ensureCurrent()
    }

    /// For the overview's Files/Code/Git actions. The visual surface's own
    /// Open IDE action has already prepared its session and may call open().
    public func openAfterSaving(_ destination: GameIDEDestination) async throws {
        try await prepareVisualEditing()
        try Task.checkCancellation()
        try open(.init(workspace: workspace, destination: destination))
    }

    public func snapshot(_ expected: GameIDEWorkspacePin) async throws -> GameProjectContext {
        try Task.checkCancellation()
        try ensureCurrent(); try ensureVisualSaved()
        guard expected == workspace else { throw GameIDEBridgeError.workspaceChanged }
        let checkpoint = try target.revisions.checkpoint()
        let opened = try await repository.openWorkingProject(workspace.projectID, owner: workspace.owner)
        try Task.checkCancellation()
        try ensureCurrent(); try ensureVisualSaved()
        try target.revisions.validate(checkpoint)
        guard opened.binding == target.binding else { throw GameIDEBridgeError.workspaceChanged }
        return try .init(projectID: opened.project.projectID, owner: opened.project.owner,
            rootURL: opened.binding.rootURL, savedRevision: opened.project.revision,
            environmentID: opened.binding.environmentID)
    }

    /// One instance belongs to one existing IDE presentation. Its stop action
    /// stops only its own request, including a launch that returns late.
    public func ideRunExtension(engine: GameEngineID, gameRoot: GameRelativePath? = nil) -> IDEProjectRunExtension {
        let bridge = GameIDEProjectExtension(workspace: workspace, host: self)
        return .init(run: { [self] saveAll in
            try await prepareVisualEditing()
            try await bridge.run(engine: engine, gameRoot: gameRoot, saveAllSurfaces: saveAll)
        }, stop: { await bridge.stop() })
    }

    public func launch(_ request: GameIDEProjectRunRequest) async throws {
        try ensureCurrent(); try ensureVisualSaved()
        guard request.workspace == workspace, runs[request.id] == nil else { throw GameIDEBridgeError.workspaceChanged }
        runs[request.id] = .preparing
        do {
            try request.context.validate(current: await snapshot(workspace))
            try Task.checkCancellation()
            guard runs[request.id] == .preparing else { throw GameIDEBridgeError.superseded }
            try await actions.launch(request)
            try Task.checkCancellation()
            try ensureCurrent(); try ensureVisualSaved()
            guard runs[request.id] == .preparing else { throw GameIDEBridgeError.superseded }
            try request.context.validate(current: await snapshot(workspace))
            guard runs[request.id] == .preparing else { throw GameIDEBridgeError.superseded }
            runs[request.id] = .active
        } catch {
            runs.removeValue(forKey: request.id)
            // Always repeat cleanup after an in-flight launch returns: an
            // earlier stop may have reached the job service before creation.
            await actions.stop(request.id)
            throw error
        }
    }

    public func stop(requestID: UUID) async {
        guard let state = runs[requestID] else { return }
        switch state {
        case .active: runs.removeValue(forKey: requestID)
        case .preparing, .cancelled: runs[requestID] = .cancelled
        }
        await actions.stop(requestID)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        target.revisions.close()
        let owned = Array(runs.keys)
        for id in owned {
            if runs[id] == .active { runs.removeValue(forKey: id) }
            else { runs[id] = .cancelled }
        }
        for id in owned { await actions.stop(id) }
    }

    private func prepareVisualEditing() async throws {
        try ensureCurrent()
        if let session = visualSession { _ = try await session.prepareForHandoff() }
        try ensureCurrent(); try ensureVisualSaved()
    }
    private func ensureCurrent() throws {
        guard !isClosed, currentWorkspace() == workspace else { throw GameIDEBridgeError.workspaceChanged }
        _ = try target.revisions.checkpoint()
    }
    private func ensureVisualSaved() throws {
        if let session = visualSession, hasPendingEdits(session) { throw GameIDEBridgeError.unsavedChanges }
    }
    private func hasPendingEdits(_ session: GameEditingSession) -> Bool {
        session.isBusy || session.isDirty || session.pendingDraft != nil || session.conflict != nil || !session.fileConflicts.isEmpty
    }
}
