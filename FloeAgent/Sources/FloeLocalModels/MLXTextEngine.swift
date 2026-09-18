import Foundation
import Synchronization
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM
import Tokenizers
import FloeCore
import FloeLocalModelCatalog
import FloeProviders

/// Process-wide MLX compiled-trace policy.
///
/// Cloud run 35189276226 (source 43a68eb8) showed that the accepted MLX
/// revision pair retains ~1.3-1.6 GB of live buffers per engine when compiled
/// traces are enabled, and drops to a stable <64 MB settled active set when
/// compile is disabled. This type applies that policy exactly once per
/// process, before any Floe MLX model construction.
///
/// Disabling compiled traces removes an optimization (graph specialization /
/// fusion), not inference: generation still runs, just without the compiled
/// fast path. There is deliberately no per-turn toggle and no environment
/// mutation; the only public mutator is the one-time `applyBeforeModelLoad()`.
@available(macOS 15.4, iOS 26.0, *)
public enum MLXCompilePolicy {
    /// The once-token. Swift initializes a `static let` at most once per
    /// process under the runtime's thread-safe once-token, so concurrent first
    /// model loads cannot race and the mode cannot be flipped per turn.
    private static let disableCompiledTracesOnce: Void = {
        MLX.compile(enable: false)
    }()

    /// Records whether the one-time policy actually ran. `Mutex` keeps the
    /// diagnostic read race-free without unsafe assumptions.
    private static let applied = Mutex<Bool>(false)

    /// Applies the process compile policy. Must be called before any MLX model
    /// or graph construction; repeated and concurrent calls are no-ops.
    public static func applyBeforeModelLoad() {
        _ = disableCompiledTracesOnce
        applied.withLock { $0 = true }
    }

    /// Truthful diagnostic metadata for qualification hosts and logs: `true`
    /// only after this process applied the compile-disabled policy. It reports
    /// the production code path, not an environment variable.
    public static var compiledTracesDisabled: Bool {
        applied.withLock { $0 }
    }
}

