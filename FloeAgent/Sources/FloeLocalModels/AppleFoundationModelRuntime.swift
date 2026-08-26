import Foundation
import FloeCore
import FloeLocalModelCatalog
import FloeModels
import FloeProviders

#if canImport(FoundationModels)
import FoundationModels
#endif
#if compiler(>=6.4) && canImport(FoundationModels)
import ImageIO
#endif

/// Stable identity for the system-owned Apple Intelligence model. Unlike
/// GGUF entries this model has no downloaded file and never participates in
/// Floe's resident-model ledger.
public enum AppleFoundationModelIdentity {
    public static let profileID = UUID(
        uuidString: "A1480001-0000-4000-8000-000000000004"
    )!
    public static let remoteModelID = "apple-foundation-model"
}

/// Foundation Models can consume imported bytes and stable local file URLs.
/// Network/iCloud resolution stays in Floe's attachment pipeline so local
/// inference never performs unreported I/O.
public enum AppleFoundationImageInput: Sendable, Equatable {
    case data(Data)
    case file(URL)

    public func dataForLegacyRuntime() throws -> Data {
        switch self {
        case .data(let data):
            return data
        case .file(let url):
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
    }
}

/// One externally executed Floe tool exchange reconstructed into the public
/// Foundation Models transcript on the follow-up turn. The call ID is kept
/// identical so Apple sees a real structured tool call/output pair rather
/// than a prompt string or a fake sentinel result.
public struct AppleFoundationToolExchange: Sendable, Equatable {
    public let call: FloeModels.ToolCall
    public let output: String

    public init(call: FloeModels.ToolCall, output: String) {
        self.call = call
        self.output = output
    }
}

/// A prior natural-language turn reconstructed into the system model's
/// transcript. Floe persists the canonical conversation; Foundation Models
/// receives only this bounded projection, so a new session can continue a
/// second user turn without retaining hidden per-run state.
public struct AppleFoundationConversationMessage: Sendable, Equatable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public enum AppleFoundationModelAvailability: Sendable, Equatable {
    case available(contextTokens: Int, supportsVision: Bool, supportsTools: Bool, supportsReasoning: Bool)
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
    case unsupportedLocale(String)
    case unsupportedToolchain

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// Serializes access to Foundation Models. A fresh session is used for each
/// harness activation because Floe already supplies its bounded transcript;
/// retaining a second hidden transcript would double-count context.
public actor AppleFoundationModelRuntime {
    public static let shared = AppleFoundationModelRuntime()

    /// Release gate used by tests to prevent an older Xcode image from
    /// silently compiling only the unsupported fallback implementation.
    public nonisolated static var sdkIntegrationCompiled: Bool {
#if canImport(FoundationModels)
        true
#else
        false
#endif
    }

    public func availability() -> AppleFoundationModelAvailability {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, *) else { return .unsupportedOS }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            guard model.supportsLocale(Locale.current) else {
                return .unsupportedLocale(Locale.current.identifier)
            }
            return .available(
                contextTokens: model.contextSize,
                supportsVision: model.capabilities.contains(.vision),
                supportsTools: model.capabilities.contains(.toolCalling),
                supportsReasoning: model.capabilities.contains(.reasoning)
            )
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceDisabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .modelNotReady
        }
#elseif canImport(FoundationModels)
        // Xcode 26 ships the first public Foundation Models API used by the
        // App Store build. Its base text session is fully usable even though
        // Xcode 27-only vision, capability and usage APIs are unavailable.
        guard #available(iOS 26.0, macOS 26.0, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available(
                contextTokens: 4_096,
                supportsVision: false,
                // Xcode 26 does not expose the newer dynamic Tool bridge used
                // below, but Floe still offers its bounded schemas and parses
                // the same strict JSON tool_call envelope as the MLX path.
                supportsTools: true,
                supportsReasoning: false
            )
        case .unavailable(.deviceNotEligible):
            return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled):
            return .appleIntelligenceDisabled
        case .unavailable(.modelNotReady):
            return .modelNotReady
        @unknown default:
            return .modelNotReady
        }
#else
        return .unsupportedToolchain
