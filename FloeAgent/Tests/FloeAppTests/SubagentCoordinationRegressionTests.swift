// FloeAppTests — delegated-child environment coordination and discovery
// feedback through the PUBLIC runtime surface.
//
// App-target regressions for two independently reviewed runtime defects:
//
//  * a delegation envelope held an environment consumer ticket for the child's
//    WHOLE lifetime, so the child's own environment start/stop/restart/repair
//    call was refused as "busy" after the bounded wait. The envelope is now
//    excluded from consumer registration, while every real main-run or child
//    call still registers (and still blocks an unsafe lifecycle operation);
//  * the child's `tools.search` response advertised presentation matches as
//    "Loaded" even when admission had deferred them, and a previously loaded
//    schema could disappear without an explicit eviction receipt. The response
//    now lists only the schemas the next request really carries, and every
//    disappearance is reported.
//
// Everything here runs on scripted provider adapters and fake executors — no
// model inference and no Linux guest/VM. The runtime and runner are the REAL
// production types, driven through PUBLIC API only (`FloeAgentRuntime`,
// `SubagentRunner`, `CatalogToolExecutor`), so these tests exercise the same
// canonical dispatch/coordination path the app uses. The integration owner
// (D) adds this file to the FloeAppTests target and regenerates the project;
// it never touches internal runtime types (`@testable` is not used).

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloeAgentRuntime

// MARK: - Scripted provider / recording fixtures (never a real model)

/// One scripted provider stream per turn, in order, recording the exact wire
/// request of every child/parent turn so the tests can assert the tool schemas
/// and feedback that really crossed the wire. Clearly scripted: no inference.
private final class HCoordinationScriptedAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions

    private let lock = NSLock()
    private var turns: [[AgentEvent]]
    private var recorded: [ProviderStreamRequest] = []

    init(turns: [[AgentEvent]]) {
        self.turns = turns
    }

    var requests: [ProviderStreamRequest] {
        lock.withLock { recorded }
    }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let turn: [AgentEvent]? = lock.withLock {
            recorded.append(request)
            return turns.isEmpty ? nil : turns.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            if let turn {
                for event in turn { continuation.yield(event) }
            }
            continuation.yield(.completed(.init(stopReason: .endTurn)))
            continuation.finish()
        }
    }

    func listModels(
        provider: ProviderProfile,
        credentials: ProviderCredentials
    ) async throws -> [ModelProfile] { [] }
}

private actor HCoordinationAuditRecorder: AuditSink {
    private var storage: [AuditEntry] = []
    func record(_ entry: AuditEntry) async throws { storage.append(entry) }
    func entries() -> [AuditEntry] { storage }
}

private actor HCoordinationCheckpointStore: CheckpointStore {
    private var storage: [UUID: AgentCheckpoint] = [:]
    func save(_ checkpoint: AgentCheckpoint) async throws { storage[checkpoint.runID] = checkpoint }
    func load(runID: UUID) async throws -> AgentCheckpoint? { storage[runID] }
}

/// Records which registry tools really executed (never a string assertion).
private actor HCoordinationExecutionRecorder {
    private var calls: [String] = []
    func record(tool: String) { calls.append(tool) }
    func executedTools() -> [String] { calls }
}

/// Parks one call until the test releases it, so a real in-flight consumer can
/// be observed while a lifecycle attempt is made.
private actor HCoordinationGate {
    private var entered = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    var hasEntered: Bool { entered }

    func wait() async {
        entered = true
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// The real registry tool for `environment.hardRestartLinux`. The Linux guest
/// itself is out of scope here; the runtime-side lifecycle coordination is.
private struct HCoordinationLifecycleTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var vcpus: Int?
    }

    static let name = "environment.hardRestartLinux"
    static let toolDescription = "Scripted hard restart used to observe environment lifecycle coordination"
    static let parametersJSON = #"{"type":"object","properties":{"vcpus":{"type":"integer"}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let recorder: HCoordinationExecutionRecorder

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        await recorder.record(tool: Self.name)
        return ToolExecutionOutput(summary: "scripted restart", fullOutputSHA256: "d", exitStatus: 0)
    }
}

