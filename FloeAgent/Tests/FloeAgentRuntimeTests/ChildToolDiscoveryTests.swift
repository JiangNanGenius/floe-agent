// FloeAgentRuntimeTests — child-side progressive tool discovery.
//
// These tests exercise the ACTUAL child loop and, for the large-catalog case,
// the real runtime dispatch chain: parent run → canonical delegate handoff →
// child loop → canonical child dispatch → real tool. They reproduce the
// production catalog size on the wire so the 254 KB > 48 KiB frozen-schema
// regression can never return as a "child cannot start" abort.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeProviders
@testable import FloePersistence
@testable import FloeAgentRuntime

@Suite("FloeAgentRuntime.ChildToolDiscovery")
struct ChildToolDiscoveryTests {
    // MARK: - Fixtures

    /// Records real tool effects so tests assert artifacts, not strings.
    actor DiscoveryRecorder {
        struct Record: Sendable { var path: String; var digest: String }
        private var storage: [Record] = []
        var records: [Record] { storage }
        func record(path: String, digest: String) { storage.append(Record(path: path, digest: digest)) }
    }

    /// A real file-writing tool in the child's non-seed ceiling.
    struct DiscoveryWriteTool: AgentTool {
        struct Arguments: Decodable, Sendable {
            var path: String
            var text: String
        }

        static let name = "test.discoverwrite"
        static let toolDescription = "Write a real file in the task workspace"
        static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"},"text":{"type":"string"}},"required":["path","text"],"additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = [.writesFiles]
        static let isSideEffecting = true
        static let toolEffect: ToolEffect = .mutating

        let recorder: DiscoveryRecorder

        func validate(_ args: Arguments) throws {
            guard !args.path.isEmpty else { throw FloeError.validationFailed("path must not be empty") }
        }

        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            try context.cancellation.throwIfCancelled()
            try context.authorizeWorkspacePath(args.path)
            let root = context.workspaceRootURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let target = root.appendingPathComponent(args.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = Data(args.text.utf8)
            try data.write(to: target, options: .atomic)
            await recorder.record(path: args.path, digest: FloeDigest.sha256Hex(data))
            return ToolExecutionOutput(
                summary: "wrote \(args.path) (\(data.count) bytes)",
                fullOutputSHA256: FloeDigest.sha256Hex(data),
                exitStatus: 0
            )
        }
    }

    /// The guide-declared dependency target. Never in the seed.
    struct ArtifactTool: AgentTool {
        struct Arguments: Decodable, Sendable {
            var name: String
        }

        static let name = "test.artifact"
        static let toolDescription = "Produce a test artifact file after a guide declares it required"
        static let parametersJSON = #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = [.writesFiles]
        static let isSideEffecting = true
        static let toolEffect: ToolEffect = .mutating

        let recorder: DiscoveryRecorder

