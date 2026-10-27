// FloeAgentRuntimeTests — fast conversation (.chat) runtime integration.
//
// Pins the RUNTIME half of the chat contract after the chat ceiling lift:
// an ordinary fast chat run offers and executes the SAME authorized
// toolchain as an ordinary task — every tool the run's enabled integrations,
// capability toggles, task policy, skills and provider ceilings already
// allow — with the same progressive tools.search/tools.list discovery (no
// pinned catalog on the wire); explicit per-run denials (allowedToolNames,
// plan mode, the temporary read ceiling) keep denying exactly as before.
// The brief conversational envelope, the verifyFinalAnswer skip and the
// frozen reasoningPolicy are unchanged. The policy internals live in
// FloeTools and are tested there.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ChatModePolicy")
struct ChatModePolicyTests {

    // MARK: - Fixtures

    /// Parks one scripted parent-run execution until the test releases it, so
    /// delegated child calls can be dispatched while the owning run is really
    /// active (the runtime only accepts child dispatch from a live run).
    actor ExecutionSuspensionGate {
        private(set) var entered = false
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func park() async {
            entered = true
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func isParked() -> Bool { entered }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var call: ToolCall
            var context: ToolContext
        }

        private let storage = AsyncLock<[Entry]>([])
        private let descriptors: [String: ToolCatalog.Descriptor]
        private let gate: ExecutionSuspensionGate?
        private let gatedCallID: String?

        init(
            descriptors: [String: ToolCatalog.Descriptor],
            gate: ExecutionSuspensionGate? = nil,
            gatedCallID: String? = nil
        ) {
            self.descriptors = descriptors
            self.gate = gate
            self.gatedCallID = gatedCallID
        }

        var entries: [Entry] { storage.withLock { $0 } }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptors[name] }

        var allDescriptors: [ToolCatalog.Descriptor] {
            descriptors.values.sorted { $0.name < $1.name }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            try await execute(call, expectedAuthorizationIdentity: nil, context: context)
        }