#endif
    }

    public func complete(
        instructions: String,
        prompt: String,
        images: [AppleFoundationImageInput],
        tools: [ToolSchemaDescriptor],
        historicalTools: [ToolSchemaDescriptor] = [],
        conversation: [AppleFoundationConversationMessage] = [],
        toolHistory: [AppleFoundationToolExchange] = [],
        forceToolCall: Bool = false,
        maxTokens: Int
    ) async throws -> LocalRuntimeCompletion {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, *) else {
            throw FloeError.invalidConfiguration("请将 iPadOS 更新到支持 Apple Intelligence 模型的版本")
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw FloeError.invalidConfiguration(Self.unavailableMessage(for: availability()))
        }
        guard model.supportsLocale(Locale.current) else {
            throw FloeError.invalidConfiguration(
                "Apple Intelligence 模型暂不支持当前语言或地区（\(Locale.current.identifier)）"
            )
        }
        guard images.count <= 4 else {
            throw FloeError.validationFailed("Apple Intelligence 模型每次最多处理四张图片")
        }

        let traceID = UUID().uuidString
        let startedAt = ContinuousClock.now
        let availableBefore = LocalInferenceResourcePolicy.availableMemoryBytes()
        FloeLogger(category: .providers).info(
            "appleFoundationStarted trace=\(traceID) history=\(conversation.count) promptCharacters=\(prompt.count) images=\(images.count) offeredTools=\(tools.count) historicalTools=\(historicalTools.count) toolResults=\(toolHistory.count) context=\(model.contextSize) availableBeforeBytes=\(availableBefore)"
        )
        let recorder = DeferredToolCallRecorder()
        var nativeDescriptors = tools
        for descriptor in historicalTools
            where !nativeDescriptors.contains(where: { $0.name == descriptor.name }) {
            nativeDescriptors.append(descriptor)
        }
        let nativeTools = nativeDescriptors.compactMap { descriptor in
            Self.deferredTool(from: descriptor, recorder: recorder)
        }
        if !tools.isEmpty, nativeTools.isEmpty {
            throw FloeError.invalidConfiguration(
                "所选工具暂时无法交给 Apple Intelligence 模型使用，请减少工具后重试"
            )
        }
        let callableNames = nativeDescriptors.map(\.name).sorted().joined(separator: ", ")
        let localizedInstructions = instructions
            + "\nRespond using the user's language when it is supported. Current locale: \(Locale.current.identifier)."
            + (callableNames.isEmpty ? "" : "\nCallable native tools: \(callableNames). Use the native tool interface when the request needs current or external information; never claim those tools are unavailable.")
        let session = LanguageModelSession(
            model: model,
            tools: nativeTools,
            instructions: localizedInstructions
        )
        let effectiveMaxTokens = max(64, min(maxTokens, 2_048))
        let options = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0,
            maximumResponseTokens: effectiveMaxTokens,
            // `.required` could leave the system model waiting indefinitely
            // when a dynamically bridged tool was selected. The prompt still
            // asks for the one exact capability, while `.allowed` lets the
            // model fail naturally instead of wedging the session.
            toolCallingMode: tools.isEmpty ? .disallowed : .allowed
        )
        let contextOptions = ContextOptions(
            reasoningLevel: model.capabilities.contains(.reasoning) ? .light : nil
        )
        for message in conversation {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch message.role.lowercased() {
            case "user":
                session.transcript.append(.prompt(.init(
                    segments: [.text(.init(content: text))],
                    options: options,
                    contextOptions: contextOptions
                )))
            case "assistant":
                session.transcript.append(.response(.init(
                    segments: [.text(.init(content: text))]
                )))
            default:
                continue
            }
        }
        // A reconstructed Foundation Models transcript must preserve causal
        // order. The previous code appended toolCalls/toolOutput before the
        // prompt that caused them, then sent that prompt afterward as a new
        // request. Put the compact conversation prompt first and ask for a
        // natural continuation only after the recorded tool evidence.
        if !toolHistory.isEmpty {
            session.transcript.append(.prompt(.init(
                segments: [.text(.init(content: prompt))],
                options: options,
                contextOptions: contextOptions
            )))
        }
        for exchange in toolHistory {
            let arguments = try GeneratedContent(
                json: String(decoding: exchange.call.argumentsJSON, as: UTF8.self)
            )
            session.transcript.append(.toolCalls(.init([
                .init(
                    id: exchange.call.id,
                    toolName: exchange.call.toolName,
                    arguments: arguments
                )
            ])))
            session.transcript.append(.toolOutput(.init(
                id: exchange.call.id,
                toolName: exchange.call.toolName,
                segments: [.text(.init(content: exchange.output))]
            )))
        }
        FloeLogger(category: .providers).debug(
            "appleFoundationSessionPrepared trace=\(traceID) transcriptEntries=\(session.transcript.count)"
        )
        var latest = ""
        var firstContentAt: ContinuousClock.Instant?
        var usageInputTokens: Int?
        var usageCacheReadTokens: Int?
        var usageOutputTokens: Int?
        var usageReasoningTokens: Int?
        let attachments = try images.enumerated().map { index, input in
            try Self.imageAttachment(input, index: index)
        }
        if !attachments.isEmpty, !model.capabilities.contains(.vision) {
            throw FloeError.invalidConfiguration("Apple Foundation Model vision is not available on this device")
        }
        let request: Prompt
        if toolHistory.isEmpty {
            request = Prompt {
                prompt
                attachments
            }
        } else {
            request = Prompt(
                "Answer the user's latest request naturally using the verified tool output above. Do not repeat the tool call and do not expose tool-call JSON."
            )
        }
        FloeLogger(category: .providers).debug("appleFoundationPreflightStarted trace=\(traceID)")
        let promptTokens = try await model.tokenCount(for: request)
        let instructionTokens = try await model.tokenCount(for: Instructions(localizedInstructions))
        let toolTokens = try await model.tokenCount(for: nativeTools)
        let transcriptTokens = try await model.tokenCount(for: session.transcript)
        // `session.transcript` already contains the instructions. Use the
        // larger accounting result so reconstructed tool evidence cannot make
        // the manual preflight undercount the real request.
        let inputTokenCount = max(
            promptTokens + instructionTokens + toolTokens,
            promptTokens + transcriptTokens
        )
        FloeLogger(category: .providers).info(
            "appleFoundationPreflightFinished trace=\(traceID) inputTokens=\(inputTokenCount) reservedOutputTokens=\(effectiveMaxTokens) promptTokens=\(promptTokens) instructionTokens=\(instructionTokens) toolTokens=\(toolTokens) transcriptTokens=\(transcriptTokens) context=\(model.contextSize)"
        )
        guard inputTokenCount + effectiveMaxTokens <= model.contextSize else {
            throw FloeError.validationFailed(
                "当前对话超出 Apple Intelligence 模型的容量，请先整理对话后重试"
            )
        }
        do {
            FloeLogger(category: .providers).debug("appleFoundationStreamStarted trace=\(traceID)")
            for try await snapshot in session.streamResponse(
                to: request,
                options: options,
                contextOptions: contextOptions
            ) {
                // Foundation Models snapshots are cumulative. Replacing `latest`
                // avoids duplicated prefixes in the chat UI.
                latest = snapshot.content
                usageInputTokens = snapshot.usage.input.totalTokenCount
                usageCacheReadTokens = snapshot.usage.input.cachedTokenCount
                usageOutputTokens = snapshot.usage.output.totalTokenCount
                usageReasoningTokens = snapshot.usage.output.reasoningTokenCount
                if firstContentAt == nil, !latest.isEmpty {
                    firstContentAt = .now
                    FloeLogger(category: .providers).info(
                        "appleFoundationFirstContent trace=\(traceID) ttftMs=\(Self.milliseconds(startedAt.duration(to: .now)))"
                    )
                }
            }
        } catch {
            FloeLogger(category: .providers).warning(
                "appleFoundationFailed trace=\(traceID) phase=stream message=\(String(error.localizedDescription.prefix(300))) availableAfterBytes=\(LocalInferenceResourcePolicy.availableMemoryBytes())"
            )
            if Task.isCancelled || error is CancellationError { throw FloeError.cancelled }
            throw Self.normalizedFoundationError(error)
        }
        let deferredToolCall = try await recorder.toolCall()
        if deferredToolCall != nil {
            // The system model may append prose after our neutral sentinel.
            // Discard it: the approved tool result will drive the next turn.
            latest = ""
        }
        guard deferredToolCall != nil || !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("Apple Intelligence 模型没有返回内容，请重试")
        }
        let elapsed = startedAt.duration(to: .now)
        let elapsedMs = Self.milliseconds(elapsed)
        let firstMs = firstContentAt.map { Self.milliseconds(startedAt.duration(to: $0)) }
        let inputTokens = usageInputTokens ?? inputTokenCount
        let outputTokens = usageOutputTokens ?? max(1, latest.utf8.count / 4)
        let decodeMs = max(1, elapsedMs - (firstMs ?? 0))
        FloeLogger(category: .providers).info(
            "appleFoundationFinished trace=\(traceID) inputTokens=\(inputTokens) outputTokens=\(outputTokens) durationMs=\(elapsedMs) availableBeforeBytes=\(availableBefore) availableAfterBytes=\(LocalInferenceResourcePolicy.availableMemoryBytes())"
        )
        return LocalRuntimeCompletion(
            text: latest,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: usageCacheReadTokens,
            reasoningTokens: usageReasoningTokens,
            totalDurationMs: elapsedMs,
            timeToFirstTokenMs: firstMs,
            tokensPerSecond: Double(outputTokens) / (Double(decodeMs) / 1_000),
            deferredToolCall: deferredToolCall
        )
