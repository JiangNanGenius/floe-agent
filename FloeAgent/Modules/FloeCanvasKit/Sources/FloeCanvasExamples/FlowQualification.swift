// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasFlow

// MARK: - Scenario 4: offline Flow harness (ICH07/08/09/10)
//
// Drives the REAL FlowRuntimeService with a deterministic injected
// CanvasStepExecutor and clearly labeled OFFLINE TEST nodes. Covers: a
// composite graph (condition branch selection + skipped propagation, loop
// with carry + stopWhen, variable scope isolation, batch per-item
// result/failure isolation, subgraph template instance), debugger controls
// (breakpoint / step / resume), pause with in-flight external work,
// submission dedupe call counts, cancel with fenced late delivery that
// cannot touch another run, unknown-submission reconcile without
// resubmission, frozen journal recovery, partial rerun adoption, and the
// fail-closed missing-environment error. No fake success records: every
// PASS is backed by run outputs, step records and driver call counts.

enum FlowQualification {
    static let scenarioName = "s4-offline-flow-harness"
    static let environmentID = "env-offline-qualification"

    // MARK: Deterministic injected executor (offline test driver)

    actor OfflineTestStepExecutor: CanvasStepExecutor {
        struct ScriptedOutcome: Sendable {
            var status: CanvasStepQueryStatus
            var outputs: [String: FlowValue]
            var error: String?

            init(
                status: CanvasStepQueryStatus = .succeeded,
                outputs: [String: FlowValue] = [:],
                error: String? = nil
            ) {
                self.status = status
                self.outputs = outputs
                self.error = error
            }
        }

        private var submissions: [UUID: CanvasStepExecutionRequest] = [:]
        private var results: [UUID: CanvasStepQueryResult] = [:]
        private var performedAttemptIDs: [UUID] = []
        private var submittedNodeIDs: [UUID] = []
        private var held: Set<UUID> = []
        private var outcomeForNode: [UUID: ScriptedOutcome]
        private var failUnconfiguredEnvironment: Bool
        private(set) var cancelRunCalls: [UUID] = []
        /// The next submission answers `.unknown` (submission could not be
        /// confirmed). Consumed once.
        var makeNextSubmissionUnknown = false
        /// When true every new submission is held as `.running` until the
        /// harness calls `complete`.
        var holdAll = false
        func setHoldAll(_ value: Bool) { holdAll = value }
        func armUnknownSubmission() { makeNextSubmissionUnknown = true }

        init(
            outcomeForNode: [UUID: ScriptedOutcome] = [:],
            failUnconfiguredEnvironment: Bool = true
        ) {
            self.outcomeForNode = outcomeForNode
            self.failUnconfiguredEnvironment = failUnconfiguredEnvironment
        }

        func submitStep(
            _ request: CanvasStepExecutionRequest
        ) throws -> CanvasStepQueryResult {
            let key = request.attemptID
            if let existing = results[key] {
                // Host-side dedupe: a known attempt never starts a second job.
                return existing
            }
            if !performedAttemptIDs.contains(key) {
                performedAttemptIDs.append(key)
                submittedNodeIDs.append(request.node.id)
            }
            submissions[key] = request

            // ICH10: a script step without an explicit environment is a
            // fail-closed error, never a local interpreter fallback.
            if failUnconfiguredEnvironment, !request.context.hasEnvironment {
                let result = CanvasStepQueryResult(
                    attemptID: key, nodeID: request.node.id,
                    status: .failed,
                    error: "no execution environment configured for offline "
                        + "script step; the host executor refuses local "
                        + "interpreter fallbacks")
                results[key] = result
                return result
            }

            if makeNextSubmissionUnknown {
                makeNextSubmissionUnknown = false
                return CanvasStepQueryResult(
                    attemptID: key, nodeID: request.node.id,
                    status: .unknown, hostTaskBinding: UUID())
            }
            if holdAll {
                held.insert(key)
                return CanvasStepQueryResult(
                    attemptID: key, nodeID: request.node.id,
                    status: .running, hostTaskBinding: UUID())
            }
            let outcome = outcomeForNode[request.node.id] ?? ScriptedOutcome()
            let result = CanvasStepQueryResult(
                attemptID: key, nodeID: request.node.id,
                status: outcome.status, outputs: outcome.outputs,
                hostTaskBinding: UUID(), error: outcome.error)
            results[key] = result
            return result
        }

        /// Harness hook: resolve a held attempt with an outcome.
        func complete(attemptID: UUID, outcome: ScriptedOutcome) throws {
            guard let request = submissions[attemptID] else {
                throw CanvasKitError.missingEntity("attempt \(attemptID)")
            }
            results[attemptID] = CanvasStepQueryResult(
                attemptID: attemptID, nodeID: request.node.id,
                status: outcome.status, outputs: outcome.outputs,
                hostTaskBinding: UUID(), error: outcome.error)
            held.remove(attemptID)
        }

        func queryStep(
            attemptID: UUID, runID: UUID
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
        func submissionCount() -> Int { performedAttemptIDs.count }
        func submissionCount(forNode nodeID: UUID) -> Int {
            submittedNodeIDs.filter { $0 == nodeID }.count
        }
        var attemptedIDs: [UUID] { performedAttemptIDs }
    }

    // MARK: Offline native registry (deterministic, clearly labeled)

    static func makeRegistry() -> FlowNativeStepRegistry {
        var registry = FlowNativeStepRegistry()
        registry.register("offline.math.add") { context in
            guard case .number(let a)? = context.inputs["a"],
                  case .number(let b)? = context.inputs["b"] else {
                throw FlowOperandError.typeMismatch(
                    "offline.math.add requires number inputs a and b")
            }
            return ["sum": .number(a + b)]
        }
        registry.register("offline.math.addOneVar") { context in
            guard case .number(let value)? = context.variable("carry.value") else {
                throw FlowVariableError.undefinedVariable("carry.value")
            }
            return ["out": .number(value + 1)]
        }
        registry.register("offline.text.concat") { context in
            func text(_ value: FlowValue?) -> String {
                guard case .string(let string)? = value else { return "" }
                return string
            }
            return ["text": .string(text(context.inputs["a"]) + text(context.inputs["b"]))]
        }
        registry.register("offline.math.double") { context in
            guard case .number(let value)? = context.inputs["in"] else {
                throw FlowOperandError.typeMismatch(
                    "offline.math.double requires number input 'in'")
            }
            return ["out": .number(value * 2)]
        }
        registry.register("offline.batch.double") { context in
            guard case .number(let item)? = context.variable("item") else {
                throw FlowVariableError.undefinedVariable("item")
            }
            if item == 3 {
                throw FlowRuntimeError.hostCapabilityUnavailable(
                    "scripted item failure (offline)")
            }
            return ["itemResult": .number(item * 2)]
        }
        registry.register("offline.noop") { _ in ["out": .json(.null)] }
        return registry
    }

    // MARK: Graph factories (deterministic ids)

    static func u(_ seed: UInt64) -> UUID {
        SyntheticQualification.uuid(seed)
    }

    struct PortSet: Sendable {
        var node: FlowNode
        var inputs: [FlowPort]
        var outputs: [FlowPort]
    }

    static func constantSource(
        _ seed: UInt64, name: String, literal: JSONValue, type: FlowValueType
    ) -> (node: FlowNode, out: FlowPort) {
        let out = FlowPort(
            id: u(seed + 1), name: "out", dataType: type, direction: .output)
        let node = FlowNode(
            id: u(seed), kind: .source, name: name, ports: [out],
            parameters: ["sourceKind": .string("constant"), "literal": literal],
            position: .zero)
        return (node, out)
    }

    static func transform(
        _ seed: UInt64, name: String, nativeKey: String,
        inputs: [(String, FlowValueType)],
        outputs: [(String, FlowValueType)],
        writeVariables: [String: String]? = nil
    ) -> PortSet {
        let inPorts = inputs.enumerated().map {
            FlowPort(id: u(seed + 1 + UInt64($0.offset) * 2),
                     name: $0.element.0, dataType: $0.element.1,
                     direction: .input)
        }
        let outPorts = outputs.enumerated().map {
            FlowPort(id: u(seed + 2 + UInt64($0.offset) * 2),
                     name: $0.element.0, dataType: $0.element.1,
                     direction: .output)
        }
        var parameters: [String: JSONValue] = ["nativeKey": .string(nativeKey)]
        if let writeVariables {
            parameters["writeVariables"] = .object(
                writeVariables.mapValues(JSONValue.string))
        }
        return PortSet(
            node: FlowNode(
                id: u(seed), kind: .transform, name: name,
                ports: inPorts + outPorts, parameters: parameters,
                position: .zero),
            inputs: inPorts, outputs: outPorts)
    }

    static func external(
        _ seed: UInt64, name: String,
        inputs: [(String, FlowValueType)],
        outputs: [(String, FlowValueType)]
    ) -> PortSet {
        let inPorts = inputs.enumerated().map {
            FlowPort(id: u(seed + 1 + UInt64($0.offset) * 2),
                     name: $0.element.0, dataType: $0.element.1,
                     direction: .input)
        }
        let outPorts = outputs.enumerated().map {
            FlowPort(id: u(seed + 2 + UInt64($0.offset) * 2),
                     name: $0.element.0, dataType: $0.element.1,
                     direction: .output)
        }
        return PortSet(
            node: FlowNode(
                id: u(seed), kind: .customScript, name: name,
                ports: inPorts + outPorts,
                script: FlowScriptDescriptor(
                    language: "bash", sourceHash: "sha256:offline-fixture"),
                position: .zero),
            inputs: inPorts, outputs: outPorts)
    }

    static func outputNode(
        _ seed: UInt64, name: String = "output",
        inputs: [(String, FlowValueType)], resultKey: String? = nil
    ) -> (node: FlowNode, inputs: [FlowPort]) {
        let inPorts = inputs.enumerated().map {
            FlowPort(id: u(seed + 1 + UInt64($0.offset)),
                     name: $0.element.0, dataType: $0.element.1,
                     direction: .input)
        }
        var parameters: [String: JSONValue] = [:]
        if let resultKey { parameters["resultKey"] = .string(resultKey) }
        return (FlowNode(
            id: u(seed), kind: .output, name: name, ports: inPorts,
            parameters: parameters, position: .zero), inPorts)
    }

    static func edge(
        _ seed: UInt64, from source: FlowPort, node sourceNode: FlowNode,
        to destination: FlowPort, node destinationNode: FlowNode
    ) -> FlowEdge {
        FlowEdge(
            id: u(seed),
            sourceNodeID: sourceNode.id, sourcePortID: source.id,
            destinationNodeID: destinationNode.id, destinationPortID: destination.id)
    }

    static func makeIdentity(
        runID: UUID, canvasID: UUID, graphID: UUID, graphRevision: Int64
    ) -> FlowRunIdentity {
        FlowRunIdentity(
            runID: runID, canvasID: canvasID,
            canvasRevision: 1, flowGraphID: graphID,
            flowGraphRevision: graphRevision,
            environmentID: environmentID,
            owningTaskID: u(0xF0F0))
    }

    static func makeConfiguration(
        identity: FlowRunIdentity
    ) -> FlowRunConfiguration {
        FlowRunConfiguration(
            identity: identity,
            configurationDigest: "offline-qualification-v1",
            maxLoopIterations: FlowGraph.defaultMaxLoopIterations)
    }

    /// Polls `condition` until it holds or the deadline (~1s default) passes.
    static func waitFor(
        _ condition: @Sendable () async -> Bool,
        deadlineNanoseconds: UInt64 = 1_000_000_000
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + deadlineNanoseconds
        while await !condition() {
            if DispatchTime.now().uptimeNanoseconds >= deadline { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    // MARK: Event collection

    static func collectEvents(
        _ runtime: FlowRuntimeService, runID: UUID
    ) async -> [FlowRuntimeEvent] {
        // Scenarios perform their own bounded completion checks. A failed
        // scenario must still export diagnostics rather than hanging on a
        // terminal event it may never produce.
        await runtime.retainedEvents(runID: runID)
    }

    static func describe(_ event: FlowRuntimeEvent) -> String {
        func id(_ value: UUID) -> JSONValue { .string(value.uuidString) }
        func integer(_ value: Int) -> JSONValue { .number(String(value)) }
        var fields: [String: JSONValue]
        switch event {
        case .runStarted(let run, let bound):
            fields = ["event": .string("runStarted"), "runID": id(run), "revisionKeyBound": .bool(bound)]
        case .stepScheduled(let run, let node, let attempt, let path):
            fields = ["event": .string("stepScheduled"), "runID": id(run), "nodeID": id(node),
                      "attempt": integer(attempt), "callPath": .string(path)]
        case .stepStarted(let run, let node, let attempt, let external):
            fields = ["event": .string("stepStarted"), "runID": id(run), "nodeID": id(node),
                      "attempt": integer(attempt), "external": .bool(external)]
        case .stepCompleted(let run, let node, let attempt, let outputs):
            fields = ["event": .string("stepCompleted"), "runID": id(run), "nodeID": id(node),
                      "attempt": integer(attempt), "outputs": .object(outputs.mapValues(traceValue))]
        case .stepFailed(let run, let node, let attempt, let error):
            fields = ["event": .string("stepFailed"), "runID": id(run), "nodeID": id(node),
                      "attempt": integer(attempt), "error": .string(error)]
        case .stepSkipped(let run, let node, let reason):
            fields = ["event": .string("stepSkipped"), "runID": id(run), "nodeID": id(node),
                      "reason": .string(reason)]
        case .conditionSelected(let run, let node, let port):
            fields = ["event": .string("conditionSelected"), "runID": id(run), "nodeID": id(node),
                      "branchOutputPortID": id(port)]
        case .loopIteration(let run, let node, let iteration):
            fields = ["event": .string("loopIteration"), "runID": id(run), "nodeID": id(node),
                      "iteration": integer(iteration)]
        case .batchProgress(let run, let node, let completed, let total):
            fields = ["event": .string("batchProgress"), "runID": id(run), "nodeID": id(node),
                      "completedItems": integer(completed), "totalItems": integer(total)]
        case .breakpointHit(let run, let node):
            fields = ["event": .string("breakpointHit"), "runID": id(run), "nodeID": id(node)]
        case .paused(let run):
            fields = ["event": .string("paused"), "runID": id(run)]
        case .steppingPaused(let run, let node):
            fields = ["event": .string("steppingPaused"), "runID": id(run), "completedNodeID": id(node)]
        case .resumed(let run):
            fields = ["event": .string("resumed"), "runID": id(run)]
        case .cancelled(let run):
            fields = ["event": .string("cancelled"), "runID": id(run)]
        case .reconcileRequired(let run, let attempt, let node):
            fields = ["event": .string("reconcileRequired"), "runID": id(run), "attemptID": id(attempt), "nodeID": id(node)]
        case .reconciled(let run, let attempt, let status):
            fields = ["event": .string("reconciled"), "runID": id(run), "attemptID": id(attempt), "status": .string(status)]
        case .lateDeliveryRecorded(let run, let attempt, let node):
            fields = ["event": .string("lateDeliveryRecorded"), "runID": id(run), "attemptID": id(attempt), "nodeID": id(node)]
        case .checkpointSaved(let run):
            fields = ["event": .string("checkpointSaved"), "runID": id(run)]
        case .checkpointFailed(let run, let error):
            fields = ["event": .string("checkpointFailed"), "runID": id(run), "error": .string(error)]
        case .runFinished(let run, let phase):
            fields = ["event": .string("runFinished"), "runID": id(run), "phase": .string(phase.rawValue)]
        }
        return describeJSON(.object(fields))
    }

    private static func traceValue(_ value: FlowValue) -> JSONValue {
        switch value {
        case .string(let value): return .string(value)
        case .number(let value):
            // Never trap converting a large integral Double to Int64.
            return value.isFinite ? .number(String(value))
                : .object(["nonFiniteNumber": .string(String(value))])
        case .bool(let value): return .bool(value)
        case .list(let values): return .array(values.map(traceValue))
        case .table(let header, let rows):
            return .object(["type": .string("table"), "header": .array(header.map(JSONValue.string)),
                            "rows": .array(rows.map { .array($0.map(JSONValue.string)) })])
        case .asset(let locator):
            return (try? JSONFidelity.parse(JSONEncoder().encode(locator)))
                ?? .object(["type": .string("asset"), "id": .string(locator.id.uuidString)])
        case .json(let value): return value
        }
    }

    static func describe(_ value: FlowValue) -> String { describeJSON(traceValue(value)) }

    static func describeJSON(_ value: JSONValue) -> String {
        guard let bytes = try? JSONFidelity.serialize(value),
              let text = String(data: bytes, encoding: .utf8) else {
            return #"{"event":"traceEncodingFailed"}"#
        }
        return text
    }

    // MARK: Composite graph (condition + loop + variables + batch + subgraph)

    struct CompositeGraph: Sendable {
        var graph: FlowGraph
        var template: FlowSubgraphTemplate
        var loopBodyID: UUID
        var skippedBranchNodeID: UUID
    }

    static func makeCompositeGraph() throws -> CompositeGraph {
        // Loop with carry: 1 → … → 6, stop when carry.value > 5.
        let source = constantSource(
            0x1000, name: "offline.constant", literal: .number("1"),
            type: .number)
        let valuePort = FlowPort(
            id: u(0x1101), name: "value", dataType: .number, direction: .input)
        let finalPort = FlowPort(
            id: u(0x1102), name: "final", dataType: .number, direction: .output)
        let stopWhen = try FlowLiterals.encodeToJSON(FlowPredicate.comparison(
            .greaterThan,
            lhs: .variable(name: "carry.value"),
            rhs: .literal(.number(5))))
        let step = transform(
            0x1200, name: "offline.step", nativeKey: "offline.math.addOneVar",
            inputs: [], outputs: [("out", .number)])
        let loop = FlowNode(
            id: u(0x1100), kind: .loop, name: "offline.loop",
            ports: [valuePort, finalPort],
            parameters: ["stopWhen": stopWhen],
            bodyNodeIDs: [step.node.id],
            position: .zero)
        let loopOut = outputNode(
            0x1300, inputs: [("final", .number)], resultKey: "loop.final")

        // Condition: "hello" == "hello" takes the true branch; the false
        // branch downstream is skipped with branchNotTaken.
        let textSource = constantSource(
            0x2000, name: "offline.constant.text", literal: .string("hello"),
            type: .string)
        let conditionIn = FlowPort(
            id: u(0x2101), name: "in", dataType: .string, direction: .input)
        let truePort = FlowPort(
            id: u(0x2102), name: "true", dataType: .bool, direction: .output)
        let falsePort = FlowPort(
            id: u(0x2103), name: "false", dataType: .bool, direction: .output)
        let predicate = FlowPredicate.comparison(
            .equal,
            lhs: .nodeOutput(nodeID: textSource.node.id, portName: "out"),
            rhs: .literal(.string("hello")))
        let condition = FlowNode(
            id: u(0x2100), kind: .condition, name: "offline.check",
            ports: [conditionIn, truePort, falsePort],
            branches: [FlowConditionBranch(
                id: u(0x2104), predicate: predicate, outputPortID: truePort.id)],
            position: .zero)
        let taken = transform(
            0x2200, name: "offline.taken", nativeKey: "offline.text.concat",
            inputs: [("a", .string), ("gate", .bool)],
            outputs: [("text", .string)])
        let skippedBranch = transform(
            0x2300, name: "offline.skipped", nativeKey: "offline.text.concat",
            inputs: [("a", .string), ("gate", .bool)],
            outputs: [("text", .string)])
        let textOut = outputNode(
            0x2400, inputs: [("text", .string)], resultKey: "branch.text")

        // Batch: [1,2,3,4] → double each; item 3 fails and is isolated.
        let listSource = constantSource(
            0x3000, name: "offline.constant.list",
            literal: .array([.number("1"), .number("2"), .number("3"), .number("4")]),
            type: .list)
        let itemsPort = FlowPort(
            id: u(0x3101), name: "items", dataType: .list, direction: .input)
        let resultsPort = FlowPort(
            id: u(0x3102), name: "results", dataType: .list, direction: .output)
        let failuresPort = FlowPort(
            id: u(0x3103), name: "failures", dataType: .list, direction: .output)
        let batchBody = transform(
            0x3200, name: "offline.batch.double", nativeKey: "offline.batch.double",
            inputs: [], outputs: [("itemResult", .number)],
            writeVariables: ["itemResult": "itemResult"])
        let batch = FlowNode(
            id: u(0x3100), kind: .batch, name: "offline.batch",
            ports: [itemsPort, resultsPort, failuresPort],
            bodyNodeIDs: [batchBody.node.id],
            position: .zero)
        let batchOut = outputNode(
            0x3300, inputs: [("results", .list), ("failures", .list)])

        // Subgraph template instance: doubles the constant 5 → 10.
        let templateSource = constantSource(
            0x4000, name: "offline.template.constant", literal: .number("5"),
            type: .number)
        let templateDouble = transform(
            0x4100, name: "offline.template.double",
            nativeKey: "offline.math.double",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let templateOutput = outputNode(
            0x4200, inputs: [("in", .number)], resultKey: "doubled")
        let templateGraph = FlowGraph(
            id: u(0x4001), revision: 1,
            nodes: [templateSource.node, templateDouble.node, templateOutput.node],
            edges: [
                edge(0x4300, from: templateSource.out, node: templateSource.node,
                     to: templateDouble.inputs[0], node: templateDouble.node),
                edge(0x4301, from: templateDouble.outputs[0], node: templateDouble.node,
                     to: templateOutput.inputs[0], node: templateOutput.node),
            ])
        let template = FlowSubgraphTemplate(
            id: u(0x4002), version: 1, name: "offline.doubleTemplate",
            graph: templateGraph,
            exposedPorts: [FlowPort(
                id: u(0x4003), name: "doubled", dataType: .number,
                direction: .output)])
        let subgraphOut = FlowPort(
            id: u(0x4401), name: "doubled", dataType: .number, direction: .output)
        let subgraphNode = FlowNode(
            id: u(0x4400), kind: .subgraph, name: "offline.doubleIt",
            ports: [subgraphOut], subgraphTemplateID: template.id,
            position: .zero)
        let subgraphOutput = outputNode(
            0x4500, inputs: [("doubled", .number)], resultKey: "template.doubled")

        let graph = FlowGraph(
            id: u(0x5000), revision: 1,
            nodes: [
                source.node, loop, step.node, loopOut.node,
                textSource.node, condition, taken.node, skippedBranch.node,
                textOut.node,
                listSource.node, batch, batchBody.node, batchOut.node,
                subgraphNode, subgraphOutput.node,
            ],
            edges: [
                edge(0x5100, from: source.out, node: source.node,
                     to: valuePort, node: loop),
                edge(0x5101, from: step.outputs[0], node: step.node,
                     to: valuePort, node: loop),
                edge(0x5102, from: step.outputs[0], node: step.node,
                     to: loopOut.inputs[0], node: loopOut.node),
                edge(0x5200, from: textSource.out, node: textSource.node,
                     to: conditionIn, node: condition),
                edge(0x5201, from: truePort, node: condition,
                     to: taken.inputs[1], node: taken.node),
                edge(0x5202, from: falsePort, node: condition,
                     to: skippedBranch.inputs[1], node: skippedBranch.node),
                edge(0x5203, from: textSource.out, node: textSource.node,
                     to: taken.inputs[0], node: taken.node),
                edge(0x5204, from: textSource.out, node: textSource.node,
                     to: skippedBranch.inputs[0], node: skippedBranch.node),
                edge(0x5205, from: taken.outputs[0], node: taken.node,
                     to: textOut.inputs[0], node: textOut.node),
                edge(0x5300, from: listSource.out, node: listSource.node,
                     to: itemsPort, node: batch),
                edge(0x5301, from: resultsPort, node: batch,
                     to: batchOut.inputs[0], node: batchOut.node),
                edge(0x5302, from: failuresPort, node: batch,
                     to: batchOut.inputs[1], node: batchOut.node),
                edge(0x5400, from: subgraphOut, node: subgraphNode,
                     to: subgraphOutput.inputs[0], node: subgraphOutput.node),
            ],
            variables: [
                FlowVariable(
                    id: u(0x5500), name: "itemResult", dataType: .number,
                    ownerNodeID: batch.id, initial: .number(0)),
            ])

        return CompositeGraph(
            graph: graph,
            template: template,
            loopBodyID: step.node.id,
            skippedBranchNodeID: skippedBranch.node.id)
    }

    // MARK: Held external chain

    struct HeldChain: Sendable {
        var graph: FlowGraph
        var ext1: FlowNode
        var ext2: FlowNode
        var runID: UUID
        var graphID: UUID
    }

    static func makeHeldChain(
        executor: OfflineTestStepExecutor, seedBase: UInt64
    ) throws -> HeldChain {
        let source = constantSource(
            seedBase, name: "offline.constant.go", literal: .string("go"),
            type: .string)
        let ext1 = external(
            seedBase + 0x100, name: "offline.ext1", inputs: [("in", .string)],
            outputs: [("out", .string)])
        let ext2 = external(
            seedBase + 0x200, name: "offline.ext2", inputs: [("in", .string)],
            outputs: [("out", .string)])
        let out = outputNode(
            seedBase + 0x300, inputs: [("in", .string)], resultKey: "done")
        let graph = FlowGraph(
            id: u(seedBase + 0x400), revision: 1,
            nodes: [source.node, ext1.node, ext2.node, out.node],
            edges: [
                edge(seedBase + 0x500, from: source.out, node: source.node,
                     to: ext1.inputs[0], node: ext1.node),
                edge(seedBase + 0x501, from: ext1.outputs[0], node: ext1.node,
                     to: ext2.inputs[0], node: ext2.node),
                edge(seedBase + 0x502, from: ext2.outputs[0], node: ext2.node,
                     to: out.inputs[0], node: out.node),
            ])
        return HeldChain(
            graph: graph, ext1: ext1.node, ext2: ext2.node,
            runID: u(seedBase + 0x600), graphID: graph.id)
    }

    // MARK: Run all flow checks

    static func run(outputRoot: URL) async throws -> ScenarioReport {
        var checks: [Check] = []
        var artifacts: [String] = []
        var notes: [String] = []
        let directory = outputRoot.appendingPathComponent("flow", isDirectory: true)
        var allEvents: [String] = []

        // ---------- Run A: composite graph ----------
        do {
            let composite = try makeCompositeGraph()
            let runtime = FlowRuntimeService(
                executor: nil,
                nativeRegistry: makeRegistry(),
                subgraphTemplates: [composite.template])
            let runID = u(0xA000)
            let runIdentity = makeIdentity(
                runID: runID, canvasID: u(0xA001), graphID: composite.graph.id,
                graphRevision: composite.graph.revision)
            try await runtime.startRun(
                compiled: try await runtime.compile(composite.graph),
                configuration: makeConfiguration(identity: runIdentity))
            let status = await runtime.status(runID: runID)
            let result = await runtime.result(runID: runID)
            let records = await runtime.stepRecords(runID: runID)
            let events = await collectEvents(runtime, runID: runID)
            allEvents.append(contentsOf: events.map(describe))

            let outputs = result?.runOutputs ?? [:]
            let loopOK = outputs["loop.final"] == .number(6)
            let branchOK = outputs["branch.text"] == .string("hello")
            let batchResultsOK = outputs["results"]
                == .list([.number(2), .number(4), .json(.null), .number(8)])
            let failures: [FlowValue]
            if case .list(let list)? = outputs["failures"] {
                failures = list
            } else {
                failures = []
            }
            let batchFailuresOK = failures.count == 1
            let templateOK = outputs["template.doubled"] == .number(10)
            let skippedOK = records.contains {
                $0.nodeID == composite.skippedBranchNodeID
                    && $0.status == .skipped
                    && ($0.error ?? "").contains("branchNotTaken")
            }
            let loopStepsOK = records.filter {
                $0.nodeID == composite.loopBodyID && $0.status == .succeeded
            }.count == 5
            let completedOK = status?.phase == .completed
            checks.append(Check(
                id: "s4.composite",
                scenario: scenarioName,
                status: (loopOK && branchOK && batchResultsOK && batchFailuresOK
                    && templateOK && skippedOK && loopStepsOK && completedOK)
                    ? .pass : .fail,
                detail: "real runtime over offline nodes: loop carry 1→6 with "
                    + "stopWhen, condition selects true branch and skips the "
                    + "false branch (branchNotTaken), batch isolates the "
                    + "scripted item-3 failure (results [2,4,null,8], "
                    + "failures=1), subgraph template doubles 5→10",
                evidence: [
                    "phase=\(status?.phase.rawValue ?? "nil")",
                    "loop.final=\(describe(outputs["loop.final"] ?? .json(.null)))",
                    "branch.text=\(describe(outputs["branch.text"] ?? .json(.null)))",
                    "results=\(describe(outputs["results"] ?? .json(.null)))",
                    "failures=\(failures.count)",
                    "template.doubled=\(describe(outputs["template.doubled"] ?? .json(.null)))",
                    "skipped(branchNotTaken)=\(skippedOK)",
                    "loop body steps=5: \(loopStepsOK)",
                ]))
            checks.append(Check(
                id: "s4.composite.events",
                scenario: scenarioName,
                status: (events.contains { if case .conditionSelected = $0 { return true }; return false }
                    && events.contains { if case .loopIteration = $0 { return true }; return false }
                    && events.contains { if case .batchProgress = $0 { return true }; return false }
                    && events.last.map {
                        if case .runFinished(_, let phase) = $0 {
                            return phase == .completed
                        }
                        return false
                    } == true)
                    ? .pass : .fail,
                detail: "live runtime event stream drives the evidence: "
                    + "conditionSelected / loopIteration / batchProgress / "
                    + "runFinished(completed)",
                evidence: [
                    "events=\(events.count)",
                    "conditionSelected=\(events.contains { if case .conditionSelected = $0 { return true }; return false })",
                    "loopIterations=\(events.filter { if case .loopIteration = $0 { return true }; return false }.count)",
                    "batchProgress=\(events.filter { if case .batchProgress = $0 { return true }; return false }.count)",
                ]))
        } catch {
            checks.append(Check(
                id: "s4.composite",
                scenario: scenarioName,
                status: .fail,
                detail: "composite run error: \(error)",
                evidence: []))
        }

        // ---------- Run B1: breakpoint pauses before the marked node ----------
        do {
            let source = constantSource(
                0x6000, name: "offline.constant.one", literal: .number("1"),
                type: .number)
            let middle = transform(
                0x6100, name: "offline.middle", nativeKey: "offline.noop",
                inputs: [("in", .number)], outputs: [("out", .number)])
            let out = outputNode(0x6200, inputs: [("in", .number)])
            let graph = FlowGraph(
                id: u(0x6300), revision: 1,
                nodes: [source.node, middle.node, out.node],
                edges: [
                    edge(0x6400, from: source.out, node: source.node,
                         to: middle.inputs[0], node: middle.node),
                    edge(0x6401, from: middle.outputs[0], node: middle.node,
                         to: out.inputs[0], node: out.node),
                ])
            let runtime = FlowRuntimeService(
                executor: nil, nativeRegistry: makeRegistry())
            let runID = u(0x6500)
            let runIdentity = makeIdentity(
                runID: runID, canvasID: u(0x6501), graphID: graph.id,
                graphRevision: graph.revision)
            await runtime.setBreakpoints([middle.node.id], runID: runID)
            try await runtime.startRun(
                compiled: try await runtime.compile(graph),
                configuration: makeConfiguration(identity: runIdentity))
            let pausedStatus = await runtime.status(runID: runID)
            let recordsWhilePaused = await runtime.stepRecords(runID: runID)
            let middleRanWhilePaused = recordsWhilePaused.contains {
                $0.nodeID == middle.node.id
            }
            await runtime.resume(runID: runID)
            let finalStatus = await runtime.status(runID: runID)
            let events = await collectEvents(runtime, runID: runID)
            allEvents.append(contentsOf: events.map(describe))

            let breakpointOK = pausedStatus?.phase == .paused
                && !middleRanWhilePaused
            let resumeOK = finalStatus?.phase == .completed
            checks.append(Check(
                id: "s4.breakpoint",
                scenario: scenarioName,
                status: (breakpointOK && resumeOK) ? .pass : .fail,
                detail: "a breakpoint pauses the run BEFORE the marked node "
                    + "executes; resume completes it",
                evidence: [
                    "pausedAtBreakpoint=\(breakpointOK)",
                    "middleRanWhilePaused=\(middleRanWhilePaused)",
                    "completed=\(resumeOK)",
                    "breakpointHit event=\(events.contains { if case .breakpointHit = $0 { return true }; return false })",
                ]))
        } catch {
            checks.append(Check(
                id: "s4.breakpoint",
                scenario: scenarioName,
                status: .fail,
                detail: "breakpoint run error: \(error)",
                evidence: []))
        }

        // ---------- Run B2: step executes exactly one unit then pauses ----------
        do {
            let executor = OfflineTestStepExecutor()
            await executor.setHoldAll(true)
            let chain = try makeHeldChain(executor: executor, seedBase: 0x6600)
            let runtime = FlowRuntimeService(
                executor: executor, nativeRegistry: makeRegistry())
            let runIdentity = makeIdentity(
                runID: chain.runID, canvasID: u(0x6601), graphID: chain.graphID,
                graphRevision: 1)
            let runTask = Task {
                try await runtime.startRun(
                    compiled: try await runtime.compile(chain.graph),
                    configuration: makeConfiguration(identity: runIdentity))
            }
            await waitFor({ await executor.submissionCount() >= 1 })
            let submissionsBeforeStep = await executor.submissionCount()
            await runtime.pause(runID: chain.runID)
            let attempts = await executor.attemptedIDs
            try await executor.complete(
                attemptID: attempts[0],
                outcome: .init(outputs: ["out": .string("ok")]))
            await runtime.externalStepDidFinish(
                runID: chain.runID, attemptID: attempts[0])
            try? await runTask.value
            // ext2 is pending; stepping schedules exactly one more unit.
            await runtime.step(runID: chain.runID)
            await waitFor({ await executor.submissionCount() >= 2 })
            let submissionsAfterStep = await executor.submissionCount()
            let phaseAfterStep = await runtime.status(runID: chain.runID)?.phase
            let attempts2 = await executor.attemptedIDs
            try await executor.complete(
                attemptID: attempts2[attempts2.count - 1],
                outcome: .init(outputs: ["out": .string("done")]))
            await runtime.externalStepDidFinish(
                runID: chain.runID, attemptID: attempts2[attempts2.count - 1])
            await runtime.resume(runID: chain.runID)
            await waitFor({
                await runtime.status(runID: chain.runID)?.phase == .completed
            })
            let finalStatus = await runtime.status(runID: chain.runID)
            let events = await collectEvents(runtime, runID: chain.runID)
            allEvents.append(contentsOf: events.map(describe))
            _ = runTask

            let stepOK = submissionsAfterStep == submissionsBeforeStep + 1
                && (phaseAfterStep == .stepping || phaseAfterStep == .paused)
            let completedOK = finalStatus?.phase == .completed
            checks.append(Check(
                id: "s4.step",
                scenario: scenarioName,
                status: (stepOK && completedOK) ? .pass : .fail,
                detail: "step schedules exactly one more unit then pauses "
                    + "(driver submissions \(submissionsBeforeStep)→"
                    + "\(submissionsAfterStep)); resume completes the run",
                evidence: [
                    "submissions \(submissionsBeforeStep)→\(submissionsAfterStep)",
                    "phase after step=\(phaseAfterStep?.rawValue ?? "nil")",
                    "steppingPaused event=\(events.contains { if case .steppingPaused = $0 { return true }; return false })",
                    "completed=\(completedOK)",
                ]))
        } catch {
            checks.append(Check(
                id: "s4.step",
                scenario: scenarioName,
                status: .fail,
                detail: "step run error: \(error)",
                evidence: []))
        }

        // ---------- Run C: dedupe call counts + cancel + late delivery ----------
        do {
            let executor = OfflineTestStepExecutor()
            await executor.setHoldAll(true)
            let chain = try makeHeldChain(executor: executor, seedBase: 0x7000)
            let runtime = FlowRuntimeService(
                executor: executor, nativeRegistry: makeRegistry())
            let runIdentity = makeIdentity(
                runID: chain.runID, canvasID: u(0x7001), graphID: chain.graphID,
                graphRevision: 1)
            let runTask = Task {
                try await runtime.startRun(
                    compiled: try await runtime.compile(chain.graph),
                    configuration: makeConfiguration(identity: runIdentity))
            }
            await waitFor({ await executor.submissionCount() >= 1 })
            let firstCount = await executor.submissionCount()
            guard firstCount == 1 else {
                throw CanvasKitError.invalidSnapshot(
                    "expected 1 held submission, got \(firstCount)")
            }
            let attempts = await executor.attemptedIDs
            // Pause BEFORE resolving ext1: nothing new may be scheduled while
            // paused, so ext2 must wait for the resume.
            await runtime.pause(runID: chain.runID)
            try await executor.complete(
                attemptID: attempts[0],
                outcome: .init(outputs: ["out": .string("ok")]))
            await runtime.externalStepDidFinish(
                runID: chain.runID, attemptID: attempts[0])
            try? await runTask.value
            let pausedPhase = await runtime.status(runID: chain.runID)?.phase
            let ext2WhilePaused = await executor.submissionCount(forNode: chain.ext2.id)

            // Resume: ext2 must be scheduled exactly once (dedupe evidence).
            await runtime.resume(runID: chain.runID)
            await waitFor({ await executor.submissionCount(forNode: chain.ext2.id) >= 1 })
            let ext2Count = await executor.submissionCount(forNode: chain.ext2.id)
            let attempts2 = await executor.attemptedIDs
            try await executor.complete(
                attemptID: attempts2[attempts2.count - 1],
                outcome: .init(outputs: ["out": .string("done")]))
            await runtime.externalStepDidFinish(
                runID: chain.runID, attemptID: attempts2[attempts2.count - 1])
            await waitFor({
                await runtime.status(runID: chain.runID)?.phase == .completed
            })
            let finalStatus = await runtime.status(runID: chain.runID)
            let result = await runtime.result(runID: chain.runID)
            let ext1Count = await executor.submissionCount(forNode: chain.ext1.id)
            let events = await collectEvents(runtime, runID: chain.runID)
            allEvents.append(contentsOf: events.map(describe))
            _ = runTask

            let dedupeOK = ext1Count == 1 && ext2Count == 1
                && finalStatus?.phase == .completed
                && result?.runOutputs["done"] == .string("done")
            checks.append(Check(
                id: "s4.dedupeCallCounts",
                scenario: scenarioName,
                status: dedupeOK ? .pass : .fail,
                detail: "in-flight external step completes while paused; "
                    + "resume schedules the next step exactly once; total "
                    + "driver submissions per node stay at 1 across pause/"
                    + "resume (no duplicate paid work)",
                evidence: [
                    "phase after pause=\(pausedPhase?.rawValue ?? "nil")",
                    "ext2 while paused=\(ext2WhilePaused)",
                    "ext1 submissions=\(ext1Count)",
                    "ext2 submissions=\(ext2Count)",
                    "completed=\(finalStatus?.phase.rawValue ?? "nil")",
                    "done=\(describe(result?.runOutputs["done"] ?? .json(.null)))",
                ]))

            // Cancel + fenced late delivery, isolated from another run.
            let cancelExecutor = OfflineTestStepExecutor()
            await cancelExecutor.setHoldAll(true)
            let cancelChain = try makeHeldChain(
                executor: cancelExecutor, seedBase: 0x8000)
            let cancelRuntime = FlowRuntimeService(
                executor: cancelExecutor, nativeRegistry: makeRegistry())
            let cancelIdentity = makeIdentity(
                runID: cancelChain.runID, canvasID: u(0x8001),
                graphID: cancelChain.graphID, graphRevision: 1)
            let cancelTask = Task {
                try await cancelRuntime.startRun(
                    compiled: try await cancelRuntime.compile(cancelChain.graph),
                    configuration: makeConfiguration(identity: cancelIdentity))
            }
            await waitFor({ await cancelExecutor.submissionCount() >= 1 })
            let cancelAttempts = await cancelExecutor.attemptedIDs
            await cancelRuntime.cancel(runID: cancelChain.runID)
            try? await cancelTask.value
            let cancelledPhase = await cancelRuntime.status(
                runID: cancelChain.runID)?.phase
            // The late callback arrives after cancellation.
            try await cancelExecutor.complete(
                attemptID: cancelAttempts[0],
                outcome: .init(outputs: ["out": .string("late")]))
            await cancelRuntime.externalStepDidFinish(
                runID: cancelChain.runID, attemptID: cancelAttempts[0])
            let late = await cancelRuntime.lateDeliveries(runID: cancelChain.runID)
            let ext2AfterCancel = await cancelExecutor.submissionCount(
                forNode: cancelChain.ext2.id)

            // A second run on the same runtime is untouched by the late result.
            let otherSource = constantSource(
                0x18100, name: "offline.constant.other", literal: .number("7"),
                type: .number)
            let otherOut = outputNode(
                0x18200, inputs: [("in", .number)], resultKey: "other")
            let otherGraph = FlowGraph(
                id: u(0x8300), revision: 1,
                nodes: [otherSource.node, otherOut.node],
                edges: [edge(0x8400, from: otherSource.out, node: otherSource.node,
                             to: otherOut.inputs[0], node: otherOut.node)])
            let otherIdentity = makeIdentity(
                runID: u(0x8500), canvasID: u(0x8501), graphID: otherGraph.id,
                graphRevision: 1)
            try await cancelRuntime.startRun(
                compiled: try await cancelRuntime.compile(otherGraph),
                configuration: makeConfiguration(identity: otherIdentity))
            let otherResult = await cancelRuntime.result(runID: u(0x8500))
            let otherRecords = await cancelRuntime.stepRecords(runID: u(0x8500))
            let otherUntouched = otherResult?.runOutputs["other"] == .number(7)
                && !otherRecords.contains {
                    $0.nodeID == cancelChain.ext1.id
                        || $0.nodeID == cancelChain.ext2.id
                }
            let cancelEvents = await collectEvents(
                cancelRuntime, runID: cancelChain.runID)
            allEvents.append(contentsOf: cancelEvents.map(describe))

            let cancelOK = cancelledPhase == .cancelled
                && late.count == 1
                && ext2AfterCancel == 0
                && otherUntouched
            checks.append(Check(
                id: "s4.cancelLateDelivery",
                scenario: scenarioName,
                status: cancelOK ? .pass : .fail,
                detail: "cancel fences the in-flight attempt; the late host "
                    + "callback is recorded in lateDeliveries of its own run, "
                    + "never resubmitted and never mutates another run's "
                    + "records or outputs",
                evidence: [
                    "phase=\(cancelledPhase?.rawValue ?? "nil")",
                    "lateDeliveries=\(late.count)",
                    "ext2 submissions after cancel=\(ext2AfterCancel)",
                    "other run output intact=\(otherUntouched)",
                ]))
        } catch {
            checks.append(Check(
                id: "s4.executorHarness",
                scenario: scenarioName,
                status: .fail,
                detail: "executor harness error: \(error)",
                evidence: []))
        }

        // ---------- Run D: unknown submission -> reconcile, never resubmit ----------
        do {
            let executor = OfflineTestStepExecutor()
            // Hold everything: the first submission consumes the `.unknown`
            // ambiguity flag; later submissions stay held until the harness
            // completes them, so adoption is observed without races.
            await executor.setHoldAll(true)
            await executor.armUnknownSubmission()
            let chain = try makeHeldChain(executor: executor, seedBase: 0x9000)
            let runtime = FlowRuntimeService(
                executor: executor, nativeRegistry: makeRegistry())
            let runIdentity = makeIdentity(
                runID: chain.runID, canvasID: u(0x9001), graphID: chain.graphID,
                graphRevision: 1)
            let runTask = Task {
                try await runtime.startRun(
                    compiled: try await runtime.compile(chain.graph),
                    configuration: makeConfiguration(identity: runIdentity))
            }
            await waitFor({ await executor.submissionCount() >= 1 })
            try? await Task.sleep(nanoseconds: 50_000_000)
            let waitingPhase = await runtime.status(runID: chain.runID)?.phase
            let submissionsAfterUnknown = await executor.submissionCount()
            let attempts = await executor.attemptedIDs
            // The host later confirms the work succeeded; reconcile adopts it.
            try await executor.complete(
                attemptID: attempts[0],
                outcome: .init(outputs: ["out": .string("ok")]))
            await runtime.reconcile(runID: chain.runID, attemptID: attempts[0])
            await waitFor({ await executor.submissionCount(forNode: chain.ext2.id) >= 1 })
            let attempts2 = await executor.attemptedIDs
            try await executor.complete(
                attemptID: attempts2[attempts2.count - 1],
                outcome: .init(outputs: ["out": .string("done")]))
            await runtime.externalStepDidFinish(
                runID: chain.runID, attemptID: attempts2[attempts2.count - 1])
            await waitFor({
                await runtime.status(runID: chain.runID)?.phase == .completed
            })
            let finalPhase = await runtime.status(runID: chain.runID)?.phase
            let result = await runtime.result(runID: chain.runID)
            let ext1Count = await executor.submissionCount(forNode: chain.ext1.id)
            let events = await collectEvents(runtime, runID: chain.runID)
            allEvents.append(contentsOf: events.map(describe))
            _ = runTask

            let reconcileOK = waitingPhase == .waitingReconcile
                && submissionsAfterUnknown == 1
                && ext1Count == 1
                && finalPhase == .completed
                && result?.runOutputs["done"] == .string("done")
                && events.contains { if case .reconcileRequired = $0 { return true }; return false }
                && events.contains { if case .reconciled = $0 { return true }; return false }
            checks.append(Check(
                id: "s4.reconcileNoResubmit",
                scenario: scenarioName,
                status: reconcileOK ? .pass : .fail,
                detail: "an unconfirmed submission parks the run in "
                    + "waitingReconcile; the host reconcile adopts the "
                    + "completed work without a second submission",
                evidence: [
                    "phase during ambiguity=\(waitingPhase?.rawValue ?? "nil")",
                    "submissions during ambiguity=\(submissionsAfterUnknown)",
                    "ext1 submissions total=\(ext1Count)",
                    "completed=\(finalPhase?.rawValue ?? "nil")",
                ]))
        } catch {
            checks.append(Check(
                id: "s4.reconcileNoResubmit",
                scenario: scenarioName,
                status: .fail,
                detail: "reconcile run error: \(error)",
                evidence: []))
        }

        // ---------- Run E: frozen journal recovery (dedupe across restart) ----------
        do {
            let journalRoot = directory.appendingPathComponent(
                "journal-\(UUID().uuidString)", isDirectory: true)
            let journal = try FlowRunJournal(root: journalRoot)
            let executor = OfflineTestStepExecutor()
            await executor.setHoldAll(true)
            let chain = try makeHeldChain(executor: executor, seedBase: 0xA000)
            let runConfiguration = makeConfiguration(identity: makeIdentity(
                runID: chain.runID, canvasID: u(0xA001), graphID: chain.graphID,
                graphRevision: 1))

            let runtime1 = FlowRuntimeService(
                executor: executor, journal: journal,
                nativeRegistry: makeRegistry())
            let runTask = Task {
                try await runtime1.startRun(
                    compiled: try await runtime1.compile(chain.graph),
                    configuration: runConfiguration)
            }
            await waitFor({ await executor.submissionCount() >= 1 })
            await runtime1.pause(runID: chain.runID)
            // The suspended run task is abandoned without awaiting — exactly
            // like the owning process dying. Awaiting it here would hang.
            _ = runTask

            // A fresh runtime resumes from the frozen journal only.
            let runtime2 = FlowRuntimeService(
                executor: executor, journal: journal,
                nativeRegistry: makeRegistry())
            try await runtime2.resumeRun(runID: chain.runID)
            let countAfterResume = await executor.submissionCount()
            let attempts = await executor.attemptedIDs
            try await executor.complete(
                attemptID: attempts[0],
                outcome: .init(outputs: ["out": .string("ok")]))
            await runtime2.externalStepDidFinish(
                runID: chain.runID, attemptID: attempts[0])
            await waitFor({ await executor.submissionCount(forNode: chain.ext2.id) >= 1 })
            let attempts2 = await executor.attemptedIDs
            try await executor.complete(
                attemptID: attempts2[attempts2.count - 1],
                outcome: .init(outputs: ["out": .string("done")]))
            await runtime2.externalStepDidFinish(
                runID: chain.runID, attemptID: attempts2[attempts2.count - 1])
            await waitFor({
                await runtime2.status(runID: chain.runID)?.phase == .completed
            })
            let finalPhase = await runtime2.status(runID: chain.runID)?.phase
            let result = await runtime2.result(runID: chain.runID)
            let ext1Count = await executor.submissionCount(forNode: chain.ext1.id)
            let events = await collectEvents(runtime2, runID: chain.runID)
            allEvents.append(contentsOf: events.map(describe))

            let resumeOK = countAfterResume == 1
                && ext1Count == 1
                && finalPhase == .completed
                && result?.runOutputs["done"] == .string("done")
            checks.append(Check(
                id: "s4.frozenRecovery",
                scenario: scenarioName,
                status: resumeOK ? .pass : .fail,
                detail: "a paused run resumed from the frozen journal in a "
                    + "fresh runtime adopts the held attempt without "
                    + "resubmission and completes",
                evidence: [
                    "submissions after resume=\(countAfterResume)",
                    "ext1 submissions total=\(ext1Count)",
                    "phase=\(finalPhase?.rawValue ?? "nil")",
                    "done=\(describe(result?.runOutputs["done"] ?? .json(.null)))",
                ]))
            notes.append("journal evidence retained at \(journalRoot.path)")
        } catch {
            checks.append(Check(
                id: "s4.frozenRecovery",
                scenario: scenarioName,
                status: .fail,
                detail: "journal recovery error: \(error)",
                evidence: []))
        }

        // ---------- Run F: partial rerun adoption ----------
        do {
            let executor = OfflineTestStepExecutor()
            let v1 = try makeHeldChain(executor: executor, seedBase: 0xB000)
            let runtime = FlowRuntimeService(
                executor: executor, nativeRegistry: makeRegistry())
            let firstRunID = u(0xB700)
            let firstIdentity = makeIdentity(
                runID: firstRunID, canvasID: u(0xB701), graphID: v1.graphID,
                graphRevision: 1)
            try await runtime.startRun(
                compiled: try await runtime.compile(v1.graph),
                configuration: makeConfiguration(identity: firstIdentity))
            guard let firstResult = await runtime.result(runID: firstRunID) else {
                throw CanvasKitError.missingEntity("first partial-rerun result")
            }
            let ext1AfterFirst = await executor.submissionCount(forNode: v1.ext1.id)

            // Edit: insert a new external step between ext1 and ext2, reusing
            // the existing nodes' real ports (never fabricating new ones).
            var editedGraph = v1.graph
            let inserted = external(
                0xB500, name: "offline.inserted", inputs: [("in", .string)],
                outputs: [("out", .string)])
            editedGraph.nodes.append(inserted.node)
            editedGraph.revision = 2
            editedGraph.edges.removeAll {
                $0.sourceNodeID == v1.ext1.id && $0.destinationNodeID == v1.ext2.id
            }
            guard let ext1Node = editedGraph.nodes.first(where: { $0.id == v1.ext1.id }),
                  let ext1Out = ext1Node.ports.first(where: {
                      $0.direction == .output && $0.name == "out"
                  }),
                  let ext2Node = editedGraph.nodes.first(where: { $0.id == v1.ext2.id }),
                  let ext2In = ext2Node.ports.first(where: {
                      $0.direction == .input && $0.name == "in"
                  }) else {
                throw CanvasKitError.missingEntity("ext1/ext2 ports")
            }
            editedGraph.edges.append(contentsOf: [
                edge(0xB600, from: ext1Out, node: ext1Node,
                     to: inserted.inputs[0], node: inserted.node),
                edge(0xB601, from: inserted.outputs[0], node: inserted.node,
                     to: ext2In, node: ext2Node),
            ])
            let newRunID = u(0xB800)
            let newIdentity = makeIdentity(
                runID: newRunID, canvasID: u(0xB701), graphID: v1.graphID,
                graphRevision: 2)
            let plan = try FlowRerunPlanner.plan(
                previous: firstResult,
                previousGraph: v1.graph,
                editedGraph: editedGraph,
                editedCompiled: try await runtime.compile(editedGraph),
                configuration: makeConfiguration(identity: newIdentity))
            try await runtime.startRun(
                compiled: try await runtime.compile(editedGraph),
                configuration: makeConfiguration(identity: newIdentity),
                seed: plan.seed)
            let secondResult = await runtime.result(runID: newRunID)
            let ext1AfterSecond = await executor.submissionCount(forNode: v1.ext1.id)
            let insertedCount = await executor.submissionCount(forNode: inserted.node.id)

            let partialOK = plan.invalidatedNodeIDs.contains(inserted.node.id)
                && !plan.reusableNodeIDs.contains(inserted.node.id)
                && ext1AfterFirst == 1
                && ext1AfterSecond == 1 // adopted, never resubmitted
                && insertedCount == 1
                && secondResult?.terminalStatus == .completed
            checks.append(Check(
                id: "s4.partialRerun",
                scenario: scenarioName,
                status: partialOK ? .pass : .fail,
                detail: "after an upstream-preserving edit, the rerun planner "
                    + "invalidates only the new node and its downstream; the "
                    + "previous run's external result is adopted via the seed "
                    + "(driver call counts stay at 1)",
                evidence: [
                    "invalidated=\(plan.invalidatedNodeIDs.count)",
                    "reusable=\(plan.reusableNodeIDs.count)",
                    "ext1 calls \(ext1AfterFirst)→\(ext1AfterSecond)",
                    "inserted calls=\(insertedCount)",
                    "second run=\(secondResult?.terminalStatus.rawValue ?? "nil")",
                ]))
        } catch {
            checks.append(Check(
                id: "s4.partialRerun",
                scenario: scenarioName,
                status: .fail,
                detail: "partial rerun error: \(error)",
                evidence: []))
        }

        // ---------- Environment gate (ICH10) ----------
        do {
            let executor = OfflineTestStepExecutor()
            let step = external(
                0xC000, name: "offline.script", inputs: [],
                outputs: [("out", .string)])
            let graph = FlowGraph(
                id: u(0xC100), revision: 1, nodes: [step.node], edges: [])
            let runtime = FlowRuntimeService(
                executor: executor, nativeRegistry: makeRegistry())
            var rejected = false
            do {
                var emptyIdentity = makeIdentity(
                    runID: u(0xC200), canvasID: u(0xC201), graphID: graph.id,
                    graphRevision: 1)
                emptyIdentity.environmentID = ""
                try await runtime.startRun(
                    compiled: try await runtime.compile(graph),
                    configuration: makeConfiguration(identity: emptyIdentity))
                let status = await runtime.status(runID: emptyIdentity.runID)
                let records = await runtime.stepRecords(runID: emptyIdentity.runID)
                let submitted = await executor.submissionCount()
                rejected = status?.phase == .failed && submitted == 0
                    && records.contains { ($0.error ?? "").contains("environmentRequired") }
            } catch {
                rejected = true
            }
            // Direct host-executor view of the same fail-closed rule.
            let directResult = try await executor.submitStep(CanvasStepExecutionRequest(
                runIdentity: makeIdentity(
                    runID: u(0xC300), canvasID: u(0xC301), graphID: graph.id,
                    graphRevision: 1),
                node: step.node,
                context: CanvasRuntimeContext(
                    canvasID: u(0xC301), pageID: u(0xC302), revision: 0,
                    owningTaskID: nil, environmentID: "")))
            let gateOK = rejected && directResult.status == .failed
                && (directResult.error ?? "").contains("no execution environment")
            checks.append(Check(
                id: "s4.environmentGate",
                scenario: scenarioName,
                status: gateOK ? .pass : .fail,
                detail: "a script step without an explicit environment is "
                    + "rejected by the runtime (environmentRequired) and by "
                    + "the host executor with an explicit unconfigured error; "
                    + "no local interpreter fallback exists",
                evidence: [
                    "runtime rejected=\(rejected)",
                    "executor status=\(directResult.status.rawValue)",
                    "error=\(directResult.error ?? "nil")",
                ]))
        } catch {
            checks.append(Check(
                id: "s4.environmentGate",
                scenario: scenarioName,
                status: .fail,
                detail: "environment gate error: \(error)",
                evidence: []))
        }

        // ---------- Nested structured templates: honest limit ----------
        notes.append(
            "this CLI composite covers conditions, loops, batches and flat "
            + "template instances; nested-template recovery is qualified "
            + "separately by the Flow behavior suite")

        // ---------- artifacts ----------
        if !allEvents.isEmpty {
            for event in allEvents { _ = try JSONFidelity.parse(Data(event.utf8)) }
            let eventData = Data(
                (allEvents.joined(separator: "\n") + "\n").utf8)
            let name = try QualifyIO.write(
                eventData, to: directory, name: "events.jsonl")
            artifacts.append("flow/\(name)")
        }

        return ScenarioReport(
            scenario: scenarioName,
            checks: checks,
            artifacts: artifacts,
            notes: notes)
    }
}
