import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloePersistence
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("Selected primary user input")
struct ModelUserInputProjectionTests {
    @Test func closedOwnerGivesContinuationANewProjectionWithoutReopeningLateCallbacks() throws {
        let old = ModelUserInputProjection()
        let secret = CapturedSecret(label: "synthetic", value: Data("QUESTION_SECRET_42".utf8))
        try old.register(id: UUID(), safe: secret.placeholder, live: "QUESTION_SECRET_42", captures: [secret])
        #expect(old.successorIfClosed() == nil)
        old.close()
        let next = try #require(old.successorIfClosed())
        #expect(throws: (any Error).self) {
            try old.register(id: UUID(), safe: "My own answer", live: "My own answer")
        }
        try next.register(id: UUID(), safe: "My own answer", live: "My own answer")
        #expect(next.redacted("QUESTION_SECRET_42") == secret.placeholder)
        old.clear()
        #expect(next.redacted("QUESTION_SECRET_42") == secret.placeholder)
    }

    @Test func nativeSourceIdentityAndShortSecretRedaction() throws {
        let projection = ModelUserInputProjection()
        let id = UUID()
        let secret = CapturedSecret(label: "synthetic", value: Data("7".utf8))
        try projection.register(id: id, safe: secret.placeholder, live: "7", captures: [secret])
        #expect(projection.liveText(for: .init(id: id, text: secret.placeholder)) == "7")
        #expect(projection.liveText(for: .init(id: UUID(), text: secret.placeholder)) == secret.placeholder)
        #expect(projection.liveText(for: .init(id: id, text: "different")) == "different")
        #expect(projection.redacted(secret.placeholder) == secret.placeholder)
        #expect(projection.redacted("command --password=7") == "command --password=" + secret.placeholder)
        let input = Data(#"{"id":"native-7","command":"echo 7"}"#.utf8)
        let json = try #require(try JSONSerialization.jsonObject(with: projection.redactedJSON(input, preservingNativeIdentity: true)) as? [String: String])
        #expect(json["id"] == "native-7")
        #expect(json["command"] == "echo " + secret.placeholder)
        let unchanged = Data(#"{ "command" : "echo ordinary" }"#.utf8)
        #expect(projection.redactedJSON(unchanged) == unchanged)
        projection.close()
        #expect(projection.liveText(for: .init(id: id, text: secret.placeholder)) == secret.placeholder)
        #expect(projection.redacted("7") == secret.placeholder) // late durable writer remains protected
        projection.clear()
        #expect(throws: (any Error).self) { try projection.register(id: UUID(), safe: "x", live: "x") }
    }

    @Test func primaryGetsPlaintextWhileCheckpointAndOtherRuntimeStaySafe() async throws {
        let sourceID = UUID()
        let secret = CapturedSecret(label: "synthetic", value: Data("MODEL_INPUT_SYNTHETIC_2048".utf8))
        let safe = "API key: " + secret.placeholder
        let live = "API key: MODEL_INPUT_SYNTHETIC_2048"
        let projection = ModelUserInputProjection()
        try projection.register(id: sourceID, safe: safe, live: live, captures: [secret])
        let provider = TestFixtures.localhostProvider()
        let model = TestFixtures.testModel(providerID: provider.id)
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "Saved MODEL_INPUT_SYNTHETIC_2048")), .completed(.init(stopReason: .endTurn))]]
        let checkpoints = MockCheckpointStore()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider, model: model, verifyFinalAnswer: false),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: MockExecutor(), checkpointStore: checkpoints,
            modelInputProjection: projection)
        try await runtime.start(goal: safe, userMessageID: sourceID)
        let request = try #require(adapter.requests.first)
        #expect(request.effectiveMessages.contains { message in message.content.contains { part in
            if case .text(let text) = part { return text.contains("MODEL_INPUT_SYNTHETIC_2048") }; return false
        } })
        for checkpoint in checkpoints.saved {
            #expect(!String(decoding: try checkpoint.encoded(), as: UTF8.self).contains("MODEL_INPUT_SYNTHETIC_2048"))
        }
        let dispatch = try #require(checkpoints.saved.first { $0.providerDispatchRequest != nil })
        #expect(dispatch.providerDispatchRequest?.modelInputProjection == "selected-primary-user-input")
        #expect(dispatch.providerDispatchEnvelope?.modelInputProjection == "selected-primary-user-input")

        // Recovery owns a new RAM projection. The native hydrator uses the
        // saved reference, not another user question or a shared adapter.
        let recovered = ModelUserInputProjection()
        let second = MockAdapter()
        second.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let resumed = FloeAgentRuntime(configuration: .init(provider: provider, model: model, verifyFinalAnswer: false),
            adapter: second, policy: HumanApprovalPolicy(), executor: MockExecutor(), checkpointStore: MockCheckpointStore(),
            modelInputProjection: recovered, hydrateModelInputs: { sources in
                for source in sources {
                    try recovered.register(source: source, values: [secret.id: "MODEL_INPUT_SYNTHETIC_2048"])
                }
            })
        try await resumed.resume(from: dispatch)
        #expect(second.requests.first?.effectiveMessages.contains { message in message.content.contains { part in
            if case .text(let text) = part { return text == live }; return false
        } } == true)

        let ordinary = MockAdapter()
        ordinary.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let other = FloeAgentRuntime(configuration: .init(provider: provider, model: model, verifyFinalAnswer: false),
            adapter: ordinary, policy: HumanApprovalPolicy(), executor: MockExecutor())
        try await other.start(goal: safe)
        #expect(ordinary.requests.first?.effectiveMessages.contains { message in message.content.contains { part in
            if case .text(let text) = part { return text.contains("MODEL_INPUT_SYNTHETIC_2048") }; return false
        } } == false)
    }

    @Test func oldQuestionsRemainOrdinaryAndKnownCredentialMetadataSurvivesJSON() throws {
        let old = try JSONDecoder().decode(UserQuestionRequest.self, from: Data(#"{"questions":[{"question":"Name?"}]}"#.utf8))
        #expect(old.questions[0].answerSensitivity == .ordinary)
        let request = UserQuestionRequest(questions: [.init(question: "Password?", answerSensitivity: .credential, allowsFreeText: true)])
        let questions = try request.makeQuestions(requestID: "test", conversationID: UUID(), runID: UUID(), toolCallID: "test", createdAt: Date())
        let roundTrip = try JSONDecoder().decode(UserQuestion.self, from: JSONEncoder().encode(questions[0]))
        #expect(roundTrip.answerSensitivity == .credential)
    }

    @Test func knownPlaintextCannotEnterProcessOrDelegatedArguments() async throws {
        let secret = CapturedSecret(label: "synthetic", value: Data("SYNTHETIC_COMMAND_SECRET_42".utf8))
        let source = UUID(), projection = ModelUserInputProjection()
        try projection.register(id: source, safe: secret.placeholder, live: "SYNTHETIC_COMMAND_SECRET_42", captures: [secret])
        let executor = MockExecutor()
        executor.descriptors["exec.shell"] = .init(name: "exec.shell", riskLabels: [], isSideEffecting: false)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "unsafe", toolName: "exec.shell",
                arguments: #"{"command":"echo SYNTHETIC_COMMAND_SECRET_42"}"#)), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "Use a credential binding")), .completed(.init(stopReason: .endTurn))]
        ]
        let provider = TestFixtures.localhostProvider(), checkpoints = MockCheckpointStore()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), verifyFinalAnswer: false),
            adapter: adapter, policy: HumanApprovalPolicy(), executor: executor,
            checkpointStore: checkpoints, modelInputProjection: projection)
        try await runtime.start(goal: secret.placeholder, userMessageID: source)
        #expect(executor.executedCalls.isEmpty)
        for checkpoint in checkpoints.saved {
            #expect(!String(decoding: try checkpoint.encoded(), as: UTF8.self).contains("SYNTHETIC_COMMAND_SECRET_42"))
        }
    }

    @Test func boundedRAMRejectsOversizedDisclosure() {
        let projection = ModelUserInputProjection()
        #expect(throws: (any Error).self) {
            try projection.register(id: UUID(), safe: "bounded", live: String(repeating: "x", count: 1_048_577))
        }
    }
}

