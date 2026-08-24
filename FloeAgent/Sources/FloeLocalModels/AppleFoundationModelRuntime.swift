import Foundation
import FloeCore
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
        maxTokens: Int
    ) async throws -> LocalRuntimeCompletion {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, *) else {
            throw FloeError.invalidConfiguration("Apple Foundation Models requires iOS or iPadOS 27 or later")
        }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            throw FloeError.invalidConfiguration(Self.unavailableMessage(for: availability()))
        }
        guard model.supportsLocale(Locale.current) else {
            throw FloeError.invalidConfiguration(
                "Apple Foundation Models does not support the current language or locale (\(Locale.current.identifier))"
            )
        }
        guard images.count <= 4 else {
            throw FloeError.validationFailed("Apple Foundation Models accepts at most four images per request")
        }

        let startedAt = ContinuousClock.now
        let recorder = DeferredToolCallRecorder()
        let nativeTools = tools.compactMap { descriptor in
            Self.deferredTool(from: descriptor, recorder: recorder)
        }
        let localizedInstructions = instructions +
            "\nRespond using the user's language when it is supported. Current locale: \(Locale.current.identifier)."
        let session = LanguageModelSession(
            model: model,
            tools: nativeTools,
            instructions: localizedInstructions
        )
        session.prewarm()
        let effectiveMaxTokens = max(64, min(maxTokens, 2_048))
        let options = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0,
            maximumResponseTokens: effectiveMaxTokens,
            toolCallingMode: .allowed
        )
        let contextOptions = ContextOptions(
            reasoningLevel: model.capabilities.contains(.reasoning) ? .light : nil
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
        let request = Prompt {
            prompt
            attachments
        }
        let promptTokens = try await model.tokenCount(for: request)
        let instructionTokens = try await model.tokenCount(for: Instructions(localizedInstructions))
        let toolTokens = try await model.tokenCount(for: nativeTools)
        let inputTokenCount = promptTokens + instructionTokens + toolTokens
        guard inputTokenCount + effectiveMaxTokens <= model.contextSize else {
            throw FloeError.validationFailed(
                "Apple Foundation Models context is too large (\(inputTokenCount) input + \(effectiveMaxTokens) reserved, limit \(model.contextSize)); compact the conversation and retry"
            )
        }
        do {
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
                }
            }
        } catch {
            if Task.isCancelled { throw FloeError.cancelled }
            throw Self.normalizedFoundationError(error)
        }
        let deferredToolCall = try await recorder.toolCall()
        if deferredToolCall != nil {
            // The system model may append prose after our neutral sentinel.
            // Discard it: the approved tool result will drive the next turn.
            latest = ""
        }
        guard deferredToolCall != nil || !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("Apple Foundation Models returned an empty response")
        }
        let elapsed = startedAt.duration(to: .now)
        let elapsedMs = Self.milliseconds(elapsed)
        let firstMs = firstContentAt.map { Self.milliseconds(startedAt.duration(to: $0)) }
        let inputTokens = usageInputTokens ?? inputTokenCount
        let outputTokens = usageOutputTokens ?? max(1, latest.utf8.count / 4)
        let decodeMs = max(1, elapsedMs - (firstMs ?? 0))
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
            throw FloeError.invalidConfiguration("Apple Foundation Models requires iOS or iPadOS 26 or later")
        }
        guard images.isEmpty else {
            throw FloeError.invalidConfiguration(
                "This App Store build supports Apple Intelligence text requests; image input requires the newer system Foundation Models runtime"
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
        session.prewarm()
        let startedAt = ContinuousClock.now
        var latest = ""
        var firstContentAt: ContinuousClock.Instant?
        do {
            for try await snapshot in session.streamResponse(to: prompt) {
                latest = snapshot.content
                if firstContentAt == nil, !latest.isEmpty { firstContentAt = .now }
            }
        } catch {
            if Task.isCancelled { throw FloeError.cancelled }
            throw FloeError.syncUnavailable(
                "Apple Foundation Models could not complete the request: \(error.localizedDescription)"
            )
        }
        guard !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("Apple Foundation Models returned an empty response")
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
            "This build does not include the Xcode 27 Foundation Models SDK"
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
            return "Apple Foundation Models requires a supported iOS or iPadOS version"
        case .deviceNotEligible:
            return "This device is not eligible for Apple Intelligence"
        case .appleIntelligenceDisabled:
            return "Turn on Apple Intelligence in System Settings"
        case .modelNotReady:
            return "The system model is still downloading or is not ready"
        case .unsupportedLocale(let identifier):
            return "Apple Foundation Models does not support the current language or locale (\(identifier))"
        case .unsupportedToolchain:
            return "This installation does not contain the Apple Foundation Models framework"
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
                throw FloeError.validationFailed("Image \(index + 1) exceeds the 24 MB local-model limit")
            }
            guard let decoded = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw FloeError.validationFailed("Image \(index + 1) could not be decoded")
            }
            source = decoded
        case .file(let url):
            guard url.isFileURL else {
                throw FloeError.validationFailed("Image \(index + 1) must be a validated local file")
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumBytes else {
                throw FloeError.validationFailed("Image \(index + 1) exceeds the 24 MB local-model limit")
            }
            guard let decoded = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw FloeError.validationFailed("Image \(index + 1) could not be decoded")
            }
            source = decoded
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard width > 0, height > 0, width * height <= 50_000_000 else {
            throw FloeError.validationFailed("Image \(index + 1) has unsupported pixel dimensions")
        }
        let orientationValue = properties?[kCGImagePropertyOrientation] as? UInt32
        let orientation = orientationValue.flatMap(CGImagePropertyOrientation.init(rawValue:))
        switch input {
        case .file(let url):
            return Attachment<ImageAttachmentContent>(imageURL: url, orientation: orientation)
                .label("user-image-\(index)")
        case .data:
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw FloeError.validationFailed("Image \(index + 1) could not be decoded")
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
                return FloeError.validationFailed(
                    "Apple Foundation Models context exceeded (\(details.tokenCount)/\(details.contextSize)); compact and retry once"
                )
            case .rateLimited(let details):
                let retry = details.resetDate.map { " Retry after \($0.formatted())." } ?? ""
                return FloeError.syncUnavailable("Apple Foundation Models is rate limited.\(retry)")
            case .unsupportedLanguageOrLocale:
                return FloeError.invalidConfiguration("Apple Foundation Models does not support this language or locale")
            case .timeout:
                return FloeError.syncUnavailable("Apple Foundation Models timed out; retry once")
            case .guardrailViolation, .refusal:
                return FloeError.validationFailed("Apple Foundation Models declined this request")
            case .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                return FloeError.invalidConfiguration("Apple Foundation Models does not support part of this request")
            @unknown default:
                return FloeError.internalError(error.localizedDescription)
            }
        }
        if error is LanguageModelSession.Error {
            return FloeError.syncUnavailable("Apple Foundation Models is busy; wait for the current request and retry once")
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
                "Apple Foundation Models requested multiple tools concurrently; retry with one tool per turn"
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
        switch type ?? (properties == nil ? "string" : "object") {
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
