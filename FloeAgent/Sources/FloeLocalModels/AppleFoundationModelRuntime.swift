import Foundation
import FloeCore
import FloeModels
import FloeProviders

#if compiler(>=6.4) && canImport(FoundationModels)
import FoundationModels
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

public enum AppleFoundationModelAvailability: Sendable, Equatable {
    case available(contextTokens: Int, supportsVision: Bool, supportsTools: Bool, supportsReasoning: Bool)
    case unsupportedOS
    case deviceNotEligible
    case appleIntelligenceDisabled
    case modelNotReady
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

    public func availability() -> AppleFoundationModelAvailability {
#if compiler(>=6.4) && canImport(FoundationModels)
        guard #available(iOS 27.0, macOS 27.0, *) else { return .unsupportedOS }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
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
#else
        return .unsupportedToolchain
#endif
    }

    public func complete(
        instructions: String,
        prompt: String,
        images: [Data],
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

        let startedAt = ContinuousClock.now
        let recorder = DeferredToolCallRecorder()
        let nativeTools = tools.compactMap { descriptor in
            Self.deferredTool(from: descriptor, recorder: recorder)
        }
        let session = LanguageModelSession(
            model: model,
            tools: nativeTools,
            instructions: instructions
        )
        session.prewarm()
        let options = GenerationOptions(
            samplingMode: .greedy,
            temperature: 0,
            maximumResponseTokens: max(64, min(maxTokens, 2_048)),
            toolCallingMode: .allowed
        )
        let contextOptions = ContextOptions(
            reasoningLevel: model.capabilities.contains(.reasoning) ? .light : nil
        )
        var latest = ""
        var firstContentAt: ContinuousClock.Instant?
        let attachments = try images.enumerated().map { index, data in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw FloeError.validationFailed("Image \(index + 1) could not be decoded")
            }
            return Attachment<ImageAttachmentContent>(image).label("user-image-\(index)")
        }
        if !attachments.isEmpty, !model.capabilities.contains(.vision) {
            throw FloeError.invalidConfiguration("Apple Foundation Model vision is not available on this device")
        }
        let request = Prompt {
            prompt
            attachments
        }
        for try await snapshot in session.streamResponse(
            to: request,
            options: options,
            contextOptions: contextOptions
        ) {
            // Foundation Models snapshots are cumulative. Replacing `latest`
            // avoids duplicated prefixes in the chat UI.
            latest = snapshot.content
            if firstContentAt == nil, !latest.isEmpty {
                firstContentAt = .now
            }
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
        let inputTokens = max(1, prompt.utf8.count / 4)
        let outputTokens = max(1, latest.utf8.count / 4)
        let decodeMs = max(1, elapsedMs - (firstMs ?? 0))
        return LocalRuntimeCompletion(
            text: latest,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            totalDurationMs: elapsedMs,
            timeToFirstTokenMs: firstMs,
            tokensPerSecond: Double(outputTokens) / (Double(decodeMs) / 1_000),
            deferredToolCall: deferredToolCall
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
            return "Apple Foundation Models requires iOS or iPadOS 27 or later"
        case .deviceNotEligible:
            return "This device is not eligible for Apple Intelligence"
        case .appleIntelligenceDisabled:
            return "Turn on Apple Intelligence in System Settings"
        case .modelNotReady:
            return "The system model is still downloading or is not ready"
        case .unsupportedToolchain:
            return "This build does not include the Xcode 27 Foundation Models SDK"
        }
    }

#if compiler(>=6.4) && canImport(FoundationModels)
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

    func record(name: String, arguments: String) -> Bool {
        guard recorded == nil else { return false }
        recorded = (name, arguments)
        return true
    }

    func toolCall() throws -> FloeModels.ToolCall? {
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
