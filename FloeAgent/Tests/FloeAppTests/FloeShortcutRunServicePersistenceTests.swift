// S3-C focused tests on the REAL persistence path.
//
// Runs, assistant messages, terminal/error markers and the exact-run reply
// reader all use the production SQLite stores in an isolated in-memory
// database. Only provider work, model configuration and process ownership are
// injected, because starting or cancelling a live run is outside this suite.

import XCTest
@testable import FloeApp
import FloeCore
import FloeModels
import FloePersistence

final class FloeShortcutRunServicePersistenceTests: XCTestCase {

    private var database: DatabaseManager!
    private var conversations: SQLiteConversationStore!
    private var runs: SQLiteRunStore!

    override func setUp() async throws {
        try await super.setUp()
        database = try DatabaseManager.inMemory()
        try await database.migrate()
        conversations = SQLiteConversationStore(database: database)
        runs = SQLiteRunStore(database: database)
    }

    override func tearDown() async throws {
        conversations = nil
        runs = nil
        database = nil
        try await super.tearDown()
    }

    private func makeService() -> FloeShortcutRunService {
        let conversations = self.conversations!
        let runs = self.runs!
        let reader = SQLiteRunReplyReader(database: database)
        return FloeShortcutRunService(deps: FloeShortcutRunDeps(
            ensureReady: { _ in },
            capabilityEnabled: { true },
            defaultModel: { nil },
            startTask: { _ in throw FloeShortcutRunError.noDefaultModelConfigured },
            cancelRun: { _ in },
            hasLiveOwner: { _ in false },
            loadRun: { try await runs.run(id: $0) },
            loadConversation: { try await conversations.conversation(id: $0) },
            recentRunEvents: { runID, limit in
                try await runs.recentEvents(runID: runID, limit: limit)
            },
            earlierRunEvents: { runID, sequence, limit in
                try await runs.earlierEvents(runID: runID, beforeSequence: sequence, limit: limit)
            },
            provenFinalReplyText: { runID, conversationID, messageID in
                try await reader.provenFinalReplyText(
                    runID: runID, conversationID: conversationID, messageID: messageID)
            },
            monotonicNow: { 0 },
            pause: { _ in }
        ))
    }

    @discardableResult
    private func seedConversation(_ id: UUID = UUID(), title: String = "Synthetic task") async throws -> UUID {
        try await conversations.saveConversation(.init(
            id: id, title: title, createdAt: Date(), updatedAt: Date()))
        return id
    }

    @discardableResult
    private func seedRun(
        conversationID: UUID,
        runID: UUID = UUID(),
        state: String = "completed"
    ) async throws -> UUID {
        try await runs.saveRun(.init(
            id: runID,
            conversationID: conversationID,
            state: state,
            goal: "Synthetic goal",
            startedAt: Date(),
            endedAt: ["completed", "failed", "cancelled", "interrupted"].contains(state) ? Date() : nil
        ))
        return runID
    }

    @discardableResult
    private func appendAssistant(
        conversationID: UUID,
        runID: UUID,
        _ text: String,
        role: String = "assistant"
    ) async throws -> UUID {
        let messageID = UUID()
        try await conversations.appendMessage(.init(
            id: messageID, conversationID: conversationID, role: role,
            content: text, createdAt: Date(), runID: runID))
        return messageID
    }

    private func appendAssistantEvent(runID: UUID, _ text: String) async throws {
        _ = try await runs.appendEvent(
            runID: runID, kind: .assistantText,
            payloadJSON: "{\"text\":\"\(text)\"}")
    }

    private func appendToolRequest(runID: UUID) async throws {
        _ = try await runs.appendEvent(
            runID: runID, kind: .toolRequest, payloadJSON: "{}")
    }

    /// Production-shape terminal marker: `finalMessageID` is present only
    /// when the runtime actually persisted (or CONFIRM-bound) that row.
    private func appendTerminal(
        runID: UUID,
        stopReason: String,
        finalMessageID: UUID? = nil
    ) async throws {
        let payload: String
        if let finalMessageID {
            payload = "{\"stopReason\":\"\(stopReason)\",\"finalMessageID\":\"\(finalMessageID.uuidString)\"}"
        } else {
            payload = "{\"stopReason\":\"\(stopReason)\"}"
        }
        _ = try await runs.appendEvent(
            runID: runID, kind: .terminal,
            payloadJSON: payload)
    }

