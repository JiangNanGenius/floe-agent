import Foundation
import FloeCore
import FloeModels
import FloeProviders
import FloeLocalModelCatalog

public struct LocalRuntimeCompletion: Sendable, Equatable {
    public var text: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int? = nil
    public var cacheWriteTokens: Int? = nil
    public var reasoningTokens: Int? = nil
    public var totalDurationMs: Int
    public var timeToFirstTokenMs: Int?
    public var tokensPerSecond: Double?
    /// System Foundation Models invokes its Tool closure internally. The
    /// closure only records the request; Floe's normal approval harness still
    /// owns execution and continuation.
    public var deferredToolCall: ToolCall? = nil
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
        let engine: MLXTextEngine
        let profile: LocalInferenceResourceProfile
    }
    /// iOS cannot safely keep several multi-gigabyte model mappings alive.
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
            // Public on-device inference is text-only. Never map the vision
            // projector even if an older caller still requests it.
            wantsVision: false,
            traceID: UUID().uuidString
        )
    }

    @available(macOS 15.4, iOS 26.0, *)
    public func complete(modelID: String, prompt: String, images: [Data], maxTokens: Int) async throws -> String {
        try await completeMeasured(
            modelID: modelID,
            instructions: Self.defaultInstructions,
            prompt: prompt,
            images: images,
            tools: [],
            maxTokens: maxTokens
        ).text
    }

    public func completeMeasured(
        modelID: String,
        instructions: String,
        prompt: String,
        images: [Data],
        tools: [ToolSchemaDescriptor],
        maxTokens: Int
    ) async throws -> LocalRuntimeCompletion {
        await acquireInferenceSlot()
        defer { releaseInferenceSlot() }
        try Task.checkCancellation()
        guard images.isEmpty else {
            throw FloeError.validationFailed(
                "当前本地模型仅支持文字；图片会先通过系统 OCR 转成工作区文字文件。"
            )
        }
        let traceID = UUID().uuidString
        let startedAt = Date()
        let wantsVision = false
        let prepared = try await prepareEngine(
            modelID: modelID,
            wantsVision: wantsVision,
            traceID: traceID
        )
        let engine = prepared.engine
        let profile = prepared.profile
        let availableBeforeInference = LocalInferenceResourcePolicy.availableMemoryBytes()
        FloeLogger(category: .providers).info(
            "localInferenceStarted trace=\(traceID) model=\(modelID) promptCharacters=\(prompt.count) images=\(images.count) imageBytes=\(images.reduce(0) { $0 + $1.count }) requestedMaxTokens=\(maxTokens) effectiveMaxTokens=\(min(maxTokens, profile.maximumOutputTokens)) availableBeforeBytes=\(availableBeforeInference) physicalBytes=\(ProcessInfo.processInfo.physicalMemory) tier=\(profile.tier.rawValue) context=\(profile.contextSize) batch=\(profile.batchSize)"
        )
        do {
            let engineStartedAt = Date()
            let output = try await engine.completeMeasured(
                instructions: instructions,
                prompt: prompt,
                images: images,
                tools: tools,
                maxTokens: min(maxTokens, profile.maximumOutputTokens)
            )
            // Do not leave a multi-gigabyte mapped container resident while
            // the harness executes a tool or renders the completed answer.
            // Device reports showed occasional process termination precisely
            // in that gap. A follow-up turn reloads the same pinned snapshot;
            // reliability is more important than hiding its visible prepare
            // phase on memory-constrained iPads.
            if activeEngine?.key == prepared.key {
                activeEngine = nil
                await engine.shutdown()
                loadState = .unloaded
            }
            let endedAt = Date()
            let availableAfterInference = LocalInferenceResourcePolicy.availableMemoryBytes()
            let prepareDurationMs = max(0, Int(engineStartedAt.timeIntervalSince(startedAt) * 1_000))
            FloeLogger(category: .providers).info(
                "localInferenceFinished trace=\(traceID) model=\(modelID) outputCharacters=\(output.text.count) inputTokens=\(output.inputTokens) outputTokens=\(output.outputTokens) ttftMs=\(output.timeToFirstTokenMs.map { $0 + prepareDurationMs } ?? -1) tokensPerSecond=\(output.tokensPerSecond ?? -1) durationMs=\(Int(endedAt.timeIntervalSince(startedAt) * 1_000)) availableBeforeBytes=\(availableBeforeInference) availableAfterBytes=\(availableAfterInference) availableDeltaBytes=\(Int64(availableAfterInference) - Int64(availableBeforeInference)) tier=\(profile.tier.rawValue) context=\(profile.contextSize) batch=\(profile.batchSize) engineReleased=true"
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
            if activeEngine?.key == prepared.key {
                activeEngine = nil
                await engine.shutdown()
                loadState = .failed(
                    modelID: modelID,
                    message: String(error.localizedDescription.prefix(300))
                )
            }
            let availableAfterFailure = LocalInferenceResourcePolicy.availableMemoryBytes()
            let nsError = error as NSError
            let safeMessage = String(error.localizedDescription.prefix(300))
            FloeLogger(category: .providers).warning(
                "localInferenceFailed trace=\(traceID) model=\(modelID) domain=\(nsError.domain) code=\(nsError.code) message=\(safeMessage) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000)) availableBeforeBytes=\(availableBeforeInference) availableAfterBytes=\(availableAfterFailure) availableDeltaBytes=\(Int64(availableAfterFailure) - Int64(availableBeforeInference)) tier=\(profile.tier.rawValue) context=\(profile.contextSize) batch=\(profile.batchSize)"
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
            instructions: Self.defaultInstructions,
            prompt: "请仅输出从 1 到 32 的整数，以空格分隔，不要解释。",
            images: [],
            tools: [],
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
        // Keep text-only turns on the language-model factory. Vision models
        // are loaded only when an actual image arrives; a resident VLM can
        // still serve later text turns without remapping.
        let key = EngineKey(modelID: modelID, includesVisionProjector: wantsVision)
        if let cached = activeEngine,
           cached.key.modelID == modelID,
           cached.key.includesVisionProjector || !wantsVision {
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
                throw FloeError.notFound("这个本地模型尚未下载，请先在设置中下载")
            }
            guard let entry = CuratedLocalModelCatalog.entries.first(where: { $0.id == modelID }),
                  entry.runtimeFormat == .mlx else {
                throw FloeError.invalidConfiguration(
                    "这个模型版本暂不受支持，请在本地模型列表中选择可用型号"
                )
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
            let mappedBytes = await store.installedWeightBytes(id: modelID) ?? 0
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
                "localInferenceEngineLoadStarted trace=\(traceID) model=\(modelID) runtime=mlx visionRequested=\(wantsVision) mappedBytes=\(mappedBytes) availableBytes=\(availableMemory) physicalBytes=\(physicalMemory) tier=\(profile.tier.rawValue) context=\(profile.contextSize) batch=\(profile.batchSize)"
            )
            let loaded: MLXTextEngine
            do {
                loaded = try await MLXTextEngine(
                    modelDirectory: modelURL,
                    includesVisionProjector: wantsVision,
                    resourceProfile: profile
                )
            } catch {
                let nsError = error as NSError
                let safeMessage = String(error.localizedDescription.prefix(300))
                FloeLogger(category: .providers).warning(
                    "localInferenceEngineLoadFailed trace=\(traceID) model=\(modelID) runtime=mlx visionRequested=\(wantsVision) domain=\(nsError.domain) code=\(nsError.code) message=\(safeMessage) durationMs=\(Int(Date().timeIntervalSince(loadStartedAt) * 1_000))"
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

    private static let defaultInstructions =
        "You are Floe, a concise on-device agent. Think silently and return only the final answer."

}

/// Provider-neutral bridge from downloaded MLX weights into the same event
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
            let appleWatchdog: Task<Void, Never>? = if request.model.remoteModelID
                == AppleFoundationModelIdentity.remoteModelID {
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    FloeLogger(category: .providers).warning(
                        "appleFoundationWatchdogExpired model=\(request.model.remoteModelID) timeoutSeconds=30"
                    )
                    continuation.finish(throwing: FloeError.syncUnavailable(
                        "Apple Intelligence 模型长时间没有响应，本次任务已停止，请重试"
                    ))
                }
            } else {
                nil
            }
            let task = Task {
                defer { appleWatchdog?.cancel() }
                do {
                    guard #available(iOS 26.0, macOS 15.4, *) else {
                        throw FloeError.invalidConfiguration("Local inference requires iOS or iPadOS 26 or later")
                    }
                    let latestUserHasImage = request.effectiveMessages
                        .last(where: { $0.role == "user" })?
                        .content.contains(where: { part in
                            switch part {
                            case .imageData, .imageURL: return true
                            case .text: return false
                            }
                        }) ?? false
                    guard !latestUserHasImage else {
                        throw FloeError.validationFailed(
                            "当前本地模型仅支持文字；图片会先通过系统 OCR 转成工作区文字文件。"
                        )
                    }
                    let promptBuild = Self.buildPrompt(for: request)
                    let prompt = promptBuild.text
                    let imageParts: [AppleFoundationImageInput] = []
                    FloeLogger(category: .providers).info(
                        "localPromptPrepared model=\(request.model.remoteModelID) messages=\(request.effectiveMessages.count) sourceCharacters=\(promptBuild.sourceCharacters) promptCharacters=\(prompt.count) offeredTools=\(request.toolSchemas.count) selectedTools=\(promptBuild.selectedToolCount) omittedTools=\(max(0, request.toolSchemas.count - promptBuild.selectedToolCount))"
                    )
                    var completion: LocalRuntimeCompletion
                    if request.model.remoteModelID == AppleFoundationModelIdentity.remoteModelID {
                        let availability = await AppleFoundationModelRuntime.shared.availability()
                        guard availability.isAvailable else {
                            let reason = AppleFoundationModelRuntime.unavailableMessage(for: availability)
                            FloeLogger(category: .providers).warning(
                                "appleFoundationModelUnavailable model=\(request.model.remoteModelID) reason=\(reason)"
                            )
                            throw FloeError.invalidConfiguration(
                                "Apple Intelligence 模型当前无法调用：\(reason)"
                            )
                        }
                        let resultByCallID = Dictionary(
                            request.toolResults.map { ($0.callID, $0.output) },
                            uniquingKeysWith: { _, newest in newest }
                        )
                        let toolHistory = request.pendingToolCalls.compactMap { call in
                            resultByCallID[call.id].map {
                                AppleFoundationToolExchange(call: call, output: $0)
                            }
                        }
                        let historicalNames = Set(toolHistory.map { $0.call.toolName })
                        completion = try await AppleFoundationModelRuntime.shared.complete(
                            instructions: promptBuild.systemInstructions,
                            prompt: promptBuild.applePrompt,
                            images: imageParts,
                            tools: promptBuild.selectedTools,
                            historicalTools: request.toolSchemas.filter {
                                historicalNames.contains($0.name)
                            },
                            conversation: promptBuild.appleConversation,
                            toolHistory: toolHistory,
                            forceToolCall: promptBuild.requiresToolCall,
                            maxTokens: min(max(64, request.model.limits.configuredMaxOutputTokens ?? 512), 2_048)
                        )
                    } else {
                        completion = try await runtime.completeMeasured(
                            modelID: request.model.remoteModelID,
                            instructions: promptBuild.systemInstructions,
                            prompt: prompt,
                            images: try imageParts.map { try $0.dataForLegacyRuntime() },
                            tools: promptBuild.selectedTools,
                            maxTokens: min(max(64, request.model.limits.configuredMaxOutputTokens ?? 1024), 4096)
                        )
                    }
                    if let deferred = completion.deferredToolCall {
                        continuation.yield(.toolRequest(deferred))
                        continuation.yield(.completed(.init(stopReason: .toolUse)))
                        continuation.finish()
                        return
                    }
                    var channels = Self.splitReasoning(from: completion.text)
                    var parsedToolCall = try Self.fallbackToolCall(
                        from: channels.answer,
                        modelRemoteID: request.model.remoteModelID,
                        selectedTools: promptBuild.fallbackTools
                    )
                    if parsedToolCall == nil,
                       promptBuild.requiresToolCall,
                       request.model.remoteModelID != AppleFoundationModelIdentity.remoteModelID {
                        FloeLogger(category: .providers).warning(
                            "localToolInvocationRepairStarted model=\(request.model.remoteModelID) outputCharacters=\(channels.answer.count) selectedTools=\(promptBuild.selectedToolCount)"
                        )
                        let repair = try await runtime.completeMeasured(
                            modelID: request.model.remoteModelID,
                            instructions: "You must invoke exactly one offered native tool. If native invocation is unavailable, output exactly one JSON object with this shape and no prose: {\"tool_call\":{\"name\":\"exact.offered.name\",\"arguments\":{}}}. Never claim the action succeeded.",
                            prompt: prompt + "\n\nYour previous answer did not invoke a tool. Perform the requested action now using exactly one offered tool.",
                            images: [],
                            tools: promptBuild.selectedTools,
                            maxTokens: 256
                        )
                        completion.inputTokens += repair.inputTokens
                        completion.outputTokens += repair.outputTokens
                        completion.cacheReadTokens = Self.sumOptional(
                            completion.cacheReadTokens, repair.cacheReadTokens
                        )
                        completion.cacheWriteTokens = Self.sumOptional(
                            completion.cacheWriteTokens, repair.cacheWriteTokens
                        )
                        completion.reasoningTokens = Self.sumOptional(
                            completion.reasoningTokens, repair.reasoningTokens
                        )
                        completion.totalDurationMs += repair.totalDurationMs
                        completion.text = repair.text
                        completion.tokensPerSecond = completion.totalDurationMs > 0
                            ? Double(completion.outputTokens) / (Double(completion.totalDurationMs) / 1_000)
                            : nil
                        channels = Self.splitReasoning(from: repair.text)
                        parsedToolCall = try Self.fallbackToolCall(
                            from: channels.answer,
                            modelRemoteID: request.model.remoteModelID,
                            selectedTools: promptBuild.fallbackTools
                        )
                        FloeLogger(category: .providers).info(
                            "localToolInvocationRepairFinished model=\(request.model.remoteModelID) parsed=\(parsedToolCall != nil) outputCharacters=\(channels.answer.count)"
                        )
                    }
                    if !channels.reasoning.isEmpty {
                        continuation.yield(.reasoningSummary(.init(text: channels.reasoning)))
                    }
                    continuation.yield(.usage(.init(
                        inputTokens: completion.inputTokens,
                        outputTokens: completion.outputTokens,
                        cacheReadTokens: completion.cacheReadTokens,
                        cacheWriteTokens: completion.cacheWriteTokens,
                        reasoningTokens: completion.reasoningTokens,
                        totalDurationMs: completion.totalDurationMs,
                        timeToFirstTokenMs: completion.timeToFirstTokenMs,
                        tokensPerSecond: completion.tokensPerSecond
                    )))
                    if let call = parsedToolCall {
                        continuation.yield(.toolRequest(call))
                        continuation.yield(.completed(.init(stopReason: .toolUse)))
                    } else {
                        if promptBuild.requiresToolCall {
                            throw FloeError.validationFailed(
                                "本地模型没有形成有效的工具调用。请重试，或切换到云端模型完成这项操作。"
                            )
                        }
                        let visibleAnswer = Self.visibleAnswer(from: channels.answer)
                        guard !visibleAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw FloeError.validationFailed(
                                "The local model returned internal reasoning without a final answer. Retry with thinking disabled."
                            )
                        }
                        continuation.yield(.textDelta(.init(text: visibleAnswer)))
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
        let appleAvailability = await AppleFoundationModelRuntime.shared.availability()
        var appleLimits = ModelLimits(contextTokens: 4_096, maxOutputTokens: 512)
        var appleCapabilities: ModelCapabilities = [.text, .approval]
        var appleReasoning: ModelReasoningEffort? = .automatic
        var appleSuffix = "（不可用：" + AppleFoundationModelRuntime.unavailableMessage(for: appleAvailability) + "）"
        if case .available(let contextTokens, _, let supportsTools, let supportsReasoning) = appleAvailability {
            appleLimits = .init(
                contextTokens: contextTokens,
                maxOutputTokens: min(2_048, max(256, contextTokens / 4))
            )
            // Build 23 device evidence returned ModelManagerError 1001 for
            // direct Apple image input. Keep image attachments on Floe's
            // auxiliary/OCR path until the OS model reports this reliably.
            if supportsTools { appleCapabilities.insert(.tools) }
            appleReasoning = supportsReasoning ? .low : .automatic
            appleSuffix = ""
        }
        models.append(ModelProfile(
            id: AppleFoundationModelIdentity.profileID,
            providerID: provider.id,
            remoteModelID: AppleFoundationModelIdentity.remoteModelID,
            displayName: "Apple Foundation Model" + appleSuffix,
            limits: appleLimits,
            capabilities: appleCapabilities,
            reasoningEffort: appleReasoning
        ))
        for entry in CuratedLocalModelCatalog.entries {
            guard await store.installedModelURL(id: entry.id) != nil else { continue }
            let mappedBytes = await store.installedWeightBytes(id: entry.id) ?? 0
            let resourceProfile = LocalInferenceResourcePolicy.profile(
                mappedBytes: mappedBytes,
                physicalMemoryBytes: LocalInferenceResourcePolicy.availableMemoryBytes()
            )
            let capabilities: ModelCapabilities = [.text, .tools, .approval]
            models.append(ModelProfile(
                id: entry.profileID,
                providerID: provider.id,
                remoteModelID: entry.id,
                displayName: entry.displayName,
                // The runtime reserves memory headroom for the UI, Metal and
                // tools. Advertise the guaranteed profile, not the model's
                // theoretical maximum, so the local-only compactor runs in time.
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

    struct PromptBuild: Sendable, Equatable {
        let systemInstructions: String
        let text: String
        /// Apple Foundation Models gets a real transcript instead of one
        /// flattened pseudo-user message. This prevents a completed first run
        /// from poisoning or stalling the second run's session preparation.
        let applePrompt: String
        let appleConversation: [AppleFoundationConversationMessage]
        let selectedTools: [ToolSchemaDescriptor]
        /// All tools admitted for this local model. Native schemas remain
        /// context-bounded, while strict JSON fallback may resolve any exact
        /// name from the authoritative directory shown to the model.
        let fallbackTools: [ToolSchemaDescriptor]
        let selectedToolCount: Int
        let requiresToolCall: Bool
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
        let isAppleToolFollowUp = request.model.remoteModelID
            == AppleFoundationModelIdentity.remoteModelID && !request.toolResults.isEmpty
        let contextTokens = max(1, request.model.limits.contextTokens)
        let availableTools = admissibleTools(
            request.toolSchemas,
            modelRemoteID: request.model.remoteModelID
        )
        let rankedTools = isAppleToolFollowUp ? [] : selectTools(
            availableTools,
            latestUserText: latestUserText,
            pendingToolNames: Set(request.pendingToolCalls.map(\.toolName)),
            contextTokens: contextTokens
        )
        // Dynamic Foundation Models schemas are intentionally limited to one
        // exact Apple capability per turn. Build 23 logs showed five schemas
        // entering a stream that never produced its first token.
        let selectedTools = request.model.remoteModelID
            == AppleFoundationModelIdentity.remoteModelID
            ? Array(rankedTools.prefix(1))
            : rankedTools

        let normalizedUserText = latestUserText.lowercased()
        let actionRequested = requestsAction(normalizedUserText)
        let inventoryRequested = requestsInventory(normalizedUserText)
        let explicitToolExecutionRequested = requestsExplicitToolExecution(normalizedUserText)
        let includeToolDirectory = inventoryRequested || actionRequested
            || !selectedTools.isEmpty || !request.pendingToolCalls.isEmpty
        let budgets = promptBudgets(contextTokens: contextTokens)

        var sections: [String] = []
        // The cloud harness carries the complete tool inventory in a system
        // message, but local turns intentionally drop that oversized system
        // payload. Keep a compact, authoritative name-only directory only for
        // actions and capability questions; injecting it into greetings made
        // the Apple model behave like a command form instead of a chat model.
        // Structured schemas below still define the only calls it may emit.
        if includeToolDirectory, !availableTools.isEmpty {
            let names = availableTools.map(\.name).sorted().joined(separator: ", ")
            sections.append("AVAILABLE TOOL NAMES (authoritative): \(clipped(names, limit: budgets.directoryCharacters))")
        }
        if !selectedTools.isEmpty {
            let offered = selectedTools.map { tool in
                // The same full schema is already rendered by the native MLX
                // or Foundation Models tool interface. Repeating parameters
                // here doubled constrained-context memory with no added
                // authority; retain a short human-readable index only.
                "- \(tool.name): \(clipped(tool.description, limit: 120))"
            }.joined(separator: "\n")
            let invocationInstructions: String
            if request.model.remoteModelID == AppleFoundationModelIdentity.remoteModelID {
                invocationInstructions = "To call one, use only the native Foundation Models tool interface. Never print a tool call or tool result as JSON."
            } else {
                invocationInstructions = """
                To call one, use the native tool interface. If the model template cannot emit a native call, return exactly one JSON object and no prose:
                {"tool_call":{"name":"exact.offered.name","arguments":{}}}
                """
            }
            sections.append("""
            OFFERED TOOLS FOR THIS TURN (callable now):
            \(offered)
            \(invocationInstructions)
            """)
        }

        var applePromptSections = sections
        if !latestUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applePromptSections.append(latestUserText)
        }
        let latestUserIndex = request.effectiveMessages.lastIndex(where: { $0.role == "user" })
        let historyMessages = latestUserIndex.map { request.effectiveMessages[..<$0] }
            ?? request.effectiveMessages[...]
        var appleConversation: [AppleFoundationConversationMessage] = []
        var appleHistoryCharacters = 0
        let appleHistoryBudget = max(2_000, min(14_000, contextTokens * 2))
        for message in historyMessages.reversed()
            where message.role == "user" || message.role == "assistant" {
            let raw = message.content.compactMap { part -> String? in
                if case .text(let value) = part { return value }
                if case .imageData = part { return "<image attached>" }
                if case .imageURL = part { return "<image attached>" }
                return nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let remaining = appleHistoryBudget - appleHistoryCharacters
            guard remaining > 80 else { break }
            let bounded = clipped(raw, limit: min(4_000, remaining))
            appleConversation.insert(.init(role: message.role, text: bounded), at: 0)
            appleHistoryCharacters += bounded.count
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
            let remaining = budgets.transcriptCharacters - transcriptCharacters
            guard remaining > 80 else { break }
            let line = "\(message.role.uppercased()): \(clipped(raw, limit: min(800, remaining)))"
            transcriptSections.insert(line, at: 0)
            transcriptCharacters += line.count
        }
        sections.append(contentsOf: transcriptSections)
        // Tool evidence shares the same bounded history budget. Without this,
        // a tool follow-up could grow back beyond the bounded local context even
        // after the cloud system prompt had been removed.
        var evidenceBudget = max(0, budgets.evidenceCharacters - transcriptCharacters)
        if !isAppleToolFollowUp {
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
        }
        let transcript = sections.joined(separator: "\n\n")
        let toolInstructions: String
        if selectedTools.isEmpty {
            toolInstructions = "No tool is callable on this turn. Reply directly in natural language. Never emit tool-call JSON or wrap an ordinary answer in a tool/result object."
        } else if request.model.remoteModelID == AppleFoundationModelIdentity.remoteModelID {
            toolInstructions = "Use only offered native Foundation Models tools, never invent tool names, and never claim an action succeeded without a tool result. Invoke at most one tool per turn. Do not print JSON tool-call envelopes."
        } else {
            toolInstructions = "Use only offered native tools, never invent tool names, and never claim an action succeeded without a tool result. Invoke at most one tool per turn. If native tool calling is unavailable, emit the documented single JSON tool_call object with no prose. If a tool returns PENDING_EXTERNAL_EXECUTION, stop immediately without claiming completion."
        }
        let directoryInstructions = includeToolDirectory
            ? "The user message contains an authoritative AVAILABLE TOOL NAMES directory and, when action is needed, an OFFERED TOOLS section. For capability questions, report exact names from that directory; never claim you cannot see it."
            : "This is an ordinary conversation turn and no tool directory is needed."
        let requiredInvocation = actionRequested
            && (!inventoryRequested || explicitToolExecutionRequested)
        let invocationPriority = requiredInvocation && !selectedTools.isEmpty
            ? "The user explicitly requested an action. Invoke exactly one offered tool now; do not answer with a proposed call, sample JSON, or a claim that you invoked it."
            : ""
        let system = "You are Floe, a concise and natural on-device assistant. The latest user message may be a request or ordinary conversation. Respond normally and warmly to greetings, small talk, questions, brainstorming, opinions, and follow-ups; never demand a more explicit task merely because no tool is needed. Ask a clarifying question only when missing information materially changes a consequential action. Tool execution and approval are enforced by the app. \(directoryInstructions) \(toolInstructions) \(invocationPriority) Think silently. Never print chain-of-thought, planning notes, drafts, self-corrections, or a 'Thinking Process' section. Return only the final answer."
        return PromptBuild(
            systemInstructions: system,
            // MLX receives structured system/user messages and applies the
            // model's own chat template exactly once. Hand-written Qwen or
            // Mistral control tokens here caused double templating, exposed
            // chain-of-thought, and made native tool calls invisible.
            text: transcript,
            applePrompt: applePromptSections.joined(separator: "\n\n"),
            appleConversation: appleConversation,
            selectedTools: selectedTools,
            fallbackTools: availableTools,
            selectedToolCount: selectedTools.count,
            requiresToolCall: requiredInvocation && !selectedTools.isEmpty,
            sourceCharacters: sourceCharacters
        )
    }

    /// Small MLX models are reliable with bounded read/search and simple
    /// local execution, but often hallucinate multi-step browser, SSH, cloud
    /// and write-heavy source-control actions. Apple Foundation Models are
    /// deliberately limited to Apple-owned capabilities until Floe can bridge
    /// third-party execution into one native Foundation Models session.
    static func admissibleTools(
        _ tools: [ToolSchemaDescriptor],
        modelRemoteID: String
    ) -> [ToolSchemaDescriptor] {
        if modelRemoteID == AppleFoundationModelIdentity.remoteModelID {
            return tools.filter { $0.name.hasPrefix("apple.") }
        }
        return tools.filter { mlxAdmissibleToolNames.contains($0.name) }
    }

    /// The app runtime uses the same list before composing its generic tool
    /// inventory, so a local model never sees visual/browser capabilities
    /// that the adapter will later remove.
    public static func admissibleToolNames(
        from names: Set<String>,
        modelRemoteID: String
    ) -> Set<String> {
        if modelRemoteID == AppleFoundationModelIdentity.remoteModelID {
            return Set(names.filter { $0.hasPrefix("apple.") })
        }
        return names.intersection(mlxAdmissibleToolNames)
    }

    private static let mlxAdmissibleToolNames: Set<String> = [
            "web.search", "web.searchAI", "web.fetch",
            "workspace.listDirectory", "workspace.readFile", "workspace.searchFiles",
            "workspace.inspectFileMetadata", "workspace.createFile", "workspace.writeFile",
            "workspace.applyPatch",
            "image.ocr", "document.pdf.inspect", "document.pdf.render",
            "exec.localPython", "exec.javascript", "exec.localNumerical",
            "memory.recall", "git.status", "git.diff", "git.log"
    ]

    private static func selectTools(
        _ tools: [ToolSchemaDescriptor],
        latestUserText: String,
        pendingToolNames: Set<String>,
        contextTokens: Int
    ) -> [ToolSchemaDescriptor] {
        let text = latestUserText.lowercased()
        let actionRequested = requestsAction(text)
        let inventoryRequested = requestsInventory(text)
        let intentPrefixes: [(needles: [String], prefixes: [String])] = [
            (["文件", "目录", "文档", "pdf", "代码", "file", "folder", "document", "code"], ["workspace.", "document.", "pdf."]),
            (["图片", "照片", "图像", "视觉", "ocr", "image", "photo", "vision"], ["image."]),
            (["网页", "浏览器", "联网", "搜索", "网站", "天气", "预报", "web", "browser", "search", "weather", "forecast", "url"], ["web."]),
            (["python", "javascript", "js", "脚本", "计算", "运行", "execute", "script", "compute"], ["exec."]),
            (["ssh", "主机", "远程", "终端", "服务器", "host", "remote", "terminal", "server"], ["ssh."]),
            (["记忆", "memory", "偏好"], ["memory."]),
            (["git", "github", "版本控制", "源码管理", "代码仓库", "仓库", "分支", "提交", "暂存", "克隆", "拉取", "推送",
              "source control", "repository", "repo", "branch", "commit", "stage", "clone", "fetch", "pull", "push"],
             ["git.", "github.", "cloudworkspace.git"]),
            (["位置", "定位", "地址", "我在哪", "where am i", "current location", "location"], ["apple.location."]),
            (["自动化", "快捷指令", "automation", "shortcut"], ["apple.automation."]),
            (["日历", "提醒", "邮件", "地图", "家庭", "calendar", "reminder", "mail", "map", "home"], ["apple."]),
            (["表格", "图表", "网页预览", "table", "chart", "preview", "presentation"], ["presentation."]),
            (["技能", "skill"], ["skill."])
        ]
        let fallbackNames: Set<String> = [
            "workspace.listDirectory", "workspace.readFile", "web.search",
            "image.ocr", "exec.localPython", "memory.recall"
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
            let isGitIntent = containsAny(text, [
                "git", "github", "版本控制", "源码管理", "代码仓库", "仓库", "分支", "提交", "暂存", "克隆", "拉取", "推送",
                "source control", "repository", "repo", "branch", "commit", "stage", "clone", "fetch", "pull", "push"
            ])
            if isGitIntent {
                let wantsCloud = containsAny(text, ["云端", "云工作区", "cloud", "remote workspace"])
                let wantsGitHub = containsAny(text, ["github", "远程仓库", "repository", "repo", "克隆", "clone"])
                if wantsCloud, normalizedName.hasPrefix("cloudworkspace.git") { score += 220 }
                if !wantsCloud, normalizedName.hasPrefix("git.") { score += 180 }
                if wantsGitHub, normalizedName.hasPrefix("github.") { score += 200 }
            }
            if inventoryRequested { score += 20 }
            if actionRequested && fallbackNames.contains(tool.name) { score += 10 }
            return score > 0 ? (tool, score) : nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.0.name < $1.0.name
        }

        let budgets = promptBudgets(contextTokens: contextTokens)
        var selected: [ToolSchemaDescriptor] = []
        var schemaCharacters = 0
        for (tool, _) in scored {
            let cost = tool.name.count + min(tool.description.count, 120) + tool.parametersJSON.count + 16
            let maximumCount = inventoryRequested ? budgets.inventoryToolCount : budgets.actionToolCount
            let maximumCharacters = inventoryRequested ? budgets.inventorySchemaCharacters : budgets.actionSchemaCharacters
            guard selected.count < maximumCount else { break }
            guard schemaCharacters + cost <= maximumCharacters else { continue }
            selected.append(tool)
            schemaCharacters += cost
        }
        // Preserve score-based admission under the schema budget, then expose
        // a stable order so chat templates and tests do not churn between
        // equivalent tool sets.
        return selected.sorted { $0.name < $1.name }
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains(where: { text.contains($0) })
    }

    private static func requestsAction(_ text: String) -> Bool {
        containsAny(text, [
            "创建", "读取", "查看", "看一下", "查", "查找", "搜索", "获取", "告诉我", "帮我", "运行", "执行", "修改", "编辑", "删除", "生成", "连接", "分析", "测试", "尝试", "试一下", "试试", "试一个",
            "当前位置", "当前地址", "我的位置", "我在哪", "定位",
            "初始化", "提交", "暂存", "克隆", "拉取", "推送", "同步", "切换分支",
            "create", "read", "inspect", "find", "search", "get", "show me", "where am i", "current location", "run", "execute", "edit", "delete", "generate", "connect", "analyze", "test",
            "initialize", "commit", "stage", "clone", "fetch", "pull", "push", "sync", "switch branch"
        ])
    }

    /// Capability questions are normally informational, but phrases such as
    /// “列出工具并随便试一个” contain a second, explicit execution request.
    /// Keep that useful fuzzy instruction from being downgraded to inventory.
    private static func requestsExplicitToolExecution(_ text: String) -> Bool {
        containsAny(text, [
            "调用一个", "调用一下", "随便调用", "尝试一个", "尝试一下", "随便尝试",
            "试一个", "试一下", "试试", "测试一个", "测试一下",
            "call one", "invoke one", "try one", "test one", "try a tool"
        ])
    }

    private static func requestsInventory(_ text: String) -> Bool {
        containsAny(text, [
            "工具", "能力", "能做什么", "可以做什么", "可用", "tool", "capability", "what can you do", "available"
        ])
    }

    private struct PromptBudgets {
        let directoryCharacters: Int
        let transcriptCharacters: Int
        let evidenceCharacters: Int
        let actionToolCount: Int
        let inventoryToolCount: Int
        let actionSchemaCharacters: Int
        let inventorySchemaCharacters: Int
    }

    private static func promptBudgets(contextTokens: Int) -> PromptBudgets {
        if contextTokens <= 2_048 {
            return .init(
                directoryCharacters: 600,
                transcriptCharacters: 850,
                evidenceCharacters: 900,
                actionToolCount: 3,
                inventoryToolCount: 4,
                actionSchemaCharacters: 1_100,
                inventorySchemaCharacters: 1_300
            )
        }
        if contextTokens <= 4_096 {
            return .init(
                directoryCharacters: 1_000,
                transcriptCharacters: 1_300,
                evidenceCharacters: 1_400,
                actionToolCount: 5,
                inventoryToolCount: 6,
                actionSchemaCharacters: 2_200,
                inventorySchemaCharacters: 2_600
            )
        }
        return .init(
            directoryCharacters: 1_600,
            transcriptCharacters: 1_600,
            evidenceCharacters: 2_000,
            actionToolCount: 8,
            inventoryToolCount: 10,
            actionSchemaCharacters: 3_600,
            inventorySchemaCharacters: 4_800
        )
    }

    struct OutputChannels: Sendable, Equatable {
        let reasoning: String
        let answer: String
    }

    /// Some local templates may return raw `<think>` blocks. Normalize
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

        // Some small local chat templates ignore XML tags and emit an
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

    private static func sumOptional(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }

    /// Local text fallback is a control channel, not a prose scanner. Accept
    /// only an entire JSON payload (or an entire JSON fence) after reasoning
    /// has been separated. Searching arbitrary embedded objects makes braces,
    /// code samples, and long reasoning capable of becoming phantom calls.
    static func toolCall(
        from output: String,
        offeredToolNames: Set<String>
    ) throws -> ToolCall? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [strictJSONObject(trimmed), strictFencedJSON(trimmed)]
            .compactMap { $0 }
            .uniqued()
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            guard let body = toolCallBody(in: object),
                  let rawName = body["name"] as? String else { continue }
            let emittedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let aliases = [
                "browser.get": "web.fetch",
                "browser.fetch": "web.fetch",
                "browser.search": "web.search"
            ]
            let name = offeredToolNames.contains(emittedName)
                ? emittedName : (aliases[emittedName] ?? emittedName)
            guard offeredToolNames.contains(name) else { continue }
            let arguments: [String: Any]
            if let dictionary = body["arguments"] as? [String: Any] {
                arguments = dictionary
            } else if let encoded = body["arguments"] as? String,
                      let encodedData = encoded.data(using: .utf8),
                      let dictionary = try? JSONSerialization.jsonObject(with: encodedData) as? [String: Any] {
                arguments = dictionary
            } else if body["arguments"] == nil {
                arguments = [:]
            } else {
                continue
            }
            let argumentsData = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
            return try ToolCall(
                id: "local-\(UUID().uuidString)", toolName: name,
                argumentsJSON: argumentsData,
                scope: inferredScope(from: arguments)
            )
        }
        return nil
    }

    /// Foundation Models has a real native Tool channel. Text emitted by that
    /// model is always an answer, never a second wire protocol. MLX keeps the
    /// strict JSON fallback, bounded to the model's admissible authoritative
    /// tool directory. Runtime schema validation and approval still apply.
    static func fallbackToolCall(
        from output: String,
        modelRemoteID: String,
        selectedTools: [ToolSchemaDescriptor]
    ) throws -> ToolCall? {
        guard modelRemoteID != AppleFoundationModelIdentity.remoteModelID else { return nil }
        return try toolCall(
            from: output,
            offeredToolNames: Set(selectedTools.map(\.name))
        )
    }

    /// Xcode 27 Foundation Models can occasionally serialize a plain answer
    /// using the legacy `{tool,result}` envelope seen in early builds. It is
    /// not a callable tool request, so unwrap only the exact string-result
    /// shape and keep all other model output untouched.
    static func visibleAnswer(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.keys.allSatisfy({ $0 == "tool" || $0 == "result" }),
              object["tool"] is String,
              let result = object["result"] as? String
        else { return output }
        return result
    }

    /// Local JSON fallback has no wire translator, so derive the same
    /// host/path scope here. Without this, valid Qwen SSH calls were marked
    /// local and rejected by the runtime before reaching the real tool.
    private static func inferredScope(from arguments: [String: Any]) -> ToolScope {
        let hostID = ["hostID", "hostId", "host_id"]
            .compactMap { arguments[$0] as? String }
            .compactMap(UUID.init(uuidString:))
            .first
        guard let hostID else { return .local }
        if let path = ["path", "remotePath", "remote_path"]
            .compactMap({ arguments[$0] as? String }).first,
           !path.isEmpty {
            return .hostPath(hostID: hostID, path: path)
        }
        return .host(hostID)
    }

    private static func toolCallBody(in object: Any) -> [String: Any]? {
        guard let dictionary = object as? [String: Any] else { return nil }
        if let body = dictionary["tool_call"] as? [String: Any] {
            return (body["function"] as? [String: Any]) ?? body
        }
        if let calls = dictionary["tool_calls"] as? [[String: Any]],
           let first = calls.first {
            return (first["function"] as? [String: Any]) ?? first
        }
        if let function = dictionary["function"] as? [String: Any] {
            return function
        }
        return dictionary["name"] is String ? dictionary : nil
    }

    private static func strictJSONObject(_ text: String) -> String? {
        guard text.first == "{", text.last == "}" else { return nil }
        return text
    }

    private static func strictFencedJSON(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 3,
              lines.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "```json",
              lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```"
        else { return nil }
        let body = lines.dropFirst().dropLast().joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return strictJSONObject(body)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
