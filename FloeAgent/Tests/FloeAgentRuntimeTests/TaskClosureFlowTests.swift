import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

@Suite("FloeAgentRuntime.TaskClosure", .serialized)
struct TaskClosureFlowTests {
    private func checklist(_ runID:UUID,finished:Bool = false) -> TaskChecklist {
        .init(conversationID:UUID(),runID:runID,revision:finished ? 2:1,title:"Native edits",
            steps:[.init(id:"diagram",title:"Edit diagram",status:finished ? .completed:.pending,
                evidence:finished ? ["write receipt"]:[])],updatedAt:Date())
    }
    private func executor() -> MockExecutor {
        let value = MockExecutor()
        value.descriptors["workspace.readFile"] = .init(name:"workspace.readFile",riskLabels:[],isSideEffecting:false)
        value.descriptors["studio.edit"] = .init(name:"studio.edit",riskLabels:[],isSideEffecting:true)
        return value
    }
    private func runtime(_ adapter:MockAdapter,_ executor:MockExecutor,runID:UUID,sink:MockSink = .init(),
        mode:ConversationMode = .chat,verify:Bool = false,fast:Bool = false,
        checklist:(@Sendable ()async->TaskChecklist?)? = nil,
        dependencies:(@Sendable ()async->[RunDependencyLabel])? = nil,
        checkpointStore:MockCheckpointStore = .init()) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(configuration:.init(provider:provider,model:TestFixtures.testModel(providerID:provider.id),
                conversationMode:mode,pauseTimeout:0.1,verifyFinalAnswer:verify,planChecklistProvider:checklist,
                providerRetryBaseDelay:0,providerRetryMaxDelay:0,providerRetryJitterRatio:0,chatFastMode:fast,outstandingDependencies:dependencies),
            adapter:adapter,policy:AutomaticApprovalPolicy(backend:RecordingApprovalBackend()),executor:executor,
            checkpointStore:checkpointStore,sink:sink,runID:runID)
    }

    @Test("A pending task promise continues through the actual executor once")
    func promisedWorkActuallyExecutes() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor()
        let pending = checklist(run), done = checklist(run,finished:true)
        adapter.script = [
            [.textDelta(.init(text:"接下来继续编辑图示。")),.completed(.init(stopReason:.endTurn))],
            [.toolRequest(try TestFixtures.toolCall(id:"edit",toolName:"studio.edit",arguments:#"{"projectID":"owned","expectedRevision":"1","editsJSON":"[]"}"#)),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"图示编辑完成。")),.completed(.init(stopReason:.endTurn))]
        ]
        let subject = runtime(adapter,calls,runID:run,checklist:{ calls.executedCalls.isEmpty ? pending:done })
        try await subject.start(goal:"编辑图示")
        #expect(adapter.requests.count == 3)
        #expect(calls.executedCalls.map(\.id) == ["edit"])
        #expect(await subject.state.name == "completed")
    }

    @Test("A second future promise cannot become a completed run")
    func repeatedPromiseFailsRecoverably() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor(), sink = MockSink()
        let plan = checklist(run)
        adapter.script = [
            [.textDelta(.init(text:"图示编辑失败。接下来按各工具返回的实际结构格式修正编辑输入，并继续化学结构分析。")),.completed(.init(stopReason:.endTurn))],
            [.textDelta(.init(text:"编辑失败。接下来按各工具返回的实际结构格式修正编辑输入，并继续化学结构分析。")),.completed(.init(stopReason:.endTurn))]
        ]
        let subject = runtime(adapter,calls,runID:run,sink:sink,checklist:{plan})
        try await subject.start(goal:"完成原生编辑")
        #expect(adapter.requests.count == 2)
        #expect(calls.executedCalls.isEmpty)
        guard case .failed(let failure) = await subject.state else { Issue.record("Expected unfinished work failure"); return }
        #expect(failure.isRecoverable)
        #expect(!sink.events.contains { if case .completed = $0 { true } else { false } })
    }

    @Test("Read success and write failure require a factual closure without replay")
    func partialFailureReportsTheBlockerWithoutReplay() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor()
        let plan = checklist(run)
        let read = try TestFixtures.toolCall(id:"read",toolName:"workspace.readFile",arguments:#"{"path":"diagram.json"}"#)
        let write = try TestFixtures.toolCall(id:"write",toolName:"studio.edit",arguments:#"{"projectID":"owned"}"#)
        calls.results = [.init(callID:read.id,status:.ok,outputSummary:"read",outputDigest:"read"),
            .init(callID:write.id,status:.failed,outputSummary:"Missing target binding",outputDigest:"failed")]
        adapter.script = [
            [.toolRequest(read),.completed(.init(stopReason:.toolUse))],
            [.toolRequest(write),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"图示编辑失败。接下来按各工具返回的实际结构格式修正编辑输入，并继续化学结构分析。")),.completed(.init(stopReason:.endTurn))],
            [.textDelta(.init(text:"读取已完成；图示编辑失败，化学计算未完成，需要先绑定目标。")),.completed(.init(stopReason:.endTurn))]
        ]
        let subject = runtime(adapter,calls,runID:run,fast:true,checklist:{plan})
        try await subject.start(goal:"编辑图示并计算化学结构")
        #expect(adapter.requests.count == 4)
        #expect(calls.executedCalls.map(\.id) == ["read","write"])
        #expect(await subject.state.name == "completed")
        #expect(adapter.requests.last?.messages.contains { $0.role == "system" && $0.content.contains("Read/search/discovery and draft-only success are not evidence") } == true)
    }

    @Test("A read receipt cannot justify a new write and cannot authorize one")
    func readOnlyReceiptCorrectsTheClaimWithoutWriting() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id:"read",toolName:"workspace.readFile",arguments:#"{"path":"test.txt"}"#)),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"已创建 test.txt 文件并保存。")),.completed(.init(stopReason:.endTurn))],
            [.textDelta(.init(text:"只读取了 test.txt 文件，未执行创建或保存。")),.completed(.init(stopReason:.endTurn))]
        ]
        let subject = runtime(adapter,calls,runID:run)
        try await subject.start(goal:"读取这个文件")
        #expect(adapter.requests.count == 3)
        #expect(calls.executedCalls.map(\.toolName) == ["workspace.readFile"])
        #expect(await subject.state.name == "completed")
    }

    @Test("Audited native inspections and drafts cannot prove a saved file")
    func mixedToolReadAndDraftReceiptsRequireAnHonestCorrection() async throws {
        let projectID = "D971821A-96BE-46A8-A5D7-C0A80913979A"
        let fixtures:[(String,String)] = [
            ("studio.run", "{\"projectID\":\"\(projectID)\",\"action\":\"inspectAudio\",\"inputJSON\":\"{}\"}"),
            ("studio.machining", "{\"projectID\":\"\(projectID)\",\"action\":\"inspect\"}"),
            ("studio.chemistry", "{\"projectID\":\"\(projectID)\",\"action\":\"history\"}"),
            ("document.office.edit", #"{"documentID":"owned","action":"propose"}"#)
        ]
        for (name,arguments) in fixtures {
            let adapter = MockAdapter(), calls = executor(), store = MockCheckpointStore()
            // These families conservatively retain a mutating descriptor.
            calls.descriptors[name] = .init(name:name,riskLabels:[],isSideEffecting:true)
            let call = try TestFixtures.toolCall(id:"observe",toolName:name,arguments:arguments)
            adapter.script = [
                [.toolRequest(call),.completed(.init(stopReason:.toolUse))],
                [.textDelta(.init(text:"文件已保存。")),.completed(.init(stopReason:.endTurn))],
                [.textDelta(.init(text:"只获得了观察或草稿结果，未执行文件保存。")),.completed(.init(stopReason:.endTurn))]
            ]
            let subject = runtime(adapter,calls,runID:UUID(),checkpointStore:store)
            try await subject.start(goal:"只观察已有素材或准备草稿，汇报实际结果")
            #expect(adapter.requests.count == 3,Comment(rawValue:name))
            #expect(calls.executedCalls.map(\.id) == [call.id])
            #expect(await subject.state.name == "completed")
            #expect(adapter.requests.last?.messages.contains {
                $0.role == "system" && $0.content.contains("no successful tool result")
            } == true)
            // No change to the persisted lifecycle/effect contract.
            let entries: [AgentExecutionLedgerEntry] = store.saved.flatMap { $0.executionLedgerEntries ?? [] }
            let retainedEffectContract = entries.contains { entry in
                entry.toolName == name && entry.status == .ok && entry.isSideEffecting == true
            }
            #expect(retainedEffectContract)
        }
    }

    @Test("Repeated saved-file claims after audio inspection fail after one correction")
    func audioObservationCannotMaskARepeatedFalseSaveClaim() async throws {
        let adapter = MockAdapter(), calls = executor(), sink = MockSink()
        calls.descriptors["studio.run"] = .init(name:"studio.run",riskLabels:[],isSideEffecting:true)
        let call = try TestFixtures.toolCall(id:"observe",toolName:"studio.run",
            arguments:#"{"projectID":"D971821A-96BE-46A8-A5D7-C0A80913979A","action":"inspectAudio","inputJSON":"{}"}"#)
        adapter.script = [
            [.toolRequest(call),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"文件已保存。")),.completed(.init(stopReason:.endTurn))],
            [.textDelta(.init(text:"文件已保存。")),.completed(.init(stopReason:.endTurn))]
        ]
        let subject = runtime(adapter,calls,runID:UUID(),sink:sink)
        try await subject.start(goal:"观察音频波形")
        #expect(adapter.requests.count == 3)
        #expect(calls.executedCalls.map(\.id) == [call.id])
        guard case .failed(let failure) = await subject.state else {
            Issue.record("Expected a bounded, recoverable false-claim failure"); return
        }
        #expect(failure.isRecoverable)
        #expect(!sink.events.contains { if case .completed = $0 { true } else { false } })
    }

    @Test("Successful native create and edit receipts still support completed work")
    func nativeMutationsRetainTheirSuccessfulEvidence() async throws {
        for name in ["studio.create","studio.edit"] {
            let adapter = MockAdapter(), calls = executor()
            calls.descriptors[name] = .init(name:name,riskLabels:[],isSideEffecting:true)
            let arguments = name == "studio.create"
                ? #"{"kind":"diagram","title":"Native evidence fixture"}"#
                : #"{"projectID":"D971821A-96BE-46A8-A5D7-C0A80913979A","expectedRevision":"1","operationsJSON":"{\"action\":\"append\",\"text\":\"Saved fixture\"}"}"#
            let call = try TestFixtures.toolCall(id:"mutate",toolName:name,arguments:arguments)
            adapter.script = [
                [.toolRequest(call),.completed(.init(stopReason:.toolUse))],
                [.textDelta(.init(text:"文件已保存。")),.completed(.init(stopReason:.endTurn))]
            ]
            let subject = runtime(adapter,calls,runID:UUID())
            try await subject.start(goal:"编辑并保存文档")
            #expect(adapter.requests.count == 2,Comment(rawValue:name))
            #expect(calls.executedCalls.map(\.id) == [call.id])
            #expect(await subject.state.name == "completed")
        }
    }

    @Test("Another run's unfinished checklist cannot expand a new request")
    func staleChecklistDoesNotCreateWork() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor()
        let old = checklist(UUID())
        adapter.script = [[.textDelta(.init(text:"你好。")),.completed(.init(stopReason:.endTurn))]]
        let subject = runtime(adapter,calls,runID:run,checklist:{old})
        try await subject.start(goal:"你好")
        #expect(adapter.requests.count == 1)
        #expect(calls.executedCalls.isEmpty)
        #expect(await subject.state.name == "completed")
    }

    @Test("Plan mode and budget stops do not acquire an execution retry")
    func explicitNonExecutionBoundariesRemainAuthoritative() async throws {
        for planMode in [true,false] {
            let run = UUID(), adapter = MockAdapter(), calls = executor()
            let plan = checklist(run)
            adapter.script = [[.textDelta(.init(text:"接下来我会继续执行。")),.completed(.init(stopReason:planMode ? .endTurn:.budgetLimited))]]
            let subject = runtime(adapter,calls,runID:run,mode:planMode ? .plan:.chat,checklist:{plan})
            try await subject.start(goal:planMode ? "只制定计划":"完成工作")
            #expect(adapter.requests.count == 1)
            #expect(calls.executedCalls.isEmpty)
            guard case .completed(let info) = await subject.state else { Issue.record("Existing boundary changed"); return }
            #expect(info.stopReason == (planMode ? .endTurn:.budgetLimited))
        }
    }

    @Test("A real required job retains the existing checkpoint and resume lifecycle")
    func finiteDependencyParksInsteadOfInventingAnotherRun() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor()
        let plan = checklist(run)
        adapter.script = [[.textDelta(.init(text:"接下来继续完成导出。")),.completed(.init(stopReason:.endTurn))]]
        let subject = runtime(adapter,calls,runID:run,checklist:{plan},dependencies:{[.init(identifier:"owned-job",kind:"job",label:"Export")]})
        try await subject.start(goal:"导出结果")
        #expect(adapter.requests.count == 1)
        #expect(calls.executedCalls.isEmpty)
        guard case .checkpointed(let reference) = await subject.state else { Issue.record("Expected existing finite dependency wait"); return }
        #expect(reference.reason?.hasPrefix(FloeAgentRuntime.dependencyWaitReasonPrefix) == true)
    }

    @Test("Tool-free final review cannot promise another execution phase")
    func finalReviewPromiseFailsWithoutReopeningTools() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor(), sink = MockSink()
        adapter.script = [
            [.textDelta(.init(text:"答复完成。")),.completed(.init(stopReason:.endTurn))],
            [.textDelta(.init(text:"I will now inspect the logs.")),.completed(.init(stopReason:.endTurn))]
        ]
        let subject = runtime(adapter,calls,runID:run,sink:sink,verify:true)
        try await subject.start(goal:"答复这个问题")
        #expect(adapter.requests.count == 2)
        #expect(adapter.requests.last?.toolSchemas.isEmpty == true)
        #expect(calls.executedCalls.isEmpty)
        #expect(await subject.state.name == "failed")
        #expect(sink.verifiedDraftConfirmations.isEmpty)
    }
}
