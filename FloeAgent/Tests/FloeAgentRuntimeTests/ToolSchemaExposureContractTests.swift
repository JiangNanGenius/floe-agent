import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloeTestSupport
@testable import FloeAgentRuntime

/// Captures real runtime dispatch requests; never invokes a provider/model.
private final class ExposureRequestAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let captured = AsyncLock<[ProviderStreamRequest]>([])
    let events: @Sendable (ProviderStreamRequest, Int) async throws -> [AgentEvent]
    init(_ events: @escaping @Sendable (ProviderStreamRequest, Int) async throws -> [AgentEvent]) {
        self.events = events
    }
    var requests: [ProviderStreamRequest] { captured.withLock { $0 } }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        let index = captured.withLock { requests -> Int in
            requests.append(request)
            return requests.count - 1
        }
        return AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    for event in try await self.events(request, index) { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

@Suite("Actual dispatched tool schema exposure")
struct ToolSchemaExposureContractTests {
    private static func descriptor(_ name: String, padding: Int = 0) -> ToolCatalog.Descriptor {
        .init(name: name, toolDescription: "Read a fixture value. " + String(repeating: "d", count: padding),
              parametersJSON: #"{"type":"object","properties":{},"additionalProperties":false}"#,
              riskLabels: [], isSideEffecting: false)
    }
    private static func done() -> [AgentEvent] {
        [.textDelta(.init(text: "Done")), .completed(.init(stopReason: .endTurn))]
    }
    private static func use(_ call: ToolCall) -> [AgentEvent] {
        [.toolRequest(call), .completed(.init(stopReason: .toolUse))]
    }
    private static func listCall(id: String, after: String? = nil, limit: Int = 100) throws -> ToolCall {
        var args: [String: Any] = ["group": "workspace", "limit": limit]
        if let after { args["afterName"] = after }
        return try TestFixtures.toolCall(id: id, toolName: "tools.list",
            arguments: String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self))
    }
    private static func rows(_ request: ProviderStreamRequest, callID: String) throws -> [[String: Any]] {
        let result = try #require(request.toolResults.first { $0.callID == callID })
        let call = try #require(request.pendingToolCalls.first { $0.id == callID })
        try #require(call.toolName == ToolDiscovery.listName)
        // modelVisibleToolResult prepends one compact runtime provenance JSON
        // line, then preserves the complete tool body after a single newline.
        // Parse those two bounded sections independently; do not strip an
        // arbitrary JSON prefix, remove evidence or accept a truncated body.
        let sections = result.output.split(separator: "\n", maxSplits: 1,
            omittingEmptySubsequences: false)
        try #require(sections.count == 2)
        try #require(sections[0].utf8.count <= 16_384 && sections[1].utf8.count <= 262_144)
        let envelope = try #require(JSONSerialization.jsonObject(
            with: Data(sections[0].utf8)) as? [String: Any])
        try #require(envelope["toolName"] as? String == call.toolName)
        let sourceID = try #require(envelope["trustedSourceID"] as? String)
        try #require(sourceID.count == 64 && sourceID.allSatisfy { $0.isHexDigit })
        let runID = try #require(envelope["runID"] as? String)
        try #require(UUID(uuidString: runID) != nil && runID == request.diagnosticRunID)
        let object = try #require(JSONSerialization.jsonObject(
            with: Data(sections[1].utf8)) as? [String: Any])
        return try #require(object["tools"] as? [[String: Any]])
    }
    private func runtime(adapter: any ProviderAdapter, executor: MockExecutor, provider: ProviderProfile,
                         window: Int = 65_536, allowed: Set<String>? = nil,
                         cloudAgentBase: Bool = false, store: MockCheckpointStore = MockCheckpointStore()) -> FloeAgentRuntime {
        let model = ModelProfile(providerID: provider.id, remoteModelID: "exposure-contract",
            displayName: "Exposure contract", limits: .init(contextTokens: window, maxOutputTokens: 2_048),
            capabilities: [.text, .tools])
        var configuration = FloeAgentRuntime.Configuration(provider: provider, model: model,
            allowedToolNames: allowed, maxProviderRetries: 0)
        configuration.offersCloudAgentBaseTools = cloudAgentBase
        return FloeAgentRuntime(configuration: configuration, adapter: adapter,
            policy: HumanApprovalPolicy(), executor: executor, checkpointStore: store,
            liveSystemContext: { "Owned read-only fixture context." })
    }

    @Test func cloudAgentBaseIsOfferedWithoutDiscoveryWithinTheLiveCeiling() async throws {
        let names = ToolDiscovery.cloudAgentCoreNames
        #expect(names.count == 45) // The runtime provides three discovery helpers.
        let disabled = "memory.forget"
        let executor = MockExecutor()
        for name in names.union(["image.view", "delegate.peers"]) {
            executor.descriptors[name] = Self.descriptor(name)
        }
        let allowed = Set(executor.descriptors.keys).subtracting([disabled])
        for enabled in [false, true] {
            let adapter = ExposureRequestAdapter { _, _ in Self.done() }
            let agent = runtime(adapter: adapter, executor: executor, provider: TestFixtures.localhostProvider(),
                                allowed: allowed, cloudAgentBase: enabled)
            try await agent.start(goal: "Hello")
            let request = try #require(adapter.requests.first)
            let offered = Set(request.toolSchemas.map(\.name))
            let expected = (enabled ? names : ToolDiscovery.coreNames).subtracting([disabled])
                .union([ToolDiscovery.name, ToolDiscovery.listName, ToolResultPagingTool.name])
            #expect(offered == expected)
        }
    }

    @Test func finalReadmissionEvictionIsFalseInActualListResponse() async throws {
        let executor = MockExecutor()
        for index in 0..<60 {
            let name = String(format: "workspace.op%03d", index)
            executor.descriptors[name] = Self.descriptor(name, padding: 600)
        }
        let provider = TestFixtures.localhostProvider(), store = MockCheckpointStore()
        let lateTarget = AsyncLock<String?>(nil)
        let adapter = ExposureRequestAdapter { request, index in
            guard index == 0 else { return Self.done() }
            // The real checkpoint retains the pre-guidance messages. Prove
            // the fixture reached second-pass eviction, rather than merely
            // choosing a definition too large at the first admission.
            let checkpoint = try #require(store.saved.first { $0.providerDispatchRequest != nil })
            let descriptors = executor.allDescriptors
            let matches = ToolDiscovery.matches(query: "workspace", descriptors: descriptors)
            var candidates = ToolSchemaOfferPlanner.prioritized(matches,
                priority: matches.map(\.name), pinned: [], coreNames: ToolDiscovery.coreNames)
            candidates += ToolDiscovery.runtimeDescriptors(publicWebOnly: false)
            let budget = ToolSchemaOfferPlanner.availableTokenBudget(contextWindowTokens: 16_384,
                reservedOutputTokens: 2_048,
                messageTokens: ContextTokenEstimator().estimate(checkpoint.messages),
                imageTokens: 0, replayTokens: 0, toolResultReserveTokens: 4_096,
                minimumDiscoveryTokens: ToolSchemaOfferPlanner.tokenCost(ToolDiscovery.descriptor))
            let initial = ToolSchemaOfferPlanner.plan(descriptors: candidates, tokenBudget: budget,
                alwaysKeep: [ToolDiscovery.name, ToolDiscovery.listName, ToolResultPagingTool.name],
                discoveryName: ToolDiscovery.name)
            let finalNames = Set(request.toolSchemas.map(\.name))
            let target = try #require(initial.offered.first {
                $0.name.hasPrefix("workspace.") && !finalNames.contains($0.name)
            }?.name, "Fixture must produce an actual second-admission eviction")
            lateTarget.withLock { $0 = target }
            let ordered = descriptors.map(\.name).sorted()
            let position = try #require(ordered.firstIndex(of: target))
            return Self.use(try Self.listCall(id: "late-list",
                after: position > 0 ? ordered[position - 1] : nil, limit: 1))
        }
        let agent = runtime(adapter: adapter, executor: executor, provider: provider, window: 16_384, store: store)
        try await agent.start(goal: "workspace")
        try #require(adapter.requests.count == 2)
        let target = try #require(lateTarget.withLock { $0 })
        let row = try #require(try Self.rows(adapter.requests[1], callID: "late-list").first)
        #expect(row["name"] as? String == target)
        #expect(row["schemaLoaded"] as? Bool == false)
        #expect(!adapter.requests[0].toolSchemas.contains { $0.name == target })
        for schema in adapter.requests[0].toolSchemas where schema.name.hasPrefix("workspace.") {
            #expect(schema.parametersJSON == executor.descriptor(named: schema.name)?.parametersJSON)
        }
    }

    @Test func exactSearchDeferralDoesNotClaimSchemaWasSent() async throws {
        let executor = MockExecutor()
        executor.descriptors["workspace.huge"] = Self.descriptor("workspace.huge", padding: 300_000)
        let adapter = ExposureRequestAdapter { _, index in
            if index == 0 {
                return Self.use(try TestFixtures.toolCall(id: "activate", toolName: ToolDiscovery.name,
                    arguments: #"{"query":"workspace.huge"}"#))
            }
            if index == 1 { return Self.use(try Self.listCall(id: "deferred-list")) }
            return Self.done()
        }
        let agent = runtime(adapter: adapter, executor: executor, provider: TestFixtures.localhostProvider())
        try await agent.start(goal: "Begin")
        try #require(adapter.requests.count == 3)
        #expect(!adapter.requests[1].toolSchemas.contains { $0.name == "workspace.huge" })
        let summary = try #require(adapter.requests[1].toolResults.first { $0.callID == "activate" }?.output)
        #expect(summary.contains("candidate") && !summary.contains("Loaded for the next request"))
        let row = try #require(try Self.rows(adapter.requests[2], callID: "deferred-list").first)
        #expect(row["schemaLoaded"] as? Bool == false)
    }

    @Test func byteBoundedSearchOffersMoreThan23AndNeverRevivesDisabledTools() async throws {
        let executor = MockExecutor()
        for index in 0..<40 {
            let name = String(format: "workspace.small%02d", index)
            executor.descriptors[name] = Self.descriptor(name)
        }
        let disabled = "workspace.small39"
        let allowed = Set(executor.allDescriptors.map(\.name)).subtracting([disabled])
        let adapter = ExposureRequestAdapter { _, index in
            if index == 0 {
                return Self.use(try TestFixtures.toolCall(id: "many-search", toolName: ToolDiscovery.name,
                    arguments: #"{"query":"workspace"}"#))
            }
            if index == 1 { return Self.use(try Self.listCall(id: "many-list")) }
            return Self.done()
        }
        let provider = TestFixtures.localhostProvider()
        let agent = runtime(adapter: adapter, executor: executor, provider: provider,
                            window: 131_072, allowed: allowed)
        try await agent.start(goal: "Begin")
        try #require(adapter.requests.count == 3)
        #expect(Set(adapter.requests[1].toolSchemas.map(\.name)).isSuperset(of: allowed))
        #expect(adapter.requests[1].toolSchemas.filter { $0.name.hasPrefix("workspace.") }.count == 39)
        #expect(adapter.requests.allSatisfy { !$0.allToolNames.contains(disabled) })
        let rows = try Self.rows(adapter.requests[2], callID: "many-list")
        #expect(rows.count == 39 && rows.allSatisfy { $0["schemaLoaded"] as? Bool == true })
        // The child uses the same byte-bounded search, not the implicit 23 cap.
        var child = ChildToolDiscovery(descriptors: executor.allDescriptors.filter {
            allowed.contains($0.name)
        }, seedNames: [])
        let call = try TestFixtures.toolCall(id: "child-many", toolName: ToolDiscovery.name,
            arguments: #"{"query":"workspace"}"#)
        _ = SubagentRunner.localDiscoverySearchResult(call, discovery: &child,
            provider: provider, maxSchemaBytes: 200_000)
        #expect(allowed.isSubset(of: Set(child.loaded)))
        #expect(!child.loaded.contains(disabled))
        #expect(ToolDiscovery.bounded(executor.allDescriptors, priority: [], maxTools: 2).count == 2)
    }

    @Test func localFinalSelectionAndLateOldAttemptCallbackStayIsolated() async throws {
        let executor = MockExecutor()
        for name in ["workspace.visible", "workspace.hidden", "archive.history"] { executor.descriptors[name] = Self.descriptor(name) }
        var provider = TestFixtures.localhostProvider(); provider.kind = .local
        let oldCallback = AsyncLock<(@Sendable ([String]) async -> Void)?>(nil)
        let adapter = ExposureRequestAdapter { request, index in
            if index == 0 {
                oldCallback.withLock { $0 = request.onToolSchemasPrepared }
                await request.onToolSchemasPrepared?(["tools.list", "workspace.hidden"])
                return Self.use(try TestFixtures.toolCall(id: "refresh", toolName: ToolDiscovery.name,
                    arguments: #"{"query":"workspace"}"#))
            }
            if index == 1 {
                await request.onToolSchemasPrepared?(["tools.list", "workspace.visible", "archive.history", "not.in.catalog"])
                // A delayed receipt from request 0 must not replace request 1.
                if let old = oldCallback.withLock({ $0 }) { await old(["tools.list", "workspace.hidden"]) }
                return Self.use(try TestFixtures.toolCall(id: "local-list", toolName: ToolDiscovery.listName, arguments: #"{"limit":100}"#))
            }
            return Self.done()
        }
        let agent = runtime(adapter: adapter, executor: executor, provider: provider)
        try await agent.start(goal: "workspace")
        try #require(adapter.requests.count == 3)
        #expect(adapter.requests[1].toolSchemas.contains { $0.name == "workspace.hidden" })
        #expect(!adapter.requests[1].toolSchemas.contains { $0.name == "archive.history" })
        let rows = try Self.rows(adapter.requests[2], callID: "local-list")
        #expect(rows.first { $0["name"] as? String == "workspace.visible" }?["schemaLoaded"] as? Bool == true)
        #expect(rows.first { $0["name"] as? String == "workspace.hidden" }?["schemaLoaded"] as? Bool == false)
        #expect(rows.first { $0["name"] as? String == "archive.history" }?["schemaLoaded"] as? Bool == true)
        #expect(!rows.contains { $0["name"] as? String == "not.in.catalog" })
    }

    @Test func childListWithoutAnActualDispatchIsNotHistoricallyLoaded() throws {
        let source = [Self.descriptor("workspace.visible")]
        var child = ChildToolDiscovery(descriptors: source, seedNames: [])
        _ = child.load(["workspace.visible"], maxBytes: 50_000)
        let call = try Self.listCall(id: "child-list")
        let provider = TestFixtures.localhostProvider()
        let before = SubagentRunner.localDiscoveryListResult(call, discovery: child, provider: provider)
        let object = try #require(JSONSerialization.jsonObject(with: Data(before.outputSummary.utf8)) as? [String: Any])
        let rows = try #require(object["tools"] as? [[String: Any]])
        #expect(rows.first?["schemaLoaded"] as? Bool == false)
        let sent = SubagentRunner.localDiscoveryListResult(call, discovery: child, provider: provider,
            offeredNames: ["workspace.visible"])
        let sentObject = try #require(JSONSerialization.jsonObject(with: Data(sent.outputSummary.utf8)) as? [String: Any])
        let sentRows = try #require(sentObject["tools"] as? [[String: Any]])
        #expect(sentRows.first?["schemaLoaded"] as? Bool == true)
    }
    @Test func compactFallbackCarriesLiveGroupsWithoutRevivingDisabledGroup() async throws {
        let executor = MockExecutor()
        for name in ["cad.document", "studio.list", "studio.read", "studio.run", "studio.media", "studio.chemistry"] {
            executor.descriptors[name] = Self.descriptor(name)
        }
        executor.descriptors["disabledFixture.read"] = Self.descriptor("disabledFixture.read")
        let allowed = Set(executor.allDescriptors.map(\.name)).subtracting(["disabledFixture.read"])
        let provider = TestFixtures.localhostProvider()
        let model = ModelProfile(providerID: provider.id, remoteModelID: "compact-directory",
            displayName: "Compact directory", limits: .init(contextTokens: 16_384, maxOutputTokens: 2_048),
            capabilities: [.text, .tools])
        let adapter = ExposureRequestAdapter { _, _ in Self.done() }
        let context = "Protected fixture context " + String(repeating: "p", count: 24_000)
        let agent = FloeAgentRuntime(configuration: .init(provider: provider, model: model,
            allowedToolNames: allowed, maxProviderRetries: 0), adapter: adapter,
            policy: HumanApprovalPolicy(), executor: executor, checkpointStore: MockCheckpointStore(),
            liveSystemContext: { context })
        try await agent.start(goal: "Begin")
        let request = try #require(adapter.requests.first)
        let full = request.effectiveMessages.flatMap(\.content).compactMap { part -> String? in
            if case .text(let text) = part { return text }; return nil
        }.joined(separator: "\n")
        #expect(full.contains("Available tool groups (metadata only): cad (1), studio (5)"))
        #expect(!full.contains("disabledFixture"))
        #expect(!request.allToolNames.contains("disabledFixture.read"))
        #expect(request.toolSchemas.contains { $0.name == ToolDiscovery.name })
    }

}
