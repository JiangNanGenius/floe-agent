// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeTools
import FloeSecurity
import FloeAgentRuntime

/// One incarnation owns its stores, cancellation fence and provider work.
/// Ordinary Mac admission, disk checkpoints and the task workspace are absent.
public actor FloeMacTemporaryConversation {
    public nonisolated let id = UUID()
    private nonisolated let lifetime = CancellationToken()
    private let conversations: EphemeralConversationStore
    private let runs: EphemeralRunStore
    private let launch: EphemeralRunLaunchStore
    private var profiles: [UUID: ConversationPromoter.ModelConfiguration] = [:]
    private var service: ConversationRunService?
    private var activeRun: UUID?
    private var stopping = false
    private var keeping = false

    public init() {
        let now = Date()
        let record = ConversationRecord(id: id, title: "", createdAt: now, updatedAt: now, purpose: .temporary)
        let conversationStore = EphemeralConversationStore(record: record)
        let runStore = EphemeralRunStore(hostedConversationID: id)
        conversations = conversationStore
        runs = runStore
        launch = EphemeralRunLaunchStore(hostedConversationID: id, conversationStore: conversationStore, runStore: runStore)
    }

    public func messages() async -> [PersistedMessage] { await conversations.bufferedSnapshot().messages }

    public nonisolated func invalidate() { lifetime.cancel() }
    public nonisolated func checkCancellation() throws { try lifetime.throwIfCancelled() }

    public func discard() async {
        invalidate()
        await conversations.close()
        await runs.close()
        profiles.removeAll()
        await service?.cancel()
    }

    public func stop() async {
        guard activeRun != nil else { return }
        stopping = true
        await service?.cancel()
    }

    public func resolve(_ approval: ApprovalRequestSnapshot, allow: Bool) async -> Bool {
        guard !lifetime.isCancelled, let service, TemporaryChatToolPolicy.publicWebToolNames.contains(approval.toolCall.toolName) else { return false }
        let decision: ApprovalDecision = allow
            ? .allow(scope: ApprovalScope(toolName: approval.toolCall.toolName, singleUse: true), expiresAt: nil)
            : .deny(reason: "Declined by user")
        return await service.resolveApproval(decision, for: approval.toolCall.id)
    }

    public func send(_ text: String, provider binding: FloeMacSelfProviderBinding,
                     publicWeb: [AnyAgentTool] = [],
                     onPrepared: @escaping @Sendable () async -> Void,
                     onEvent: @escaping @Sendable (HarnessEvent) async -> Void) async throws {
        try checkCancellation()
        guard !keeping, activeRun == nil else { throw FloeError.validationFailed("Temporary chat is busy") }
        let input = SecretIngressScanner.scan(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let goal = SecretRedactor.redact(input.sanitizedText, secret: binding.credentials.apiKey)
        guard !goal.isEmpty else { throw FloeError.validationFailed("Enter a message") }
        let binding = try FloeMacSelfCapabilityResolver.resolveProvider(binding)
        let run = UUID()
        activeRun = run
        stopping = false
        defer { activeRun = nil; service = nil; stopping = false }
        let history = try await ConversationHistoryAssembler(store: conversations)
            .build(conversationID: id, includeInlineImages: false)
        try checkCancellation()
        guard !stopping else { throw CancellationError() }
        let prepared = try await launch.prepare(.init(conversationID: id, runID: run, goal: goal,
            providerID: binding.provider.id, modelID: binding.model.id,
            providerName: binding.provider.displayName ?? binding.provider.kind.rawValue, modelName: binding.model.displayName))
        profiles[binding.model.id] = .init(provider: binding.provider, model: binding.model)
        do {
            try checkCancellation()
            guard !stopping else { throw CancellationError() }
            let executor = FloeMacTemporaryWebExecutor(tools: publicWeb)
            let allowed = TemporaryChatToolPolicy.allowedToolNames(from: executor.allDescriptors)
            let config = FloeAgentRuntime.Configuration(conversationID: id, provider: binding.provider, model: binding.model,
                conversationMode: .chat, allowedToolNames: allowed,
                toolsEnabled: !allowed.isEmpty && binding.model.capabilities.contains(.tools),
                ephemeralTransport: true, publicWebOnly: true, temporaryReadOnly: true, chatFastMode: true)
            let projection = ModelUserInputProjection()
            defer { projection.clear() }
            // The raw credential may reach only this one explicitly chosen
            // provider. Saved messages, events and any future history keep
            // placeholders. No temporary credential is ever hydrated from disk.
            if !input.captures.isEmpty {
                try projection.register(id: prepared.userMessage.id, safe: goal,
                    live: text.trimmingCharacters(in: .whitespacesAndNewlines), captures: input.captures)
            }
            let running = ConversationRunService(configuration: config, adapter: binding.adapter, policy: HumanApprovalPolicy(),
                executor: executor, credentials: binding.credentials, modelInputProjection: projection,
                conversationStore: conversations, runStore: runs,
                runID: run, conversationHistory: history)
            service = running
            let stream = running.events()
            await onPrepared()
            try checkCancellation()
            guard !stopping else { throw CancellationError() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await running.startPrepared(goal: goal, userMessageID: prepared.userMessage.id)
                }
                group.addTask {
                    for await event in stream {
                        try Task.checkCancellation()
                        try self.checkCancellation()
                        await onEvent(event)
                        if case .terminal = event { return }
                    }
                }
                while let _ = try await group.next() {}
            }
        } catch {
            if !lifetime.isCancelled {
                try await runs.updateRunState(id: run, state: stopping ? "cancelled" : "failed", endedAt: Date())
            }
            throw error
        }
    }

    /// Called after the run has settled. No writer can append a post-Keep tail
    /// to this frozen transcript. A failed transaction restores the same draft.
    public func keep(writer: @Sendable (ConversationPromoter.Snapshot, [ConversationPromoter.ModelConfiguration],
                                        @escaping @Sendable () throws -> Void) async throws -> Void) async throws {
        try checkCancellation()
        guard activeRun == nil, !keeping else { throw FloeError.validationFailed("Temporary chat is busy") }
        keeping = true
        defer { keeping = false }
        let chat = await conversations.bufferedSnapshot()
        guard !chat.messages.isEmpty else { throw FloeError.validationFailed("Temporary chat is empty") }
        let recorded = await runs.bufferedSnapshot()
        var saved = chat.conversation
        saved.purpose = .ordinary
        saved.title = String((chat.messages.first(where: { $0.role == "user" })?.content ?? "")
            .split(whereSeparator: \.isNewline).first.map { String($0.prefix(80)) } ?? "")
        let snapshot = ConversationPromoter.Snapshot(conversation: saved, messages: chat.messages, attachments: [],
            runs: recorded.runs, events: recorded.runs.flatMap { recorded.events[$0.id] ?? [] },
            usage: recorded.runs.flatMap { recorded.usage[$0.id] ?? [] }, errors: recorded.runs.flatMap { recorded.errors[$0.id] ?? [] })
        try checkCancellation()
        try await writer(snapshot, Array(profiles.values), { try self.checkCancellation() })
        invalidate()
    }
}