/// Serialized MLX inference engine backed by a fully downloaded, revision-
/// pinned Hugging Face snapshot. The catalog owns all network transfer; this
/// type only opens local files and therefore never performs a hidden download.
@available(macOS 15.4, iOS 26.0, *)
public actor MLXTextEngine {
    private var container: ModelContainer?
    private let resourceProfile: LocalInferenceResourceProfile

    /// Blocks until queued MLX work has left the device stream. Freeing the
    /// container or clearing the process-wide cache while an `asyncEval`
    /// still references its buffers is an ownership error; the stream is the
    /// boundary that says the buffers are no longer in flight.
    static func drainMLXPipeline() {
        MLX.Stream.gpu.synchronize()
    }

    /// Hard bound for MLX/runtime text that reaches the diagnostic log. MLX
    /// error strings describe kernels, dtypes, shapes and Metal failures; they
    /// never contain prompt text, but a single-line bounded form keeps the
    /// feedback log readable and cheap to upload.
    nonisolated static func boundedRuntimeDiagnostic(
        _ error: Error,
        limit: Int = 240
    ) -> String {
        let nsError = error as NSError
        var message = error.localizedDescription
        if message.isEmpty { message = "<no description>" }
        message = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if message.count > limit {
            message = String(message.prefix(limit)) + "…"
        }
        return "domain=\(nsError.domain) code=\(nsError.code) message=\(message)"
    }

    /// True when the failure is the caller's cancellation rather than a model
    /// failure. mlx-swift-lm checks `Task.checkCancellation()` between prefill
    /// windows, so an interrupted local turn arrives here as
    /// `CancellationError`; collapsing it into `decodeFailed` made an ordinary
    /// stop look like a broken model in the device log and in the run status.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        if nsError.domain == "Swift.CancellationError" { return true }
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// Teardown variant of `drainMLXPipeline()` plus `Memory.clearCache()`.
    ///
    /// These calls run outside the generation error scope (`defer`,
    /// `shutdown()`, failed load). When MLX observes a queued Metal error
    /// there, the task-local `MLX.withError` handler is empty and MLX's
    /// runtime terminates the process. Teardown must not turn an
    /// already-finished turn into a crash: run it under a scoped handler and
    /// record a bounded diagnostic instead. The failure is not swallowed as a
    /// success — the next request still runs through the full scoped checks.
    nonisolated static func drainPipelineAndClearCaches(
        context: String,
        traceID: String? = nil
    ) {
        do {
            try MLX.withError { errors in
                Self.drainMLXPipeline()
                Memory.clearCache()
                try errors.check()
            }
        } catch {
            FloeLogger(category: .providers).warning(
                "localInferenceTeardownError context=\(context) trace=\(traceID ?? "none") \(boundedRuntimeDiagnostic(error))"
            )
        }
    }

    public init(
        modelDirectory: URL,
        includesVisionProjector: Bool,
        resourceProfile: LocalInferenceResourceProfile
    ) async throws {
        // Must precede every MLX model/graph construction below. MLX caches its
        // global compile mode the first time a compiled trace is built, and on
        // the accepted pins the enabled path retained ~1.3-1.6 GB per engine
        // after shutdown. This one-time disable is the production guard the
        // qualification host verifies; it is not per-turn and never reads or
        // mutates the environment.
        MLXCompilePolicy.applyBeforeModelLoad()
        self.resourceProfile = resourceProfile
        // A previous model or a failed Metal graph can leave process-wide
        // allocations cached even after its Swift container is gone. Start a
        // new load from a known baseline so the preflight allowance describes
        // this model, rather than this model plus stale MLX cache pages.
        Self.drainPipelineAndClearCaches(context: "modelLoadBaseline")
        do {
            // MLX's default error handler exits the process when no scoped
            // handler is installed. Weight loading and graph construction can
            // raise errors in the C++ layer, so this scope is what turns them
            // into a Swift throw instead of a signal.
            let loaded: ModelContainer = try await MLX.withError { errors in
                do {
                    let container: ModelContainer
                    if includesVisionProjector {
                        container = try await VLMModelFactory.shared.loadContainer(
                            from: modelDirectory,
                            using: FloeTokenizerLoader()
                        )
                    } else {
                        // Qwen3.5/3.8 and Gemma 4 snapshots include a vision
                        // tower, but the upstream LLM factory deliberately
                        // strips those weights and remaps language_model.* for
                        // text generation. Loading the full VLM for every
                        // tool/text turn wasted more than a gigabyte and could
                        // terminate the process during the first Metal graph
                        // construction on iPad.
                        container = try await LLMModelFactory.shared.loadContainer(
                            from: modelDirectory,
                            using: FloeTokenizerLoader()
                        )
                    }
                    try errors.check()
                    return container
                } catch {
                    try errors.check()
                    throw error
                }
            }
            self.container = loaded
        } catch {
            // A failed graph/model construction can leave Metal allocations
            // in MLX's process-wide cache even though no container escaped.
            // Clear them before the runtime evaluates or loads another model.
            Self.drainPipelineAndClearCaches(context: "modelLoadFailure")
            let nsError = error as NSError
            // Keep the useful class/code while avoiding model paths or raw
            // provider payloads in the user-visible diagnostic.
            throw LocalInferenceError.modelLoadFailedWithReason(
                "MLX container initialization failed (domain "
                    + nsError.domain
                    + ", code "
                    + String(nsError.code)
                    + "). Verify the model snapshot and device memory, then retry."
            )
        }
    }

    /// Dropping the final container reference releases MLX tensors. The
    /// runtime calls this before loading a replacement and when the last task
    /// finishes so several multi-gigabyte models never remain resident.
    public func shutdown() {
        container = nil
        // Dropping Swift references is not enough: MLX deliberately keeps a
        // process-wide Metal allocation cache for reuse. On iPad that made a
        // 3.8 -> 3.5 switch look like two resident multi-GB models and could
        // end in a jetsam-style termination without a normal crash report.
        Self.drainPipelineAndClearCaches(context: "shutdown")
    }

    public func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data] = [],
        tools: [ToolSchemaDescriptor] = [],
        maxTokens: Int = 1_024,
        // Optional correlation with the caller's existing provider trace.
        // Defaulted so tool/qualification hosts that never pass a trace keep
        // their current call sites unchanged.
        diagnosticTraceID: String? = nil
    ) async throws -> LocalGenerationResult {
        guard let container else { throw LocalInferenceError.contextCreationFailed }
        // Keep the mapped model resident across tool turns, but release Metal
        // scratch buffers and the completed turn's KV cache before the next
        // decode. Device diagnostics showed the process disappearing between
        // a successful tool result and the second decode without a Swift
        // error, which is exactly where retaining both turns' cached pages is
        // most expensive. Drain queued graph work before releasing pages.
        defer {
            Self.drainPipelineAndClearCaches(
                context: "turnTeardown",
                traceID: diagnosticTraceID
            )
        }
        try Task.checkCancellation()
        let startedAt = Date()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mlx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let imageInputs = try images.enumerated().map { index, data -> UserInput.Image in
            let url = temporaryDirectory.appendingPathComponent(
                "image-\(index).\(Self.imageFileExtension(data))"
            )
            try data.write(to: url, options: .atomic)
            return .url(url)
        }
        let prepared: LMInput
        // The tokenizer call consumes its chat input with `consuming sending`,
        // so the value must be built in the same region as the transfer.
        // Building it in the actor and closing over it here made the value
        // task-isolated to the async error scope and the Swift 6.4 region pass
        // rejected the send ("sending 'input' risks causing data races"). Keep
        // the diagnostic on primitive values only and construct the chat input
        // inside the scope where it is consumed.
        let toolSchemas = tools.compactMap(Self.toolSpec)
        let promptCharacters = instructions.count + 1 + prompt.count
        let prepareDiagnostic = "localInferencePrepareStarted trace=\(diagnosticTraceID ?? "none") promptCharacters=\(promptCharacters) images=\(imageInputs.count) tools=\(toolSchemas.count) batchSize=\(resourceProfile.batchSize) contextSize=\(resourceProfile.contextSize) kvBits=\(resourceProfile.tier == .constrained ? 4 : 8) availableMemoryBytes=\(LocalInferenceResourcePolicy.availableMemoryBytes()) mlxActiveBytes=\(Memory.activeMemory) mlxCacheBytes=\(Memory.cacheMemory)"
        FloeLogger(category: .providers).info(prepareDiagnostic)
        do {
            // Tokenizer template + chat-template application. The scoped
            // handler converts anything MLX reports here into a Swift throw
            // instead of letting MLX's default handler exit the process.
            prepared = try await MLX.withError { errors in
                do {
                    let input = UserInput(
                        chat: [
                            .system(instructions),
                            .user(prompt, images: imageInputs)
                        ],
                        tools: toolSchemas,
                        // Qwen 3.x templates enable thinking by default. Floe
                        // routes reasoning privately and the on-device path has
                        // a tight context, so explicitly disable it instead of
                        // relying on a textual /no_think suffix that some VLM
                        // templates ignore.
                        additionalContext: ["enable_thinking": false]
                    )
                    let value = try await container.prepare(input: input)
                    try errors.check()
                    return value
                } catch {
                    try errors.check()
                    throw error
                }
            }
        } catch {
            if Self.isCancellation(error) { throw CancellationError() }
            FloeLogger(category: .providers).warning(
                "localInferencePrepareFailed trace=\(diagnosticTraceID ?? "none") images=\(images.count) \(Self.boundedRuntimeDiagnostic(error))"
            )
            throw images.isEmpty
                ? LocalInferenceError.promptTooLong
                : LocalInferenceError.visionInputFailed
        }

        let effectiveMaximum = min(max(1, maxTokens), resourceProfile.maximumOutputTokens)
        let preparedInputTokens = prepared.text.tokens.dim(-1)
        // Single source of truth so the logged KV precision is exactly what
        // GenerateParameters below will use.
        let kvBits = resourceProfile.tier == .constrained ? 4 : 8
        // Materialize every numeric telemetry value while `prepared` is still a
        // plain local. `FloeLogger.info` takes an `@autoclosure`, so an inline
        // interpolation would let that actor-isolated closure capture the
        // non-Sendable `LMInput` and keep it aliased across the later `sending`
        // transfer to `generatePrepared`, which is the Swift 6.4 region-isolation
        // error at the `prepared` declaration. Reading rank/shape only (never
        // token ids, instructions or prompt text) preserves the privacy boundary.
        let preparedTokensRank = prepared.text.tokens.ndim
        let preparedTokensShape = prepared.text.tokens.shape
        // Numeric-only prefill diagnostics, emitted after the real tokenizer
        // has prepared the prompt and before the context guard can reject it.
        // The message is fully built as a `String` here, so the logger
        // autoclosure captures only `Sendable` values, never `prepared`.
        // `mlxProcessPeakBytes` is MLX's process-wide cumulative peak since
        // program start, NOT this turn's peak.
        // `mlxCompilePolicy` is emitted with every prepared turn so a host log
        // proves compiled traces are disabled by the production policy rather
        // than by an environment variable. See `MLXCompilePolicy`.
        let compilePolicyLabel = MLXCompilePolicy.compiledTracesDisabled
            ? "disabled-by-process-policy"
            : "not-applied"
        let preparedDiagnostic =
            "localInferencePrepared trace=\(diagnosticTraceID ?? "none") inputTokens=\(preparedInputTokens) effectiveMaxTokens=\(effectiveMaximum) contextSize=\(resourceProfile.contextSize) batchSize=\(resourceProfile.batchSize) kvBits=\(kvBits) tokensRank=\(preparedTokensRank) tokensShape=\(preparedTokensShape) availableMemoryBytes=\(LocalInferenceResourcePolicy.availableMemoryBytes()) mlxActiveBytes=\(Memory.activeMemory) mlxCacheBytes=\(Memory.cacheMemory) mlxProcessPeakBytes=\(Memory.peakMemory) mlxCompilePolicy=\(compilePolicyLabel)"
        FloeLogger(category: .providers).info(preparedDiagnostic)
        // A simple quantized cache is not rotating, so enforce the device
        // context before asking MLX to allocate it. The prepared token shape
        // includes chat-template overhead and native tool schemas, unlike a
        // character estimate of the visible prompt.
        guard preparedInputTokens + effectiveMaximum <= Int(resourceProfile.contextSize) else {
            throw LocalInferenceError.promptTooLong
        }
        let parameters = GenerateParameters(
            maxTokens: effectiveMaximum,
            // MLX uses RotatingKVCache whenever maxKVSize is non-nil, and that
            // cache is not quantized by the current upstream implementation.
            // Leave it nil so kvBits actually applies to KVCacheSimple.
            maxKVSize: nil,
            kvBits: kvBits,
            temperature: 0.55,
            topP: 0.95,
            repetitionPenalty: 1.05,
            // The resource policy's batch size is the prompt prefill chunk,
            // not a decorative catalog value. Gemma's constrained profile is
            // intentionally 32 instead of MLX's 512-token default.
            prefillStepSize: Int(resourceProfile.batchSize)
        )
        return try await generatePrepared(
            container: container,
            input: prepared,
            parameters: parameters,
            inputTokens: preparedInputTokens,
            startedAt: startedAt,
            diagnosticTraceID: diagnosticTraceID
        )
    }

    /// Keep the stream and its live KV cache in a nested scope. When this
    /// helper returns (or throws), those references are destroyed before the
    /// caller's `Memory.clearCache()` defer runs, so freed pages cannot simply
    /// fall back into MLX's process-wide cache after it was cleared.
    private nonisolated func generatePrepared(
        container: ModelContainer,
        input: sending LMInput,
        parameters: GenerateParameters,
        inputTokens: Int,
        startedAt: Date,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        // MLX's C error callback calls fatalError when no task-local handler
        // exists. A Swift do/catch alone cannot catch that callback. Keep the
        // scope across prefill and the inherited generation task, then check
        // before consuming each event so an invalid graph cannot report success.
        let transfer = Mutex<LMInput?>(input)
        return try await MLX.withError { errors in
            let prepared = transfer.withLock { value in
                let result = value!
                value = nil
                return result
            }
            return try await generateGuarded(container: container, input: prepared,
                parameters: parameters, inputTokens: inputTokens,
                startedAt: startedAt, errors: errors,
                diagnosticTraceID: diagnosticTraceID)
        }
    }

    private nonisolated func generateGuarded(
        container: ModelContainer,
        input: sending LMInput,
        parameters: GenerateParameters,
        inputTokens: Int,
        startedAt: Date,
        errors: MLX.ErrorBox,
        diagnosticTraceID: String?
    ) async throws -> LocalGenerationResult {
        let stream: AsyncStream<Generation>
        do {
            // `container.generate` runs the chunked prefill inside
            // mlx-swift-lm's `LLMModel.prepare` before it returns this stream.
            // The build-191 report symbolicated the terminated prefill to
            // TokenIterator.prepare -> LLMModel.prepare -> withPreparedCache ->
            // Qwen35GatedDeltaNet.forward -> gatedDeltaUpdate, i.e. this exact
            // call. A scoped handler converts every error MLX reports here into
            // a Swift throw; it cannot catch a Metal command-buffer failure
            // raised off the calling task (that stays an upstream residual).
            stream = try await container.generate(input: input, parameters: parameters)
            try errors.check()
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
            FloeLogger(category: .providers).warning(
                "localInferencePrefillFailed trace=\(diagnosticTraceID ?? "none") inputTokens=\(inputTokens) batchSize=\(parameters.prefillStepSize ?? 0) availableMemoryBytes=\(LocalInferenceResourcePolicy.availableMemoryBytes()) mlxActiveBytes=\(Memory.activeMemory) \(Self.boundedRuntimeDiagnostic(error))"
            )
            throw LocalInferenceError.decodeFailed
        }
        // Prefill and the priming step are complete; without this marker a
        // device report cannot tell a prefill crash from a decode crash.
        FloeLogger(category: .providers).info(
            "localInferencePrefillCompleted trace=\(diagnosticTraceID ?? "none") inputTokens=\(inputTokens) prefillMs=\(max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))) availableMemoryBytes=\(LocalInferenceResourcePolicy.availableMemoryBytes()) mlxActiveBytes=\(Memory.activeMemory) mlxCacheBytes=\(Memory.cacheMemory)"
        )

        var text = ""
        var firstTokenAt: Date?
        var info: GenerateCompletionInfo?
        for await event in stream {
            if Task.isCancelled { throw CancellationError() }
            do {
                try errors.check()
            } catch {
                if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                FloeLogger(category: .providers).warning(
                    "localInferenceDecodeFailed trace=\(diagnosticTraceID ?? "none") stage=stream \(Self.boundedRuntimeDiagnostic(error))"
                )
                throw LocalInferenceError.decodeFailed
            }
            switch event {
            case .chunk(let chunk):
                if firstTokenAt == nil, !chunk.isEmpty { firstTokenAt = Date() }
                text += chunk
            case .info(let completionInfo):
                info = completionInfo
            case .toolCall(let call):
                // Floe's provider-neutral harness already parses this compact
                // envelope and applies the normal approval path.
                if let encoded = Self.encodeToolCall(call) {
                    if firstTokenAt == nil { firstTokenAt = Date() }
                    text += encoded
                }
            }
        }
        do {
            try errors.check()
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
            FloeLogger(category: .providers).warning(
                "localInferenceDecodeFailed trace=\(diagnosticTraceID ?? "none") stage=final \(Self.boundedRuntimeDiagnostic(error))"
            )
            throw LocalInferenceError.decodeFailed
        }
        let endedAt = Date()
        let outputTokens = info?.generationTokenCount ?? Self.estimatedTokens(text)
        let generationDurationMs = info.map { max(1, Int($0.generateTime * 1_000)) }
            ?? max(1, Int(endedAt.timeIntervalSince(firstTokenAt ?? startedAt) * 1_000))
        return LocalGenerationResult(
            text: text,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            timeToFirstTokenMs: firstTokenAt.map {
                max(0, Int($0.timeIntervalSince(startedAt) * 1_000))
            },
            generationDurationMs: generationDurationMs
        )
    }

    private static func encodeToolCall(_ call: MLXLMCommon.ToolCall) -> String? {
        guard let arguments = try? JSONSerialization.data(
            withJSONObject: call.function.arguments.mapValues(\.anyValue),
            options: [.sortedKeys]
        ), let argumentsText = String(data: arguments, encoding: .utf8) else { return nil }
        return "{\"tool_call\":{\"name\":\(jsonString(call.function.name)),\"arguments\":\(argumentsText)}}"
    }

    /// Convert Floe's provider-neutral descriptor into the OpenAI-style
    /// schema consumed by MLX chat templates. Invalid schemas are omitted so a
    /// single plugin cannot make every local turn fail before generation.
    private static func toolSpec(_ descriptor: ToolSchemaDescriptor) -> ToolSpec? {
        guard let data = descriptor.parametersJSON.data(using: .utf8),
              let parameters = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = parameters else { return nil }
        return [
            "type": "function",
            "function": [
                "name": descriptor.name,
                "description": descriptor.description,
                "parameters": sendableValue(parameters)
            ] as [String: any Sendable]
        ]
    }

    private static func sendableValue(_ value: JSONValue) -> any Sendable {
        switch value {
        case .null: NSNull()
        case .bool(let value): value
        case .int(let value): value
        case .double(let value): value
        case .string(let value): value
        case .array(let values): values.map(sendableValue)
        case .object(let values): values.mapValues(sendableValue)
        }
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return text
    }

    private static func estimatedTokens(_ text: String) -> Int {
        max(1, Int(ceil(Double(text.utf8.count) / 3.2)))
    }

    private static func imageFileExtension(_ data: Data) -> String {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if data.count >= 12,
           String(data: data.subdata(in: 4..<12), encoding: .ascii)?.contains("ftyp") == true {
            return "heic"
        }
        return "img"
    }
}

/// The upstream convenience tokenizer loader is currently exposed only as a
/// compiler macro. Xcode 27 beta can incorrectly compile that host macro for
/// the iOS destination, which breaks an otherwise valid archive before Floe's
/// sources are reached. Keep the same runtime behavior with a small direct
/// adapter over swift-transformers and avoid shipping a compiler plugin as an
/// app dependency.
private struct FloeTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return FloeTokenizerAdapter(tokenizer)
    }
}

private struct FloeTokenizerAdapter: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