/// A registry tool that holds a real environment consumer open until the test
/// releases it.
private struct HCoordinationShellTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var command: String
    }

    static let name = "exec.shell"
    static let toolDescription = "Scripted shell used to hold a real environment consumer open"
    static let parametersJSON = #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.executesLocalCode]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let recorder: HCoordinationExecutionRecorder
    let gate: HCoordinationGate?

    func validate(_ args: Arguments) throws {
        guard !args.command.isEmpty else { throw FloeError.validationFailed("command must not be empty") }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        await recorder.record(tool: Self.name)
        await gate?.wait()
        return ToolExecutionOutput(summary: "scripted shell", fullOutputSHA256: "d", exitStatus: 0)
    }
}

// MARK: - Shared helpers

private func hCoordinationProvider() -> ProviderProfile {
    ProviderProfile(
        kind: .openAI,
        wireProtocol: .openAIChatCompletions,
        baseURL: URL(string: "https://scripted-coordination.example/v1")!,
        displayName: "Scripted Coordination Provider"
    )
}

private func hCoordinationModel(_ provider: ProviderProfile) -> ModelProfile {
    ModelProfile(
        providerID: provider.id,
        remoteModelID: "scripted-coordination-model",
        displayName: "Scripted Coordination Model",
        limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
        capabilities: [.tools]
    )
}

private func hCoordinationCall(
    _ id: String,
    _ toolName: String,
    _ arguments: String
) throws -> ToolCall {
    try ToolCall(id: id, toolName: toolName, argumentsJSON: Data(arguments.utf8), scope: .local)
}

private func hCoordinationChildContext(
    identity: ChildExecutionIdentity,
    environmentID: String,
    allowedToolNames: Set<String>
) -> ToolContext {
    ToolContext(
        runID: identity.parentRunID,
        scope: .local,
        allowedToolNames: allowedToolNames,
        cancellation: CancellationToken(),
        childBudget: ChildBudgetContext(maximumIterations: 4, reserve: { true }, finish: {}),
        environmentID: environmentID,
        conversationID: identity.rootTaskID
    )
}

/// A fake executor whose descriptors are padded to a real wire size, so the
/// child's 48 KiB schema ledger is genuinely exercised (no credentials, no
/// media, only synthetic schema text).
private struct HPaddedDiscoveryExecutor: ToolExecutor {
    private let byName: [String: ToolCatalog.Descriptor]

    init(pads: [String: Int]) {
        var map: [String: ToolCatalog.Descriptor] = [:]
        for (name, padding) in pads {
            map[name] = ToolCatalog.Descriptor(
                name: name,
                toolDescription: "Padded discovery capability \(name)",
                parametersJSON: #"{"type":"object","properties":{"v":{"type":"string","description":""#
                    + String(repeating: "p", count: padding)
                    + #""}},"additionalProperties":false}"#,
                riskLabels: [],
                isSideEffecting: false
            )
        }
        self.byName = map
    }

    var descriptorNames: Set<String> { Set(byName.keys) }

    func descriptor(named name: String) -> ToolCatalog.Descriptor? { byName[name] }

    var allDescriptors: [ToolCatalog.Descriptor] {
        byName.values.sorted { $0.name < $1.name }
    }

    func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
    }
}

/// A child context with a real canonical handoff, used to drive the real child
/// loop directly through the public `SubagentRunner` seam.
private func hCoordinationDiscoveryContext(
    runID: UUID,
    conversationID: UUID,
    allowedToolNames: Set<String>
) -> ToolContext {
    let identity = ChildExecutionIdentity(
        parentRunID: runID, rootTaskID: conversationID, delegateCallID: "d-discovery"
    )
    let dispatcher = ChildToolDispatcher(
        descriptorProvider: { _ in nil },
        allDescriptors: { [] },
        dispatch: { call, _ in
            ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
        }
    )
    let bus = SubagentPeerBus()
    return ToolContext(
        runID: runID,
        scope: .local,
        allowedToolNames: allowedToolNames,
        cancellation: CancellationToken(),
        childBudget: ChildBudgetContext(maximumIterations: 6, reserve: { true }, finish: {}),
        conversationID: conversationID,
        childExecution: ChildExecutionHandoff(
            identity: identity, dispatcher: dispatcher, peers: bus.handle(for: identity)
        )
    )
}

