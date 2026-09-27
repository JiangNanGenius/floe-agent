import Foundation
import FloeCore
import FloeProviders

/// One bounded, secret-free progress observation from a local generation.
/// The engine emits these while a turn is still inside prefill (the long
/// silent window on iPad) so the adapter can publish truthful stage progress
/// before the first answer token instead of buffering the whole turn.
///
/// The payload is deliberately numeric/categorical only — no prompt text, no
/// generated content — and emissions are throttled by the engine, so a long
/// prefill cannot turn the diagnostic or UI channel into a hot loop.
public struct LocalInferenceProgress: Sendable, Equatable {
    public enum Stage: String, Sendable, Equatable {
        /// Chat-template application and tokenization.
        case preparing
        /// Chunked prompt prefill into the KV cache (`prefilledTokens` of
        /// `totalInputTokens`); this is the multi-second silent window that
        /// Build 230 reported as "the local model never replies".
        case prefill
        /// Autoregressive decode has produced at least one token.
        case decoding
    }

    public var stage: Stage
    public var prefilledTokens: Int
    public var totalInputTokens: Int
    /// Number of upstream MLX `.chunk`/`.toolCall` events produced so far
    /// (0 during prefill). This is an EVENT count, not a model token count:
    /// a chunk may carry several sampled tokens or a multi-byte piece, and
    /// the authoritative output-token total only arrives in the terminal
    /// `.info` event, which the completion value reports. It exists for
    /// liveness display only and is never published as usage.
    public var emittedChunks: Int

    public init(
        stage: Stage,
        prefilledTokens: Int = 0,
        totalInputTokens: Int = 0,
        emittedChunks: Int = 0
    ) {
        self.stage = stage
        self.prefilledTokens = prefilledTokens
        self.totalInputTokens = totalInputTokens
        self.emittedChunks = emittedChunks
    }
}

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

    /// True when the engine observed an UNCLEAN teardown: a queued MLX/Metal
    /// error surfaced while draining a completed turn. The turn's result was
    /// already returned (its text may be valid), but the drain error is logged
    /// and surfaced through this flag — it is never silently treated as a
    /// clean drain. `LocalModelRuntime` recreates the container before the
    /// next message and releases it as soon as its last claim drops, instead
    /// of leaving a possibly poisoned mapping resident through the idle
    /// window (the Build 228 "successful first answer, second message fails"
    /// class). Default false keeps the accepted clean container-reuse
    /// behavior.
    var requiresCleanReload: Bool { get }

    func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult

    /// Streaming generation. Engines forward generated answer text and tool
    /// envelopes as they are decoded (MLX) and emit bounded prefill progress,
    /// instead of buffering the entire turn until the stream finishes.
    ///
    /// `onOutput` is `@Sendable` and called on the engine's inference
    /// executor; implementations MUST throttle calls and MUST NOT deliver
    /// anything after the call returns or throws. The returned value carries
    /// the full text and final measurements exactly as `completeMeasured`.
    ///
    /// A default implementation keeps deterministic test doubles and any
    /// future engine working: it runs the buffered call and delivers the
    /// complete text as one output chunk.
    func streamMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?,
        onProgress: @escaping @Sendable (LocalInferenceProgress) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> LocalGenerationResult

    /// Drops the mapped model and releases process-wide MLX caches. Called by
    /// the runtime before a replacement load, after the last task finishes,
    /// and on the failure-cleanup path. The requirement is `async` so the
    /// actor-isolated production engine satisfies it without a data-race
    /// crossing; every caller already awaits it.
    func shutdown() async
}

extension LocalModelTextEngine {
    /// Clean-turn default for deterministic test doubles and any future
    /// engine that does not track teardown state.
    var requiresCleanReload: Bool { false }

    /// Buffered fallback: engines that do not implement chunked streaming
    /// still satisfy the boundary by delivering their full text once. It is
    /// strictly more informative than the old all-at-once adapter behavior
    /// but keeps the deterministic fakes unchanged. The single delivery is
    /// safe under cancellation because it happens before the call returns.
    func streamMeasured(
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int,
        diagnosticTraceID: String?,
        onProgress: @escaping @Sendable (LocalInferenceProgress) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> LocalGenerationResult {
        let result = try await completeMeasured(
            instructions: instructions,
            prompt: prompt,
            images: images,
            tools: tools,
            maxTokens: maxTokens,
            diagnosticTraceID: diagnosticTraceID
        )
        onProgress(LocalInferenceProgress(stage: .decoding, emittedChunks: 1))
        onOutput(result.text)
        return result
    }
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
    /// Engines physically released by an explicit Linux resource demand while
    /// durable runs kept their logical claims (`yieldIdleResidentEngineForLinux`).
    /// Deliberately distinct from `idleUnloadCount`: the yield path is the one
    /// release that may unmap an engine a retained run still owns, and device
    /// logs/tests must be able to tell the two policies apart.
    private(set) var linuxYieldCount = 0
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
    mutating func recordLinuxYield() { linuxYieldCount += 1 }
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
            + "linuxYields=\(linuxYieldCount) "
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
