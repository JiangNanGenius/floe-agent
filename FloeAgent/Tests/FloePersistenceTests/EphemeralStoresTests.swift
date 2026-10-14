// FloePersistenceTests — Ephemeral (temporary-chat) stores and the
// promotion gateway: RAM-only behavior, ordering, exactly-once forwarding,
// abort recovery and fail-closed hosting.

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.EphemeralStores")
struct EphemeralStoresTests {

    private func makeSessionRecord(id: UUID = UUID()) -> ConversationRecord {
        ConversationRecord(
            id: id,
            title: "",
            createdAt: Date(),
            updatedAt: Date(),
            purpose: .temporary
        )
    }

    private func makeDurablePair() async throws -> (DatabaseManager, SQLiteConversationStore, SQLiteRunStore) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        return (database, SQLiteConversationStore(database: database), SQLiteRunStore(database: database))
    }

    @Test("Conversation CRUD stays in RAM and pages like the SQLite store")
    func conversationCRUDAndPaging() async throws {
        let id = UUID()
        let store = EphemeralConversationStore(record: makeSessionRecord(id: id))
        for index in 0..<45 {
            try await store.appendMessage(PersistedMessage(
                id: UUID(),
                conversationID: id,
                role: index % 2 == 0 ? "user" : "assistant",
                content: "m\(index)",
                createdAt: Date().addingTimeInterval(TimeInterval(index))
            ))
        }
        let all = try await store.messages(conversationID: id)
        #expect(all.count == 45)
        #expect(all.first?.content == "m0")
        #expect(all.last?.content == "m44")
        let page = try await store.messagePage(conversationID: id, before: nil, limit: 20)
        #expect(page.messages.count == 20)
        #expect(page.hasEarlier)
        #expect(page.messages.last?.content == "m44")
        // Fail closed for foreign ids.
        await #expect(throws: FloeError.self) {
            _ = try await store.messages(conversationID: UUID())
        }
    }

    @Test("Run store keeps per-run event sequences and terminal state in RAM")
    func runEventsAndSequences() async throws {
        let conversationID = UUID()
        let store = EphemeralRunStore(hostedConversationID: conversationID)
        let run = RunRecord(
            id: UUID(),
            conversationID: conversationID,
            state: "preparing",
            goal: "goal",
            startedAt: Date()
        )
        try await store.saveRun(run)
        for index in 0..<10 {
            let record = try await store.appendEvent(
                runID: run.id,
                kind: .assistantText,
                payloadJSON: #"{"delta":"d\#(index)"}"#
            )
            #expect(record.sequence == index + 1)
        }
        let events = try await store.events(runID: run.id)
        #expect(events.count == 10)
        #expect(events.last?.sequence == 10)
        try await store.updateRunState(id: run.id, state: "completed", endedAt: Date())
        #expect(try await store.nonTerminalRuns().isEmpty)
        #expect(try await store.run(id: run.id)?.state == "completed")
        await #expect(throws: FloeError.self) {
            _ = try await store.appendEvent(runID: UUID(), kind: .status, payloadJSON: "{}")
        }
    }

    @Test("Promotion forwards buffered rows exactly once and in append order")
    func promotionForwardsInOrder() async throws {
        let conversationID = UUID()
        let ephemeral = EphemeralConversationStore(record: makeSessionRecord(id: conversationID))
        let ephemeralRuns = EphemeralRunStore(hostedConversationID: conversationID)
        let (_, durable, durableRuns) = try await makeDurablePair()

        // Simulate a launch + stream.
        let run = RunRecord(
            id: UUID(), conversationID: conversationID,
            state: "preparing", goal: "canary-goal", startedAt: Date()
        )
        try await ephemeralRuns.saveRun(run)
        try await ephemeral.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "canary-user", createdAt: Date(), runID: run.id
        ))

        // Begin promotion, then append DURING promotion (stream continues).
        try await ephemeral.beginPromotion()
        try await ephemeralRuns.beginPromotion()
        let during = PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant",
            content: "canary-assistant", createdAt: Date().addingTimeInterval(1), runID: run.id
        )
        try await ephemeral.appendMessage(during)
        _ = try await ephemeralRuns.appendEvent(runID: run.id, kind: .assistantText, payloadJSON: #"{"delta":"late"}"#)

        // Promote the frozen snapshot into durable storage in schema FK
        // order: runs before messages (messages.run_id references runs).
        var saved = await ephemeral.bufferedSnapshot().conversation
        saved.purpose = .ordinary
        try await durable.saveConversation(saved)
        for runHeader in try await ephemeralRuns.bufferedSnapshot().runs {
            try await durableRuns.saveRun(runHeader)
        }
        for message in try await ephemeral.bufferedSnapshot().messages {
            try await durable.appendMessage(message)
        }

        // Complete: buffered-during-promotion rows forward inside the actor.
        try await ephemeral.completePromotion(durable: durable)
        try await ephemeralRuns.completePromotion(durable: durableRuns)

        // Post-promotion appends go straight to the durable store.
        let after = PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "canary-follow-up", createdAt: Date().addingTimeInterval(2), runID: run.id
        )
        try await ephemeral.appendMessage(after)
        _ = try await ephemeralRuns.appendEvent(runID: run.id, kind: .status, payloadJSON: #"{"state":"completed"}"#)

        let savedMessages = try await durable.messages(conversationID: conversationID)
        #expect(savedMessages.map(\.content) == ["canary-user", "canary-assistant", "canary-follow-up"])
        let savedEvents = try await durableRuns.events(runID: run.id)
        #expect(savedEvents.map(\.sequence) == Array(1...savedEvents.count))
        #expect(savedEvents.first?.payloadJSON.contains("late") == true)
        #expect(savedEvents.last?.payloadJSON.contains("completed") == true)
        #expect(try await durable.conversation(id: conversationID)?.purpose == .ordinary)
    }

    @Test("Promotion watermark: the transactional snapshot and the forwarded tail never overlap, so run events cannot duplicate")
    func promotionWatermarkPreventsEventDuplication() async throws {
        let conversationID = UUID()
        let ephemeralRuns = EphemeralRunStore(hostedConversationID: conversationID)
        let (_, durableConversation, durableRuns) = try await makeDurablePair()
        let run = RunRecord(
            id: UUID(), conversationID: conversationID,
            state: "preparing", goal: "wm-goal", startedAt: Date()
        )
        try await ephemeralRuns.saveRun(run)
        for index in 0..<3 {
            _ = try await ephemeralRuns.appendEvent(
                runID: run.id, kind: .assistantText,
                payloadJSON: #"{"delta":"base-\#(index)"}"#
            )
        }
        // beginPromotion freezes the watermark snapshot (what the promoter
        // commits inside its GRDB transaction).
        let frozen = try await ephemeralRuns.beginPromotion()
        #expect(frozen.events[run.id]?.count == 3)
        // A stream append during promotion is tail-only.
        _ = try await ephemeralRuns.appendEvent(
            runID: run.id, kind: .assistantText,
            payloadJSON: #"{"delta":"tail"}"#
        )
        // The promoter commits the FROZEN snapshot (original event ids),
        // conversation before runs per the durable schema's FK order.
        var durableRecord = ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date(), purpose: .temporary
        )
        durableRecord.purpose = .ordinary
        try await durableConversation.saveConversation(durableRecord)
        try await durableRuns.saveRun(run)
        for event in frozen.events[run.id, default: []] {
            let committed = try await durableRuns.appendEvent(
                runID: run.id, kind: event.kind, payloadJSON: event.payloadJSON
            )
            #expect(committed.sequence == event.sequence)
        }
        // The gateway forwards only the tail.
        try await ephemeralRuns.completePromotion(durable: durableRuns)
        let events = try await durableRuns.events(runID: run.id)
        #expect(events.count == 4)
        #expect(Set(events.map(\.id)).count == 4)
        #expect(events.map(\.sequence) == [1, 2, 3, 4])
        #expect(events.last?.payloadJSON.contains("tail") == true)
    }

    @Test("Aborted promotion leaves RAM intact and writes nothing durable")
    func abortedPromotionIsRecoverable() async throws {
        let conversationID = UUID()
        let ephemeral = EphemeralConversationStore(record: makeSessionRecord(id: conversationID))
        let ephemeralRuns = EphemeralRunStore(hostedConversationID: conversationID)
        let (_, durable, durableRuns) = try await makeDurablePair()
        try await ephemeral.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "canary-abort", createdAt: Date()
        ))
        try await ephemeral.beginPromotion()
        try await ephemeralRuns.beginPromotion()
        // Mid-promotion failure: no durable rows may exist.
        await ephemeral.abortPromotion()
        await ephemeralRuns.abortPromotion()
        #expect(try await durable.conversation(id: conversationID) == nil)
        // RAM is fully recoverable and a retry can start cleanly.
        try await ephemeral.beginPromotion()
        var saved = await ephemeral.bufferedSnapshot().conversation
        saved.purpose = .ordinary
        try await durable.saveConversation(saved)
        for message in try await ephemeral.bufferedSnapshot().messages {
            try await durable.appendMessage(message)
        }
        try await ephemeral.completePromotion(durable: durable)
        let messages = try await durable.messages(conversationID: conversationID)
        #expect(messages.count == 1)
        #expect(messages.first?.content == "canary-abort")
    }

    @Test("Closed store fails closed for reads and writes")
    func closedStoreFailsClosed() async throws {
        let id = UUID()
        let store = EphemeralConversationStore(record: makeSessionRecord(id: id))
        await store.close()
        await #expect(throws: FloeError.self) {
            try await store.appendMessage(PersistedMessage(
                id: UUID(), conversationID: id, role: "user", content: "x", createdAt: Date()
            ))
        }
    }

    @Test("Ephemeral launch store produces the same prepared shape as SQLite without durable writes")
    func launchStoreParityWithoutDurability() async throws {
        let conversationID = UUID()
        let ephemeral = EphemeralConversationStore(record: makeSessionRecord(id: conversationID))
        let ephemeralRuns = EphemeralRunStore(hostedConversationID: conversationID)
        let launch = EphemeralRunLaunchStore(
            hostedConversationID: conversationID,
            conversationStore: ephemeral,
            runStore: ephemeralRuns
        )
        let runID = UUID()
        let prepared = try await launch.prepare(RunLaunchRequest(
            conversationID: conversationID,
            conversationTitle: "",
            runID: runID,
            goal: "canary-goal",
            providerID: UUID(),
            modelID: UUID()
        ))
        #expect(prepared.conversation.id == conversationID)
        #expect(prepared.conversation.purpose == .temporary)
        #expect(!prepared.createdConversation)
        #expect(prepared.userMessage.content == "canary-goal")
        // Applied into the session stores: runtime appends can proceed.
        #expect(try await ephemeralRuns.run(id: runID) != nil)
        #expect(try await ephemeral.messages(conversationID: conversationID).count == 1)
        // Nothing durable.
        let (_, durable, durableRuns) = try await makeDurablePair()
        #expect(try await durable.conversation(id: conversationID) == nil)
        #expect(try await durableRuns.run(id: runID) == nil)
    }

    @Test("Running input queue mirrors claim, steer and consume transitions in RAM")
    func runningInputTransitions() async throws {
        let conversationID = UUID()
        let store = EphemeralRunningInputStore(hostedConversationID: conversationID)
        let steerRunID = UUID()
        let first = try await store.enqueue(PendingUserInput(
            conversationID: conversationID, content: "first"
        ))
        let second = try await store.enqueue(PendingUserInput(
            conversationID: conversationID, targetRunID: steerRunID, content: "second"
        ))
        #expect(first.position == 1)
        #expect(second.position == 2)
        let claimed = try await store.claimNextQueued(conversationID: conversationID)
        #expect(claimed?.id == first.id)
        #expect(claimed?.status == .promoting)
        try await store.restoreQueued(id: first.id)
        // Steer promotion requires the input to target the expected run —
        // the durable store enforces the same target_run_id comparison.
        let steer = try await store.beginSteerPromotion(id: second.id, expectedRunID: steerRunID)
        #expect(steer?.status == .promoting)
        try await store.markSteerAccepted(id: second.id, runID: steerRunID)
        // Parity with the durable queue: steerPending stays a pending row
        // (the SQLite projection includes 'steerPending') until consumed;
        // the restored queued input is pending too.
        #expect(try await store.pending(conversationID: conversationID).map(\.id) == [first.id, second.id])
        try await store.markConsumed(id: second.id, runID: steerRunID)
        #expect(try await store.pending(conversationID: conversationID).map(\.id) == [first.id])
    }

    @Test("Steer-pending withdrawal restores the row to queued with the target cleared")
    func steerPendingWithdrawRestoresQueued() async throws {
        let conversationID = UUID()
        let store = EphemeralRunningInputStore(hostedConversationID: conversationID)
        let runID = UUID()
        let input = try await store.enqueue(PendingUserInput(
            conversationID: conversationID, targetRunID: runID, content: "steer me"
        ))
        try await store.beginSteerPromotion(id: input.id, expectedRunID: runID)
        try await store.markSteerAccepted(id: input.id, runID: runID)
        #expect(try await store.input(id: input.id)?.status == .steerPending)
        // The durable store accepts restoring a steerPending row; the
        // ephemeral store must mirror that transition exactly (this used to
        // throw and strand the row).
        try await store.restoreQueued(id: input.id)
        let restored = try #require(try await store.input(id: input.id))
        #expect(restored.status == .queued)
        #expect(restored.mode == .queue)
        #expect(restored.targetRunID == nil)
        #expect(try await store.pending(conversationID: conversationID).map(\.id) == [input.id])
    }

    @Test("Promotion carries the running-input queue and forwards the late tail")
    func promotionCarriesRunningInputs() async throws {
        let conversationID = UUID()
        let inputs = EphemeralRunningInputStore(hostedConversationID: conversationID)
        // One shared database so the input rows' target_run_id FK resolves
        // against the run header committed by the promotion.
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let durableConversation = SQLiteConversationStore(database: database)
        let durableRuns = SQLiteRunStore(database: database)
        let durableInputs = SQLiteRunningInputStore(database: database)

        // A live run header (and its conversation row) must exist before
        // inputs can target it (target_run_id / runs.conversation_id FKs
        // once forwarded).
        var conversation = makeSessionRecord(id: conversationID)
        conversation.purpose = .ordinary
        try await durableConversation.saveConversation(conversation)
        let run = RunRecord(
            id: UUID(), conversationID: conversationID,
            state: "running", goal: "input-goal", startedAt: Date()
        )
        try await durableRuns.saveRun(run)

        let first = try await inputs.enqueue(PendingUserInput(
            conversationID: conversationID, content: "queued-first"
        ))
        let steerRun = run.id
        let second = try await inputs.enqueue(PendingUserInput(
            conversationID: conversationID, targetRunID: steerRun, content: "steer-second"
        ))
        try await inputs.beginSteerPromotion(id: second.id, expectedRunID: steerRun)
        try await inputs.markSteerAccepted(id: second.id, runID: steerRun)

        // Promotion: the frozen watermark rows commit in the promoter's
        // transaction; a row enqueued DURING promotion is tail-only.
        let frozen = try await inputs.beginPromotion()
        #expect(frozen.count == 2)
        let during = try await inputs.enqueue(PendingUserInput(
            conversationID: conversationID, content: "queued-during"
        ))
        for input in frozen {
            try await durableInputs.upsert(input)
        }
        try await inputs.completePromotion(durable: durableInputs)

        // The whole queue is durable — no window where Keep reported success
        // but the pending messages only existed in RAM.
        let saved = try await durableInputs.pending(conversationID: conversationID)
        #expect(saved.map(\.id) == [first.id, second.id, during.id])
        #expect(saved.first(where: { $0.id == second.id })?.status == .steerPending)
        #expect(saved.first(where: { $0.id == second.id })?.targetRunID == steerRun)

        // Post-promotion mutations forward directly and mirror back: the
        // live run service holding this store reference reads current state.
        let claimed = try #require(try await inputs.claimNextQueued(conversationID: conversationID))
        #expect(claimed.id == first.id)
        #expect(try await durableInputs.input(id: first.id)?.status == .promoting)
        #expect(try await inputs.input(id: first.id)?.status == .promoting)
        let late = try await inputs.enqueue(PendingUserInput(
            conversationID: conversationID, content: "queued-after"
        ))
        #expect(try await durableInputs.input(id: late.id)?.content == "queued-after")
        let pendingIDs = try await inputs.pending(conversationID: conversationID).map(\.id)
        // 'promoting' is still a pending status: the claimed row stays in the
        // projection until it is consumed, exactly like the durable queue.
        #expect(pendingIDs == [first.id, second.id, during.id, late.id])
    }

    @Test("Forwarded conversation/run stores mirror writes: reads never serve a stale pre-Keep snapshot")
    func forwardedStoresReadCurrentState() async throws {
        let conversationID = UUID()
        let ephemeral = EphemeralConversationStore(record: makeSessionRecord(id: conversationID))
        let ephemeralRuns = EphemeralRunStore(hostedConversationID: conversationID)
        let (_, durable, durableRuns) = try await makeDurablePair()

        let run = RunRecord(
            id: UUID(), conversationID: conversationID,
            state: "preparing", goal: "mirror-goal", startedAt: Date()
        )
        try await ephemeralRuns.saveRun(run)
        try await ephemeral.appendMessage(PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "user",
            content: "mirror-base", createdAt: Date(), runID: run.id
        ))
        _ = try await ephemeral.beginPromotion()
        _ = try await ephemeralRuns.beginPromotion()
        var saved = try await ephemeral.bufferedSnapshot().conversation
        saved.purpose = .ordinary
        try await durable.saveConversation(saved)
        try await durableRuns.saveRun(run)
        for message in try await ephemeral.bufferedSnapshot().messages {
            try await durable.appendMessage(message)
        }
        try await ephemeral.completePromotion(durable: durable)
        try await ephemeralRuns.completePromotion(durable: durableRuns)

        // The run keeps streaming through its OWN store references.
        let lateMessage = PersistedMessage(
            id: UUID(), conversationID: conversationID, role: "assistant",
            content: "mirror-late", createdAt: Date().addingTimeInterval(1), runID: run.id
        )
        try await ephemeral.appendMessage(lateMessage)
        let event = try await ephemeralRuns.appendEvent(
            runID: run.id, kind: .assistantText, payloadJSON: #"{"delta":"mirror"}"#
        )
        try await ephemeralRuns.updateRunState(id: run.id, state: "completed", endedAt: Date())

        // BOTH sides read the identical current state (read-after-forwarded-
        // write), with durable-minted event identity.
        #expect(try await ephemeral.messages(conversationID: conversationID).map(\.content)
            == ["mirror-base", "mirror-late"])
        #expect(try await durable.messages(conversationID: conversationID).map(\.content)
            == ["mirror-base", "mirror-late"])
        #expect(try await ephemeralRuns.events(runID: run.id).map(\.id) == [event.id])
        #expect(try await ephemeralRuns.events(runID: run.id).map(\.sequence) == [1])
        #expect(try await durableRuns.events(runID: run.id).map(\.id) == [event.id])
        #expect(try await ephemeralRuns.run(id: run.id)?.state == "completed")
        #expect(try await durableRuns.run(id: run.id)?.state == "completed")
    }

    @Test("A mid-tail forwarding failure resumes exactly once without duplicating events")
    func runTailForwardingResumesWithoutDuplicates() async throws {
        let conversationID = UUID()
        let ephemeralRuns = EphemeralRunStore(hostedConversationID: conversationID)
        let (database, durableConversation, durableRuns) = try await makeDurablePair()
        let run = RunRecord(
            id: UUID(), conversationID: conversationID,
            state: "preparing", goal: "resume-goal", startedAt: Date()
        )
        try await ephemeralRuns.saveRun(run)
        for index in 0..<2 {
            _ = try await ephemeralRuns.appendEvent(
                runID: run.id, kind: .assistantText,
                payloadJSON: #"{"delta":"wm-\#(index)"}"#
            )
        }
        _ = try await ephemeralRuns.beginPromotion()
        for index in 0..<2 {
            _ = try await ephemeralRuns.appendEvent(
                runID: run.id, kind: .assistantText,
                payloadJSON: #"{"delta":"tail-\#(index)"}"#
            )
        }
        // The promoter commits the watermark rows with their ORIGINAL event
        // ids inside one GRDB transaction (conversation → run → events).
        var saved = ConversationRecord(
            id: conversationID, title: "", createdAt: Date(), updatedAt: Date(), purpose: .temporary
        )
        saved.purpose = .ordinary
        let frozen = try await ephemeralRuns.bufferedSnapshot()
        try await durableConversation.saveConversation(saved)
        try await durableRuns.saveRun(run)
        try await database.writer { db in
            for event in frozen.events[run.id, default: []] where event.sequence <= 2 {
                try db.execute(
                    sql: """
                        INSERT INTO run_events (id, run_id, sequence, kind, payload_json, created_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        event.id.uuidString, event.runID.uuidString, event.sequence,
                        event.kind.rawValue, event.payloadJSON,
                        PersistenceCodec.encode(event.createdAt)
                    ]
                )
            }
        }

        // First attempt: the durable store throws after the first tail row.
        let throwing = ThrowingRunStore(upstream: durableRuns, failEventAfterCount: 1)
        await #expect(throws: (any Error).self) {
            try await ephemeralRuns.completePromotion(durable: throwing)
        }
        // The watermark commit is intact; one tail event landed.
        #expect(try await durableRuns.events(runID: run.id).count == 3)

        // Retry resumes AFTER the forwarded tail row: total 4 events, unique
        // ids, contiguous sequences — never a duplicate.
        try await ephemeralRuns.completePromotion(durable: durableRuns)
        let events = try await durableRuns.events(runID: run.id)
        #expect(events.count == 4)
        #expect(Set(events.map(\.id)).count == 4)
        #expect(events.map(\.sequence) == [1, 2, 3, 4])
        #expect(events.last?.payloadJSON.contains("tail-1") == true)
        // The RAM mirror now serves the durable-minted identities.
        #expect(try await ephemeralRuns.events(runID: run.id).map(\.id) == events.map(\.id))
    }
}

/// Fails the Nth forwarded event append (after N successful durable appends)
/// to prove mid-tail resumption.
private actor ThrowingRunStore: RunStore {
    let upstream: SQLiteRunStore
    let failEventAfterCount: Int
    private var appended = 0

    init(upstream: SQLiteRunStore, failEventAfterCount: Int) {
        self.upstream = upstream
        self.failEventAfterCount = failEventAfterCount
    }

    func saveRun(_ run: RunRecord) async throws { try await upstream.saveRun(run) }
    func run(id: UUID) async throws -> RunRecord? { try await upstream.run(id: id) }
    func runs(conversationID: UUID) async throws -> [RunRecord] {
        try await upstream.runs(conversationID: conversationID)
    }
    func recentRuns(conversationID: UUID, limit: Int) async throws -> [RunRecord] {
        try await upstream.recentRuns(conversationID: conversationID, limit: limit)
    }
    func nonTerminalRuns() async throws -> [RunRecord] { try await upstream.nonTerminalRuns() }
    func updateRunState(id: UUID, state: String, endedAt: Date?) async throws {
        try await upstream.updateRunState(id: id, state: state, endedAt: endedAt)
    }
    func assignGoal(runID: UUID, goalID: UUID) async throws {
        try await upstream.assignGoal(runID: runID, goalID: goalID)
    }
    func appendEvent(runID: UUID, kind: RunEventRecord.Kind, payloadJSON: String) async throws -> RunEventRecord {
        appended += 1
        if appended > failEventAfterCount {
            throw FloeError.internalError("injected mid-tail forwarding failure")
        }
        return try await upstream.appendEvent(runID: runID, kind: kind, payloadJSON: payloadJSON)
    }
    func events(runID: UUID) async throws -> [RunEventRecord] { try await upstream.events(runID: runID) }
    func recentEvents(runID: UUID, limit: Int) async throws -> [RunEventRecord] {
        try await upstream.recentEvents(runID: runID, limit: limit)
    }
    func earlierEvents(runID: UUID, beforeSequence: Int, limit: Int) async throws -> [RunEventRecord] {
        try await upstream.earlierEvents(runID: runID, beforeSequence: beforeSequence, limit: limit)
    }
    func events(runID: UUID, afterSequence: Int, limit: Int) async throws -> [RunEventRecord] {
        try await upstream.events(runID: runID, afterSequence: afterSequence, limit: limit)
    }
    func recordUsage(_ usage: RunUsageRecord) async throws { try await upstream.recordUsage(usage) }
    func usage(runID: UUID) async throws -> [RunUsageRecord] { try await upstream.usage(runID: runID) }
    func recordError(_ error: RunErrorRecord) async throws { try await upstream.recordError(error) }
    func errors(runID: UUID) async throws -> [RunErrorRecord] { try await upstream.errors(runID: runID) }
    func saveCheckpoint(runID: UUID, conversationID: UUID, formatVersion: Int, state: String, bodyJSON: String) async throws {
        try await upstream.saveCheckpoint(runID: runID, conversationID: conversationID, formatVersion: formatVersion, state: state, bodyJSON: bodyJSON)
    }
    func checkpointBody(runID: UUID) async throws -> String? { try await upstream.checkpointBody(runID: runID) }
    func deleteCheckpoint(runID: UUID) async throws { try await upstream.deleteCheckpoint(runID: runID) }
    func usageStatistics() async throws -> UsageStatistics { try await upstream.usageStatistics() }
}