/// Extracts the names rendered inside a `tools.search` "Loaded for the next
/// request:" block. Tool names are ASCII identifiers; the block ends at the
/// next note paragraph.
private func hLoadedBlockNames(in output: String) -> [String] {
    let marker = "Loaded for the next request:"
    guard let range = output.range(of: marker) else { return [] }
    var names: [String] = []
    var sawLine = false
    for line in output[range.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
        if line.isEmpty, !sawLine { continue }
        guard let colon = line.firstIndex(of: ":") else { break }
        let candidate = String(line[line.startIndex..<colon])
        guard !candidate.isEmpty,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" })
        else { break }
        sawLine = true
        names.append(candidate)
    }
    return names
}

// MARK: - F1: the delegation envelope and environment consumer lifetime

@Suite("FloeApp.SubagentEnvironmentCoordination")
struct SubagentEnvironmentCoordinationRegressionTests {
    @Test("a nested delegate envelope never holds an environment consumer for the child's lifetime")
    func delegateChildLifecycleCallExecutes() async throws {
        let provider = hCoordinationProvider()
        let model = hCoordinationModel(provider)
        let runID = UUID()
        let conversationID = UUID()

        let recorder = HCoordinationExecutionRecorder()
        let registry = ToolRunnerRegistry()
        let runners = SubagentRunnerRegistry()
        registerDelegateTool(registry: registry, runners: runners)
        registry.register(HCoordinationLifecycleTool(recorder: recorder))
        let executor = CatalogToolExecutor(runners: registry)

        let mainAdapter = HCoordinationScriptedAdapter(turns: [
            [.toolRequest(try hCoordinationCall(
                "delegate-lifecycle", "delegate",
                #"{"task":"restart the shared environment","type":"execute","maxIterations":4}"#
            ))],
            [.textDelta(.init(text: "parent done"))],
        ])
        let childAdapter = HCoordinationScriptedAdapter(turns: [
            [.toolRequest(try hCoordinationCall(
                "child-restart", "environment.hardRestartLinux", #"{"vcpus":2}"#
            ))],
            [.textDelta(.init(text: "child done"))],
        ])
        await runners.register(
            SubagentRunner(
                provider: provider,
                model: model,
                adapter: childAdapter,
                credentials: ProviderCredentials(),
                executor: executor
            ),
            for: runID
        )
        let audit = HCoordinationAuditRecorder()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: ["delegate", "environment.hardRestartLinux"],
                environmentID: "env-app-delegate-lifecycle",
                environmentLifecycleWait: 0.3
            ),
            adapter: mainAdapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: audit,
            checkpointStore: HCoordinationCheckpointStore(),
            runID: runID
        )
        try await runtime.start(goal: "delegate an environment lifecycle call")

        // The child's own lifecycle call really executed through the real
        // nested envelope. Holding an ancestor consumer ticket for the child's
        // whole lifetime would have made this call wait out the bounded budget
        // and fail as busy, without ever reaching the executor.
        let executed = await recorder.executedTools()
        #expect(executed == ["environment.hardRestartLinux"], "the child lifecycle call must really execute")
        #expect(childAdapter.requests.count == 2, "the child loop must run inside the real delegate envelope")
        let entries = await audit.entries()
        let restart = try #require(entries.first { $0.toolName == "environment.hardRestartLinux" })
        #expect(
            restart.decision.hasPrefix("allow"),
            "the child's own lifecycle call must not be refused: \(restart.decision)"
        )
        #expect(
            !entries.contains {
                $0.toolName == "environment.hardRestartLinux" && $0.decision == "deny:environment-busy"
            }
        )
    }

    @Test("a real child consumer still blocks an unsafe lifecycle call through public dispatch")
    func activeChildConsumerStillBlocksLifecycle() async throws {
        let provider = hCoordinationProvider()
        let model = hCoordinationModel(provider)
        let runID = UUID()
        let conversationID = UUID()
        let gate = HCoordinationGate()
        let recorder = HCoordinationExecutionRecorder()
        let registry = ToolRunnerRegistry()
        registry.register(HCoordinationShellTool(recorder: recorder, gate: gate))
        registry.register(HCoordinationLifecycleTool(recorder: recorder))
        let executor = CatalogToolExecutor(runners: registry)
        let environmentID = "env-app-consumer-control"
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: ["exec.shell", "environment.hardRestartLinux"],
                environmentID: environmentID,
                environmentLifecycleWait: 0.3
            ),
            adapter: HCoordinationScriptedAdapter(turns: []),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: HCoordinationAuditRecorder(),
            checkpointStore: HCoordinationCheckpointStore(),
            runID: runID
        )

        // One child consumer parks INSIDE the executor, registered against the
        // shared environment for the duration of its real call.
        let callerIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationID, delegateCallID: "d-caller"
        )
        let shellCall = try hCoordinationCall("parked-shell", "exec.shell", #"{"command":"sleep"}"#)
        let parked = Task {
            await runtime.dispatchChildTool(
                shellCall,
                identity: callerIdentity,
                childContext: hCoordinationChildContext(
                    identity: callerIdentity,
                    environmentID: environmentID,
                    allowedToolNames: ["exec.shell", "environment.hardRestartLinux"]
                )
            )
        }
        var attempts = 0
        while !(await gate.hasEntered), attempts < 300 {
            try await Task.sleep(nanoseconds: 10_000_000)
            attempts += 1
        }
        #expect(await gate.hasEntered, "the consumer must really be in flight before the lifecycle attempt")

        // A sibling child's hard restart must still be refused, bounded, with
        // the real active consumer named — and never reach the executor.
        let siblingIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationID, delegateCallID: "d-sibling"
        )
        let restartCall = try hCoordinationCall(
            "blocked-restart", "environment.hardRestartLinux", #"{"vcpus":2}"#
        )
        let restartResult = await runtime.dispatchChildTool(
            restartCall,
            identity: siblingIdentity,
            childContext: hCoordinationChildContext(
                identity: siblingIdentity,
                environmentID: environmentID,
                allowedToolNames: ["exec.shell", "environment.hardRestartLinux"]
            )
        )
        #expect(restartResult.status == .failed)
        #expect(
            restartResult.outputSummary.contains("busy")
                || restartResult.outputSummary.contains("restarting")
        )
        #expect(restartResult.outputSummary.contains("exec.shell"))
        let executedWhileParked = await recorder.executedTools()
        #expect(!executedWhileParked.contains("environment.hardRestartLinux"))

        await gate.open()
        let shellResult = await parked.value
        #expect(shellResult.status == .ok)
    }
}

