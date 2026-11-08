import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeSecurity
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.UserQuestions")
struct UserQuestionTests {

    private func fixture() async throws -> (DatabaseManager, UUID, UUID, UserQuestionStore, UserQuestionCoordinator) {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversation = UUID()
        let run = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(
            .init(id: conversation, title: "Questions", createdAt: Date(), updatedAt: Date())
        )
        try await SQLiteRunStore(database: database).saveRun(
            .init(id: run, conversationID: conversation, state: "running", goal: "Ask", startedAt: Date())
        )
        let store = UserQuestionStore(database: database)
        let coordinator = UserQuestionCoordinator(store: store)
        return (database, conversation, run, store, coordinator)
    }

    private func waitForSnapshot(
        _ store: UserQuestionStore,
        requestID: String,
        timeout: TimeInterval = 2
    ) async throws -> UserQuestionWaitingSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let snapshot = try await store.snapshot(requestID: requestID) {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw UserQuestionError.notFound
    }

    private func request(
        _ drafts: [UserQuestionDraft],
        policy: UserQuestionWaitPolicy = .required,
        timeout: Int? = nil
    ) -> UserQuestionRequest {
        UserQuestionRequest(waitPolicy: policy, timeoutSeconds: timeout, questions: drafts)
    }

    @Test("Minimal old payloads decode with required policy and no timeout")
    func decodingDefaultsAreConservative() throws {
        let json = #"{"questions":[{"question":"Only question"}]}"#
        let request = try JSONDecoder().decode(UserQuestionRequest.self, from: Data(json.utf8))
        #expect(request.waitPolicy == .required)
        #expect(request.timeoutSeconds == nil)
        #expect(request.questions[0].selection == .single)
        #expect(request.questions[0].allowsFreeText == false)
        try request.validate()
    }

