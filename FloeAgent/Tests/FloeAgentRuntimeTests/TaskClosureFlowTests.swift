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
    private func runtime(_ adapter:MockAdapter,_ executor:any ToolExecutor,runID:UUID,sink:MockSink = .init(),
        mode:ConversationMode = .chat,verify:Bool = false,fast:Bool = false,
        checklist:(@Sendable ()async->TaskChecklist?)? = nil,
        dependencies:(@Sendable ()async->[RunDependencyLabel])? = nil,
        checkpointStore:MockCheckpointStore = .init(),
        policy:(any ApprovalPolicy)? = nil) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(configuration:.init(provider:provider,model:TestFixtures.testModel(providerID:provider.id),
                conversationMode:mode,pauseTimeout:0.1,verifyFinalAnswer:verify,planChecklistProvider:checklist,
                providerRetryBaseDelay:0,providerRetryMaxDelay:0,providerRetryJitterRatio:0,chatFastMode:fast,outstandingDependencies:dependencies),
            adapter:adapter,policy:policy ?? AutomaticApprovalPolicy(backend:RecordingApprovalBackend()),executor:executor,
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

    // MARK: - Correction/supersession evidence (W10)

    private func exportReceipt(
        _ fingerprint:String,_ status:String,_ outputPath:String,
        dispatched:Bool,mutation:Bool = false,unknown:Bool = false
    ) -> TaskClosureGate.Receipt {
        .init(toolName:"document.pdf.export",callFingerprint:fingerprint,status:status,
            isSideEffecting:true,outcomeUnknown:unknown,supportsMutationClaim:mutation,
            wasDispatched:dispatched,
            operationIdentity:"tool=document.pdf.export|outputPath=\(outputPath)")
    }

    @Test("A corrected pre-execution rejection with the same output identity completes")
    func correctedPreExecutionRejectionCompletes() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor()
        calls.descriptors["document.pdf.export"] = .init(name:"document.pdf.export",riskLabels:[],isSideEffecting:true)
        let denied = try TestFixtures.toolCall(id:"denied-call",toolName:"document.pdf.export",
            arguments:#"{"outputPath":"/tmp/report.pdf"}"#)
        let corrected = try TestFixtures.toolCall(id:"corrected-call",toolName:"document.pdf.export",
            arguments:#"{"outputPath":"/tmp/report.pdf","quality":1}"#)
        adapter.script = [
            [.toolRequest(denied),.completed(.init(stopReason:.toolUse))],
            [.toolRequest(corrected),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"PDF 已导出。")),.completed(.init(stopReason:.endTurn))]
        ]
        let done = checklist(run,finished:true)
        let subject = runtime(adapter,calls,runID:run,fast:true,checklist:{done},
            policy:DenyCallIDsPolicy(deniedCallIDs:["denied-call"]))
        try await subject.start(goal:"导出 PDF")
        #expect(adapter.requests.count == 3)
        #expect(calls.executedCalls.map(\.id) == ["corrected-call"])
        #expect(await subject.state.name == "completed")
    }

    @Test("A different output on the same tool never swallows a failure")
    func differentOutputOnSameToolStillFails() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor(), sink = MockSink()
        calls.descriptors["document.pdf.export"] = .init(name:"document.pdf.export",riskLabels:[],isSideEffecting:true)
        let denied = try TestFixtures.toolCall(id:"denied-call",toolName:"document.pdf.export",
            arguments:#"{"outputPath":"/tmp/a.pdf"}"#)
        let other = try TestFixtures.toolCall(id:"other-call",toolName:"document.pdf.export",
            arguments:#"{"outputPath":"/tmp/b.pdf"}"#)
        adapter.script = [
            [.toolRequest(denied),.completed(.init(stopReason:.toolUse))],
            [.toolRequest(other),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"PDF 已导出。")),.completed(.init(stopReason:.endTurn))],
            [.textDelta(.init(text:"PDF 已导出。")),.completed(.init(stopReason:.endTurn))]
        ]
        let done = checklist(run,finished:true)
        let subject = runtime(adapter,calls,runID:run,sink:sink,fast:true,checklist:{done},
            policy:DenyCallIDsPolicy(deniedCallIDs:["denied-call"]))
        try await subject.start(goal:"导出 PDF")
        #expect(calls.executedCalls.map(\.id) == ["other-call"])
        guard case .failed(let failure) = await subject.state else {
            Issue.record("An independent output must not absorb the failed one"); return
        }
        #expect(failure.isRecoverable)
        #expect(!sink.events.contains { if case .completed = $0 { true } else { false } })
    }

    @Test("A post-dispatch failure is never superseded by a corrected success")
    func dispatchedFailureIsNotSuperseded() async throws {
        let run = UUID(), adapter = MockAdapter(), calls = executor(), sink = MockSink()
        calls.descriptors["document.pdf.export"] = .init(name:"document.pdf.export",riskLabels:[],isSideEffecting:true)
        let failed = try TestFixtures.toolCall(id:"failed-call",toolName:"document.pdf.export",
            arguments:#"{"outputPath":"/tmp/report.pdf"}"#)
        let corrected = try TestFixtures.toolCall(id:"corrected-call",toolName:"document.pdf.export",
            arguments:#"{"outputPath":"/tmp/report.pdf","quality":1}"#)
        calls.results = [
            .init(callID:failed.id,status:.failed,outputSummary:"synthetic tool validation failure",outputDigest:"f"),
            .init(callID:corrected.id,status:.ok,outputSummary:"exported",outputDigest:"d")
        ]
        adapter.script = [
            [.toolRequest(failed),.completed(.init(stopReason:.toolUse))],
            [.toolRequest(corrected),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"PDF 已导出。")),.completed(.init(stopReason:.endTurn))],
            [.textDelta(.init(text:"PDF 已导出。")),.completed(.init(stopReason:.endTurn))]
        ]
        let done = checklist(run,finished:true)
        let subject = runtime(adapter,calls,runID:run,sink:sink,fast:true,checklist:{done})
        try await subject.start(goal:"导出 PDF")
        guard case .failed(let failure) = await subject.state else {
            Issue.record("A dispatched failure must keep blocking"); return
        }
        #expect(failure.isRecoverable)
    }

    @Test("A tool-body cancellation after dispatch is never superseded")
    func executorThrownCancellationIsNotSuperseded() async throws {
        let run = UUID(), adapter = MockAdapter(), sink = MockSink()
        let projectID = "D971821A-96BE-46A8-A5D7-C0A80913979A"
        let cancelled = try TestFixtures.toolCall(id:"cancelled-call",toolName:"document.pdf.export",
            arguments:#"{"outputPath":"/tmp/report.pdf"}"#)
        let corrected = try TestFixtures.toolCall(id:"corrected-call",toolName:"document.pdf.export",
            arguments:#"{"outputPath":"/tmp/report.pdf","quality":1}"#)
        let calls = CancelThrowingExecutor(
            descriptors:["document.pdf.export":.init(name:"document.pdf.export",riskLabels:[],isSideEffecting:true)],
            cancelledCallIDs:["cancelled-call"])
        adapter.script = [
            [.toolRequest(cancelled),.completed(.init(stopReason:.toolUse))],
            [.toolRequest(corrected),.completed(.init(stopReason:.toolUse))],
            [.textDelta(.init(text:"PDF 已导出。")),.completed(.init(stopReason:.endTurn))],
            [.textDelta(.init(text:"PDF 已导出。")),.completed(.init(stopReason:.endTurn))]
        ]
        let done = checklist(run,finished:true)
        let subject = runtime(adapter,calls,runID:run,sink:sink,fast:true,checklist:{done})
        try await subject.start(goal:"导出 PDF")
        #expect(calls.executedCalls.map(\.id) == ["cancelled-call","corrected-call"])
        guard case .failed(let failure) = await subject.state else {
            Issue.record("An executor-thrown cancellation must keep blocking"); return
        }
        #expect(failure.isRecoverable)
    }

    @Test("Closure supersession needs a trusted same-output correction")
    func closureSupersessionNeedsTrustedCorrection() {
        let done = TaskClosureGate.Step(id:"all",title:"t",status:"completed")
        let denied = exportReceipt("fp-denied","denied","/tmp/report.pdf",dispatched:false)
        let corrected = exportReceipt("fp-ok","ok","/tmp/report.pdf",dispatched:true,mutation:true)
        let fixed = TaskClosureGate.Facts(steps:[done],receipts:[denied,corrected],availableToolNames:["document.pdf.export"])
        #expect(!fixed.hasNonSuccessfulWork)

        let otherOutput = exportReceipt("fp-ok2","ok","/tmp/other.pdf",dispatched:true,mutation:true)
        let independent = TaskClosureGate.Facts(steps:[done],receipts:[denied,otherOutput],availableToolNames:["document.pdf.export"])
        #expect(independent.hasNonSuccessfulWork)

        var dispatchedFailure = denied
        dispatchedFailure.wasDispatched = true
        let postDispatch = TaskClosureGate.Facts(steps:[done],receipts:[dispatchedFailure,corrected],availableToolNames:["document.pdf.export"])
        #expect(postDispatch.hasNonSuccessfulWork)

        var unknown = denied
        unknown.outcomeUnknown = true
        let unknownFacts = TaskClosureGate.Facts(steps:[done],receipts:[unknown,corrected],availableToolNames:["document.pdf.export"])
        #expect(unknownFacts.hasNonSuccessfulWork)

        // In-place/container families (studio.edit, studio.media, office
        // apply, CAD apply, batch creation) carry no provable output
        // identity: their receipts must never supersede.
        var untrustedFailure = denied
        untrustedFailure.operationIdentity = nil
        var untrustedSuccess = corrected
        untrustedSuccess.operationIdentity = nil
        let untrusted = TaskClosureGate.Facts(steps:[done],receipts:[untrustedFailure,untrustedSuccess],availableToolNames:["document.pdf.export"])
        #expect(untrusted.hasNonSuccessfulWork)

        let secondFailure = exportReceipt("fp-denied-2","denied","/tmp/second.pdf",dispatched:false)
        let oneSuccessTwoFailures = TaskClosureGate.Facts(steps:[done],receipts:[denied,secondFailure,corrected],availableToolNames:["document.pdf.export"])
        #expect(oneSuccessTwoFailures.hasNonSuccessfulWork)

        let sameFingerprintRetry = exportReceipt("fp-denied","ok","/tmp/report.pdf",dispatched:true,mutation:true)
        let retried = TaskClosureGate.Facts(steps:[done],receipts:[denied,sameFingerprintRetry],availableToolNames:["document.pdf.export"])
        #expect(!retried.hasNonSuccessfulWork)
    }
}

/// Test policy denying an exact set of call ids (trusted pre-execution
/// rejections); everything else is allowed once.
private struct DenyCallIDsPolicy: ApprovalPolicy {
    let policyName = "test-deny-call-ids"
    let deniedCallIDs: Set<String>
    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        if deniedCallIDs.contains(action.toolCall.id) {
            return .deny(reason: "Synthetic pre-execution rejection for regression")
        }
        return .allow(scope: ApprovalScope(toolName: action.toolCall.toolName, singleUse: true), expiresAt: nil)
    }
}

/// Executor whose chosen calls throw `FloeError.cancelled` from INSIDE the
/// tool body (a post-dispatch cancellation), proving the receipt stays
/// marked as dispatched and is never superseded as a pre-execution rejection.
private final class CancelThrowingExecutor: ToolExecutor, @unchecked Sendable {
    private let descriptors: [String: ToolCatalog.Descriptor]
    private let cancelledCallIDs: Set<String>
    private let storage = AsyncLock<[ToolCall]>([])
    init(descriptors: [String: ToolCatalog.Descriptor], cancelledCallIDs: Set<String>) {
        self.descriptors = descriptors
        self.cancelledCallIDs = cancelledCallIDs
    }
    var executedCalls: [ToolCall] { storage.withLock { $0 } }
    func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptors[name] }
    var allDescriptors: [ToolCatalog.Descriptor] { descriptors.values.sorted { $0.name < $1.name } }
    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        storage.withLock { $0.append(call) }
        if cancelledCallIDs.contains(call.id) { throw FloeError.cancelled }
        return ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
    }
}
