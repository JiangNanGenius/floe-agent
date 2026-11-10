import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeAgentRuntime
@testable import FloePersistence

/// Contracts for the pre-switch recoverable history cleanup (job-dd5880e37b8742f3):
/// small-window transition, sufficient-window no-op, failed/cancelled/stale
/// transitions with the original history untouched, full native identity CAS,
/// reservation honesty (measured/bounded/system), and manual-path protection
/// parity with tool-pair provenance.
@Suite("FloeAgentRuntime.ModelSwitchHistoryPreparer")
struct ModelSwitchHistoryPreparerTests {

    // MARK: - Fixtures

    private func incomingModel(window: Int, maxOutput: Int = 0, tools: Bool = true) -> ModelProfile {
        ModelProfile(
            id: UUID(),
            providerID: UUID(),
            remoteModelID: "switch-test-model",
            displayName: "Switch Test Model",
            limits: ModelLimits(contextTokens: window, maxOutputTokens: maxOutput),
            pricing: nil,
            capabilities: tools ? [.text, .tools] : [.text],
            isEnabled: true
        )
    }

    private func history(turns: Int, characters: Int) -> [ConversationMessage] {
        var messages: [ConversationMessage] = []
        for turn in 0..<turns {
            let filler = String(repeating: "x", count: characters)
            messages.append(ConversationMessage(
                id: UUID(), role: "user",
                content: "req-\(turn) \(filler)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(turn * 2))
            ))
            messages.append(ConversationMessage(
                id: UUID(), role: "assistant",
                content: "ans-\(turn) \(filler)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(turn * 2 + 1))
            ))
        }
        return messages
    }

    private actor SpyEngine: ContextEngine {
        enum Behavior {
            case noOpWithEmptyRecord
            case record(CompactionResult)
            case fail
        }
        private(set) var requests: [ContextRequest] = []
        private let behavior: Behavior
        init(behavior: Behavior) { self.behavior = behavior }
        func observeUsage(_ usage: UsageSnapshot) {}
        func prepareContext(for request: ContextRequest) async throws -> PreparedContext {
            let result = try await compact(CompactionRequest(context: request))
            return PreparedContext(messages: result.messages, estimatedInputTokens: result.estimatedTokens,
                compaction: result.record.sourceMessageIDs.isEmpty ? nil : result.record)
        }
        func compact(_ request: CompactionRequest) async throws -> CompactionResult {
            let context = request.context
            requests.append(context)
            switch behavior {
            case .noOpWithEmptyRecord:
                let estimate = ContextTokenEstimator().estimate(context.messages)
                return CompactionResult(messages: context.messages, record: ContextCompactionRecord(
                    sourceMessageIDs: [], sourceDigest: "",
                    beforeEstimatedTokens: estimate, afterEstimatedTokens: estimate),
                    estimatedTokens: estimate)
            case .record(let result):
                return result
            case .fail:
                throw FloeError.validationFailed("spy compaction failure")
            }
        }
    }

    private actor EffectBox {
        private(set) var commits: [(ContextCompactionRecord, String)] = []
        func commit(_ record: ContextCompactionRecord, _ summary: String) { commits.append((record, summary)) }
    }

    private func prepare(
        kind: ProviderKind = .openAI,
        window: Int,
        maxOutput: Int = 0,
        history messages: [ConversationMessage],
        reservation: ModelSwitchHistoryPlanner.Reservation,
        engine: any ContextEngine,
        fresh: @escaping @Sendable () async throws -> [ConversationMessage],
        ownership: @escaping @Sendable () async -> Bool = { true },
        commit: @escaping @Sendable (ContextCompactionRecord, String) async throws -> Void
    ) async throws -> ModelSwitchHistoryPreparer.Outcome {
        try await ModelSwitchHistoryPreparer().prepare(
            incomingProviderKind: kind,
            incomingModel: incomingModel(window: window, maxOutput: maxOutput),
            history: messages,
            reservation: reservation,
            engine: engine,
            loadFreshHistory: fresh,
            ownershipIsValid: ownership,
            commit: commit
        )
    }