// MARK: - F2: truthful child discovery feedback (loaded / deferred / evicted)

@Suite("FloeApp.SubagentDiscoveryFeedback")
struct SubagentDiscoveryFeedbackRegressionTests {
    @Test("search feedback names only schemas the next request really carries, and evictions are explicit")
    func searchFeedbackMatchesNextRequestSchemas() async throws {
        let runID = UUID()
        let conversationID = UUID()
        let executor = HPaddedDiscoveryExecutor(pads: [
            "test.oldA": 12_500,
            "test.newD": 12_500,
            "test.newE": 12_500,
            "test.newF": 12_500,
        ])
        let adapter = HCoordinationScriptedAdapter(turns: [
            [.toolRequest(try hCoordinationCall(
                "search-oldA", "tools.search", #"{"queries":["test.oldA"]}"#
            ))],
            [
                .toolRequest(try hCoordinationCall(
                    "search-newD", "tools.search", #"{"queries":["test.newD"]}"#
                )),
                .toolRequest(try hCoordinationCall(
                    "search-newE", "tools.search", #"{"queries":["test.newE"]}"#
                )),
                .toolRequest(try hCoordinationCall(
                    "search-newF", "tools.search", #"{"queries":["test.newF"]}"#
                )),
            ],
            [.textDelta(.init(text: "child finished"))],
        ])
        let provider = hCoordinationProvider()
        let runner = SubagentRunner(
            provider: provider,
            model: hCoordinationModel(provider),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "discover bounded definitions", maxIterations: 6, runID: runID),
            context: hCoordinationDiscoveryContext(
                runID: runID,
                conversationID: conversationID,
                allowedToolNames: executor.descriptorNames
            )
        )
        #expect(outcome.status == .completed)

