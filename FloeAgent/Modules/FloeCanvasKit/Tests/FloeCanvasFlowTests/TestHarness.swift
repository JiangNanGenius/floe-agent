import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

// MARK: - Async assertion helpers

func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ verifier: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error to be thrown, but none was", file: file, line: line)
    } catch {
        verifier(error)
    }
}

/// Polls until `condition` holds or `timeout` elapses.
func XCTAssertEventually(
    _ condition: @Sendable () async -> Bool,
    timeout: TimeInterval = 5,
    message: String = "condition not met in time",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    if await condition() { return }
    XCTFail(message, file: file, line: line)
}

// MARK: - Controlled test executor

/// Deterministic test driver implementing the frozen `CanvasStepExecutor`
/// contract: dedupe by attempt ID, `.unknown` for unconfirmed submissions,
/// in-flight steps completed only when the test calls `complete`, and
/// per-node scripted outcomes. Never labels itself as a real provider.
actor TestStepExecutor: CanvasStepExecutor {
    struct ScriptedOutcome: Sendable {
        var status: CanvasStepQueryStatus
        var outputs: [String: FlowValue]
        var producedAssets: [CanvasAssetLocator]
        var error: String?

        init(
            status: CanvasStepQueryStatus = .succeeded,
            outputs: [String: FlowValue] = [:],
            producedAssets: [CanvasAssetLocator] = [],
            error: String? = nil
        ) {
            self.status = status
            self.outputs = outputs
            self.producedAssets = producedAssets
            self.error = error
        }
    }

    private var submissions: [UUID: CanvasStepExecutionRequest] = [:]
    private var results: [UUID: CanvasStepQueryResult] = [:]
    private var unconfirmed: Set<UUID>
    private let outcomeForNode: @Sendable (UUID) -> ScriptedOutcome?
    private var held: Set<UUID> = []
    private(set) var cancelRunCalls: [UUID] = []
    /// Every attempt whose submission reached the driver (deduped).
    private(set) var performedAttemptIDs: [UUID] = []
    private(set) var submittedNodeIDs: [UUID] = []
    /// When true, every new submission is held as `.running` until the test
    /// calls `complete`.
    var holdAll = false
    private var heldSubmissionNumbers: Set<Int> = []
    func holdSubmission(number: Int) { heldSubmissionNumbers.insert(number) }

    /// Test hook: actor-isolated mutation entry point (Swift 6 forbids
    /// mutating an actor's isolated stored property from a nonisolated
    /// context even with `await`).
    func setHoldAll(_ value: Bool) {
        holdAll = value
    }

    init(
        outcomeForNode: @escaping @Sendable (UUID) -> ScriptedOutcome? = { _ in nil },
        unconfirmedAttempts: Set<UUID> = []
    ) {
        self.outcomeForNode = outcomeForNode
        self.unconfirmed = unconfirmedAttempts
    }

    func submitStep(
        _ request: CanvasStepExecutionRequest
    ) throws -> CanvasStepQueryResult {
        let key = request.attemptID
        if let existing = results[key] {
            return existing
        }
        if !performedAttemptIDs.contains(key) {
            performedAttemptIDs.append(key)
            submittedNodeIDs.append(request.node.id)
        }
        submissions[key] = request
        if holdAll || heldSubmissionNumbers.contains(performedAttemptIDs.count) {
            held.insert(key)
        }

        if unconfirmed.contains(key) {
            // Submission may or may not have reached the provider.
            return CanvasStepQueryResult(
                attemptID: key,
                nodeID: request.node.id,
                status: .unknown,
                hostTaskBinding: UUID())
        }
        if held.contains(key) {
            return CanvasStepQueryResult(
                attemptID: key,
                nodeID: request.node.id,
                status: .running,
                hostTaskBinding: UUID())
        }
        let outcome = outcomeForNode(request.node.id) ?? ScriptedOutcome(status: .succeeded)
        let result = CanvasStepQueryResult(
            attemptID: key,
            nodeID: request.node.id,
            status: outcome.status,
            outputs: outcome.outputs,
            producedAssets: outcome.producedAssets,
            hostTaskBinding: UUID(),
            error: outcome.error)
        results[key] = result
        return result
    }

    /// Test hook: hold an attempt as `.running` until `complete` is called.
    func hold(attemptID: UUID) {
        held.insert(attemptID)
    }

    /// Test hook: resolve a held (or unconfirmed) attempt with an outcome.
    func complete(attemptID: UUID, outcome: ScriptedOutcome) throws {
        guard let request = submissions[attemptID] else {
            throw CanvasKitError.missingEntity("attempt \(attemptID)")
        }
        results[attemptID] = CanvasStepQueryResult(
            attemptID: attemptID,
            nodeID: request.node.id,
            status: outcome.status,
            outputs: outcome.outputs,
            producedAssets: outcome.producedAssets,
            hostTaskBinding: UUID(),
            error: outcome.error)
        unconfirmed.remove(attemptID)
        held.remove(attemptID)
    }

    func queryStep(
        attemptID: UUID,
        runID: UUID
    ) throws -> CanvasStepQueryResult {
        guard let result = results[attemptID] else {
            throw CanvasKitError.missingEntity("attempt \(attemptID)")
        }
        return result
    }

    func queryRun(runID: UUID) throws -> FlowRunCheckpoint {
        FlowRunCheckpoint(runID: runID)
    }

    func cancelRun(runID: UUID) throws {
        cancelRunCalls.append(runID)
    }

    // Inspection
    func request(attemptID: UUID) -> CanvasStepExecutionRequest? {
        submissions[attemptID]
    }

    func submissionCount() -> Int {
        performedAttemptIDs.count
    }

    func submissionCount(forNode nodeID: UUID) -> Int {
        submittedNodeIDs.filter { $0 == nodeID }.count
    }
}

