// FloeAgentRuntimeTests — fast conversation (.chat) runtime integration.
//
// Pins the RUNTIME half of the chat contract: the frozen `ChatToolPolicy`
// ceiling at BOTH canonical dispatch boundaries (main run and delegated
// child) including descriptor revalidation and frozen catalog identity;
// discovery deriving only from the projected ceiling; the fast-chat brief
// envelope (task-pipeline layers absent, attachment line bounded, prior
// voice note quoted and untrusted); the `verifyFinalAnswer` skip; and the
// frozen `reasoningPolicy` reaching the provider request and the dispatch
// checkpoint. The policy internals live in FloeTools and are tested there.

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

    final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
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
            try await execute(call, expectedAuthorizationIdentity: nil, context: context)
        }

        func execute(
            _ call: ToolCall,
            expectedAuthorizationIdentity: String?,
            context: ToolContext
        ) async throws -> ToolResult {
            try context.cancellation.throwIfCancelled()
            storage.withLock { $0.append(Entry(call: call, context: context)) }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "read ok", outputDigest: "d")
        }
    }

    private static let boundAttachment = UUID()
    private static let boundPath = "Attachments/\(boundAttachment.uuidString)/notes.txt"

    private func descriptor(
        _ name: String,
        riskLabels: Set<RiskLabel>,
        isSideEffecting: Bool = false,
        executionBoundary: ToolExecutionBoundary = .any
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            riskLabels: riskLabels,
            isSideEffecting: isSideEffecting,
            executionBoundary: executionBoundary
        )
    }

    /// A realistic small catalog: the ceiling families plus the neighbours a
    /// fast chat must never reach (discovery names included: they are ordinary
    /// callable descriptors in real runs).
    private func catalog() -> [String: ToolCatalog.Descriptor] {
        [
            "web.search": descriptor("web.search", riskLabels: [.networkAccess]),
            "web.searchAI": descriptor("web.searchAI", riskLabels: [.networkAccess]),
            "web.fetch": descriptor("web.fetch", riskLabels: [.networkAccess]),
            "workspace.readFile": descriptor("workspace.readFile", riskLabels: [.readsFiles]),
            "image.ocr": descriptor("image.ocr", riskLabels: [.readsFiles]),
            "workspace.searchFiles": descriptor("workspace.searchFiles", riskLabels: [.readsFiles]),
            "workspace.listDirectory": descriptor("workspace.listDirectory", riskLabels: [.readsFiles]),
            "workspace.writeFile": descriptor("workspace.writeFile", riskLabels: [.writesFiles], isSideEffecting: true),
            "exec.shell": descriptor("exec.shell", riskLabels: [.executesLocalCode], isSideEffecting: true),
            "notes.read": descriptor("notes.read", riskLabels: [.readsFiles]),
            "tools.search": descriptor("tools.search", riskLabels: []),
            "tools.list": descriptor("tools.list", riskLabels: []),
            "delegate.collaborate": descriptor("delegate.collaborate", riskLabels: [],
                                               isSideEffecting: true, executionBoundary: .childOnly),
        ]
    }

    private func resourceContext() -> ChatToolPolicy.ResourceContext {
        ChatToolPolicy.ResourceContext(
            conversationID: UUID(), boundRelativePaths: [Self.boundPath])
    }

    private func makeRuntime(
        adapter: MockAdapter,
        executor: RecordingExecutor,
        allowedToolNames: Set<String>?,
        chatFastMode: Bool = true,
        chatResourceCeiling: ChatToolPolicy.ResourceContext? = nil,
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
                chatResourceCeiling: chatResourceCeiling,
                reasoningPolicy: reasoningPolicy
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
    }

    private func ordinaryChatAllowed(_ executor: RecordingExecutor) -> Set<String> {
        ChatToolPolicy.allowedToolNames(
            from: executor.allDescriptors, hasResourceContext: true)
    }

    private func completionEvents() -> [AgentEvent] {
        [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
    }

    // MARK: - Execution ceiling (main dispatch)

    @Test("bound attachment reads and public web execute; everything else is denied before effect")
    func mainDispatchCeiling() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        let boundRead = try TestFixtures.toolCall(
            id: "r-1", toolName: "workspace.readFile",
            arguments: #"{"path":"\#(Self.boundPath)"}"#)
        let webRead = try TestFixtures.toolCall(
            id: "w-1", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#)
        let ocrInline = try TestFixtures.toolCall(
            id: "o-1", toolName: "image.ocr", arguments: #"{"imageBase64":"aGVsbG8="}"#)
        let unbound = try TestFixtures.toolCall(
            id: "u-1", toolName: "workspace.readFile", arguments: #"{"path":"private/diary.txt"}"#)
        let write = try TestFixtures.toolCall(
            id: "x-1", toolName: "workspace.writeFile", arguments: #"{"path":"a.md","text":"x"}"#)
        let shell = try TestFixtures.toolCall(
            id: "s-1", toolName: "exec.shell", arguments: #"{"command":"id"}"#)
        let discoveryWiden = try TestFixtures.toolCall(
            id: "d-1", toolName: "workspace.searchFiles", arguments: #"{"query":"notes"}"#)
        adapter.script = [
            [.toolRequest(boundRead), .toolRequest(webRead), .toolRequest(ocrInline)],
            [.toolRequest(unbound), .toolRequest(write), .toolRequest(shell), .toolRequest(discoveryWiden)],
            completionEvents()
        ]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: ordinaryChatAllowed(executor),
            chatResourceCeiling: resourceContext())
        try await runtime.start(goal: "chat: read my attached notes and the web")

        // Allowed family executed.
        #expect(executor.entries.contains { $0.call.id == "r-1" })
        #expect(executor.entries.contains { $0.call.id == "w-1" })
        #expect(executor.entries.contains { $0.call.id == "o-1" })
        // Denied family never reached the executor.
        for deniedID in ["u-1", "x-1", "s-1", "d-1"] {
            #expect(!executor.entries.contains { $0.call.id == deniedID }, Comment(rawValue: deniedID))
        }
        let denialOutputs = adapter.requests[2].toolResults
        for callID in ["u-1", "x-1", "s-1", "d-1"] {
            let denial = try #require(denialOutputs.first { $0.callID == callID })
            #expect(denial.output.contains("fast chat") || denial.output.contains("outside"),
                    "\(callID): \(denial.output)")
        }
        // The offered schemas are the projection: never the denied families.
        let firstSchemas = Set(adapter.requests[0].toolSchemas.map(\.name))
        #expect(firstSchemas.isSubset(of: ordinaryChatAllowed(executor)))
        #expect(firstSchemas.contains("workspace.readFile"))
        #expect(!firstSchemas.contains("exec.shell"))
        #expect(!firstSchemas.contains("workspace.searchFiles"))
        #expect(!firstSchemas.contains("notes.read"))
        #expect(!firstSchemas.contains("workspace.writeFile"))
        // Child-only collaboration tools never enter the chat catalog.
        #expect(!firstSchemas.contains("delegate.collaborate"))
    }

    @Test("no frozen resource context fails the ceiling closed to public web only")
    func noContextFailsClosedToWebOnly() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        let anyRead = try TestFixtures.toolCall(
            id: "r-9", toolName: "workspace.readFile",
            arguments: #"{"path":"\#(Self.boundPath)"}"#)
        let web = try TestFixtures.toolCall(
            id: "w-9", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#)
        adapter.script = [
            [.toolRequest(anyRead), .toolRequest(web)],
            completionEvents()
        ]
        // Even a WIDER allowed-name set cannot re-open file reads: the
        // resource context is the missing proof, and the projection hides
        // file tools when the run has no attachments.
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: ChatToolPolicy.allowedToolNames(
                from: executor.allDescriptors, hasResourceContext: true),
            chatResourceCeiling: nil)
        try await runtime.start(goal: "chat without attachments")
        #expect(!executor.entries.contains { $0.call.id == "r-9" })
        #expect(executor.entries.contains { $0.call.id == "w-9" })
        let schemas = Set(adapter.requests[0].toolSchemas.map(\.name))
        #expect(!schemas.contains("workspace.readFile"))
        #expect(!schemas.contains("image.ocr"))
        #expect(schemas.contains("web.fetch"))
        let denial = try #require(adapter.requests[1].toolResults.first { $0.callID == "r-9" })
        #expect(denial.output.contains("no attached files"), Comment(rawValue: denial.output))
    }

    @Test("descriptor metadata revalidation: an allowed name with forged broad metadata is denied")
    func forgedDescriptorDenied() async throws {
        var descriptors = catalog()
        descriptors["workspace.readFile"] = descriptor(
            "workspace.readFile", riskLabels: [.readsFiles, .networkAccess], isSideEffecting: false)
        let executor = RecordingExecutor(descriptors: descriptors)
        let adapter = MockAdapter()
        let forgedRead = try TestFixtures.toolCall(
            id: "f-1", toolName: "workspace.readFile",
            arguments: #"{"path":"\#(Self.boundPath)"}"#)
        adapter.script = [[.toolRequest(forgedRead)], completionEvents()]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: ordinaryChatAllowed(executor),
            chatResourceCeiling: resourceContext())
        try await runtime.start(goal: "read the attached file")
        #expect(!executor.entries.contains { $0.call.id == "f-1" })
        let schemas = Set(adapter.requests[0].toolSchemas.map(\.name))
        #expect(!schemas.contains("workspace.readFile"))
        let denial = try #require(adapter.requests[1].toolResults.first { $0.callID == "f-1" })
        #expect(denial.output.contains("pure local read"), Comment(rawValue: denial.output))
    }

    @Test("multi-action and host-scope arguments fail closed on a bound path")
    func actionAndScopeDenied() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        let actioned = try TestFixtures.toolCall(
            id: "a-1", toolName: "workspace.readFile",
            arguments: #"{"action":"append","path":"\#(Self.boundPath)"}"#)
        let scoped = try TestFixtures.toolCall(
            id: "a-2", toolName: "workspace.readFile",
            arguments: #"{"path":"\#(Self.boundPath)","scope":{"hostID":"\#(UUID().uuidString)"}}"#)
        adapter.script = [[.toolRequest(actioned), .toolRequest(scoped)], completionEvents()]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: ordinaryChatAllowed(executor),
            chatResourceCeiling: resourceContext())
        try await runtime.start(goal: "touch the attached file")
        #expect(executor.entries.isEmpty)
        let actionDenial = try #require(adapter.requests[1].toolResults.first { $0.callID == "a-1" })
        #expect(actionDenial.output.contains("read action"), Comment(rawValue: actionDenial.output))
        let scopeDenial = try #require(adapter.requests[1].toolResults.first { $0.callID == "a-2" })
        #expect(scopeDenial.output.contains("host scope"), Comment(rawValue: scopeDenial.output))
    }

    // MARK: - Discovery enforcement

    @Test("tools.list inside a fast chat describes only the projected ceiling")
    func discoveryDerivesFromProjectedCeiling() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        let list = try TestFixtures.toolCall(id: "l-1", toolName: "tools.list", arguments: #"{"query":""}"#)
        let widen = try TestFixtures.toolCall(
            id: "l-2", toolName: "exec.shell", arguments: #"{"command":"id"}"#)
        adapter.script = [
            [.toolRequest(list)],
            [.toolRequest(widen)],
            completionEvents()
        ]
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: ordinaryChatAllowed(executor),
            chatResourceCeiling: resourceContext())
        try await runtime.start(goal: "what tools do you have? then run a command")
        // The discovery utility itself answered (it is a runtime built-in),
        // and its output can only name tools inside the projection.
        let listResult = try #require(adapter.requests[1].toolResults.first { $0.callID == "l-1" })
        for outside in ["exec.shell", "workspace.writeFile", "notes.read", "workspace.searchFiles",
                        "workspace.listDirectory", "delegate.collaborate"] {
            #expect(!listResult.output.contains(outside),
                    "discovery leaked \(outside): \(listResult.output.prefix(400))")
        }
        #expect(listResult.output.contains("web.fetch"))
        #expect(listResult.output.contains("workspace.readFile"))
        // Reaching for anything the directory does not advertise is denied.
        #expect(!executor.entries.contains { $0.call.id == "l-2" })
        let widenDenial = try #require(adapter.requests[2].toolResults.first { $0.callID == "l-2" })
        #expect(widenDenial.output.contains("fast chat"), Comment(rawValue: widenDenial.output))
    }

    // MARK: - Child dispatch

    @Test("a delegated call inside a fast chat keeps the same frozen ceiling")
    func childDispatchCeiling() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let runtime = makeRuntime(
            adapter: MockAdapter(), executor: executor,
            allowedToolNames: ordinaryChatAllowed(executor),
            chatResourceCeiling: resourceContext())
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
        for (name, arguments) in [
            ("workspace.writeFile", #"{"path":"a.md","text":"x"}"#),
            ("exec.shell", #"{"command":"id"}"#),
            ("notes.read", "{}"),
            ("workspace.readFile", #"{"path":"private/diary.txt"}"#),
            ("tools.search", #"{"query":"shell"}"#),
            ("delegate.collaborate", "{}"),
        ] {
            let call = try TestFixtures.toolCall(
                id: "child-\(name)", toolName: name, arguments: arguments)
            let result = await runtime.dispatchChildTool(
                call, identity: identity, childContext: await childContext())
            #expect(result.status == .denied, Comment(rawValue: name))
        }
        #expect(executor.entries.isEmpty)
        let boundRead = try TestFixtures.toolCall(
            id: "child-read", toolName: "workspace.readFile",
            arguments: #"{"path":"\#(Self.boundPath)"}"#)
        let ok = await runtime.dispatchChildTool(
            boundRead, identity: identity, childContext: await childContext())
        #expect(ok.status == .ok)
        #expect(executor.entries.first?.call.id == "child-read")
    }

    @Test("a temporary run keeps the stricter public-web ceiling even with both flags set")
    func temporaryCeilingWinsWhenBothFlagsExist() async throws {
        let executor = RecordingExecutor(descriptors: catalog())
        let adapter = MockAdapter()
        let boundRead = try TestFixtures.toolCall(
            id: "t-1", toolName: "workspace.readFile",
            arguments: #"{"path":"\#(Self.boundPath)"}"#)
        let web = try TestFixtures.toolCall(
            id: "t-2", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#)
        adapter.script = [[.toolRequest(boundRead), .toolRequest(web)], completionEvents()]
        // The center never launches a temporary run with both flags; the
        // composition is still pinned to fail closed on the stricter policy.
        let runtime = makeRuntime(
            adapter: adapter, executor: executor,
            allowedToolNames: ordinaryChatAllowed(executor),
            chatResourceCeiling: resourceContext(),
            temporaryReadOnly: true)
        try await runtime.start(goal: "forged temporary chat")
        #expect(!executor.entries.contains { $0.call.id == "t-1" })
        #expect(executor.entries.contains { $0.call.id == "t-2" })
        let schemas = Set(adapter.requests[0].toolSchemas.map(\.name))
        #expect(!schemas.contains("workspace.readFile"))
        let denial = try #require(adapter.requests[1].toolResults.first { $0.callID == "t-1" })
        #expect(denial.output.contains("temporary"), Comment(rawValue: denial.output))
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

    @Test("the fast envelope is conversational, bounded and never re-injects task layers")
    func fastEnvelopeIsBriefBoundedAndQuoted() throws {
        var paths = (1...12).map { "Attachments/att-\($0)/file\($0).txt" }
        paths.insert(Self.boundPath, at: 0)
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
        #expect(fast.contains("# Fast conversation"))
        #expect(fast.contains("conversation, not a task pipeline"))
        // The task-pipeline layers are absent.
        for absent in ["# Operating protocol", "# Capability routing",
                       "# Step settlement protocol", "# Delivering work",
                       "Discovery routing:", "Installed tool groups",
                       "Available workflow guides", "Remembered context",
                       "Project instructions (FLOE.md", "Workspace top-level entries",
                       "Workspace links", "Continue from the next incomplete step"] {
            #expect(!fast.contains(absent), "fast envelope leaked layer: \(absent)")
        }
        // Attachment line is bounded: 8 shown of 13.
        #expect(fast.contains(Self.boundPath))
        #expect(fast.contains("(+5 more)"))
        // Prior voice note is quoted as data and states possible partial hearing.
        #expect(fast.contains("INTERRUPTED"))
        #expect(fast.contains("First part heard. Second 'quoted' tail."))
        #expect(fast.contains("not a new request"))
        // Soul/profile data layers stay (style for conversation).
        #expect(fast.contains("# Interaction style (SOUL.md)"))

        // Completed playbacks carry NO tail quote.
        let completedContext = ConversationRunService.RunContext(
            priorVoicePlayback: VoicePlaybackReceipt(
                runID: UUID(), status: .completed, spokenText: "A whole answer spoken."))
        let completed = ConversationRunService.buildContextMessage(
            completedContext, mode: .chat, toolsAvailable: true, chatFastMode: true)
        #expect(!completed.contains("A whole answer spoken."))
        #expect(completed.contains("played back to the user"))

        // No attachments → honest "no attached files" line, no (+N).
        let empty = ConversationRunService.buildContextMessage(
            ConversationRunService.RunContext(), mode: .chat,
            toolsAvailable: true, chatFastMode: true)
        #expect(empty.contains("no attached files"))

        // Task-mode composition is byte-identical with the flag false.
        let task = ConversationRunService.buildContextMessage(context, mode: .goal)
        #expect(task.contains("# Operating protocol"))
        #expect(task.contains("# Delivering work"))
        #expect(!task.contains("# Fast conversation"))
        // Local fast chat keeps the device contract line and the envelope.
        let localFast = ConversationRunService.buildContextMessage(
            context, mode: .chat, toolsAvailable: true, compactForLocal: true,
            localContextTokens: 128_000, chatFastMode: true)
        #expect(localFast.contains("# Floe local runtime contract"))
        #expect(localFast.contains("# Fast conversation"))
        #expect(!localFast.contains("Callable tools are supplied by the device adapter"))
    }

    @Test("Configuration defaults keep every existing caller on the task path")
    func configurationDefaultsAreSourceCompatible() {
        let provider = TestFixtures.localhostProvider()
        let configuration = FloeAgentRuntime.Configuration(
            provider: provider, model: TestFixtures.testModel(providerID: provider.id))
        #expect(configuration.chatFastMode == false)
        #expect(configuration.chatResourceCeiling == nil)
        #expect(configuration.reasoningPolicy == .modelDefault)
    }
}