#elseif canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw FloeError.invalidConfiguration("请将 iPadOS 更新到支持 Apple Intelligence 模型的版本")
        }
        guard images.isEmpty else {
            throw FloeError.invalidConfiguration(
                "当前系统仅支持 Apple Intelligence 文字对话；升级系统后才能直接处理图片"
            )
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw FloeError.invalidConfiguration(Self.unavailableMessage(for: availability()))
        }
        let localizedInstructions = instructions
            + "\nRespond using the user's language when it is supported. Current locale: \(Locale.current.identifier)."
            + (tools.isEmpty ? "" : "\nIf a tool is required, emit only the exact JSON tool_call object documented in the prompt.")
        let session = LanguageModelSession(instructions: localizedInstructions)
        let startedAt = ContinuousClock.now
        var latest = ""
        var firstContentAt: ContinuousClock.Instant?
        do {
            let legacyConversation = conversation.map {
                "\($0.role.uppercased()): \($0.text)"
            }.joined(separator: "\n\n")
            let legacyPrompt = legacyConversation.isEmpty
                ? prompt : legacyConversation + "\n\nUSER: " + prompt
            for try await snapshot in session.streamResponse(to: legacyPrompt) {
                latest = snapshot.content
                if firstContentAt == nil, !latest.isEmpty { firstContentAt = .now }
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw FloeError.cancelled }
            throw FloeError.syncUnavailable(
                "Apple Intelligence 模型未能完成请求：\(error.localizedDescription)"
            )
        }
        guard !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("Apple Intelligence 模型没有返回内容，请重试")
        }
        let elapsed = startedAt.duration(to: .now)
        let elapsedParts = elapsed.components
        let elapsedMs = Int(elapsedParts.seconds * 1_000)
            + Int(elapsedParts.attoseconds / 1_000_000_000_000_000)
        let firstMs = firstContentAt.map { instant in
            let parts = startedAt.duration(to: instant).components
            return Int(parts.seconds * 1_000)
                + Int(parts.attoseconds / 1_000_000_000_000_000)
        }
        let inputTokens = max(1, (localizedInstructions.utf8.count + prompt.utf8.count) / 4)
        let outputTokens = max(1, latest.utf8.count / 4)
        let decodeMs = max(1, elapsedMs - (firstMs ?? 0))
        return LocalRuntimeCompletion(
            text: latest,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalDurationMs: elapsedMs,
            timeToFirstTokenMs: firstMs,
            tokensPerSecond: Double(outputTokens) / (Double(decodeMs) / 1_000)
        )
