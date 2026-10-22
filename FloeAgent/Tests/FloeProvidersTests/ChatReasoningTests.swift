// FloeProvidersTests — conversation-local fast chat reasoning contract.
//
// Deterministic and offline: the resolution is a pure function of the frozen
// preference plus synthetic provider/model fixtures, plus the freeze/reuse
// behaviour of `ChatReasoningCoordinator` with injected RAM seed/record
// closures. No request ever leaves this process; stored model profiles are
// never mutated by this path.

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders

// MARK: - Fixtures

private func makeProvider(
    kind: ProviderKind,
    wireProtocol: ModelProtocol,
    host: String
) -> ProviderProfile {
    ProviderProfile(
        kind: kind,
        wireProtocol: wireProtocol,
        baseURL: URL(string: "https://\(host)/v1")!
    )
}

private func makeModel(
    provider: ProviderProfile,
    remoteID: String,
    reasoningEffort: ModelReasoningEffort? = nil
) -> ModelProfile {
    ModelProfile(
        providerID: provider.id,
        remoteModelID: remoteID,
        displayName: remoteID,
        limits: ModelLimits(contextTokens: 128_000, maxOutputTokens: 4_096),
        capabilities: [.text, .tools],
        reasoningEffort: reasoningEffort
    )
}

private let dashScopeProvider = makeProvider(
    kind: .custom, wireProtocol: .openAIChatCompletions, host: "dashscope.aliyuncs.com")
private let arkProvider = makeProvider(
    kind: .volcengineArk, wireProtocol: .openAIChatCompletions, host: "ark.cn-beijing.volces.com")
private let deepSeekProvider = makeProvider(
    kind: .custom, wireProtocol: .openAIChatCompletions, host: "api.deepseek.com")
private let openAIChatProvider = makeProvider(
    kind: .openAI, wireProtocol: .openAIChatCompletions, host: "api.openai.com")
private let anthropicProvider = makeProvider(
    kind: .anthropic, wireProtocol: .anthropicMessages, host: "api.anthropic.com")
private let arkAnthropicWiredProvider = makeProvider(
    kind: .volcengineArk, wireProtocol: .anthropicMessages, host: "ark.anthropic.example.com")
private let unknownProvider = makeProvider(
    kind: .custom, wireProtocol: .openAIChatCompletions, host: "gateway.example.com")
private let localProvider = makeProvider(
    kind: .local, wireProtocol: .openAIChatCompletions, host: "localhost")

private func recordingLog() -> ChatDecisionLog { ChatDecisionLog() }

private actor ChatDecisionLog {
    private(set) var recorded: [(UUID, ChatReasoningDecision)] = []

    func append(runID: UUID, decision: ChatReasoningDecision) {
        recorded.append((runID, decision))
    }

    var count: Int { recorded.count }
}

/// Deterministic gate for the durable-seed read: the test can forget the run
/// while the seed reader is suspended, then release it.
private actor SeedReadGate {
    private var entered = false
    private var isOpen = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func waitForOpen() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters.removeAll()
        if isOpen { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in openWaiters { waiter.resume() }
        openWaiters.removeAll()
    }
}

@Suite("FloeProviders.ChatReasoning resolution matrix")
struct ChatReasoningResolutionTests {

    // MARK: - .fast: the documented-knob-first product rule