    @Test("A required custom answer reaches the model receipt and durable runtime recovery")
    func requiredCustomAnswerAndRecovery() async throws {
        let (database, conversation, run, store, coordinator) = try await fixture()
        let callID = "call_custom_required"
        let requestID = UserQuestionCoordinator.requestID(runID: run, toolCallID: callID)
        let waiting = Task {
            try await coordinator.ask(request([.init(question: "Which approach?", options: [.init(id: "a", label: "A")],
                allowsFreeText: false)]), runID: run, conversationID: conversation, toolCallID: callID,
                cancellation: CancellationToken(), temporaryReadOnly: false)
        }
        let snapshot = try await waitForSnapshot(store, requestID: requestID)
        let target = snapshot.target(for: try #require(snapshot.currentQuestion))
        _ = try await coordinator.submitHumanAnswer(target: target, answer: .init(customText: "My own approach"))
        let receipt = try await waiting.value
        #expect(receipt.status == .answered)
        #expect(receipt.answers[0].customText == "My own approach")
        #expect(receipt.answers[0].freeText == nil)
        #expect(receipt.answers[0].source == .human)
        let restored = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        let call = try ToolCall(id: callID, toolName: UserAskTool.name, argumentsJSON: Data("{}".utf8), scope: .local)
        let recovered = try #require(await restored.recoverInterruptedQuestion(runID: run, conversationID: conversation,
            call: call))
        let delivered = try JSONDecoder().decode(UserQuestionToolReceipt.self, from: Data(recovered.outputSummary.utf8))
        #expect(delivered.answers[0].customText == "My own approach")
        #expect(delivered.answers[0].selectedOptionIDs.isEmpty)
        #expect(delivered.humanAnsweredQuestionIDs == [target.questionID])
    }

    @Test("Optional custom and note content survives recovery until the exact delivery is acknowledged")
    func optionalCustomDeliveryRecovery() async throws {
        let (database, conversation, run, store, coordinator) = try await fixture()
        let callID = "call_custom_optional"
        _ = try await coordinator.ask(request([.init(question: "Which options?", options: [.init(id: "a", label: "A")],
            selection: .multiple, allowsFreeText: true)], policy: .optionalContinue), runID: run,
            conversationID: conversation, toolCallID: callID, cancellation: CancellationToken(), temporaryReadOnly: false)
        let snapshot = try await waitForSnapshot(store, requestID: UserQuestionCoordinator.requestID(runID: run, toolCallID: callID))
        let target = snapshot.target(for: try #require(snapshot.currentQuestion))
        _ = try await coordinator.submitHumanAnswer(target: target,
            answer: .init(selectedOptionIDs: ["a"], freeText: "A note", customText: "My option"))
        let first = try #require(try await coordinator.pendingDeliveries(conversationID: conversation).first)
        let restored = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        let replay = try #require(try await restored.pendingDeliveries(conversationID: conversation).first)
        #expect(replay.id == first.id)
        #expect(replay.answers[0].customText == "My option")
        #expect(replay.answers[0].freeText == "A note")
        #expect(replay.answers[0].selectedOptionIDs == ["a"])
        #expect(replay.text.contains("custom answer: My option"))
        #expect(replay.text.contains("note: A note"))
        try await restored.acknowledgeDeliveries(questionIDs: replay.answers.map(\.questionID))
        #expect(try await coordinator.pendingDeliveries(conversationID: conversation).isEmpty)
    }

    @Test("Spoken custom replies and validation keep note policy, cancellation and text questions distinct")
    func spokenCustomValidationAndCancellation() async throws {
        let (_, conversation, run, store, coordinator) = try await fixture()
        let callID = "call_custom_cancel"
        _ = try await coordinator.ask(request([.init(question: "Which?", options: [.init(id: "a", label: "A")],
            allowsFreeText: false)], policy: .optionalContinue), runID: run, conversationID: conversation,
            toolCallID: callID, cancellation: CancellationToken(), temporaryReadOnly: false)
        let snapshot = try await waitForSnapshot(store, requestID: UserQuestionCoordinator.requestID(runID: run, toolCallID: callID))
        let question = try #require(snapshot.currentQuestion), target = snapshot.target(for: question)
        #expect(UserQuestionAnswer.spokenText("a", for: question)?.selectedOptionIDs == ["a"])
        #expect(UserQuestionAnswer.spokenText("My alternative", for: question)?.customText == "My alternative")
        #expect(throws: (any Error).self) { try UserQuestionAnswer(freeText: "A note").validated(for: question, partial: false) }
        #expect(throws: (any Error).self) {
            try UserQuestionAnswer(selectedOptionIDs: ["a"], customText: "Other").validated(for: question, partial: true)
        }
        try await coordinator.cancelRequest(requestID: snapshot.requestID)
        let late = try await coordinator.submitHumanAnswer(target: target, answer: .init(customText: "Late answer"))
        #expect(!late.accepted)
        #expect(late.alreadySettled)
        #expect(late.answer == nil)
        #expect(late.status == .cancelled)
    }

    @Test("Custom and note credentials reach only the primary request and never its durable checkpoints")
    func customAndNoteCredentialWireProjection() async throws {
        let questionID = "uq_custom_wire.q1"
        let noteSecret = CapturedSecret(label: "synthetic-note", value: Data("QUESTION_NOTE_SYNTHETIC_42".utf8))
        let customSecret = CapturedSecret(label: "synthetic-custom", value: Data("QUESTION_CUSTOM_SYNTHETIC_43".utf8))
        let projection = ModelUserInputProjection()
        try projection.register(id: ModelUserInputProjection.questionSourceID(questionID),
            safe: noteSecret.placeholder, live: "QUESTION_NOTE_SYNTHETIC_42", captures: [noteSecret])
        try projection.register(id: ModelUserInputProjection.questionSourceID("custom-answer:" + questionID),
            safe: customSecret.placeholder, live: "QUESTION_CUSTOM_SYNTHETIC_43", captures: [customSecret])
        let record = UserQuestionAnswerRecord(questionID: questionID, question: "Which credential?",
            selectedOptionIDs: [], selectedOptionLabels: [], freeText: noteSecret.placeholder,
            customText: customSecret.placeholder, source: .human, answeredAt: Date())
        let receipt = UserQuestionToolReceipt(requestID: "uq_custom_wire", status: .answered, answers: [record],
            pendingQuestionIDs: [], expiredQuestionIDs: [], cancelledQuestionIDs: [],
            humanAnsweredQuestionIDs: [questionID], defaultedQuestionIDs: [], message: "Answered")
        let executor = MockExecutor()
        executor.descriptors[UserAskTool.name] = .init(name: UserAskTool.name,
            parametersJSON: UserAskTool.parametersJSON, riskLabels: [], isSideEffecting: false,
            executionBoundary: .mainRunOnly)
        executor.results = [.init(callID: "custom-wire-call", status: .ok,
            outputSummary: String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self),
            outputDigest: "safe", maximumSummaryCharacters: 262_144)]
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "custom-wire-call", toolName: UserAskTool.name,
                arguments: #"{"questions":[{"question":"Which?","options":[{"id":"a","label":"A"}]}]}"#)),
             .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let provider = TestFixtures.localhostProvider(), checkpoints = MockCheckpointStore()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), verifyFinalAnswer: false),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: executor,
            checkpointStore: checkpoints, modelInputProjection: projection)
        try await runtime.start(goal: "Synthetic question projection")
        #expect(adapter.requests.count == 2)
        let wire = try #require(adapter.requests.last).toolResults
        #expect(wire.contains { $0.output.contains("QUESTION_CUSTOM_SYNTHETIC_43") })
        #expect(wire.contains { $0.output.contains("QUESTION_NOTE_SYNTHETIC_42") })
        for checkpoint in checkpoints.saved {
            let saved = String(decoding: try checkpoint.encoded(), as: UTF8.self)
            #expect(!saved.contains("QUESTION_CUSTOM_SYNTHETIC_43"))
            #expect(!saved.contains("QUESTION_NOTE_SYNTHETIC_42"))
        }
    }

    @Test("A required wait has no silent timeout or model default")
    func requiredCannotDeclareTimeoutOrFallback() throws {
        #expect(throws: (any Error).self) {
            try UserQuestionRequest(
                waitPolicy: .required,
                timeoutSeconds: 30,
                questions: [.init(question: "Proceed?")]
            ).validate()
        }
        #expect(throws: (any Error).self) {
            try UserQuestionRequest(
                waitPolicy: .required,
                questions: [.init(
                    question: "Proceed?",
                    options: [.init(id: "y", label: "Yes")],
                    fallback: .init(selectedOptionIDs: ["y"])
                )]
            ).validate()
        }
        #expect(throws: (any Error).self) {
            try UserQuestionRequest(
                waitPolicy: .optionalDeadline,
                questions: [.init(question: "No interval?")]
            ).validate()
        }
    }

    @Test("Required ask parks until a human answer and returns the real receipt")
    func requiredWaitsForHumanAnswer() async throws {
        let (database, conversation, run, store, coordinator) = try await fixture()
        let requestID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "call_required")
        let task = Task {
            try await coordinator.ask(
                request([.init(question: "Which environment?", options: [
                    .init(id: "dev", label: "Development"),
                    .init(id: "prod", label: "Production"),
                ])]),
                runID: run,
                conversationID: conversation,
                toolCallID: "call_required",
                cancellation: CancellationToken(),
                temporaryReadOnly: false
            )
        }
        let pending = try await waitForSnapshot(store, requestID: requestID)
        let question = try #require(pending.currentQuestion)
        #expect(pending.state == .awaitingAnswer)
        _ = try await coordinator.submitHumanAnswer(
            target: pending.target(for: question),
            answer: .init(selectedOptionIDs: ["dev"])
        )
        let receipt = try await task.value
        #expect(receipt.status == .answered)
        #expect(receipt.humanAnsweredQuestionIDs == [question.questionID])
        #expect(receipt.answers.first?.selectedOptionLabels == ["Development"])
        let count = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_questions") ?? 0
        }
        #expect(count == 1)
    }

    @Test("optionalContinue returns a pending receipt and delivers its answer once")
    func optionalContinueReturnsAndDeliversLater() async throws {
        let (_, conversation, run, store, coordinator) = try await fixture()
        let receipt = try await coordinator.ask(
            request(
                [.init(question: "Preferred name?", waitPolicy: .optionalContinue)],
                policy: .optionalContinue
            ),
            runID: run,
            conversationID: conversation,
            toolCallID: "call_optional",
            cancellation: CancellationToken(),
            temporaryReadOnly: false
        )
        #expect(receipt.status == .pending)
        #expect(receipt.pendingQuestionIDs.count == 1)
        let requestID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "call_optional")
        let snapshot = try await waitForSnapshot(store, requestID: requestID)
        let question = try #require(snapshot.currentQuestion)
        _ = try await coordinator.submitHumanAnswer(
            target: snapshot.target(for: question),
            answer: .init(freeText: "Ash")
        )
        let deliveries = try await coordinator.pendingDeliveries(conversationID: conversation)
        #expect(deliveries.count == 1)
        #expect(deliveries[0].answers.first?.freeText == "Ash")
        #expect(deliveries[0].text.contains("Ash"))
        #expect(deliveries[0].text.contains("answer"))
        // Peeking is read-only: a process death before the durable queue
        // commit cannot lose the answer.
        let peekingAgain = try await coordinator.pendingDeliveries(conversationID: conversation)
        #expect(peekingAgain.first?.id == deliveries.first?.id)
        try await coordinator.acknowledgeDeliveries(
            questionIDs: deliveries.flatMap { $0.answers.map(\.questionID) }
        )
        #expect(try await coordinator.pendingDeliveries(conversationID: conversation).isEmpty)
    }

    @Test("Mixed policy blocks only required work, then leaves optional pending")
    func mixedPolicyOnlyBlocksRequired() async throws {
        let (_, conversation, run, store, coordinator) = try await fixture()
        let requestID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "call_mixed")
        let task = Task {
            try await coordinator.ask(
                request([
                    .init(question: "Required", options: [.init(id: "r", label: "R")], waitPolicy: .required),
                    .init(question: "Optional", options: [.init(id: "o", label: "O")], waitPolicy: .optionalContinue),
                ]),
                runID: run,
                conversationID: conversation,
                toolCallID: "call_mixed",
                cancellation: CancellationToken(),
                temporaryReadOnly: false
            )
        }
        let pending = try await waitForSnapshot(store, requestID: requestID)
        let required = try #require(pending.questions.first)
        _ = try await coordinator.submitHumanAnswer(
            target: pending.target(for: required),
            answer: .init(selectedOptionIDs: ["r"])
        )
        let receipt = try await task.value
        #expect(receipt.status == .pending)
        #expect(receipt.pendingQuestionIDs == [pending.questions[1].questionID])
        #expect(receipt.humanAnsweredQuestionIDs == [required.questionID])
    }

    @Test("Cancel resolves a required wait with cancelled provenance, not an answer")
    func cancelResolvesWaitingTool() async throws {
        let (_, conversation, run, store, coordinator) = try await fixture()
        let requestID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "call_cancel")
        let task = Task {
            try await coordinator.ask(
                request([.init(question: "Cancel me?")]),
                runID: run,
                conversationID: conversation,
                toolCallID: "call_cancel",
                cancellation: CancellationToken(),
                temporaryReadOnly: false
            )
        }
        _ = try await waitForSnapshot(store, requestID: requestID)
        try await coordinator.cancelRequest(requestID: requestID)
        let receipt = try await task.value
        #expect(receipt.status == .cancelled)
        #expect(receipt.answers.isEmpty)
        #expect(receipt.cancelledQuestionIDs.count == 1)
        let snapshot = try #require(try await store.snapshot(requestID: requestID))
        #expect(snapshot.questions[0].answerSource == .cancelled)
    }

    @Test("Duplicate and stale answers cannot settle a second time")
    func duplicateAnswerIsIdempotent() async throws {
        let (_, conversation, run, store, coordinator) = try await fixture()
        let requestID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "call_dupe")
        let task = Task {
            try await coordinator.ask(
                request([.init(question: "Once?", options: [.init(id: "a", label: "A")])]),
                runID: run,
                conversationID: conversation,
                toolCallID: "call_dupe",
                cancellation: CancellationToken(),
                temporaryReadOnly: false
            )
        }
        let pending = try await waitForSnapshot(store, requestID: requestID)
        let target = pending.target(for: try #require(pending.currentQuestion))
        let first = try await coordinator.submitHumanAnswer(target: target, answer: .init(selectedOptionIDs: ["a"]))
        #expect(first.accepted)
        let second = try await coordinator.submitHumanAnswer(target: target, answer: .init(selectedOptionIDs: []))
        #expect(!second.accepted)
        #expect(second.alreadySettled)
        #expect(second.answer?.selectedOptionIDs == ["a"])
        _ = try await task.value
    }

    @Test("A notification answer cannot target another conversation or run")
    func notificationAnswerIsBound() async throws {
        let (_, conversation, run, store, coordinator) = try await fixture()
        let receipt = try await coordinator.ask(
            request([.init(question: "Temporary?", waitPolicy: .optionalContinue)], policy: .optionalContinue),
            runID: run,
            conversationID: conversation,
            toolCallID: "call_bound",
            cancellation: CancellationToken(),
            temporaryReadOnly: false
        )
        let requestID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "call_bound")
        let snapshot = try await waitForSnapshot(store, requestID: requestID)
        let question = try #require(snapshot.currentQuestion)
        await #expect(throws: (any Error).self) {
            try await coordinator.submitNotificationAnswer(
                requestID: requestID,
                questionID: question.questionID,
                conversationID: UUID(),
                runID: run,
                expectedRevision: question.revision,
                answer: .init(freeText: "spoof")
            )
        }
        await #expect(throws: (any Error).self) {
            try await coordinator.submitNotificationAnswer(
                requestID: requestID,
                questionID: question.questionID,
                conversationID: conversation,
                runID: UUID(),
                expectedRevision: question.revision,
                answer: .init(freeText: "spoof")
            )
        }
        #expect(receipt.pendingQuestionIDs.count == 1)
    }

    @Test("Restart recovery reconstructs the durable answer, not an unknown outcome")
    func restartRecoveryUsesDurableAnswer() async throws {
        let (database, conversation, run, store, coordinator) = try await fixture()
        let requestID = UserQuestionCoordinator.requestID(runID: run, toolCallID: "call_recover")
        let task = Task {
            try await coordinator.ask(
                request([.init(question: "Recoverable?", options: [.init(id: "yes", label: "Yes")])]),
                runID: run,
                conversationID: conversation,
                toolCallID: "call_recover",
                cancellation: CancellationToken(),
                temporaryReadOnly: false
            )
        }
        let pending = try await waitForSnapshot(store, requestID: requestID)
        _ = try await coordinator.submitHumanAnswer(
            target: pending.target(for: try #require(pending.currentQuestion)),
            answer: .init(selectedOptionIDs: ["yes"])
        )
        _ = try await task.value

        // A new process: same durable store, a fresh coordinator.
        let recoveredCoordinator = UserQuestionCoordinator(store: UserQuestionStore(database: database))
        let call = try ToolCall(
            id: "call_recover",
            toolName: UserAskTool.name,
            argumentsJSON: Data("{}".utf8),
            scope: .local
        )
        let recovered = await recoveredCoordinator.recoverInterruptedQuestion(
            runID: run,
            conversationID: conversation,
            call: call
        )
        let result = try #require(recovered)
        #expect(result.status == .ok)
        #expect(result.outputSummary.contains("Recoverable?"))
        #expect(result.outputSummary.contains("Yes"))
        #expect(result.outputSummary.contains("human"))
    }

    @Test("Temporary ask never writes question rows")
    func temporaryAskStaysInRAM() async throws {
        let (database, conversation, run, _, coordinator) = try await fixture()
        let receipt = try await coordinator.ask(
            request([.init(question: "Temporary?", waitPolicy: .optionalContinue)], policy: .optionalContinue),
            runID: run,
            conversationID: conversation,
            toolCallID: "call_temp",
            cancellation: CancellationToken(),
            temporaryReadOnly: true
        )
        #expect(receipt.status == .pending)
        let count = try await database.reader { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM user_questions") ?? 0
        }
        #expect(count == 0)
        let snapshots = try await coordinator.snapshots(conversationID: conversation, includeSettled: true)
        #expect(snapshots.count == 1)
        #expect(snapshots[0].isEphemeral)
    }

    @Test("Typed waiting state carries identifiers and blocking/deadline metadata only")
    func waitingStateCarriesOnlyIdentifiers() throws {
        let conversation = UUID(), run = UUID(), now = Date()
        let request = UserQuestionRequest(
            waitPolicy: .optionalDeadline,
            timeoutSeconds: 30,
            questions: [.init(question: "Question text", options: [.init(id: "a", label: "A")], fallback: .init(selectedOptionIDs: ["a"]))]
        )
        try request.validate()
        let questions = try request.makeQuestions(
            requestID: "uq_wait", conversationID: conversation, runID: run,
            toolCallID: "call_wait", createdAt: now
        )
        let snapshot = UserQuestionWaitingSnapshot(
            requestID: "uq_wait", requestDigest: "digest",
            conversationID: conversation, runID: run, toolCallID: "call_wait",
            waitPolicy: .optionalDeadline, state: .awaitingAnswer,
            questions: questions, createdAt: now, updatedAt: now, isEphemeral: false
        )
        let waiting = AgentState.WaitingUserQuestion(snapshot: snapshot)
        #expect(waiting.requestID == "uq_wait")
        #expect(waiting.pendingQuestionIDs == ["uq_wait.q1"])
        #expect(waiting.blockingQuestionIDs == ["uq_wait.q1"])
        #expect(waiting.deadlineAt != nil)
        #expect(waiting.isEphemeral == false)
        #expect(AgentState.waitingUserQuestion(waiting).name == "waitingUserQuestion")
        // The payload stores identifiers/timing, not question text or answers.
        let encoded = try JSONEncoder().encode(waiting)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("Question text"))
    }

    @Test("Progressive discovery finds user.ask from an ordinary clarifying-question intent")
    func progressiveDiscoveryFindsQuestionTool() throws {
        ToolCatalog.register(UserAskTool.self)
        let descriptor = try #require(ToolCatalog.descriptor(named: UserAskTool.name))
        #expect(descriptor.name == "user.ask")
        #expect(!descriptor.toolDescription.isEmpty)
        for query in [
            "ask the user a clarifying question",
            "need to ask a person which option they prefer",
            "request missing information from the user",
        ] {
            let matches = ToolDiscovery.matches(queries: [query], descriptors: [descriptor])
            #expect(matches.contains { $0.name == UserAskTool.name }, Comment(rawValue: query))
        }
        // It remains main-run only; a delegated child never discovers it.
        #expect(descriptor.executionBoundary == .mainRunOnly)
    }

    @Test("The catalog preserves the complete typed question schema")
    func completeQuestionSchemaSurvivesCatalogAdmission() throws {
        let descriptor = ToolCatalog.Descriptor(name: UserAskTool.name,
            parametersJSON: UserAskTool.parametersJSON, riskLabels: [], isSideEffecting: false)
        #expect(descriptor.parametersJSON == UserAskTool.parametersJSON)
        let raw = try JSONSerialization.jsonObject(with: Data(descriptor.parametersJSON.utf8))
        let root = try #require(raw as? [String: Any])
        #expect(root["required"] as? [String] == ["questions"])
        let properties = try #require(root["properties"] as? [String: Any])
        let questions = try #require(properties["questions"] as? [String: Any])
        let item = try #require(questions["items"] as? [String: Any])
        #expect(item["required"] as? [String] == ["question"])
        #expect(questions["maxItems"] as? Int == 3)
    }

    @Test("Tool metadata is a main-run-only local interaction, never an approval")
    func toolMetadataIsNarrow() throws {
        #expect(UserAskTool.name == "user.ask")
        #expect(UserAskTool.isSideEffecting == false)
        #expect(UserAskTool.toolEffect == .internalState)
        #expect(UserAskTool.riskLabels.isEmpty)
        #expect(UserAskTool.executionBoundary == .mainRunOnly)
        #expect(UserAskTool.parametersJSON.contains("\"questions\""))
        #expect(UserAskTool.parametersJSON.contains("\"required\""))
    }
}