/// The descriptor and every dispatch must pass the shared temporary ceiling.
/// The caller supplies only the native public-URL reader, never a workspace,
/// registry, child dispatcher or GUI automation capability.
private struct FloeMacTemporaryWebExecutor: ToolExecutor {
    let tools: [AnyAgentTool]
    var allDescriptors: [ToolCatalog.Descriptor] {
        tools.compactMap { tool in
            guard tool.isAvailable(), TemporaryChatToolPolicy.isReadOnlySafe(tool.descriptor) else { return nil }
            return tool.descriptor
        }
    }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? { allDescriptors.first { $0.name == name } }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        guard let tool = tools.first(where: { $0.descriptor.name == call.toolName }),
              let descriptor = descriptor(named: call.toolName), context.publicWebOnly, context.temporaryReadOnly,
              TemporaryChatToolPolicy.denialReason(descriptor: descriptor, arguments: call.argumentsJSON) == nil else {
            throw FloeError.unauthorized
        }
        try context.cancellation.throwIfCancelled()
        let output = try await tool.execute(argumentsJSON: call.argumentsJSON, context: context)
        return ToolResult(callID: call.id, status: .ok, outputSummary: output.summary, outputDigest: output.fullOutputSHA256,
                          maximumSummaryCharacters: 200_000)
    }
}
