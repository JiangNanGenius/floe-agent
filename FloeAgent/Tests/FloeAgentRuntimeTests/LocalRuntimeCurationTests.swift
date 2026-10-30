// FloeAgentRuntimeTests — local catalog now uses the REAL task authority.
//
// Focused deterministic tests for the user-approved change: local models get
// the same task-authorized tool catalog as cloud (no second curated-name
// fence), while temporary read-only/plan/user ceilings still narrow it and
// retired aliases stay denied. Intent pins are presentation hints, not an
// authorization whitelist.
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

    /// An on-device turn is only final once a visible answer reaches the user.
    /// A scripted `.completed` with no text is treated as an unfinished turn
    /// (the runtime requests one continuation), so every deterministic scripted
    /// run must include an actual final body or the mock will be exhausted.
    private var finalAnswerScript: [AgentEvent] {
        [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
    }

    @Test("Local geometry edits pin CAD without enabling it in temporary chat")
    func cadIntentKeepsTemporaryCeiling() async throws {
        for temporary in [false, true] {
            let provider = makeProvider(local: true)
            let mockExecutor = executor(names: ["cad.document", "workspace.readFile", "web.search", "exec.shell"])
            // The canonical CAD tool is mutating even though some actions read.
            mockExecutor.descriptors["cad.document"] = .init(name: "cad.document",
                toolDescription: "Inspect and edit CAD documents", parametersJSON: #"{"type":"object","required":["action"],"properties":{"action":{"type":"string"}}}"#,
                riskLabels: [], isSideEffecting: true)
            let adapter = MockAdapter()
            adapter.script = [finalAnswerScript]
            let runtime = FloeAgentRuntime(configuration: .init(provider: provider,
                model: makeModel(providerID: provider.id), temporaryReadOnly: temporary),
                adapter: adapter, policy: HumanApprovalPolicy(), executor: mockExecutor)
            try await runtime.start(goal: "把支架孔径改为 8 毫米并增加圆角")
            let request = try #require(adapter.requests.first)
            let names = Set(request.toolSchemas.map(\.name))
            #expect(names.contains("cad.document") == !temporary)
            // An ordinary local task may choose the interpreter when it is
            // actually authorized; temporary read-only still excludes it.
            #expect(names.contains("exec.shell") == !temporary)
        }
    }

    @Test("A local run uses the task catalog, not a curated-name whitelist")
    func localCatalogUsesTaskAuthority() async throws {
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
        adapter.script = [finalAnswerScript]
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: makeModel(providerID: provider.id)),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: mockExecutor
        )

        try await runtime.start(goal: "搜索今天的新闻")

        let request = try #require(adapter.requests.first)
        let presented = Set(request.toolSchemas.map(\.name))
        // Core shell and the discovered web tool are both offered. A
        // registered-but-unrequested write tool need not be dumped into the
        // first presentation (progressive discovery is preserved).
        #expect(presented.contains("exec.shell"))
        #expect(presented.contains("web.search"))
        #expect(!presented.contains("workspace.createFile"))
        #expect(!presented.isSubset(of: [
            "web.search", "workspace.readFile", "workspace.listDirectory"
        ]))
    }

    @Test("A local shell request can select the authorized interpreter")
    func localShellIsSelectable() async throws {
        let provider = makeProvider(local: true)
        let mockExecutor = executor(names: [
            "workspace.readFile", "exec.shell", "environment.prepareLinux"
        ])
        let adapter = MockAdapter()
        adapter.script = [finalAnswerScript]
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
        #expect(presented.contains("exec.shell"))
        // Environment lifecycle is not auto-dumped by a generic shell query.
        #expect(!presented.contains("environment.prepareLinux"))
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
        adapter.script = [finalAnswerScript]
        let runtime = FloeAgentRuntime(
            configuration: .init(provider: provider, model: makeModel(providerID: provider.id)),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: mockExecutor
        )

        try await runtime.start(goal: "用 shell 执行命令并创建文件，然后搜索今天的新闻")

        let request = try #require(adapter.requests.first)
        let presented = Set(request.toolSchemas.map(\.name))
        // Cloud keeps its dynamic discovery; local now follows the same
        // task-authority rule rather than a second curated fence.
        #expect(presented.contains("exec.shell"))
        #expect(presented.contains("web.search"))
    }

    @Test("Remembered tools are restored under the same task authority")
    func rememberedStateIsRestored() async throws {
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
        adapter.script = [finalAnswerScript]
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
        // Persisted discovery is a presentation hint again, not a hidden
        // authorization ceiling: the registered tools are restored.
        #expect(presented.contains("exec.shell"))
        #expect(presented.contains("environment.prepareLinux"))
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
        adapter.script = [finalAnswerScript]
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
