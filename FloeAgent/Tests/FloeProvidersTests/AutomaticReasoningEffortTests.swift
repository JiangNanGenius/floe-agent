// FloeProvidersTests — Automatic reasoning-effort decision contract.
//
// Deterministic, offline: synthetic provider/model fixtures plus a counting
// fake classifier. The fakes are explicitly NOT live providers — no request
// ever leaves this process. The real-auxiliary-model qualification hook lives
// in FloeAppTests (`LiveAutomaticReasoningEffortQualificationTests`) and is
// gated behind an explicit opt-in environment variable.

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

private let openAIProvider = makeProvider(
    kind: .openAI, wireProtocol: .openAIChatCompletions, host: "api.openai.com")
private let openAIResponsesProvider = makeProvider(
    kind: .openAI, wireProtocol: .openAIResponses, host: "api.openai.com")
private let deepSeekProvider = makeProvider(
    kind: .custom, wireProtocol: .openAIChatCompletions, host: "api.deepseek.com")
private let arkProvider = makeProvider(
    kind: .volcengineArk, wireProtocol: .openAIChatCompletions, host: "ark.cn-beijing.volces.com")
private let dashScopeProvider = makeProvider(
    kind: .custom, wireProtocol: .openAIChatCompletions, host: "dashscope.aliyuncs.com")
private let anthropicProvider = makeProvider(
    kind: .anthropic, wireProtocol: .anthropicMessages, host: "api.anthropic.com")
private let unknownProvider = makeProvider(
    kind: .custom, wireProtocol: .openAIChatCompletions, host: "gateway.example.com")
private let localProvider = makeProvider(
    kind: .local, wireProtocol: .openAIChatCompletions, host: "localhost")

private func decision(
    _ level: ModelReasoningEffort?,
    source: AutomaticReasoningEffortDecision.Source = .auxiliary,
    provider: ProviderProfile,
    model: ModelProfile,
    errorCategory: String? = nil,
    abstractLevel: ModelReasoningEffort? = nil
) -> AutomaticReasoningEffortDecision {
    AutomaticReasoningEffortDecision(
        source: source,
        level: level,
        targetProviderID: provider.id,
        targetModelID: model.id,
        targetRemoteModelID: model.remoteModelID,
        targetCapabilitiesRawValue: model.capabilities.rawValue,
        latencyMilliseconds: 12,
        errorCategory: errorCategory,
        abstractLevel: abstractLevel
    )
}

/// Deterministic gate for the durable-seed read: the test can delete the run
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

private actor StubClassifier: AutomaticReasoningEffortClassifying {
    private(set) var calls = 0
    private let outcome: Result<ModelReasoningEffort, Error>
    private let delay: Duration?

    init(
        _ outcome: Result<ModelReasoningEffort, Error> = .success(.high),
        delay: Duration? = nil
    ) {
        self.outcome = outcome
        self.delay = delay
    }

    func classify(_ input: String) async throws -> ModelReasoningEffort {
        calls += 1
        if let delay {
            try await Task.sleep(for: delay)
        }
        return try outcome.get()
    }
}

private actor DecisionLog {
    private(set) var decisions: [AutomaticReasoningEffortDecision] = []

    func append(_ decision: AutomaticReasoningEffortDecision) {
        decisions.append(decision)
    }
}

/// A classifier that deliberately ignores cancellation (it swallows the
/// sleep cancellation error) so tests can prove a late completion can never
/// overwrite a frozen fallback or resurrect a deleted run's decision.
private actor IgnoringCancellationClassifier: AutomaticReasoningEffortClassifying {
    private(set) var calls = 0
    private let outcome: Result<ModelReasoningEffort, Error>
    private let delay: Duration

    init(outcome: Result<ModelReasoningEffort, Error>, delay: Duration) {
        self.outcome = outcome
        self.delay = delay
    }

    func classify(_ input: String) async throws -> ModelReasoningEffort {
        calls += 1
        try? await Task.sleep(for: delay)
        return try outcome.get()
    }
}

// MARK: - Wire-family support

@Suite("Automatic reasoning effort")
struct AutomaticReasoningEffortTests {