// MARK: - Native test handlers

enum TestNativeHandlers {
    /// Registers deterministic offline handlers. These are qualification
    /// stand-ins, never real AI.
    static func makeRegistry() -> FlowNativeStepRegistry {
        var registry = FlowNativeStepRegistry()
        registry.register("math.add") { context in
            guard case .number(let a)? = context.inputs["a"],
                  case .number(let b)? = context.inputs["b"] else {
                throw FlowOperandError.typeMismatch("math.add requires number inputs a and b")
            }
            return ["sum": .number(a + b)]
        }
        registry.register("math.addOneVar") { context in
            guard case .number(let value)? = context.variable("carry.value") else {
                throw FlowVariableError.undefinedVariable("carry.value")
            }
            return ["out": .number(value + 1)]
        }
        registry.register("text.concat") { context in
            let a = (context.inputs["a"] ?? .string("")).stringValue ?? ""
            let b = (context.inputs["b"] ?? .string("")).stringValue ?? ""
            return ["text": .string(a + b)]
        }
        registry.register("math.double") { context in
            guard case .number(let value)? = context.inputs["in"] else {
                throw FlowOperandError.typeMismatch("math.double requires number input 'in'")
            }
            return ["out": .number(value * 2)]
        }
        registry.register("batch.double") { context in
            guard case .number(let item)? = context.variable("item") else {
                throw FlowVariableError.undefinedVariable("item")
            }
            if item == 3 { throw FlowRuntimeError.hostCapabilityUnavailable("scripted item failure") }
            return ["itemResult": .number(item * 2)]
        }
        registry.register("acc.bump") { context in
            guard case .number(let value)? = context.variable("acc") else {
                throw FlowVariableError.undefinedVariable("acc")
            }
            return ["acc": .number(value + 1)]
        }
        registry.register("noop") { _ in ["out": .json(.null)] }
        return registry
    }
}

private extension FlowValue {
    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

// MARK: - Graph building helpers

/// Functional graph factory used across the Flow tests.
enum GraphFactory {
    static func constantSource(
        id: UUID = UUID(),
        name: String = "const",
        literal: JSONValue,
        type: FlowValueType
    ) -> (node: FlowNode, out: FlowPort) {
        let port = FlowPort(name: "out", dataType: type, direction: .output)
        let node = FlowNode(
            id: id,
            kind: .source,
            name: name,
            ports: [port],
            parameters: ["sourceKind": .string("constant"), "literal": literal])
        return (node, port)
    }

