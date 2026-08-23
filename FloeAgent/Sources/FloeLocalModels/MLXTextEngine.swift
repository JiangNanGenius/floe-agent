import Foundation
import MLXHuggingFace
import MLXLMCommon
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
        resourceProfile: LocalInferenceResourceProfile
    ) async throws {
        self.resourceProfile = resourceProfile
        do {
            self.container = try await VLMModelFactory.shared.loadContainer(
                from: modelDirectory,
                using: #huggingFaceTokenizerLoader()
            )
        } catch {
            throw LocalInferenceError.modelLoadFailed
        }
    }

    /// Dropping the final container reference releases MLX tensors. The
    /// runtime calls this before loading a replacement and when the last task
    /// finishes so several multi-gigabyte models never remain resident.
    public func shutdown() {
        container = nil
    }

    public func completeMeasured(
        instructions: String,
        prompt: String,
        images: [Data] = [],
        tools: [ToolSchemaDescriptor] = [],
        maxTokens: Int = 1_024
    ) async throws -> LocalGenerationResult {
        guard let container else { throw LocalInferenceError.contextCreationFailed }
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
        let parameters = GenerateParameters(
            maxTokens: effectiveMaximum,
            maxKVSize: Int(resourceProfile.contextSize),
            // Eight-bit KV cache substantially reduces long-agent-turn memory
            // without quantizing model weights again.
            kvBits: 8,
            temperature: 0.55,
            topP: 0.95,
            repetitionPenalty: 1.05
        )
        let stream: AsyncStream<Generation>
        do {
            stream = try await container.generate(input: prepared, parameters: parameters)
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
            case .rejectedToolCall:
                // The harness will request a corrected call when the textual
                // response is incomplete; do not fabricate executable JSON.
                continue
            }
        }
        let endedAt = Date()
        let outputTokens = info?.generationTokenCount ?? Self.estimatedTokens(text)
        let inputTokens = info?.totalPromptTokenCount ?? Self.estimatedTokens(prompt)
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
