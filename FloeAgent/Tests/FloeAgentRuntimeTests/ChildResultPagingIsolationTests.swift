import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ChildResultPagingIsolation")
struct ChildResultPagingIsolationTests {
    final class Counter: @unchecked Sendable {
        private let storage = AsyncLock(0)
        var value: Int { storage.withLock { $0 } }
        func increment() { storage.withLock { $0 += 1 } }
    }

    struct Echo: AgentTool {
        struct Arguments: Decodable, Sendable {}
        static let name = "test.pagingEcho"
        static let toolDescription = "Read-only reachability control"
        static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = []
        static let isSideEffecting = false
        let counter: Counter
        func validate(_ args: Arguments) throws {}
        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            counter.increment()
            return ToolExecutionOutput(summary: "child reached executor", fullOutputSHA256: "echo")
        }
    }

    @Test("An active child can read the SAME task's captures but not another task's, while its allowed tool reaches the executor")
    func activeChildReadsOnlySameTaskCaptures() async throws {
        try await ActiveParentTestScope.withScope {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("child-paging-isolation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ActiveParentTestScope.afterStop { try? FileManager.default.removeItem(at: root) }
            let conversationID = UUID()
            let runID = UUID()
            let body = "parent-owned-captured-result-\(UUID().uuidString)"
            let store = ToolResultCaptureStore.shared(durableRoot: root)
            await store.capture(conversationID: conversationID, runID: runID,
                                callID: "parent-call", toolName: "exec.shell", status: "ok",
                                text: body, temporary: false)
            let paging = ToolResultPagingTool(store: store)
            // Establish real data and a sensitive control: a valid parent read
            // succeeds before testing the child dispatch boundary.
            let parentRead = try await paging.execute(.init(callID: "parent-call"), context: ToolContext(
                runID: runID, allowedToolNames: [ToolResultPagingTool.name],
                cancellation: CancellationToken(), conversationID: conversationID
            ))
            #expect(parentRead.summary.contains(body))

            let counter = Counter()
            let registry = ToolRunnerRegistry()
            registry.register(paging)
            registry.register(Echo(counter: counter))
            let executor = CatalogToolExecutor(runners: registry)
            #expect(executor.descriptor(named: ToolResultPagingTool.name)?.executionBoundary == .any)
            #expect(ToolResultPagingTool.descriptor.executionBoundary == ToolResultPagingTool.executionBoundary)
            #expect(ToolResultPagingTool.descriptor.supportsConcurrentBatchDispatch == ToolResultPagingTool.supportsConcurrentBatchDispatch)
            let provider = TestFixtures.localhostProvider()
            let runtime = FloeAgentRuntime(
                configuration: .init(conversationID: conversationID, provider: provider,
                                     model: TestFixtures.testModel(providerID: provider.id),
                                     allowedToolNames: [Echo.name, ToolResultPagingTool.name],
                                     toolResultCaptureRoot: root),
                adapter: ActiveParentTestAdapter(),
                policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
                executor: executor, auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore(),
                runID: runID
            )
            try await ActiveParentTestScope.activate(runtime)
            #expect(await runtime.state.name == "streamingModel")
            let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-1")
            let context = ToolContext(runID: UUID(), allowedToolNames: [Echo.name],
                                      cancellation: CancellationToken(), conversationID: conversationID,
                                      frozenEffectiveCatalogNames: [Echo.name])
            // Same-task child read: the parent capture is available by its
            // stable ref/call id. The runtime still resolves the owning
            // conversation itself, so a child cannot name another task.
            let pageCall = try TestFixtures.toolCall(id: "child-parent-page", toolName: ToolResultPagingTool.name,
                                                    arguments: #"{"callID":"parent-call"}"#)
            let read = await runtime.dispatchChildTool(pageCall, identity: identity, childContext: context)
            #expect(read.status == .ok, "\(read.outputSummary)")
            #expect(read.outputSummary.contains(body))
            // A forged context naming another conversation is denied.
            let foreignContext = ToolContext(runID: UUID(), allowedToolNames: [ToolResultPagingTool.name],
                                             cancellation: CancellationToken(), conversationID: UUID())
            let foreign = await runtime.dispatchChildTool(pageCall, identity: identity, childContext: foreignContext)
            #expect(foreign.status == .denied)
            #expect(foreign.outputSummary.contains("scoped to this task"))
            #expect(!foreign.outputSummary.contains(body))
            let echoCall = try TestFixtures.toolCall(id: "child-allowed-echo", toolName: Echo.name, arguments: "{}")
            let reached = await runtime.dispatchChildTool(echoCall, identity: identity, childContext: context)
            #expect(reached.status == .ok, "\(reached.outputSummary)")
            #expect(reached.outputSummary == "child reached executor")
            #expect(counter.value == 1)
        }
    }

    struct TaggedEcho: AgentTool {
        struct Arguments: Decodable, Sendable {
            let tag: String
        }
        static let name = "test.taggedEcho"
        static let toolDescription = "Return a deterministic tagged body"
        static let parametersJSON = #"{"type":"object","properties":{"tag":{"type":"string"}},"required":["tag"],"additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = []
        static let isSideEffecting = false

        static func body(tag: String) -> String {
            "\(tag)-HEAD-" + String(repeating: tag.lowercased(), count: 300) + "-\(tag)-TAIL"
        }

        func validate(_ args: Arguments) throws {}

        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            ToolExecutionOutput(digesting: Self.body(tag: args.tag))
        }
    }

    struct LargeBodyEcho: AgentTool {
        struct Arguments: Decodable, Sendable {}
        static let name = "test.largeBodyEcho"
        static let toolDescription = "Return a large deterministic body"
        static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = []
        static let isSideEffecting = false
        static let body = "WIRE-HEAD-" + String(repeating: "W", count: 60 * 1_024) + "-WIRE-TAIL"

        func validate(_ args: Arguments) throws {}

        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            ToolExecutionOutput(digesting: Self.body)
        }
    }

    @Test("Sibling and parent reuse of one provider call id stays isolated in the real store and paging routes")
    func siblingAndParentCallIDsStayIsolated() async throws {
        try await ActiveParentTestScope.withScope {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("child-paging-identity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ActiveParentTestScope.afterStop { try? FileManager.default.removeItem(at: root) }
            let conversationID = UUID()
            let runID = UUID()
            let store = ToolResultCaptureStore.shared(durableRoot: root)
            let registry = ToolRunnerRegistry()
            registry.register(TaggedEcho())
            registry.register(ToolResultPagingTool(store: store))
            let executor = CatalogToolExecutor(runners: registry)
            let provider = TestFixtures.localhostProvider()
            let runtime = FloeAgentRuntime(
                configuration: .init(
                    conversationID: conversationID, provider: provider,
                    model: TestFixtures.testModel(providerID: provider.id),
                    allowedToolNames: [TaggedEcho.name, ToolResultPagingTool.name],
                    toolResultCaptureRoot: root
                ),
                adapter: ActiveParentTestAdapter(),
                policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
                executor: executor, auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore(),
                runID: runID
            )
            try await ActiveParentTestScope.activate(runtime)
            #expect(await runtime.state.name == "streamingModel")

            let sharedCallID = "provider-reused-call-id"
            let identityA = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-A"
            )
            let identityB = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-B"
            )
            func context(for identity: ChildExecutionIdentity) -> ToolContext {
                ToolContext(
                    runID: identity.parentRunID,
                    allowedToolNames: [TaggedEcho.name, ToolResultPagingTool.name],
                    cancellation: CancellationToken(),
                    conversationID: conversationID,
                    frozenEffectiveCatalogNames: [TaggedEcho.name, ToolResultPagingTool.name]
                )
            }
            let bodyP = TaggedEcho.body(tag: "P")
            let bodyA = TaggedEcho.body(tag: "A")
            let bodyB = TaggedEcho.body(tag: "B")
            // The parent's own capture under the root run namespace, exactly
            // what the main-run retention path writes.
            let parentReceipt = await store.capture(
                conversationID: conversationID, runID: runID,
                callID: sharedCallID, toolName: TaggedEcho.name, status: "ok",
                text: bodyP, temporary: false
            )
            #expect(parentReceipt.retained)

            // Two sibling children reuse the SAME provider call id with
            // different arguments and distinct bodies.
            let callA = try TestFixtures.toolCall(
                id: sharedCallID, toolName: TaggedEcho.name, arguments: #"{"tag":"A"}"#
            )
            let callB = try TestFixtures.toolCall(
                id: sharedCallID, toolName: TaggedEcho.name, arguments: #"{"tag":"B"}"#
            )
            let resultA = await runtime.dispatchChildTool(
                callA, identity: identityA, childContext: context(for: identityA)
            )
            let resultB = await runtime.dispatchChildTool(
                callB, identity: identityB, childContext: context(for: identityB)
            )
            #expect(resultA.status == .ok, "\(resultA.outputSummary)")
            #expect(resultB.status == .ok, "\(resultB.outputSummary)")
            let refA = ToolResultCaptureStore.reference(
                runID: identityA.childID, callID: sharedCallID
            )
            let refB = ToolResultCaptureStore.reference(
                runID: identityB.childID, callID: sharedCallID
            )
            #expect(resultA.captureInfo?.available == true)
            #expect(resultB.captureInfo?.available == true)
            #expect(resultA.captureInfo?.ref == refA)
            #expect(resultB.captureInfo?.ref == refB)
            let parentRunRef = ToolResultCaptureStore.reference(
                runID: runID, callID: sharedCallID
            )
            #expect(refA != refB)
            #expect(refA != parentRunRef)
            #expect(refB != parentRunRef)
            #expect(refA != parentReceipt.ref)
            #expect(refB != parentReceipt.ref)
            #expect(resultA.captureInfo?.retainedBytes == bodyA.utf8.count)
            #expect(resultB.captureInfo?.retainedBytes == bodyB.utf8.count)

            // Each record really holds its OWN body: the sibling and the
            // parent never overwrote or misattributed one another.
            guard case .page(let pageA) = await store.page(
                conversationID: conversationID, ref: refA, offset: 0, maxBytes: 2_000
            ), case .page(let pageB) = await store.page(
                conversationID: conversationID, ref: refB, offset: 0, maxBytes: 2_000
            ), case .page(let pageP) = await store.page(
                conversationID: conversationID, ref: parentReceipt.ref, offset: 0, maxBytes: 2_000
            ) else {
                Issue.record("each namespace must own a pageable capture")
                return
            }
            #expect(pageA.capture.text == bodyA)
            #expect(pageB.capture.text == bodyB)
            #expect(pageP.capture.text == bodyP)

            // The same-task parent route (the exact context the runtime builds
            // for its own paging call) pages each record by ref.
            let paging = ToolResultPagingTool(store: store)
            let parentContext = ToolContext(
                runID: runID, cancellation: CancellationToken(), conversationID: conversationID
            )
            let parentPageA = try await paging.execute(
                .init(ref: refA, offset: bodyA.utf8.count - 16, maxBytes: 64),
                context: parentContext
            )
            #expect(parentPageA.summary.contains(String(bodyA.suffix(16))))
            let parentPageB = try await paging.execute(
                .init(ref: refB, offset: bodyB.utf8.count - 16, maxBytes: 64),
                context: parentContext
            )
            #expect(parentPageB.summary.contains(String(bodyB.suffix(16))))

            // A child may page its own sibling-isolated ref directly too.
            let childRefCallA = try TestFixtures.toolCall(
                id: "page-by-ref-A", toolName: ToolResultPagingTool.name,
                arguments: #"{"ref":"\#(refA)","offset":\#(bodyA.utf8.count - 16),"maxBytes":64}"#
            )
            let childRefPageA = await runtime.dispatchChildTool(
                childRefCallA, identity: identityA, childContext: context(for: identityA)
            )
            #expect(childRefPageA.status == .ok, "\(childRefPageA.outputSummary)")
            #expect(childRefPageA.outputSummary.contains(String(bodyA.suffix(16))))
            let childRefCallB = try TestFixtures.toolCall(
                id: "page-by-ref-B", toolName: ToolResultPagingTool.name,
                arguments: #"{"ref":"\#(refB)","offset":\#(bodyB.utf8.count - 16),"maxBytes":64}"#
            )
            let childRefPageB = await runtime.dispatchChildTool(
                childRefCallB, identity: identityB, childContext: context(for: identityB)
            )
            #expect(childRefPageB.status == .ok, "\(childRefPageB.outputSummary)")
            #expect(childRefPageB.outputSummary.contains(String(bodyB.suffix(16))))

            // A bare call id resolves the CALLER's own namespace first: the
            // sibling capture with the identical id is never preferred.
            func childCallIDPage(
                _ callID: String,
                identity: ChildExecutionIdentity,
                callIDForCall: String
            ) async throws -> ToolResult {
                let call = try TestFixtures.toolCall(
                    id: callIDForCall, toolName: ToolResultPagingTool.name,
                    arguments: #"{"callID":"\#(callID)","offset":\#(bodyA.utf8.count - 16),"maxBytes":64}"#
                )
                return await runtime.dispatchChildTool(
                    call, identity: identity, childContext: context(for: identity)
                )
            }
            let childPageA = try await childCallIDPage(
                sharedCallID, identity: identityA, callIDForCall: "page-by-call-A"
            )
            #expect(childPageA.status == .ok, "\(childPageA.outputSummary)")
            #expect(childPageA.outputSummary.contains(String(bodyA.suffix(16))))
            #expect(!childPageA.outputSummary.contains(String(bodyB.suffix(16))))
            let childPageB = try await childCallIDPage(
                sharedCallID, identity: identityB, callIDForCall: "page-by-call-B"
            )
            #expect(childPageB.status == .ok, "\(childPageB.outputSummary)")
            #expect(childPageB.outputSummary.contains(String(bodyB.suffix(16))))
            #expect(!childPageB.outputSummary.contains(String(bodyA.suffix(16))))
            let parentByCallID = try await paging.execute(
                .init(callID: sharedCallID, offset: bodyP.utf8.count - 16, maxBytes: 64),
                context: parentContext
            )
            #expect(parentByCallID.summary.contains(String(bodyP.suffix(16))))

            // A resumed run of the SAME child preserves its namespace/ref and
            // still pages its own record.
            let resumedA = ChildExecutionIdentity(
                childID: identityA.childID, parentRunID: runID,
                rootTaskID: conversationID, delegateCallID: "resume-token"
            )
            #expect(ToolResultCaptureStore.reference(
                runID: resumedA.childID, callID: sharedCallID
            ) == refA)
            let resumedPage = try await childCallIDPage(
                sharedCallID, identity: resumedA, callIDForCall: "page-by-call-resumed-A"
            )
            #expect(resumedPage.status == .ok, "\(resumedPage.outputSummary)")
            #expect(resumedPage.outputSummary.contains(String(bodyA.suffix(16))))

            // A foreign task can never read the record, even with the exact
            // generated ref.
            if case .missing = await store.page(
                conversationID: UUID(), ref: refA, offset: 0, maxBytes: 64
            ) {
                // Expected: ownership is the trusted conversation.
            } else {
                Issue.record("a foreign task must not read another task's retained capture")
            }

            guard case .index(let rows, _) = await store.taskIndex(
                conversationID: conversationID
            ) else {
                Issue.record("expected the task's retained index")
                return
            }
            #expect(rows.filter { $0.callID == sharedCallID }.count == 3)
        }
    }

    @Test("The real canonical child wire ref equals the real retained store record, never a guessed hash")
    func realChildWireRefMatchesActualRetention() async throws {
        try await ActiveParentTestScope.withScope {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("child-wire-receipt-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try ActiveParentTestScope.afterStop { try? FileManager.default.removeItem(at: root) }
            let conversationID = UUID()
            let runID = UUID()
            let store = ToolResultCaptureStore.shared(durableRoot: root)
            let registry = ToolRunnerRegistry()
            registry.register(LargeBodyEcho())
            registry.register(ToolResultPagingTool(store: store))
            let executor = CatalogToolExecutor(runners: registry)
            let provider = TestFixtures.localhostProvider()
            let runtime = FloeAgentRuntime(
                configuration: .init(
                    conversationID: conversationID, provider: provider,
                    model: TestFixtures.testModel(providerID: provider.id),
                    allowedToolNames: [LargeBodyEcho.name, ToolResultPagingTool.name],
                    toolResultCaptureRoot: root
                ),
                adapter: ActiveParentTestAdapter(),
                policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
                executor: executor, auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore(),
                runID: runID
            )
            try await ActiveParentTestScope.activate(runtime)

            let identity = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-wire"
            )
            let bus = SubagentPeerBus()
            let handoff = ChildExecutionHandoff(
                identity: identity,
                dispatcher: ChildToolDispatcher(
                    descriptorProvider: { name in executor.descriptor(named: name) },
                    allDescriptors: { executor.allDescriptors },
                    dispatch: { call, context in
                        await runtime.dispatchChildTool(
                            call, identity: identity, childContext: context
                        )
                    }
                ),
                peers: bus.handle(for: identity)
            )
            let call = try TestFixtures.toolCall(
                id: "wire-call", toolName: LargeBodyEcho.name, arguments: "{}"
            )
            let adapter = MockAdapter()
            adapter.script = [
                [.toolRequest(call)],
                [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
            ]
            var profile = TestFixtures.testModel(providerID: provider.id)
            // A 12K-token window (about 30 KB of wire) cannot carry the 60 KB
            // body whole, so the wire must become an excerpt with the ref.
            profile.limits = ModelLimits(contextTokens: 12_288, maxOutputTokens: 2_048)
            let runner = SubagentRunner(
                provider: provider, model: profile, adapter: adapter,
                credentials: ProviderCredentials(), executor: executor
            )
            let context = ToolContext(
                runID: runID,
                scope: .local,
                allowedToolNames: [LargeBodyEcho.name, ToolResultPagingTool.name],
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(
                    maximumIterations: 6, reserve: { true }, finish: {}
                ),
                conversationID: conversationID,
                childExecution: handoff,
                frozenEffectiveCatalogNames: [LargeBodyEcho.name, ToolResultPagingTool.name]
            )
            let outcome = try await runner.runStructured(
                SubagentRequest(task: "read the large result", kind: .explore, runID: runID),
                context: context
            )
            #expect(outcome.status == .completed, "\(outcome.findings)")
            let wire = try #require(adapter.requests.last?.toolResults.first?.output)
            let expectedRef = ToolResultCaptureStore.reference(
                runID: identity.childID, callID: call.id
            )
            #expect(wire.contains("truncated for this request"))
            #expect(wire.contains("ref=\(expectedRef)"))
            // The old bug hashed the PARENT run id here; that ref names no
            // record in this child's namespace.
            #expect(!wire.contains(
                "ref=\(ToolResultCaptureStore.reference(runID: runID, callID: call.id))"
            ))
            #expect(!wire.contains("NOT retained"))
            // That exact ref really pages the full retained body.
            guard case .page(let headPage) = await store.page(
                conversationID: conversationID, ref: expectedRef,
                offset: 0, maxBytes: ToolResultPagingTool.maximumPageBytes
            ) else {
                Issue.record("the child's advertised ref must page the real store record")
                return
            }
            #expect(headPage.totalBytes == LargeBodyEcho.body.utf8.count)
            #expect(LargeBodyEcho.body.hasPrefix(headPage.text))
            guard case .page(let tailPage) = await store.page(
                conversationID: conversationID, ref: expectedRef,
                offset: LargeBodyEcho.body.utf8.count - 64, maxBytes: 64
            ) else {
                Issue.record("the retained tail must be pageable")
                return
            }
            #expect(tailPage.text == String(LargeBodyEcho.body.suffix(64)))
        }
    }

    @Test("An intentionally idle parent still refuses an otherwise allowed child before execution")
    func inactiveParentStillDenied() async throws {
        let counter = Counter()
        let registry = ToolRunnerRegistry()
        registry.register(Echo(counter: counter))
        let provider = TestFixtures.localhostProvider()
        let conversationID = UUID()
        let runtime = FloeAgentRuntime(
            configuration: .init(conversationID: conversationID, provider: provider,
                                 model: TestFixtures.testModel(providerID: provider.id)),
            adapter: MockAdapter(),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: CatalogToolExecutor(runners: registry),
            auditSink: MockAuditSink(), checkpointStore: MockCheckpointStore()
        )
        let identity = ChildExecutionIdentity(parentRunID: await runtime.runID, rootTaskID: conversationID, delegateCallID: "idle-delegate")
        let call = try TestFixtures.toolCall(id: "idle-call", toolName: Echo.name, arguments: "{}")
        let denied = await runtime.dispatchChildTool(call, identity: identity, childContext: ToolContext(
            runID: UUID(), allowedToolNames: [Echo.name], cancellation: CancellationToken(), conversationID: conversationID
        ))
        #expect(denied.status == .denied)
        #expect(denied.outputSummary.contains("no longer active"))
        #expect(counter.value == 0)
    }
}
