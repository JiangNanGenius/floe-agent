// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameIDEBridge
import FloeGameRunKit
import FloeGameWebKit

/// Request-bound selection over the shared preparer. It never mutates the
/// preparer's default selection for another IDE tab or nested game.
private actor SelectedWorkspaceGamePreparation: GameWebRunPreparationHost {
    let expected: GameWebRunRequest
    let selection: GameRunSelection
    let preparer: GameUnifiedRunPreparer
    init(expected: GameWebRunRequest, selection: GameRunSelection, preparer: GameUnifiedRunPreparer) {
        self.expected = expected; self.selection = selection; self.preparer = preparer
    }
    func prepare(_ request: GameWebRunRequest) async throws -> GamePreparedWebRun {
        guard request == expected else { throw GameProjectError.invalidContext }
        return try await preparer.prepare(request, selection: selection)
    }
    func cancel(_ request: GameWebRunRequest) async {
        guard request == expected else { return }
        await preparer.cancel(request)
    }
}

/// Thin composition of the existing unified preparer and WebKit controller.
/// Retain it in the host's existing game/jobs service, not in a View. Each IDE
/// request owns its controller and cancellation task, including before a player
/// exists. There is no new interpreter, plugin loader or workspace store.
@MainActor public final class ExistingWorkspaceGameWebJobs {
    private struct Entry {
        let controller: GameProjectRunController
        var preparation: Task<Void, any Error>?
    }
    private let contexts: ExistingWorkspaceGameContexts
    private let preparer: GameUnifiedRunPreparer
    private let developerBridge: (@MainActor (GameIDEProjectRunRequest) throws -> GameDeveloperBridgeConfiguration?)?
    private var jobs: [UUID: Entry] = [:]
    private var closed = false

    public init(contexts: ExistingWorkspaceGameContexts, preparer: GameUnifiedRunPreparer,
                developerBridge: (@MainActor (GameIDEProjectRunRequest) throws -> GameDeveloperBridgeConfiguration?)? = nil) {
        self.contexts = contexts; self.preparer = preparer
        self.developerBridge = developerBridge
    }

    public func controller(for requestID: UUID) -> GameProjectRunController? {
        jobs[requestID]?.controller
    }

    public func launch(_ request: GameIDEProjectRunRequest) async throws {
        try Task.checkCancellation()
        guard !closed, jobs[request.id] == nil else { throw GameIDEBridgeError.superseded }
        try request.workspace.validate(context: request.context)
        // Register the cancellable task before the first await. The existing
        // controller validates the real context before preparation and launch.
        let selection = try GameRunSelection(context: request.context, root: request.gameRoot?.value ?? ".")
        let expected = GameWebRunRequest(id: request.id, context: request.context, engine: request.engine)
        let preparation = SelectedWorkspaceGamePreparation(expected: expected, selection: selection, preparer: preparer)
        let controller = GameProjectRunController(contexts: contexts, preparation: preparation)
        controller.developerBridgeConfiguration = try developerBridge?(request)
        let task = Task { try await controller.run(context: request.context, engine: request.engine, requestID: request.id) }
        jobs[request.id] = Entry(controller: controller, preparation: task)
        do {
            try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try Task.checkCancellation()
            guard !closed, jobs[request.id]?.controller === controller else { throw GameIDEBridgeError.superseded }
            jobs[request.id]?.preparation = nil
        } catch {
            if jobs[request.id]?.controller === controller { jobs.removeValue(forKey: request.id) }
            task.cancel()
            _ = await controller.stop(runID: request.id)
            throw error
        }
    }

    public func stop(requestID: UUID) async {
        guard let entry = jobs.removeValue(forKey: requestID) else { return }
        entry.preparation?.cancel()
        _ = await entry.controller.stop(runID: requestID)
        if let task = entry.preparation { _ = await task.result }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        for id in Array(jobs.keys) { await stop(requestID: id) }
    }
}
