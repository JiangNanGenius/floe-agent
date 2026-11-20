// SPDX-License-Identifier: MPL-2.0
//
// User-question integration tests for the Mac self-owned runtime. Every
// case passes allowsUserQuestions explicitly (the default stays false for
// headless callers). The synthetic provider is a test double; the durable
// store, coordinator, session fencing and real run lifecycle are the
// production composition.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
@testable import FloeMacSelfCore

private actor QuestionEventRecorder {
    private var storage: [UserQuestionEvent] = []

    func record(_ event: UserQuestionEvent) {
        storage.append(event)
    }

    func presentedCount(requestID: String) -> Int {
        storage.filter { event in
            if case .presented(let snapshot) = event { return snapshot.requestID == requestID }
            return false
        }.count
    }

    func latestPresented(conversationID: UUID) -> UserQuestionWaitingSnapshot? {
        storage.reversed().compactMap { event in
            if case .presented(let snapshot) = event, snapshot.conversationID == conversationID {
                return snapshot
            }
            return nil
        }.first
    }
}

@Suite("Mac self-owned runtime user questions")
struct QuestionToolIntegrationTests {

    private func questionRequest(waitPolicy: UserQuestionWaitPolicy = .required) throws -> Data {
        let request = UserQuestionRequest(
            waitPolicy: waitPolicy,
            questions: [UserQuestionDraft(
                id: "format",
                question: "Which output format do you want?",
                options: [
                    UserQuestionOption(id: "report", label: "Report"),
                    UserQuestionOption(id: "table", label: "Table"),
                ]
            )]
        )
        return try JSONEncoder().encode(request)
    }

