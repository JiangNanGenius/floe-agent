// FloeAgentRuntimeTests — temporary (ephemeral) chat public-web enforcement.
//
// The policy itself lives in FloeTools (`TemporaryChatToolPolicy`) and is
// verified in its own tests. These tests exercise the RUNTIME half of the
// shared contract:
//
//   * `Configuration.temporaryReadOnly` propagates into every main/child call
//     context from immutable runtime authority,
//   * the canonical resolution boundary re-validates the public web tools for
//     the exact descriptor + arguments BEFORE any effect (main run and
//     delegated child), even when a wider name set is supplied,
//   * offered/discovery schemas are the policy's public web projection while
//     execution still uses the ORIGINAL descriptor authorization identity,
//   * an ordinary run and an ordinary read-only child keep their existing
//     private read/write authority when the temporary flag is false.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeProviders
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.TemporaryReadOnly")
struct TemporaryReadOnlyRuntimeTests {
    /// Child dispatch is meaningful only while the parent owns a live run.
    /// Park a real parent tool instead of testing an idle/completed runtime.
    actor ParentExecutionGate {
        private var entered = false
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

    /// Always release the fixture on a throwing #require/failure path so the
    /// test cannot leave an orphaned parent task blocked inside the executor.
    private func withActiveParent(
        runtime: FloeAgentRuntime,
        gate: ParentExecutionGate,
        goal: String,
        body: () async throws -> Void
    ) async throws {
        let parent = Task { try await runtime.start(goal: goal) }
        do {
            for _ in 0..<500 {
                if await gate.isParked() { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let parked = await gate.isParked()
            try #require(parked, "The parent must be executing its real hold tool before child dispatch")
            try await body()
        } catch {
            await gate.open()
            await runtime.cancel()
            _ = try? await parent.value
            throw error
        }
        await gate.open()
        try await parent.value
    }

    final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var call: ToolCall
            var context: ToolContext
            var expectedAuthorizationIdentity: String?
        }

        private let storage = AsyncLock<[Entry]>([])
        private let descriptors: [String: ToolCatalog.Descriptor]
        private let gate: ParentExecutionGate?
        private let gatedCallID: String?

        init(
            descriptors: [String: ToolCatalog.Descriptor],
            gate: ParentExecutionGate? = nil,
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
            storage.withLock {
                $0.append(Entry(
                    call: call, context: context,
                    expectedAuthorizationIdentity: expectedAuthorizationIdentity
                ))
            }
            if call.id == gatedCallID { await gate?.park() }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "read ok", outputDigest: "d")
        }
    }

