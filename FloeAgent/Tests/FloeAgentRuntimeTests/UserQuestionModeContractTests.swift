import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeSecurity
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("User-question mode contract")
struct UserQuestionModeContractTests {
    private func descriptor() -> ToolCatalog.Descriptor {
        .init(name: UserAskTool.name, toolDescription: UserAskTool.toolDescription,
              parametersJSON: UserAskTool.parametersJSON, riskLabels: UserAskTool.riskLabels,
              isSideEffecting: UserAskTool.isSideEffecting, effect: UserAskTool.toolEffect,
              executionBoundary: UserAskTool.executionBoundary)
    }

    @Test("Plan can offer and dispatch the existing main-run question without authorizing execution")
    func planOffersAndDispatchesQuestion() async throws {
        let question = descriptor()
        let executor = MockExecutor()
        executor.descriptors = [question.name: question,
            "file.write": .init(name: "file.write", riskLabels: [.writesFiles], isSideEffecting: true),
            "checklist.updatePlan": .init(name: "checklist.updatePlan", riskLabels: [],
                                          isSideEffecting: false, effect: .internalState)]
        let receipt = UserQuestionToolReceipt(requestID: "uq_plan_decision", status: .pending,
            answers: [], pendingQuestionIDs: ["uq_plan_decision.q1"], expiredQuestionIDs: [],
            cancelledQuestionIDs: [], humanAnsweredQuestionIDs: [], defaultedQuestionIDs: [],
            message: "Pending ordinary decision")
        executor.results = [.init(callID: "plan-question", status: .ok,
            outputSummary: String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self),
            outputDigest: "question-receipt", maximumSummaryCharacters: 262_144)]
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "plan-question", toolName: UserAskTool.name,
                arguments: #"{"waitPolicy":"optionalContinue","questions":[{"question":"Which output?","options":[{"id":"a","label":"Report"},{"id":"b","label":"Dashboard"}]}]}"#)),
             .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "Independent inspection is complete; the output choice remains pending.")),
             .completed(.init(stopReason: .endTurn))]
        ]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), conversationMode: .plan,
            verifyFinalAnswer: false), adapter: adapter, policy: HumanApprovalPolicy(),
            executor: executor, checkpointStore: MockCheckpointStore())
        try await runtime.start(goal: "Plan the requested analysis and ask which deliverable is wanted")
        let first = try #require(adapter.requests.first)
        #expect(first.toolSchemas.contains { $0.name == UserAskTool.name })
        #expect(!first.toolSchemas.contains { $0.name == "file.write" || $0.name == "checklist.updatePlan" })
        #expect(executor.executedCalls.map(\.toolName) == [UserAskTool.name])
        let returned = try #require(adapter.requests.dropFirst().first?.toolResults.first)
        // The model receives the provenance envelope followed by the raw
        // receipt; it is deliberately not a single JSON document.
        let parts = returned.output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        try #require(parts.count == 2)
        let provenance = try #require(JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any])
        #expect(provenance["toolName"] as? String == UserAskTool.name)
        #expect((provenance["trustedSourceID"] as? String)?.isEmpty == false)
        let saved = try JSONDecoder().decode(UserQuestionToolReceipt.self, from: Data(parts[1].utf8))
        #expect(saved.requestID == receipt.requestID)
        #expect(saved.status == .pending && saved.humanAnsweredQuestionIDs.isEmpty)
        #expect(saved.defaultedQuestionIDs.isEmpty)
    }

    @Test("The Plan exception does not admit other internal writes or broaden question metadata")
    func planExceptionStaysNarrow() throws {
        let policy = PlanToolPolicy(), question = descriptor()
        let call = try TestFixtures.toolCall(id: "question", toolName: UserAskTool.name, arguments: "{}")
        #expect(policy.allowedDescriptors(from: [question]).map(\.name) == [UserAskTool.name])
        #expect(policy.denialResult(call: call, descriptor: question) == nil)
        #expect(question.effect == .internalState && question.executionBoundary == .mainRunOnly)
        #expect(!question.effect.isAllowedInPlanMode)
        #expect(!question.isSideEffecting && question.riskLabels.isEmpty)

        var variants: [ToolCatalog.Descriptor] = []
        var other = question; other.name = "checklist.updatePlan"; variants.append(other)
        var mutating = question; mutating.effect = .mutating; variants.append(mutating)
        var sideEffect = question; sideEffect.isSideEffecting = true; variants.append(sideEffect)
        var anyRun = question; anyRun.executionBoundary = .any; variants.append(anyRun)
        var child = question; child.executionBoundary = .childOnly; variants.append(child)
        var risky = question; risky.riskLabels = [.writesFiles]; variants.append(risky)
        var remote = question; remote.requiresHostScope = true; variants.append(remote)
        for value in variants {
            #expect(policy.allowedDescriptors(from: [value]).isEmpty)
            #expect(policy.denialResult(call: call, descriptor: value)?.status == .denied)
        }
        #expect(policy.denialResult(call: call, descriptor: nil)?.status == .denied)
    }

    @Test("Normal, Plan, Goal, local and fast chat all carry the proactive choice contract once")
    func proactiveQuestionPromptAcrossOrdinaryModes() {
        for mode in [ConversationMode.chat, .plan, .goal] {
            for compact in [false, true] {
                for fast in mode == .chat ? [false, true] : [false] {
                    let prompt = AgentPromptComposer.compose(mode: mode, runtimeContext: "ctx",
                        toolsAvailable: true, compactForLocal: compact, chatFastMode: fast)
                    #expect(prompt.components(separatedBy: "# User decisions").count == 2)
                    #expect(prompt.contains("call it before dependent work or plan.submit"))
                    #expect(prompt.contains("a question only in assistant prose is insufficient"))
                    #expect(prompt.contains("preferring 2–3 concise meaningful options"))
                    #expect(prompt.contains("custom-answer field"))
                    #expect(prompt.contains("Reuse answered decisions"))
                    #expect(prompt.contains("routine reversible details"))
                    #expect(prompt.contains("initially 15 seconds"))
                    #expect(prompt.contains("required with no timeout or fallback"))
                    #expect(prompt.contains("neither an answer nor a timeout grants authority"))
                    if compact { #expect(prompt.utf8.count < 8_000) }
                }
            }
        }
    }

    @Test("A signed style or delivery overlay cannot remove the native decision contract")
    func overlaysRetainDecisionContract() throws {
        let overlay = try AgentPromptOverlay(sections: [
            .init(id: AgentPromptOverlay.communicationSectionID, body: "Give concise progress."),
            .init(id: AgentPromptOverlay.deliverySectionID, body: "Verify the requested deliverable.")
        ])
        let prompt = AgentPromptComposer.compose(mode: .plan, runtimeContext: "ctx", overlay: overlay)
        #expect(prompt.contains("Give concise progress."))
        #expect(prompt.contains("# User decisions"))
        #expect(prompt.contains("Resolve material ambiguity through user.ask before plan.submit"))
    }

    @Test("Tool-free and temporary envelopes do not promise an unavailable decision card")
    func unavailableQuestionCardIsNotInvented() {
        for compact in [false, true] {
            for mode in [ConversationMode.chat, .plan] {
                let unavailable = AgentPromptComposer.compose(mode: mode, runtimeContext: "ctx",
                    toolsAvailable: false, compactForLocal: compact)
                #expect(!unavailable.contains("# User decisions"))
                #expect(!unavailable.contains("Resolve material ambiguity through user.ask before plan.submit"))
            }
            let temporary = AgentPromptComposer.compose(mode: .chat, runtimeContext: "ctx",
                toolsAvailable: true, compactForLocal: compact, chatFastMode: true, temporaryReadOnly: true)
            #expect(!temporary.contains("# User decisions"))
            #expect(temporary.contains("temporary, RAM-only conversation"))
        }
    }

    @Test("Question discovery preserves preferred concise choices and the existing custom answer")
    func schemaKeepsCustomChoiceContract() throws {
        let raw = try JSONSerialization.jsonObject(with: Data(UserAskTool.parametersJSON.utf8))
        let root = try #require(raw as? [String: Any])
        let properties = try #require(root["properties"] as? [String: Any])
        let questions = try #require(properties["questions"] as? [String: Any])
        let item = try #require(questions["items"] as? [String: Any])
        let fields = try #require(item["properties"] as? [String: Any])
        let options = try #require(fields["options"] as? [String: Any])
        #expect((options["description"] as? String)?.contains("Prefer 2–3") == true)
        #expect((options["description"] as? String)?.contains("custom-answer field") == true)
        // Preference is not a wire-format restriction on legitimate multi-select questions.
        #expect(options["maxItems"] as? Int == 8)
        for query in ["user.ask", "ask a clarifying question", "ask which approach the user wants"] {
            #expect(ToolDiscovery.matches(queries: [query], descriptors: [descriptor()])
                .contains { $0.name == UserAskTool.name })
        }
    }
}