        func execute(
            _ call: ToolCall,
            expectedAuthorizationIdentity: String?,
            context: ToolContext
        ) async throws -> ToolResult {
            try context.cancellation.throwIfCancelled()
            storage.withLock { $0.append(Entry(call: call, context: context)) }
            if call.id == gatedCallID {
                await gate?.park()
            }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "executed ok", outputDigest: "d")
        }
    }

    private func descriptor(
        _ name: String,
        riskLabels: Set<RiskLabel>,
        isSideEffecting: Bool = false,
        effect: ToolEffect? = nil,
        executionBoundary: ToolExecutionBoundary = .any
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            riskLabels: riskLabels,
            isSideEffecting: isSideEffecting,
            effect: effect,
            executionBoundary: executionBoundary
        )
    }

    /// A realistic small catalog spanning the ordinary toolchain: web,
    /// workspace, execution, personal data, discovery helpers, the basic
    /// device reads and a child-only collaboration tool.
    private func catalog() -> [String: ToolCatalog.Descriptor] {
        [
            "web.search": descriptor("web.search", riskLabels: [.networkAccess], effect: .readOnly),
            "web.searchAI": descriptor("web.searchAI", riskLabels: [.networkAccess], effect: .readOnly),
            "web.fetch": descriptor("web.fetch", riskLabels: [.networkAccess], effect: .readOnly),
            "workspace.readFile": descriptor("workspace.readFile", riskLabels: [.readsFiles], effect: .readOnly),
            "workspace.writeFile": descriptor("workspace.writeFile", riskLabels: [.writesFiles],
                                               isSideEffecting: true, effect: .mutating),
            "exec.shell": descriptor("exec.shell", riskLabels: [.executesLocalCode],
                                     isSideEffecting: true, effect: .mutating),
            "notes.read": descriptor("notes.read", riskLabels: [.readsFiles], effect: .readOnly),
            "apple.calendar.list": descriptor("apple.calendar.list", riskLabels: [.persistsPersonalData],
                                              effect: .readOnly),
            "apple.location.current": descriptor("apple.location.current", riskLabels: [],
                                                 effect: .readOnly),
            "tools.search": descriptor("tools.search", riskLabels: []),
            "tools.list": descriptor("tools.list", riskLabels: []),
            "delegate.collaborate": descriptor("delegate.collaborate", riskLabels: [],
                                               isSideEffecting: true,
                                               executionBoundary: .childOnly),
        ]
    }

    private func makeRuntime(
        adapter: MockAdapter,
        executor: RecordingExecutor,
        allowedToolNames: Set<String>?,
        chatFastMode: Bool = true,
        reasoningPolicy: ProviderReasoningPolicy = .modelDefault,
        verifyFinalAnswer: Bool = false,
        temporaryReadOnly: Bool = false
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: allowedToolNames,
                verifyFinalAnswer: verifyFinalAnswer,
                temporaryReadOnly: temporaryReadOnly,
                chatFastMode: chatFastMode,
                reasoningPolicy: reasoningPolicy
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
    }

    private func completionEvents() -> [AgentEvent] {
        [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
    }

    // MARK: - Ordinary chat runs the full authorized toolchain

    @Test("an ordinary chat executes every authorized tool, not a web/file subset")
    func ordinaryChatExecutesAuthorizedCatalog() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        let shell = try TestFixtures.toolCall(
            id: "s-1", toolName: "exec.shell", arguments: #"{"command":"id"}"#)
        let write = try TestFixtures.toolCall(
            id: "w-1", toolName: "workspace.writeFile", arguments: #"{"path":"a.md","text":"x"}"#)
        let webRead = try TestFixtures.toolCall(
            id: "f-1", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#)
        let calendar = try TestFixtures.toolCall(
            id: "c-1", toolName: "apple.calendar.list", arguments: #"{"limit":5}"#)
        adapter.script = [
            [.toolRequest(shell), .toolRequest(write), .toolRequest(webRead), .toolRequest(calendar)],
            completionEvents()
        ]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: Set(executor.allDescriptors.map(\.name)))
        try await runtime.start(goal: "chat: exec.shell workspace.writeFile")

        for id in ["s-1", "w-1", "f-1", "c-1"] {
            #expect(executor.entries.contains { $0.call.id == id }, Comment(rawValue: id))
        }
        // The chat run stays an ordinary boundary: a tool outside the run's
        // explicit allowed set is still denied before any effect.
        let adapter2 = MockAdapter()
        let outsider = try TestFixtures.toolCall(
            id: "o-1", toolName: "exec.shell", arguments: #"{"command":"id"}"#)
        adapter2.script = [[.toolRequest(outsider)], completionEvents()]
        let narrowed = makeRuntime(
            adapter: adapter2, executor: executor,
            allowedToolNames: ["web.fetch"])
        try await narrowed.start(goal: "chat")
        #expect(!executor.entries.contains { $0.call.id == "o-1" })
        let denial = try #require(adapter2.requests[1].toolResults.first { $0.callID == "o-1" })
        #expect(denial.output.contains("outside the active skill capability set"),
                Comment(rawValue: denial.output))
    }

    @Test("chat discovery is progressive like a task: the wire is not the whole catalog")
    func ordinaryChatDiscoveryIsProgressive() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        let search = try TestFixtures.toolCall(
            id: "d-1", toolName: "tools.search", arguments: #"{"queries":["notes"]}"#)
        let loaded = try TestFixtures.toolCall(
            id: "n-1", toolName: "notes.read", arguments: "{}")
        adapter.script = [
            [.toolRequest(search)],
            [.toolRequest(loaded)],
            completionEvents()
        ]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: Set(executor.allDescriptors.map(\.name)))
        try await runtime.start(goal: "chat: exec.shell")

        // First request: goal-matched schemas only. The old fast-chat pin put
        // EVERY offered name on the wire; the lifted catalog must not.
        let firstSchemas = Set(adapter.requests[0].toolSchemas.map(\.name))
        #expect(firstSchemas.contains("exec.shell"))
        #expect(!firstSchemas.contains("notes.read"),
                "notes.read must stay deferred until discovered: \(firstSchemas)")
        #expect(!firstSchemas.contains("delegate.collaborate"),
                "child-only collaboration tools never reach the main-run wire")
        // tools.search itself answered over the full authorized catalog.
        let searchResult = try #require(adapter.requests[1].toolResults.first { $0.callID == "d-1" })
        #expect(searchResult.output.contains("notes.read"))
        // The discovered schema loads for the next request and executes.
        let secondSchemas = Set(adapter.requests[1].toolSchemas.map(\.name))
        #expect(secondSchemas.contains("notes.read"))
        #expect(executor.entries.map(\.call.id) == ["n-1"])
    }

    @Test("a delegated child of an ordinary chat keeps the same authorized boundary")
    func ordinaryChatChildDispatch() async throws {
        let gate = ExecutionSuspensionGate()
        let executor = RecordingExecutor(
            descriptors: catalog(), gate: gate, gatedCallID: "hold")
        let adapter = MockAdapter()
        let hold = try TestFixtures.toolCall(
            id: "hold", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#)
        adapter.script = [[.toolRequest(hold)], completionEvents()]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: Set(executor.allDescriptors.map(\.name)))
        let parentRun = Task {
            try await runtime.start(goal: "hold the chat open for delegation")
        }
        var waited = 0
        while await gate.isParked() == false, waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        #expect(await gate.isParked())
        func childContext() async -> ToolContext {
            ToolContext(
                runID: await runtime.runID,
                allowedToolNames: Set(executor.allDescriptors.map(\.name)),
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
                temporaryReadOnly: false
            )
        }
        let identity = ChildExecutionIdentity(
            parentRunID: await runtime.runID, rootTaskID: UUID(), delegateCallID: "d")
        // An authorized child call executes exactly like a task child.
        let childWrite = try TestFixtures.toolCall(
            id: "child-write", toolName: "workspace.writeFile",
            arguments: #"{"path":"a.md","text":"x"}"#)
        let ok = await runtime.dispatchChildTool(
            childWrite, identity: identity, childContext: await childContext())
        #expect(ok.status == .ok)
        // A child name outside the parent's frozen catalog identity is denied.
        let forgedContext = ToolContext(
            runID: await runtime.runID,
            allowedToolNames: ["credential.read"],
            cancellation: CancellationToken(),
            childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
            temporaryReadOnly: false,
            frozenEffectiveCatalogNames: ["credential.read"]
        )
        let forged = try TestFixtures.toolCall(
            id: "child-forged", toolName: "credential.read", arguments: "{}")
        let denied = await runtime.dispatchChildTool(
            forged, identity: identity, childContext: forgedContext)
        #expect(denied.status == .denied)
        await gate.open()
        try await parentRun.value
    }

    // MARK: - Temporary chat keeps the read ceiling (basic device reads)

    @Test("a temporary chat admits the basic device reads and still denies writes and private reads")
    func temporaryChatAdmitsBasicDeviceReads() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        let calendar = try TestFixtures.toolCall(
            id: "t-cal", toolName: "apple.calendar.list", arguments: #"{"limit":5}"#)
        let location = try TestFixtures.toolCall(
            id: "t-loc", toolName: "apple.location.current", arguments: "{}")
        let locationSpoofed = try TestFixtures.toolCall(
            id: "t-loc-bad", toolName: "apple.location.current",
            arguments: #"{"query":"Sydney"}"#)
        let write = try TestFixtures.toolCall(
            id: "t-write", toolName: "workspace.writeFile",
            arguments: #"{"path":"a.md","text":"x"}"#)
        let notes = try TestFixtures.toolCall(
            id: "t-notes", toolName: "notes.read", arguments: "{}")
        adapter.script = [
            [.toolRequest(calendar), .toolRequest(location), .toolRequest(locationSpoofed),
             .toolRequest(write), .toolRequest(notes)],
            completionEvents()
        ]
        let temporaryCeiling = TemporaryChatToolPolicy.allowedToolNames(
            from: executor.allDescriptors)
        #expect(temporaryCeiling.contains("apple.calendar.list"))
        #expect(temporaryCeiling.contains("apple.location.current"))
        #expect(!temporaryCeiling.contains("notes.read"))
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: temporaryCeiling,
            temporaryReadOnly: true)
        try await runtime.start(goal: "临时聊天：我现在在哪")

        // Approved calls dispatch through the concurrent task group, so the
        // arrival order at the executor boundary is scheduling-dependent (the
        // established convention pins dispatch by call id as a set — cf.
        // TemporaryChatPolicyTests and ToolResultPagingTool's
        // supportsConcurrentBatchDispatch); the denied calls must never reach
        // the executor at all.
        #expect(Set(executor.entries.map(\.call.id)) == ["t-cal", "t-loc"])
        // Exactly-once: a set alone could hide a duplicate dispatch.
        #expect(executor.entries.count == 2)
        let results = adapter.requests[1].toolResults
        let spoofDenial = try #require(results.first { $0.callID == "t-loc-bad" })
        #expect(spoofDenial.output.contains("takes no arguments"), Comment(rawValue: spoofDenial.output))
        let writeDenial = try #require(results.first { $0.callID == "t-write" })
        #expect(writeDenial.output.contains("temporary"), Comment(rawValue: writeDenial.output))
        let notesDenial = try #require(results.first { $0.callID == "t-notes" })
        #expect(notesDenial.output.contains("temporary"), Comment(rawValue: notesDenial.output))
        // The wire advertises exactly the temporary projection plus the
        // always-callable discovery helpers.
        let wireCeiling = temporaryCeiling.union(
            [ToolDiscovery.name, ToolDiscovery.listName, ToolResultPagingTool.name])
        let wireNames = Set(adapter.requests[0].toolSchemas.map(\.name))
            .union(adapter.requests[0].allToolNames)
        #expect(wireNames.isSubset(of: wireCeiling))
        #expect(!wireNames.contains("notes.read"))
        #expect(!wireNames.contains("workspace.writeFile"))
    }

    @Test("a forged basic-device descriptor is denied inside a temporary chat")
    func temporaryChatForgedDeviceDescriptorDenied() async throws {
        var descriptors = catalog()
        descriptors["apple.calendar.list"] = descriptor(
            "apple.calendar.list",
            riskLabels: [.persistsPersonalData, .accessesCredentials],
            effect: .readOnly)
        let executor = RecordingExecutor(descriptors: descriptors)
        let adapter = MockAdapter()
        let forged = try TestFixtures.toolCall(
            id: "t-forged", toolName: "apple.calendar.list", arguments: #"{"limit":5}"#)
        adapter.script = [[.toolRequest(forged)], completionEvents()]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: ["apple.calendar.list", "web.fetch"],
            temporaryReadOnly: true)
        try await runtime.start(goal: "临时聊天：看下日历")
        #expect(executor.entries.isEmpty)
        let denial = try #require(adapter.requests[1].toolResults.first { $0.callID == "t-forged" })
        #expect(denial.output.contains("not a pure on-device read"),
                Comment(rawValue: denial.output))
        let schemas = Set(adapter.requests[0].toolSchemas.map(\.name))
        #expect(!schemas.contains("apple.calendar.list"))
    }

    // MARK: - Verify pass + reasoning policy

    @Test("fast chat never spends the final-answer verification hop; task modes still do")
    func verifyFinalAnswerSkippedForFastChat() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let chatAdapter = MockAdapter()
        chatAdapter.script = [completionEvents()]
        let chatSink = MockSink()
        let provider = TestFixtures.localhostProvider()
        let chatRuntime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: nil,
                verifyFinalAnswer: true,
                chatFastMode: true
            ),
            adapter: chatAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            sink: chatSink
        )
        try await chatRuntime.start(goal: "chat answer")
        #expect(chatAdapter.requests.count == 1)
        #expect(!chatSink.transitions.contains("verifying"))
        #expect(chatSink.verifiedDraftSeals.isEmpty)

        let taskAdapter = MockAdapter()
        taskAdapter.script = [completionEvents(), completionEvents()]
        let taskSink = MockSink()
        let taskRuntime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                verifyFinalAnswer: true,
                chatFastMode: false
            ),
            adapter: taskAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            sink: taskSink
        )
        try await taskRuntime.start(goal: "task answer")
        #expect(taskAdapter.requests.count == 2)
        #expect(taskSink.transitions.contains("verifying"))
    }

    @Test("the frozen reasoningPolicy reaches the provider request and round-trips the checkpoint")
    func reasoningPolicyOnWireAndCheckpoint() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        adapter.script = [completionEvents()]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                chatFastMode: true,
                reasoningPolicy: .disabled
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
        try await runtime.start(goal: "fast answer")
        #expect(adapter.requests.first?.reasoningPolicy == .disabled)

        // The dispatch snapshot already round-trips the knob: a resumed
        // chat run replays `.disabled` without a new decision.
        let snapshot = ProviderDispatchRequestSnapshot(request: try #require(adapter.requests.first))
        #expect(snapshot.reasoningDisabled == true)
        #expect(snapshot.request().reasoningPolicy == .disabled)
        let ordinary = ProviderDispatchRequestSnapshot(request: ProviderStreamRequest(
            provider: provider, model: TestFixtures.testModel(providerID: provider.id)))
        #expect(ordinary.reasoningDisabled == false)
        #expect(ordinary.request().reasoningPolicy == .modelDefault)
    }

    // MARK: - Fast-chat envelope

    @Test("the ordinary fast envelope is conversational and states the full authorized toolchain")
    func ordinaryFastEnvelopeIsFullToolchain() throws {
        var paths = (1...12).map { "Attachments/att-\($0)/file\($0).txt" }
        let receipt = VoicePlaybackReceipt(
            runID: UUID(), status: .interrupted,
            spokenText: "First part heard.\nSecond \"quoted\" tail.")
        let context = ConversationRunService.RunContext(
            workspaceName: "Private Task Workspace",
            availableToolNames: ["web.fetch", "workspace.readFile"],
            skillInstructions: "installed skill body",
            memoryContext: "remembered fact",
            soulContext: "style",
            userProfileContext: "profile",
            workspaceAttachmentPaths: paths,
            workspaceNotes: ["cloud://mount"],
            workspaceListing: "dir1\n",
            projectInstructions: "FLOE.md body",
            priorVoicePlayback: receipt
        )
        let fast = ConversationRunService.buildContextMessage(
            context, mode: .chat, toolsAvailable: true, chatFastMode: true)
        // Brief conversational envelope present.
        #expect(fast.contains("# Conversation"))
        #expect(fast.contains("conversation, not a task pipeline"))
        // The honest capability statement: the ordinary authorized toolset,
        // not the retired public-web/file-only ceiling.
        #expect(fast.contains("the same enabled, permission-authorized toolset as an ordinary task"))
        #expect(fast.contains("tools.search/tools.list"))
        #expect(!fast.contains("Nothing else can run here"))
        // Location honesty: the clock/time zone never implies a place.
        #expect(fast.contains("never infer a place from the time zone"))
        #expect(fast.contains("current-location tool"))
        // The task-pipeline layers are absent.
        for absent in ["# Operating protocol", "# Capability routing",
                       "# Step settlement protocol", "# Delivering work",
                       "Discovery routing:", "Installed tool groups",
                       "Available workflow guides", "Remembered context",
                       "Project instructions (FLOE.md", "Workspace top-level entries",
                       "Workspace links", "Continue from the next incomplete step"] {
            #expect(!fast.contains(absent), "fast envelope leaked layer: \(absent)")
        }
        // Attachment list is bounded: 8 shown of 12.
        #expect(fast.contains("(+4 more)"))
        // Prior voice note is quoted as data and states possible partial hearing.
        #expect(fast.contains("INTERRUPTED"))
        #expect(fast.contains("First part heard. Second 'quoted' tail."))
        #expect(fast.contains("not a new request"))
        // Soul/profile data layers stay (style for conversation).
        #expect(fast.contains("# Interaction style (SOUL.md)"))
    }

    @Test("the temporary fast envelope states the read ceiling and never promises writes")
    func temporaryFastEnvelopeStatesReadCeiling() throws {
        let fast = ConversationRunService.buildContextMessage(
            ConversationRunService.RunContext(), mode: .chat,
            toolsAvailable: true, chatFastMode: true, temporaryReadOnly: true)
        #expect(fast.contains("# Temporary conversation"))
        #expect(fast.contains("basic on-device reads"))
        #expect(fast.contains("calendar events"))
        #expect(fast.contains("current location"))
        #expect(fast.contains("using only permissions already granted"))
        #expect(fast.contains("no writing, executing, installs"))
        #expect(fast.contains("never infer a place from the time zone"))
        #expect(!fast.contains("the same enabled, permission-authorized toolset as an ordinary task"))

        // Task-mode composition is byte-identical with the flags false, and
        // the ordinary envelope never carries the temporary ceiling line.
        let context = ConversationRunService.RunContext(
            workspaceAttachmentPaths: ["Attachments/a/1.txt"])
        let task = ConversationRunService.buildContextMessage(context, mode: .goal)
        #expect(task.contains("# Operating protocol"))
        #expect(task.contains("# Delivering work"))
        #expect(!task.contains("# Conversation"))
        #expect(!task.contains("# Temporary conversation"))
        let ordinary = ConversationRunService.buildContextMessage(
            context, mode: .chat, toolsAvailable: true, chatFastMode: true)
        #expect(!ordinary.contains("Capability ceiling for this temporary conversation"))
        // Local fast chat keeps the device contract line and the envelope.
        let localFast = ConversationRunService.buildContextMessage(
            context, mode: .chat, toolsAvailable: true, compactForLocal: true,
            localContextTokens: 128_000, chatFastMode: true)
        #expect(localFast.contains("# Floe local runtime contract"))
        #expect(localFast.contains("# Conversation"))
        #expect(!localFast.contains("Callable tools are supplied by the device adapter"))
    }

    @Test("Configuration defaults keep every existing caller on the task path")
    func configurationDefaultsAreSourceCompatible() {
        let provider = TestFixtures.localhostProvider()
        let configuration = FloeAgentRuntime.Configuration(
            provider: provider, model: TestFixtures.testModel(providerID: provider.id))
        #expect(configuration.chatFastMode == false)
        #expect(configuration.temporaryReadOnly == false)
        #expect(configuration.reasoningPolicy == .modelDefault)
    }
}
