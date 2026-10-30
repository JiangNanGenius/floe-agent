// FloeAgentRuntimeTests — effective-permission subagents, canonical child
// dispatch routing and same-root sibling collaboration.

import Foundation
import Testing
import FloeCore
import FloeModels
@testable import FloeProviders
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.SubagentExecution")
struct SubagentExecutionTests {
    // MARK: - Harness

    /// Records every dispatch the child routes through the canonical seam.
    final class RecordingDispatcher: @unchecked Sendable {
        private let storage = AsyncLock<[(call: ToolCall, context: ToolContext)]>([])
        var calls: [ToolCall] { storage.withLock { $0.map(\.call) } }
        var contexts: [ToolContext] { storage.withLock { $0.map(\.context) } }
        var results: [String: ToolResult] = [:]

        func dispatch(_ call: ToolCall, context: ToolContext) async -> ToolResult {
            storage.withLock { $0.append((call, context)) }
            return results[call.id] ?? ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "dispatched",
                outputDigest: "d"
            )
        }
    }

    private func makeRunner(
        adapter: MockAdapter,
        executor: any ToolExecutor = MockExecutor(),
        provider: ProviderProfile = TestFixtures.localhostProvider(),
        model: ModelProfile? = nil
    ) -> SubagentRunner {
        SubagentRunner(
            provider: provider,
            model: model ?? TestFixtures.testModel(providerID: provider.id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor
        )
    }

    /// A model whose REAL context window is explicit, so request-budget tests
    /// never fall back to a default window that hides the behavior.
    private func model(
        providerID: UUID,
        contextTokens: Int,
        maxOutputTokens: Int
    ) -> ModelProfile {
        var profile = TestFixtures.testModel(providerID: providerID)
        profile.limits = ModelLimits(
            contextTokens: contextTokens,
            maxOutputTokens: maxOutputTokens
        )
        return profile
    }

    private func budgetContext() -> ChildBudgetContext {
        ChildBudgetContext(maximumIterations: 6, reserve: { true }, finish: {})
    }

    private func handoff(
        identity: ChildExecutionIdentity,
        dispatcher: RecordingDispatcher,
        bus: SubagentPeerBus
    ) -> ChildExecutionHandoff {
        ChildExecutionHandoff(
            identity: identity,
            dispatcher: ChildToolDispatcher(
                descriptorProvider: { _ in nil },
                allDescriptors: { [] },
                dispatch: { call, context in
                    await dispatcher.dispatch(call, context: context)
                }
            ),
            peers: bus.handle(for: identity)
        )
    }

    private func childContext(
        identity: ChildExecutionIdentity,
        dispatcher: RecordingDispatcher,
        bus: SubagentPeerBus,
        allowedToolNames: Set<String>? = nil
    ) -> ToolContext {
        ToolContext(
            runID: identity.parentRunID,
            scope: .local,
            allowedToolNames: allowedToolNames,
            cancellation: CancellationToken(),
            childBudget: budgetContext(),
            conversationID: identity.rootTaskID,
            childExecution: handoff(identity: identity, dispatcher: dispatcher, bus: bus)
        )
    }

    // MARK: - Classification and schema ceiling

    @Test("delegate is effectful, main-run only and parallel-safe, and offers execute")
    func delegateClassification() {
        #expect(DelegateTool.isSideEffecting)
        #expect(DelegateTool.toolEffect == .mutating)
        #expect(DelegateTool.executionBoundary == .mainRunOnly)
        #expect(DelegateTool.supportsConcurrentBatchDispatch)
        #expect(DelegateTool.parametersJSON.contains("\"explore\", \"research\", \"execute\""))
        #expect(DelegateTool.riskLabels.contains(.writesFiles))
        #expect(DelegateTool.riskLabels.contains(.executesLocalCode))
    }

    @Test("the child-only peer tools are child-only and bounded")
    func peerToolClassification() {
        #expect(DelegatePeersTool.executionBoundary == .childOnly)
        #expect(DelegateMessageTool.executionBoundary == .childOnly)
    }

    @Test("every kind inherits the parent ceiling with a canonical handoff; delegate stays main-only")
    func schemaCeilingsByKind() async throws {
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        executor.descriptors["test.write"] = .init(name: "test.write", riskLabels: [], isSideEffecting: true)
        executor.descriptors["delegate"] = .init(
            name: "delegate", riskLabels: [], isSideEffecting: true,
            executionBoundary: .mainRunOnly
        )
        executor.descriptors["delegate.peers"] = .init(
            name: "delegate.peers", riskLabels: [], isSideEffecting: false,
            executionBoundary: .childOnly
        )
        let runID = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: UUID(), delegateCallID: "d")
        let dispatcher = RecordingDispatcher()
        let ceiling: Set<String> = ["test.echo", "test.write", "delegate", "delegate.peers"]

        // Canonical handoff: the SAME effective ceiling for every kind, but
        // schemas load progressively inside the child. The first request
        // carries the stable seed plus the child-only sibling tools; the
        // parent's write capability is reachable through the child's own
        // discovery, and `delegate` never appears for any kind.
        for kind in [SubagentRequest.Kind.explore, .research, .execute] {
            let adapter = MockAdapter()
            let search = try TestFixtures.toolCall(
                id: "search-\(kind.rawValue)", toolName: "tools.search",
                arguments: #"{"queries":["test.write"]}"#
            )
            adapter.script = [
                [.toolRequest(search)],
                [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
            ]
            _ = try await makeRunner(adapter: adapter, executor: executor).runStructured(
                SubagentRequest(task: "work", kind: kind, runID: runID),
                context: childContext(
                    identity: identity, dispatcher: dispatcher, bus: bus,
                    allowedToolNames: ceiling
                )
            )
            let first = try #require(adapter.requests.first?.toolSchemas.map(\.name))
            #expect(first.contains("tools.search"), "\(kind) needs discovery")
            #expect(first.contains("tools.list"), "\(kind) needs discovery")
            #expect(first.contains("delegate.peers"), "\(kind) is a child and may coordinate")
            #expect(!first.contains("delegate"), "\(kind) must never see main-only delegation")
            #expect(!first.contains("test.write"), "\(kind) starts from the bounded seed, not the whole catalog")
            // The child's own tools.search really loads the parent's write
            // capability for the next request — the ceiling is inherited, the
            // schema is deferred.
            let second = try #require(adapter.requests.last?.toolSchemas.map(\.name))
            #expect(second.contains("test.write"), "\(kind) must be able to load the parent write ceiling")
            #expect(!second.contains("delegate"), "\(kind) must never see main-only delegation")
        }

        // A read-only parent task keeps a write-free ceiling for every kind:
        // the child inherits the ceiling, it does not expand it, and a search
        // for a tool outside the ceiling loads nothing.
        let readOnlyAdapter = MockAdapter()
        let search = try TestFixtures.toolCall(
            id: "search-ro", toolName: "tools.search",
            arguments: #"{"queries":["test.write"]}"#
        )
        readOnlyAdapter.script = [
            [.toolRequest(search)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        _ = try await makeRunner(adapter: readOnlyAdapter, executor: executor).runStructured(
            SubagentRequest(task: "read", kind: .explore, runID: runID),
            context: childContext(
                identity: identity, dispatcher: dispatcher, bus: bus,
                allowedToolNames: ["test.echo"]
            )
        )
        let readOnlySchemas = readOnlyAdapter.requests.compactMap { $0.toolSchemas.map(\.name) }
        #expect(readOnlySchemas.allSatisfy { !$0.contains("test.write") })

        // Legacy (no canonical handoff): fail-closed read-only ceiling, still
        // with progressive discovery.
        let legacyAdapter = MockAdapter()
        legacyAdapter.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        var legacyContext = ToolContext(runID: runID, cancellation: CancellationToken())
        legacyContext.childBudget = budgetContext()
        _ = try await makeRunner(adapter: legacyAdapter, executor: executor).runStructured(
            SubagentRequest(task: "inspect", kind: .execute, runID: runID),
            context: legacyContext
        )
        let legacySchemas = try #require(legacyAdapter.requests.first?.toolSchemas.map(\.name))
        #expect(!legacySchemas.contains("test.write"))
        #expect(!legacySchemas.contains("delegate"))
        #expect(legacySchemas.contains("tools.search"))
    }

    @Test("a main run never sees the child-only peer tools")
    func mainRunSchemaExcludesChildOnly() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        executor.descriptors["delegate.peers"] = .init(
            name: "delegate.peers", riskLabels: [], isSideEffecting: false,
            executionBoundary: .childOnly
        )
        let runner = makeRunner(adapter: adapter, executor: executor)
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = budgetContext()
        _ = try await runner.runStructured(
            SubagentRequest(task: "read", kind: .execute, runID: UUID()),
            context: context
        )
        let schemas = try #require(adapter.requests.first?.toolSchemas.map(\.name))
        #expect(!schemas.contains("delegate.peers"))
        // Progressive discovery: the first request carries the stable seed;
        // the read-only tool is reachable through the child's own search.
        #expect(schemas.contains("tools.search"))
        #expect(!schemas.contains("test.echo"))
    }

    // MARK: - Canonical dispatcher routing

    @Test("child calls route through the canonical dispatcher for every kind, never the raw executor")
    func childCallsRouteThroughDispatcher() async throws {
        let runID = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: UUID(), delegateCallID: "d")
        // explore / research must dispatch a mutating call too: the kind is a
        // focus hint, so the parent's effective permission is what decides.
        for kind in [SubagentRequest.Kind.explore, .research, .execute] {
            let adapter = MockAdapter()
            let write = try TestFixtures.toolCall(
                id: "w-1", toolName: "test.write", arguments: #"{"path":"a.md","text":"x"}"#
            )
            adapter.script = [
                [.toolRequest(write)],
                [.textDelta(.init(text: "written")), .completed(.init(stopReason: .endTurn))]
            ]
            let executor = MockExecutor()
            executor.descriptors["test.write"] = .init(name: "test.write", riskLabels: [], isSideEffecting: true)
            let runner = makeRunner(adapter: adapter, executor: executor)
            let dispatcher = RecordingDispatcher()
            let outcome = try await runner.runStructured(
                SubagentRequest(task: "write", kind: kind, runID: runID),
                context: childContext(
                    identity: identity, dispatcher: dispatcher, bus: bus,
                    allowedToolNames: ["test.write"]
                )
            )
            #expect(outcome.status == .completed, "\(kind)")
            #expect(dispatcher.calls.map(\.id) == ["w-1"], "\(kind) must dispatch through the canonical seam")
            #expect(executor.executedCalls.isEmpty, "\(kind) must never touch the raw registry")
            let dispatchedContext = try #require(dispatcher.contexts.first)
            #expect(dispatchedContext.childExecution?.identity == identity)
            #expect(adapter.requests.last?.toolResults.first?.output == "dispatched")
        }
    }

    @Test("a legacy child without a retention receipt sends its admitted body but invents no pageable ref")
    func childWireSendsAdmittedBodyWithoutInventingRetention() async throws {
        let runID = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: UUID(), delegateCallID: "d")
        let provider = TestFixtures.localhostProvider()
        // 1M tokens easily carries 160 KiB; 16K tokens absolutely does not.
        // Both are explicit real limits, never the legacy fixed 96 KiB cap.
        let largeModel = model(
            providerID: provider.id, contextTokens: 1_000_000, maxOutputTokens: 8_192
        )
        let smallModel = model(
            providerID: provider.id, contextTokens: 16_384, maxOutputTokens: 2_048
        )
        let call = try TestFixtures.toolCall(
            id: "large-child-result", toolName: "test.echo", arguments: "{}"
        )
        let body = "HEAD-" + String(repeating: "Z", count: 160 * 1_024) + "-TAIL"

        for (profile, expectFull) in [(largeModel, true), (smallModel, false)] {
            let adapter = MockAdapter()
            adapter.script = [
                [.toolRequest(call)],
                [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
            ]
            let executor = MockExecutor()
            executor.descriptors["test.echo"] = .init(
                name: "test.echo", riskLabels: [], isSideEffecting: false
            )
            let dispatcher = RecordingDispatcher()
            dispatcher.results[call.id] = ToolResult(
                callID: call.id,
                status: .ok,
                outputSummary: "bounded child summary",
                outputDigest: "d",
                capturedOutput: body
            )
            let runner = makeRunner(
                adapter: adapter, executor: executor, provider: provider, model: profile
            )
            let outcome = try await runner.runStructured(
                SubagentRequest(task: "read", kind: .explore, runID: runID),
                context: childContext(
                    identity: identity, dispatcher: dispatcher, bus: bus,
                    allowedToolNames: ["test.echo"]
                )
            )
            #expect(outcome.status == .completed, "\(expectFull)")
            let request = try #require(adapter.requests.last)
            let wire = try #require(request.toolResults.first)
            #expect(wire.callID == call.id)
            // The ACTUAL outgoing request stays inside this model's real
            // window (not a fixed constant) for both directions.
            let ceiling = SubagentRunner.requestContextByteCeiling(model: profile)
            #expect(SubagentRunner.contextWireBytes(of: request) <= ceiling)
            if expectFull {
                #expect(wire.output.utf8.count > 150 * 1_024)
                #expect(wire.output == body)
                #expect(!wire.output.contains("truncated for this request"))
            } else {
                #expect(wire.output.contains("truncated for this request"))
                // No canonical dispatcher retained this body, so there is no
                // real receipt and the child must not advertise one.
                #expect(wire.output.contains("no capture ref is available"))
                #expect(!wire.output.contains("ref=tr_"))
                #expect(!wire.output.contains("complete retained output ref"))
                #expect(wire.output.utf8.count < body.utf8.count)
            }
            // Selection never re-executes the tool to produce evidence.
            #expect(dispatcher.calls.map(\.id) == [call.id])
        }
    }

    @Test("the child wire advertises the ACTUAL retained receipt ref, which really pages the store")
    func childWireUsesActualRetainedReceipt() async throws {
        let runID = UUID()
        let rootTaskID = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: rootTaskID, delegateCallID: "d"
        )
        let provider = TestFixtures.localhostProvider()
        // A 12K-token window (about 30 KB of wire) cannot carry this 60 KB
        // body whole, so the planner must truly excerpt it.
        let profile = model(
            providerID: provider.id, contextTokens: 12_288, maxOutputTokens: 2_048
        )
        let call = try TestFixtures.toolCall(
            id: "retained-child-result", toolName: "test.echo", arguments: "{}"
        )
        let body = "HEAD-" + String(repeating: "R", count: 60 * 1_024) + "-TAIL-RECEIPT"
        // A REAL store record under the child's own namespace, never a
        // guessed hash of the parent run id.
        let store = ToolResultCaptureStore(durableRoot: nil)
        let receipt = await store.capture(
            conversationID: rootTaskID, runID: identity.childID,
            callID: call.id, toolName: call.toolName, status: "ok",
            text: body, temporary: false
        )
        #expect(receipt.retained)
        #expect(receipt.ref == ToolResultCaptureStore.reference(
            runID: identity.childID, callID: call.id
        ))

        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(
            name: "test.echo", riskLabels: [], isSideEffecting: false
        )
        let dispatcher = RecordingDispatcher()
        dispatcher.results[call.id] = ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "bounded child summary",
            outputDigest: "d",
            capturedOutput: body,
            captureInfo: ToolResultCaptureInfo(
                ref: receipt.ref,
                originalBytes: receipt.totalBytes,
                retainedBytes: receipt.retainedBytes,
                retentionTruncated: receipt.retentionTruncated,
                executionReportedTruncation: receipt.executionReportedTruncation,
                available: receipt.retained
            )
        )
        let runner = makeRunner(
            adapter: adapter, executor: executor, provider: provider, model: profile
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "read", kind: .explore, runID: runID),
            context: childContext(
                identity: identity, dispatcher: dispatcher, bus: bus,
                allowedToolNames: ["test.echo"]
            )
        )
        #expect(outcome.status == .completed)
        let request = try #require(adapter.requests.last)
        let wire = try #require(request.toolResults.first)
        #expect(wire.output.contains("truncated for this request"))
        #expect(wire.output.contains("ref=\(receipt.ref)"))
        #expect(!wire.output.contains("NOT retained"))
        // The advertised ref is backed by the real store bytes (the body was
        // retained whole here), not merely a formatted string.
        guard case .page(let page) = await store.page(
            conversationID: rootTaskID, ref: receipt.ref, offset: 0,
            maxBytes: ToolResultPagingTool.maximumPageBytes
        ) else {
            Issue.record("the advertised receipt ref must page the real store record")
            return
        }
        #expect(page.totalBytes == body.utf8.count)
        #expect(body.hasPrefix(page.text))
        let tailOffset = body.utf8.count - 64
        guard case .page(let tail) = await store.page(
            conversationID: rootTaskID, ref: receipt.ref, offset: tailOffset,
            maxBytes: 64
        ) else {
            Issue.record("the advertised receipt ref must page the retained tail")
            return
        }
        #expect(tail.text == String(body.suffix(64)))
        #expect(dispatcher.calls.map(\.id) == [call.id])
    }

    @Test("a retention-truncated child capture never sends or advertises the unretained tail")
    func childWireClipsUnretainedTailAndReportsTruncation() async throws {
        let runID = UUID()
        let rootTaskID = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: rootTaskID, delegateCallID: "d"
        )
        let provider = TestFixtures.localhostProvider()
        // The clipped 4 KB prefix fits this large window, so the result is
        // sent "complete": the truncation note must still be present.
        let profile = model(
            providerID: provider.id, contextTokens: 32_768, maxOutputTokens: 8_192
        )
        let call = try TestFixtures.toolCall(
            id: "truncated-child-result", toolName: "test.echo", arguments: "{}"
        )
        let body = "HEAD-" + String(repeating: "T", count: 30_000) + "-UNRETAINED-TAIL"
        let store = ToolResultCaptureStore(
            durableRoot: nil,
            caps: .init(perResultBytes: 4_096, perTaskBytes: 1_048_576, perTaskResults: 64)
        )
        let receipt = await store.capture(
            conversationID: rootTaskID, runID: identity.childID,
            callID: call.id, toolName: call.toolName, status: "ok",
            text: body, temporary: false
        )
        #expect(receipt.retentionTruncated)
        #expect(receipt.retainedBytes == 4_096)

        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(
            name: "test.echo", riskLabels: [], isSideEffecting: false
        )
        let dispatcher = RecordingDispatcher()
        dispatcher.results[call.id] = ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "bounded child summary",
            outputDigest: "d",
            capturedOutput: body,
            captureInfo: ToolResultCaptureInfo(
                ref: receipt.ref,
                originalBytes: receipt.totalBytes,
                retainedBytes: receipt.retainedBytes,
                retentionTruncated: receipt.retentionTruncated,
                executionReportedTruncation: receipt.executionReportedTruncation,
                available: receipt.retained
            )
        )
        let runner = makeRunner(
            adapter: adapter, executor: executor, provider: provider, model: profile
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "read", kind: .explore, runID: runID),
            context: childContext(
                identity: identity, dispatcher: dispatcher, bus: bus,
                allowedToolNames: ["test.echo"]
            )
        )
        #expect(outcome.status == .completed)
        let wire = try #require(adapter.requests.last?.toolResults.first)
        #expect(wire.output.contains("retention truncated"))
        #expect(wire.output.contains("ref=\(receipt.ref)"))
        #expect(!wire.output.contains("UNRETAINED-TAIL"))
        #expect(wire.output.utf8.count < body.utf8.count)
        #expect(dispatcher.calls.map(\.id) == [call.id])
    }

    @Test("a tools.readResult page is pointer-only, never partially cut, when the small window cannot carry it")
    func childPagingPageIsNeverPartiallyCut() async throws {
        let runID = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: UUID(), delegateCallID: "d")
        let provider = TestFixtures.localhostProvider()
        let smallModel = model(
            providerID: provider.id, contextTokens: 6_144, maxOutputTokens: 2_048
        )
        let call = try TestFixtures.toolCall(
            id: "child-page", toolName: ToolResultPagingTool.name, arguments: #"{"ref":"tr_x"}"#
        )
        let pageBody = String(repeating: "P", count: 30_000)
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        let dispatcher = RecordingDispatcher()
        dispatcher.results[call.id] = ToolResult(
            callID: call.id, status: .ok,
            outputSummary: pageBody, outputDigest: "d",
            maximumSummaryCharacters: 262_144
        )
        let runner = makeRunner(
            adapter: adapter, executor: executor, provider: provider, model: smallModel
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "page", kind: .explore, runID: runID),
            context: childContext(
                identity: identity, dispatcher: dispatcher, bus: bus,
                allowedToolNames: [ToolResultPagingTool.name]
            )
        )
        #expect(outcome.status == .completed)
        let request = try #require(adapter.requests.last)
        let wire = try #require(request.toolResults.first?.output)
        #expect(wire.contains("page not repeated in this request"))
        #expect(!wire.contains(String(repeating: "P", count: 100)))
        #expect(SubagentRunner.contextWireBytes(of: request)
            <= SubagentRunner.requestContextByteCeiling(model: smallModel))
        #expect(dispatcher.calls.map(\.id) == [call.id])
    }

    @Test("a small window counts complete schemas and the output reserve instead of assuming 96 KiB")
    func smallWindowCountsSchemasAndOutputReserve() async throws {
        let provider = TestFixtures.localhostProvider()
        let smallModel = model(
            providerID: provider.id, contextTokens: 16_384, maxOutputTokens: 2_048
        )
        let schema = #"{"type":"object","properties":{"command":{"type":"string","description":""#
            + String(repeating: "c", count: 4_000)
            + #""}},"required":["command"],"additionalProperties":false}"#
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]]
        let executor = MockExecutor()
        executor.descriptors["exec.shell"] = .init(
            name: "exec.shell",
            toolDescription: "Run one command in the resolved Linux environment",
            parametersJSON: schema,
            riskLabels: [], isSideEffecting: true
        )
        let runner = makeRunner(
            adapter: adapter, executor: executor, provider: provider, model: smallModel
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "inspect", kind: .explore, runID: UUID()),
            context: childContext(
                identity: ChildExecutionIdentity(
                    parentRunID: UUID(), rootTaskID: UUID(), delegateCallID: "d"
                ),
                dispatcher: RecordingDispatcher(),
                bus: SubagentPeerBus(),
                allowedToolNames: ["exec.shell"]
            )
        )
        #expect(outcome.status == .completed)
        let request = try #require(adapter.requests.first)
        let ceiling = SubagentRunner.requestContextByteCeiling(model: smallModel)
        // Concrete arithmetic: (16 384 - 2 048 - 256) * 3, not 96 KiB.
        #expect(ceiling == (16_384 - 2_048 - 256) * 3)
        #expect(SubagentRunner.outputReservationTokens(limits: smallModel.limits) == 2_048)
        #expect(SubagentRunner.contextWireBytes(of: request) <= ceiling)
        let shell = try #require(request.toolSchemas.first { $0.name == "exec.shell" })
        // The exact complete definition is carried, never sliced.
        #expect(shell.parametersJSON == schema)
    }

    @Test("a required frozen seed schema that cannot fit the real window fails truthfully before any request")
    func frozenSeedSchemaOverflowIsTruthful() async throws {
        let provider = TestFixtures.localhostProvider()
        let smallModel = model(
            providerID: provider.id, contextTokens: 8_192, maxOutputTokens: 2_048
        )
        let adapter = MockAdapter()
        let executor = MockExecutor()
        // skill.read is part of the always-present seed; this pathological
        // definition cannot fit the model's actual schema allowance, so the
        // child must fail closed instead of cutting the definition or sending
        // an over-budget request.
        executor.descriptors["skill.read"] = .init(
            name: "skill.read",
            toolDescription: "Read a guide",
            parametersJSON: #"{"type":"object","properties":{"id":{"type":"string","description":""#
                + String(repeating: "s", count: 40_000)
                + #""}},"additionalProperties":true}"#,
            riskLabels: [], isSideEffecting: false
        )
        let runner = makeRunner(
            adapter: adapter, executor: executor, provider: provider, model: smallModel
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "inspect", kind: .explore, runID: UUID()),
            context: childContext(
                identity: ChildExecutionIdentity(
                    parentRunID: UUID(), rootTaskID: UUID(), delegateCallID: "d"
                ),
                dispatcher: RecordingDispatcher(),
                bus: SubagentPeerBus(),
                allowedToolNames: ["skill.read"]
            )
        )
        #expect(outcome.status == .toolError)
        #expect(outcome.iterationsUsed == 0)
        #expect(outcome.findings.contains("actual request context"))
        #expect(outcome.findings.contains("No provider request was sent"))
        #expect(adapter.requests.isEmpty)
    }

    @Test("child typed sensitive output is only in the immediate child provider request")
    func childSensitiveOutputIsImmediateOnly() async throws {
        let runID = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: UUID(), delegateCallID: "d")
        let call = try TestFixtures.toolCall(id: "child-sensitive", toolName: "test.echo", arguments: "{}")
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let dispatcher = RecordingDispatcher()
        dispatcher.results[call.id] = ToolResult(
            callID: call.id,
            status: .ok,
            outputSummary: "Authorized cookie read; value withheld from durable output.",
            outputDigest: "d",
            ephemeralSensitiveOutput: "CHILD_MODEL_ONLY_SENTINEL"
        )
        let runner = makeRunner(adapter: adapter, executor: executor)
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "read", kind: .explore, runID: runID),
            context: childContext(
                identity: identity, dispatcher: dispatcher, bus: bus,
                allowedToolNames: ["test.echo"]
            )
        )
        #expect(outcome.status == .completed)
        let wire = try #require(adapter.requests.last?.toolResults.first?.output)
        #expect(wire.contains("CHILD_MODEL_ONLY_SENTINEL"))
        #expect(wire.contains("Ephemeral sensitive tool output"))
        // The child's findings/outcome must not carry the typed secret.
        #expect(!outcome.findings.contains("CHILD_MODEL_ONLY_SENTINEL"))
        #expect(dispatcher.calls.map(\.id) == [call.id])
    }

    @Test("a dispatcher denial is preserved as a real denied result for every kind")
    func dispatcherDenialIsHonest() async throws {
        let runID = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: UUID(), delegateCallID: "d")
        for kind in [SubagentRequest.Kind.explore, .research, .execute] {
            let adapter = MockAdapter()
            let write = try TestFixtures.toolCall(
                id: "w-2", toolName: "test.write", arguments: #"{"path":"a.md","text":"x"}"#
            )
            let delegate = try TestFixtures.toolCall(id: "d-1", toolName: "delegate", arguments: #"{"task":"x"}"#)
            adapter.script = [
                [.toolRequest(write), .toolRequest(delegate)],
                [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
            ]
            let executor = MockExecutor()
            let runner = makeRunner(adapter: adapter, executor: executor)
            let dispatcher = RecordingDispatcher()
            // The parent's canonical dispatcher denies the write (for example
            // an approval denial) and refuses the nested delegate.
            dispatcher.results["w-2"] = ToolResult(
                callID: "w-2", status: .denied,
                outputSummary: "Denied by the parent approval policy", outputDigest: ""
            )
            dispatcher.results["d-1"] = ToolResult(
                callID: "d-1", status: .denied,
                outputSummary: "Denied: main-run only", outputDigest: ""
            )
            let outcome = try await runner.runStructured(
                SubagentRequest(task: "work", kind: kind, runID: runID),
                context: childContext(
                    identity: identity, dispatcher: dispatcher, bus: bus,
                    allowedToolNames: ["test.write", "delegate"]
                )
            )
            #expect(outcome.status == .completed, "\(kind)")
            #expect(outcome.evidence.contains { $0.hasPrefix("delegate ") && $0.contains("[denied]") }, "\(kind)")
            #expect(outcome.evidence.contains { $0.hasPrefix("test.write ") && $0.contains("[denied]") }, "\(kind)")
            let followUp = try #require(adapter.requests.last)
            #expect(followUp.toolResults.contains { $0.callID == "d-1" && $0.output.contains("Denied") })
            #expect(followUp.toolResults.contains { $0.callID == "w-2" && $0.output.contains("Denied") })
        }
    }

    // MARK: - Sibling collaboration

    @Test("a sibling message queued during the run is delivered at the next safe boundary for every kind")
    func peerMessageDeliveredAtBoundary() async throws {
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        for kind in [SubagentRequest.Kind.explore, .research, .execute] {
            let adapter = MockAdapter()
            let read = try TestFixtures.toolCall(id: "r-1")
            adapter.script = [
                [.toolRequest(read)],
                [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
            ]
            let runner = makeRunner(adapter: adapter, executor: executor)
            let runID = UUID()
            let root = UUID()
            let bus = SubagentPeerBus()
            let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: root, delegateCallID: "d")
            let sibling = ChildExecutionIdentity(parentRunID: runID, rootTaskID: root, delegateCallID: "d2")
            await bus.register(identity, label: "writer")
            await bus.register(sibling, label: "reader")
            // Queued BEFORE the child runs; delivered after its first tool batch.
            let first = await bus.send(
                from: sibling.childID, to: identity.childID,
                body: "file a.md is mine", clientMessageID: "m1"
            )
            #expect(first.accepted)
            // Idempotent resend is not queued twice.
            let resend = await bus.send(
                from: sibling.childID, to: identity.childID,
                body: "file a.md is mine", clientMessageID: "m1"
            )
            #expect(resend.accepted)
            #expect(resend.messageID == first.messageID)

            let dispatcher = RecordingDispatcher()
            let outcome = try await runner.runStructured(
                SubagentRequest(task: "work", kind: kind, runID: runID),
                context: childContext(
                    identity: identity, dispatcher: dispatcher, bus: bus,
                    allowedToolNames: ["test.echo"]
                )
            )
            #expect(outcome.status == .completed, "\(kind)")
            #expect(outcome.evidence.contains { $0.contains("1 message(s) delivered") }, "\(kind)")
            let followUp = try #require(adapter.requests.last)
            let body = followUp.effectiveMessages
                .flatMap(\.content)
                .compactMap { part -> String? in
                    if case .text(let text) = part { return text }
                    return nil
                }
                .joined(separator: "\n")
            #expect(body.contains("file a.md is mine"), "\(kind)")
            #expect(body.contains("reader"), "\(kind)")
            #expect(body.contains("untrusted coordination data"), "\(kind)")
            // Exactly once despite the resend.
            let occurrences = body.components(separatedBy: "file a.md is mine").count - 1
            #expect(occurrences == 1, "\(kind)")
        }
    }

    @Test("messages cannot cross root tasks and cannot reach a finished child")
    func peerBoundaries() async {
        let bus = SubagentPeerBus()
        let root = UUID()
        let otherRoot = UUID()
        let first = ChildExecutionIdentity(parentRunID: UUID(), rootTaskID: root, delegateCallID: "d1")
        let second = ChildExecutionIdentity(parentRunID: UUID(), rootTaskID: root, delegateCallID: "d2")
        let foreign = ChildExecutionIdentity(parentRunID: UUID(), rootTaskID: otherRoot, delegateCallID: "d3")
        await bus.register(first, label: "one")
        await bus.register(second, label: "two")
        await bus.register(foreign, label: "foreign")

        // Same root is allowed.
        #expect(await bus.send(from: first.childID, to: second.childID, body: "hi").accepted)
        // Cross root is rejected.
        let crossRoot = await bus.send(from: first.childID, to: foreign.childID, body: "hi")
        #expect(!crossRoot.accepted)
        #expect(crossRoot.reason?.contains("different root task") == true)
        // Self-message is rejected.
        #expect(!(await bus.send(from: first.childID, to: first.childID, body: "hi").accepted))
        // Empty/oversized bodies are rejected.
        #expect(!(await bus.send(from: first.childID, to: second.childID, body: "   ").accepted))
        let huge = String(repeating: "x", count: SubagentPeerBus.maxBodyBytes + 1)
        #expect(!(await bus.send(from: first.childID, to: second.childID, body: huge).accepted))

        // A finished child cannot be messaged or drained.
        await bus.unregister(childID: second.childID)
        let afterFinish = await bus.send(from: first.childID, to: second.childID, body: "still there?")
        #expect(!afterFinish.accepted)
        #expect(afterFinish.reason?.contains("already finished") == true)
        #expect(await bus.drain(childID: second.childID).isEmpty)

        // The sender's drain only sees its own mailbox.
        #expect(await bus.drain(childID: first.childID).isEmpty)
        // Audit trail records accepted and rejected sends.
        let audit = await bus.auditEntries
        #expect(audit.contains { $0.accepted })
        #expect(audit.contains { !$0.accepted })
    }

    @Test("a registry wrapper cannot smuggle delegate, but the genuine main call succeeds")
    func wrapperCannotDelegate() async throws {
        let adapter = MockAdapter()
        adapter.script = [[.textDelta(.init(text: "child done")), .completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let runID = UUID()
        let runners = SubagentRunnerRegistry()
        await runners.register(
            SubagentRunner(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                adapter: adapter,
                credentials: ProviderCredentials(),
                executor: MockExecutor()
            ),
            for: runID
        )
        let registry = ToolRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        let delegate = try #require(registry.runner(named: "delegate"))

        // 1. The genuine main-run call with its exact runtime-issued origin
        //    succeeds end to end through the raw registry entry.
        let mainContext = ToolContext(
            runID: runID,
            toolCallID: "call-main",
            cancellation: CancellationToken(),
            childBudget: budgetContext(),
            callOrigin: ToolCallOrigin(kind: .mainRunDelegate, runID: runID, callID: "call-main", toolName: "delegate")
        )
        let mainResult = try await delegate.execute(
            argumentsJSON: Data(#"{"task":"say done"}"#.utf8),
            context: mainContext
        )
        #expect((mainResult.exitStatus ?? 1) == 0)
        #expect(mainResult.summary.contains("status=ok"))

        // 2. A wrapper that rebuilt a child context (with a live child
        //    handoff) is refused at the callable boundary.
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: UUID(), delegateCallID: "call-parent"
        )
        let dispatcher = RecordingDispatcher()
        let childContext = ToolContext(
            runID: runID,
            toolCallID: "call-wrapper",
            cancellation: CancellationToken(),
            childBudget: budgetContext(),
            childExecution: ChildExecutionHandoff(
                identity: identity,
                dispatcher: ChildToolDispatcher(
                    descriptorProvider: { _ in nil },
                    allDescriptors: { [] },
                    dispatch: { call, context in await dispatcher.dispatch(call, context: context) }
                ),
                peers: bus.handle(for: identity)
            ),
            callOrigin: ToolCallOrigin(
                kind: .delegatedChild,
                runID: runID,
                callID: "call-wrapper",
                toolName: "delegate",
                childID: identity.childID,
                rootTaskID: identity.rootTaskID
            )
        )
        let nested = try await delegate.execute(
            argumentsJSON: Data(#"{"task":"nested"}"#.utf8),
            context: childContext
        )
        #expect(nested.exitStatus == 1)
        #expect(nested.summary.contains("status=denied"))

        // 3. A from-scratch reconstruction with NO origin is also refused:
        //    absence of provenance is never a main-run fallback.
        let noOrigin = ToolContext(
            runID: runID,
            toolCallID: "call-main",
            cancellation: CancellationToken(),
            childBudget: budgetContext()
        )
        let refused = try await delegate.execute(
            argumentsJSON: Data(#"{"task":"nested"}"#.utf8),
            context: noOrigin
        )
        #expect(refused.exitStatus == 1)
        #expect(refused.summary.contains("status=denied"))

        // 4. The REAL wrapper case: a main-run wrapper holds a genuine
        //    runtime-issued `.mainRunDelegate` origin for ITS OWN approved
        //    tool and forwards the identical runID + callID into this raw
        //    registry entry. The tool-name binding must refuse it; without
        //    that binding the wrapper would inherit main-run delegation.
        let wrapperOrigin = ToolContext(
            runID: runID,
            toolCallID: "call-main",
            cancellation: CancellationToken(),
            callOrigin: ToolCallOrigin(
                kind: .mainRunDelegate,
                runID: runID,
                callID: "call-main",
                toolName: "test.mainwrapper"
            )
        )
        let forwarded = try await delegate.execute(
            argumentsJSON: Data(#"{"task":"forwarded nested"}"#.utf8),
            context: wrapperOrigin
        )
        #expect(forwarded.exitStatus == 1)
        #expect(forwarded.summary.contains("status=denied"),
                "a wrapper's own main origin must not authorize delegate: \(forwarded.summary)")
    }

    @Test("registerDelegateTool wires delegate plus the child-only peer tools")
    func registrationWiresPeerTools() {
        let registry = ToolRunnerRegistry()
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        #expect(registry.runner(named: "delegate") != nil)
        #expect(registry.runner(named: "delegate.peers") != nil)
        #expect(registry.runner(named: "delegate.message") != nil)
        #expect(registry.descriptor(named: "delegate")?.executionBoundary == .mainRunOnly)
        #expect(registry.descriptor(named: "delegate.peers")?.executionBoundary == .childOnly)
        #expect(registry.descriptor(named: "delegate.message")?.executionBoundary == .childOnly)
    }

    @Test("the peer tool denies outside a delegated child context")
    func peerToolsDenyOutsideChild() async throws {
        let context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        await #expect(throws: Error.self) {
            _ = try await DelegatePeersTool().execute(.init(), context: context)
        }
        await #expect(throws: Error.self) {
            _ = try await DelegateMessageTool().execute(
                .init(to: UUID().uuidString, message: "hi"),
                context: context
            )
        }
    }
}