    /// Runs the commit path against a stub compaction and returns the outcome
    /// with the commit count, so every stale/failure assertion proves the
    /// durable store was never touched.
    private func casRun(
        before: [ConversationMessage],
        fresh: [ConversationMessage]
    ) async throws -> (outcome: ModelSwitchHistoryPreparer.Outcome, commits: Int) {
        let engine = SpyEngine(behavior: .record(SelfStub.compactedResult(covering: before)))
        let box = EffectBox()
        let outcome = try await prepare(
            window: 4_096,
            history: before,
            reservation: ReservationFixture.none,
            engine: engine,
            fresh: { fresh },
            commit: { record, summary in await box.commit(record, summary) }
        )
        return (outcome, await box.commits.count)
    }

    // MARK: - Sufficient-window no-op (fast chats stay fast, zero engine calls)

    @Test("A fitting history returns fits without ever touching the engine")
    func sufficientWindowNoop() async throws {
        let small = history(turns: 3, characters: 40)
        let engine = SpyEngine(behavior: .noOpWithEmptyRecord)
        let box = EffectBox()
        let outcome = try await prepare(
            window: 128_000, maxOutput: 8_192,
            history: small,
            reservation: ReservationFixture.none,
            engine: engine,
            fresh: { small },
            commit: { record, summary in await box.commit(record, summary) }
        )
        switch outcome {
        case .fits: break
        default: Issue.record("expected .fits, got \(outcome)")
        }
        let requestCount = await engine.requests.count
        let commitCount = await box.commits.count
        #expect(requestCount == 0)
        #expect(commitCount == 0)
    }

    @Test("An empty conversation is a no-history no-op")
    func noHistorySkips() async throws {
        let engine = SpyEngine(behavior: .noOpWithEmptyRecord)
        let outcome = try await prepare(
            window: 4_096,
            history: [],
            reservation: ReservationFixture.none,
            engine: engine,
            fresh: { [] },
            commit: { _, _ in }
        )
        #expect(outcome == .noHistory)
        let requestCount = await engine.requests.count
        #expect(requestCount == 0)
    }

    // MARK: - Small-window transition with the real engine + real durable store

