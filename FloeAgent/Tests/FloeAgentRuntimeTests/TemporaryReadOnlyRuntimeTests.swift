// FloeAgentRuntimeTests — temporary (ephemeral) chat read-only enforcement.
//
// The policy itself lives in FloeTools (`TemporaryChatToolPolicy`) and is
// verified in its own tests. These tests exercise the RUNTIME half of the
// shared contract:
//
//   * `Configuration.temporaryReadOnly` propagates into every main/child call
//     context from immutable runtime authority,
//   * the canonical resolution boundary re-validates the policy for the exact
//     descriptor + arguments BEFORE any effect (main run and delegated child),
//   * offered/discovery schemas are the policy's read-only projections while
//     execution still uses the ORIGINAL descriptor authorization identity,
//   * a verified mixed read/write tool runs a safe read action without
//     demanding a write-only approval and refuses its write actions.

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
    final class RecordingExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var call: ToolCall
            var context: ToolContext
            var expectedAuthorizationIdentity: String?
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
            storage.withLock {
                $0.append(Entry(
                    call: call, context: context,
                    expectedAuthorizationIdentity: expectedAuthorizationIdentity
                ))
            }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "read ok", outputDigest: "d")
        }
    }

    private func descriptors() -> [String: ToolCatalog.Descriptor] {
        [
            "notes.read": .init(name: "notes.read", riskLabels: [], isSideEffecting: false),
            "test.write": .init(
                name: "test.write", riskLabels: [.writesFiles], isSideEffecting: true
            ),
            "exec.shell": .init(
                name: "exec.shell", riskLabels: [.executesLocalCode], isSideEffecting: true
            ),
            // Verified mixed read/write tool: the base descriptor is a real
            // mutating tool; the action policy is the authority.
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
                temporaryReadOnly: temporaryReadOnly
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore()
        )
    }

    @Test("a write outside the temporary read-only ceiling is denied before the executor and never offered")
    func writeDeniedBeforeEffects() async throws {
        let executor = RecordingExecutor(descriptors: descriptors())
        let ceiling = temporaryCeiling(executor)
        #expect(ceiling.contains("notes.read"))
        #expect(ceiling.contains("media.models"))
        #expect(!ceiling.contains("test.write"))
        #expect(!ceiling.contains("exec.shell"))

        let adapter = MockAdapter()
        let write = try TestFixtures.toolCall(
            id: "w-1", toolName: "test.write", arguments: #"{"path":"a.md","text":"x"}"#
        )
        let shell = try TestFixtures.toolCall(
            id: "s-1", toolName: "exec.shell", arguments: #"{"command":"id"}"#
        )
        let read = try TestFixtures.toolCall(id: "r-1", toolName: "notes.read", arguments: "{}")
        adapter.script = [
            [.toolRequest(write), .toolRequest(shell)],
            [.toolRequest(read)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = makeRuntime(adapter: adapter, executor: executor, allowedToolNames: ceiling)
        try await runtime.start(goal: "temporary chat")

        // Offered schemas contain the read-only projection only.
        let firstSchemas = Set((adapter.requests.first?.toolSchemas ?? []).map(\.name))
        #expect(!firstSchemas.contains("test.write"))
        #expect(!firstSchemas.contains("exec.shell"))

        // Denied calls never reached the executor; their real denial flowed
        // back to the model as a tool result.
        #expect(!executor.entries.contains { $0.call.id == "w-1" })
        #expect(!executor.entries.contains { $0.call.id == "s-1" })
        let deniedResults = adapter.requests[1].toolResults
        // The canonical boundary denies both (the run's effective ceiling and
        // the temporary read-only policy fail closed before any effect); the
        // real denial reason flows back as the tool result.
        let writeDenial = try #require(deniedResults.first { $0.callID == "w-1" })
        let shellDenial = try #require(deniedResults.first { $0.callID == "s-1" })
        #expect(writeDenial.output.contains("outside"))
        #expect(shellDenial.output.contains("outside"))
        // The safe read executed and carried the temporary flag into its
        // context.
        let readEntry = try #require(executor.entries.first { $0.call.id == "r-1" })
        #expect(readEntry.context.temporaryReadOnly)
        #expect(readEntry.context.clientSessionID != nil)
    }

    @Test("a delegated child of a temporary run is denied a write and a mixed-tool write action, and allowed a read")
    func childDeniedForWriteAllowedForRead() async throws {
        let executor = RecordingExecutor(descriptors: descriptors())
        let ceiling = temporaryCeiling(executor)
        let runtime = makeRuntime(
            adapter: MockAdapter(), executor: executor, allowedToolNames: ceiling
        )
        func childContext() async -> ToolContext {
            ToolContext(
                runID: await runtime.runID,
                allowedToolNames: ceiling,
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
                temporaryReadOnly: true
            )
        }
        let identity = ChildExecutionIdentity(
            parentRunID: await runtime.runID, rootTaskID: UUID(), delegateCallID: "d"
        )
        let write = try TestFixtures.toolCall(
            id: "cw-1", toolName: "test.write", arguments: #"{"path":"a.md","text":"x"}"#
        )
        let install = try TestFixtures.toolCall(
            id: "ci-1", toolName: "media.models", arguments: #"{"action":"install"}"#
        )
        let writeResult = await runtime.dispatchChildTool(
            write, identity: identity, childContext: await childContext()
        )
        #expect(writeResult.status == .denied)
        let installResult = await runtime.dispatchChildTool(
            install, identity: identity, childContext: await childContext()
        )
        #expect(installResult.status == .denied)
        #expect(installResult.outputSummary.contains("install"))
        #expect(executor.entries.isEmpty)

        let read = try TestFixtures.toolCall(id: "cr-1", toolName: "notes.read", arguments: "{}")
        let readResult = await runtime.dispatchChildTool(
            read, identity: identity, childContext: await childContext()
        )
        #expect(readResult.status == .ok)
        let entry = try #require(executor.entries.first { $0.call.id == "cr-1" })
        #expect(entry.context.temporaryReadOnly)
        #expect(entry.context.childExecution != nil)
        #expect(entry.context.clientSessionID?.hasPrefix("child:") == true)
    }

    @Test("a mixed tool's safe read action executes with the base authorization identity and a narrowed schema")
    func mixedActionReadKeepsBaseIdentity() async throws {
        let executor = RecordingExecutor(descriptors: descriptors())
        let ceiling = temporaryCeiling(executor)
        let adapter = MockAdapter()
        let allowed = try TestFixtures.toolCall(
            id: "m-1", toolName: "media.models", arguments: #"{"action":"status"}"#
        )
        let forbidden = try TestFixtures.toolCall(
            id: "m-2", toolName: "media.models", arguments: #"{"action":"remove"}"#
        )
        adapter.script = [
            [.toolRequest(allowed), .toolRequest(forbidden)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = makeRuntime(adapter: adapter, executor: executor, allowedToolNames: ceiling)
        // The goal names the mixed tool so discovery loads its narrowed
        // schema on this turn.
        try await runtime.start(goal: "inspect media.models status")

        // The offered schema is the policy's narrowed projection: the write
        // actions are not advertised at all.
        let modelsSchema = try #require(
            adapter.requests.first?.toolSchemas.first { $0.name == "media.models" }
        )
        #expect(modelsSchema.parametersJSON.contains("list"))
        #expect(modelsSchema.parametersJSON.contains("status"))
        #expect(!modelsSchema.parametersJSON.contains("install"))
        #expect(!modelsSchema.parametersJSON.contains("remove"))

        // The safe read executed; the executor was asked to verify the BASE
        // descriptor's authorization identity, never a projected copy's.
        let entry = try #require(executor.entries.first { $0.call.id == "m-1" })
        let baseIdentity = try #require(executor.descriptor(named: "media.models")?.authorizationIdentity)
        #expect(entry.expectedAuthorizationIdentity == baseIdentity)
        #expect(entry.context.temporaryReadOnly)
        // The forbidden action was denied before any effect.
        #expect(!executor.entries.contains { $0.call.id == "m-2" })
        let denied = try #require(adapter.requests[1].toolResults.first { $0.callID == "m-2" })
        #expect(denied.output.contains("Denied"))
        #expect(denied.output.contains("remove"))
    }

    @Test("a temporary run without the flag never applies the read-only projection")
    func nonTemporaryRunIsUnaffected() async throws {
        let executor = RecordingExecutor(descriptors: descriptors())
        let adapter = MockAdapter()
        let write = try TestFixtures.toolCall(
            id: "w-2", toolName: "test.write", arguments: #"{"path":"a.md","text":"x"}"#
        )
        adapter.script = [
            [.toolRequest(write)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = makeRuntime(
            adapter: adapter,
            executor: executor,
            allowedToolNames: Set(executor.allDescriptors.map(\.name)),
            temporaryReadOnly: false
        )
        try await runtime.start(goal: "use test.write now")
        // The ordinary run executes the write normally and the schema is not
        // narrowed.
        #expect(executor.entries.contains { $0.call.id == "w-2" })
        #expect(executor.entries.first { $0.call.id == "w-2" }?.context.temporaryReadOnly == false)
        let schema = try #require(
            adapter.requests.first?.toolSchemas.first { $0.name == "test.write" }
        )
        #expect(schema.parametersJSON == executor.descriptor(named: "test.write")?.parametersJSON)
    }
}
