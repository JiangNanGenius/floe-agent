// API-shape and ordering probe for `LocalModelRuntime.completeMeasured`.
//
// The real `LocalProviderAdapter.swift` cannot be compiled on this host (it
// imports `FloeCore`/`FloeModels`/`FloeProviders`/`FloeLocalModelCatalog`
// modules that only exist in a full build), so this probe mirrors the exact
// production sequence against the same production lifecycle types:
//
//     foreground gate → register → create task → attach → await value
//
// The runner compiles it together with the real canceller source and emits
// SIL/object, which exercises Swift 6 isolation and `sending` diagnostics for
// the pattern without a heavy App build. It is not an App compile; the
// ordering itself is additionally asserted textually against the real file.
import Foundation

struct PatternGenerationResult: Sendable {
    var text: String
}

actor PatternEngine {
    func completeMeasured() async throws -> PatternGenerationResult {
        PatternGenerationResult(text: "ok")
    }
}

func patternRuntime(engine: PatternEngine) async throws -> PatternGenerationResult {
    // Mirror of the advisory gate before mapping weights.
    guard await LocalInferenceBackgroundCanceller.shared.isForegroundEligible() else {
        throw CancellationError()
    }
    // Mirror of the production order: register before the GPU task exists.
    let relay = LocalInferenceCancellationRelay()
    guard let cancelToken = await LocalInferenceBackgroundCanceller.shared.registerForeground(
        traceID: "pattern",
        cancel: { relay.requestCancellation() }
    ) else {
        throw CancellationError()
    }
    defer { LocalInferenceBackgroundCanceller.shared.unregister(cancelToken) }
    let generation = Task {
        try await engine.completeMeasured()
    }
    if relay.attach({ generation.cancel() }) {
        generation.cancel()
    }
    // Mirror of `withTaskCancellationHandler`: caller cancellation keeps
    // working for the unstructured generation task.
    return try await withTaskCancellationHandler {
        try await generation.value
    } onCancel: {
        relay.requestCancellation()
    }
}
