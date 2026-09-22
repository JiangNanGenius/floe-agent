import Foundation
import FloeCore
import FloeProviders

/// Engine boundary consumed by `LocalModelRuntime`. `MLXTextEngine` is the
/// production implementation; focused lifecycle tests inject a deterministic
/// fake so load/teardown/retry ownership is verifiable without mapping real
/// multi-gigabyte weights on the development machine.
///
/// The protocol deliberately mirrors `MLXTextEngine.completeMeasured` exactly
/// (no default arguments in requirements) so the production actor satisfies
/// the conformance without behavior drift.
protocol LocalModelTextEngine: Sendable {
    /// True when this engine embeds the VLM vision projector and therefore
    /// retains the vision tower weights; text-only engines return false so a
    /// text-only continuation can shed obsolete vision tensors.
    var includesVisionProjector: Bool { get }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult

    /// Drops the mapped model and releases process-wide MLX caches. Called by
    /// the runtime before a replacement load, after the last task finishes,
    /// and on the failure-cleanup path. The requirement is `async` so the
    /// actor-isolated production engine satisfies it without a data-race
    /// crossing; every caller already awaits it.
    func shutdown() async
}

/// Structured, secret-free lifecycle telemetry for the single resident local
/// model. The build-198 device report showed a first turn succeeding and the
/// next turns failing with `decodeFailed`, then `insufficientMemory`, then
/// `MLX container initialization failed`, with no visibility into load
/// ownership, retention, cleanup or the retry path. This value records exactly
/// those transitions so a host log or a focused test can assert the lifecycle
/// without ever logging prompt text, image bytes or credentials.
struct LocalInferenceLifecycleDiagnostics {
    /// One memory observation taken while deciding whether a load is safe.
    /// MLX active/cache bytes are logged by the engine's own prepare and
    /// teardown lines; the sample here stays focused on the allowance the
    /// safety rule consumes.
    struct PreflightSample: Sendable, Equatable {
        let index: Int
        let availableBytes: UInt64
    }

    private(set) var engineCreateCount = 0
    private(set) var engineShutdownCount = 0
    /// Build 222: engines released by the two-minute idle timer rather than by
    /// an explicit unload, a failure or a decode retry.
    private(set) var idleUnloadCount = 0
    private(set) var engineReuseCount = 0
    private(set) var visionShedCount = 0
    private(set) var loadFailureCount = 0
    private(set) var loadRecoveredCount = 0
    private(set) var decodeRetryCount = 0
    private(set) var reclaimCount = 0
    private(set) var preflightRejectCount = 0
    private(set) var consecutiveFailureCount = 0
    private(set) var lastPreflightSamples: [PreflightSample] = []
    private(set) var lastFailureStage: String?
    private(set) var lastFailureDomain: String?
    private(set) var lastFailureCode: Int?

    mutating func recordEngineCreated() { engineCreateCount += 1 }
    mutating func recordEngineShutdown() { engineShutdownCount += 1 }
    mutating func recordIdleUnload() { idleUnloadCount += 1 }
    mutating func recordEngineReused() { engineReuseCount += 1 }
    mutating func recordVisionShed() { visionShedCount += 1 }
    mutating func recordReclaim() { reclaimCount += 1 }

    mutating func recordPreflight(_ samples: [PreflightSample]) {
        lastPreflightSamples = samples
    }

    mutating func recordPreflightRejected() { preflightRejectCount += 1 }

    mutating func recordLoadFailure() { loadFailureCount += 1 }

    mutating func recordLoadRecovered() { loadRecoveredCount += 1 }

    mutating func recordDecodeRetry() { decodeRetryCount += 1 }

    mutating func recordTurnSucceeded() {
        consecutiveFailureCount = 0
        lastFailureStage = nil
        lastFailureDomain = nil
        lastFailureCode = nil
    }

    mutating func recordTurnFailed(stage: String, error: Error) {
        consecutiveFailureCount += 1
        lastFailureStage = stage
        let nsError = error as NSError
        lastFailureDomain = nsError.domain
        lastFailureCode = nsError.code
    }

    /// Compact single-line projection used on failure and in tests. Numeric
    /// and categorical only: model identifiers, byte counts, counters. No
    /// prompt text, no image data, no secrets.
    var summaryLine: String {
        "enginesCreated=\(engineCreateCount) enginesShutdown=\(engineShutdownCount) "
            + "idleUnloads=\(idleUnloadCount) "
            + "engineReuses=\(engineReuseCount) visionSheds=\(visionShedCount) "
            + "loadFailures=\(loadFailureCount) loadRecoveries=\(loadRecoveredCount) "
            + "decodeRetries=\(decodeRetryCount) reclaims=\(reclaimCount) "
            + "preflightRejects=\(preflightRejectCount) consecutiveFailures=\(consecutiveFailureCount) "
            + "lastFailureStage=\(lastFailureStage ?? "none") "
            + "lastFailureDomain=\(lastFailureDomain ?? "none") "
            + "lastFailureCode=\(lastFailureCode.map(String.init) ?? "none") "
            + "lastPreflightSamples=\(lastPreflightSamples.map { "\($0.index):\($0.availableBytes)" }.joined(separator: ","))"
    }
}

extension LocalInferenceLifecycleDiagnostics {
    func log(_ event: String, extra: String = "") {
        let suffix = extra.isEmpty ? "" : " " + extra
        FloeLogger(category: .providers).info(
            "localInferenceLifecycle event=\(event) \(summaryLine)\(suffix)"
        )
    }
}