    @Test("Only families whose protocol transmits an effort value are supported")
    func supportPredicateMatchesWireFamilies() {
        let gpt = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        #expect(AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: openAIProvider, model: gpt))
        #expect(AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: openAIResponsesProvider, model: makeModel(
                provider: openAIResponsesProvider, remoteID: "gpt-5.2")))

        let deepSeek = makeModel(provider: deepSeekProvider, remoteID: "deepseek-chat")
        #expect(AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: deepSeekProvider, model: deepSeek))
        // The Responses adapter never forwards DeepSeek's chat-shaped
        // reasoning fields, so no decision may be requested there.
        #expect(!AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: makeProvider(kind: .custom, wireProtocol: .openAIResponses,
                                   host: "api.deepseek.com"),
            model: deepSeek))

        #expect(AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: arkProvider,
            model: makeModel(provider: arkProvider, remoteID: "doubao-seed-2-1-pro")))
        #expect(AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: dashScopeProvider,
            model: makeModel(provider: dashScopeProvider, remoteID: "qwen3-max")))
        #expect(AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: anthropicProvider,
            model: makeModel(provider: anthropicProvider, remoteID: "claude-opus-4-6")))
        #expect(!AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: anthropicProvider,
            model: makeModel(provider: anthropicProvider, remoteID: "claude-3-5-sonnet-latest")))

        #expect(!AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: unknownProvider,
            model: makeModel(provider: unknownProvider, remoteID: "mystery-model")))
        #expect(!AutomaticReasoningEffortSupport.supportsVariableEffort(
            provider: localProvider,
            model: makeModel(provider: localProvider, remoteID: "mlx-community/Qwen3-4B")))
    }

    @Test("Clamping freezes the tier the wire will actually use")
    func clampFreezesTheActualWireTier() {
        let deepSeek = makeModel(provider: deepSeekProvider, remoteID: "deepseek-chat")
        #expect(AutomaticReasoningEffortSupport.clamped(
            .medium, provider: deepSeekProvider, model: deepSeek) == .high)
        #expect(AutomaticReasoningEffortSupport.clamped(
            .maximum, provider: deepSeekProvider, model: deepSeek) == .maximum)
        #expect(AutomaticReasoningEffortSupport.clamped(
            .low, provider: deepSeekProvider, model: deepSeek) == .low)

        let ark = makeModel(provider: arkProvider, remoteID: "doubao-seed-2-1-pro")
        #expect(AutomaticReasoningEffortSupport.clamped(
            .maximum, provider: arkProvider, model: ark) == .high)
        #expect(AutomaticReasoningEffortSupport.clamped(
            .medium, provider: arkProvider, model: ark) == .medium)

        let qwen = makeModel(provider: dashScopeProvider, remoteID: "qwen3-max")
        #expect(AutomaticReasoningEffortSupport.clamped(
            .maximum, provider: dashScopeProvider, model: qwen) == .maximum)

        let gpt52 = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        #expect(AutomaticReasoningEffortSupport.clamped(
            .maximum, provider: openAIProvider, model: gpt52) == .maximum)
        let gpt51 = makeModel(provider: openAIProvider, remoteID: "gpt-5.1")
        #expect(AutomaticReasoningEffortSupport.clamped(
            .maximum, provider: openAIProvider, model: gpt51) == .high)

        let opus = makeModel(provider: anthropicProvider, remoteID: "claude-opus-4-6")
        #expect(AutomaticReasoningEffortSupport.clamped(
            .maximum, provider: anthropicProvider, model: opus) == .maximum)
    }

    @Test("The reported wire token is the exact adapter value")
    func wireEffortTokensMatchAdapters() {
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider,
            model: makeModel(provider: openAIProvider, remoteID: "gpt-5.2")) == nil)

        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider,
            model: makeModel(provider: openAIProvider, remoteID: "gpt-5.2",
                             reasoningEffort: .high)) == "high")
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider,
            model: makeModel(provider: openAIProvider, remoteID: "gpt-5.2",
                             reasoningEffort: .maximum)) == "xhigh")
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIResponsesProvider,
            model: makeModel(provider: openAIResponsesProvider, remoteID: "gpt-5.2",
                             reasoningEffort: .low)) == "low")

        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: deepSeekProvider,
            model: makeModel(provider: deepSeekProvider, remoteID: "deepseek-chat",
                             reasoningEffort: .medium)) == "high")
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: deepSeekProvider,
            model: makeModel(provider: deepSeekProvider, remoteID: "deepseek-chat",
                             reasoningEffort: .maximum)) == "max")
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: arkProvider,
            model: makeModel(provider: arkProvider, remoteID: "doubao-seed-2-1-pro",
                             reasoningEffort: .maximum)) == "high")
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: anthropicProvider,
            model: makeModel(provider: anthropicProvider, remoteID: "claude-opus-4-6",
                             reasoningEffort: .maximum)) == "max")
    }

    @Test("A simple and a deep choice both land on the real wire option")
    func validChoicesMapToWireOptions() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")

        let simple = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: target,
            boundedInput: "Request: say hi", classifier: StubClassifier(.success(.low)),
            ingress: .freshRound)
        #expect(simple.reasoningEffort == .low)
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider, model: simple) == "low")

        let deep = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: target,
            boundedInput: "Request: redesign the scheduler",
            classifier: StubClassifier(.success(.maximum)), ingress: .freshRound)
        #expect(deep.reasoningEffort == .maximum)
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider, model: deep) == "xhigh")

        let medium = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: target,
            boundedInput: "Request: fix a failing test",
            classifier: StubClassifier(.success(.medium)), ingress: .freshRound)
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider, model: medium) == "medium")
    }

    @Test("The response parser accepts only one bounded structured token")
    func responseParserIsStrict() {
        #expect(AutomaticReasoningEffortResponse.parse(#"{"effort":"high"}"#) == .high)
        #expect(AutomaticReasoningEffortResponse.parse(#"  {"effort":"Medium"} "#
            .trimmingCharacters(in: .whitespaces)) == .medium)
        #expect(AutomaticReasoningEffortResponse.parse("```json\n{\"effort\":\"maximum\"}\n```") == .maximum)

        #expect(AutomaticReasoningEffortResponse.parse("high") == nil)
        #expect(AutomaticReasoningEffortResponse.parse("I would say high.") == nil)
        #expect(AutomaticReasoningEffortResponse.parse("Sure: {\"effort\":\"high\"}") == nil)
        #expect(AutomaticReasoningEffortResponse.parse(#"{"effort":"max"}"#) == nil)
        #expect(AutomaticReasoningEffortResponse.parse(#"{"level":"high"}"#) == nil)
        #expect(AutomaticReasoningEffortResponse.parse(
            "{\"effort\":\"" + String(repeating: "x", count: 3_000) + "\"}") == nil)
    }

    @Test("Classifier input is bounded and never carries file names or content")
    func inputBuilderIsBoundedAndMinimal() {
        let longGoal = String(repeating: "a", count: 3_000) + "TAIL"
        let attachments = (0..<12).map { index in
            AttachmentRef(
                kind: index.isMultiple(of: 2) ? .document : .image,
                displayName: "private-name-\(index).pdf",
                uti: "com.adobe.pdf",
                byteCount: 1_024 * (index + 1)
            )
        }
        let input = AutomaticReasoningEffortInputBuilder.build(
            goal: longGoal, attachments: attachments)
        #expect(!input.contains("TAIL"))
        #expect(input.count < AutomaticReasoningEffortInputBuilder.maximumGoalCharacters + 800)
        #expect(!input.contains("private-name-"))
        #expect(input.contains("ext=pdf"))
        #expect(input.contains("kind=document"))
        let attachmentLines = input.split(separator: "\n").filter { $0.hasPrefix("- Attachment ") }
        #expect(attachmentLines.count == AutomaticReasoningEffortInputBuilder.maximumAttachmentMetadataCount)
    }

    @Test("The durable decision record round-trips and carries no input text")
    func decisionPayloadIsTextFree() {
        let targetProvider = openAIProvider
        let target = makeModel(provider: targetProvider, remoteID: "gpt-5.2")
        let record = decision(.high, provider: targetProvider, model: target)
        let payload = record.payloadJSON()
        #expect(payload.contains("\"automaticReasoningEffort\""))
        #expect(!payload.contains("User request text"))
        #expect(!payload.lowercased().contains("apikey"))

        let event = RunEventRecord(
            runID: UUID(), sequence: 3, kind: .status, payloadJSON: payload)
        #expect(AutomaticReasoningEffortDecision.find(in: [event]) == record)
        #expect(AutomaticReasoningEffortDecision.find(in: [
            RunEventRecord(runID: UUID(), sequence: 1, kind: .assistantText,
                           payloadJSON: payload)
        ]) == nil)
    }

    @Test("Concurrent starts for one round join a single helper request")
    func concurrentStartsJoinOneRequest() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let classifier = StubClassifier(.success(.high), delay: .milliseconds(80))
        let log = DecisionLog()
        let runID = UUID()

        let resolved = await withTaskGroup(of: ModelProfile.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await coordinator.resolvedModel(
                        runID: runID,
                        provider: openAIProvider,
                        model: target,
                        boundedInput: "Request: hello",
                        classifier: classifier,
                        ingress: .freshRound,
                        recorder: { _, decision in await log.append(decision) })
                }
            }
            var results: [ModelProfile] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
        #expect(await classifier.calls == 1)
        #expect(resolved.count == 6)
        for model in resolved {
            #expect(model.reasoningEffort == .high)
            #expect(AutomaticReasoningEffortSupport.wireEffort(
                provider: openAIProvider, model: model) == "high")
        }
        #expect(await log.decisions.count == 1)
        #expect(await log.decisions.first?.source == .auxiliary)
    }

    @Test("Resume, retry, 2 steers and tool turns reuse the frozen decision with no resubmit")
    func resumeReusesFrozenDecision() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let classifier = StubClassifier(.success(.medium))
        let runID = UUID()

        let first = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: target,
            boundedInput: "Request: write a parser", classifier: classifier,
            ingress: .freshRound)
        #expect(first.reasoningEffort == .medium)
        #expect(await classifier.calls == 1)

        // A resumed service, a retried run, two explicit steering turns and
        // two tool-result model iterations all re-enter with the same run
        // identity: zero additional helper requests.
        let reentryInputs = ["steer#1", "steer#2", "toolTurn#1", "toolTurn#2"]
        for input in reentryInputs {
            let again = await coordinator.resolvedModel(
                runID: runID, provider: openAIProvider, model: target,
                boundedInput: input, classifier: classifier,
                ingress: .continuation)
            #expect(again.reasoningEffort == .medium)
        }
        #expect(await classifier.calls == 1)
        #expect(await coordinator.decision(runID: runID)?.level == .medium)
    }

    @Test("A manual selection and an unsupported family never call the helper")
    func manualAndUnsupportedBypassTheHelper() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let classifier = StubClassifier(.success(.maximum))

        let manual = makeModel(provider: openAIProvider, remoteID: "gpt-5.2",
                               reasoningEffort: .low)
        let manualResult = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: manual,
            boundedInput: "Request: hello", classifier: classifier,
            ingress: .freshRound)
        #expect(manualResult.reasoningEffort == .low)

        let unsupported = makeModel(provider: unknownProvider, remoteID: "mystery-model")
        let unsupportedResult = await coordinator.resolvedModel(
            runID: UUID(), provider: unknownProvider, model: unsupported,
            boundedInput: "Request: hello", classifier: classifier,
            ingress: .freshRound)
        #expect(unsupportedResult.reasoningEffort == nil)
        #expect(unsupportedResult.effectiveReasoningEffort == .automatic)

        #expect(await classifier.calls == 0)
    }

    @Test("An unconfigured helper falls back to the provider default, bounded")
    func unconfiguredHelperFallsBack() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let log = DecisionLog()
        let runID = UUID()

        let resolved = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: target,
            boundedInput: "Request: hello", classifier: nil,
            ingress: .freshRound,
            recorder: { _, decision in await log.append(decision) })
        #expect(resolved.effectiveReasoningEffort == .automatic)
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider, model: resolved) == nil)
        let recorded = await log.decisions.first
        #expect(recorded?.source == .fallback)
        #expect(recorded?.level == nil)
        #expect(recorded?.errorCategory == AutomaticReasoningEffortFailureCategory.unconfigured.rawValue)
        // The fallback is frozen too, so a resume does not resubmit.
        _ = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: target,
            boundedInput: "Request: hello", classifier: StubClassifier(.success(.maximum)),
            ingress: .continuation)
        #expect(await coordinator.decision(runID: runID)?.source == .fallback)
    }

    @Test("A slow helper is cut off by the deadline and falls back")
    func timeoutFallsBackBounded() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(80))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let classifier = StubClassifier(.success(.maximum), delay: .seconds(30))
        let log = DecisionLog()
        let started = ContinuousClock.now

        let resolved = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: target,
            boundedInput: "Request: deep work", classifier: classifier,
            ingress: .freshRound,
            recorder: { _, decision in await log.append(decision) })
        let elapsed = started.duration(to: .now)

        #expect(resolved.effectiveReasoningEffort == .automatic)
        #expect(elapsed < .seconds(5))
        #expect(await classifier.calls == 1)
        let recorded = await log.decisions.first
        #expect(recorded?.source == .fallback)
        #expect(recorded?.errorCategory == AutomaticReasoningEffortFailureCategory.timedOut.rawValue)
    }

    @Test("Malformed and provider-error answers fall back with their category")
    func malformedAndProviderFailuresFallBack() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")

        let malformed = StubClassifier(.failure(AutomaticReasoningEffortClassifyFailure(
            category: .malformedResponse)))
        let malformedLog = DecisionLog()
        _ = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: target,
            boundedInput: "Request: hello", classifier: malformed,
            ingress: .freshRound,
            recorder: { _, decision in await malformedLog.append(decision) })
        let malformedDecision = await malformedLog.decisions.first
        #expect(malformedDecision?.source == .fallback)
        #expect(malformedDecision?.errorCategory == "malformedResponse")

        let providerFailure = StubClassifier(.failure(AutomaticReasoningEffortClassifyFailure(
            category: .providerError, detail: "httpError/http500")))
        let providerLog = DecisionLog()
        _ = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: target,
            boundedInput: "Request: hello", classifier: providerFailure,
            ingress: .freshRound,
            recorder: { _, decision in await providerLog.append(decision) })
        let providerDecision = await providerLog.decisions.first
        #expect(providerDecision?.errorCategory == "providerError")
        #expect(providerDecision?.source == .fallback)
    }

    @Test("Cancelling the caller never applies a late helper result")
    func cancelledCallerDoesNotApply() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(80))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let classifier = StubClassifier(.success(.maximum), delay: .seconds(30))
        let runID = UUID()

        let caller = Task {
            await coordinator.resolvedModel(
                runID: runID, provider: openAIProvider, model: target,
                boundedInput: "Request: deep work", classifier: classifier,
                ingress: .freshRound)
        }
        try? await Task.sleep(for: .milliseconds(20))
        caller.cancel()
        let resolved = await caller.value
        #expect(resolved.effectiveReasoningEffort == .automatic)
        #expect(await classifier.calls == 1)
    }

    @Test("Destroying a round cancels its helper and drops the decision")
    func cancelAndForgetDropsRequestAndDecision() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(80))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let classifier = StubClassifier(.success(.maximum), delay: .seconds(30))
        let runID = UUID()

        let caller = Task {
            await coordinator.resolvedModel(
                runID: runID, provider: openAIProvider, model: target,
                boundedInput: "Request: deep work", classifier: classifier,
                ingress: .freshRound)
        }
        try? await Task.sleep(for: .milliseconds(20))
        await coordinator.cancelAndForget(runID: runID)
        let resolved = await caller.value
        #expect(resolved.effectiveReasoningEffort == .automatic)
        #expect(await coordinator.decision(runID: runID) == nil)
        // A replacement round (new identity) is unaffected and can decide.
        let replacement = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: target,
            boundedInput: "Request: hello", classifier: StubClassifier(.success(.low)),
            ingress: .freshRound)
        #expect(replacement.reasoningEffort == .low)
    }

    @Test("A re-selected model inside the same round re-clamps the frozen choice with no second request")
    func sameRoundModelReselectionReclampsWithoutResubmit() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let firstTarget = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let secondTarget = makeModel(provider: openAIProvider, remoteID: "gpt-5.1")
        let runID = UUID()

        let first = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: firstTarget,
            boundedInput: "Request: hello", classifier: StubClassifier(.success(.maximum)),
            ingress: .freshRound)
        #expect(first.reasoningEffort == .maximum)

        // Continue with a different model is still the SAME round: the frozen
        // abstract choice is reused, re-clamped to the new target's real wire
        // tier, and the second classifier is never asked.
        let secondClassifier = StubClassifier(.success(.low))
        let second = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: secondTarget,
            boundedInput: "Request: hello", classifier: secondClassifier,
            ingress: .continuation)
        #expect(second.reasoningEffort == .high)
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider, model: second) == "high")
        #expect(await secondClassifier.calls == 0)
        let frozen = await coordinator.decision(runID: runID)
        #expect(frozen?.targetModelID == secondTarget.id)
        #expect(frozen?.level == .high)
        #expect(frozen?.source == .auxiliary)
    }

    @Test("A fresh-ingress relaunch of the same run identity reuses the frozen choice")
    func freshRelaunchReusesFrozenChoice() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let firstTarget = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let secondTarget = makeModel(provider: openAIProvider, remoteID: "gpt-5.1")
        let runID = UUID()

        let first = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: firstTarget,
            boundedInput: "Request: hello", classifier: StubClassifier(.success(.high)),
            ingress: .freshRound)
        #expect(first.reasoningEffort == .high)

        // A crash-retry relaunch with the same run identity (a scheduled
        // occurrence's frozen runID) must not decide a second time.
        let relaunchClassifier = StubClassifier(.success(.maximum))
        let relaunch = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: secondTarget,
            boundedInput: "Request: hello", classifier: relaunchClassifier,
            ingress: .freshRound)
        #expect(relaunch.reasoningEffort == .high)
        #expect(await relaunchClassifier.calls == 0)
    }

    @Test("A durable seed is reused after process death without resubmitting")
    func durableSeedReusesDecision() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let seeded = decision(.maximum, provider: openAIProvider, model: target)
        let classifier = StubClassifier(.success(.low))
        let runID = UUID()

        // First ingress after a crash: the durable decision is recovered and
        // never resubmitted.
        let resolved = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: target,
            boundedInput: "Request: hello", classifier: classifier,
            ingress: .continuation,
            seedReader: { _ in seeded })
        #expect(resolved.reasoningEffort == .maximum)
        #expect(await classifier.calls == 0)
        #expect(await coordinator.decision(runID: runID) == seeded)

        // A seed recorded for a DIFFERENT target (the model changed inside
        // the original run) is never applied raw and never resubmitted: its
        // abstract level is re-clamped for the current target.
        let otherTarget = makeModel(provider: openAIProvider, remoteID: "gpt-5.1")
        let otherRunID = UUID()
        let other = await coordinator.resolvedModel(
            runID: otherRunID, provider: openAIProvider, model: otherTarget,
            boundedInput: "Request: hello", classifier: classifier,
            ingress: .continuation,
            seedReader: { _ in seeded })
        #expect(other.reasoningEffort == .high)
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider, model: other) == "high")
        #expect(await classifier.calls == 0)
        let recovered = await coordinator.decision(runID: otherRunID)
        #expect(recovered?.targetModelID == otherTarget.id)
        #expect(recovered?.level == .high)
    }

    @Test("A run that started manual/unsupported freezes the provider default on its auto resume, with no late decision")
    func manualToAutomaticResumeDoesNotDecideLate() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let classifier = StubClassifier(.success(.maximum))
        let runID = UUID()
        let log = DecisionLog()
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")

        // The round starts manual: nothing is decided, nothing is recorded.
        let manual = makeModel(provider: openAIProvider, remoteID: "gpt-5.2",
                               reasoningEffort: .low)
        let started = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: manual,
            boundedInput: "Request: hello", classifier: classifier,
            ingress: .freshRound,
            recorder: { _, decision in await log.append(decision) })
        #expect(started.reasoningEffort == .low)
        #expect(await coordinator.decision(runID: runID) == nil)

        // The user switches the SAME round to automatic and resumes: the
        // helper must not start its first request late — the provider's own
        // default is kept and frozen instead.
        let resumed = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: target,
            boundedInput: "Request: hello", classifier: classifier,
            ingress: .continuation,
            recorder: { _, decision in await log.append(decision) })
        #expect(resumed.effectiveReasoningEffort == .automatic)
        #expect(await classifier.calls == 0)
        let frozen = await coordinator.decision(runID: runID)
        #expect(frozen?.source == .fallback)
        #expect(frozen?.level == nil)
        #expect(await log.decisions.count == 1)
    }

    @Test("Normal Stop cancels a pending classifier promptly and keeps an already frozen choice")
    func cancelPendingWakesPromptlyAndPreservesFrozenChoice() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .seconds(30))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")

        // A pending classification is cancelled promptly: the caller returns
        // long before either the 30 s deadline or the 30 s helper response,
        // and nothing is frozen from a cancelled attempt.
        let slowClassifier = StubClassifier(.success(.maximum), delay: .seconds(30))
        let pendingRunID = UUID()
        let pendingLog = DecisionLog()
        let caller = Task {
            await coordinator.resolvedModel(
                runID: pendingRunID, provider: openAIProvider, model: target,
                boundedInput: "Request: deep work", classifier: slowClassifier,
                ingress: .freshRound,
                recorder: { _, decision in await pendingLog.append(decision) })
        }
        try? await Task.sleep(for: .milliseconds(30))
        let started = ContinuousClock.now
        await coordinator.cancelPending(runID: pendingRunID)
        let resolved = await caller.value
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .seconds(5))
        #expect(resolved.effectiveReasoningEffort == .automatic)
        #expect(await coordinator.decision(runID: pendingRunID) == nil)
        #expect(await pendingLog.decisions.isEmpty)

        // A same-round Continue afterwards freezes the provider default once
        // and never submits a late second request.
        let afterStop = await coordinator.resolvedModel(
            runID: pendingRunID, provider: openAIProvider, model: target,
            boundedInput: "Request: deep work", classifier: slowClassifier,
            ingress: .continuation,
            recorder: { _, decision in await pendingLog.append(decision) })
        #expect(afterStop.effectiveReasoningEffort == .automatic)
        #expect(await slowClassifier.calls == 1)
        #expect(await coordinator.decision(runID: pendingRunID)?.source == .fallback)

        // An already frozen choice survives a normal Stop and is reused by
        // the same-round resume with no new request.
        let frozenRunID = UUID()
        let frozenClassifier = StubClassifier(.success(.high))
        let first = await coordinator.resolvedModel(
            runID: frozenRunID, provider: openAIProvider, model: target,
            boundedInput: "Request: hello", classifier: frozenClassifier,
            ingress: .freshRound)
        #expect(first.reasoningEffort == .high)
        await coordinator.cancelPending(runID: frozenRunID)
        #expect(await coordinator.decision(runID: frozenRunID)?.level == .high)
        let reused = await coordinator.resolvedModel(
            runID: frozenRunID, provider: openAIProvider, model: target,
            boundedInput: "Request: continue", classifier: frozenClassifier,
            ingress: .continuation)
        #expect(reused.reasoningEffort == .high)
        #expect(await frozenClassifier.calls == 1)
    }

    @Test("A target change while only an old request is in flight freezes the fallback and drops the late result")
    func supersededInflightRequestFreezesFallback() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .seconds(30))
        let firstTarget = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let secondTarget = makeModel(provider: openAIProvider, remoteID: "gpt-5.1")
        let runID = UUID()
        let log = DecisionLog()

        // A classifier that ignores cancellation and eventually succeeds for
        // the OLD target.
        let ignoring = IgnoringCancellationClassifier(
            outcome: .success(.maximum), delay: .milliseconds(250))
        let pending = Task {
            await coordinator.resolvedModel(
                runID: runID, provider: openAIProvider, model: firstTarget,
                boundedInput: "Request: hello", classifier: ignoring,
                ingress: .freshRound,
                recorder: { _, decision in await log.append(decision) })
        }
        try? await Task.sleep(for: .milliseconds(30))

        // The model is re-selected while the old request is still in flight:
        // it is cancelled, the provider default is frozen for the NEW target,
        // and no second request is submitted.
        let secondClassifier = StubClassifier(.success(.low))
        let started = ContinuousClock.now
        let second = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: secondTarget,
            boundedInput: "Request: hello", classifier: secondClassifier,
            ingress: .continuation,
            recorder: { _, decision in await log.append(decision) })
        #expect(started.duration(to: .now) < .seconds(5))
        #expect(second.effectiveReasoningEffort == .automatic)
        #expect(await secondClassifier.calls == 0)
        let superseded = await coordinator.decision(runID: runID)
        #expect(superseded?.source == .fallback)
        #expect(superseded?.targetModelID == secondTarget.id)
        #expect(superseded?.errorCategory == AutomaticReasoningEffortFailureCategory.cancelled.rawValue)

        // The old request's late success must not be applied to the new
        // target nor rewrite the frozen fallback.
        _ = await pending.value
        try? await Task.sleep(for: .milliseconds(400))
        let afterLate = await coordinator.decision(runID: runID)
        #expect(afterLate?.level == nil)
        #expect(afterLate?.targetModelID == secondTarget.id)
        #expect(await log.decisions.count == 1)
    }

    @Test("Deleting a run forgets its decision and a late helper result cannot resurrect it")
    func deletionForgetsAndLateResultCannotResurrect() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .seconds(30))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let runID = UUID()
        let log = DecisionLog()
        let ignoring = IgnoringCancellationClassifier(
            outcome: .success(.maximum), delay: .milliseconds(250))

        let caller = Task {
            await coordinator.resolvedModel(
                runID: runID, provider: openAIProvider, model: target,
                boundedInput: "Request: hello", classifier: ignoring,
                ingress: .freshRound,
                recorder: { _, decision in await log.append(decision) })
        }
        try? await Task.sleep(for: .milliseconds(30))
        await coordinator.cancelAndForget(runID: runID)
        let resolved = await caller.value
        #expect(resolved.effectiveReasoningEffort == .automatic)

        // The ignoring helper completes afterwards: no decision and no
        // durable record may appear for the deleted run.
        try? await Task.sleep(for: .milliseconds(500))
        #expect(await coordinator.decision(runID: runID) == nil)
        #expect(await log.decisions.isEmpty)
    }

    @Test("The production default deadline is two seconds and falls back bounded")
    func productionDefaultDeadlineIsTwoSeconds() async {
        // No injected timeout: exercises the production default directly.
        let coordinator = AutomaticReasoningEffortCoordinator()
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let classifier = StubClassifier(.success(.maximum), delay: .seconds(30))
        let log = DecisionLog()
        let started = ContinuousClock.now

        let resolved = await coordinator.resolvedModel(
            runID: UUID(), provider: openAIProvider, model: target,
            boundedInput: "Request: deep work", classifier: classifier,
            ingress: .freshRound,
            recorder: { _, decision in await log.append(decision) })
        let elapsed = started.duration(to: .now)

        #expect(resolved.effectiveReasoningEffort == .automatic)
        #expect(elapsed >= .seconds(1))
        #expect(elapsed < .seconds(5))
        #expect(await classifier.calls == 1)
        let recorded = await log.decisions.first
        #expect(recorded?.source == .fallback)
        #expect(recorded?.errorCategory == AutomaticReasoningEffortFailureCategory.timedOut.rawValue)
    }

    @Test("A→B→A inside one round keeps the abstract helper choice with a single call")
    func abstractChoiceSurvivesRepeatedReselection() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        // gpt-5.1 downgrades `maximum` to `high`; gpt-5.2 accepts xhigh.
        let downgraded = makeModel(provider: openAIProvider, remoteID: "gpt-5.1")
        let full = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let runID = UUID()
        let classifier = StubClassifier(.success(.maximum))
        let secondClassifier = StubClassifier(.success(.low))
        let thirdClassifier = StubClassifier(.success(.low))

        let first = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: downgraded,
            boundedInput: "Request: hello", classifier: classifier,
            ingress: .freshRound)
        #expect(first.reasoningEffort == .high)
        #expect(await coordinator.decision(runID: runID)?.abstractLevel == .maximum)

        let second = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: full,
            boundedInput: "Request: hello", classifier: secondClassifier,
            ingress: .continuation)
        #expect(second.reasoningEffort == .maximum)
        #expect(AutomaticReasoningEffortSupport.wireEffort(
            provider: openAIProvider, model: second) == "xhigh")

        let third = await coordinator.resolvedModel(
            runID: runID, provider: openAIProvider, model: downgraded,
            boundedInput: "Request: hello", classifier: thirdClassifier,
            ingress: .continuation)
        #expect(third.reasoningEffort == .high)
        #expect(await classifier.calls == 1)
        #expect(await secondClassifier.calls == 0)
        #expect(await thirdClassifier.calls == 0)
        let frozen = await coordinator.decision(runID: runID)
        #expect(frozen?.abstractLevel == .maximum)
        #expect(frozen?.targetModelID == downgraded.id)
    }

    @Test("A deletion during the durable seed read cannot resurrect the run")
    func deletionDuringSeedReadDoesNotResurrect() async {
        let coordinator = AutomaticReasoningEffortCoordinator(timeout: .milliseconds(500))
        let target = makeModel(provider: openAIProvider, remoteID: "gpt-5.2")
        let seeded = decision(.maximum, provider: openAIProvider, model: target)
        let runID = UUID()
        let log = DecisionLog()
        let gate = SeedReadGate()

        let caller = Task {
            await coordinator.resolvedModel(
                runID: runID, provider: openAIProvider, model: target,
                boundedInput: "Request: hello", classifier: StubClassifier(.success(.low)),
                ingress: .continuation,
                seedReader: { _ in
                    await gate.waitForOpen()
                    return seeded
                },
                recorder: { _, decision in await log.append(decision) })
        }
        await gate.waitUntilEntered()
        // Deletion lands while the durable read is suspended.
        await coordinator.cancelAndForget(runID: runID)
        await gate.open()
        let resolved = await caller.value
        #expect(resolved.effectiveReasoningEffort == .automatic)
        #expect(await coordinator.decision(runID: runID) == nil)
        #expect(await log.decisions.isEmpty)
    }
}
