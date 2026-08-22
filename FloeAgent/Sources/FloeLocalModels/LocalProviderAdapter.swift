import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeLocalModelCatalog

@available(macOS 15.4, iOS 18.4, *)
public actor LocalModelRuntime {
    private let store: LocalModelStore
    private struct EngineKey: Equatable {
        let modelID: String
        let includesVisionProjector: Bool
    }
    private struct ActiveEngine {
        let key: EngineKey
        let engine: LlamaTextEngine
        let profile: LocalInferenceResourceProfile
    }
    /// iOS cannot safely keep several multi-gigabyte GGUF mappings alive.
    /// One FIFO slot also prevents actor reentrancy from swapping an engine
    /// while an earlier request is still decoding with it.
    private var activeEngine: ActiveEngine?
    private var inferenceBusy = false
    private var inferenceWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: LocalModelStore = LocalModelStore()) { self.store = store }

    @available(macOS 15.4, iOS 18.4, *)
    public func complete(modelID: String, prompt: String, images: [Data], maxTokens: Int) async throws -> String {
        await acquireInferenceSlot()
        defer { releaseInferenceSlot() }
        try Task.checkCancellation()
        let traceID = UUID().uuidString
        let startedAt = Date()
        let wantsVision = !images.isEmpty
        let key = EngineKey(modelID: modelID, includesVisionProjector: wantsVision)
        let engine: LlamaTextEngine
        let profile: LocalInferenceResourceProfile
        if let cached = activeEngine, cached.key == key {
            engine = cached.engine
            profile = cached.profile
            FloeLogger(category: .providers).debug(
                "localInferenceEngineReused trace=\(traceID) model=\(modelID) vision=\(wantsVision)"
            )
        } else {
            guard let modelURL = await store.installedModelURL(id: modelID) else {
                FloeLogger(category: .providers).warning(
                    "localInferenceUnavailable trace=\(traceID) model=\(modelID) reason=notInstalled"
                )
                throw FloeError.notFound("Local model \(modelID) is not installed")
            }
            let projectorURL: URL?
            if wantsVision {
                guard let installed = await store.installedProjectorURL(id: modelID) else {
                    throw LocalInferenceError.visionLoadFailed
                }
                projectorURL = installed
            } else {
                // Vision projectors are often hundreds of MB to several GB.
                // Never map one for a text-only turn.
                projectorURL = nil
            }
            let mappedBytes = Self.fileSize(modelURL) + (projectorURL.map(Self.fileSize) ?? 0)
            let physicalMemory = ProcessInfo.processInfo.physicalMemory
            guard LocalInferenceResourcePolicy.canLoad(
                mappedBytes: mappedBytes,
                physicalMemoryBytes: physicalMemory
            ) else {
                FloeLogger(category: .providers).warning(
                    "localInferenceEngineLoadRejected trace=\(traceID) model=\(modelID) reason=memoryHeadroom mappedBytes=\(mappedBytes) physicalBytes=\(physicalMemory) vision=\(wantsVision)"
                )
                throw LocalInferenceError.insufficientMemory(
                    required: mappedBytes,
                    physical: physicalMemory
                )
            }
            profile = LocalInferenceResourcePolicy.profile(
                mappedBytes: mappedBytes,
                physicalMemoryBytes: physicalMemory
            )
            let loadStartedAt = Date()
            FloeLogger(category: .providers).info(
                "localInferenceEngineLoadStarted trace=\(traceID) model=\(modelID) projector=\(projectorURL != nil) mappedBytes=\(mappedBytes) physicalBytes=\(physicalMemory) context=\(profile.contextSize) batch=\(profile.batchSize) gpuLayers=\(profile.gpuLayers)"
            )
            if let previous = activeEngine {
                activeEngine = nil
                await previous.engine.shutdown()
                FloeLogger(category: .providers).info(
                    "localInferencePreviousEngineReleased trace=\(traceID) previousModel=\(previous.key.modelID) previousVision=\(previous.key.includesVisionProjector)"
                )
            }
            let loaded: LlamaTextEngine
            do {
                loaded = try LlamaTextEngine(
                    modelURL: modelURL,
                    projectorURL: projectorURL,
                    resourceProfile: profile
                )
            } catch {
                let nsError = error as NSError
                FloeLogger(category: .providers).warning(
                    "localInferenceEngineLoadFailed trace=\(traceID) model=\(modelID) projector=\(projectorURL != nil) domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(loadStartedAt) * 1_000))"
                )
                throw error
            }
            activeEngine = ActiveEngine(key: key, engine: loaded, profile: profile)
            engine = loaded
            FloeLogger(category: .providers).info(
                "localInferenceEngineLoadFinished trace=\(traceID) model=\(modelID) durationMs=\(Int(Date().timeIntervalSince(loadStartedAt) * 1_000))"
            )
        }
        FloeLogger(category: .providers).info(
            "localInferenceStarted trace=\(traceID) model=\(modelID) promptCharacters=\(prompt.count) images=\(images.count) imageBytes=\(images.reduce(0) { $0 + $1.count }) requestedMaxTokens=\(maxTokens) effectiveMaxTokens=\(min(maxTokens, profile.maximumOutputTokens))"
        )
        do {
            let output = try await engine.complete(
                prompt: prompt,
                images: images,
                maxTokens: min(maxTokens, profile.maximumOutputTokens)
            )
            FloeLogger(category: .providers).info(
                "localInferenceFinished trace=\(traceID) model=\(modelID) outputCharacters=\(output.count) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            return output
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .providers).warning(
                "localInferenceFailed trace=\(traceID) model=\(modelID) domain=\(nsError.domain) code=\(nsError.code) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw error
        }
    }

    public func unload(modelID: String? = nil) async {
        await acquireInferenceSlot()
        defer { releaseInferenceSlot() }
        let previous = activeEngine
        if modelID == nil || previous?.key.modelID == modelID {
            activeEngine = nil
            if let previous { await previous.engine.shutdown() }
        }
        FloeLogger(category: .providers).info(
            "localInferenceUnloaded requested=\(modelID ?? "all") released=\(previous != nil && (modelID == nil || previous?.key.modelID == modelID))"
        )
    }

    private func acquireInferenceSlot() async {
        if !inferenceBusy {
            inferenceBusy = true
            return
        }
        await withCheckedContinuation { continuation in
            inferenceWaiters.append(continuation)
        }
    }

    private func releaseInferenceSlot() {
        if inferenceWaiters.isEmpty {
            inferenceBusy = false
        } else {
            inferenceWaiters.removeFirst().resume()
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return UInt64(max(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0, 0))
    }
}

/// Provider-neutral bridge from downloaded GGUF weights into the same event
/// stream consumed by the remote-provider harness. Local models therefore use
/// identical approval, loop protection, tool execution and checkpoint logic.
@available(macOS 15.4, iOS 18.4, *)
public struct LocalProviderAdapter: ProviderAdapter {
    public static let providerProfile = ProviderProfile(
        id: ProviderProfile.onDeviceProviderID,
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
                // The runtime reserves memory headroom for the UI, Metal and
                // tools. Advertise the guaranteed profile, not llama.cpp's
                // theoretical maximum, so the harness compacts in time.
                limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
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