    @Test("fast resolves to the disable knob ONLY where the contract documents one")
    func fastDisableWhereDocumented() {
        let cases: [(ProviderProfile, String)] = [
            (dashScopeProvider, "qwen-plus"),
            (arkProvider, "deepseek-v3.2"),
            (deepSeekProvider, "deepseek-chat"),
            (openAIChatProvider, "gpt-5.1"),
            (openAIChatProvider, "gpt-5.6-mini"),
        ]
        for (provider, modelID) in cases {
            let model = makeModel(provider: provider, remoteID: modelID)
            #expect(ChatReasoningSupport.supportsDocumentedDisable(provider: provider, model: model),
                    "\(modelID) should report a documented disable knob")
            let resolution = ChatReasoningSupport.resolve(.fast, provider: provider, model: model)
            #expect(resolution.policy == .disabled, Comment(rawValue: modelID))
            #expect(resolution.level == nil, Comment(rawValue: modelID))
        }
    }

    @Test("fast falls to the lowest known tier where effort is transmitted but none is documented")
    func fastLowestKnownTier() {
        // GPT-6 Astra / GPT-6.1 Sol intentionally do NOT support `none`.
        for modelID in ["gpt-6-astra", "gpt-6.1-sol"] {
            let model = makeModel(provider: openAIChatProvider, remoteID: modelID)
            #expect(ChatReasoningSupport.supportsDocumentedDisable(
                provider: openAIChatProvider, model: model) == false, Comment(rawValue: modelID))
            let resolution = ChatReasoningSupport.resolve(.fast, provider: openAIChatProvider, model: model)
            #expect(resolution.policy == .modelDefault, Comment(rawValue: modelID))
            #expect(resolution.level == .low, Comment(rawValue: modelID))
        }
        // The Anthropic adapter maps effort only — never a disable knob.
        let claude = makeModel(provider: anthropicProvider, remoteID: "claude-opus-4-5")
        #expect(ChatReasoningSupport.supportsDocumentedDisable(provider: anthropicProvider, model: claude) == false)
        #expect(ChatReasoningSupport.resolve(.fast, provider: anthropicProvider, model: claude).level == .low)
        // Ark-shaped provider on the Anthropic protocol: no disable wiring either.
        let arkClaude = makeModel(provider: arkAnthropicWiredProvider, remoteID: "claude-opus-4-5")
        #expect(ChatReasoningSupport.supportsDocumentedDisable(
            provider: arkAnthropicWiredProvider, model: arkClaude) == false)
    }

    @Test("fast omits every reasoning field on unknown, media or on-device endpoints")
    func fastOmitsForUnknownEndpoints() {
        for (provider, modelID) in [
            (unknownProvider, "some-router-model"),
            (localProvider, "llama-3.3"),
        ] {
            let model = makeModel(provider: provider, remoteID: modelID)
            #expect(ChatReasoningSupport.supportsDocumentedDisable(provider: provider, model: model) == false)
            let resolution = ChatReasoningSupport.resolve(.fast, provider: provider, model: model)
            #expect(resolution.policy == .modelDefault)
            #expect(resolution.level == nil, "\(modelID) must receive no guessed tier")
        }
    }

    // MARK: - Explicit levels: clamped, never guessed

    @Test("explicit levels clamp exactly like the automatic helper and never claim an unsupported tier")
    func explicitLevelsClamp() {
        // Ark's own model contract sends `maximum` as high (the provider-kind
        // clamp `AutomaticReasoningEffortTests` pins for `doubao-*`).
        let arkNative = makeModel(provider: arkProvider, remoteID: "doubao-seed-2-1-pro")
        #expect(ChatReasoningSupport.resolve(.high, provider: arkProvider, model: arkNative).level == .high)
        #expect(ChatReasoningSupport.resolve(.maximum, provider: arkProvider, model: arkNative).level == .high)
        // A DeepSeek-family model on the Ark gateway keeps DeepSeek's own wire
        // contract (native `max`): `ProviderTraits.isDeepSeek` matches the
        // model id intentionally, and both `chatOptions` and the clamp resolve
        // the family before the provider-kind branch.
        let arkDeepSeek = makeModel(provider: arkProvider, remoteID: "deepseek-v3.2")
        #expect(ChatReasoningSupport.resolve(.maximum, provider: arkProvider, model: arkDeepSeek).level == .maximum)

        let deepSeek = makeModel(provider: deepSeekProvider, remoteID: "deepseek-chat")
        // No native DeepSeek medium: the abstract choice lands on high.
        #expect(ChatReasoningSupport.resolve(.medium, provider: deepSeekProvider, model: deepSeek).level == .high)
        #expect(ChatReasoningSupport.resolve(.low, provider: deepSeekProvider, model: deepSeek).level == .low)

        let gpt51 = makeModel(provider: openAIChatProvider, remoteID: "gpt-5.1")
        // `maximum` is only a distinct xhigh where the model accepts it.
        #expect(ChatReasoningSupport.resolve(.maximum, provider: openAIChatProvider, model: gpt51).level == .high)
        let gpt52 = makeModel(provider: openAIChatProvider, remoteID: "gpt-5.2")
        #expect(ChatReasoningSupport.resolve(.maximum, provider: openAIChatProvider, model: gpt52).level == .maximum)

        let claude = makeModel(provider: anthropicProvider, remoteID: "claude-opus-4-5")
        #expect(ChatReasoningSupport.resolve(.maximum, provider: anthropicProvider, model: claude).level == .maximum)

        // Unknown endpoints transmit no effort field at all: an explicit
        // choice is honestly omitted rather than claimed on the wire.
        let unknown = makeModel(provider: unknownProvider, remoteID: "mystery")
        let resolution = ChatReasoningSupport.resolve(.high, provider: unknownProvider, model: unknown)
        #expect(resolution.policy == .modelDefault)
        #expect(resolution.level == nil)
        // Explicit levels never take the disable path.
        #expect(ChatReasoningSupport.resolve(.maximum, provider: dashScopeProvider,
                                             model: makeModel(provider: dashScopeProvider, remoteID: "qwen-plus")).policy
                == .modelDefault)
    }

    @Test("resolution never mutates the stored model profile")
    func resolutionIsRunScopedOnly() {
        let stored = makeModel(provider: dashScopeProvider, remoteID: "qwen-plus", reasoningEffort: .high)
        let model = ChatReasoningDecision(
            preference: .fast, appliesDisabledPolicy: true, level: nil,
            abstractLevel: nil, targetProviderID: stored.providerID,
            targetModelID: stored.id, targetRemoteModelID: stored.remoteModelID
        ).applied(to: stored)
        #expect(model.reasoningEffort == nil)
        #expect(stored.reasoningEffort == .high)
    }
}

