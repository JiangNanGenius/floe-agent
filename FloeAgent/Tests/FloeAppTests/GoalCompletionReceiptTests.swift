#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeProviders
@testable import FloeApp

private struct NativeGoalReviewInput: Decodable, Sendable {
    var objective: String
    var criteria: [GoalCriterion]
    var steps: [GoalStep]
    var evidence: [GoalEvidence]
}
private final class NativeGoalReviewSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NativeGoalReviewInput] = []
    func append(_ value: NativeGoalReviewInput) { lock.withLock { values.append(value) } }
    var reviews: [NativeGoalReviewInput] { lock.withLock { values } }
}
private struct NativeGoalReceiptProvider: ProviderAdapter {
    let spy: NativeGoalReviewSpy
    var protocolKind: ModelProtocol { .openAIChatCompletions }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        guard request.messages.contains(where: { $0.role == "system" && $0.content == GoalEvidenceReviewContract.instructions }),
              let text = request.messages.last(where: { $0.role == "user" })?.content,
              let input = try? JSONDecoder().decode(NativeGoalReviewInput.self, from: Data(text.utf8)) else {
            // No provider/network/tools are executed by the fixture. A real
            // continuation can stay owned here until normal cancellation.
            return AsyncThrowingStream { _ in }
        }
        spy.append(input)
        return AsyncThrowingStream { continuation in
            do {
                let ids = input.evidence.map { $0.id.uuidString }
                let reply: [String: Any] = [
                    "valid": true, "progressEvidenceIDs": ids,
                    "criteria": input.criteria.map { ["id": $0.id.uuidString, "evidenceIDs": ids] },
                    "steps": input.steps.map { ["id": $0.id.uuidString, "evidenceIDs": ids] },
                    "blockingCondition": NSNull(), "blockingEvidenceIDs": []
                ]
                let data = try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
                continuation.yield(.textDelta(.init(text: String(decoding: data, as: UTF8.self))))
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
}

@MainActor @Suite("Completed Goal native receipts", .serialized, .timeLimit(.minutes(1)))
struct GoalCompletionReceiptTests {
    private struct Fixture {
        let environment: AppEnvironment
        let center: ConversationCenter
        let provider: ProviderProfile
        let model: ModelProfile
        let conversationID: UUID
        let workspaceID: UUID
        let spy: NativeGoalReviewSpy
    }
    private actor Gate {
        private var entered = false, released = false
        private var continuation: CheckedContinuation<Void, Never>?
        func hold() async {
            entered = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        func waitUntilEntered() async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !entered && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(entered, "The new definition never reached actual launch preparation")
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
    private func fixture() async throws -> Fixture {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.markIsolatedLaunchReadyForTesting()
        let center = environment.conversationCenter
        center.localModelDiscoveryOverrideForTesting = {}
        let spy = NativeGoalReviewSpy()
        let adapter = NativeGoalReceiptProvider(spy: spy)
        center.providerAdapterTestOverride = { _, _ in adapter }
        let provider = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://owned-goal-receipt.invalid/v1")!)
        let model = ModelProfile(providerID: provider.id, remoteModelID: "owned-goal-receipt", displayName: "Owned receipt fixture",
            limits: .init(contextTokens: 16_384, maxOutputTokens: 2_048), capabilities: [.text, .tools])
        try await environment.configurationStore.saveProvider(provider)
        try await environment.configurationStore.saveModel(model)
        var preferences = try await environment.configurationStore.preferences()
        preferences.defaultAgentModelID = model.id
        try await environment.configurationStore.savePreferences(preferences)
        await center.reload()
        let conversation = try await center.createConversation(title: "Owned completed Goal receipts")
        let workspace = try #require(try await SQLiteWorkspaceStore(database: environment.database).workspaceID(conversationID: conversation.id))
        return .init(environment: environment, center: center, provider: provider, model: model,
            conversationID: conversation.id, workspaceID: workspace, spy: spy)
    }
    private func seed(_ f: Fixture) async throws -> ConversationGoal {
        let goal = ConversationGoal(conversationID: f.conversationID, objective: "Verify the owned native result",
            acceptanceCriteria: [.init(text: "The owned result is verified", requiresUserConfirmation: false)],
            steps: [.init(title: "Verify the result", order: 0)], status: .active,
            budgets: .init(maxCycles: 10, maxModelCalls: 20),
            progress: .init(cycleCount: 1, modelCallCount: 1, startedAt: Date()))
        try await f.environment.intelligenceStore.saveGoal(goal)
        return try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
    }
    private func prepare(_ f: Fixture, goal: ConversationGoal) async throws -> UUID {
        let fingerprint = try GoalRunDefinitionFingerprint.make(goal)
        let prepared = try await SQLiteRunLaunchStore(database: f.environment.database).prepare(.init(
            conversationID: f.conversationID, goal: goal.objective, workspaceID: f.workspaceID,
            conversationMode: "goal", goalID: goal.id, expectedGoalRevision: goal.revision ?? 1,
            goalDefinitionFingerprint: fingerprint,
            providerID: f.provider.id, modelID: f.model.id))
        return prepared.run.id
    }
    private func payload(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private enum DispatchValue { case native(Bool), legacy(String), absent }
    private func receipt(_ f: Fixture, runID: UUID, call: String, tool: String = "file.read",
                         input: String = "{\"path\":\"owned.txt\"}", digest: String = "owned-digest",
                         status: String = "ok", dispatched: DispatchValue = .native(true)) async throws -> GoalEvidence {
        _ = try await f.environment.runStore.appendEvent(runID: runID, kind: .toolRequest,
            payloadJSON: payload(["id": call, "tool": tool, "input": input, "attempt": 1]))
        let summary = "Owned fixture verified result"
        var result: [String: Any] = ["id": call, "tool": tool, "status": status, "summary": summary,
            "outputDigest": digest, "durationMs": 12.5]
        switch dispatched {
        case .native(let value): result["dispatched"] = value
        case .legacy(let value): result["dispatched"] = value
        case .absent: break
        }
        let event = try await f.environment.runStore.appendEvent(runID: runID, kind: .toolResult, payloadJSON: payload(result))
        return GoalEvidence(kind: .toolResult, reference: "run:\(runID.uuidString):event:\(event.sequence)",
            summary: summary, capturedAt: event.createdAt,
            fingerprint: FloeDigest.sha256Hex(Data((tool + "|" + input + "|" + (digest.isEmpty ? summary : digest)).utf8)))
    }
    private func finish(_ f: Fixture, runID: UUID) async throws {
        try await f.environment.runStore.updateRunState(id: runID, state: "completed", endedAt: Date())
        _ = try await f.environment.runStore.appendEvent(runID: runID, kind: .terminal,
            payloadJSON: payload(["state": "completed"]))
    }

    @Test("Already-durable mixed-typed receipts are reviewed with their original IDs; old output and undispatched/preparation results are excluded")
    func persistedMixedReceiptsStillReachReview() async throws {
        let f = try await fixture()
        var goal = try await seed(f)
        let priorRun = try await prepare(f, goal: goal)
        let historical = try await receipt(f, runID: priorRun, call: "old", digest: "repeated")
        try await finish(f, runID: priorRun)
        let run = try await prepare(f, goal: goal)
        let repeated = try await receipt(f, runID: run, call: "repeated", digest: "repeated")
        let native = try await receipt(f, runID: run, call: "native", digest: "new-native")
        let legacy = try await receipt(f, runID: run, call: "legacy", input: "legacy-input", digest: "",
            status: "success", dispatched: .legacy("true"))
        _ = try await receipt(f, runID: run, call: "not-dispatched", dispatched: .native(false))
        _ = try await receipt(f, runID: run, call: "unknown-status", status: "unknown-success")
        _ = try await receipt(f, runID: run, call: "missing-dispatch", dispatched: .absent)
        _ = try await receipt(f, runID: run, call: "preparation", tool: "tools.search")
        try await finish(f, runID: run)
        // Model Core's already-committed native receipt history in the actual
        // SQLite Goal. The evaluator must review, not append duplicate IDs.
        goal.evidence = [historical, repeated, native, legacy]
        try #require(try await f.environment.intelligenceStore.saveGoalIfRevisionMatches(goal, expectedRevision: goal.revision ?? 1))
        await f.center.evaluateAndContinueGoal(completedRunID: run, conversationID: f.conversationID,
            provider: f.provider, model: f.model, workspaceID: f.workspaceID)
        let review = try #require(f.spy.reviews.first)
        #expect(f.spy.reviews.count == 1)
        #expect(Set(review.evidence.map(\.id)) == Set([native.id, legacy.id]))
        let coreLegacyFingerprint = FloeDigest.sha256Hex(Data("file.read|legacy-input|Owned fixture verified result".utf8))
        #expect(legacy.fingerprint == coreLegacyFingerprint)
        #expect(review.evidence.first { $0.id == legacy.id }?.fingerprint == coreLegacyFingerprint,
            "The actual App review must use Core's summary fallback for an empty native digest")
        let saved = try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
        #expect(saved.status == .completed)
        #expect(saved.acceptanceCriteria.first?.isSatisfied == true)
        #expect(Set(saved.acceptanceCriteria[0].evidenceIDs) == Set([native.id, legacy.id]))
        #expect(Set(saved.evidence.map(\.id)) == Set(goal.evidence.map(\.id)))
        #expect(saved.evidence.count == 4)
        #expect(try await f.environment.runStore.events(runID: run).last?.kind == .terminal)
        try await f.center.deleteConversation(id: f.conversationID)
    }

    @Test("An admitted old definition completes after edit/rearm: it launches the new definition without reviewing old evidence or blocking new criteria")
    func editedDefinitionContinuesWithoutOldCriteriaReview() async throws {
        let f = try await fixture()
        var goal = try await seed(f)
        let run = try await prepare(f, goal: goal)
        let oldEvidence = try await receipt(f, runID: run, call: "old-definition", digest: "old-definition-output")
        try await finish(f, runID: run)
        goal.objective = "Implement the newly edited definition"
        goal.acceptanceCriteria = [.init(text: "Verify only the new requirement", requiresUserConfirmation: false)]
        goal.evidence = [oldEvidence]
        goal.progress.repeatedBlockerKey = "no-inspectable-evidence"
        goal.progress.repeatedBlockerCount = 2
        goal.status = .active // Explicit rearm while the admitted old round continues.
        try #require(try await f.environment.intelligenceStore.saveGoalIfRevisionMatches(goal, expectedRevision: goal.revision ?? 1))
        let edited = try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
        let gate = Gate()
        f.center.launchTestHooks.afterRunPrepared = { _ in await gate.hold() }
        let evaluation = Task {
            await f.center.evaluateAndContinueGoal(completedRunID: run, conversationID: f.conversationID,
                provider: f.provider, model: f.model, workspaceID: f.workspaceID)
        }
        defer {
            f.center.launchTestHooks.afterRunPrepared = nil
            evaluation.cancel()
            Task { await gate.release() }
        }
        try await gate.waitUntilEntered()
        let runs = try await f.environment.runStore.runs(conversationID: f.conversationID)
        let next = try #require(runs.first { $0.id != run })
        #expect(runs.count == 2 && next.goalID == goal.id && next.state == "preparing")
        #expect(next.goal.contains(edited.objective))
        let held = try #require(try await f.environment.intelligenceStore.goal(id: goal.id))
        #expect(held.status == .active && held.acceptanceCriteria.allSatisfy { !$0.isSatisfied && $0.evidenceIDs.isEmpty })
        #expect(held.progress.repeatedBlockerCount == 2 && held.progress.repeatedBlockerKey == "no-inspectable-evidence")
        #expect(f.spy.reviews.isEmpty, "Old-definition evidence must never satisfy the new criteria")
        let events = try await f.environment.runStore.events(runID: next.id)
        let admitted = try #require(events.first { $0.kind == .status })
        let fields = try JSONDecoder().decode([String:String].self, from: Data(admitted.payloadJSON.utf8))
        let expectedFingerprint = try GoalRunDefinitionFingerprint.make(edited)
        #expect(fields["goalDefinitionFingerprint"] == expectedFingerprint)
        await gate.release()
        await evaluation.value
        f.center.launchTestHooks.afterRunPrepared = nil
        await f.center.cancel(runID: next.id)
        try await f.center.deleteConversation(id: f.conversationID)
    }
}
#endif