@Suite("Question credential ingress")
struct QuestionCredentialIngressTests {
    @Test(arguments: [UserQuestionWaitPolicy.required, .optionalContinue])
    func shortCredentialUsesNativeSensitivityAndBothReceiptsStaySafe(policy: UserQuestionWaitPolicy) async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversation = UUID(), run = UUID()
        try await SQLiteConversationStore(database: database).saveConversation(
            .init(id: conversation, title: "Synthetic setup", createdAt: Date(), updatedAt: Date()))
        try await SQLiteRunStore(database: database).saveRun(
            .init(id: run, conversationID: conversation, state: "running", goal: "Synthetic setup", startedAt: Date()))
        let store = UserQuestionStore(database: database)
        let request = UserQuestionRequest(waitPolicy: policy,
            questions: [.init(question: "Password?", answerSensitivity: .credential, allowsFreeText: true)])
        let requestID = "native-question-" + UUID().uuidString
        let questions = try request.makeQuestions(requestID: requestID, conversationID: conversation,
            runID: run, toolCallID: "question-call", createdAt: Date())
        let registered = try await store.register(.init(requestID: requestID, requestDigest: "synthetic-digest",
            conversationID: conversation, runID: run, toolCallID: "question-call", waitPolicy: policy,
            questions: questions, createdAt: Date(), isEphemeral: false))
        let capture = CapturedSecret(label: "synthetic", value: Data("7".utf8))
        let projection = ModelUserInputProjection()
        let coordinator = UserQuestionCoordinator(store: store, answerNormalizer: { answer, question, _ in
            guard question.answerSensitivity == .credential, let text = answer.freeText else { return answer }
            try projection.register(id: ModelUserInputProjection.questionSourceID(question.questionID),
                safe: capture.placeholder, live: text, captures: [capture])
            var safe = answer; safe.freeText = capture.placeholder; return safe
        })
        let target = registered.target(for: try #require(registered.currentQuestion))
        let settled = try await coordinator.submitHumanAnswer(target: target, answer: .init(freeText: "7"))
        #expect(settled.accepted)
        let snapshot = try #require(try await store.snapshot(requestID: requestID))
        #expect(snapshot.questions.first?.answer?.freeText == capture.placeholder)
        let receipt = UserQuestionFormatting.toolReceipt(for: snapshot)
        #expect(receipt.answers.first?.freeText == capture.placeholder)
        #expect(projection.liveText(for: .init(id: ModelUserInputProjection.questionSourceID(questions[0].questionID),
            text: capture.placeholder)) == "7")
        if policy == .required {
            let executor = MockExecutor()
            executor.descriptors[UserAskTool.name] = .init(name: UserAskTool.name,
                parametersJSON: UserAskTool.parametersJSON, riskLabels: [], isSideEffecting: false,
                executionBoundary: .mainRunOnly)
            executor.results = [.init(callID: "question-call", status: .ok,
                outputSummary: String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self), outputDigest: "safe",
                maximumSummaryCharacters: 262_144)]
            let adapter = MockAdapter()
            adapter.script = [
                [.toolRequest(try TestFixtures.toolCall(id: "question-call", toolName: UserAskTool.name,
                    arguments: #"{"questions":[{"question":"Password?","answerSensitivity":"credential"}]}"#)),
                 .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
            ]
            let provider = TestFixtures.localhostProvider(), checkpoints = MockCheckpointStore()
            let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
                model: TestFixtures.testModel(providerID: provider.id), verifyFinalAnswer: false),
                adapter: adapter, policy: HumanApprovalPolicy(), executor: executor,
                checkpointStore: checkpoints, modelInputProjection: projection)
            try await runtime.start(goal: "Synthetic setup")
            #expect(adapter.requests.count == 2)
            #expect(adapter.requests[1].toolResults.contains { $0.output.contains("\"freeText\":\"7\"") })
            for checkpoint in checkpoints.saved {
                #expect(!String(decoding: try checkpoint.encoded(), as: UTF8.self).contains("\"freeText\":\"7\""))
            }
        }
        if policy == .optionalContinue {
            let deliveries = try await coordinator.pendingDeliveries(conversationID: conversation)
            #expect(deliveries.first?.text.contains(capture.placeholder) == true)
        }
    }
}

