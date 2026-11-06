import Foundation
import FloeCanvasCore

/// Controlled in-memory `CanvasStepExecutor` for qualification. It models
/// the contract semantics the real host must honor:
///
/// - Dedupe: submitting the same `(runID, attemptID)` twice performs one
///   scripted execution and returns the same result.
/// - Unconfirmed submission: attempts listed in `unconfirmedAttempts` get
///   `.unknown` — the caller must reconcile, never auto-resend.
/// - Per-step query returns status, outputs, produced assets and the
///   recoverable host task binding for previously submitted attempts.
public actor ControlledStepExecutor: CanvasStepExecutor {
    public struct ScriptedOutcome: Sendable {
        public var status: CanvasStepQueryStatus
        public var outputs: [String: FlowValue]
        public var producedAssets: [CanvasAssetLocator]
        public var error: String?

        public init(
            status: CanvasStepQueryStatus,
            outputs: [String: FlowValue] = [:],
            producedAssets: [CanvasAssetLocator] = [],
            error: String? = nil
        ) {
            self.status = status
            self.outputs = outputs
            self.producedAssets = producedAssets
            self.error = error
        }
    }

    private var submissions: [UUID: CanvasStepExecutionRequest] = [:]
    private var results: [UUID: CanvasStepQueryResult] = [:]
    private var runCheckpoints: [UUID: FlowRunCheckpoint] = [:]
    private let outcomeForNode: (UUID) -> ScriptedOutcome?
    private var unconfirmed: Set<UUID>
    /// Every attempt ID ever submitted, in order — tests assert dedupe.
    public private(set) var performedAttemptIDs: [UUID] = []

    public init(
        outcomeForNode: @escaping (UUID) -> ScriptedOutcome? = { _ in nil },
        unconfirmedAttempts: Set<UUID> = []
    ) {
        self.outcomeForNode = outcomeForNode
        self.unconfirmed = unconfirmedAttempts
    }

    public func submitStep(
        _ request: CanvasStepExecutionRequest
    ) throws -> CanvasStepQueryResult {
        let key = request.attemptID
        if let existing = results[key] {
            return existing
        }
        performedAttemptIDs.append(key)
        submissions[key] = request

        if unconfirmed.contains(key) {
            // Submission may or may not have reached the provider: report
            // unknown without recording a terminal result.
            let result = CanvasStepQueryResult(
                attemptID: key,
                nodeID: request.node.id,
                status: .unknown,
                hostTaskBinding: UUID()
            )
            return result
        }

        let outcome = outcomeForNode(request.node.id) ?? ScriptedOutcome(status: .succeeded)
        let result = CanvasStepQueryResult(
            attemptID: key,
            nodeID: request.node.id,
            status: outcome.status,
            outputs: outcome.outputs,
            producedAssets: outcome.producedAssets,
            hostTaskBinding: UUID(),
            error: outcome.error
        )
        results[key] = result
        return result
    }

    /// Test hook: resolve a previously unconfirmed attempt to a concrete
    /// outcome, modelling host-side reconciliation.
    public func reconcile(attemptID: UUID, outcome: ScriptedOutcome) throws {
        guard submissions[attemptID] != nil else {
            throw CanvasKitError.missingEntity("attempt \(attemptID)")
        }
        guard let request = submissions[attemptID] else { return }
        results[attemptID] = CanvasStepQueryResult(
            attemptID: attemptID,
            nodeID: request.node.id,
            status: outcome.status,
            outputs: outcome.outputs,
            producedAssets: outcome.producedAssets,
            hostTaskBinding: UUID(),
            error: outcome.error
        )
        unconfirmed.remove(attemptID)
    }

    public func queryStep(
        attemptID: UUID,
        runID: UUID
    ) throws -> CanvasStepQueryResult {
        guard let result = results[attemptID] else {
            throw CanvasKitError.missingEntity("attempt \(attemptID)")
        }
        return result
    }

    public func queryRun(runID: UUID) throws -> FlowRunCheckpoint {
        runCheckpoints[runID] ?? FlowRunCheckpoint(runID: runID)
    }

    public func cancelRun(runID: UUID) throws {
        runCheckpoints[runID] = FlowRunCheckpoint(runID: runID)
    }
}
