// FloeAgentRuntimeTests — Discovery budget eviction notices and catalog
// enumeration loop guard (regression tests for repeated tools.list loops).

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeSecurity
@testable import FloeTools
@testable import FloeCore
@testable import FloePersistence
import FloeTestSupport

@Suite("Tool discovery budget and catalog enumeration guard")
struct ToolDiscoveryHardeningTests {
    private func registerEcho(in executor: MockExecutor) {
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo",
            toolDescription: "Echo the provided text back.",
            parametersJSON: #"{"type":"object","properties":{"text":{"type":"string"}}}"#,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    @Test("Schema budget eviction is announced instead of silently dropping tools")
    func schemaEvictionIsAnnounced() async throws {
        let adapter = MockAdapter()
        let executor = MockExecutor()
        // Two groups with fat schemas: the 23 tools / 23KB presentation budget
        // cannot hold both, so loading the second group evicts the first.
        let padding = String(repeating: "x", count: 48)
        let optionEntries = (0..<20).map { "\"option\($0)\":{\"type\":\"string\",\"description\":\"\(padding)\"}" }
        let fatSchema = #"{"type":"object","properties":{"# + optionEntries.joined(separator: ",") + "}}"
        for index in 0..<20 {
            for group in ["alpha", "beta"] {
                let name = "\(group).t\(index)"
                executor.descriptors[name] = ToolCatalog.Descriptor(
                    name: name,
                    toolDescription: "\(group.capitalized) tool number \(index) for schema budget testing",
                    parametersJSON: fatSchema,
                    riskLabels: [],
                    isSideEffecting: false
                )
            }
        }
        adapter.script = [
            [.toolRequest(try ToolCall(id: "s1", toolName: "tools.search", argumentsJSON: Data(#"{"queries":["alpha"]}"#.utf8), scope: .local))],
            [.toolRequest(try ToolCall(id: "s2", toolName: "tools.search", argumentsJSON: Data(#"{"queries":["beta"]}"#.utf8), scope: .local))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let provider = TestFixtures.localhostProvider()
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: TestFixtures.testModel(providerID: provider.id)),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor
        )

        try await runtime.start(goal: "hello there")

        let third = try #require(adapter.requests.dropFirst(2).first)
        #expect(third.messages.contains {
            $0.role == "system"
                && $0.content.contains("Schema budget unloaded")
                && $0.content.contains("alpha.")
        })
        // The retained group stays visible as schemas.
        #expect(third.toolSchemas.contains { $0.name.hasPrefix("beta.") })
    }

    @Test("Repeated identical catalog enumerations are warned then stopped across epochs")
    func catalogEnumerationGuard() throws {
        var guardUnderTest = ToolLoopGuard()
        func call(_ tool: String, _ args: String, id: String) throws -> ToolCall {
            try ToolCall(id: id, toolName: tool, argumentsJSON: Data(args.utf8), scope: .local)
        }
        func ok(_ call: ToolCall, _ summary: String) -> ToolResult {
            ToolResult(callID: call.id, status: .ok, outputSummary: summary, outputDigest: "")
        }

        // First sweep across two pages plus a skill.list: all fresh, no warning.
        let page1First = try call("tools.list", #"{"limit":30}"#, id: "1")
        #expect(guardUnderTest.record(call: page1First, result: ok(page1First, "page-1"), isSideEffecting: false) == nil)
        let page2 = try call("tools.list", #"{"limit":30,"afterName":"image.scanBarcode"}"#, id: "2")
        #expect(guardUnderTest.record(call: page2, result: ok(page2, "page-2"), isSideEffecting: false) == nil)
        let skills1 = try call("skill.list", "{}", id: "3")
        #expect(guardUnderTest.record(call: skills1, result: ok(skills1, "skills"), isSideEffecting: false) == nil)

        // Interleaved productive work with fresh observations opens new epochs;
        // catalog repeat counts must survive those epoch advances.
        let read = try call("workspace.readFile", #"{"path":"a.txt"}"#, id: "4")
        #expect(guardUnderTest.record(call: read, result: ok(read, "new evidence"), isSideEffecting: false) == nil)

        // Repeating the exact same catalog page warns without blocking…
        let repeatPage1 = try call("tools.list", #"{"limit":30}"#, id: "5")
        let warningDecision = guardUnderTest.record(
            call: repeatPage1,
            result: ok(repeatPage1, "page-1 again"),
            isSideEffecting: false
        )
        let warning = try #require(warningDecision)
        #expect(!warning.shouldStop)
        #expect(warning.message.contains("already performed earlier in this turn"))

        // …and a third identical enumeration is stopped.
        let thirdPage1 = try call("tools.list", #"{"limit":30}"#, id: "6")
        let stoppedDecision = guardUnderTest.record(
            call: thirdPage1,
            result: ok(thirdPage1, "page-1 third"),
            isSideEffecting: false
        )
        let stopped = try #require(stoppedDecision)
        #expect(stopped.shouldStop)

        // skill.list has no arguments at all: a second identical call warns.
        let skills2 = try call("skill.list", "{}", id: "7")
        let skillWarningDecision = guardUnderTest.record(
            call: skills2,
            result: ok(skills2, "skills again"),
            isSideEffecting: false
        )
        let skillWarning = try #require(skillWarningDecision)
        #expect(!skillWarning.shouldStop)
    }

    @Test("Failed catalog enumerations do not consume the repeat budget")
    func catalogEnumerationFailuresNotCounted() throws {
        var guardUnderTest = ToolLoopGuard()
        let call = try ToolCall(id: "1", toolName: "skill.list", argumentsJSON: Data("{}".utf8), scope: .local)
        let failed = ToolResult(callID: call.id, status: .failed, outputSummary: "boom", outputDigest: "")
        #expect(guardUnderTest.record(call: call, result: failed, isSideEffecting: false) == nil)
        let ok = ToolResult(callID: call.id, status: .ok, outputSummary: "skills", outputDigest: "")
        #expect(guardUnderTest.record(call: call, result: ok, isSideEffecting: false) == nil)
    }

    @Test("Discovery state persists across runs of one conversation")
    func discoveryPersistsAcrossRuns() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationDiscoveryStore(database: database)
        let conversationID = UUID()

        let executor = MockExecutor()
        registerEcho(in: executor)
        let provider = TestFixtures.localhostProvider()
        var configuration = FloeAgentRuntime.Configuration(
            conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id)
        )
        let firstAdapter = MockAdapter()
        firstAdapter.script = [
            [.toolRequest(try ToolCall(id: "s1", toolName: "tools.search", argumentsJSON: Data(#"{"queries":["echo"]}"#.utf8), scope: .local))],
            [.completed(.init(stopReason: .endTurn))]
        ]
        let first = FloeAgentRuntime(
            configuration: configuration,
            adapter: firstAdapter, policy: HumanApprovalPolicy(), executor: executor,
            discoveryStore: store
        )
        try await first.start(goal: "hello there")
        #expect(firstAdapter.requests.dropFirst().first?.toolSchemas.contains { $0.name == "test.echo" } == true)

        // The persist hook is fire-and-forget; wait for the store write.
        let deadline = Date().addingTimeInterval(5)
        var persisted: (names: Set<String>, priority: [String])?
        while Date() < deadline {
            persisted = try await store.load(conversationID: conversationID)
            if persisted?.names.contains("test.echo") == true { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(persisted?.names.contains("test.echo") == true)

        // A fresh run on the same conversation reopens with the schema loaded —
        // no new tools.search round trip needed.
        configuration = FloeAgentRuntime.Configuration(
            conversationID: conversationID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id)
        )
        let secondAdapter = MockAdapter()
        secondAdapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let second = FloeAgentRuntime(
            configuration: configuration,
            adapter: secondAdapter, policy: HumanApprovalPolicy(), executor: executor,
            discoveryStore: store
        )
        try await second.start(goal: "something unrelated")
        let firstRequest = try #require(secondAdapter.requests.first)
        #expect(firstRequest.toolSchemas.contains { $0.name == "test.echo" })
    }
}
