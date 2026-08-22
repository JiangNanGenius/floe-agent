import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeLocalModelCatalog

@available(macOS 15.4, iOS 18.4, *)
public actor LocalModelRuntime {
    private let store: LocalModelStore
    private var engines: [String: LlamaTextEngine] = [:]

    public init(store: LocalModelStore = LocalModelStore()) { self.store = store }

    @available(macOS 15.4, iOS 18.4, *)
    public func complete(modelID: String, prompt: String, images: [Data], maxTokens: Int) async throws -> String {
        let engine: LlamaTextEngine
        if let cached = engines[modelID] {
            engine = cached
        } else {
            guard let modelURL = await store.installedModelURL(id: modelID) else {
                throw FloeError.notFound("Local model \(modelID) is not installed")
            }
            let projectorURL = await store.installedProjectorURL(id: modelID)
            let loaded = try LlamaTextEngine(modelURL: modelURL, projectorURL: projectorURL)
            engines[modelID] = loaded
            engine = loaded
        }
        return try await engine.complete(prompt: prompt, images: images, maxTokens: maxTokens)
    }

    public func unload(modelID: String? = nil) {
        if let modelID { engines[modelID] = nil } else { engines.removeAll() }
    }
}

/// Provider-neutral bridge from downloaded GGUF weights into the same event
/// stream consumed by the remote-provider harness. Local models therefore use
/// identical approval, loop protection, tool execution and checkpoint logic.
@available(macOS 15.4, iOS 18.4, *)
public struct LocalProviderAdapter: ProviderAdapter {
    public static let providerProfile = ProviderProfile(
        id: UUID(uuidString: "A1480000-0000-4000-8000-000000000001")!,
        kind: .local,
        wireProtocol: .openAIChatCompletions,
        baseURL: URL(string: "http://127.0.0.1")!,
        displayName: "On-device models",
        isEnabled: true,
        allowsPlainHTTP: true
    )
    public let protocolKind: ModelProtocol = .openAIChatCompletions
    private let runtime: LocalModelRuntime
    private let store: LocalModelStore

    public init(runtime: LocalModelRuntime, store: LocalModelStore) {
        self.runtime = runtime
        self.store = store
    }

    public func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard #available(iOS 18.4, macOS 15.4, *) else {
                        throw FloeError.invalidConfiguration("Local inference requires iOS 18.4 or later")
                    }
                    let prompt = Self.prompt(for: request)
                    let images = request.effectiveMessages.flatMap(\.content).compactMap { part -> Data? in
                        guard case .imageData(_, let base64) = part else { return nil }
                        return Data(base64Encoded: base64)
                    }
                    let output = try await runtime.complete(
                        modelID: request.model.remoteModelID,
                        prompt: prompt,
                        images: images,
                        maxTokens: min(max(64, request.model.limits.configuredMaxOutputTokens ?? 1024), 4096)
                    )
                    if let call = try Self.toolCall(from: output) {
                        continuation.yield(.toolRequest(call))
                        continuation.yield(.completed(.init(stopReason: .toolUse)))
                    } else {
                        continuation.yield(.textDelta(.init(text: output)))
                        let input = max(1, prompt.utf8.count / 4)
                        let outputTokens = max(1, output.utf8.count / 4)
                        continuation.yield(.usage(.init(inputTokens: input, outputTokens: outputTokens)))
                        continuation.yield(.completed(.init(stopReason: .endTurn)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] {
        var models: [ModelProfile] = []
        for entry in CuratedLocalModelCatalog.entries where await store.isInstalled(id: entry.id) {
            var capabilities: ModelCapabilities = [.text, .tools, .approval]
            if entry.supportsVision { capabilities.insert(.vision) }
            models.append(ModelProfile(
                id: entry.profileID,
                providerID: provider.id,
                remoteModelID: entry.id,
                displayName: entry.displayName,
                limits: .init(contextTokens: 8_192, maxOutputTokens: 2_048),
                capabilities: capabilities,
                reasoningEffort: entry.supportsReasoning ? .low : .automatic
            ))
        }
        return models
    }

    public func testConnection(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws {
        guard !(try await listModels(provider: provider, credentials: credentials)).isEmpty else {
            throw FloeError.notFound("No local model is installed")
        }
    }

    private static func prompt(for request: ProviderStreamRequest) -> String {
        var sections: [String] = []
        if !request.toolSchemas.isEmpty {
            let schemas = request.toolSchemas.map {
                "- \($0.name): \($0.description) arguments=\($0.parametersJSON)"
            }.joined(separator: "\n")
            sections.append("""
            SYSTEM: Tools available:\n\(schemas)
            When a tool is needed, output only one JSON object in this exact shape:
            {"tool_call":{"name":"tool.name","arguments":{}}}
            Otherwise answer normally. Never invent a tool name.
            """)
        }
        for message in request.effectiveMessages {
            let text = message.content.compactMap { part -> String? in
                if case .text(let value) = part { return value }
                if case .imageData = part { return "<__media__>" }
                if case .imageURL(let url) = part { return "[image: \(url.absoluteString)]" }
                return nil
            }.joined(separator: "\n")
            sections.append("\(message.role.uppercased()): \(text)")
        }
        for call in request.pendingToolCalls {
            sections.append("ASSISTANT TOOL REQUEST \(call.id): \(call.toolName) \(String(decoding: call.argumentsJSON, as: UTF8.self))")
        }
        for result in request.toolResults {
            sections.append("TOOL RESULT \(result.callID): \(result.output)")
        }
        let transcript = sections.joined(separator: "\n\n")
        let modelID = request.model.remoteModelID.lowercased()
        if modelID.contains("qwen") {
            return "<|im_start|>system\nYou are Floe, an on-device agent. Follow the transcript and use only offered tools.<|im_end|>\n<|im_start|>user\n\(transcript)<|im_end|>\n<|im_start|>assistant\n"
        }
        if modelID.contains("ministral") || modelID.contains("mistral") {
            return "[INST] You are Floe, an on-device agent. Follow the transcript and use only offered tools.\n\n\(transcript) [/INST]"
        }
        return transcript + "\n\nASSISTANT:"
    }

    private static func toolCall(from output: String) throws -> ToolCall? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [trimmed, fencedJSON(in: trimmed)].compactMap { $0 }
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let body = (object["tool_call"] as? [String: Any]) ?? object
            guard let name = body["name"] as? String,
                  let arguments = body["arguments"] as? [String: Any]
            else { continue }
            let argumentsData = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            return try ToolCall(
                id: "local-\(UUID().uuidString)", toolName: name,
                argumentsJSON: argumentsData, scope: .local
            )
        }
        return nil
    }

    private static func fencedJSON(in text: String) -> String? {
        guard let start = text.range(of: "```json", options: .caseInsensitive),
              let end = text.range(of: "```", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