    private func descriptors() -> [String: ToolCatalog.Descriptor] {
        [
            "web.fetch": .init(
                name: "web.fetch",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "web.search": .init(
                name: "web.search",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "web.searchAI": .init(
                name: "web.searchAI",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "notes.read": .init(
                name: "notes.read",
                riskLabels: [.readsFiles],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "mail.read": .init(
                name: "mail.read",
                riskLabels: [.networkAccess, .accessesCredentials],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "skill.list": .init(
                name: "skill.list",
                riskLabels: [],
                isSideEffecting: false,
                effect: .readOnly
            ),
            "test.write": .init(
                name: "test.write", riskLabels: [.writesFiles], isSideEffecting: true
            ),
            "exec.shell": .init(
                name: "exec.shell", riskLabels: [.executesLocalCode], isSideEffecting: true
            ),
            // Mixed read/write tool: allowed read actions in an ordinary
            // read-only policy, but not part of temporary chat at all.
            "media.models": .init(
                name: "media.models",
                toolDescription: "List, inspect, install or remove media models",
                parametersJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["list","status","install","remove"]}},"required":["action"],"additionalProperties":false}"#,
                riskLabels: [.networkAccess],
                isSideEffecting: true,
                effect: .mutating
            )
        ]
    }

    private func temporaryCeiling(_ executor: RecordingExecutor) -> Set<String> {
        TemporaryChatToolPolicy.allowedToolNames(from: executor.allDescriptors)
    }

    private func makeRuntime(
        adapter: MockAdapter,
        executor: RecordingExecutor,
        allowedToolNames: Set<String>,
        temporaryReadOnly: Bool = true
    ) -> FloeAgentRuntime {
        let provider = TestFixtures.localhostProvider()
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: allowedToolNames,
                ephemeralTransport: temporaryReadOnly,
                publicWebOnly: temporaryReadOnly,
                temporaryReadOnly: temporaryReadOnly
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
    }

    @Test("private reads, writes and executions are denied before the executor and never offered")
    func privateToolsDeniedBeforeEffects() async throws {
        let executor = RecordingExecutor(descriptors: descriptors())
        let ceiling = temporaryCeiling(executor)
        #expect(ceiling == ["web.fetch", "web.search", "web.searchAI"])

        let adapter = MockAdapter()
        let notes = try TestFixtures.toolCall(
            id: "n-1", toolName: "notes.read", arguments: "{}"
        )
        let mail = try TestFixtures.toolCall(
            id: "m-1", toolName: "mail.read", arguments: #"{"action":"message"}"#
        )
        let write = try TestFixtures.toolCall(
            id: "w-1", toolName: "test.write", arguments: #"{"path":"a.md","text":"x"}"#
        )
        let shell = try TestFixtures.toolCall(
            id: "s-1", toolName: "exec.shell", arguments: #"{"command":"id"}"#
        )
        let read = try TestFixtures.toolCall(
            id: "r-1", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#
        )
        adapter.script = [
            [.toolRequest(notes), .toolRequest(mail), .toolRequest(write), .toolRequest(shell)],
            [.toolRequest(read)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        // Deliberately wider than the ceiling: the runtime's canonical
        // temporary policy (not merely the name set) must refuse the private
        // tools.
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            allowedToolNames: ["web.fetch", "web.search", "notes.read", "mail.read", "test.write", "exec.shell"]
        )
        try await runtime.start(goal: "temporary chat: use web.fetch for a public page")

        // Offered schemas contain the public web projection only.
        let firstSchemas = Set((adapter.requests.first?.toolSchemas ?? []).map(\.name))
        #expect(firstSchemas.contains("web.fetch"))
        #expect(!firstSchemas.contains("notes.read"))
        #expect(!firstSchemas.contains("mail.read"))
        #expect(!firstSchemas.contains("test.write"))
        #expect(!firstSchemas.contains("exec.shell"))

        // Denied calls never reached the executor; their real denial flowed
        // back to the model as a tool result.
        #expect(!executor.entries.contains { $0.call.id == "n-1" })
        #expect(!executor.entries.contains { $0.call.id == "m-1" })
        #expect(!executor.entries.contains { $0.call.id == "w-1" })
        #expect(!executor.entries.contains { $0.call.id == "s-1" })
        let deniedResults = adapter.requests[1].toolResults
        for callID in ["n-1", "m-1", "w-1", "s-1"] {
            let denial = try #require(deniedResults.first { $0.callID == callID })
            #expect(denial.output.contains("outside"), "\(callID): \(denial.output)")
        }
        // The public web read executed and carried both temporary boundaries
        // into its context.
        let readEntry = try #require(executor.entries.first { $0.call.id == "r-1" })
        #expect(readEntry.context.temporaryReadOnly)
        #expect(readEntry.context.publicWebOnly)
        #expect(readEntry.context.clientSessionID != nil)
    }

    @Test("a delegated temporary child is denied private reads and mixed-tool writes, and allowed the public web")
    func childDeniedForPrivateReadsAllowedForWeb() async throws {
        let gate = ParentExecutionGate()
        let executor = RecordingExecutor(descriptors: descriptors(), gate: gate, gatedCallID: "temporary-parent-hold")
        let ceiling = temporaryCeiling(executor)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(id: "temporary-parent-hold", toolName: "web.fetch",
                arguments: #"{"url":"https://example.com"}"#))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = makeRuntime(adapter: adapter, executor: executor, allowedToolNames: ceiling)
        func childContext() async -> ToolContext {
            ToolContext(
                runID: await runtime.runID,
                allowedToolNames: [
                    "web.fetch", "web.search", "notes.read", "mail.read",
                    "test.write", "exec.shell", "media.models", "web.searchAI",
                ],
                publicWebOnly: true,
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
                temporaryReadOnly: true
            )
        }
        let identity = ChildExecutionIdentity(
            parentRunID: await runtime.runID, rootTaskID: UUID(), delegateCallID: "d"
        )
        let inactiveRead = try TestFixtures.toolCall(id: "unstarted-child", toolName: "web.fetch",
            arguments: #"{"url":"https://example.com"}"#)
        let inactiveResult = await runtime.dispatchChildTool(inactiveRead, identity: identity, childContext: await childContext())
        #expect(inactiveResult.status == .denied)
        #expect(inactiveResult.outputSummary.contains("owning task is no longer active"))
        #expect(executor.entries.isEmpty)

        try await withActiveParent(runtime: runtime, gate: gate, goal: "keep the temporary parent active for its child") {
            for name in ["notes.read", "mail.read", "test.write", "exec.shell", "media.models"] {
                let arguments: Data = name == "media.models"
                    ? Data(#"{"action":"install"}"#.utf8)
                    : Data("{}".utf8)
                let call = try TestFixtures.toolCall(
                    id: "child-\(name)", toolName: name, arguments: String(decoding: arguments, as: UTF8.self))
                let result = await runtime.dispatchChildTool(
                    call, identity: identity, childContext: await childContext()
                )
                #expect(result.status == .denied, "\(name) must be denied")
                #expect(result.outputSummary.contains("temporary chat"), "\(name): \(result.outputSummary)")
            }
            #expect(executor.entries.map(\.call.id) == ["temporary-parent-hold"])

            let read = try TestFixtures.toolCall(
                id: "cr-1", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#
            )
            let readResult = await runtime.dispatchChildTool(
                read, identity: identity, childContext: await childContext()
            )
            #expect(readResult.status == .ok)
            let entry = try #require(executor.entries.first { $0.call.id == "cr-1" })
            #expect(entry.context.temporaryReadOnly)
            #expect(entry.context.publicWebOnly)
            #expect(entry.context.childExecution != nil)
            #expect(entry.context.clientSessionID?.hasPrefix("child:") == true)

            // The configured Bocha AI-summary search is also a public web tool.
            let aiSearch = try TestFixtures.toolCall(
                id: "ca-1", toolName: "web.searchAI",
                arguments: #"{"query":"weather summary"}"#)
            let aiResult = await runtime.dispatchChildTool(
                aiSearch, identity: identity, childContext: await childContext())
            #expect(aiResult.status == .ok)
            #expect(executor.entries.first { $0.call.id == "ca-1" }?.context.publicWebOnly == true)
        }
        let finishedRead = try TestFixtures.toolCall(id: "finished-child", toolName: "web.fetch",
            arguments: #"{"url":"https://example.com"}"#)
        let finishedResult = await runtime.dispatchChildTool(finishedRead, identity: identity, childContext: await childContext())
        #expect(finishedResult.status == .denied)
        #expect(finishedResult.outputSummary.contains("owning task is no longer active"))
        #expect(!executor.entries.contains { $0.call.id == "finished-child" })
    }

    @Test("a public web read keeps the base authorization identity; the LAN opt-in is denied before effect")
    func publicWebReadKeepsBaseIdentity() async throws {
        let executor = RecordingExecutor(descriptors: descriptors())
        let ceiling = temporaryCeiling(executor)
        let adapter = MockAdapter()
        let allowed = try TestFixtures.toolCall(
            id: "w-1", toolName: "web.fetch", arguments: #"{"url":"https://example.com"}"#
        )
        let lan = try TestFixtures.toolCall(
            id: "w-2", toolName: "web.fetch",
            arguments: #"{"url":"http://192.168.1.1","localNetwork":true}"#
        )
        adapter.script = [
            [.toolRequest(allowed), .toolRequest(lan)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = makeRuntime(adapter: adapter, executor: executor, allowedToolNames: ceiling)
        try await runtime.start(goal: "use web.fetch for a public page")

        // The safe public read executed; the executor was asked to verify the
        // BASE descriptor's authorization identity, never a projected copy's.
        let entry = try #require(executor.entries.first { $0.call.id == "w-1" })
        let baseIdentity = try #require(executor.descriptor(named: "web.fetch")?.authorizationIdentity)
        #expect(entry.expectedAuthorizationIdentity == baseIdentity)
        #expect(entry.context.temporaryReadOnly)
        #expect(entry.context.publicWebOnly)
        // The LAN/diagnostic opt-in was denied before any effect.
        #expect(!executor.entries.contains { $0.call.id == "w-2" })
        let denied = try #require(adapter.requests[1].toolResults.first { $0.callID == "w-2" })
        #expect(denied.output.contains("local-network"))
    }

    @Test("an ordinary run and ordinary child keep private read/write authority when the flag is false")
    func nonTemporaryPathsAreUnaffected() async throws {
        let gate = ParentExecutionGate()
        let executor = RecordingExecutor(descriptors: descriptors(), gate: gate, gatedCallID: "ordinary-parent-hold")
        let allNames = Set(executor.allDescriptors.map(\.name))
        let adapter = MockAdapter()
        let privateRead = try TestFixtures.toolCall(
            id: "n-2", toolName: "notes.read", arguments: "{}"
        )
        let write = try TestFixtures.toolCall(
            id: "w-2", toolName: "test.write", arguments: #"{"path":"a.md","text":"x"}"#
        )
        adapter.script = [
            [.toolRequest(privateRead), .toolRequest(write)],
            [.toolRequest(try TestFixtures.toolCall(id: "ordinary-parent-hold", toolName: "web.fetch",
                arguments: #"{"url":"https://example.com"}"#))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            allowedToolNames: allNames,
            temporaryReadOnly: false
        )
        try await withActiveParent(runtime: runtime, gate: gate, goal: "use notes.read and test.write now") {
            // The ordinary main run executes both; no temporary projection is
            // applied and the schemas stay unchanged.
            #expect(executor.entries.contains { $0.call.id == "n-2" })
            #expect(executor.entries.contains { $0.call.id == "w-2" })
            #expect(executor.entries.first { $0.call.id == "n-2" }?.context.temporaryReadOnly == false)
            let notesSchema = try #require(
                adapter.requests.first?.toolSchemas.first { $0.name == "notes.read" }
            )
            #expect(notesSchema.parametersJSON == executor.descriptor(named: "notes.read")?.parametersJSON)

            // An ordinary delegated child keeps the existing private read path:
            // the temporary policy is keyed strictly off `temporaryReadOnly`.
            let identity = ChildExecutionIdentity(
                parentRunID: await runtime.runID, rootTaskID: UUID(), delegateCallID: "d-ordinary"
            )
            let childContext = ToolContext(
                runID: await runtime.runID,
                allowedToolNames: ["notes.read", "test.write"],
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
                temporaryReadOnly: false
            )
            let childRead = try TestFixtures.toolCall(
                id: "cn-1", toolName: "notes.read", arguments: "{}"
            )
            let childResult = await runtime.dispatchChildTool(
                childRead, identity: identity, childContext: childContext
            )
            #expect(childResult.status == .ok)
            let childEntry = try #require(executor.entries.first { $0.call.id == "cn-1" })
            #expect(childEntry.context.temporaryReadOnly == false)
        }
    }
}