    @Test("128k -> 32k cloud transition compacting through the real engine commits into the real store")
    func smallWindowCloudTransition() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationStore = SQLiteConversationStore(database: database)
        let runStore = SQLiteRunStore(database: database)
        let intelligenceStore = SQLiteIntelligenceStore(database: database)
        let conversationID = UUID()
        try await conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "Switch", createdAt: Date(), updatedAt: Date()))
        let anchor = RunRecord(id: UUID(), conversationID: conversationID, state: "completed",
            goal: "g", startedAt: Date(), endedAt: Date())
        try await runStore.saveRun(anchor)
        var expectedCount = 0
        for message in history(turns: 45, characters: 1_000) {
            try await conversationStore.appendMessage(PersistedMessage(
                id: message.id, conversationID: conversationID, role: message.role,
                content: message.content, createdAt: message.createdAt))
            expectedCount += 1
        }
        func load() async throws -> [ConversationMessage] {
            try await ConversationHistoryAssembler(store: conversationStore,
                compactionStore: intelligenceStore).build(conversationID: conversationID)
        }
        let before = try await load()
        #expect(before.count == expectedCount)

        let box = EffectBox()
        let model = incomingModel(window: 32_768)
        let loadFresh: @Sendable () async throws -> [ConversationMessage] = {
            try await ConversationHistoryAssembler(store: conversationStore,
                compactionStore: intelligenceStore).build(conversationID: conversationID)
        }
        let outcome = try await ModelSwitchHistoryPreparer().prepare(
            incomingProviderKind: .openAI,
            incomingModel: model,
            history: before,
            reservation: ReservationFixture.none,
            engine: HybridContextEngine(),   // production deterministic tier
            loadFreshHistory: loadFresh,
            ownershipIsValid: { true },
            commit: { record, summary in
                try await intelligenceStore.saveCompaction(runID: anchor.id, record: record, summary: summary)
                await box.commit(record, summary)
            }
        )
        switch outcome {
        case .compacted(let tokensBefore, let afterTokens, let count):
            #expect(tokensBefore > afterTokens)
            #expect(count > 0)
        default:
            Issue.record("expected .compacted, got \(outcome)")
            return
        }
        // The committed snapshot projects into the NEXT assembled history
        // through the existing store, and the originals remain durable.
        let after = try await load()
        #expect(after.contains { ContextHistorySnapshot.isSummary($0) })
        let persisted = try await conversationStore.messages(conversationID: conversationID)
        #expect(persisted.count == expectedCount)
        let commitCount = await box.commits.count
        #expect(commitCount == 1)
        // The committed summary rides the existing automatic-projection
        // prefix — no second store identity.
        let summaries = after.filter { ContextHistorySnapshot.isSummary($0) }
        #expect(summaries.count == 1)
        // With the snapshot applied, the same incoming projection now fits:
        // the undersized-window dispatch pressure is actually removed.
        let projection = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .openAI, incomingModel: model, history: after,
            reservation: ReservationFixture.none)
        #expect(!projection.needsCompaction)
    }

    // MARK: - Protection parity + tool evidence provenance

    @Test("Protection matches the manual path exactly: latest user id only, no invented pair policy")
    func protectionParityWithManualPath() async throws {
        let large = history(turns: 40, characters: 900)
        let engine = SpyEngine(behavior: .noOpWithEmptyRecord)
        _ = try await prepare(
            window: 4_096,
            history: large,
            reservation: ReservationFixture.none,
            engine: engine,
            fresh: { large },
            commit: { _, _ in }
        )
        let requests = await engine.requests
        #expect(requests.count == 1)
        let request = requests[0]
        #expect(request.protection.messageIDs.count == 1)
        #expect(request.protection.messageIDs == Set([large.last(where: { $0.role == "user" })!.id]))
        // No production caller (manual or in-run) sets unresolved pair IDs,
        // plan draft or goal state here; the switch pass must not invent one.
        #expect(request.protection.unresolvedToolPairMessageIDs.isEmpty)
        #expect(request.protection.planDraft == nil)
        #expect(request.protection.goalState == nil)
        #expect(request.messages.map(\.id) == large.map(\.id))
        #expect(request.budget.availableInputTokens
            == ModelSwitchHistoryPlanner.projection(
                incomingProviderKind: .openAI,
                incomingModel: incomingModel(window: 4_096),
                history: large,
                reservation: ReservationFixture.none
            ).availableInputTokens)
    }

    @Test("Real-engine output keeps a contiguous retained tail and fully covers dropped sources")
    func toolEvidenceProvenanceAndContiguousTail() async throws {
        // user / assistant / tool rows interleaved: every durable original is
        // either kept (as one contiguous suffix of non-system messages) or
        // listed by the compaction record — the unchanged engine contract.
        var messages: [ConversationMessage] = []
        for turn in 0..<40 {
            let filler = String(repeating: "y", count: 900)
            messages.append(ConversationMessage(id: UUID(), role: "user",
                content: "task \(turn) \(filler)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(turn * 3))))
            messages.append(ConversationMessage(id: UUID(), role: "assistant",
                content: "call tool-call-\(turn) args-\(filler.prefix(200))",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(turn * 3 + 1))))
            messages.append(ConversationMessage(id: UUID(), role: "tool",
                content: "result call-\(turn) evidence \(filler)",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(turn * 3 + 2))))
        }
        let model = incomingModel(window: 32_768)
        let projection = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .openAI, incomingModel: model, history: messages,
            reservation: ReservationFixture.none)
        let result = try await HybridContextEngine().compact(CompactionRequest(context: ContextRequest(
            messages: messages,
            budget: projection.policy.budget,
            protection: ContextProtection(messageIDs: Set([messages.last!.id]))
        ), force: false))
        let record = result.record
        #expect(!record.sourceMessageIDs.isEmpty)
        let keptIDs = Set(result.messages
            .filter { !ContextHistorySnapshot.isSummary($0) && $0.role != "system" }
            .map(\.id))
        let nonSystem = messages.filter { $0.role != "system" }.map(\.id)
        let dropped = Set(nonSystem).subtracting(keptIDs)
        // Contiguous suffix: the kept block starts strictly after the last
        // dropped original, so no tool result survives without the original
        // context block that precedes the summary boundary.
        if !dropped.isEmpty, !keptIDs.isEmpty {
            let maxDroppedIndex = nonSystem.indices.last { dropped.contains(nonSystem[$0]) }!
            let minKeptIndex = nonSystem.indices.first { keptIDs.contains(nonSystem[$0]) }!
            #expect(maxDroppedIndex < minKeptIndex)
        }
        #expect(Set(record.sourceMessageIDs).isSubset(of: Set(messages.map(\.id))))
        #expect(dropped.isSubset(of: Set(record.sourceMessageIDs)))
    }

    // MARK: - Identity CAS (coordinator review point 2)

    @Test("Equal role+text but different message IDs must be stale")
    func casRejectsIdentityChange() async throws {
        let base = history(turns: 40, characters: 900)
        var fresh = base
        fresh[3] = ConversationMessage(id: UUID(), role: fresh[3].role, content: fresh[3].content,
            createdAt: fresh[3].createdAt)
        let run = try await casRun(before: base, fresh: fresh)
        #expect(run.outcome == .stale)
        #expect(run.commits == 0)
    }

    @Test("Same text and IDs but changed image evidence must be stale")
    func casRejectsImageChange() async throws {
        let base = history(turns: 40, characters: 900)
        var mutated = base
        mutated[2].images.append(ConversationImagePart(mimeType: "image/png", base64: "AAECAw=="))
        let run = try await casRun(before: base, fresh: mutated)
        #expect(run.outcome == .stale)
        #expect(run.commits == 0)
        // Sanity: the untouched snapshot itself commits (identity CAS passes).
        let passing = try await casRun(before: base, fresh: base)
        if case .compacted = passing.outcome { } else { Issue.record("unchanged snapshot must commit") }
        #expect(passing.commits == 1)
    }

    @Test("Changed reasoning payload must be stale")
    func casRejectsReasoningChange() async throws {
        let base = history(turns: 40, characters: 900)
        var fresh = base
        fresh[1].reasoningContent = "different continuation payload"
        let run = try await casRun(before: base, fresh: fresh)
        #expect(run.outcome == .stale)
        #expect(run.commits == 0)
    }

    @Test("Same-length tool-call envelope text with a different call id must be stale")
    func casRejectsToolPairEvidenceChange() async throws {
        let base = history(turns: 40, characters: 900)
        var fresh = base
        // content length preserved; identity of the call evidence changed.
        fresh[5] = ConversationMessage(id: fresh[5].id, role: fresh[5].role,
            content: "xx" + String(fresh[5].content.dropFirst(2)), createdAt: fresh[5].createdAt)
        let run = try await casRun(before: base, fresh: fresh)
        #expect(run.outcome == .stale)
        #expect(run.commits == 0)
    }

    @Test("Newer history appended before commit is stale, not silently re-based")
    func casRejectsGrownHistory() async throws {
        let base = history(turns: 40, characters: 900)
        let grown = base + history(turns: 1, characters: 900)
        let run = try await casRun(before: base, fresh: grown)
        #expect(run.outcome == .stale)
        #expect(run.commits == 0)
    }

    @Test("Ownership lost before commit yields stale with nothing persisted")
    func ownershipInvalidYieldsStale() async throws {
        let before = history(turns: 40, characters: 900)
        let engine = SpyEngine(behavior: .record(SelfStub.compactedResult(covering: before)))
        let box = EffectBox()
        let outcome = try await prepare(
            window: 4_096,
            history: before,
            reservation: ReservationFixture.none,
            engine: engine,
            fresh: { before },
            ownership: { false },
            commit: { record, summary in await box.commit(record, summary) }
        )
        #expect(outcome == .stale)
        let commitCount = await box.commits.count
        #expect(commitCount == 0)
    }

    // MARK: - Failure + cancellation keep originals

    @Test("Engine failure propagates with zero commits")
    func engineFailurePropagates() async throws {
        let before = history(turns: 40, characters: 900)
        let engine = SpyEngine(behavior: .fail)
        let box = EffectBox()
        await #expect(throws: (any Error).self) {
            try await prepare(
                window: 4_096,
                history: before,
                reservation: ReservationFixture.none,
                engine: engine,
                fresh: { before },
                commit: { record, summary in await box.commit(record, summary) }
            )
        }
        let commitCount = await box.commits.count
        #expect(commitCount == 0)
    }

    @Test("Cancellation during the provider summarization leaves nothing committed")
    func cancellationPropagates() async throws {
        let before = history(turns: 40, characters: 900)
        let engine = SpyEngine(behavior: .record(SelfStub.compactedResult(covering: before)))
        let box = EffectBox()
        let task = Task { () -> ModelSwitchHistoryPreparer.Outcome in
            try await ModelSwitchHistoryPreparer().prepare(
                incomingProviderKind: .openAI,
                incomingModel: ModelProfile(id: UUID(), providerID: UUID(),
                    remoteModelID: "m", displayName: "m",
                    limits: ModelLimits(contextTokens: 4_096, maxOutputTokens: 0),
                    pricing: nil, capabilities: [.text, .tools], isEnabled: true),
                history: before,
                reservation: ReservationFixture.none,
                engine: engine,
                loadFreshHistory: {
                    await Task.yield()
                    try Task.checkCancellation()
                    return before
                },
                ownershipIsValid: { true },
                commit: { record, summary in await box.commit(record, summary) }
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let commitCount = await box.commits.count
        #expect(commitCount == 0)
    }

    // MARK: - Reservation honesty (coordinator review point 1)

    @Test("Measured receipts win, hidden tools charge zero, bounded applies otherwise")
    func reservationChannelsAreHonest() throws {
        let model = incomingModel(window: 32_768, maxOutput: 4_096)
        let sample = history(turns: 10, characters: 100)
        // tools hidden: even a measured receipt must not be charged (the next
        // turn offers no schemas).
        let hidden = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .openAI, incomingModel: model, history: sample,
            reservation: ModelSwitchHistoryPlanner.Reservation(toolsEnabledForNextRun: false, measuredToolSchemaTokens: 6_000))
        #expect(hidden.reservedSchemaTokens == 0)
        #expect(hidden.availableInputTokens == 32_768 - 4_096)
        // measured receipt charged verbatim when tools visible.
        let measured = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .openAI, incomingModel: model, history: sample,
            reservation: ModelSwitchHistoryPlanner.Reservation(measuredToolSchemaTokens: 6_000))
        #expect(measured.reservedSchemaTokens == 6_000)
        // explicit bound charged when no measurement exists.
        let bounded = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .openAI, incomingModel: model, history: sample,
            reservation: ModelSwitchHistoryPlanner.Reservation(boundedSchemaReserveTokens: 2_500))
        #expect(bounded.reservedSchemaTokens == 2_500)
        // system bound folds into the same fixed dimension (never a second store).
        let withSystem = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .openAI, incomingModel: model, history: sample,
            reservation: ModelSwitchHistoryPlanner.Reservation(boundedSchemaReserveTokens: 2_500, systemContextTokenEstimate: 1_024))
        #expect(withSystem.reservedSystemContextTokens == 1_024)
        #expect(withSystem.availableInputTokens == bounded.availableInputTokens - 1_024)
        // a non-tool model never charges schemas.
        let plain = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .openAI,
            incomingModel: incomingModel(window: 32_768, maxOutput: 4_096, tools: false),
            history: sample,
            reservation: ModelSwitchHistoryPlanner.Reservation(boundedSchemaReserveTokens: 2_500))
        #expect(plain.reservedSchemaTokens == 0)
    }

    @Test("Bounded initial schema reservation is the catalog cost clamped by the offer budget")
    func boundedInitialSchemaReservationMath() throws {
        let descriptors = (0..<4).map { index in
            ToolCatalog.Descriptor(
                name: "switch.qual.tool\(index)",
                toolDescription: String(repeating: "d", count: 3_000),
                riskLabels: [.readsFiles],
                isSideEffecting: false
            )
        }
        let catalogCost = descriptors.reduce(0) { $0 + ToolSchemaOfferPlanner.tokenCost($1) }
        // Plenty of window: the bounded value is the true catalog size (all
        // initial schemas), not the whole remaining budget.
        let largeWindow = ModelSwitchHistoryPlanner.boundedInitialSchemaReservation(
            contextWindowTokens: 128_000, reservedOutputTokens: 8_192,
            messageTokens: 1_000, imageTokens: 0, toolSchemasVisible: true,
            catalogDescriptors: descriptors)
        #expect(largeWindow == catalogCost)
        // Tight window: the planner's offer budget is the hard clamp — the
        // first dispatch defers/trims schemas there, so the switch pass never
        // charges more than schemas could actually occupy.
        let tight = ModelSwitchHistoryPlanner.boundedInitialSchemaReservation(
            contextWindowTokens: 8_192, reservedOutputTokens: 2_048,
            messageTokens: 3_000, imageTokens: 0, toolSchemasVisible: true,
            catalogDescriptors: descriptors)
        let window = 8_192
        let resultReserve = min(window / 3, max(1_024, window / 4))
        let budget = ToolSchemaOfferPlanner.availableTokenBudget(
            contextWindowTokens: window, reservedOutputTokens: 2_048,
            messageTokens: 3_000, imageTokens: 0, replayTokens: 0,
            toolResultReserveTokens: resultReserve)
        #expect(tight == min(catalogCost, budget))
        #expect(tight <= budget)
        // hidden tools -> zero.
        #expect(ModelSwitchHistoryPlanner.boundedInitialSchemaReservation(
            contextWindowTokens: 128_000, reservedOutputTokens: 8_192,
            messageTokens: 0, imageTokens: 0, toolSchemasVisible: false,
            catalogDescriptors: descriptors) == 0)
    }

    @Test("Local incoming mirrors the runtime floor and never double-counts with zero system bound")
    func localMirrorChargesCuratedFloor() throws {
        let model = incomingModel(window: 4_096)
        let sample = history(turns: 2, characters: 40)
        // Center's real local input shape: bounded supplied, system 0.
        let local = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .local, incomingModel: model, history: sample,
            reservation: ModelSwitchHistoryPlanner.Reservation(toolsEnabledForNextRun: true,
                                     measuredToolSchemaTokens: 0,
                                     boundedSchemaReserveTokens: 2_100,
                                     systemContextTokenEstimate: 0))
        #expect(local.reservedSchemaTokens == 2_100)
        #expect(local.policy.mode == .local)
        #expect(local.policy.tier == .micro) // 4_096 -> micro tier band
        let local8k = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .local, incomingModel: incomingModel(window: 8_192),
            history: sample,
            reservation: ModelSwitchHistoryPlanner.Reservation(boundedSchemaReserveTokens: 2_100,
                systemContextTokenEstimate: 0))
        #expect(local8k.policy.tier == .compact) // <=8_192 -> compact tier band
        let belowFloor = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .local, incomingModel: model, history: sample,
            reservation: ModelSwitchHistoryPlanner.Reservation(boundedSchemaReserveTokens: 500))
        #expect(belowFloor.reservedSchemaTokens == 2_000) // runtime curated floor
        let chatOnly = ModelSwitchHistoryPlanner.projection(
            incomingProviderKind: .local, incomingModel: model, history: sample,
            reservation: .chatOnly)
        #expect(chatOnly.reservedSchemaTokens == 0)
    }

    @Test("Engine honest no-op after a triggered projection returns fits, never a manufactured commit")
    func triggeredButManageableStaysFits() async throws {
        let before = history(turns: 40, characters: 900)
        let engine = SpyEngine(behavior: .noOpWithEmptyRecord)
        let outcome = try await prepare(
            window: 4_096,
            history: before,
            reservation: ModelSwitchHistoryPlanner.Reservation(boundedSchemaReserveTokens: 500, systemContextTokenEstimate: 1_024),
            engine: engine,
            fresh: { before },
            commit: { _, _ in Issue.record("must not commit an empty record") }
        )
        if case .fits = outcome { } else { Issue.record("expected .fits, got \(outcome)") }
    }

    @Test("A compaction result without a persistable summary never strands provenance")
    func summarylessRecordIsStaleNotCommitted() async throws {
        let base = history(turns: 40, characters: 900)
        var broken = SelfStub.compactedResult(covering: base)
        broken.messages = broken.messages.map { message in
            var copy = message
            if ContextHistorySnapshot.isSummary(copy) { copy.content = "" }
            return copy
        }.filter { !$0.content.isEmpty || $0.role != "system" }
        let engine = SpyEngine(behavior: .record(broken))
        let box = EffectBox()
        let outcome = try await prepare(
            window: 4_096,
            history: base,
            reservation: ReservationFixture.none,
            engine: engine,
            fresh: { base },
            commit: { record, summary in await box.commit(record, summary) }
        )
        #expect(outcome == .stale)
        let commitCount = await box.commits.count
        #expect(commitCount == 0)
    }
}