#else
        throw FloeError.invalidConfiguration(
            "当前安装无法使用 Apple Intelligence 模型，请更新 Floe 后重试"
        )
#endif
    }

    public static func unavailableMessage(
        for availability: AppleFoundationModelAvailability
    ) -> String {
        switch availability {
        case .available:
            return "Available"
        case .unsupportedOS:
            return "请将 iPadOS 更新到支持 Apple Intelligence 模型的版本"
        case .deviceNotEligible:
            return "这台设备不支持 Apple Intelligence"
        case .appleIntelligenceDisabled:
            return "请先在系统设置中打开 Apple Intelligence"
        case .modelNotReady:
            return "系统模型仍在下载或准备中，请稍后再试"
        case .unsupportedLocale(let identifier):
            return "系统模型暂不支持当前语言或地区（\(identifier)）"
        case .unsupportedToolchain:
            return "当前安装无法使用 Apple Intelligence 模型，请更新 Floe 后重试"
        }
    }

#if compiler(>=6.4) && canImport(FoundationModels)
    @available(iOS 27.0, macOS 27.0, *)
    private static func imageAttachment(
        _ input: AppleFoundationImageInput,
        index: Int
    ) throws -> Attachment<ImageAttachmentContent> {
        let maximumBytes = 24 * 1_024 * 1_024
        let source: CGImageSource
        switch input {
        case .data(let data):
            guard data.count <= maximumBytes else {
                throw FloeError.validationFailed("第 \(index + 1) 张图片超过 24 MB，请压缩后重试")
            }
            guard let decoded = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw FloeError.validationFailed("无法读取第 \(index + 1) 张图片，请更换文件后重试")
            }
            source = decoded
        case .file(let url):
            guard url.isFileURL else {
                throw FloeError.validationFailed("第 \(index + 1) 张图片尚未安全导入 Floe，请重新选择文件")
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else {
                throw FloeError.validationFailed("第 \(index + 1) 张图片超过 24 MB，请压缩后重试")
            }
            guard let decoded = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw FloeError.validationFailed("无法读取第 \(index + 1) 张图片，请更换文件后重试")
            }
            source = decoded
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, width * height <= 50_000_000 else {
            throw FloeError.validationFailed("第 \(index + 1) 张图片的尺寸暂不支持，请调整尺寸后重试")
        }
        let orientationValue = properties?[kCGImagePropertyOrientation] as? UInt32
        let orientation = orientationValue.flatMap(CGImagePropertyOrientation.init(rawValue:))
        switch input {
        case .file(let url):
            return Attachment<ImageAttachmentContent>(imageURL: url, orientation: orientation)
                .label("user-image-\(index)")
        case .data:
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw FloeError.validationFailed("无法读取第 \(index + 1) 张图片，请更换文件后重试")
            }
            return Attachment<ImageAttachmentContent>(image, orientation: orientation)
                .label("user-image-\(index)")
        }
    }

    @available(iOS 27.0, macOS 27.0, *)
    private static func normalizedFoundationError(_ error: Error) -> Error {
        if let modelError = error as? LanguageModelError {
            switch modelError {
            case .contextSizeExceeded(let details):
                FloeLogger(category: .providers).warning(
                    "appleFoundationContextExceeded used=\(details.tokenCount) limit=\(details.contextSize)"
                )
                return FloeError.validationFailed(
                    "当前对话超出 Apple Intelligence 模型的容量，请先整理对话后重试"
                )
            case .rateLimited(let details):
                let retry = details.resetDate.map { " 可在 \($0.formatted()) 后重试。" } ?? ""
                return FloeError.syncUnavailable("Apple Intelligence 模型暂时请求过多。\(retry)")
            case .unsupportedLanguageOrLocale:
                return FloeError.invalidConfiguration("Apple Intelligence 模型暂不支持当前语言或地区")
            case .timeout:
                return FloeError.syncUnavailable("Apple Intelligence 模型响应超时，请重试")
            case .guardrailViolation, .refusal:
                return FloeError.validationFailed("Apple Intelligence 模型无法处理这项请求")
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                return FloeError.invalidConfiguration("Apple Intelligence 模型暂不支持请求中的部分内容")
            @unknown default:
                return FloeError.internalError(error.localizedDescription)
            }
        }
        if error is LanguageModelSession.Error {
            return FloeError.syncUnavailable("Apple Intelligence 模型正忙，请稍后重试")
        }
        return error
    }

    @available(iOS 27.0, macOS 27.0, *)
    private static func deferredTool(
        from descriptor: ToolSchemaDescriptor,
        recorder: DeferredToolCallRecorder
    ) -> (any FoundationModels.Tool)? {
        guard let schema = try? DynamicToolSchema(descriptor: descriptor).generationSchema else {
            FloeLogger(category: .providers).warning(
                "appleFoundationToolSchemaSkipped tool=\(descriptor.name) reason=unsupportedSchema"
            )
            return nil
        }
        return DeferredFloeTool(
            name: descriptor.name,
            description: descriptor.description,
            parameters: schema,
            recorder: recorder
        )
    }

    @available(iOS 27.0, macOS 27.0, *)
    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        return Int(components.seconds * 1_000) + Int(components.attoseconds / 1_000_000_000_000_000)
    }