        func validate(_ args: Arguments) throws {
            guard !args.name.isEmpty else { throw FloeError.validationFailed("name must not be empty") }
        }

        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            try context.cancellation.throwIfCancelled()
            let path = "child/\(args.name)"
            try context.authorizeWorkspacePath(path)
            let root = context.workspaceRootURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let target = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = Data("artifact from guide dependency".utf8)
            try data.write(to: target, options: .atomic)
            await recorder.record(path: path, digest: FloeDigest.sha256Hex(data))
            return ToolExecutionOutput(
                summary: "artifact written", fullOutputSHA256: FloeDigest.sha256Hex(data), exitStatus: 0
            )
        }
    }

    /// Test double for the real FloeSkills `skill.read` JSON contract. The
    /// real tool is verified in its own module tests; here the runtime side
    /// (child activation) is the subject.
    struct SkillReadFixtureTool: AgentTool {
        struct Arguments: Decodable, Sendable {
            var id: String?
            var queries: [String]?
        }

        static let name = "skill.read"
        static let toolDescription = "Read a workflow guide's instructions and declared tool dependencies"
        static let parametersJSON = #"{"type":"object","properties":{"id":{"type":"string"}},"additionalProperties":true}"#
        static let riskLabels: Set<RiskLabel> = []
        static let isSideEffecting = false
        static let toolEffect: ToolEffect = .readOnly

        let requiredToolNames: [String]
        let digest: String

        func validate(_ args: Arguments) throws {}

        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            let rows = [[
                "id": "floe-test-guide",
                "name": "Test guide",
                "version": "1",
                "enabled": true,
                "digest": digest,
                "currentDigest": digest,
                "requiredToolNames": requiredToolNames
            ]] as [[String: Any]]
            let data = try JSONSerialization.data(withJSONObject: rows)
            return ToolExecutionOutput(
                summary: String(decoding: data, as: UTF8.self),
                fullOutputSHA256: FloeDigest.sha256Hex(data),
                exitStatus: 0
            )
        }
    }

    /// Real-size synthetic catalog entry: ~1.1 KB of schema each, so 239
    /// descriptors reproduce the production serialized size on the wire.
    private func bulkDescriptor(_ index: Int) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: String(format: "bulk.capability%03d", index),
            toolDescription: "Bulk capability \(index) used to reproduce the production-size catalog. "
                + String(repeating: "d", count: 700),
            parametersJSON: #"{"type":"object","properties":{"path":{"type":"string","description":""#
                + String(repeating: "s", count: 700)
                + #""},"mode":{"type":"string","enum":["read","write"]}},"additionalProperties":false}"#,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    private func discoveryBudgetContext() -> ChildBudgetContext {
        ChildBudgetContext(maximumIterations: 8, reserve: { true }, finish: {})
    }

    // MARK: - Production-size catalog end to end

    @Test("a real 239-descriptor catalog above 254 KB still lets a child discover exec/Skill, write and produce an artifact")
    func largeCatalogChildWorkflow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-child-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recorder = DiscoveryRecorder()
        let registry = ToolRunnerRegistry()
        registry.register(DiscoveryWriteTool(recorder: recorder))
        registry.register(ArtifactTool(recorder: recorder))
        registry.register(SkillReadFixtureTool(requiredToolNames: ["test.artifact"], digest: "rev-1"))
        for index in 0..<236 {
            registry.register(AnyAgentTool(
                descriptor: bulkDescriptor(index),
                run: { _, _ in
                    ToolExecutionOutput(summary: "unused", fullOutputSHA256: "x", exitStatus: 0)
                }
            ))
        }
        let executor = CatalogToolExecutor(runners: registry)
        let descriptors = executor.allDescriptors
        let serializedBytes = descriptors.reduce(0) {
            $0 + $1.toolDescription.utf8.count + $1.parametersJSON.utf8.count
        }
        // The regression premise: a production-size catalog serializes far
        // above the child's explicit 48 KiB frozen-schema allowance.
        #expect(descriptors.count >= 239)
        #expect(serializedBytes > 254_288, "fixture catalog too small: \(serializedBytes)")
        #expect(serializedBytes > SubagentRunner.maximumFrozenToolSchemaBytes)

        let provider = TestFixtures.localhostProvider()
        let runID = UUID()
        let conversationID = UUID()
        let delegateCall = try TestFixtures.toolCall(
            id: "delegate-big", toolName: "delegate",
            arguments: #"{"task":"write the delegated file and follow the guide","type":"execute","maxIterations":8}"#
        )
        let parentAdapter = MockAdapter()
        parentAdapter.script = [
            [.toolRequest(delegateCall)],
            [.textDelta(.init(text: "parent done")), .completed(.init(stopReason: .endTurn))]
        ]
        let childAdapter = MockAdapter()
        let search = try TestFixtures.toolCall(
            id: "search-1", toolName: "tools.search",
            arguments: #"{"queries":["test.discoverwrite"]}"#
        )
        let write = try TestFixtures.toolCall(
            id: "write-1", toolName: "test.discoverwrite",
            arguments: #"{"path":"child/out.txt","text":"hello from child"}"#
        )
        let skillRead = try TestFixtures.toolCall(
            id: "skill-1", toolName: "skill.read", arguments: #"{"id":"floe-test-guide"}"#
        )
        let artifact = try TestFixtures.toolCall(
            id: "artifact-1", toolName: "test.artifact", arguments: #"{"name":"artifact.txt"}"#
        )
        childAdapter.script = [
            [.toolRequest(search)],
            [.toolRequest(write)],
            [.toolRequest(skillRead)],
            [.toolRequest(artifact)],
            [.textDelta(.init(text: "child finished")), .completed(.init(stopReason: .endTurn))]
        ]
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        await runners.register(
            SubagentRunner(
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                adapter: childAdapter,
                credentials: ProviderCredentials(),
                executor: executor
            ),
            for: runID
        )
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                workspaceRootURL: root
            ),
            adapter: parentAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            runID: runID
        )
        try await runtime.start(goal: "delegate the big-catalog workflow")

        // 1. The child ran all five turns: search → write → skill.read →
        //    guide-declared artifact → final answer.
        #expect(childAdapter.requests.count == 5)
        // 2. Every child request stayed inside the explicit frozen-schema
        //    allowance and never carried the bulk catalog.
        for request in childAdapter.requests {
            #expect(
                SubagentRunner.frozenSchemaWireBytes(of: request)
                    <= SubagentRunner.maximumFrozenToolSchemaBytes,
                "frozen schema ledger exceeded on a real request"
            )
            #expect(!request.toolSchemas.contains { $0.name.hasPrefix("bulk.capability") })
        }
        // 3. The child's own search loaded the write capability for the next
        //    request, and the guide's declared dependency loaded inside the
        //    CHILD after skill.read.
        #expect(childAdapter.requests[1].toolSchemas.contains { $0.name == "test.discoverwrite" })
        #expect(!childAdapter.requests[0].toolSchemas.contains { $0.name == "test.discoverwrite" })
        #expect(childAdapter.requests[3].toolSchemas.contains { $0.name == "test.artifact" })
        #expect(!childAdapter.requests[2].toolSchemas.contains { $0.name == "test.artifact" })
        // 4. Real side effects with exact bytes/hashes.
        let written = try Data(contentsOf: root.appendingPathComponent("child/out.txt"))
        #expect(String(decoding: written, as: UTF8.self) == "hello from child")
        let artifactData = try Data(contentsOf: root.appendingPathComponent("child/artifact.txt"))
        #expect(String(decoding: artifactData, as: UTF8.self) == "artifact from guide dependency")
        let records = await recorder.records
        #expect(records.map(\.path) == ["child/out.txt", "child/artifact.txt"])
        #expect(records.last?.digest == FloeDigest.sha256Hex(artifactData))
    }

    // MARK: - Bounded admission, eviction and protocol pairs

    /// Deterministic executor with a family of medium schemas.
    private final class BulkExecutor: ToolExecutor, @unchecked Sendable {
        private let descriptorsByName: [String: ToolCatalog.Descriptor]

        init(names: [String], schemaPadding: Int) {
            var map: [String: ToolCatalog.Descriptor] = [:]
            for name in names {
                map[name] = ToolCatalog.Descriptor(
                    name: name,
                    toolDescription: "Bulk \(name)",
                    parametersJSON: #"{"type":"object","properties":{"v":{"type":"string","description":""#
                        + String(repeating: "p", count: schemaPadding)
                        + #""}},"additionalProperties":false}"#,
                    riskLabels: [],
                    isSideEffecting: false
                )
            }
            self.descriptorsByName = map
        }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptorsByName[name] }

        var allDescriptors: [ToolCatalog.Descriptor] {
            descriptorsByName.values.sorted { $0.name < $1.name }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            try context.cancellation.throwIfCancelled()
            return ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
        }
    }

    private func exploreRequest(maxIterations: Int = 6) -> SubagentRequest {
        SubagentRequest(task: "discover bounded tools", maxIterations: maxIterations, runID: UUID())
    }

    private func makeRunner(
        adapter: MockAdapter,
        executor: any ToolExecutor
    ) -> SubagentRunner {
        let provider = TestFixtures.localhostProvider()
        return SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor
        )
    }

    private func plainContext() -> ToolContext {
        var context = ToolContext(runID: UUID(), cancellation: CancellationToken())
        context.childBudget = discoveryBudgetContext()
        return context
    }

    @Test("many loaded definitions evict oldest-first, are surfaced and stay inside the schema budget")
    func manyLoadedDefinitionsEvictWithinBudget() async throws {
        let names = (0..<24).map { String(format: "test.bulk%02d", $0) }
        let adapter = MockAdapter()
        let executor = BulkExecutor(names: names, schemaPadding: 2_600)
        // Two turns of ten exact-name searches each: the cumulative 48 KiB
        // child budget cannot hold them all, so the oldest are evicted and the
        // eviction is surfaced.
        func searchBatch(_ range: Range<Int>) -> [AgentEvent] {
            range.map { index in
                let name = names[index]
                return .toolRequest(try! TestFixtures.toolCall(
                    id: "s-\(name)", toolName: "tools.search",
                    arguments: #"{"queries":["\#(name)"]}"#
                ))
            }
        }
        adapter.script = [
            searchBatch(0..<10),
            searchBatch(10..<20),
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runner = makeRunner(adapter: adapter, executor: executor)
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: plainContext())
        #expect(outcome.status == .completed)

        // Every frozen request stays inside the explicit allowance.
        for request in adapter.requests {
            #expect(
                SubagentRunner.frozenSchemaWireBytes(of: request)
                    <= SubagentRunner.maximumFrozenToolSchemaBytes
            )
        }
        // Loading more definitions than fit really evicted earlier ones, and
        // the eviction was surfaced (in the search result or the next system
        // note), never silent.
        let evicting = adapter.requests.contains { request in
            request.effectiveMessages.contains { message in
                message.content.contains { part in
                    if case .text(let text) = part {
                        return text.contains("Unloaded to stay inside the schema budget")
                            || text.contains("Schema budget unloaded")
                    }
                    return false
                }
            }
        }
        #expect(evicting, "expected an explicit eviction notice")
        // The final request cannot hold more than the budget allows.
        let final = try #require(adapter.requests.last)
        let finalBytes = final.toolSchemas.reduce(0) {
            $0 + $1.description.utf8.count + $1.parametersJSON.utf8.count
        }
        #expect(finalBytes <= SubagentRunner.maximumFrozenToolSchemaBytes)
        #expect(final.toolSchemas.count < names.count)
    }

    @Test("a pending settled pair keeps its protocol mapping even when later loads crowd the schema budget")
    func pendingPairKeepsProtocolMapping() async throws {
        let names = (0..<20).map { String(format: "test.crowd%02d", $0) }
        let adapter = MockAdapter()
        let executor = BulkExecutor(names: names, schemaPadding: 2_600)
        let first = try TestFixtures.toolCall(id: "p-1", toolName: "test.crowd00")
        func searchBatch(_ range: Range<Int>) -> [AgentEvent] {
            range.map { index in
                let name = names[index]
                return .toolRequest(try! TestFixtures.toolCall(
                    id: "s-\(name)", toolName: "tools.search",
                    arguments: #"{"queries":["\#(name)"]}"#
                ))
            }
        }
        adapter.script = [
            [.toolRequest(first)],
            searchBatch(0..<10),
            searchBatch(10..<20),
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runner = makeRunner(adapter: adapter, executor: executor)
        let outcome = try await runner.runStructured(exploreRequest(maxIterations: 6), context: plainContext())
        #expect(outcome.status == .completed)

        // The pending pair from turn 1 stays paired on every later request and
        // its tool name stays inside the recorded ceiling mapping even after
        // its schema is evicted from the wire.
        for request in adapter.requests {
            #expect(request.pendingToolCalls.count == request.toolResults.count)
            for (index, call) in request.pendingToolCalls.enumerated() {
                #expect(request.toolResults[index].callID == call.id)
            }
        }
        var sawEvictedButMapped = false
        for request in adapter.requests.dropFirst() {
            if request.toolResults.contains(where: { $0.callID == "p-1" }) {
                #expect(request.allToolNames.contains("test.crowd00"))
                if !request.toolSchemas.contains(where: { $0.name == "test.crowd00" }) {
                    sawEvictedButMapped = true
                }
            }
        }
        #expect(sawEvictedButMapped, "expected the pending tool schema to be evicted while its mapping stayed")
    }

    // MARK: - Deterministic retention: truthful loaded / deferred / evicted

    /// A child-local descriptor padded to a real wire size, so admission is
    /// exercised through the same JSON-escaped ledger the wire uses.
    private func paddedDescriptor(_ name: String, padding: Int) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            toolDescription: "Padded discovery capability \(name)",
            parametersJSON: #"{"type":"object","properties":{"v":{"type":"string","description":""#
                + String(repeating: "p", count: padding)
                + #""}},"additionalProperties":false}"#,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    private func paddedDiscovery(
        _ descriptors: [(name: String, padding: Int)],
        seed: [String] = []
    ) -> ChildToolDiscovery {
        ChildToolDiscovery(
            descriptors: descriptors.map { paddedDescriptor($0.name, padding: $0.padding) },
            seedNames: Set(seed)
        )
    }

    @Test("a requested definition that fills the budget evicts the oldest retained schema with an explicit notice")
    func requestPressureEvictsOldestWithNotice() {
        var discovery = paddedDiscovery([
            (name: "test.oldA", padding: 8_000),
            (name: "test.newD", padding: 8_000),
            (name: "test.newE", padding: 8_000),
            (name: "test.newF", padding: 8_000),
        ])
        // Room for three padded schemas after the name ledger, not four.
        let budget = 30_000
        let first = discovery.load(["test.oldA"], maxBytes: budget)
        #expect(first.admitted == ["test.oldA"])
        #expect(first.evicted.isEmpty)
        _ = discovery.load(["test.newD"], maxBytes: budget)
        _ = discovery.load(["test.newE"], maxBytes: budget)
        let revisionBefore = discovery.revision
        let third = discovery.load(["test.newF"], maxBytes: budget)

        #expect(third.admitted == ["test.newF"])
        #expect(third.deferred.isEmpty)
        #expect(third.evicted == ["test.oldA"], "the oldest retained schema must be evicted")
        #expect(discovery.revision == revisionBefore + 1, "a disappearance must change the revision")
        #expect(discovery.takeEvictionNotices() == ["test.oldA"], "the eviction must be surfaced")
        #expect(!discovery.loaded.contains("test.oldA"))
        #expect(Set(discovery.loaded) == ["test.newD", "test.newE", "test.newF"])
    }

    @Test("a newer retained definition keeps its schema while the older one is evicted, never the reverse")
    func newerRetainedOutranksOlder() {
        var discovery = paddedDiscovery([
            (name: "test.oldA", padding: 12_000),
            (name: "test.newerB", padding: 12_000),
        ])
        // Room for exactly one padded schema after the name ledger.
        let budget = 20_000
        _ = discovery.load(["test.oldA"], maxBytes: budget)
        let second = discovery.load(["test.newerB"], maxBytes: budget)

        #expect(second.admitted == ["test.newerB"])
        #expect(second.evicted == ["test.oldA"], "the older schema must not outlive the newer one")
        #expect(discovery.loaded == ["test.newerB"])
        #expect(discovery.takeEvictionNotices() == ["test.oldA"])
    }

    @Test("a protected previously loaded schema is retained ahead of ordinary retention")
    func protectedRetainedSurvivesBudgetPressure() {
        var discovery = paddedDiscovery([
            (name: "test.protectedA", padding: 9_000),
            (name: "test.ordinaryB", padding: 9_000),
            (name: "test.newC", padding: 9_000),
        ])
        // Room for the new request plus exactly ONE of the two retained
        // schemas; recency would keep ordinaryB, the protected contract keeps
        // protectedA.
        let budget = 25_000
        _ = discovery.load(["test.protectedA"], maxBytes: budget, protected: ["test.protectedA"])
        _ = discovery.load(["test.ordinaryB"], maxBytes: budget, protected: ["test.protectedA"])
        #expect(Set(discovery.loaded) == ["test.protectedA", "test.ordinaryB"])
        let third = discovery.load(["test.newC"], maxBytes: budget, protected: ["test.protectedA"])

        #expect(third.admitted == ["test.newC"])
        #expect(discovery.loaded.contains("test.protectedA"), "a protected schema is never evicted")
        #expect(!discovery.loaded.contains("test.ordinaryB"))
        #expect(third.evicted == ["test.ordinaryB"])
        #expect(discovery.takeEvictionNotices() == ["test.ordinaryB"])
    }

    @Test("a new request cannot displace the only protected schema")
    func protectedSchemaReservesBudgetBeforeNewRequest() {
        var discovery = paddedDiscovery([
            (name: "test.protectedA", padding: 9_000),
            (name: "test.newB", padding: 9_000),
        ])
        let budget = 15_000
        _ = discovery.load(["test.protectedA"], maxBytes: budget)
        let receipt = discovery.load(
            ["test.newB"], maxBytes: budget, protected: ["test.protectedA"]
        )
        #expect(discovery.loaded == ["test.protectedA"])
        #expect(receipt.admitted.isEmpty)
        #expect(receipt.deferred == ["test.newB"])
        #expect(receipt.oversized.isEmpty)
        #expect(receipt.evicted.isEmpty)
        #expect(discovery.takeEvictionNotices().isEmpty)
    }

    @Test("a new request that cannot fit is deferred, never reported as an evicted older name")
    func unloadedRequestIsDeferredNotEvicted() {
        var discovery = paddedDiscovery([
            (name: "test.a", padding: 11_000),
            (name: "test.b", padding: 11_000),
            (name: "test.c", padding: 11_000),
        ])
        let receipt = discovery.load(["test.a", "test.b", "test.c"], maxBytes: 30_000)
        #expect(receipt.admitted == ["test.a", "test.b"])
        #expect(receipt.deferred == ["test.c"])
        #expect(receipt.oversized.isEmpty)
        #expect(receipt.evicted.isEmpty)
        #expect(discovery.takeEvictionNotices().isEmpty)
    }

    @Test("a single definition too large for the whole schema budget is reported for itself and never aborts")
    func oversizedSingleDefinitionIsReportedForItself() {
        var discovery = paddedDiscovery([
            (name: "test.huge", padding: 60_000),
            (name: "test.small", padding: 40),
        ])
        let receipt = discovery.load(["test.huge"], maxBytes: 30_000)
        #expect(receipt.oversized["test.huge"] != nil)
        #expect(receipt.deferred.isEmpty)
        #expect(receipt.evicted.isEmpty)
        #expect(discovery.loaded.isEmpty)

        // The child is not aborted: a later, feasible load still works.
        let second = discovery.load(["test.small"], maxBytes: 30_000)
        #expect(second.admitted == ["test.small"])
    }

    // MARK: - Compat wire (OpenAI / Anthropic / DeepSeek naming)

    @Test("child requests stay wire-ready for OpenAI Responses, OpenAI Chat and Anthropic bodies")
    func compatWireBodiesStayBounded() async throws {
        let names = ["test.echo", "test.write"]
        let adapter = MockAdapter()
        let executor = BulkExecutor(names: names, schemaPadding: 4_000)
        let read = try TestFixtures.toolCall(id: "r-1", toolName: "test.echo", arguments: #"{"v":"x"}"#)
        adapter.script = [
            [.toolRequest(read)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runner = makeRunner(adapter: adapter, executor: executor)
        let outcome = try await runner.runStructured(exploreRequest(), context: plainContext())
        #expect(outcome.status == .completed)
        let feedback = try #require(adapter.requests.last)
        let ledger = SubagentRunner.contextWireBytes(of: feedback)
        let allowance = SubagentRunner.maximumRequestContextBytes
            + SubagentRunner.maximumFrozenToolSchemaBytes
            + SubagentRunner.wireEnvelopeAllowanceBytes
        let refreshed = feedback.refreshingRuntimeClock()
        let bodies: [(String, Data)] = [
            ("chat", try ProviderWireEncoder.encode(OpenAIChatCompletionsAdapter().buildBody(from: refreshed))),
            ("anthropic", try ProviderWireEncoder.encode(AnthropicMessagesAdapter().buildBody(from: refreshed))),
            ("responses", try ProviderWireEncoder.encode(OpenAIResponsesAdapter().buildBody(from: refreshed)))
        ]
        for (name, body) in bodies {
            #expect(body.count <= allowance, "\(name) body \(body.count) exceeds \(allowance)")
            #expect(body.count <= ledger + SubagentRunner.wireEnvelopeAllowanceBytes)
        }
    }

    @Test("a DeepSeek-style compat provider receives underscored discovery names and reverse-maps them")
    func deepSeekCompatNamesRoundTrip() async throws {
        var provider = TestFixtures.localhostProvider(wireProtocol: .openAIChatCompletions)
        provider = ProviderProfile(
            id: provider.id,
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: provider.baseURL,
            displayName: "DeepSeek",
            presetID: nil,
            secretRef: nil,
            region: nil,
            nonSecretHeaders: [:],
            isEnabled: true,
            allowsPlainHTTP: false,
            toolNameCompatibility: true,
            createdAt: provider.createdAt,
            updatedAt: provider.updatedAt,
            syncRevision: provider.syncRevision
        )
        #expect(CompatToolNames.usesWireSafeNames(provider))
        let adapter = MockAdapter()
        let executor = BulkExecutor(names: ["test.echo"], schemaPadding: 200)
        let search = try TestFixtures.toolCall(
            id: "s-1", toolName: "tools.search", arguments: #"{"queries":["test.echo"]}"#
        )
        adapter.script = [
            [.toolRequest(search)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runner = SubagentRunner(
            provider: provider,
            model: TestFixtures.testModel(providerID: provider.id),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor
        )
        let outcome = try await runner.runStructured(exploreRequest(), context: plainContext())
        #expect(outcome.status == .completed)
        let request = try #require(adapter.requests.last)
        #expect(request.toolSchemas.contains { $0.name == "tools.search" })
        // The wire name is underscored and reverse-maps to the canonical name
        // using the child's own ceiling mapping.
        #expect(CompatToolNames.wireName("tools.search", for: provider) == "tools_search")
        #expect(CompatToolNames.canonicalName("tools_search", request: request) == "tools.search")
        let body = try ProviderWireEncoder.encode(
            OpenAIChatCompletionsAdapter().buildBody(from: request.refreshingRuntimeClock())
        )
        let text = String(decoding: body, as: UTF8.self)
        #expect(text.contains("tools_search"))
        // The wire declares the underscored function name; the dotted canonical
        // spelling never appears as a schema name. (The child's own system
        // prompt may legitimately mention the canonical name in prose.)
        #expect(!text.contains(#""name":"tools.search""#))
        #expect(!text.contains(#""name": "tools.search""#))
    }

    // MARK: - Child-local skill activation and state isolation

    @Test("skill.read activates declared dependencies inside the child, never relying on the parent audit")
    func skillReadActivatesInChild() async throws {
        // No runtime and no dispatcher audit path: a plain recording
        // dispatcher proves the activation happens in the child itself.
        let executor = MockExecutor()
        executor.descriptors["test.artifact"] = .init(
            name: "test.artifact", riskLabels: [], isSideEffecting: true
        )
        let adapter = MockAdapter()
        let skillRead = try TestFixtures.toolCall(
            id: "skill-1", toolName: "skill.read", arguments: #"{"id":"floe-test-guide"}"#
        )
        adapter.script = [
            [.toolRequest(skillRead)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runner = makeRunner(adapter: adapter, executor: executor)
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil },
            allDescriptors: { [] },
            dispatch: { call, _ in
                ToolResult(
                    callID: call.id, status: .ok,
                    outputSummary: #"[{"id":"floe-test-guide","digest":"rev-7","requiredToolNames":["test.artifact"]}]"#,
                    outputDigest: "d"
                )
            }
        )
        let identity = ChildExecutionIdentity(parentRunID: UUID(), rootTaskID: UUID(), delegateCallID: "d")
        let bus = SubagentPeerBus()
        var context = ToolContext(
            runID: identity.parentRunID,
            scope: .local,
            allowedToolNames: ["test.artifact"],
            cancellation: CancellationToken(),
            childBudget: discoveryBudgetContext(),
            conversationID: identity.rootTaskID,
            childExecution: ChildExecutionHandoff(
                identity: identity, dispatcher: dispatcher, peers: bus.handle(for: identity)
            )
        )
        context.childBudget = discoveryBudgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .completed)
        #expect(!adapter.requests[0].toolSchemas.contains { $0.name == "test.artifact" })
        #expect(adapter.requests[1].toolSchemas.contains { $0.name == "test.artifact" })
        #expect(outcome.evidence.contains { $0.contains("skill.read floe-test-guide revision=rev-7") })
    }

    @Test("a guide declaring a tool outside the child ceiling loads nothing (metadata is not permission)")
    func skillDependenciesRespectCeiling() async throws {
        let executor = MockExecutor()
        executor.descriptors["test.allowed"] = .init(
            name: "test.allowed", riskLabels: [], isSideEffecting: false
        )
        let adapter = MockAdapter()
        let skillRead = try TestFixtures.toolCall(
            id: "skill-2", toolName: "skill.read", arguments: #"{"id":"floe-test-guide"}"#
        )
        adapter.script = [
            [.toolRequest(skillRead)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runner = makeRunner(adapter: adapter, executor: executor)
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil },
            allDescriptors: { [] },
            dispatch: { call, _ in
                ToolResult(
                    callID: call.id, status: .ok,
                    outputSummary: #"[{"id":"floe-test-guide","digest":"rev-1","requiredToolNames":["test.outsideCeiling","test.allowed"]}]"#,
                    outputDigest: "d"
                )
            }
        )
        let identity = ChildExecutionIdentity(parentRunID: UUID(), rootTaskID: UUID(), delegateCallID: "d")
        let bus = SubagentPeerBus()
        var context = ToolContext(
            runID: identity.parentRunID,
            scope: .local,
            allowedToolNames: ["test.allowed"],
            cancellation: CancellationToken(),
            conversationID: identity.rootTaskID,
            childExecution: ChildExecutionHandoff(
                identity: identity, dispatcher: dispatcher, peers: bus.handle(for: identity)
            )
        )
        context.childBudget = discoveryBudgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .completed)
        #expect(adapter.requests[1].toolSchemas.contains { $0.name == "test.allowed" })
        #expect(!adapter.requests[1].toolSchemas.contains { $0.name == "test.outsideCeiling" })
    }

    @Test("a child's skill.read never mutates the parent's discovery state or persists it")
    func childSkillReadDoesNotActivateParentDiscovery() async throws {
        // A real persistence store proves the parent's discovery was neither
        // mutated nor saved by a CHILD's skill.read.
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationDiscoveryStore(database: database)
        let conversationID = UUID()

        let json = #"[{"id":"floe-test-guide","digest":"rev-1","requiredToolNames":["test.artifact"]}]"#
        final class SkillExecutor: ToolExecutor, @unchecked Sendable {
            let json: String
            private let storage = AsyncLock<[String]>([])
            init(json: String) { self.json = json }
            var executed: [String] { storage.withLock { $0 } }
            func descriptor(named name: String) -> ToolCatalog.Descriptor? {
                switch name {
                case "skill.read": return .init(name: "skill.read", riskLabels: [], isSideEffecting: false)
                case "test.artifact": return .init(name: "test.artifact", riskLabels: [], isSideEffecting: false)
                default: return nil
                }
            }
            var allDescriptors: [ToolCatalog.Descriptor] {
                [
                    .init(name: "skill.read", riskLabels: [], isSideEffecting: false),
                    .init(name: "test.artifact", riskLabels: [], isSideEffecting: false)
                ]
            }
            func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
                storage.withLock { $0.append(call.toolName) }
                if call.toolName == "skill.read" {
                    return ToolResult(callID: call.id, status: .ok, outputSummary: json, outputDigest: "d")
                }
                return ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
            }
        }
        let executor = SkillExecutor(json: json)
        let provider = TestFixtures.localhostProvider()
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(try TestFixtures.toolCall(
                id: "skill-main", toolName: "skill.read", arguments: #"{"id":"floe-test-guide"}"#
            ))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                allowedToolNames: ["skill.read", "test.artifact"]
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            discoveryStore: store
        )

        // 1. A CHILD's skill.read is audited in the child's own scope: the
        //    parent's discovery store stays untouched.
        let childRead = try TestFixtures.toolCall(
            id: "skill-child", toolName: "skill.read", arguments: #"{"id":"floe-test-guide"}"#
        )
        let identity = ChildExecutionIdentity(
            parentRunID: await runtime.runID, rootTaskID: conversationID, delegateCallID: "d"
        )
        let childResult = await runtime.dispatchChildTool(
            childRead,
            identity: identity,
            childContext: ToolContext(
                runID: await runtime.runID,
                allowedToolNames: ["skill.read", "test.artifact"],
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 2, reserve: { true }, finish: {}),
                conversationID: conversationID
            )
        )
        #expect(childResult.status == .ok)
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterChild = try await store.load(conversationID: conversationID)
        #expect(afterChild == nil, "a child's skill.read must not persist parent discovery")

        // 2. Control: the SAME skill.read as the main run's own call does
        //    activate + persist the parent's discovery, proving the assertion
        //    above is sensitive.
        try await runtime.start(goal: "read the guide")
        var saved: (names: Set<String>, priority: [String])?
        var attempts = 0
        while saved == nil, attempts < 50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            saved = try await store.load(conversationID: conversationID)
            attempts += 1
        }
        #expect(saved?.names.contains("test.artifact") == true)
    }

    @Test("two sibling children never share discovery state: one child's loads stay out of the other's wire")
    func siblingDiscoveryStateIsIsolated() async throws {
        let executor = MockExecutor()
        executor.descriptors["test.artifact"] = .init(
            name: "test.artifact", riskLabels: [], isSideEffecting: true
        )
        let bus = SubagentPeerBus()
        let identityA = ChildExecutionIdentity(parentRunID: UUID(), rootTaskID: UUID(), delegateCallID: "dA")
        let identityB = ChildExecutionIdentity(
            parentRunID: identityA.parentRunID, rootTaskID: identityA.rootTaskID, delegateCallID: "dB"
        )
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil },
            allDescriptors: { [] },
            dispatch: { call, _ in
                ToolResult(
                    callID: call.id, status: .ok,
                    outputSummary: #"[{"id":"floe-test-guide","digest":"rev-1","requiredToolNames":["test.artifact"]}]"#,
                    outputDigest: "d"
                )
            }
        )
        let readerAdapter = MockAdapter()
        let readerSkill = try TestFixtures.toolCall(
            id: "skill-A", toolName: "skill.read", arguments: #"{"id":"floe-test-guide"}"#
        )
        readerAdapter.script = [
            [.toolRequest(readerSkill)],
            [.textDelta(.init(text: "A done")), .completed(.init(stopReason: .endTurn))]
        ]
        let reader = makeRunner(adapter: readerAdapter, executor: executor)
        var readerContext = ToolContext(
            runID: identityA.parentRunID,
            allowedToolNames: ["test.artifact"],
            cancellation: CancellationToken(),
            childBudget: discoveryBudgetContext(),
            childExecution: ChildExecutionHandoff(
                identity: identityA, dispatcher: dispatcher, peers: bus.handle(for: identityA)
            )
        )
        readerContext.childBudget = discoveryBudgetContext()
        _ = try await reader.runStructured(exploreRequest(), context: readerContext)

        let siblingAdapter = MockAdapter()
        siblingAdapter.script = [[.textDelta(.init(text: "B done")), .completed(.init(stopReason: .endTurn))]]
        let sibling = makeRunner(adapter: siblingAdapter, executor: executor)
        var siblingContext = ToolContext(
            runID: identityB.parentRunID,
            allowedToolNames: ["test.artifact"],
            cancellation: CancellationToken(),
            childBudget: discoveryBudgetContext(),
            childExecution: ChildExecutionHandoff(
                identity: identityB, dispatcher: dispatcher, peers: bus.handle(for: identityB)
            )
        )
        siblingContext.childBudget = discoveryBudgetContext()
        _ = try await sibling.runStructured(exploreRequest(), context: siblingContext)

        #expect(readerAdapter.requests[1].toolSchemas.contains { $0.name == "test.artifact" })
        #expect(!siblingAdapter.requests[0].toolSchemas.contains { $0.name == "test.artifact" })
    }

    @Test("sibling messages still arrive at the child's next safe boundary under progressive discovery")
    func peerDeliveryUnderDiscovery() async throws {
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = .init(name: "test.echo", riskLabels: [], isSideEffecting: false)
        let runID = UUID()
        let root = UUID()
        let bus = SubagentPeerBus()
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: root, delegateCallID: "d")
        let sibling = ChildExecutionIdentity(parentRunID: runID, rootTaskID: root, delegateCallID: "d2")
        await bus.register(identity, label: "worker")
        await bus.register(sibling, label: "sender")
        _ = await bus.send(from: sibling.childID, to: identity.childID, body: "claiming a.md", clientMessageID: "m1")

        let adapter = MockAdapter()
        let read = try TestFixtures.toolCall(id: "r-1", toolName: "test.echo")
        adapter.script = [
            [.toolRequest(read)],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let runner = makeRunner(adapter: adapter, executor: executor)
        let dispatcher = ChildToolDispatcher(
            descriptorProvider: { _ in nil },
            allDescriptors: { [] },
            dispatch: { call, _ in ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d") }
        )
        var context = ToolContext(
            runID: runID,
            allowedToolNames: ["test.echo"],
            cancellation: CancellationToken(),
            childBudget: discoveryBudgetContext(),
            conversationID: root,
            childExecution: ChildExecutionHandoff(
                identity: identity, dispatcher: dispatcher, peers: bus.handle(for: identity)
            )
        )
        context.childBudget = discoveryBudgetContext()
        let outcome = try await runner.runStructured(exploreRequest(), context: context)
        #expect(outcome.status == .completed)
        let followUp = try #require(adapter.requests.last)
        let joined = followUp.effectiveMessages.flatMap(\.content).compactMap { part -> String? in
            if case .text(let text) = part { return text }
            return nil
        }.joined(separator: "\n")
        #expect(joined.contains("claiming a.md"))
        #expect(joined.contains("untrusted coordination data"))
        #expect(outcome.evidence.contains { $0.contains("delegate.peers 1 message(s) delivered") })
    }
}