@Suite("FloeProviders.ChatReasoning freeze coordinator")
struct ChatReasoningCoordinatorTests {

    private func decision(
        preference: ChatReasoningPreference,
        provider: ProviderProfile,
        model: ModelProfile,
        appliesDisabled: Bool = false,
        level: ModelReasoningEffort? = nil
    ) -> ChatReasoningDecision {
        ChatReasoningDecision(
            preference: preference,
            appliesDisabledPolicy: appliesDisabled,
            level: level,
            abstractLevel: preference.modelEffortOverride,
            targetProviderID: provider.id,
            targetModelID: model.id,
            targetRemoteModelID: model.remoteModelID
        )
    }

    @Test("the first resolve freezes the preference and records exactly one decision")
    func firstFreezeRecordsOnce() async throws {
        let coordinator = ChatReasoningCoordinator()
        let runID = UUID()
        let provider = dashScopeProvider
        let model = makeModel(provider: provider, remoteID: "qwen-plus", reasoningEffort: .high)
        let log = recordingLog()
        let resolution = await coordinator.resolve(
            runID: runID, provider: provider, model: model, preference: .fast,
            recorder: { runID, decision in await log.append(runID: runID, decision: decision) })
        #expect(resolution.policy == .disabled)
        #expect(resolution.model.reasoningEffort == nil)
        #expect(await log.count == 1)
        let frozen = try #require(await coordinator.decision(runID: runID))
        #expect(frozen.preference == .fast)
        #expect(frozen.appliesDisabledPolicy == true)
        // The user's stored global profile is untouched by the run copy.
        #expect(model.reasoningEffort == .high)
    }

    @Test("continuations reuse the frozen preference; a re-selected target re-derives the wire answer")
    func continuationReuseAndTargetReSelection() async throws {
        let coordinator = ChatReasoningCoordinator()
        let runID = UUID()
        let log = recordingLog()
        let dashModel = makeModel(provider: dashScopeProvider, remoteID: "qwen-plus")
        _ = await coordinator.resolve(
            runID: runID, provider: dashScopeProvider, model: dashModel, preference: .fast,
            recorder: { runID, decision in await log.append(runID: runID, decision: decision) })
        // Mid-run preference switch: the ACTIVE run keeps the frozen choice.
        let sameTarget = await coordinator.resolve(
            runID: runID, provider: dashScopeProvider, model: dashModel, preference: .maximum)
        #expect(sameTarget.policy == .disabled)
        // Re-selected model inside the same round: deterministic re-derivation
        // of the frozen PREFERENCE (fast) against the new endpoint — no
        // request, no inherit of the old target's answer.
        let astra = makeModel(provider: openAIChatProvider, remoteID: "gpt-6-astra")
        let reselected = await coordinator.resolve(
            runID: runID, provider: openAIChatProvider, model: astra, preference: .maximum)
        #expect(reselected.policy == .modelDefault)
        #expect(reselected.model.reasoningEffort == .low)
        // Unknown endpoint: frozen fast omits fields.
        let mystery = makeModel(provider: unknownProvider, remoteID: "mystery")
        let unknownTarget = await coordinator.resolve(
            runID: runID, provider: unknownProvider, model: mystery, preference: .high)
        #expect(unknownTarget.policy == .modelDefault)
        #expect(unknownTarget.model.reasoningEffort == nil)
        // Still exactly one durable record: continuations never re-record.
        #expect(await log.count == 1)
        let frozen = try #require(await coordinator.decision(runID: runID))
        #expect(frozen.preference == .fast)
    }