    static func transform(
        id: UUID = UUID(),
        name: String,
        nativeKey: String? = nil,
        inputs: [(String, FlowValueType)],
        outputs: [(String, FlowValueType)],
        parameters: [String: JSONValue] = [:],
        writeVariables: [String: String]? = nil
    ) -> (node: FlowNode, inPorts: [FlowPort], outPorts: [FlowPort]) {
        var parameters = parameters
        if let nativeKey { parameters["nativeKey"] = .string(nativeKey) }
        if let writeVariables {
            parameters["writeVariables"] = .object(
                writeVariables.mapValues(JSONValue.string))
        }
        let inPorts = inputs.map { FlowPort(name: $0.0, dataType: $0.1, direction: .input) }
        let outPorts = outputs.map { FlowPort(name: $0.0, dataType: $0.1, direction: .output) }
        let node = FlowNode(
            id: id,
            kind: .transform,
            name: name,
            ports: inPorts + outPorts,
            parameters: parameters)
        return (node, inPorts, outPorts)
    }

    static func external(
        id: UUID = UUID(),
        name: String = "external",
        inputs: [(String, FlowValueType)] = [],
        outputs: [(String, FlowValueType)] = [("out", .string)]
    ) -> (node: FlowNode, inPorts: [FlowPort], outPorts: [FlowPort]) {
        let inPorts = inputs.map { FlowPort(name: $0.0, dataType: $0.1, direction: .input) }
        let outPorts = outputs.map { FlowPort(name: $0.0, dataType: $0.1, direction: .output) }
        let node = FlowNode(
            id: id,
            kind: .customScript,
            name: name,
            ports: inPorts + outPorts,
            parameters: [:],
            script: FlowScriptDescriptor(language: "bash", sourceHash: "sha256:test"))
        return (node, inPorts, outPorts)
    }

    static func edge(
        from source: FlowPort, node sourceNode: FlowNode,
        to destination: FlowPort, node destinationNode: FlowNode
    ) -> FlowEdge {
        FlowEdge(
            sourceNodeID: sourceNode.id,
            sourcePortID: source.id,
            destinationNodeID: destinationNode.id,
            destinationPortID: destination.id)
    }

    static func output(
        id: UUID = UUID(),
        name: String = "output",
        inputs: [(String, FlowValueType)],
        resultKey: String? = nil
    ) -> (node: FlowNode, inPorts: [FlowPort]) {
        let inPorts = inputs.map { FlowPort(name: $0.0, dataType: $0.1, direction: .input) }
        var parameters: [String: JSONValue] = [:]
        if let resultKey { parameters["resultKey"] = .string(resultKey) }
        let node = FlowNode(
            id: id,
            kind: .output,
            name: name,
            ports: inPorts,
            parameters: parameters)
        return (node, inPorts)
    }

    static func makeIdentity(
        runID: UUID = UUID(),
        canvasID: UUID = UUID(),
        canvasRevision: Int64 = 7,
        flowGraphID: UUID = UUID(),
        flowGraphRevision: Int64 = 3,
        environmentID: String = "env-qualification",
        taskID: UUID? = UUID()
    ) -> FlowRunIdentity {
        FlowRunIdentity(
            runID: runID,
            canvasID: canvasID,
            canvasRevision: canvasRevision,
            flowGraphID: flowGraphID,
            flowGraphRevision: flowGraphRevision,
            environmentID: environmentID,
            owningTaskID: taskID)
    }

    static func makeConfiguration(
        identity: FlowRunIdentity,
        pageID: UUID? = nil,
        runInputs: [FlowRunInput] = [],
        sourceDigests: [UUID: String] = [:],
        configurationDigest: String = "config-digest-v1",
        maxLoopIterations: Int = FlowGraph.defaultMaxLoopIterations,
        checkpointEverySteps: Int = 0
    ) -> FlowRunConfiguration {
        FlowRunConfiguration(
            identity: identity,
            pageID: pageID,
            runInputs: runInputs,
            sourceDigests: sourceDigests,
            configurationDigest: configurationDigest,
            maxLoopIterations: maxLoopIterations,
            checkpointEverySteps: checkpointEverySteps)
    }
}
