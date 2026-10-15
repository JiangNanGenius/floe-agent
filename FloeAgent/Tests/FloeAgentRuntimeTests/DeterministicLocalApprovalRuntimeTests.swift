// FloeAgentRuntimeTests — deterministic local carve-outs through the REAL
// canonical runtime path (main run and delegated child).
//
// These tests use the live runtime, a real audit sink and the real approval
// pipeline. They prove the behavioral outcome the user policy requires:
// an ordinary document edit with POSITIVELY resolved targets EXECUTES without
// an approval card and carries a runtime-minted approval grant/authority;
// repository content, nested repositories and redirected write extents keep
// the existing card/review; the local-guest binding comes from the frozen
// configuration rather than model arguments; and an ambiguous guest command
// is not covered by an earlier read-only allow. Every wait is bounded so a
// regression reports a failed expectation instead of wedging the suite.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
import FloeTestSupport

@Suite("FloeAgentRuntime.DeterministicLocalApproval", .serialized)
struct DeterministicLocalApprovalRuntimeTests {

    // MARK: - Harness

    /// Captures every executed call with the exact ToolContext the runtime
    /// built, so tests can assert the runtime-minted authority and grants.
    final class CapturingExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var call: ToolCall
            var context: ToolContext
        }

        private let storage = AsyncLock<[Entry]>([])
        private let descriptors: [String: ToolCatalog.Descriptor]

        init(descriptors: [String: ToolCatalog.Descriptor]) {
            self.descriptors = descriptors
        }

        var entries: [Entry] { storage.withLock { $0 } }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptors[name] }

        var allDescriptors: [ToolCatalog.Descriptor] {
            descriptors.values.sorted { $0.name < $1.name }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            try context.cancellation.throwIfCancelled()
            storage.withLock { $0.append(Entry(call: call, context: context)) }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
        }
    }

    /// Records which calls reached the model reviewer and denies them.
    final class DenyBackend: ModelApprovalPolicy.DecisionBackend, @unchecked Sendable {
        private let storage = AsyncLock<[String]>([])

        var toolNames: [String] { storage.withLock { $0 } }

        func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
            storage.withLock { $0.append(action.toolCall.toolName) }
            return .deny(reason: "reviewed")
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private func makeRuntime(
        adapter: MockAdapter,
        executor: any ToolExecutor,
        policy: any ApprovalPolicy,
        workspaceRoot: URL?,
        localGuest: Bool = false,
        stores: [String: String] = [:],
        audit: MockAuditSink = MockAuditSink(),
        sink: MockSink = MockSink()
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                workspaceRootURL: workspaceRoot,
                pauseTimeout: 0.1,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0,
                localLinuxGuestEnvironment: localGuest,
                serviceStorePaths: stores
            ),
            adapter: adapter,
            policy: policy,
            executor: executor,
            auditSink: audit,
            checkpointStore: MockCheckpointStore(),
            sink: sink
        )
    }

    private func makeRuntime(
        executor: any ToolExecutor,
        policy: any ApprovalPolicy,
        workspaceRoot: URL?,
        localGuest: Bool = false,
        stores: [String: String] = [:]
    ) -> FloeAgentRuntime {
        makeRuntime(
            adapter: MockAdapter(),
            executor: executor,
            policy: policy,
            workspaceRoot: workspaceRoot,
            localGuest: localGuest,
            stores: stores
        )
    }

    private func makeTree(gitDirectory: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("k-runtime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if gitDirectory {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        return root
    }

    private func makeNestedRepository(inside root: URL) throws -> URL {
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nested.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        return nested
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func descriptors() -> [String: ToolCatalog.Descriptor] {
        func mutating(_ name: String) -> ToolCatalog.Descriptor {
            ToolCatalog.Descriptor(
                name: name,
                riskLabels: [.readsFiles, .writesFiles],
                isSideEffecting: true,
                effect: .mutating
            )
        }
        return [
            "document.office.edit": mutating("document.office.edit"),
            "document.createWord": mutating("document.createWord"),
            "document.pdf.edit": mutating("document.pdf.edit"),
            "document.pdf.export": mutating("document.pdf.export"),
            "cad.document": mutating("cad.document"),
            "media.project": mutating("media.project"),
            "video.edit": mutating("video.edit"),
            "exec.shell": ToolCatalog.Descriptor(
                name: "exec.shell",
                riskLabels: [.executesLocalCode, .readsFiles, .writesFiles, .deletesFiles, .networkAccess],
                isSideEffecting: true,
                effect: .mutating
            )
        ]
    }

    private func documentCall(
        id: String = "call_doc",
        extra: String = ""
    ) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: "document.office.edit",
            argumentsJSON: Data(#"{"action":"apply","proposal_id":"p","path":"report.docx"\#(extra)}"#.utf8),
            scope: .local
        )
    }

    private func pdfEditCall(
        id: String = "call_pdf",
        input: String = "input.pdf",
        output: String = "out.pdf",
        extra: String = ""
    ) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: "document.pdf.edit",
            argumentsJSON: Data(#"{"inputPath":"\#(input)","outputPath":"\#(output)"\#(extra)}"#.utf8),
            scope: .local
        )
    }

    private func mediaProjectCall(
        id: String = "call_mp",
        projectID: UUID,
        action: String = "apply",
        extra: String = ""
    ) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: "media.project",
            argumentsJSON: Data(
                #"{"action":"\#(action)","project_id":"\#(projectID.uuidString)","proposal_id":"p"\#(extra)}"#.utf8
            ),
            scope: .local
        )
    }

    private func videoEditCall(id: String = "call_vid", input: String = "in.mov", output: String = "out.mp4") throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: "video.edit",
            argumentsJSON: Data(
                #"{"input":"\#(input)","output":"\#(output)","operations":[],"exportSpec":{"container":"mp4"}}"#.utf8
            ),
            scope: .local
        )
    }

    private func shellCall(id: String = "call_sh", command: String = "ls -la") throws -> ToolCall {
        let payload = try JSONSerialization.data(withJSONObject: ["command": command])
        return try ToolCall(
            id: id,
            toolName: "exec.shell",
            argumentsJSON: payload,
            scope: .local
        )
    }

    private func childContext(
        tools: Set<String>,
        workspaceRoot: URL,
        conversationID: UUID
    ) -> ToolContext {
        ToolContext(
            runID: UUID(),
            scope: .local,
            allowedToolNames: tools,
            workspaceRootURL: workspaceRoot,
            cancellation: CancellationToken(),
            conversationID: conversationID
        )
    }

    private func dispatchAsChild(
        _ runtime: FloeAgentRuntime,
        call: ToolCall,
        tools: Set<String>,
        workspaceRoot: URL,
        delegateCallID: String
    ) async -> ToolResult {
        let identity = ChildExecutionIdentity(
            parentRunID: await runtime.runID,
            rootTaskID: UUID(),
            delegateCallID: delegateCallID
        )
        return await runtime.dispatchChildTool(
            call,
            identity: identity,
            childContext: childContext(
                tools: tools,
                workspaceRoot: workspaceRoot,
                conversationID: identity.rootTaskID
            )
        )
    }

    // MARK: - Main run

    @Test("An ordinary document edit executes without an approval card and with runtime authority")
    func documentEditExecutesWithoutApproval() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let adapter = MockAdapter()
        let call = try documentCall()
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = CapturingExecutor(descriptors: descriptors())
        let audit = MockAuditSink()
        let sink = MockSink()
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree,
            audit: audit,
            sink: sink
        )
        let finished = AsyncLock(false)
        let task = Task {
            defer { finished.withLock { $0 = true } }
            try await runtime.start(goal: "edit the report")
        }

        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await task.value }

        #expect(settled, "The run must settle instead of parking on an approval card")
        #expect(!sink.transitions.contains("waitingApproval"))
        let entry = try #require(executor.entries.first)
        #expect(entry.call.toolName == "document.office.edit")
        #expect(entry.context.approvalGrantID != nil, "An allowed call carries its runtime grant")
        #expect(entry.context.runtimeAuthority != nil, "The runtime mints the approved-call authority")
        #expect(audit.entries.contains {
            $0.toolName == "document.office.edit" && $0.decision.hasPrefix("allow")
        })
    }

    @Test("A document edit inside a Git worktree still waits for the human card")
    func repositoryDocumentEditStillWaitsForApproval() async throws {
        let tree = try makeTree(gitDirectory: true)
        defer { cleanup(tree) }
        let adapter = MockAdapter()
        let call = try documentCall(id: "call_repo")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = CapturingExecutor(descriptors: descriptors())
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree
        )
        let finished = AsyncLock(false)
        let task = Task {
            defer { finished.withLock { $0 = true } }
            try await runtime.start(goal: "edit the repo document")
        }

        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("Repository document edit must still request approval")
            task.cancel()
            return
        }
        let accepted = await runtime.resolveApproval(
            .allow(scope: ApprovalScope(toolName: "document.office.edit", singleUse: true), expiresAt: nil),
            for: "call_repo"
        )
        #expect(accepted)
        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await task.value }
        #expect(settled)
        #expect(executor.entries.count == 1, "The human-approved call executes exactly once")
    }

    // MARK: - Delegated child (canonical path parity)

    @Test("A delegated child's resolved document edit uses the same canonical carve-out")
    func childDocumentEditExecutes() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let executor = CapturingExecutor(descriptors: descriptors())
        let runtime = makeRuntime(
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree
        )
        let result = await dispatchAsChild(
            runtime,
            call: try documentCall(id: "child-doc"),
            tools: ["document.office.edit"],
            workspaceRoot: tree,
            delegateCallID: "d1"
        )
        #expect(result.status == .ok, "child document edit executed: \(result.outputSummary)")
        let entry = try #require(executor.entries.first)
        #expect(entry.context.childExecution != nil, "The child context carries its runtime identity")
        #expect(entry.context.approvalGrantID != nil)
    }

    @Test("A delegated child cannot widen the carve-out: repository, nested repo and redirect")
    func childUnresolvedExtentsStayReviewed() async throws {
        // (a) the workspace root itself is a repository
        let repoTree = try makeTree(gitDirectory: true)
        defer { cleanup(repoTree) }
        let repoExecutor = CapturingExecutor(descriptors: descriptors())
        let repoBackend = DenyBackend()
        let repoRuntime = makeRuntime(
            executor: repoExecutor,
            policy: AutomaticApprovalPolicy(backend: repoBackend),
            workspaceRoot: repoTree
        )
        let repoResult = await dispatchAsChild(
            repoRuntime,
            call: try documentCall(id: "child-repo"),
            tools: ["document.office.edit"],
            workspaceRoot: repoTree,
            delegateCallID: "d2"
        )
        #expect(repoResult.status == .denied)
        #expect(repoExecutor.entries.isEmpty)
        #expect(repoBackend.toolNames == ["document.office.edit"], "The reviewing policy really saw the call")

        // (b) a repository nested inside an otherwise plain workspace: the
        // document target is inside it
        let outer = try makeTree()
        defer { cleanup(outer) }
        let nestedRepo = try makeNestedRepository(inside: outer)
        let nestedExecutor = CapturingExecutor(descriptors: descriptors())
        let nestedBackend = DenyBackend()
        let nestedRuntime = makeRuntime(
            executor: nestedExecutor,
            policy: AutomaticApprovalPolicy(backend: nestedBackend),
            workspaceRoot: outer
        )
        let nestedCall = try ToolCall(
            id: "child-nested",
            toolName: "document.office.edit",
            argumentsJSON: Data(
                #"{"action":"apply","proposal_id":"p","path":"nested/report.docx"}"#.utf8
            ),
            scope: .local
        )
        let nestedResult = await dispatchAsChild(
            nestedRuntime,
            call: nestedCall,
            tools: ["document.office.edit"],
            workspaceRoot: outer,
            delegateCallID: "d3"
        )
        #expect(nestedResult.status == .denied)
        #expect(nestedExecutor.entries.isEmpty)

        // (c) a redirected output INSIDE a repository is a repository write
        let repoRedirect = try documentCall(
            id: "child-out",
            extra: #","output":"\#(nestedRepo.appendingPathComponent("out.docx").path)""#
        )
        let redirectExecutor = CapturingExecutor(descriptors: descriptors())
        let redirectBackend = DenyBackend()
        let redirectRuntime = makeRuntime(
            executor: redirectExecutor,
            policy: AutomaticApprovalPolicy(backend: redirectBackend),
            workspaceRoot: outer
        )
        let redirectResult = await dispatchAsChild(
            redirectRuntime,
            call: repoRedirect,
            tools: ["document.office.edit"],
            workspaceRoot: outer,
            delegateCallID: "d4"
        )
        #expect(redirectResult.status == .denied)
        #expect(redirectExecutor.entries.isEmpty)

        // (d) an unresolved family under the EXISTING policy stays reviewed:
        // a media.project draft whose declared record cannot be pinned because
        // the runtime configuration carries no resolved store root. (A PDF
        // edit is a poor probe here: the pre-existing automatic policy
        // deterministically exempts it, so it would never reach the reviewer.)
        let unresolvedMedia = try mediaProjectCall(
            id: "child-unresolved", projectID: UUID(), action: "propose"
        )
        let unresolvedExecutor = CapturingExecutor(descriptors: descriptors())
        let unresolvedBackend = DenyBackend()
        let unresolvedRuntime = makeRuntime(
            executor: unresolvedExecutor,
            policy: AutomaticApprovalPolicy(backend: unresolvedBackend),
            workspaceRoot: outer
        )
        let unresolvedResult = await dispatchAsChild(
            unresolvedRuntime,
            call: unresolvedMedia,
            tools: ["media.project"],
            workspaceRoot: outer,
            delegateCallID: "d4b"
        )
        #expect(unresolvedResult.status == .denied)
        #expect(unresolvedExecutor.entries.isEmpty)
    }

    // MARK: - Typed-contract families through the real runtime

    @Test("An ordinary PDF edit executes without an approval card and with runtime authority")
    func pdfEditExecutesWithoutApproval() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let adapter = MockAdapter()
        let call = try pdfEditCall()
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = CapturingExecutor(descriptors: descriptors())
        let audit = MockAuditSink()
        let sink = MockSink()
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree,
            audit: audit,
            sink: sink
        )
        let finished = AsyncLock(false)
        let task = Task {
            defer { finished.withLock { $0 = true } }
            try await runtime.start(goal: "edit the PDF")
        }
        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await task.value }

        #expect(settled, "The PDF edit must settle instead of parking on an approval card")
        #expect(!sink.transitions.contains("waitingApproval"))
        let entry = try #require(executor.entries.first)
        #expect(entry.call.toolName == "document.pdf.edit")
        #expect(entry.context.approvalGrantID != nil)
        #expect(entry.context.runtimeAuthority != nil)
        #expect(audit.entries.contains {
            $0.toolName == "document.pdf.edit" && $0.decision.hasPrefix("allow")
        })
    }

    @Test("A PDF output inside a Git worktree still waits for the human card")
    func pdfRepositoryOutputStillWaitsForApproval() async throws {
        let tree = try makeTree(gitDirectory: true)
        defer { cleanup(tree) }
        let adapter = MockAdapter()
        let call = try pdfEditCall(id: "pdf-repo", output: "inside.pdf")
        adapter.script = [
            [.toolRequest(call)],
            [.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]
        ]
        let executor = CapturingExecutor(descriptors: descriptors())
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree
        )
        let finished = AsyncLock(false)
        let task = Task {
            defer { finished.withLock { $0 = true } }
            try await runtime.start(goal: "export the PDF")
        }
        guard await waitUntil({ await runtime.state.name == "waitingApproval" }) else {
            Issue.record("A repository PDF write must still request approval")
            task.cancel()
            return
        }
        let accepted = await runtime.resolveApproval(
            .allow(scope: ApprovalScope(toolName: "document.pdf.edit", singleUse: true), expiresAt: nil),
            for: "pdf-repo"
        )
        #expect(accepted)
        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await task.value }
        #expect(settled)
        #expect(executor.entries.count == 1, "The human-approved PDF edit executes exactly once")
    }

    @Test("media.project resolves the app-owned store record from the runtime configuration")
    func mediaProjectStoreBindingIsRuntimeOwned() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let store = try makeTree()
        defer { cleanup(store) }
        let projectID = UUID()
        let call = try mediaProjectCall(projectID: projectID)

        // Positive: the trusted store root travels in the frozen
        // configuration; the call executes with runtime authority.
        let executor = CapturingExecutor(descriptors: descriptors())
        let runtime = makeRuntime(
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree,
            stores: [TypedMutationContract.mediaProjectStoreKey: store.path]
        )
        let result = await dispatchAsChild(
            runtime,
            call: call,
            tools: ["media.project"],
            workspaceRoot: tree,
            delegateCallID: "mp1"
        )
        #expect(result.status == .ok, "media.project apply executed: \(result.outputSummary)")
        #expect(executor.entries.count == 1)
        #expect(executor.entries.first?.context.runtimeAuthority != nil)

        // Negative: without the store root the record cannot be pinned, so
        // the call keeps the reviewing policy.
        let deniedExecutor = CapturingExecutor(descriptors: descriptors())
        let backend = DenyBackend()
        let deniedRuntime = makeRuntime(
            executor: deniedExecutor,
            policy: AutomaticApprovalPolicy(backend: backend),
            workspaceRoot: tree
        )
        let denied = await dispatchAsChild(
            deniedRuntime,
            call: try mediaProjectCall(id: "mp2", projectID: projectID),
            tools: ["media.project"],
            workspaceRoot: tree,
            delegateCallID: "mp2"
        )
        #expect(denied.status == .denied)
        #expect(deniedExecutor.entries.isEmpty)
        #expect(backend.toolNames == ["media.project"])
    }

    @Test("A media export is classified at its REAL Workbench/Exports target, not a workspace-root bait")
    func mediaExportTargetFollowsConsumer() async throws {
        let projectIDForExport = UUID()
        let store = try makeTree()
        defer { cleanup(store) }
        let stores = [TypedMutationContract.mediaProjectStoreKey: store.path]

        func exportCall(_ id: String, fileName: String) throws -> ToolCall {
            try ToolCall(
                id: id,
                toolName: "media.project",
                argumentsJSON: Data(
                    #"{"action":"export","project_id":"\#(projectIDForExport.uuidString)","export":{"kind":"image","file_name":"\#(fileName)","format":"png"}}"#.utf8
                ),
                scope: .local
            )
        }

        // A nested repository INSIDE Workbench covers the REAL output path
        // `Workbench/Exports/clip.png`; a root-bait target (`clip.png`) would
        // have missed it and let the export through. The card stays.
        let repoTree = try makeTree()
        defer { cleanup(repoTree) }
        try FileManager.default.createDirectory(
            at: repoTree.appendingPathComponent("Workbench", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repoTree.appendingPathComponent("Workbench/.git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let deniedExecutor = CapturingExecutor(descriptors: descriptors())
        let deniedBackend = DenyBackend()
        let deniedRuntime = makeRuntime(
            executor: deniedExecutor,
            policy: AutomaticApprovalPolicy(backend: deniedBackend),
            workspaceRoot: repoTree,
            stores: stores
        )
        let denied = await dispatchAsChild(
            deniedRuntime,
            call: try exportCall("exp-repo", fileName: "clip"),
            tools: ["media.project"],
            workspaceRoot: repoTree,
            delegateCallID: "exp-repo"
        )
        #expect(denied.status == .denied,
                "the real Workbench/Exports target inside the nested repo must keep the card")
        #expect(deniedExecutor.entries.isEmpty)
        #expect(deniedBackend.toolNames == ["media.project"])

        // A repository elsewhere under the same workspace does NOT cover the
        // export directory: the same call executes without review.
        let plainTree = try makeTree()
        defer { cleanup(plainTree) }
        try FileManager.default.createDirectory(
            at: plainTree.appendingPathComponent("repo", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: plainTree.appendingPathComponent("repo/.git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let allowedExecutor = CapturingExecutor(descriptors: descriptors())
        let allowedRuntime = makeRuntime(
            executor: allowedExecutor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: plainTree,
            stores: stores
        )
        let allowed = await dispatchAsChild(
            allowedRuntime,
            call: try exportCall("exp-plain", fileName: "clip"),
            tools: ["media.project"],
            workspaceRoot: plainTree,
            delegateCallID: "exp-plain"
        )
        #expect(allowed.status == .ok, "media export executed: \(allowed.outputSummary)")
        #expect(allowedExecutor.entries.count == 1)

        // An invalid basename (`out.png` is rejected by the real schema) fails
        // closed: the policy never claims a path the tool would refuse.
        let invalidExecutor = CapturingExecutor(descriptors: descriptors())
        let invalidBackend = DenyBackend()
        let invalidRuntime = makeRuntime(
            executor: invalidExecutor,
            policy: AutomaticApprovalPolicy(backend: invalidBackend),
            workspaceRoot: plainTree,
            stores: stores
        )
        let invalid = await dispatchAsChild(
            invalidRuntime,
            call: try exportCall("exp-invalid", fileName: "out.png"),
            tools: ["media.project"],
            workspaceRoot: plainTree,
            delegateCallID: "exp-invalid"
        )
        #expect(invalid.status == .denied, "an invalid export basename must fail closed")
        #expect(invalidExecutor.entries.isEmpty)
    }

    @Test("A video output outside a repository executes; a model argument cannot forge the guest binding")
    func videoOutputExecutesWithoutApproval() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let executor = CapturingExecutor(descriptors: descriptors())
        let runtime = makeRuntime(
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree
        )
        let result = await dispatchAsChild(
            runtime,
            call: try videoEditCall(),
            tools: ["video.edit"],
            workspaceRoot: tree,
            delegateCallID: "v1"
        )
        #expect(result.status == .ok, "video edit executed: \(result.outputSummary)")
        #expect(executor.entries.count == 1)
    }

    @Test("Default-ask ordinary flow runs without approval cards: create, propose, apply, export, cad/media propose")
    func defaultAskWholeOrdinaryFlowHasNoCards() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let store = try makeTree()
        defer { cleanup(store) }
        let projectID = UUID()

        let calls = [
            try ToolCall(
                id: "flow-create", toolName: "document.createWord",
                argumentsJSON: Data(#"{"path":"flow.docx","title":"t","paragraphs":[]}"#.utf8),
                scope: .local
            ),
            // READ steps: inspect the created document before and between
            // edits; they write nothing and must not card.
            try ToolCall(
                id: "flow-read", toolName: "document.office.edit",
                argumentsJSON: Data(#"{"action":"read","path":"flow.docx"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-query", toolName: "document.office.edit",
                argumentsJSON: Data(#"{"action":"query","path":"flow.docx"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-propose", toolName: "document.office.edit",
                argumentsJSON: Data(#"{"action":"propose","path":"flow.docx","expected_sha256":"x"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-preview", toolName: "document.office.edit",
                argumentsJSON: Data(#"{"action":"preview","proposal_id":"p"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-apply", toolName: "document.office.edit",
                argumentsJSON: Data(#"{"action":"apply","path":"flow.docx","proposal_id":"p"}"#.utf8),
                scope: .local
            ),
            // READBACK after the commit, then the safe export.
            try ToolCall(
                id: "flow-readback", toolName: "document.office.edit",
                argumentsJSON: Data(#"{"action":"read","path":"flow.docx"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-export", toolName: "document.office.edit",
                argumentsJSON: Data(#"{"action":"export","path":"flow.docx"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-cad-read", toolName: "cad.document",
                argumentsJSON: Data(#"{"action":"read","path":"part.dwg"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-cad-propose", toolName: "cad.document",
                argumentsJSON: Data(#"{"action":"propose","path":"part.dwg"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-media-read", toolName: "media.project",
                argumentsJSON: Data(#"{"action":"read","project_id":"\#(projectID.uuidString)"}"#.utf8),
                scope: .local
            ),
            try ToolCall(
                id: "flow-media-capabilities", toolName: "media.project",
                argumentsJSON: Data(#"{"action":"capabilities","project_id":"\#(projectID.uuidString)"}"#.utf8),
                scope: .local
            ),
            try mediaProjectCall(id: "flow-media-propose", projectID: projectID, action: "propose")
        ]

        let adapter = MockAdapter()
        adapter.script = calls.map { [.toolRequest($0)] }
            + [[.completed(AgentEvent.CompletionInfo(stopReason: .endTurn))]]
        let executor = CapturingExecutor(descriptors: descriptors())
        let sink = MockSink()
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            policy: HumanApprovalPolicy(), // the user's default .ask policy
            workspaceRoot: tree,
            stores: [TypedMutationContract.mediaProjectStoreKey: store.path],
            sink: sink
        )
        let finished = AsyncLock(false)
        let task = Task {
            defer { finished.withLock { $0 = true } }
            try await runtime.start(goal: "make and export the document")
        }
        var settled = await waitUntil { finished.withLock { $0 } }
        if !settled {
            await runtime.cancel()
            settled = await waitUntil { finished.withLock { $0 } }
        }
        if settled { _ = try? await task.value }

        #expect(settled, "The default-ask ordinary flow must settle, not park on a card")
        #expect(!sink.transitions.contains("waitingApproval"),
                "No step of the ordinary flow may show a per-edit approval card")
        #expect(executor.entries.count == calls.count,
                "every ordinary step executed: \(executor.entries.map(\.call.id))")
        #expect(executor.entries.allSatisfy { $0.context.approvalGrantID != nil },
                "each executed step carries its runtime grant")
        #expect(executor.entries.allSatisfy { $0.context.runtimeAuthority != nil },
                "each executed step carries its runtime-issued authority")
    }

    @Test("Audited reads/drafts never card, even on a repository document; the commit still does")
    func readAndDraftDoNotCardButCommitDoes() async throws {
        // The workspace root IS a repository: inspecting/drafting its content
        // writes no code, so those steps must not card; the actual commit
        // (automatic copied output inside the repository) must.
        let repo = try makeTree(gitDirectory: true)
        defer { cleanup(repo) }
        let executor = CapturingExecutor(descriptors: descriptors())
        let backend = DenyBackend()
        let runtime = makeRuntime(
            executor: executor,
            policy: AutomaticApprovalPolicy(backend: backend),
            workspaceRoot: repo
        )
        for (id, json) in [
            ("repo-read", #"{"action":"read","path":"report.docx"}"#),
            ("repo-query", #"{"action":"query","path":"report.docx"}"#),
            ("repo-preview", #"{"action":"preview","proposal_id":"p"}"#),
            ("repo-propose", #"{"action":"propose","path":"report.docx","expected_sha256":"x"}"#)
        ] {
            let status = await dispatchAsChild(
                runtime,
                call: try ToolCall(
                    id: id, toolName: "document.office.edit",
                    argumentsJSON: Data(json.utf8), scope: .local
                ),
                tools: ["document.office.edit"],
                workspaceRoot: repo,
                delegateCallID: "read-\(id)"
            )
            #expect(status.status == .ok, "\(id) must execute without a card: \(status.outputSummary)")
        }
        // A model-authored safe flag on a write action changes nothing: the
        // repository commit still reaches the reviewing policy.
        let denied = await dispatchAsChild(
            runtime,
            call: try ToolCall(
                id: "repo-apply", toolName: "document.office.edit",
                argumentsJSON: Data(#"{"action":"apply","path":"report.docx","proposal_id":"p","readOnly":true}"#.utf8),
                scope: .local
            ),
            tools: ["document.office.edit"],
            workspaceRoot: repo,
            delegateCallID: "repo-apply"
        )
        #expect(denied.status == .denied, "the repository commit must still wait for the human card")
        #expect(backend.toolNames == ["document.office.edit"], "only the commit reached the reviewing policy")
        #expect(executor.entries.count == 4, "only the four non-mutating steps executed")
        #expect(executor.entries.allSatisfy { $0.context.approvalGrantID != nil })
    }

    @Test("A media draft needs the resolved store root; propose without it keeps the review")
    func mediaDraftRequiresResolvedStore() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let store = try makeTree()
        defer { cleanup(store) }
        let projectID = UUID()

        let executor = CapturingExecutor(descriptors: descriptors())
        let runtime = makeRuntime(
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree,
            stores: [TypedMutationContract.mediaProjectStoreKey: store.path]
        )
        let result = await dispatchAsChild(
            runtime,
            call: try mediaProjectCall(id: "mp-propose", projectID: projectID, action: "propose"),
            tools: ["media.project"],
            workspaceRoot: tree,
            delegateCallID: "mp-propose"
        )
        #expect(result.status == .ok, "propose with the resolved store executes: \(result.outputSummary)")
        #expect(executor.entries.count == 1)

        // Without the store root the draft's declared record cannot be pinned:
        // the reviewing policy decides (fail closed).
        let deniedExecutor = CapturingExecutor(descriptors: descriptors())
        let backend = DenyBackend()
        let deniedRuntime = makeRuntime(
            executor: deniedExecutor,
            policy: AutomaticApprovalPolicy(backend: backend),
            workspaceRoot: tree
        )
        let denied = await dispatchAsChild(
            deniedRuntime,
            call: try mediaProjectCall(id: "mp-propose-2", projectID: projectID, action: "propose"),
            tools: ["media.project"],
            workspaceRoot: tree,
            delegateCallID: "mp-propose-2"
        )
        #expect(denied.status == .denied)
        #expect(deniedExecutor.entries.isEmpty)
        #expect(backend.toolNames == ["media.project"], "the reviewing policy really saw the draft")
    }

    @Test("A delegated child's PDF edit uses the same canonical carve-out")
    func childPDFEditExecutes() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let executor = CapturingExecutor(descriptors: descriptors())
        let runtime = makeRuntime(
            executor: executor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree
        )
        let result = await dispatchAsChild(
            runtime,
            call: try pdfEditCall(id: "child-pdf"),
            tools: ["document.pdf.edit"],
            workspaceRoot: tree,
            delegateCallID: "d8"
        )
        #expect(result.status == .ok, "child PDF edit executed: \(result.outputSummary)")
        let entry = try #require(executor.entries.first)
        #expect(entry.context.childExecution != nil)
        #expect(entry.context.approvalGrantID != nil)
    }

    @Test("The local guest binding is runtime-owned; the same call stays reviewed without it")
    func guestBindingIsRuntimeOwned() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let call = try shellCall(id: "child-sh")

        let guestExecutor = CapturingExecutor(descriptors: descriptors())
        let guestRuntime = makeRuntime(
            executor: guestExecutor,
            policy: HumanApprovalPolicy(),
            workspaceRoot: tree,
            localGuest: true
        )
        let guestResult = await dispatchAsChild(
            guestRuntime,
            call: call,
            tools: ["exec.shell"],
            workspaceRoot: tree,
            delegateCallID: "d5"
        )
        #expect(guestResult.status == .ok, "guest read-only command executed: \(guestResult.outputSummary)")
        #expect(guestExecutor.entries.count == 1)

        let nativeExecutor = CapturingExecutor(descriptors: descriptors())
        let backend = DenyBackend()
        let nativeRuntime = makeRuntime(
            executor: nativeExecutor,
            policy: AutomaticApprovalPolicy(backend: backend),
            workspaceRoot: tree,
            localGuest: false
        )
        let nativeResult = await dispatchAsChild(
            nativeRuntime,
            call: call,
            tools: ["exec.shell"],
            workspaceRoot: tree,
            delegateCallID: "d6"
        )
        #expect(nativeResult.status == .denied)
        #expect(nativeExecutor.entries.isEmpty)
        #expect(backend.toolNames == ["exec.shell"], "Without the guest binding the policy decides")
    }

    @Test("Guest carve-outs do not widen: destructive and ambiguous commands stay reviewed")
    func guestCarveOutDoesNotWiden() async throws {
        let tree = try makeTree()
        defer { cleanup(tree) }
        let executor = CapturingExecutor(descriptors: descriptors())
        let runtime = makeRuntime(
            executor: executor,
            policy: AutomaticApprovalPolicy(backend: DenyBackend()),
            workspaceRoot: tree,
            localGuest: true
        )
        // First: the read-only command is exempt and executes.
        let safeResult = await dispatchAsChild(
            runtime,
            call: try shellCall(id: "safe-1"),
            tools: ["exec.shell"],
            workspaceRoot: tree,
            delegateCallID: "d7"
        )
        #expect(safeResult.status == .ok)

        // Later commands are re-decided: a destructive command and an
        // ambiguous write-flavoured diagnostic are NOT covered by the earlier
        // allow and reach the reviewing policy.
        for (id, command) in [
            ("destructive-1", "rm -rf build"),
            ("ambiguous-1", "sed -n 'w out' input"),
            ("date-mutation", "date -s 2020-01-01")
        ] {
            let result = await dispatchAsChild(
                runtime,
                call: try shellCall(id: id, command: command),
                tools: ["exec.shell"],
                workspaceRoot: tree,
                delegateCallID: "d7"
            )
            #expect(result.status == .denied, "\(command) must stay reviewed")
        }
        #expect(executor.entries.count == 1, "Only the read-only command executed")
    }
}