    @Test("post-death recovery seeds from the durable record without a second write")
    func durableSeedReuse() async throws {
        let seeded = decision(preference: .maximum, provider: dashScopeProvider,
                              model: makeModel(provider: dashScopeProvider, remoteID: "qwen-plus"),
                              level: .high)
        let coordinator = ChatReasoningCoordinator()
        let runID = UUID()
        let log = recordingLog()
        let resolution = await coordinator.resolve(
            runID: runID,
            provider: arkProvider,
            model: makeModel(provider: arkProvider, remoteID: "doubao-seed-2-1-pro"),
            preference: .fast,  // current conversation state must NOT override the seed
            seedReader: { _ in seeded },
            recorder: { runID, decision in await log.append(runID: runID, decision: decision) })
        // Frozen maximum re-derived against Ark's own model contract:
        // modelDefault, maximum clamped to high.
        #expect(resolution.policy == .modelDefault)
        #expect(resolution.model.reasoningEffort == .high)
        #expect(await log.count == 0)
        let stored = try #require(await coordinator.decision(runID: runID))
        #expect(stored.preference == .maximum)
    }

    @Test("cancelAndForget drops the RAM freeze so the next round captures the new preference")
    func forgetAllowsFreshFreeze() async throws {
        let coordinator = ChatReasoningCoordinator()
        let runID = UUID()
        let ark = makeModel(provider: arkProvider, remoteID: "deepseek-v3.2")
        _ = await coordinator.resolve(runID: runID, provider: arkProvider, model: ark, preference: .fast)
        await coordinator.cancelAndForget(runIDs: [runID])
        #expect(await coordinator.decision(runID: runID) == nil)
        let next = await coordinator.resolve(runID: runID, provider: arkProvider, model: ark, preference: .high)
        #expect(next.model.reasoningEffort == .high)
        let stored = try #require(await coordinator.decision(runID: runID))
        #expect(stored.preference == .high)
    }

    @Test("a run forgotten during the suspended seed read is never resurrected")
    func forgottenDuringSeedReadIsNotResurrected() async {
        let coordinator = ChatReasoningCoordinator()
        let runID = UUID()
        let gate = SeedReadGate()
        let seeded = decision(preference: .high, provider: dashScopeProvider,
                              model: makeModel(provider: dashScopeProvider, remoteID: "qwen-plus"),
                              level: .high)
        let resolution = await withTaskGroup(of: (ModelProfile, ProviderReasoningPolicy).self) { group in
            group.addTask {
                await coordinator.resolve(
                    runID: runID, provider: dashScopeProvider,
                    model: makeModel(provider: dashScopeProvider, remoteID: "qwen-plus"),
                    preference: .fast,
                    seedReader: { _ in
                        await gate.waitForOpen()
                        return seeded
                    })
            }
            await gate.waitUntilEntered()
            await coordinator.cancelAndForget(runID: runID)
            await gate.open()
            return await group.next()!
        }
        #expect(resolution.1 == .modelDefault)
        #expect(resolution.0.reasoningEffort == makeModel(provider: dashScopeProvider, remoteID: "qwen-plus").reasoningEffort)
        #expect(await coordinator.decision(runID: runID) == nil)
    }

    @Test("RAM-bounded cache forgets the oldest run past its limit")
    func cacheIsBounded() async {
        let coordinator = ChatReasoningCoordinator(cacheLimit: 2)
        let ark = makeModel(provider: arkProvider, remoteID: "deepseek-v3.2")
        let first = UUID()
        let second = UUID()
        let third = UUID()
        _ = await coordinator.resolve(runID: first, provider: arkProvider, model: ark, preference: .fast)
        _ = await coordinator.resolve(runID: second, provider: arkProvider, model: ark, preference: .fast)
        _ = await coordinator.resolve(runID: third, provider: arkProvider, model: ark, preference: .fast)
        #expect(await coordinator.decision(runID: first) == nil)
        #expect(await coordinator.decision(runID: second) != nil)
        #expect(await coordinator.decision(runID: third) != nil)
    }
}

