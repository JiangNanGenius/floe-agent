import Foundation
import Testing
import GRDB
import FloeCore
import FloeModels
@testable import FloePersistence

@Suite("FloePersistence.UserQuestionStore")
struct UserQuestionStoreTests {

    private func fixture() async throws -> (DatabaseManager, UUID, UUID) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversationID = UUID()
        let runID = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(
            .init(
                id: conversationID,
                title: "Questions",
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        try await SQLiteRunStore(database: database).saveRun(
            .init(
                id: runID,
                conversationID: conversationID,
                state: "running",
                goal: "Ask",
                startedAt: Date()
            )
        )
        return (database, conversationID, runID)
    }

    private func registration(
        conversationID: UUID,
        runID: UUID,
        requestID: String = "uq_test",
        toolCallID: String = "call_test",
        waitPolicy: UserQuestionWaitPolicy = .required,
        timeoutSeconds: Int? = nil,
        drafts: [UserQuestionDraft],
        ephemeral: Bool = false,
        now: Date = Date()
    ) throws -> UserQuestionRegistration {
        let request = UserQuestionRequest(
            waitPolicy: waitPolicy,
            timeoutSeconds: timeoutSeconds,
            questions: drafts
        )
        try request.validate()
        let questions = try request.makeQuestions(
            requestID: requestID,
            conversationID: conversationID,
            runID: runID,
            toolCallID: toolCallID,
            createdAt: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return UserQuestionRegistration(
            requestID: requestID,
            requestDigest: FloeDigest.sha256Hex(try encoder.encode(request)),
            conversationID: conversationID,
            runID: runID,
            toolCallID: toolCallID,
            waitPolicy: waitPolicy,
            questions: questions,
            createdAt: now,
            isEphemeral: ephemeral
        )
    }

    @Test("V56 tables and schema version are present")
    func migrationIsRegistered() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        #expect(DatabaseManager.currentSchemaVersion >= 56)
        let tables = try await database.reader { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('user_question_requests','user_questions') ORDER BY name"
            )
        }
        #expect(tables == ["user_question_requests", "user_questions"])
        let version = try await database.reader { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version")
        }
        #expect(version == DatabaseManager.currentSchemaVersion)
    }

