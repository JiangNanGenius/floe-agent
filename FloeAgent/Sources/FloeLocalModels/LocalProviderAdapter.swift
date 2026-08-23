import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeLocalModelCatalog

public struct LocalRuntimeCompletion: Sendable, Equatable {
    public var text: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalDurationMs: Int
    public var timeToFirstTokenMs: Int?
    public var tokensPerSecond: Double?
}

public struct LocalModelBenchmarkResult: Sendable, Equatable {
    public var modelID: String
    public var outputTokens: Int
    public var totalDurationMs: Int
    public var timeToFirstTokenMs: Int?
    public var tokensPerSecond: Double?
    public var recommendedConcurrentTasks: Int
}

/// Shared model-picker policy. Selection and residency are deliberately
/// separate: a cloud model may be selected while one local model remains
/// resident, but replacing that resident model requires a user decision.
public enum LocalModelSelectionDecision: Sendable, Equatable {
    case preloadSilently
    case useResident
    case confirmReplacement(currentModelID: String)
}

public enum LocalModelResidencyPolicy {
    public static func decision(
        residentModelID: String?,
        targetModelID: String
    ) -> LocalModelSelectionDecision {
        guard let residentModelID else { return .preloadSilently }
        guard residentModelID != targetModelID else { return .useResident }
        return .confirmReplacement(currentModelID: residentModelID)
    }
}

/// Tracks which durable agent runs still need the single resident local
/// model. The ledger is deliberately independent from the loaded engine so
/// settings-page preloads and benchmarks do not masquerade as active tasks.
public struct LocalModelTaskResidencyLedger: Sendable, Equatable {
    private var modelsByTaskID: [UUID: String] = [:]

    public init() {}

    public var activeTaskCount: Int { modelsByTaskID.count }

    public mutating func retain(taskID: UUID, modelID: String) {
        modelsByTaskID[taskID] = modelID
    }

    /// Returns true only when the released task was the last local-model
    /// owner. Releasing an unknown or already-finished task is idempotent.
    @discardableResult
    public mutating func release(taskID: UUID) -> Bool {
        guard modelsByTaskID.removeValue(forKey: taskID) != nil else { return false }
        return modelsByTaskID.isEmpty
    }
}