#endif
}

#if compiler(>=6.4) && canImport(FoundationModels)
@available(iOS 27.0, macOS 27.0, *)
private actor DeferredToolCallRecorder {
    private var recorded: (name: String, arguments: String)?
    private var additionalCallDetected = false

    func record(name: String, arguments: String) -> Bool {
        guard recorded == nil else {
            additionalCallDetected = true
            return false
        }
        recorded = (name, arguments)
        return true
    }

    func toolCall() throws -> FloeModels.ToolCall? {
        guard !additionalCallDetected else {
            throw FloeError.validationFailed(
                "Apple Intelligence 模型一次选择了多个工具，请重试"
            )
        }
        guard let recorded else { return nil }
        let data = Data(recorded.arguments.utf8)
        return try FloeModels.ToolCall(
            id: "apple-local-\(UUID().uuidString)",
            toolName: recorded.name,
            argumentsJSON: data,
            scope: .local
        )
    }
}

@available(iOS 27.0, macOS 27.0, *)
private struct DeferredFloeTool: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let recorder: DeferredToolCallRecorder

    @concurrent func call(arguments: GeneratedContent) async throws -> String {
        if await recorder.record(name: name, arguments: arguments.jsonString) {
            return "PENDING_EXTERNAL_EXECUTION"
        }
        return "TOOL_ALREADY_PENDING"
    }
}