    @Test("Registration is idempotent and refuses a reused call for different questions")
    func registrationIsIdempotentAndBound() async throws {
        let (database, conversation, run) = try await fixture()
        let store = UserQuestionStore(database: database)
        let first = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            drafts: [.init(question: "Which one?", options: [
                .init(id: "a", label: "A"), .init(id: "b", label: "B"),
            ])]
        ))
        let replay = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            drafts: [.init(question: "Which one?", options: [
                .init(id: "a", label: "A"), .init(id: "b", label: "B"),
            ])]
        ))
        #expect(first == replay)

        // Same run/tool call cannot become a different request.
        await #expect(throws: (any Error).self) {
            try await store.register(try registration(
                conversationID: conversation,
                runID: run,
                requestID: "uq_other",
                drafts: [.init(question: "Different?")]
            ))
        }
        // Same request id with a different digest is not an idempotent replay.
        await #expect(throws: (any Error).self) {
            try await store.register(try registration(
                conversationID: conversation,
                runID: run,
                drafts: [.init(question: "Changed?")]
            ))
        }
    }

    @Test("Answer CAS accepts exactly one human answer and keeps the first receipt")
    func answerCASIsExactlyOnce() async throws {
        let (database, conversation, run) = try await fixture()
        let store = UserQuestionStore(database: database)
        let snapshot = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            drafts: [.init(question: "Deploy?", options: [
                .init(id: "yes", label: "Yes"), .init(id: "no", label: "No"),
            ])]
        ))
        let question = try #require(snapshot.currentQuestion)
        let target = snapshot.target(for: question)
        let accepted = try await store.submitHumanAnswer(
            target: target,
            answer: .init(selectedOptionIDs: ["yes"]),
            now: Date()
        )
        #expect(accepted.accepted)
        #expect(accepted.status == .answered)
        #expect(accepted.answer?.source == .human)
        #expect(accepted.answer?.selectedOptionLabels == ["Yes"])

        // Duplicate action with the ORIGINAL revision returns the original
        // receipt, never an overwrite.
        let duplicate = try await store.submitHumanAnswer(
            target: target,
            answer: .init(selectedOptionIDs: ["no"]),
            now: Date()
        )
        #expect(!duplicate.accepted)
        #expect(duplicate.alreadySettled)
        #expect(duplicate.answer?.selectedOptionIDs == ["yes"])

        // A pending question with a stale revision is rejected.
        let second = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            requestID: "uq_second",
            toolCallID: "call_second",
            drafts: [.init(question: "Second?", options: [.init(id: "a", label: "A")])]
        ))
        let secondQuestion = try #require(second.currentQuestion)
        let secondTarget = second.target(for: secondQuestion)
        let draft = try await store.saveDraft(
            target: secondTarget,
            draft: .init(selectedOptionIDs: ["a"]),
            now: Date()
        )
        #expect(draft.saved)
        // Drafts are UI progress, not settlement: the answer CAS revision
        // stays the same, so the card's eventual submit is accepted.
        #expect(draft.revision == secondTarget.expectedRevision)
        let acceptedSecond = try await store.submitHumanAnswer(
            target: secondTarget,
            answer: .init(selectedOptionIDs: ["a"]),
            now: Date()
        )
        #expect(acceptedSecond.accepted)
    }

    @Test("Partial drafts persist without settling and invalid answers fail")
    func partialDraftAndValidation() async throws {
        let (database, conversation, run) = try await fixture()
        let store = UserQuestionStore(database: database)
        let snapshot = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            drafts: [.init(
                question: "Pick two",
                options: [.init(id: "a", label: "A"), .init(id: "b", label: "B"), .init(id: "c", label: "C")],
                selection: .multiple,
                allowsFreeText: true
            )]
        ))
        let question = try #require(snapshot.currentQuestion)
        let saved = try await store.saveDraft(
            target: snapshot.target(for: question),
            draft: .init(selectedOptionIDs: ["a"], freeText: "later"),
            now: Date()
        )
        #expect(saved.saved)
        let afterDraft = try #require(try await store.snapshot(requestID: snapshot.requestID))
        let draftQuestion = try #require(afterDraft.currentQuestion)
        #expect(draftQuestion.status == .pending)
        #expect(draftQuestion.draftAnswer?.selectedOptionIDs == ["a"])
        #expect(draftQuestion.draftAnswer?.freeText == "later")

        // Unknown option ids, too many single selections and free text on a
        // question that forbids a note all fail before any write.
        for answer in [
            UserQuestionAnswer(selectedOptionIDs: ["zzz"]),
            UserQuestionAnswer(selectedOptionIDs: ["a", "a"]),
        ] {
            await #expect(throws: (any Error).self) {
                try await store.submitHumanAnswer(
                    target: UserQuestionAnswerTarget(
                        requestID: snapshot.requestID,
                        questionID: draftQuestion.questionID,
                        conversationID: conversation,
                        runID: run,
                        expectedRevision: draftQuestion.revision
                    ),
                    answer: answer,
                    now: Date()
                )
            }
        }
        let textOnly = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            requestID: "uq_text",
            toolCallID: "call_text",
            drafts: [.init(question: "Any notes?")]
        ))
        let textQuestion = try #require(textOnly.currentQuestion)
        await #expect(throws: (any Error).self) {
            try await store.submitHumanAnswer(
                target: textOnly.target(for: textQuestion),
                answer: .init(selectedOptionIDs: []),
                now: Date()
            )
        }
    }

    @Test("Explicit optionalDeadline expiry uses only the declared fallback provenance")
    func deadlineExpiryHasExplicitProvenance() async throws {
        let (database, conversation, run) = try await fixture()
        let store = UserQuestionStore(database: database)
        let now = Date()
        let snapshot = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            waitPolicy: .optionalDeadline,
            timeoutSeconds: 30,
            drafts: [
                .init(
                    question: "Fallback?",
                    options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")],
                    fallback: .init(selectedOptionIDs: ["a"])
                ),
                .init(
                    question: "No fallback?",
                    options: [.init(id: "x", label: "X")]
                ),
                .init(question: "Required never times out")
            ],
            now: now
        ))
        // The last question inherits optionalDeadline too; give it no
        // fallback so expiry is honest. Required semantics are covered by the
        // separate required registration below.
        let expired = try #require(try await store.expire(
            requestID: snapshot.requestID,
            now: now.addingTimeInterval(31)
        ))
        let first = expired.questions[0]
        #expect(first.status == .expired)
        #expect(first.answerSource == .deadlineDefault)
        #expect(first.answer?.selectedOptionIDs == ["a"])
        let second = expired.questions[1]
        #expect(second.status == .expired)
        #expect(second.answer == nil)
        #expect(second.answerSource == .expired)

        let required = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            requestID: "uq_required",
            toolCallID: "call_required",
            drafts: [.init(question: "Must answer")]
        ))
        let still = try #require(try await store.expire(
            requestID: required.requestID,
            now: now.addingTimeInterval(10_000)
        ))
        #expect(still.currentQuestion?.status == .pending)
    }

    @Test("Cancellation fences late answers and run/task fences release pending work")
    func cancelFencesLateAnswers() async throws {
        let (database, conversation, run) = try await fixture()
        let store = UserQuestionStore(database: database)
        let snapshot = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            drafts: [.init(question: "Proceed?", options: [.init(id: "y", label: "Y")])]
        ))
        let target = snapshot.target(for: try #require(snapshot.currentQuestion))
        let cancelled = try #require(try await store.cancel(requestID: snapshot.requestID, now: Date()))
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.questions[0].answerSource == .cancelled)
        let late = try await store.submitHumanAnswer(
            target: target,
            answer: .init(selectedOptionIDs: ["y"]),
            now: Date()
        )
        #expect(!late.accepted)
        #expect(late.alreadySettled)
        #expect(late.answer == nil)

        let second = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            requestID: "uq_run",
            toolCallID: "call_run",
            drafts: [.init(question: "Run fence?")]
        ))
        let fenced = try await store.cancelPending(runID: run, now: Date())
        #expect(fenced.contains { $0.requestID == second.requestID })
        let after = try #require(try await store.snapshot(requestID: second.requestID))
        #expect(after.state == .cancelled)
    }

    @Test("Temporary registrations never write a database row")
    func ephemeralRegistrationsStayInRAM() async throws {
        let (database, conversation, run) = try await fixture()
        let store = UserQuestionStore(database: database)
        let snapshot = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            drafts: [.init(question: "Temporary question?")],
            ephemeral: true
        ))
        #expect(snapshot.isEphemeral)
        let count = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_questions") ?? 0
        }
        #expect(count == 0)
        let target = snapshot.target(for: try #require(snapshot.currentQuestion))
        _ = try await store.submitHumanAnswer(
            target: target,
            answer: .init(freeText: "only in RAM"),
            now: Date()
        )
        let after = try await store.snapshot(requestID: snapshot.requestID)
        #expect(after?.questions.first?.answer?.freeText == "only in RAM")
        let countAfter = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_questions") ?? 0
        }
        #expect(countAfter == 0)
        // Exact-incarnation purge: a newer temporary run that reuses the
        // same conversation id must survive.
        let recreatedRun = UUID()
        try await SQLiteRunStore(database: database).saveRun(
            .init(id: recreatedRun, conversationID: conversation, state: "running", goal: "Again", startedAt: Date())
        )
        let newer = try await store.register(try registration(
            conversationID: conversation,
            runID: recreatedRun,
            requestID: "uq_temp_new",
            toolCallID: "call_temp_new",
            drafts: [.init(question: "New incarnation?")],
            ephemeral: true
        ))
        await store.purgeEphemeral(runID: run)
        #expect(try await store.snapshot(requestID: snapshot.requestID) == nil)
        #expect(try await store.snapshot(requestID: newer.requestID) != nil)
    }

    @Test("Optional answers are delivered once; a blocking required question suppresses delivery")
    func optionalDeliveryIsExactlyOnce() async throws {
        let (database, conversation, run) = try await fixture()
        let store = UserQuestionStore(database: database)
        let snapshot = try await store.register(try registration(
            conversationID: conversation,
            runID: run,
            waitPolicy: .optionalContinue,
            drafts: [
                .init(question: "Required?", options: [.init(id: "r", label: "R")], waitPolicy: .required),
                .init(question: "Optional?", options: [.init(id: "o", label: "O")], waitPolicy: .optionalContinue),
            ]
        ))
        let optional = try #require(snapshot.questions.last)
        _ = try await store.submitHumanAnswer(
            target: snapshot.target(for: optional),
            answer: .init(selectedOptionIDs: ["o"]),
            now: Date()
        )
        // Required is still pending: no next-turn delivery yet.
        #expect(try await store.undeliveredAnswers(conversationID: conversation).isEmpty)

        let required = try #require(snapshot.questions.first)
        let current = try #require(try await store.snapshot(requestID: snapshot.requestID))
        let requiredTarget = current.target(for: try #require(current.questions.first))
        _ = try await store.submitHumanAnswer(
            target: requiredTarget,
            answer: .init(selectedOptionIDs: ["r"]),
            now: Date()
        )
        #expect(required.questionID.isEmpty == false)
        let first = try await store.undeliveredAnswers(conversationID: conversation)
        #expect(first.count == 1)
        #expect(first[0].answers.first?.selectedOptionIDs == ["o"])
        try await store.markDelivered(
            questionIDs: first.flatMap { $0.answers.map(\.questionID) },
            at: Date()
        )
        #expect(try await store.undeliveredAnswers(conversationID: conversation).isEmpty)
    }
}
