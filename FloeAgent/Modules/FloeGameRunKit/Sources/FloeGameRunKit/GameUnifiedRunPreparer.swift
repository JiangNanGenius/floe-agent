// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameWebKit

/// Unified, reusable run preparer for IDE/Space. It implements the existing
/// `GameWebRunPreparationHost` contract, so it plugs into
/// `GameProjectRunController` without changing the controller or the player.
///
/// Selection is scoped by project/owner/saved revision. A host that supports a
/// nested imported root calls `select` before starting a run; a missing
/// selection always means the repository root. No global "current project" is
/// used, and every prepared artifact is keyed by the controller's request ID.
public actor GameUnifiedRunPreparer: GameWebRunPreparationHost {
    public let configuration: GameRunPreparationConfiguration
    private struct Job: Sendable {
        let token: UUID
        let task: Task<GamePreparedWebRun, any Error>
    }
    private struct SelectionKey: Hashable, Sendable {
        let projectID: UUID
        let owner: GameProjectOwner
    }
    private var jobs: [UUID: Job] = [:]
    private var selections: [SelectionKey: GameRunSelection] = [:]

    public init(configuration: GameRunPreparationConfiguration) throws {
        if FileManager.default.fileExists(atPath: configuration.artifactDirectory.path) {
            let values = try configuration.artifactDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw GameRunPreparationError.invalidConfiguration(
                    "artifact directory must be a real directory")
            }
        }
        self.configuration = configuration
    }

    /// Sets the selected root for this project. The selection carries the
    /// saved revision it was made against; a later run at a different revision
    /// is rejected instead of silently falling back to the repository root.
    public func select(_ selection: GameRunSelection) {
        selections[SelectionKey(projectID: selection.projectID, owner: selection.owner)] = selection
    }

    public func clearSelection(context: GameProjectContext) {
        selections.removeValue(forKey: SelectionKey(
            projectID: context.projectID, owner: context.owner))
    }

    private func selectedRoot(context: GameProjectContext) throws -> GameRunSelection? {
        guard let selection = selections[SelectionKey(projectID: context.projectID,
                                                      owner: context.owner)] else {
            return nil
        }
        guard selection.savedRevision == context.savedRevision else {
            throw GameRunPreparationError.selectionContextMismatch
        }
        return selection
    }

    /// Readiness/planning for host UI. This performs the real bounded scan and
    /// never starts a player, a build job or a download.
    public func plan(context: GameProjectContext, engine: GameEngineID) async throws -> GameRunRoutePlan {
        let choice = try selectedRoot(context: context)
        return try await GameRunPreparationEngine(configuration: configuration)
            .plan(context: context, engine: engine, selection: choice)
    }

    public func plan(context: GameProjectContext, engine: GameEngineID,
                     selection: GameRunSelection) async throws -> GameRunRoutePlan {
        try await GameRunPreparationEngine(configuration: configuration)
            .plan(context: context, engine: engine, selection: selection)
    }

    public func prepare(_ request: GameWebRunRequest) async throws -> GamePreparedWebRun {
        try await prepare(request, selection: selectedRoot(context: request.context))
    }

    /// Captures a request's explicit root without changing another IDE/run's
    /// default selection. Two requests at the same revision may choose
    /// different nested games; an awaited select/prepare pair is insufficient.
    public func prepare(_ request: GameWebRunRequest, selection: GameRunSelection?) async throws -> GamePreparedWebRun {
        guard jobs[request.id] == nil else {
            throw GameRunPreparationError.duplicateRequest
        }
        try selection?.validate(context: request.context)
        let choice = selection
        let engine = GameRunPreparationEngine(configuration: configuration)
        let requestCopy = request
        let task = Task.detached(priority: .userInitiated) {
            try await engine.prepare(request: requestCopy, selection: choice)
        }
        let token = UUID()
        jobs[request.id] = Job(token: token, task: task)
        defer {
            if jobs[request.id]?.token == token { jobs.removeValue(forKey: request.id) }
        }
        return try await withTaskCancellationHandler(
            operation: { try await task.value },
            onCancel: { task.cancel() })
    }

    /// Waits for the owned preparation to finish and only then returns. A late
    /// job can never write into a newer project because its target, staging and
    /// context were captured at request start.
    public func cancel(_ request: GameWebRunRequest) async {
        guard let job = jobs[request.id] else { return }
        job.task.cancel()
        _ = await job.task.result
        if jobs[request.id]?.token == job.token {
            jobs.removeValue(forKey: request.id)
        }
    }
}