        let requests = adapter.requests
        #expect(requests.count == 3)
        // Turn 1 carried only the stable seed; turn 2 carried the loaded A.
        #expect(!requests[0].toolSchemas.contains { $0.name == "test.oldA" })
        #expect(requests[1].toolSchemas.contains { $0.name == "test.oldA" })
        // Turn 3 must NOT carry A: the three newer schemas filled the budget
        // first, and A's disappearance must be explicitly reported.
        #expect(!requests[2].toolSchemas.contains { $0.name == "test.oldA" })
        let searchFeedback = requests[2].toolResults.map { $0.output }.joined(separator: "\n")
        let systemNotes = requests[2].messages.map { $0.content }.joined(separator: "\n")
        #expect(
            searchFeedback.contains("Unloaded to stay inside the schema budget")
                || systemNotes.contains("Schema budget unloaded"),
            "an eviction must be surfaced explicitly"
        )
        #expect(searchFeedback.contains("test.oldA") || systemNotes.contains("test.oldA"))

        // Every name the search response advertised as loaded is really on the
        // next request's wire — no false "loaded" claim.
        for output in requests[2].toolResults.map { $0.output } {
            for name in hLoadedBlockNames(in: output) {
                #expect(
                    requests[2].toolSchemas.contains { $0.name == name },
                    "\(name) was advertised as loaded but is absent from the next request"
                )
            }
        }
        let carried = Set(requests[2].toolSchemas.map(\.name))
        #expect(carried.isSuperset(of: ["test.newD", "test.newE", "test.newF"]))
    }

    @Test("a deferred match is reported and stays off the wire, never advertised as loaded")
    func deferredMatchIsReportedAndAbsent() async throws {
        let runID = UUID()
        let executor = HPaddedDiscoveryExecutor(pads: [
            "test.newD": 12_500,
            "test.newE": 12_500,
        ])
        let adapter = HCoordinationScriptedAdapter(turns: [
            [.toolRequest(try hCoordinationCall(
                "search-both", "tools.search", #"{"queries":["test.newD test.newE"]}"#
            ))],
            [.textDelta(.init(text: "child finished"))],
        ])
        let provider = hCoordinationProvider()
        let runner = SubagentRunner(
            provider: provider,
            model: hCoordinationModel(provider),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "search two definitions", maxIterations: 4, runID: runID),
            context: hCoordinationDiscoveryContext(
                runID: runID,
                conversationID: UUID(),
                allowedToolNames: executor.descriptorNames
            )
        )
        #expect(outcome.status == .completed)

        let requests = adapter.requests
        #expect(requests.count == 2)
        #expect(requests[1].toolSchemas.contains { $0.name == "test.newD" })
        #expect(!requests[1].toolSchemas.contains { $0.name == "test.newE" })
        let feedback = requests[1].toolResults.map { $0.output }.joined(separator: "\n")
        #expect(
            feedback.contains("Not loaded for the next request (schema budget)"),
            "a deferred match must be reported with the real reason"
        )
        #expect(feedback.contains("test.newE"))
        for output in requests[1].toolResults.map { $0.output } {
            for name in hLoadedBlockNames(in: output) {
                #expect(name != "test.newE", "a deferred match must not be advertised as loaded")
                #expect(requests[1].toolSchemas.contains { $0.name == name })
            }
        }
    }

    @Test("a single definition too large for the schema budget is reported and never aborts the child")
    func oversizedDefinitionDoesNotAbortChild() async throws {
        let runID = UUID()
        let executor = HPaddedDiscoveryExecutor(pads: ["test.huge": 60_000, "test.small": 40])
        let adapter = HCoordinationScriptedAdapter(turns: [
            [.toolRequest(try hCoordinationCall(
                "search-huge", "tools.search", #"{"queries":["test.huge"]}"#
            ))],
            [.textDelta(.init(text: "child finished"))],
        ])
        let provider = hCoordinationProvider()
        let runner = SubagentRunner(
            provider: provider,
            model: hCoordinationModel(provider),
            adapter: adapter,
            credentials: ProviderCredentials(),
            executor: executor
        )
        let outcome = try await runner.runStructured(
            SubagentRequest(task: "search an oversized definition", maxIterations: 4, runID: runID),
            context: hCoordinationDiscoveryContext(
                runID: runID,
                conversationID: UUID(),
                allowedToolNames: executor.descriptorNames
            )
        )
        #expect(outcome.status == .completed, "an oversized definition must not abort the child")
        let requests = adapter.requests
        #expect(requests.count == 2)
        #expect(
            requests.allSatisfy { request in
                !request.toolSchemas.contains { $0.name == "test.huge" }
            }
        )
        let feedback = requests[1].toolResults.map { $0.output }.joined(separator: "\n")
        #expect(feedback.contains("Not loadable within the request schema budget"))
        #expect(feedback.contains("test.huge"))
    }
}

#endif