@available(iOS 27.0, macOS 27.0, *)
private final class DynamicToolSchema: Decodable {
    var type: String?
    var description: String?
    var properties: [String: DynamicToolSchema]?
    var required: [String]?
    var items: DynamicToolSchema?
    var enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description, properties, required, items
        case enumValues = "enum"
    }

    convenience init(descriptor: ToolSchemaDescriptor) throws {
        guard let data = descriptor.parametersJSON.data(using: .utf8) else {
            throw FloeError.validationFailed("Invalid tool schema encoding")
        }
        let decoded = try JSONDecoder().decode(Self.self, from: data)
        self.init(
            type: decoded.type,
            description: decoded.description ?? descriptor.description,
            properties: decoded.properties,
            required: decoded.required,
            items: decoded.items,
            enumValues: decoded.enumValues,
            schemaName: Self.identifier(descriptor.name) + "Arguments"
        )
    }

    // Keep this outside CodingKeys so provider JSON never controls the schema
    // identity. A default is required for Decodable synthesis.
    private var schemaName: String? = nil

    private init(
        type: String?,
        description: String?,
        properties: [String: DynamicToolSchema]?,
        required: [String]?,
        items: DynamicToolSchema?,
        enumValues: [String]?,
        schemaName: String? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.items = items
        self.enumValues = enumValues
        self.schemaName = schemaName
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        properties = try container.decodeIfPresent(
            [String: DynamicToolSchema].self,
            forKey: .properties
        )
        required = try container.decodeIfPresent([String].self, forKey: .required)
        items = try container.decodeIfPresent(DynamicToolSchema.self, forKey: .items)
        enumValues = try container.decodeIfPresent([String].self, forKey: .enumValues)
    }

    var generationSchema: GenerationSchema {
        get throws {
            let root = try dynamicSchema(name: schemaName ?? "ToolArguments")
            return try GenerationSchema(root: root, dependencies: [])
        }
    }

    private func dynamicSchema(name: String) throws -> DynamicGenerationSchema {
        if let enumValues, !enumValues.isEmpty {
            return DynamicGenerationSchema(name: name, description: description, anyOf: enumValues)
        }
        let inferredType = (properties != nil || schemaName != nil) ? "object" : "string"
        switch type ?? inferredType {
        case "object":
            let required = Set(required ?? [])
            let fields = try (properties ?? [:]).sorted { $0.key < $1.key }.map { key, value in
                DynamicGenerationSchema.Property(
                    name: key,
                    description: value.description,
                    schema: try value.dynamicSchema(name: Self.identifier(name + "_" + key)),
                    isOptional: !required.contains(key)
                )
            }
            return DynamicGenerationSchema(name: name, description: description, properties: fields)
        case "array":
            guard let items else { throw FloeError.validationFailed("Array tool schema has no items") }
            return DynamicGenerationSchema(arrayOf: try items.dynamicSchema(name: name + "Item"))
        case "string": return DynamicGenerationSchema(type: String.self)
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number": return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default: throw FloeError.validationFailed("Unsupported tool schema type")
        }
    }

    private static func identifier(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let result = String(scalars)
        return result.first?.isNumber == true ? "Tool_" + result : result
    }
}
#endif