@Suite("Main runtime live catalog subset")
struct CurrentToolAvailabilityTests {
    @Test func installationMidRunNarrowsLiveCatalogWithoutChangingFrozenCeiling() async throws {
        let ready = AsyncLock(false)
        let executor = MockExecutor()
        for name in ["test.install", "test.optional", "test.foreign"] {
            executor.descriptors[name] = ToolCatalog.Descriptor(name: name, toolDescription: name,
                parametersJSON: #"{"type":"object","properties":{}}"#, riskLabels: [], isSideEffecting: false)
        }
        executor.executionGate = { ready.withLock { $0 = true } }
        let adapter = MockAdapter()
        let install = try TestFixtures.toolCall(id: "install", toolName: "test.install", arguments: "{}")
        let list = try TestFixtures.toolCall(id: "list", toolName: ToolDiscovery.listName, arguments: "{}")
        adapter.script = [
            [.toolRequest(install), .completed(.init(stopReason: .toolUse))],
            [.toolRequest(list), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            allowedToolNames: ["test.install", "test.optional"],
            currentToolAvailability: {
                ready.withLock { $0 ? ["test.install", "test.optional", "test.foreign"] : ["test.install"] }
            }), adapter: adapter, policy: HumanApprovalPolicy(), executor: executor)
        try await runtime.start(goal: "Use test.install and discover the optional tool")
        #expect(adapter.requests.count == 3)
        #expect(adapter.requests[0].allToolNames.contains("test.optional") == false)
        #expect(adapter.requests[1].allToolNames.contains("test.optional"))
        #expect(adapter.requests.allSatisfy { !$0.allToolNames.contains("test.foreign") })
        #expect(adapter.requests[2].toolResults.contains { $0.output.contains("test.optional") })
    }
}
