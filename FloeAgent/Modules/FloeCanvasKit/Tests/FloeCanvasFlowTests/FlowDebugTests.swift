import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Debug controls: breakpoints, pause (stops scheduling, never pretends to
/// freeze remote work), step, bypass, cancel with generation fencing, and
/// observer teardown that must not cancel service-owned runs.
final class FlowDebugTests: XCTestCase {

    /// Chain: const → ext1(holdable) → ext2(holdable) → output.
    private struct HeldChain {
        let graph: FlowGraph
        let compiled: CompiledFlow
        let identity: FlowRunIdentity
        let ext1: FlowNode
        let ext2: FlowNode
    }

    private func makeHeldChain(
        runtime: FlowRuntimeService,
        executor: TestStepExecutor
    ) async throws -> HeldChain {
        let source = GraphFactory.constantSource(literal: .string("go"), type: .string)
        let ext1 = GraphFactory.external(
            name: "ext1", inputs: [("in", .string)], outputs: [("out", .string)])
        let ext2 = GraphFactory.external(
            name: "ext2", inputs: [("in", .string)], outputs: [("out", .string)])
        let out = GraphFactory.output(inputs: [("in", .string)], resultKey: "done")
        let graph = FlowGraph(nodes: [source.node, ext1.node, ext2.node, out.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: ext1.inPorts[0], node: ext1.node),
            GraphFactory.edge(from: ext1.outPorts[0], node: ext1.node,
                              to: ext2.inPorts[0], node: ext2.node),
            GraphFactory.edge(from: ext2.outPorts[0], node: ext2.node,
                              to: out.inPorts[0], node: out.node),
        ])
        _ = executor
        return HeldChain(
            graph: graph,
            compiled: try await runtime.compile(graph),
            identity: GraphFactory.makeIdentity(),
            ext1: ext1.node,
            ext2: ext2.node)
    }

    // MARK: Breakpoints

    func testBreakpointPausesBeforeExecutingNode() async throws {
        let source = GraphFactory.constantSource(literal: .number("1"), type: .number)
        let middle = GraphFactory.transform(
            name: "middle", nativeKey: "noop",
            inputs: [("in", .number)], outputs: [("out", .number)])
        let out = GraphFactory.output(inputs: [("in", .number)])
        let graph = FlowGraph(nodes: [source.node, middle.node, out.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: middle.inPorts[0], node: middle.node),
            GraphFactory.edge(from: middle.outPorts[0], node: middle.node,
                              to: out.inPorts[0], node: out.node),
        ])
        let runtime = FlowRuntimeService(executor: nil, nativeRegistry: TestNativeHandlers.makeRegistry())
        let runID = GraphFactory.makeIdentity().runID
        await runtime.setBreakpoints([middle.node.id], runID: runID)
        try await runtime.startRun(
            compiled: try await runtime.compile(graph),
            configuration: GraphFactory.makeConfiguration(
                identity: GraphFactory.makeIdentity(runID: runID)))
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .paused)
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains { $0.nodeID == source.node.id && $0.status == .succeeded })
        XCTAssertFalse(records.contains { $0.nodeID == middle.node.id })

        await runtime.resume(runID: runID)
        let completed = await runtime.status(runID: runID)
        XCTAssertEqual(completed?.phase, .completed)
    }

    // MARK: Pause with in-flight external work

    func testPauseStopsSchedulingNewWorkButInFlightCompletes() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let runtime = FlowRuntimeService(executor: executor)
        let chain = try await makeHeldChain(runtime: runtime, executor: executor)
        let runTask = Task {
            try await runtime.startRun(
                compiled: chain.compiled,
                configuration: GraphFactory.makeConfiguration(identity: chain.identity))
        }
        await XCTAssertEventually({
            await executor.submissionCount() == 1
        }, message: "ext1 should be submitted")
        // ext1 is held in-flight; pause stops further scheduling.
        await runtime.pause(runID: chain.identity.runID)
        // Complete ext1 while paused.
        let attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime.externalStepDidFinish(runID: chain.identity.runID, attemptID: attempts[0])
        try? await runTask.value
        let status = await runtime.status(runID: chain.identity.runID)
        XCTAssertEqual(status?.phase, .paused)
        // ext1 completed honestly; ext2 never scheduled while paused.
        let submissionsForExt2 = await executor.submissionCount(forNode: chain.ext2.id)
        XCTAssertEqual(submissionsForExt2, 0)

        await runtime.resume(runID: chain.identity.runID)
        await XCTAssertEventually({
            await executor.submissionCount(forNode: chain.ext2.id) == 1
        }, message: "ext2 should be scheduled after resume")
        let attempts2 = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts2.last!,
            outcome: .init(status: .succeeded, outputs: ["out": .string("done")]))
        await runtime.externalStepDidFinish(
            runID: chain.identity.runID, attemptID: attempts2.last!)
        await XCTAssertEventually({
            await runtime.status(runID: chain.identity.runID)?.phase == .completed
        }, message: "run should complete")
        let result = await runtime.result(runID: chain.identity.runID)
        XCTAssertEqual(result?.runOutputs["done"], .string("done"))
    }

    // MARK: Step

    func testStepExecutesExactlyOneUnitThenPauses() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let runtime = FlowRuntimeService(executor: executor)
        let chain = try await makeHeldChain(runtime: runtime, executor: executor)
        let runID = chain.identity.runID
        let runTask = Task {
            try await runtime.startRun(
                compiled: chain.compiled,
                configuration: GraphFactory.makeConfiguration(identity: chain.identity))
        }
        await XCTAssertEventually({
            await executor.submissionCount() == 1
        })
        await runtime.pause(runID: runID)
        let attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime.externalStepDidFinish(runID: runID, attemptID: attempts[0])
        try? await runTask.value

        await runtime.step(runID: runID)
        await XCTAssertEventually({
            await executor.submissionCount(forNode: chain.ext2.id) == 1
        }, message: "step should schedule exactly one unit")
        // The stepped unit is still executing; then the pause takes effect.
        let attemptsAfterStep = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attemptsAfterStep.last!,
            outcome: .init(status: .succeeded, outputs: ["out": .string("done")]))
        await runtime.externalStepDidFinish(
            runID: runID, attemptID: attemptsAfterStep.last!)
        await XCTAssertEventually({
            await runtime.status(runID: runID)?.phase == .paused
        }, message: "stepping pauses after the unit")
        // Nothing beyond the stepped unit was scheduled.
        let finalCount = await executor.submissionCount()
        XCTAssertEqual(finalCount, 2)
        _ = runTask
    }

    // MARK: Bypass

    func testBypassSkipsNodeWithoutExecution() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let runtime = FlowRuntimeService(executor: executor)
        let chain = try await makeHeldChain(runtime: runtime, executor: executor)
        let runID = chain.identity.runID
        await runtime.bypass(nodeID: chain.ext2.id, runID: runID)
        let runTask = Task {
            try await runtime.startRun(
                compiled: chain.compiled,
                configuration: GraphFactory.makeConfiguration(identity: chain.identity))
        }
        await XCTAssertEventually({
            await executor.submissionCount() == 1
        })
        let attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime.externalStepDidFinish(runID: runID, attemptID: attempts[0])
        try? await runTask.value
        let submissionsForExt2 = await executor.submissionCount(forNode: chain.ext2.id)
        XCTAssertEqual(submissionsForExt2, 0)
        let records = await runtime.stepRecords(runID: runID)
        XCTAssertTrue(records.contains {
            $0.nodeID == chain.ext2.id && $0.status == .skipped
                && ($0.error ?? "") == "bypassed"
        })
    }

    // MARK: Cancel with generation fencing

    func testCancelFencesLateDelivery() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let runtime = FlowRuntimeService(executor: executor)
        let chain = try await makeHeldChain(runtime: runtime, executor: executor)
        let runID = chain.identity.runID
        let runTask = Task {
            try await runtime.startRun(
                compiled: chain.compiled,
                configuration: GraphFactory.makeConfiguration(identity: chain.identity))
        }
        await XCTAssertEventually({
            await executor.submissionCount() == 1
        })
        await runtime.cancel(runID: runID)
        let cancelCalls = await executor.cancelRunCalls
        XCTAssertEqual(cancelCalls, [runID])
        // Late completion arrives after cancel.
        let attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("late")]))
        await runtime.externalStepDidFinish(runID: runID, attemptID: attempts[0])
        try? await runTask.value
        let status = await runtime.status(runID: runID)
        XCTAssertEqual(status?.phase, .cancelled)
        let late = await runtime.lateDeliveries(runID: runID)
        XCTAssertEqual(late.count, 1)
        // The late result must not have unblocked downstream work.
        let submissionsForExt2 = await executor.submissionCount(forNode: chain.ext2.id)
        XCTAssertEqual(submissionsForExt2, 0)
    }

    // MARK: Observer teardown

    func testObserverTeardownDoesNotCancelRun() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let runtime = FlowRuntimeService(executor: executor)
        let chain = try await makeHeldChain(runtime: runtime, executor: executor)
        let runID = chain.identity.runID
        let stream = await runtime.events(runID: runID)
        let runTask = Task {
            try await runtime.startRun(
                compiled: chain.compiled,
                configuration: GraphFactory.makeConfiguration(identity: chain.identity))
        }
        // Consume one event then tear the observer down.
        let consumed = Task {
            var count = 0
            for await _ in stream {
                count += 1
                if count >= 1 { break }
            }
            return count
        }
        _ = await consumed.value
        await XCTAssertEventually({
            await executor.submissionCount() == 1
        })
        let attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime.externalStepDidFinish(runID: runID, attemptID: attempts[0])
        await XCTAssertEventually({
            await executor.submissionCount(forNode: chain.ext2.id) == 1
        }, message: "run must continue after observer teardown")
        let attempts2 = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts2.last!,
            outcome: .init(status: .succeeded, outputs: ["out": .string("done")]))
        await runtime.externalStepDidFinish(
            runID: runID, attemptID: attempts2.last!)
        await XCTAssertEventually({
            await runtime.status(runID: runID)?.phase == .completed
        }, message: "run completes despite observer teardown")
        try? await runTask.value
    }
}
