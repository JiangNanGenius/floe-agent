// SPDX-License-Identifier: MPL-2.0
//
// G07.3A user-question HOST boundary semantics (job-70e89b95f588494c).
//
// The store already returns a settled question's ORIGINAL receipt before its
// pending revision CAS. The host API must not hide that contract behind its
// own pre-checks: a duplicate in-app/notification reply after the first
// answer must receive accepted=false/alreadySettled=true, while a durable
// pending row with NO parked execution (process death) stays fail-closed.
//
// These tests exercise the REAL installed host API, its real coordinator and
// a real migrated SQLite database. No provider/network/UI is involved.
import XCTest
import FloeCore
import FloeModels
import FloePersistence
import FloeAgentRuntime
import FloeTools
@testable import FloeAndroidCore

final class UserQuestionHostAPITests: XCTestCase {

    private var database: DatabaseManager!
    private var url: URL!
    private var epoch: UInt64 = 0

    override func setUp() async throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-uq-host-\(UUID().uuidString).db")
        database = try DatabaseManager(path: url)
        try await database.migrate()
    }

    override func tearDown() async throws {
        if epoch != 0 {
            UserQuestionHostAPI.shared.retire(epoch: epoch)
        }
        try? await database.close()
        try? FileManager.default.removeItem(at: url)
    }

    private func install(epoch value: UInt64) -> UserQuestionCoordinator {
        epoch = value
        return UserQuestionHostAPI.shared.install(database: database, epoch: value)
    }

    /// Minimal REAL conversation/run rows for the durable question tables'
    /// foreign keys. The question store's own durable path is what is under
    /// test here; nothing else about the task is fabricated.
    private func ensureTask(conversationID: UUID, runID: UUID) async throws {
        try await database.writer { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations (
                        id, title, created_at, updated_at, title_origin,
                        mode, is_searchable, archived_at, purpose
                    ) VALUES (?, 'question-test', ?, ?, 'manual', 'chat', 1, NULL, 'ordinary')
                    """,
                arguments: [conversationID.uuidString,
                            "2026-10-01T00:00:00.000Z", "2026-10-01T00:00:00.000Z"])
            try db.execute(
                sql: """
                    INSERT INTO runs (id, conversation_id, state, goal, started_at)
                    VALUES (?, ?, 'completed', 'question-test', ?)
                    """,
                arguments: [runID.uuidString, conversationID.uuidString,
                            "2026-10-01T00:00:00.000Z"])
        }
    }

    private func request() throws -> UserQuestionRequest {
        try UserQuestionRequest(
            waitPolicy: .required,
            questions: [
                UserQuestionDraft(
                    id: "q1",
                    question: "Proceed?",
                    options: [
                        UserQuestionOption(id: "yes", label: "Yes"),
                        UserQuestionOption(id: "no", label: "No"),
                    ],
                    selection: .single)
            ])
    }

    /// Direct durable registration without a parked execution: the exact
    /// process-death shape the host must refuse to settle.
    private func registerWithoutWaiter(
        requestID: String,
        conversationID: UUID,
        runID: UUID,
        digest: String
    ) async throws -> UserQuestionWaitingSnapshot {
        let questions = try request().makeQuestions(
            requestID: requestID,
            conversationID: conversationID,
            runID: runID,
            toolCallID: "call-\(requestID)",
            createdAt: Date())
        return try await UserQuestionStore(database: database).register(
            UserQuestionRegistration(
                requestID: requestID,
                requestDigest: digest,
                conversationID: conversationID,
                runID: runID,
                toolCallID: "call-\(requestID)",
                waitPolicy: .required,
                questions: questions,
                createdAt: Date(),
                isEphemeral: false))
    }

    private func payload(
        snapshot: UserQuestionWaitingSnapshot,
        questionIndex: Int = 0,
        revision: Int? = nil,
        nonce: String? = nil,
        runID: UUID? = nil,
        requestDigest: String? = nil,
        questionID: String? = nil,
        selectedOptionIDs: [String] = ["yes"]
    ) -> SettingsDomainV1.JSONValue {
        let question = snapshot.questions[questionIndex]
        let expectedRevision = revision ?? question.revision
        let digest = requestDigest ?? snapshot.requestDigest
        let answerNonce = nonce ?? UserQuestionHostWire.answerNonce(
            requestID: snapshot.requestID,
            questionID: questionID ?? question.questionID,
            revision: expectedRevision,
            requestDigest: digest)
        return .object([
            "requestID": .string(snapshot.requestID),
            "requestDigest": .string(digest),
            "questionID": .string(questionID ?? question.questionID),
            "runID": .string((runID ?? snapshot.runID).uuidString),
            "expectedRevision": .integer(Int64(expectedRevision)),
            "answerNonce": .string(answerNonce),
            "source": .string(UserQuestionAnswerSource.human.rawValue),
            "selectedOptionIDs": .array(selectedOptionIDs.map { .string($0) }),
        ])
    }

    private func waitForSnapshot(
        _ coordinator: UserQuestionCoordinator,
        conversationID: UUID
    ) async throws -> UserQuestionWaitingSnapshot {
        for _ in 0..<200 {
            let pending = try await coordinator.snapshots(
                conversationID: conversationID, includeSettled: false)
            if let snapshot = pending.first { return snapshot }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("the requested flow never parked a question")
        throw UserQuestionError.notFound
    }

    /// The retained contract: a duplicate reply after the FIRST answer gets
    /// the original receipt, not requestCancelled/staleRevision. The real
    /// parked execution makes the first settlement legitimate; the duplicate
    /// must not need a second waiter or a fresh revision.
    func testDuplicateReplyAfterSettlementReturnsTheOriginalReceipt() async throws {
        let coordinator = install(epoch: 7_001)
        let conversationID = UUID()
        let runID = UUID()
        try await ensureTask(conversationID: conversationID, runID: runID)
        let request = try request()
        let toolCallID = "call-duplicate"

        let asked = Task {
            try await coordinator.ask(
                request,
                runID: runID,
                conversationID: conversationID,
                toolCallID: toolCallID,
                cancellation: CancellationToken(),
                temporaryReadOnly: false)
        }
        let first = try await waitForSnapshot(coordinator, conversationID: conversationID)
        let activelyWaiting = await coordinator.isActivelyWaiting(requestID: first.requestID)
        XCTAssertTrue(activelyWaiting)
        XCTAssertEqual(first.questions[0].revision, 1)

        let firstPayload = payload(snapshot: first)
        let firstReply = try await UserQuestionHostAPI.shared.answer(
            conversationID: conversationID, epoch: epoch, payload: firstPayload)
        XCTAssertEqual(firstReply["accepted"] as? Bool, true)
        XCTAssertEqual(firstReply["alreadySettled"] as? Bool, false)
        XCTAssertEqual(firstReply["status"] as? String, UserQuestionStatus.answered.rawValue)
        XCTAssertEqual(firstReply["revision"] as? Int, 2)
        _ = try await asked.value

        // The EXACT same card/reply arrives again (double tap / receiver
        // re-entry). No parked continuation exists now; the settled row must
        // still return its original receipt byte-for-byte.
        let stillWaiting = await coordinator.isActivelyWaiting(requestID: first.requestID)
        XCTAssertFalse(stillWaiting)
        let duplicate = try await UserQuestionHostAPI.shared.answer(
            conversationID: conversationID, epoch: epoch, payload: firstPayload)
        XCTAssertEqual(duplicate["accepted"] as? Bool, false)
        XCTAssertEqual(duplicate["alreadySettled"] as? Bool, true)
        XCTAssertEqual(duplicate["status"] as? String, UserQuestionStatus.answered.rawValue)
        XCTAssertEqual(duplicate["revision"] as? Int, 2)
        XCTAssertEqual(duplicate["requestState"] as? String,
                       UserQuestionRequestState.settled.rawValue)
        let original = firstReply["answer"] as? [String: Any]
        let replayed = duplicate["answer"] as? [String: Any]
        XCTAssertEqual(original?["selectedOptionIDs"] as? [String],
                       replayed?["selectedOptionIDs"] as? [String])
        XCTAssertEqual(original?["source"] as? String, replayed?["source"] as? String)

        // A third identical re-entry stays at the same revision: never a new
        // settlement, always the original one.
        let third = try await UserQuestionHostAPI.shared.answer(
            conversationID: conversationID, epoch: epoch, payload: firstPayload)
        XCTAssertEqual(third["alreadySettled"] as? Bool, true)
        XCTAssertEqual(third["revision"] as? Int, 2)
    }

    /// A durable pending row with no parked execution is process-death
    /// debris. It must stay unanswerable: no receipt, no settlement, no fake
    /// continuation.
    func testPendingWithoutAParkedExecutionIsRefusedAndRemainsPending() async throws {
        let coordinator = install(epoch: 7_002)
        let conversationID = UUID()
        let runID = UUID()
        try await ensureTask(conversationID: conversationID, runID: runID)
        let requestID = "uq_" + String(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(32))
        let digest = String(repeating: "c", count: 64)
        let registered = try await registerWithoutWaiter(
            requestID: requestID, conversationID: conversationID,
            runID: runID, digest: digest)
        let waiting = await coordinator.isActivelyWaiting(requestID: registered.requestID)
        XCTAssertFalse(waiting)

        do {
            _ = try await UserQuestionHostAPI.shared.answer(
                conversationID: conversationID, epoch: epoch,
                payload: payload(snapshot: registered))
            XCTFail("a pending row with no parked execution must not settle")
        } catch let error as UserQuestionError {
            XCTAssertEqual(error, .requestCancelled)
        }
        let after = try await coordinator.snapshot(requestID: registered.requestID)
        XCTAssertEqual(after?.questions[0].status, .pending)
        XCTAssertEqual(after?.questions[0].revision, 1)
    }

    /// Every envelope dimension is revalidated before the settled shortcut;
    /// none of them is widened by the duplicate-receipt repair.
    func testForeignEnvelopeAndWrongNonceNeverReachTheSettledPath() async throws {
        let coordinator = install(epoch: 7_003)
        let conversationID = UUID()
        let runID = UUID()
        try await ensureTask(conversationID: conversationID, runID: runID)
        let request = try request()
        let asked = Task {
            try await coordinator.ask(
                request,
                runID: runID,
                conversationID: conversationID,
                toolCallID: "call-foreign",
                cancellation: CancellationToken(),
                temporaryReadOnly: false)
        }
        let first = try await waitForSnapshot(coordinator, conversationID: conversationID)
        _ = try await UserQuestionHostAPI.shared.answer(
            conversationID: conversationID, epoch: epoch,
            payload: payload(snapshot: first))
        _ = try await asked.value

        let foreignConversation = UUID()
        let cases: [(String, SettingsDomainV1.JSONValue, UUID, UserQuestionError)] = [
            ("foreignRun", payload(snapshot: first, runID: UUID()),
             conversationID, .runMismatch),
            ("foreignConversation", payload(snapshot: first),
             foreignConversation, .runMismatch),
            ("foreignQuestion", payload(snapshot: first, questionID: first.requestID + ".q99"),
             conversationID, .runMismatch),
            ("foreignDigest", payload(snapshot: first,
                                      requestDigest: String(repeating: "d", count: 64)),
             conversationID, .runMismatch),
            ("foreignNonce", payload(snapshot: first, nonce: String(repeating: "e", count: 64)),
             conversationID, .staleRevision(current: 2)),
            ("unissuedRevision", payload(snapshot: first, revision: 99),
             conversationID, .staleRevision(current: 2)),
        ]
        for (label, badPayload, commandConversation, expected) in cases {
            do {
                _ = try await UserQuestionHostAPI.shared.answer(
                    conversationID: commandConversation, epoch: epoch, payload: badPayload)
                XCTFail("\(label) must be refused")
            } catch let error as UserQuestionError {
                XCTAssertEqual(error, expected, label)
            }
        }

        // The exact original reply still works after every refused variant.
        let replay = try await UserQuestionHostAPI.shared.answer(
            conversationID: conversationID, epoch: epoch,
            payload: payload(snapshot: first))
        XCTAssertEqual(replay["alreadySettled"] as? Bool, true)
    }
}
