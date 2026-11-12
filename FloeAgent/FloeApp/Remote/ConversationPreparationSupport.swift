import Foundation
import FloeAgentRuntime

/// A construction failure or a rejected idle service releases only the exact
/// acquired lease. Successful services retain the owner in terminal cleanup.
/// The once gate also makes late ARC/terminal cleanup harmless.
final class ConversationRunResourceLease: @unchecked Sendable {
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?

    init(_ cleanup: @escaping @Sendable () -> Void) { self.cleanup = cleanup }

    func finish() {
        lock.lock()
        let cleanup = self.cleanup
        self.cleanup = nil
        lock.unlock()
        cleanup?()
    }

    deinit { finish() }
}

/// App-owned, serial and coalesced maintenance. A cancelled producer keeps
/// its slot until it actually returns; later requests cannot overlap it.
/// Overflow leaves the persisted cadence due for a later completion.
@MainActor
final class ConversationPersonalizationMaintenance {
    private struct Scope: Hashable, Sendable { let workspaceID: UUID? }
    private struct Request: Sendable {
        let scope: Scope
        let operation: @Sendable () async -> Void
    }
    private struct Active: Sendable {
        let scope: Scope
        let generation: UUID
        let task: Task<Void, Never>
    }
    private var active: Active?
    private var pending: [Request] = []
    private let maximumPendingScopes = 8

    var isIdle: Bool { active == nil && pending.isEmpty }

    @discardableResult
    func enqueue(workspaceID: UUID?, operation: @escaping @Sendable () async -> Void) -> Bool {
        let scope = Scope(workspaceID: workspaceID)
        guard active?.scope != scope, !pending.contains(where: { $0.scope == scope }),
              pending.count < maximumPendingScopes else { return false }
        pending.append(Request(scope: scope, operation: operation))
        startNext()
        return true
    }

    func cancel() {
        pending.removeAll()
        active?.task.cancel()
        // Never free an active producer's slot on the cancellation signal.
    }

    private func startNext() {
        guard active == nil, !pending.isEmpty else { return }
        let request = pending.removeFirst()
        let generation = UUID()
        let task = Task { [weak self] in
            if !Task.isCancelled { await request.operation() }
            self?.finished(generation)
        }
        active = Active(scope: request.scope, generation: generation, task: task)
    }

    private func finished(_ generation: UUID) {
        guard active?.generation == generation else { return }
        active = nil
        startNext()
    }

    deinit { active?.task.cancel() }
}

/// Preserve existing cadence/CAS, and fence a delayed model result before
/// it can reach generateIfDue's publication boundary. Disabling automatic
/// updates or cancelling the maintenance owner discards that late result.
struct ConversationMaintenanceGenerator: PersonalizationGenerator {
    let base: any PersonalizationGenerator
    let documents: SQLitePersonalizationStore

    func generate(_ request: PersonalizationGenerationRequest) async throws -> PersonalizationGenerationResult {
        try Task.checkCancellation()
        guard try await documents.cursor(kind: request.kind, workspaceID: request.workspaceID)
            .automaticUpdatesEnabled else { throw CancellationError() }
        let result = try await base.generate(request)
        try Task.checkCancellation()
        guard try await documents.cursor(kind: request.kind, workspaceID: request.workspaceID)
            .automaticUpdatesEnabled else { throw CancellationError() }
        try Task.checkCancellation()
        return result
    }
}