    private func questionCall(waitPolicy: UserQuestionWaitPolicy = .required,
                              id: String = "call-question-1") throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: UserAskTool.name,
            argumentsJSON: questionRequest(waitPolicy: waitPolicy),
            scope: .local
        )
    }

    private func chatRequest(_ fixture: SelfCoreFixture, goal: String,
                             workspaceID: UUID, mode: ConversationMode = .chat) -> FloeMacSelfSessionRequest {
        FloeMacSelfSessionRequest(
            workspaceID: workspaceID,
            conversationTitle: "Question fixture",
            goal: goal,
            mode: mode,
            context: FloeMacSelfRunContext(workspaceName: "Fixture"),
            chatFastMode: false,
            allowsUserQuestions: true
        )
    }

    @Test("A model question reaches UI-shaped state and one human answer reaches the same run exactly once")
    func askPresentsCardAndSingleAnswerReachesRun() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Question workspace")
            let call = try questionCall()
            let (provider, adapter) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "Report it is.")), .completed(.init(stopReason: .endTurn))],
            ])
            let (tools, executor, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let request = chatRequest(fixture, goal: "Ask which format to use", workspaceID: workspaceID)
            let handle = try await fixture.runtime.startSession(request, provider: provider, tools: tools)

            // 1. The question reaches UI-shaped state: the durable center
            // presents the snapshot for this exact run/conversation.
            let center = try await fixture.runtime.userQuestionCenter()
            let presented = await eventually {
                let snapshot = try? await center.pendingSnapshot(runID: handle.identity.runID)
                return snapshot?.currentQuestion != nil
            }
            #expect(presented)
            let snapshot = try #require(await center.pendingSnapshot(runID: handle.identity.runID))
            #expect(snapshot.conversationID == handle.identity.conversationID)
            #expect(snapshot.toolCallID == call.id)
            let question = try #require(snapshot.currentQuestion)
            #expect(question.options.map(\.id) == ["report", "table"])

            // 2. Owner/run/call identity fencing before any store write.
            let wrongConversation = await handle.resolveQuestion(.init(
                conversationID: UUID(), runID: handle.identity.runID,
                requestID: snapshot.requestID, questionID: question.questionID,
                expectedRevision: question.revision,
                answer: UserQuestionAnswer(selectedOptionIDs: ["report"])
            ))
            #expect(wrongConversation == .rejected(.conversationMismatch))
            let wrongRun = await handle.resolveQuestion(.init(
                conversationID: handle.identity.conversationID, runID: UUID(),
                requestID: snapshot.requestID, questionID: question.questionID,
                expectedRevision: question.revision,
                answer: UserQuestionAnswer(selectedOptionIDs: ["report"])
            ))
            #expect(wrongRun == .rejected(.runMismatch))

            // 3. The human answer settles exactly once through the CAS.
            let answer = UserQuestionAnswer(selectedOptionIDs: ["report"])
            let first = await handle.resolveQuestion(.init(
                conversationID: handle.identity.conversationID, runID: handle.identity.runID,
                requestID: snapshot.requestID, questionID: question.questionID,
                expectedRevision: question.revision, answer: answer
            ))
            guard case .accepted(let receipt) = first else {
                Issue.record("Expected the first answer to be accepted, got \(first)")
                return
            }
            #expect(receipt.answer?.selectedOptionLabels == ["Report"])
            #expect(receipt.answer?.source == .human)

            // 4. A duplicate tap receives the original settlement, never a
            // second write.
            let duplicate = await handle.resolveQuestion(.init(
                conversationID: handle.identity.conversationID, runID: handle.identity.runID,
                requestID: snapshot.requestID, questionID: question.questionID,
                expectedRevision: question.revision, answer: UserQuestionAnswer(selectedOptionIDs: ["table"])
            ))
            guard case .notPending(let duplicateReceipt) = duplicate else {
                Issue.record("Expected the duplicate answer to be notPending, got \(duplicate)")
                return
            }
            #expect(duplicateReceipt?.accepted == false)
            #expect(duplicateReceipt?.alreadySettled == true)
            #expect(duplicateReceipt?.answer?.selectedOptionLabels == ["Report"])

            // 5. Durable truth: one human answer, and the host executor never
            // saw the question call.
            let settled = try #require(await center.store.snapshot(requestID: snapshot.requestID))
            #expect(settled.questions.filter(\.isHumanAnswered).count == 1)
            #expect(executor.executedCalls.isEmpty)

            // 6. The answer reached the SAME run: the provider's next turn
            // carries exactly one tool result with the answer receipt.
            let terminal = await handle.waitForTerminal()
            #expect(terminal?.confirmed == true)
            #expect(adapter.requests.count == 2)
            let followUp = try #require(adapter.requests.dropFirst().first)
            let results = followUp.toolResults.filter { $0.callID == call.id }
            #expect(results.count == 1)
            #expect(results.first?.output.contains("Report") == true)
        }
    }

    @Test("A stale card revision is rejected and the card can be answered after refreshing")
    func staleRevisionIsRejected() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Stale question workspace")
            let call = try questionCall()
            let (provider, _) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "Done.")), .completed(.init(stopReason: .endTurn))],
            ])
            let (tools, _, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let handle = try await fixture.runtime.startSession(
                chatRequest(fixture, goal: "Ask once", workspaceID: workspaceID),
                provider: provider, tools: tools
            )
            let center = try await fixture.runtime.userQuestionCenter()
            #expect(await eventually {
                (try? await center.pendingSnapshot(runID: handle.identity.runID))?.currentQuestion != nil
            })
            let snapshot = try #require(await center.pendingSnapshot(runID: handle.identity.runID))
            let question = try #require(snapshot.currentQuestion)

            let stale = await handle.resolveQuestion(.init(
                conversationID: handle.identity.conversationID, runID: handle.identity.runID,
                requestID: snapshot.requestID, questionID: question.questionID,
                expectedRevision: question.revision + 1,
                answer: UserQuestionAnswer(selectedOptionIDs: ["table"])
            ))
            #expect(stale == .rejected(.staleQuestion))

            let fresh = await handle.resolveQuestion(.init(
                conversationID: handle.identity.conversationID, runID: handle.identity.runID,
                requestID: snapshot.requestID, questionID: question.questionID,
                expectedRevision: question.revision,
                answer: UserQuestionAnswer(selectedOptionIDs: ["table"])
            ))
            guard case .accepted = fresh else {
                Issue.record("Expected the fresh-revision answer to be accepted, got \(fresh)")
                return
            }
            #expect(await handle.waitForTerminal()?.confirmed == true)
        }
    }

    @Test("Decline cancels the request and the parked run receives a cancelled tool receipt")
    func declineCancelsQuestionAndRunReceivesCancelledReceipt() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Decline question workspace")
            let call = try questionCall()
            let (provider, adapter) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "Understood, cancelled.")), .completed(.init(stopReason: .endTurn))],
            ])
            let (tools, _, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let handle = try await fixture.runtime.startSession(
                chatRequest(fixture, goal: "Ask then cancel", workspaceID: workspaceID),
                provider: provider, tools: tools
            )
            let center = try await fixture.runtime.userQuestionCenter()
            #expect(await eventually {
                (try? await center.pendingSnapshot(runID: handle.identity.runID))?.currentQuestion != nil
            })
            let snapshot = try #require(await center.pendingSnapshot(runID: handle.identity.runID))

            // A cancel for another run's request is refused untouched.
            #expect(await handle.cancelQuestion(requestID: "uq_missing") == false)

            let cancelled = await handle.cancelQuestion(requestID: snapshot.requestID)
            #expect(cancelled)
            #expect(await eventually {
                guard let settled = try? await center.store.snapshot(requestID: snapshot.requestID) else { return false }
                return settled.questions.allSatisfy { $0.status == .cancelled && $0.answer == nil }
            })
            let terminal = await handle.waitForTerminal()
            #expect(terminal?.confirmed == true)
            let followUp = try #require(adapter.requests.dropFirst().first)
            let results = followUp.toolResults.filter { $0.callID == call.id }
            #expect(results.count == 1)
            #expect(results.first?.output.contains("cancelled") == true)
        }
    }

    @Test("A user stop fences pending questions with no fabricated answer")
    func stopFencesPendingQuestions() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Stop question workspace")
            let call = try questionCall()
            let (provider, _) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
            ])
            let (tools, _, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let handle = try await fixture.runtime.startSession(
                chatRequest(fixture, goal: "Ask and hold", workspaceID: workspaceID),
                provider: provider, tools: tools
            )
            let center = try await fixture.runtime.userQuestionCenter()
            #expect(await eventually {
                (try? await center.pendingSnapshot(runID: handle.identity.runID))?.currentQuestion != nil
            })
            let snapshot = try #require(await center.pendingSnapshot(runID: handle.identity.runID))

            let cancel = await handle.cancelAndWait(timeout: 15)
            #expect(cancel.terminal?.confirmed == true)
            let settled = try #require(await center.store.snapshot(requestID: snapshot.requestID))
            #expect(settled.questions.allSatisfy { $0.status == .cancelled })
            #expect(settled.questions.allSatisfy { $0.answer == nil })
            #expect(settled.questions.allSatisfy { $0.answerSource == .cancelled })

            // A late answer never settles a second time. The session fence
            // refuses it; the durable store independently preserves the
            // original cancelled settlement.
            let late = await handle.resolveQuestion(.init(
                conversationID: handle.identity.conversationID, runID: handle.identity.runID,
                requestID: snapshot.requestID, questionID: snapshot.questions[0].questionID,
                expectedRevision: snapshot.questions[0].revision,
                answer: UserQuestionAnswer(selectedOptionIDs: ["report"])
            ))
            if case .accepted = late {
                Issue.record("A late answer must never be accepted after a stop fence")
            }
            let question = try #require(settled.questions.first)
            let lateReceipt = try? await center.submitHumanAnswer(
                target: snapshot.target(for: question),
                answer: UserQuestionAnswer(selectedOptionIDs: ["report"])
            )
            #expect(lateReceipt?.accepted == false)
            #expect(lateReceipt?.alreadySettled == true)
        }
    }

    @Test("An optionalContinue question stays durably pending while held, restores across coordinator restart, and the terminal fence cancels it without fabricating an answer")
    func optionalQuestionRestoresPassivelyAndTerminalFencesIt() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Restore question workspace")
            // q1 stays optional (it never blocks); q2 is required, so the
            // run is held live while q1 remains durably pending-optional.
            let arguments = try JSONEncoder().encode(UserQuestionRequest(
                waitPolicy: .required,
                questions: [
                    UserQuestionDraft(
                        id: "optional",
                        question: "Optional: anything to add?",
                        options: [UserQuestionOption(id: "note", label: "Add a note")],
                        waitPolicy: .optionalContinue
                    ),
                    UserQuestionDraft(
                        id: "blocking",
                        question: "Required: which format do you want?",
                        options: [
                            UserQuestionOption(id: "report", label: "Report"),
                            UserQuestionOption(id: "table", label: "Table"),
                        ],
                        waitPolicy: .required
                    ),
                ]
            ))
            let call = try ToolCall(id: "call-question-optional", toolName: UserAskTool.name,
                                    argumentsJSON: arguments, scope: .local)
            let (provider, _) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "Continuing with the required answer.")), .completed(.init(stopReason: .endTurn))],
            ])
            let (tools, _, _) = try fixture.makeToolBinding(workspaceID: workspaceID)
            let recorder = QuestionEventRecorder()
            let center = try await fixture.runtime.userQuestionCenter()
            await center.subscribeEvents { event in await recorder.record(event) }
            let handle = try await fixture.runtime.startSession(
                chatRequest(fixture, goal: "Ask mixed policies", workspaceID: workspaceID),
                provider: provider, tools: tools
            )
            let conversationID = handle.identity.conversationID
            #expect(await eventually {
                (try? await center.pendingSnapshot(runID: handle.identity.runID))?.hasBlockingPending == true
            })
            let pending = try #require(await center.pendingSnapshot(conversationID: conversationID))
            let requestID = pending.requestID
            #expect(pending.state == .awaitingAnswer)
            let optionalQuestion = try #require(pending.questions.first(where: { $0.localID == "optional" }))
            let blockingQuestion = try #require(pending.questions.first(where: { $0.localID == "blocking" }))
            #expect(optionalQuestion.waitPolicy == .optionalContinue)
            #expect(blockingQuestion.waitPolicy == .required)

            // Passive restore while the run is held: re-presenting the
            // durable question emits the same presented event without
            // resuming anything.
            let before = await recorder.presentedCount(requestID: requestID)
            await center.restore(conversationID: conversationID)
            #expect(await recorder.presentedCount(requestID: requestID) == before + 1)

            // A restarted coordinator reads the same persisted truth.
            let store = await center.store
            let restarted = UserQuestionCoordinator(store: store)
            let reread = try #require(await restarted.pendingSnapshot(conversationID: conversationID))
            #expect(reread.requestID == requestID)
            #expect(reread.questions.map(\.questionID) == pending.questions.map(\.questionID))

            // Answering the blocking question lets the run finish; the iOS
            // terminal contract cancels the still-pending optional question
            // with no fabricated answer while the human answer is retained.
            let accepted = await handle.resolveQuestion(.init(
                conversationID: conversationID, runID: handle.identity.runID,
                requestID: requestID, questionID: blockingQuestion.questionID,
                expectedRevision: blockingQuestion.revision,
                answer: UserQuestionAnswer(selectedOptionIDs: ["report"])
            ))
            guard case .accepted = accepted else {
                Issue.record("Expected the blocking answer to be accepted, got \(accepted)")
                return
            }
            #expect(await handle.waitForTerminal()?.confirmed == true)
            let settled = try #require(await center.store.snapshot(requestID: requestID))
            let settledOptional = try #require(settled.questions.first(where: { $0.localID == "optional" }))
            let settledBlocking = try #require(settled.questions.first(where: { $0.localID == "blocking" }))
            #expect(settledOptional.status == .cancelled)
            #expect(settledOptional.answer == nil)
            #expect(settledOptional.answerSource == .cancelled)
            #expect(settledBlocking.isHumanAnswered)
            #expect(settledBlocking.answer?.selectedOptionIDs == ["report"])
        }
    }

    @Test("Plan mode offers and dispatches the app-owned question before plan.submit")
    func planSessionOffersQuestionTool() async throws {
        try await withSelfCoreFixture { fixture in
            let workspaceID = try await fixture.createWorkspace(named: "Plan question workspace")
            let call = try questionCall()
            let (provider, adapter) = fixture.makeProvider(scripts: [
                [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                [.textDelta(.init(text: "Plan ready.")), .completed(.init(stopReason: .endTurn))],
            ])
            // One read-only plan-ceiling tool stands in for the host's
            // investigation corpus; the runtime adds user.ask itself.
            let searchDescriptor = ToolCatalog.Descriptor(
                name: "web.search",
                toolDescription: "Search public web sources.",
                parametersJSON: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"],"additionalProperties":false}"#,
                riskLabels: [],
                isSideEffecting: false,
                effect: .readOnly
            )
            let (base, _, _) = try fixture.makeToolBinding(
                workspaceID: workspaceID,
                allowedToolNames: ["web.search"],
                descriptor: searchDescriptor
            )
            let handle = try await fixture.runtime.startSession(
                chatRequest(fixture, goal: "Clarify then plan", workspaceID: workspaceID, mode: .plan),
                provider: provider, tools: base
            )
            let center = try await fixture.runtime.userQuestionCenter()
            #expect(await eventually {
                (try? await center.pendingSnapshot(runID: handle.identity.runID))?.currentQuestion != nil
            })
            // The plan wire offers exactly one user.ask schema even though no
            // host executor owns it (checked after the first dispatch).
            #expect(await eventually {
                (adapter.requests.first?.toolSchemas.contains { $0.name == UserAskTool.name }) == true
            })
            let first = try #require(adapter.requests.first)
            let offered = first.toolSchemas.filter { $0.name == UserAskTool.name }
            #expect(offered.count == 1)

            let snapshot = try #require(await center.pendingSnapshot(runID: handle.identity.runID))
            let question = try #require(snapshot.currentQuestion)
            let accepted = await handle.resolveQuestion(.init(
                conversationID: handle.identity.conversationID, runID: handle.identity.runID,
                requestID: snapshot.requestID, questionID: question.questionID,
                expectedRevision: question.revision,
                answer: UserQuestionAnswer(selectedOptionIDs: ["report"])
            ))
            guard case .accepted = accepted else {
                Issue.record("Expected the plan-mode answer to be accepted, got \(accepted)")
                return
            }
            #expect(await handle.waitForTerminal()?.confirmed == true)
        }
    }
}