@available(macOS 15.4, iOS 26.0, *)
public actor LocalModelRuntime {
    public enum LoadState: Sendable, Equatable {
        case unloaded
        case loading(modelID: String, includesVisionProjector: Bool)
        case ready(modelID: String, includesVisionProjector: Bool)
        case failed(modelID: String, message: String)
    }
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
    private var loadState: LoadState = .unloaded
    private var taskResidency = LocalModelTaskResidencyLedger()
    private var inferenceBusy = false
    private var inferenceWaiters: [CheckedContinuation<Void, Never>] = []

    public init(store: LocalModelStore = LocalModelStore()) { self.store = store }

    public func currentLoadState() -> LoadState { loadState }

    public func residentModelID() -> String? {
        activeEngine?.key.modelID
    }

    /// Claims local-model residency for a durable run before preprocessing or
    /// inference starts. This is cheap and idempotent for launch recovery.
    public func retainForTask(taskID: UUID, modelID: String) {
        taskResidency.retain(taskID: taskID, modelID: modelID)
        FloeLogger(category: .providers).info(
            "localInferenceTaskRetained run=\(taskID.uuidString) model=\(modelID) activeTasks=\(taskResidency.activeTaskCount) resident=\(activeEngine?.key.modelID ?? "none")"
        )
    }

    /// Releases the run's residency claim. When the last local task reaches a
    /// terminal state, wait for any in-flight decode to leave the FIFO slot,
    /// re-check the ledger (another task may have started while suspended),
    /// then tear down the mapped model immediately.
    public func releaseForTask(taskID: UUID, reason: String) async {
        let shouldUnload = taskResidency.release(taskID: taskID)
        FloeLogger(category: .providers).info(
            "localInferenceTaskReleased run=\(taskID.uuidString) reason=\(reason) activeTasks=\(taskResidency.activeTaskCount) shouldUnload=\(shouldUnload)"
        )
        guard shouldUnload else { return }

        await acquireInferenceSlot()
        defer { releaseInferenceSlot() }
        guard taskResidency.activeTaskCount == 0 else {
            FloeLogger(category: .providers).info(
                "localInferenceAutoUnloadSkipped run=\(taskID.uuidString) reason=newTaskRetained activeTasks=\(taskResidency.activeTaskCount)"
            )
            return
        }
        let previous = activeEngine
        activeEngine = nil
        if let previous { await previous.engine.shutdown() }
        loadState = .unloaded
        FloeLogger(category: .providers).info(
            "localInferenceAutoUnloaded run=\(taskID.uuidString) reason=\(reason) releasedModel=\(previous?.key.modelID ?? "none")"
        )
    }

    /// Maps the model into memory without generating tokens. The settings UI
    /// can invoke this explicitly, while task launch invokes it automatically
    /// during the visible preparing phase.
    public func preload(modelID: String, includesVisionProjector: Bool = false) async throws {
        await acquireInferenceSlot()
        defer { releaseInferenceSlot() }
        _ = try await prepareEngine(
            modelID: modelID,
            wantsVision: includesVisionProjector,
            traceID: UUID().uuidString
        )
    }

    @available(macOS 15.4, iOS 26.0, *)
    public func complete(modelID: String, prompt: String, images: [Data], maxTokens: Int) async throws -> String {
        try await completeMeasured(
            modelID: modelID,
            prompt: prompt,
            images: images,
            maxTokens: maxTokens
        ).text
    }

    public func completeMeasured(
        modelID: String,
        prompt: String,
        images: [Data],
        maxTokens: Int
    ) async throws -> LocalRuntimeCompletion {
        await acquireInferenceSlot()
        defer { releaseInferenceSlot() }
        try Task.checkCancellation()
        let traceID = UUID().uuidString
        let startedAt = Date()
        let wantsVision = !images.isEmpty
        let prepared = try await prepareEngine(
            modelID: modelID,
            wantsVision: wantsVision,
            traceID: traceID
        )
        let engine = prepared.engine
        let profile = prepared.profile
        FloeLogger(category: .providers).info(
            "localInferenceStarted trace=\(traceID) model=\(modelID) promptCharacters=\(prompt.count) images=\(images.count) imageBytes=\(images.reduce(0) { $0 + $1.count }) requestedMaxTokens=\(maxTokens) effectiveMaxTokens=\(min(maxTokens, profile.maximumOutputTokens))"
        )
        do {
            let engineStartedAt = Date()
            let output = try await engine.completeMeasured(
                prompt: prompt,
                images: images,
                maxTokens: min(maxTokens, profile.maximumOutputTokens)
            )
            let endedAt = Date()
            let prepareDurationMs = max(0, Int(engineStartedAt.timeIntervalSince(startedAt) * 1_000))
            FloeLogger(category: .providers).info(
                "localInferenceFinished trace=\(traceID) model=\(modelID) outputCharacters=\(output.text.count) inputTokens=\(output.inputTokens) outputTokens=\(output.outputTokens) ttftMs=\(output.timeToFirstTokenMs.map { $0 + prepareDurationMs } ?? -1) tokensPerSecond=\(output.tokensPerSecond ?? -1) durationMs=\(Int(endedAt.timeIntervalSince(startedAt) * 1_000))"
            )
            return LocalRuntimeCompletion(
                text: output.text,
                inputTokens: output.inputTokens,
                outputTokens: output.outputTokens,
                totalDurationMs: max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000)),
                timeToFirstTokenMs: output.timeToFirstTokenMs.map { $0 + prepareDurationMs },
                tokensPerSecond: output.tokensPerSecond
            )
        } catch {
            let nsError = error as NSError
            let safeMessage = String(error.localizedDescription.prefix(300))
            FloeLogger(category: .providers).warning(
                "localInferenceFailed trace=\(traceID) model=\(modelID) domain=\(nsError.domain) code=\(nsError.code) message=\(safeMessage) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
            )
            throw error
        }
    }

    /// Runs a short, deterministic text-only probe through the same engine and
    /// queue used by real tasks. One resident model remains the hard safety
    /// boundary; the recommendation therefore starts at one until a future
    /// multi-context implementation is measured on the device.
    public func benchmark(modelID: String) async throws -> LocalModelBenchmarkResult {
        let completion = try await completeMeasured(
            modelID: modelID,
            prompt: "/no_think\n请仅输出从 1 到 32 的整数，以空格分隔，不要解释。",
            images: [],
            maxTokens: 96
        )
        return LocalModelBenchmarkResult(
            modelID: modelID,
            outputTokens: completion.outputTokens,
            totalDurationMs: completion.totalDurationMs,
            timeToFirstTokenMs: completion.timeToFirstTokenMs,
            tokensPerSecond: completion.tokensPerSecond,
            recommendedConcurrentTasks: 1
        )
    }

    private func prepareEngine(
        modelID: String,
        wantsVision: Bool,
        traceID: String
    ) async throws -> ActiveEngine {
        let key = EngineKey(modelID: modelID, includesVisionProjector: wantsVision)
        if let cached = activeEngine,
           cached.key.modelID == modelID,
           (!wantsVision || cached.key.includesVisionProjector) {
            // A vision-capable engine can serve later text turns. Reusing it
            // avoids repeatedly unloading/reloading multi-gigabyte mappings.
            loadState = .ready(
                modelID: modelID,
                includesVisionProjector: cached.key.includesVisionProjector
            )
            FloeLogger(category: .providers).debug(
                "localInferenceEngineReused trace=\(traceID) model=\(modelID) requestedVision=\(wantsVision) loadedVision=\(cached.key.includesVisionProjector)"
            )
            return cached
        }
        loadState = .loading(modelID: modelID, includesVisionProjector: wantsVision)
        do {
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
            // Release the old mapping before measuring process headroom. The
            // prior implementation measured first, so switching a loaded 4B
            // text model to its vision projector double-counted the model and
            // rejected an otherwise viable load on 12 GB iPads.
            if let previous = activeEngine {
                activeEngine = nil
                await previous.engine.shutdown()
                await Task.yield()
                FloeLogger(category: .providers).info(
                    "localInferencePreviousEngineReleased trace=\(traceID) previousModel=\(previous.key.modelID) previousVision=\(previous.key.includesVisionProjector)"
                )
            }
            let mappedBytes = Self.fileSize(modelURL) + (projectorURL.map(Self.fileSize) ?? 0)
            let physicalMemory = ProcessInfo.processInfo.physicalMemory
            let availableMemory = LocalInferenceResourcePolicy.availableMemoryBytes()
            guard LocalInferenceResourcePolicy.canLoad(
                mappedBytes: mappedBytes,
                physicalMemoryBytes: availableMemory
            ) else {
                FloeLogger(category: .providers).warning(
                    "localInferenceEngineLoadRejected trace=\(traceID) model=\(modelID) reason=memoryHeadroom mappedBytes=\(mappedBytes) availableBytes=\(availableMemory) physicalBytes=\(physicalMemory) vision=\(wantsVision)"
                )
                throw LocalInferenceError.insufficientMemory(
                    required: mappedBytes,
                    physical: availableMemory
                )
            }
            let profile = LocalInferenceResourcePolicy.profile(
                mappedBytes: mappedBytes,
                // Re-evaluate the tier for every load. Background tasks,
                // decoded images and a previously loaded model can all change
                // the process allowance without changing installed RAM.
                physicalMemoryBytes: availableMemory
            )
            let loadStartedAt = Date()
            FloeLogger(category: .providers).info(
                "localInferenceEngineLoadStarted trace=\(traceID) model=\(modelID) projector=\(projectorURL != nil) mappedBytes=\(mappedBytes) availableBytes=\(availableMemory) physicalBytes=\(physicalMemory) tier=\(profile.tier.rawValue) context=\(profile.contextSize) batch=\(profile.batchSize) gpuLayers=\(profile.gpuLayers)"
            )
            let loaded: LlamaTextEngine
            do {
                loaded = try LlamaTextEngine(
                    modelURL: modelURL,
                    projectorURL: projectorURL,
                    resourceProfile: profile
                )
            } catch {
                let nsError = error as NSError
                let safeMessage = String(error.localizedDescription.prefix(300))
                FloeLogger(category: .providers).warning(
                    "localInferenceEngineLoadFailed trace=\(traceID) model=\(modelID) projector=\(projectorURL != nil) domain=\(nsError.domain) code=\(nsError.code) message=\(safeMessage) durationMs=\(Int(Date().timeIntervalSince(loadStartedAt) * 1_000))"
                )
                throw error
            }
            let prepared = ActiveEngine(key: key, engine: loaded, profile: profile)
            activeEngine = prepared
            loadState = .ready(modelID: modelID, includesVisionProjector: wantsVision)
            FloeLogger(category: .providers).info(
                "localInferenceEngineLoadFinished trace=\(traceID) model=\(modelID) durationMs=\(Int(Date().timeIntervalSince(loadStartedAt) * 1_000))"
            )
            return prepared
        } catch {
            loadState = .failed(
                modelID: modelID,
                message: String(error.localizedDescription.prefix(300))
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
            loadState = .unloaded
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
@available(macOS 15.4, iOS 26.0, *)
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
                    guard #available(iOS 26.0, macOS 15.4, *) else {
                        throw FloeError.invalidConfiguration("Local inference requires iOS or iPadOS 26 or later")
                    }
                    let promptBuild = Self.buildPrompt(for: request)
                    let prompt = promptBuild.text
                    FloeLogger(category: .providers).info(
                        "localPromptPrepared model=\(request.model.remoteModelID) messages=\(request.effectiveMessages.count) sourceCharacters=\(promptBuild.sourceCharacters) promptCharacters=\(prompt.count) offeredTools=\(request.toolSchemas.count) selectedTools=\(promptBuild.selectedToolCount) omittedTools=\(max(0, request.toolSchemas.count - promptBuild.selectedToolCount))"
                    )
                    let images = request.effectiveMessages.flatMap(\.content).compactMap { part -> Data? in
                        guard case .imageData(_, let base64) = part else { return nil }
                        return Data(base64Encoded: base64)
                    }
                    let completion = try await runtime.completeMeasured(
                        modelID: request.model.remoteModelID,
                        prompt: prompt,
                        images: images,
                        maxTokens: min(max(64, request.model.limits.configuredMaxOutputTokens ?? 1024), 4096)
                    )
                    let channels = Self.splitReasoning(from: completion.text)
                    if !channels.reasoning.isEmpty {
                        continuation.yield(.reasoningSummary(.init(text: channels.reasoning)))
                    }
                    continuation.yield(.usage(.init(
                        inputTokens: completion.inputTokens,
                        outputTokens: completion.outputTokens,
                        totalDurationMs: completion.totalDurationMs,
                        timeToFirstTokenMs: completion.timeToFirstTokenMs,
                        tokensPerSecond: completion.tokensPerSecond
                    )))
                    if let call = try Self.toolCall(from: channels.answer) {
                        continuation.yield(.toolRequest(call))
                        continuation.yield(.completed(.init(stopReason: .toolUse)))
                    } else {
                        guard !channels.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw FloeError.validationFailed(
                                "The local model returned internal reasoning without a final answer. Retry with thinking disabled."
                            )
                        }
                        continuation.yield(.textDelta(.init(text: channels.answer)))
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
        for entry in CuratedLocalModelCatalog.entries {
            guard let modelURL = await store.installedModelURL(id: entry.id) else { continue }
            let mappedBytes = Self.fileSize(modelURL)
            let resourceProfile = LocalInferenceResourcePolicy.profile(
                mappedBytes: mappedBytes,
                physicalMemoryBytes: LocalInferenceResourcePolicy.availableMemoryBytes()
            )
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
                limits: .init(
                    contextTokens: Int(resourceProfile.contextSize),
                    maxOutputTokens: resourceProfile.maximumOutputTokens
                ),
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

    private static func fileSize(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return UInt64(max(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0, 0))
    }

    struct PromptBuild: Sendable, Equatable {
        let text: String
        let selectedToolCount: Int
        let sourceCharacters: Int
    }

    /// The full cloud harness is intentionally much larger than the safe
    /// 3K-8K on-device context. Replaying it verbatim made every local turn
    /// fail before decoding. Build a bounded local activation instead: the
    /// latest conversation evidence plus a small intent-relevant tool set.
    static func buildPrompt(for request: ProviderStreamRequest) -> PromptBuild {
        let sourceCharacters = request.effectiveMessages.reduce(0) { partial, message in
            partial + message.content.reduce(0) { count, part in
                if case .text(let value) = part { return count + value.count }
                return count
            }
        }
        let latestUserText = request.effectiveMessages.last(where: { $0.role == "user" })?
            .content.compactMap { part -> String? in
                if case .text(let value) = part { return value }
                return nil
            }.joined(separator: "\n") ?? ""
        let selectedTools = selectTools(
            request.toolSchemas,
            latestUserText: latestUserText,
            pendingToolNames: Set(request.pendingToolCalls.map(\.toolName))
        )

        var sections: [String] = []
        // The cloud harness carries the complete tool inventory in a system
        // message, but local turns intentionally drop that oversized system
        // payload. Keep a compact, authoritative name-only directory on every
        // local turn so the model can discover capabilities without paying for
        // every schema. Intent-relevant schemas below still define the only
        // calls it may actually emit.
        if !request.toolSchemas.isEmpty {
            let names = request.toolSchemas.map(\.name).sorted().joined(separator: ", ")
            sections.append("AVAILABLE TOOL NAMES (authoritative): \(clipped(names, limit: 1_600))")
        }
        if !selectedTools.isEmpty {
            let schemas = selectedTools.map {
                "- \($0.name): \(clipped($0.description, limit: 120)) arguments=\($0.parametersJSON)"
            }.joined(separator: "\n")
            sections.append("""
            TOOLS:\n\(schemas)
            To call one, output only {"tool_call":{"name":"tool.name","arguments":{}}}. Otherwise answer normally.
            """)
        }

        var transcriptSections: [String] = []
        var transcriptCharacters = 0
        for message in request.effectiveMessages.reversed() where message.role != "system" {
            let raw = message.content.compactMap { part -> String? in
                if case .text(let value) = part { return value }
                if case .imageData = part { return "<image attached>" }
                if case .imageURL = part { return "<image attached>" }
                return nil
            }.joined(separator: "\n")
            let remaining = 1_600 - transcriptCharacters
            guard remaining > 80 else { break }
            let line = "\(message.role.uppercased()): \(clipped(raw, limit: min(800, remaining)))"
            transcriptSections.insert(line, at: 0)
            transcriptCharacters += line.count
        }
        sections.append(contentsOf: transcriptSections)
        // Tool evidence shares the same bounded history budget. Without this,
        // a tool follow-up could grow back beyond the bounded local context even
        // after the cloud system prompt had been removed.
        var evidenceBudget = max(0, 2_000 - transcriptCharacters)
        for call in request.pendingToolCalls.suffix(2) where evidenceBudget > 80 {
            let line = "ASSISTANT TOOL REQUEST \(call.id): \(call.toolName) \(String(decoding: call.argumentsJSON, as: UTF8.self))"
            let bounded = clipped(line, limit: min(500, evidenceBudget))
            sections.append(bounded)
            evidenceBudget -= bounded.count
        }
        for result in request.toolResults.suffix(2) where evidenceBudget > 80 {
            let line = "TOOL RESULT \(result.callID): \(result.output)"
            let bounded = clipped(line, limit: min(700, evidenceBudget))
            sections.append(bounded)
            evidenceBudget -= bounded.count
        }
        let transcript = sections.joined(separator: "\n\n")
        let modelID = request.model.remoteModelID.lowercased()
        let system = "You are Floe, a concise on-device agent. Follow the latest user request. Tool execution and approval are enforced by the app. Use only offered tools, never invent tool names, and never claim an action succeeded without a tool result. Think silently. Never print chain-of-thought, planning notes, drafts, self-corrections, or a 'Thinking Process' section. Return only the final answer or one tool-call JSON object."
        let text: String
        if modelID.contains("qwen") {
            // Qwen thinking variants default to verbose reasoning unless the
            // turn explicitly opts out. Local inference is the constrained,
            // offline path, so keep reasoning private and preserve tokens for
            // the answer and tool loop.
            text = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(transcript)\n/no_think<|im_end|>\n<|im_start|>assistant\n"
        } else if modelID.contains("ministral") || modelID.contains("mistral") {
            text = "[INST] \(system)\n\n\(transcript) [/INST]"
        } else {
            text = "SYSTEM: \(system)\n\n\(transcript)\n\nASSISTANT:"
        }
        return PromptBuild(
            text: text,
            selectedToolCount: selectedTools.count,
            sourceCharacters: sourceCharacters
        )
    }

    private static func selectTools(
        _ tools: [ToolSchemaDescriptor],
        latestUserText: String,
        pendingToolNames: Set<String>
    ) -> [ToolSchemaDescriptor] {
        let text = latestUserText.lowercased()
        let actionRequested = containsAny(text, [
            "创建", "读取", "查看", "查找", "搜索", "运行", "执行", "修改", "编辑", "删除", "生成", "连接", "分析", "测试",
            "create", "read", "inspect", "find", "search", "run", "execute", "edit", "delete", "generate", "connect", "analyze", "test"
        ])
        let inventoryRequested = containsAny(text, [
            "工具", "能力", "能做什么", "可以做什么", "可用", "tool", "capability", "what can you do", "available"
        ])
        let intentPrefixes: [(needles: [String], prefixes: [String])] = [
            (["文件", "目录", "文档", "pdf", "代码", "file", "folder", "document", "code"], ["workspace.", "document.", "pdf."]),
            (["图片", "照片", "图像", "视觉", "ocr", "image", "photo", "vision"], ["image."]),
            (["网页", "浏览器", "联网", "搜索", "网站", "web", "browser", "search", "url"], ["browser.", "web.", "network.http"]),
            (["python", "javascript", "js", "脚本", "计算", "运行", "execute", "script", "compute"], ["exec."]),
            (["ssh", "主机", "远程", "终端", "服务器", "host", "remote", "terminal", "server"], ["ssh."]),
            (["记忆", "memory", "偏好"], ["memory."]),
            (["日历", "提醒", "邮件", "地图", "家庭", "快捷指令", "calendar", "reminder", "mail", "map", "home", "shortcut"], ["apple."]),
            (["表格", "图表", "网页预览", "table", "chart", "preview", "presentation"], ["presentation."]),
            (["技能", "skill"], ["skill."])
        ]
        let fallbackNames: Set<String> = [
            "workspace.listDirectory", "workspace.readFile", "web.search",
            "image.inspect", "exec.localPython", "memory.recall"
        ]
        let scored = tools.compactMap { tool -> (ToolSchemaDescriptor, Int)? in
            if pendingToolNames.contains(tool.name) { return (tool, 10_000) }
            var score = 0
            let normalizedName = tool.name.lowercased()
            let components = normalizedName.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            if components.contains(where: { $0.count >= 3 && text.contains(String($0)) }) { score += 200 }
            for intent in intentPrefixes where containsAny(text, intent.needles) {
                if intent.prefixes.contains(where: { normalizedName.hasPrefix($0) }) { score += 100 }
            }
            if inventoryRequested { score += 20 }
            if actionRequested && fallbackNames.contains(tool.name) { score += 10 }
            return score > 0 ? (tool, score) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name < $1.0.name
        }

        var selected: [ToolSchemaDescriptor] = []
        var schemaCharacters = 0
        for (tool, _) in scored {
            let cost = tool.name.count + min(tool.description.count, 120) + tool.parametersJSON.count + 16
            guard selected.count < 6 else { break }
            guard schemaCharacters + cost <= 2_800 else { continue }
            selected.append(tool)
            schemaCharacters += cost
        }
        return selected
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains(where: { text.contains($0) })
    }

    struct OutputChannels: Sendable, Equatable {
        let reasoning: String
        let answer: String
    }

    /// Qwen/Mistral GGUF templates may return raw `<think>` blocks. Normalize
    /// them into the same private reasoning channel used by cloud providers so
    /// tags never leak into replies or conversation titles.
    static func splitReasoning(from output: String) -> OutputChannels {
        var answer = output
        var reasoningParts: [String] = []
        let pattern = #"(?is)<think\b[^>]*>(.*?)</think\s*>"#
        if let expression = try? NSRegularExpression(pattern: pattern) {
            let full = NSRange(answer.startIndex..<answer.endIndex, in: answer)
            let matches = expression.matches(in: answer, range: full)
            for match in matches {
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: answer) else { continue }
                let value = answer[range].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { reasoningParts.append(value) }
            }
            answer = expression.stringByReplacingMatches(
                in: answer,
                range: full,
                withTemplate: ""
            )
        }
        // Be defensive around templates that emit an empty or unmatched
        // closing tag before the visible answer.
        answer = answer.replacingOccurrences(
            of: #"(?is)</?think\b[^>]*>"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        // Some small GGUF chat templates ignore XML tags and emit an
        // English planning transcript. Never expose that internal scratchpad
        // as the assistant answer. Prefer the last explicit draft/final
        // marker because these models commonly revise the same answer several
        // times before stopping.
        let lower = answer.lowercased()
        if lower.hasPrefix("thinking process:") || lower.hasPrefix("reasoning process:") {
            let markers = [
                "final answer:", "final response:", "answer:",
                "最终回答：", "最终答复：", "答复：",
                "even shorter:", "revised draft:", "draft:"
            ]
            var selected: Range<String.Index>?
            for marker in markers {
                var searchStart = answer.startIndex
                while let range = answer.range(
                    of: marker,
                    options: [.caseInsensitive],
                    range: searchStart..<answer.endIndex
                ) {
                    if selected == nil || range.lowerBound > selected!.lowerBound {
                        selected = range
                    }
                    searchStart = range.upperBound
                }
            }
            if let selected {
                let privateText = answer[..<selected.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !privateText.isEmpty { reasoningParts.append(privateText) }
                answer = answer[selected.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                reasoningParts.append(answer)
                answer = ""
            }
        }
        return OutputChannels(
            reasoning: reasoningParts.joined(separator: "\n\n"),
            answer: answer
        )
    }

    private static func clipped(_ text: String, limit: Int) -> String {
        guard text.count > limit, limit > 24 else { return text }
        let headCount = (limit - 17) * 2 / 3
        let tailCount = limit - 17 - headCount
        return String(text.prefix(headCount)) + "\n...[omitted]...\n" + String(text.suffix(tailCount))
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