private enum ReservationFixture {
    /// No caller-side bounds: the planner derives catalog/budget from the live
    /// registry (empty in a bare SwiftPM host, exactly like a fresh tool
    /// registration state) and charges no system bound.
    static let none = ModelSwitchHistoryPlanner.Reservation(
        toolsEnabledForNextRun: true,
        measuredToolSchemaTokens: 0,
        boundedSchemaReserveTokens: 0,
        systemContextTokenEstimate: 0
    )
}

/// Builds a minimal VALID CompactionResult for spy engines (real record +
/// real summary message shape, without running provider I/O).
enum SelfStub {
    static func compactedResult(covering source: [ConversationMessage]) -> CompactionResult {
        let candidates = Array(source.dropLast(2))
        let estimator = ContextTokenEstimator()
        let before = max(1, estimator.estimate(source))
        let compactionID = UUID()
        let summary = ConversationMessage(
            id: compactionID, role: "system",
            content: ContextHistorySnapshot.noticePrefix
                + "\nHistorical summary:\n## Goal\n- continue\n## Instructions\n- none\n"
                + "## Progress\n- done\n## Remaining work\n- none\n## Exact references\n- none",
            contextSourceMessageIDs: candidates.map(\.id))
        let output = [summary] + Array(source.dropFirst(candidates.count))
        let after = max(1, estimator.estimate(output))
        return CompactionResult(messages: output, record: ContextCompactionRecord(
            id: compactionID, sourceMessageIDs: candidates.map(\.id),
            sourceDigest: "stub", beforeEstimatedTokens: before, afterEstimatedTokens: after),
            estimatedTokens: after)
    }
}
