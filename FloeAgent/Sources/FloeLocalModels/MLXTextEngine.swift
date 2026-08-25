import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import MLXVLM
import Tokenizers
import FloeLocalModelCatalog
import FloeProviders

/// Serialized MLX inference engine backed by a fully downloaded, revision-
/// pinned Hugging Face snapshot. The catalog owns all network transfer; this
/// type only opens local files and therefore never performs a hidden download.
@available(macOS 15.4, iOS 26.0, *)
public actor MLXTextEngine {
    private var container: ModelContainer?
    private let resourceProfile: LocalInferenceResourceProfile

    public init(
        modelDirectory: URL,
        includesVisionProjector: Bool,
        resourceProfile: LocalInferenceResourceProfile
    ) async throws {
        self.resourceProfile = resourceProfile
        // A previous model or a failed Metal graph can leave process-wide
        // allocations cached even after its Swift container is gone. Start a
        // new load from a known baseline so the preflight allowance describes
        // this model, rather than this model plus stale MLX cache pages.
        Memory.clearCache()
        do {
            if includesVisionProjector {
                self.container = try await VLMModelFactory.shared.loadContainer(
                    from: modelDirectory,
                    using: FloeTokenizerLoader()
                )
            } else {
                // Qwen3.5/3.8 and Gemma 4 snapshots include a vision tower,
                // but the upstream LLM factory deliberately strips those
                // weights and remaps language_model.* for text generation.
                // Loading the full VLM for every tool/text turn wasted more
                // than a gigabyte and could terminate the process during the
                // first Metal graph construction on iPad.
                self.container = try await LLMModelFactory.shared.loadContainer(
                    from: modelDirectory,
                    using: FloeTokenizerLoader()
                )
            }
        } catch {
            // A failed graph/model construction can leave Metal allocations
            // in MLX's process-wide cache even though no container escaped.
            // Clear them before the runtime evaluates or loads another model.
            Memory.clearCache()
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
        Memory.clearCache()
    }

    public func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data] = [],
        tools: [ToolSchemaDescriptor] = [],
        maxTokens: Int = 1_024
    ) async throws -> LocalGenerationResult {
        guard let container else { throw LocalInferenceError.contextCreationFailed }
        // Keep the mapped model resident across tool turns, but release Metal
        // scratch buffers and the completed turn's KV cache before the next
        // decode. Device diagnostics showed the process disappearing between
        // a successful tool result and the second decode without a Swift
        // error, which is exactly where retaining both turns' cached pages is
        // most expensive.
        defer { Memory.clearCache() }
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
        let input = UserInput(
            chat: [
                .system(instructions),
                .user(prompt, images: imageInputs)
            ],
            tools: tools.compactMap(Self.toolSpec),
            // Qwen 3.x templates enable thinking by default. Floe routes
            // reasoning privately and the on-device path has a tight context,
            // so explicitly disable it instead of relying on a textual
            // /no_think suffix that some VLM templates ignore.
            additionalContext: ["enable_thinking": false]
        )
        let prepared: LMInput
        do {
            prepared = try await container.prepare(input: input)
        } catch {
            throw images.isEmpty
                ? LocalInferenceError.promptTooLong
                : LocalInferenceError.visionInputFailed
        }

        let effectiveMaximum = min(max(1, maxTokens), resourceProfile.maximumOutputTokens)
        let preparedInputTokens = prepared.text.tokens.dim(-1)
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
            kvBits: resourceProfile.tier == .constrained ? 4 : 8,
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
            startedAt: startedAt
        )
    }

    /// Keep the stream and its live KV cache in a nested scope. When this
    /// helper returns (or throws), those references are destroyed before the
    /// caller's `Memory.clearCache()` defer runs, so freed pages cannot simply
    /// fall back into MLX's process-wide cache after it was cleared.
    private func generatePrepared(
        container: ModelContainer,
        input: sending LMInput,
        parameters: GenerateParameters,
        inputTokens: Int,
        startedAt: Date
    ) async throws -> LocalGenerationResult {
        let stream: AsyncStream<Generation>
        do {
            stream = try await container.generate(input: input, parameters: parameters)
        } catch {
            throw LocalInferenceError.decodeFailed
        }

        var text = ""
        var firstTokenAt: Date?
        var info: GenerateCompletionInfo?
        for await event in stream {
            try Task.checkCancellation()
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