    private func appendNoFinalText(runID: UUID) async throws {
        _ = try await runs.appendEvent(
            runID: runID, kind: .error,
            payloadJSON: "{\"message\":\"noFinalText\"}")
    }

    // MARK: Exact final answer

    func testCompletedRunReturnsItsOwnFinalMessageNotTheStep() async throws {
        let conversationID = try await seedConversation()
        let stepRun = try await seedRun(conversationID: conversationID)
        try await appendAssistant(conversationID: conversationID, runID: stepRun, "I will check")
        try await appendAssistantEvent(runID: stepRun, "I will check")
        try await appendToolRequest(runID: stepRun)
        let finalRow = try await appendAssistant(
            conversationID: conversationID, runID: stepRun,
            "Final answer for the exact run")
        try await appendAssistantEvent(runID: stepRun, "Final answer for the exact run")
        try await appendTerminal(runID: stepRun, stopReason: "endTurn", finalMessageID: finalRow)

        let service = makeService()
        let result = try await service.textResult(runID: stepRun)
        XCTAssertEqual(result.text, "Final answer for the exact run")
        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.status.conversationID, Optional(conversationID))
    }

    func testConcurrentRunsKeepTheirOwnResults() async throws {
        let conversationID = try await seedConversation()
        let firstRun = try await seedRun(conversationID: conversationID)
        let secondRun = try await seedRun(conversationID: conversationID)
        let firstRow = try await appendAssistant(conversationID: conversationID, runID: firstRun, "First final")
        try await appendAssistantEvent(runID: firstRun, "First final")
        let secondRow = try await appendAssistant(conversationID: conversationID, runID: secondRun, "Second final")
        try await appendAssistantEvent(runID: secondRun, "Second final")
        try await appendTerminal(runID: firstRun, stopReason: "endTurn", finalMessageID: firstRow)
        try await appendTerminal(runID: secondRun, stopReason: "endTurn", finalMessageID: secondRow)

        let service = makeService()
        async let first = service.textResult(runID: firstRun)
        async let second = service.textResult(runID: secondRun)
        let (firstResult, secondResult) = try await (first, second)
        XCTAssertEqual(firstResult.text, "First final")
        XCTAssertEqual(secondResult.text, "Second final")
        XCTAssertEqual(firstResult.status.runID, Optional(firstRun))
        XCTAssertEqual(secondResult.status.runID, Optional(secondRun))
    }

    /// Exact counter-example: the run persisted a pre-tool "I will check"
    /// step, then the provider stopped without a final assistant message. The
    /// runtime records `noFinalText` before the terminal marker. Neither that
    /// step nor a later run's answer may be presented as this run's result.
    func testStepOnlyRunReturnsAbsentEvenWithLaterRunText() async throws {
        let conversationID = try await seedConversation()
        let targetRun = try await seedRun(conversationID: conversationID)
        try await appendAssistant(conversationID: conversationID, runID: targetRun, "I will check")
        try await appendAssistantEvent(runID: targetRun, "I will check")
        try await appendNoFinalText(runID: targetRun)
        try await appendTerminal(runID: targetRun, stopReason: "endTurn")

        let laterRun = try await seedRun(conversationID: conversationID)
        let laterRow = try await appendAssistant(conversationID: conversationID, runID: laterRun, "Later task answer")
        try await appendAssistantEvent(runID: laterRun, "Later task answer")
        try await appendTerminal(runID: laterRun, stopReason: "endTurn", finalMessageID: laterRow)

        let service = makeService()
        let target = try await service.textResult(runID: targetRun)
        XCTAssertNil(target.text)
        XCTAssertEqual(target.completeness, .absent(.noFinalText))
        XCTAssertFalse(target.status.isFullSuccess)

        let later = try await service.textResult(runID: laterRun)
        XCTAssertEqual(later.text, "Later task answer")
    }

    /// Real chronology counter-example: a completed header whose newest
    /// assistant text precedes a tool request/result. That text is a pre-tool
    /// step ("I will check"), so no final text is exported even without the
    /// `noFinalText` marker.
    func testCompletedStepBeforeToolIsNotFinalWithoutMarker() async throws {
        let conversationID = try await seedConversation()
        let runID = try await seedRun(conversationID: conversationID)
        try await appendAssistant(conversationID: conversationID, runID: runID, "I will check")
        try await appendAssistantEvent(runID: runID, "I will check")
        try await appendToolRequest(runID: runID)
        _ = try await runs.appendEvent(runID: runID, kind: .toolResult, payloadJSON: "{}")
        try await appendTerminal(runID: runID, stopReason: "endTurn")

        let service = makeService()
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .completed)
        XCTAssertFalse(status.finalReplyProven)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven))
    }

    /// A malformed/empty final row addressed by the marker is an explicit
    /// empty absence, never a fallback to the earlier "I will check" step.
    func testEmptyFinalRowIsAbsentNotTheEarlierStep() async throws {
        let conversationID = try await seedConversation()
        let runID = try await seedRun(conversationID: conversationID)
        try await appendAssistant(conversationID: conversationID, runID: runID, "I will check")
        let emptyRow = try await appendAssistant(conversationID: conversationID, runID: runID, "")
        try await appendAssistantEvent(runID: runID, "Final flush")
        try await appendTerminal(runID: runID, stopReason: "endTurn", finalMessageID: emptyRow)

        let service = makeService()
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.noAssistantTextPersisted))
    }

    /// Legacy/corrupt shape: a completed header with a valid terminal but no
    /// final-message identity. Even though newer assistant rows exist, the
    /// strict contract reports an honest absence instead of reading them.
    func testTerminalWithoutIdentityNeverFallsBackToLatestRow() async throws {
        let conversationID = try await seedConversation()
        let runID = try await seedRun(conversationID: conversationID)
        try await appendAssistant(conversationID: conversationID, runID: runID, "I will check")
        try await appendAssistant(conversationID: conversationID, runID: runID, "Last known text")
        try await appendAssistantEvent(runID: runID, "Last known text")
        try await appendTerminal(runID: runID, stopReason: "endTurn")

        let service = makeService()
        let status = try await service.status(runID: runID)
        XCTAssertFalse(status.finalReplyProven)
        XCTAssertFalse(status.isFullSuccess)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven))
    }

    /// A marker that references another run's row (cross-run substitution)
    /// must not export that text; the reader predicate rejects it.
    func testCrossRunMarkerIdentityIsRejected() async throws {
        let conversationID = try await seedConversation()
        let targetRun = try await seedRun(conversationID: conversationID)
        let otherRun = try await seedRun(conversationID: conversationID)
        let otherRow = try await appendAssistant(
            conversationID: conversationID, runID: otherRun, "Other run's answer")
        try await appendAssistantEvent(runID: otherRun, "Other run's answer")
        try await appendTerminal(runID: otherRun, stopReason: "endTurn", finalMessageID: otherRow)
        try await appendAssistantEvent(runID: targetRun, "I will check")
        try await appendTerminal(runID: targetRun, stopReason: "endTurn", finalMessageID: otherRow)

        let service = makeService()
        let result = try await service.textResult(runID: targetRun)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven),
            "a foreign-run id must not resolve through the exact-run predicate")
        let legitimate = try await service.textResult(runID: otherRun)
        XCTAssertEqual(legitimate.text, "Other run's answer")
    }

    /// A marker referencing a non-assistant row of the same run (forged
    /// identity) never yields text.
    func testMarkerToNonAssistantRowIsRejected() async throws {
        let conversationID = try await seedConversation()
        let runID = try await seedRun(conversationID: conversationID)
        let toolRow = try await appendAssistant(
            conversationID: conversationID, runID: runID, "tool output", role: "tool")
        try await appendAssistantEvent(runID: runID, "I will check")
        try await appendTerminal(runID: runID, stopReason: "endTurn", finalMessageID: toolRow)

        let service = makeService()
        let status = try await service.status(runID: runID)
        XCTAssertTrue(status.finalReplyProven,
            "the marker itself is well-formed; only the row predicate can veto it")
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyUnproven),
            "role is part of the identity: a tool row is never an assistant answer")
    }

    /// The failure path never persists a final assistant message. Even if the
    /// run's newest assistant row is a pre-tool "I will check" step, the text
    /// action must not export it.
    func testFailedRunAfterToolStepExportsNoIntermediateText() async throws {
        let conversationID = try await seedConversation()
        let runID = try await seedRun(conversationID: conversationID, state: "failed")
        try await appendAssistant(conversationID: conversationID, runID: runID, "I will check")
        _ = try await runs.appendEvent(
            runID: runID, kind: .status,
            payloadJSON: "{\"state\":\"failed\",\"reason\":\"Synthetic failure\"}")

        let service = makeService()
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .failed)
        XCTAssertFalse(status.finalReplyProven)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyNotPersisted))
    }

    func testInterruptedRunExportsNoIntermediateText() async throws {
        let conversationID = try await seedConversation()
        let runID = try await seedRun(conversationID: conversationID, state: "interrupted")
        try await appendAssistant(conversationID: conversationID, runID: runID, "I will check")

        let service = makeService()
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.state, .interrupted)
        XCTAssertTrue(status.finishedPerDurableRecord)
        XCTAssertFalse(status.finalReplyProven)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        XCTAssertEqual(result.completeness, .absent(.finalReplyNotPersisted))
    }

    /// A provider completion that stopped with `cancelled` keeps the
    /// `completed` durable header, saved its partial final message before the
    /// terminal marker, and remains readable as an explicitly partial reply.
    func testCancelledCompletionKeepsProvenPartialText() async throws {
        let conversationID = try await seedConversation()
        let runID = try await seedRun(conversationID: conversationID)
        let halfRow = try await appendAssistant(conversationID: conversationID, runID: runID, "Half an answer")
        try await appendAssistantEvent(runID: runID, "Half an answer")
        try await appendTerminal(runID: runID, stopReason: "cancelled", finalMessageID: halfRow)

        let service = makeService()
        let result = try await service.textResult(runID: runID)
        XCTAssertEqual(result.status.state, .cancelled)
        XCTAssertTrue(result.status.finalReplyProven)
        XCTAssertEqual(result.text, "Half an answer")
        guard case .partial(let caveats) = result.completeness else {
            return XCTFail("expected partial")
        }
        XCTAssertEqual(caveats, [.cancelledMidRun])
    }

    func testMissingRunIsUnavailableWithoutReadingConversationHistory() async throws {
        let service = makeService()
        let status = try await service.status(runID: UUID())
        XCTAssertEqual(status.state, .unavailable)
        XCTAssertEqual(status.unavailableReason, .runNotFound)
        let result = try await service.textResult(runID: UUID())
        XCTAssertNil(result.text)
        if case .untrustworthy = result.completeness {} else {
            XCTFail("expected untrustworthy")
        }
    }

    func testNotesConversationIsRefusedEvenForOrdinaryRunRow() async throws {
        let conversationID = UUID()
        try await conversations.saveConversation(.init(
            id: conversationID, title: "Notes", createdAt: Date(), updatedAt: Date(),
            purpose: .notes))
        let runID = try await seedRun(conversationID: conversationID)
        let notesRow = try await appendAssistant(conversationID: conversationID, runID: runID, "Notes answer")
        try await appendAssistantEvent(runID: runID, "Notes answer")
        try await appendTerminal(runID: runID, stopReason: "endTurn", finalMessageID: notesRow)

        let service = makeService()
        let status = try await service.status(runID: runID)
        XCTAssertEqual(status.unavailableReason, .notesConversation)
        let result = try await service.textResult(runID: runID)
        XCTAssertNil(result.text)
        if case .untrustworthy = result.completeness {} else {
            XCTFail("expected untrustworthy")
        }
    }
}
