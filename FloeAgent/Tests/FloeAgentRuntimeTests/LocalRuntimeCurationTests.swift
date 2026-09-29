// FloeAgentRuntimeTests — Build 236 curated local ceiling at runtime level.
//
// Focused deterministic tests that the on-device ceiling is enforced at the
// runtime boundary (independent of the adapter prompt build):
//   * a local query's catalog contains only curated descriptors and a
//     discovery guess for a hidden tool never reintroduces it,
//   * tools.search inside a local run cannot load hidden tools,
//   * remembered (persisted) hidden tools stay hidden on a new local run,
//   * a cloud run keeps its full catalog, including tools local hides,
//   * the first turn never emits a schema-budget eviction notice.
//
// Scripted adapter/executor only; no network, weights or real model.

import Foundation
import Testing
@testable import FloeAgentRuntime
@testable import FloeProviders
@testable import FloeModels
@testable import FloeTools
@testable import FloeCore
@testable import FloeSecurity
@testable import FloePersistence
import FloeTestSupport

@Suite("Runtime local curation boundary")
struct LocalRuntimeCurationTests {
    private func makeProvider(local: Bool) -> ProviderProfile {
        var provider = TestFixtures.localhostProvider()
        if local { provider.kind = .local }
        return provider
    }

    private func makeModel(providerID: UUID) -> ModelProfile {
        TestFixtures.testModel(providerID: providerID)
    }

    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        .init(
            name: name,
            toolDescription: "Tool \(name)",
            parametersJSON: #"{"type":"object","properties":{"input":{"type":"string"}}}"#,
            riskLabels: [],
            isSideEffecting: false
        )
    }

    private func executor(names: [String]) -> MockExecutor {
        let executor = MockExecutor()
        for name in names {
            executor.descriptors[name] = descriptor(name)
        }
        return executor
    }

    @Test("A local run only presents curated descriptors even with hidden tools registered")
    func localCatalogIsCurated() async throws {
        let provider = makeProvider(local: true)
        let hidden = [
            "exec.shell", "exec.localPython",
            "environment.prepareLinux", "environment.startLinux", "environment.hardRestartLinux",
            "workspace.createFile", "workspace.writeFile", "workspace.applyPatch",
            "ssh.execute", "notes.edit", "git.commit"
        ]
        let curated = ["web.search", "workspace.readFile", "workspace.listDirectory"]
        let mockExecutor = executor(names: hidden + curated)
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: makeModel(providerID: provider.id)),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: mockExecutor
        )

        try await runtime.start(goal: "搜索今天的新闻")

        let request = try #require(adapter.requests.first)
        let presented = Set(request.toolSchemas.map(\.name))
        #expect(presented.isSubset(of: LocalModelToolPolicy.curatedCeilingNames))
        #expect(presented.intersection(hidden).isEmpty)
        #expect(presented.contains("web.search"))
    }

    @Test("A discovery guess for a hidden capability is never loaded on a local turn")
    func hiddenDiscoveryGuessIsDropped() async throws {
        let provider = makeProvider(local: true)
        let mockExecutor = executor(names: [
            "workspace.readFile", "exec.shell", "environment.prepareLinux"
        ])
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: makeModel(providerID: provider.id)),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: mockExecutor
        )

        // A shell-intent phrase that the generic discovery matcher would
        // match to exec.shell on an uncurated run.
        try await runtime.start(goal: "用 shell 执行命令检查一下")

        let request = try #require(adapter.requests.first)
        let presented = Set(request.toolSchemas.map(\.name))
        #expect(!presented.contains("exec.shell"))
        #expect(!presented.contains("environment.prepareLinux"))
        #expect(presented.contains("workspace.readFile"))
    }

    @Test("Cloud catalogs keep tools the local ceiling hides")
    func cloudCatalogIsUnchanged() async throws {
        let provider = makeProvider(local: false)
        let names = [
            "exec.shell", "environment.prepareLinux",
            "workspace.createFile", "web.search"
        ]
        let mockExecutor = executor(names: names)
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: makeModel(providerID: provider.id)),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: mockExecutor
        )

        try await runtime.start(goal: "用 shell 执行命令并创建文件")

        let request = try #require(adapter.requests.first)
        let presented = Set(request.toolSchemas.map(\.name))
        // Cloud keeps its dynamic discovery: exec.shell is a cloud core tool
        // and the presented set is not limited to the curated ceiling — proof
        // the local ceiling was not applied to cloud.
        #expect(presented.contains("exec.shell"))
        #expect(!presented.isSubset(of: LocalModelToolPolicy.curatedCeilingNames))
    }

    @Test("Remembered hidden tools stay hidden and pinned curated tools stay presented")
    func rememberedStateIsCurated() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationDiscoveryStore(database: database)
        let conversationID = UUID()
        // Persist a mix of hidden and curated names, as a previous build could
        // have saved before the ceiling existed.
        try await store.save(
            conversationID: conversationID,
            names: [
                "exec.shell", "environment.prepareLinux", "workspace.createFile",
                "web.search", "workspace.readFile"
            ],
            priority: ["exec.shell", "web.search"]
        )
        let provider = makeProvider(local: true)
        let mockExecutor = executor(names: [
            "web.search", "workspace.readFile",
            "exec.shell", "environment.prepareLinux"
        ])
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let runtime = FloeAgentRuntime(
            configuration: .init(
                conversationID: conversationID,
                provider: provider,
                model: makeModel(providerID: provider.id)
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: mockExecutor,
            discoveryStore: store
        )

        try await runtime.start(goal: "继续之前的工作")

        let request = try #require(adapter.requests.first)
        let presented = Set(request.toolSchemas.map(\.name))
        #expect(!presented.contains("exec.shell"))
        #expect(!presented.contains("environment.prepareLinux"))
        #expect(presented.contains("web.search"))
        #expect(presented.contains("workspace.readFile"))
    }

    @Test("The first turn never emits a schema-budget eviction notice")
    func firstTurnHasNoEvictionNotice() async throws {
        let provider = makeProvider(local: true)
        let padding = String(repeating: "x", count: 48)
        let fatSchema = #"{"type":"object","properties":{"#
            + (0..<19).map { "\"o\($0)\":{\"type\":\"string\",\"description\":\"\(padding)\"}" }.joined(separator: ",")
            + "}}"
        let mockExecutor = MockExecutor()
        for index in 0..<25 {
            let name = "workspace.readFile"
            let descriptorName = index == 0 ? name : "workspace.other\(index)"
            mockExecutor.descriptors[descriptorName] = .init(
                name: descriptorName,
                toolDescription: "candidate \(index)",
                parametersJSON: fatSchema,
                riskLabels: [],
                isSideEffecting: false
            )
        }
        let adapter = MockAdapter()
        adapter.script = [[.completed(.init(stopReason: .endTurn))]]
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: makeModel(providerID: provider.id)),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: mockExecutor
        )

        try await runtime.start(goal: "读取工作区文件")

        let request = try #require(adapter.requests.first)
        let systemText = request.messages.filter { $0.role == "system" }.map(\.content).joined()
        #expect(!systemText.contains("Schema budget unloaded"))
    }
}