@Suite("FloeProviders.ChatReasoning durable records and snapshots")
struct ChatReasoningPersistenceShapeTests {

    private var sample: ChatReasoningDecision {
        ChatReasoningDecision(
            preference: .high, appliesDisabledPolicy: false, level: .high,
            abstractLevel: .high, targetProviderID: UUID(), targetModelID: UUID(),
            targetRemoteModelID: "qwen-plus")
    }

    @Test("payload round-trips through the invisible status event shape")
    func payloadRoundTrip() {
        let decision = sample
        let json = decision.payloadJSON()
        #expect(json.contains("\"chatReasoning\""))
        let decoded = ChatReasoningDecision.decision(fromEventPayloadJSON: json)
        #expect(decoded == decision)
    }

    @Test("foreign or malformed payloads decode to no decision")
    func foreignPayloadsIgnored() {
        #expect(ChatReasoningDecision.decision(fromEventPayloadJSON: "{}") == nil)
        #expect(ChatReasoningDecision.decision(fromEventPayloadJSON: "{\"state\":\"preparing\"}") == nil)
        #expect(ChatReasoningDecision.decision(fromEventPayloadJSON: "not json") == nil)
        #expect(ChatReasoningDecision.decision(
            fromEventPayloadJSON: "{\"chatReasoning\":{\"preference\":\"turbo\"}}") == nil)
    }

    @Test("findDecision reads only status events and takes the first chat record")
    func findDecisionScansStatusThread() {
        let decision = sample
        let runID = UUID()
        let events = [
            RunEventRecord(runID: runID, sequence: 1, kind: .status, payloadJSON: "{\"state\":\"preparing\"}"),
            RunEventRecord(runID: runID, sequence: 2, kind: .assistantText,
                           payloadJSON: decision.payloadJSON()),
            RunEventRecord(runID: runID, sequence: 3, kind: .status,
                           payloadJSON: decision.payloadJSON()),
        ]
        let found = ChatReasoningSupport.findDecision(in: events)
        #expect(found == decision)
        #expect(ChatReasoningSupport.findDecision(in: Array(events.dropLast())) == nil)
    }

    @Test("absent rows and missing keys default to fast; explicit snapshots round-trip")
    func snapshotDefaults() throws {
        let empty = try JSONDecoder().decode(ChatConversationPreferences.self, from: Data("{}".utf8))
        #expect(empty.effectiveChatReasoning == .fast)
        #expect(empty.chatReasoning == nil)
        let explicit = try JSONDecoder().decode(
            ChatConversationPreferences.self, from: Data(#"{"chatReasoning":"maximum"}"#.utf8))
        #expect(explicit.effectiveChatReasoning == .maximum)
        // An unknown token is a decode failure (the store treats an unreadable
        // snapshot like an absent one) — never a silent downgrade to a tier.
        let bad = try? JSONDecoder().decode(
            ChatConversationPreferences.self, from: Data(#"{"chatReasoning":"turbo"}"#.utf8))
        #expect(bad == nil)
        // The durable snapshot is a plain `JSONEncoder` payload
        // (`SQLiteChatPreferenceStore.encode`), so an unset optional is
        // omitted rather than written as an explicit null; the absent key must
        // still decode back to the product default instead of failing the
        // reader. An explicit choice is carried by value and round-trips.
        let defaultSnapshotJSON = try JSONEncoder().encode(ChatConversationPreferences())
        let defaultSnapshot = try JSONDecoder().decode(
            ChatConversationPreferences.self, from: defaultSnapshotJSON)
        #expect(defaultSnapshot.chatReasoning == nil)
        #expect(defaultSnapshot.effectiveChatReasoning == .fast)
        let explicitSnapshotJSON = try JSONEncoder().encode(
            ChatConversationPreferences(chatReasoning: .maximum))
        #expect(String(decoding: explicitSnapshotJSON, as: UTF8.self).contains("maximum"))
        let explicitSnapshot = try JSONDecoder().decode(
            ChatConversationPreferences.self, from: explicitSnapshotJSON)
        #expect(explicitSnapshot.chatReasoning == .maximum)
        #expect(explicitSnapshot.effectiveChatReasoning == .maximum)
    }
}
