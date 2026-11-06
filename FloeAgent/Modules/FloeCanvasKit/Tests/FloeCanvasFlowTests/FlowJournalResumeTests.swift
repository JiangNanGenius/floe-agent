import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Durable journal and crash-safe resume: frozen definitions, reconcile
/// without resubmission, fail-closed corruption handling, torn-tail
/// tolerance, atomic overwrite and the "current canvas moved on" case.
final class FlowJournalResumeTests: XCTestCase {

    private var root: URL!
    private var journal: FlowRunJournal!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-flow-journal-\(UUID().uuidString)")
        journal = try FlowRunJournal(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func chainGraph() -> (graph: FlowGraph, ext: FlowNode, ext2: FlowNode, out: FlowNode) {
        let source = GraphFactory.constantSource(literal: .string("go"), type: .string)
        let ext = GraphFactory.external(
            name: "ext", inputs: [("in", .string)], outputs: [("out", .string)])
        let ext2 = GraphFactory.external(
            name: "ext2", inputs: [("in", .string)], outputs: [("out", .string)])
        let out = GraphFactory.output(inputs: [("in", .string)], resultKey: "done")
        let graph = FlowGraph(nodes: [source.node, ext.node, ext2.node, out.node], edges: [
            GraphFactory.edge(from: source.out, node: source.node,
                              to: ext.inPorts[0], node: ext.node),
            GraphFactory.edge(from: ext.outPorts[0], node: ext.node,
                              to: ext2.inPorts[0], node: ext2.node),
            GraphFactory.edge(from: ext2.outPorts[0], node: ext2.node,
                              to: out.inPorts[0], node: out.node),
        ])
        return (graph, ext.node, ext2.node, out.node)
    }

    // MARK: Resume without resubmission

    func testResumeReconcilesWithoutResubmittingPaidWork() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        // Process 1: start, ext held in-flight, pause writes a checkpoint.
        let runtime1 = FlowRuntimeService(executor: executor, journal: journal)
        let compiled1 = try await runtime1.compile(fixture.graph)
        let runTask = Task {
            try await runtime1.startRun(compiled: compiled1, configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)
        // `pause` acknowledges only after its checkpoint is durable: assert
        // the crash boundary directly, with no timing fence.
        let journal = self.journal!
        let pauseSnapshot = try await journal.loadCheckpoint(runID: identity.runID)
        XCTAssertEqual(pauseSnapshot?.phase, .paused)
        // Process dies here: the suspended run task is abandoned, exactly
        // like a process exit.

        // Process 2 resumes from the journal only.
        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID)
        // Reconcile loop queried the held attempt; it stays pending, never
        // resubmitted.
        let countAfterResume = await executor.submissionCount()
        XCTAssertEqual(countAfterResume, 1)
        let extCountAfterResume = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extCountAfterResume, 1)
        // Complete ext via the host hook; ext2 then schedules exactly once.
        let attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime2.externalStepDidFinish(runID: identity.runID, attemptID: attempts[0])
        await XCTAssertEventually({
            await executor.submissionCount(forNode: fixture.ext2.id) == 1
        }, message: "ext2 schedules after resume")
        let attempts2 = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts2.last!,
            outcome: .init(status: .succeeded, outputs: ["out": .string("done")]))
        await runtime2.externalStepDidFinish(
            runID: identity.runID, attemptID: attempts2.last!)
        await XCTAssertEventually({
            await runtime2.status(runID: identity.runID)?.phase == .completed
        })
        let result = await runtime2.result(runID: identity.runID)
        XCTAssertEqual(result?.runOutputs["done"], .string("done"))
        // The adopted ext result produced no second paid call.
        let extSubmissions = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extSubmissions, 1)
    }

    func testResumeUsesFrozenDefinitionsWhenCanvasMovedOn() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        let runtime1 = FlowRuntimeService(executor: executor, journal: journal)
        let compiled1 = try await runtime1.compile(fixture.graph)
        let runTask = Task {
            try await runtime1.startRun(compiled: compiled1, configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)
        // `pause` acknowledges only after its checkpoint is durable.
        let journal = self.journal!
        let pauseSnapshot = try await journal.loadCheckpoint(runID: identity.runID)
        XCTAssertEqual(pauseSnapshot?.phase, .paused)
        // Process dies here.

        // "User edits the canvas": mutate the graph object (add a node,
        // move positions). The frozen definitions must win at resume.
        var mutated = fixture.graph
        mutated.nodes.append(FlowNode(kind: .source, name: "newNode"))
        mutated.nodes[0].position = .init(x: 999, y: 999)
        XCTAssertNotEqual(try FlowDigest.of(mutated), try FlowDigest.of(fixture.graph))

        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID) // no graph passed
        let attempts = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime2.externalStepDidFinish(runID: identity.runID, attemptID: attempts[0])
        await XCTAssertEventually({
            await executor.submissionCount(forNode: fixture.ext2.id) == 1
        })
        let attempts2 = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: attempts2.last!,
            outcome: .init(status: .succeeded, outputs: ["out": .string("done")]))
        await runtime2.externalStepDidFinish(
            runID: identity.runID, attemptID: attempts2.last!)
        await XCTAssertEventually({
            await runtime2.status(runID: identity.runID)?.phase == .completed
        })
        let result = await runtime2.result(runID: identity.runID)
        XCTAssertEqual(result?.runOutputs["done"], .string("done"))
    }

    // MARK: Fail-closed reads

    func testCorruptAttemptRecordFailsClosedWithoutResubmission() async throws {
        let executor = TestStepExecutor()
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let runtime = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime.startRun(
            compiled: try await runtime.compile(fixture.graph),
            configuration: GraphFactory.makeConfiguration(identity: identity))
        let status = await runtime.status(runID: identity.runID)
        XCTAssertEqual(status?.phase, .completed)
        let submissionsBefore = await executor.submissionCount()

        // Corrupt one attempt file.
        let attemptsDir = root.appendingPathComponent("runs/\(identity.runID.uuidString)/attempts")
        let files = try FileManager.default.contentsOfDirectory(at: attemptsDir,
                                                                includingPropertiesForKeys: nil)
        let target = files.first { $0.pathExtension == "json" }!
        try Data("not json".utf8).write(to: target)

        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        await XCTAssertThrowsErrorAsync({
            try await runtime2.resumeRun(runID: identity.runID)
        }) { error in
            guard case FlowJournalError.corruptJournal = error else {
                XCTFail("expected corruptJournal, got \(error)")
                return
            }
        }
        let submissionsAfter = await executor.submissionCount()
        XCTAssertEqual(submissionsAfter, submissionsBefore)
    }

    func testTornTailIsToleratedButMiddleCorruptionThrows() async throws {
        let executor = TestStepExecutor()
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let runtime = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime.startRun(
            compiled: try await runtime.compile(fixture.graph),
            configuration: GraphFactory.makeConfiguration(identity: identity))
        let journalURL = root.appendingPathComponent(
            "runs/\(identity.runID.uuidString)/journal.jsonl")
        let original = try Data(contentsOf: journalURL)

        // Torn tail (no trailing newline) is ignored.
        var torn = original
        torn.append(Data("{\"par".utf8)) // no newline: crash-mid-append shape
        try torn.write(to: journalURL)
        let entriesAfterTorn = try await journal.loadJournal(runID: identity.runID)
        XCTAssertFalse(entriesAfterTorn.isEmpty)

        // A newline-terminated bad line in the middle is corruption.
        var corrupt = original
        corrupt.append(Data("\n{\"bad\":true}\n".utf8))
        try corrupt.write(to: journalURL)
        await XCTAssertThrowsErrorAsync({
            _ = try await self.journal.loadJournal(runID: identity.runID)
        }) { error in
            guard case FlowJournalError.corruptJournal = error else {
                XCTFail("expected corruptJournal, got \(error)")
                return
            }
        }
    }

    func testAtomicOverwriteAllowsSecondManifestAndCheckpointWrites() async throws {
        let executor = TestStepExecutor()
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let runtime = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime.startRun(
            compiled: try await runtime.compile(fixture.graph),
            configuration: GraphFactory.makeConfiguration(identity: identity))
        // A completed run rewrote manifest + checkpoint + attempts several
        // times; all reads must reflect the latest bytes.
        let manifest = try await journal.loadManifest(runID: identity.runID)
        XCTAssertEqual(manifest?.phase, .completed)
        let snapshot = try await journal.loadCheckpoint(runID: identity.runID)
        XCTAssertEqual(snapshot?.phase, .completed)
        let attempts = try await journal.loadAttempts(runID: identity.runID)
        XCTAssertEqual(attempts.count, 2)
        XCTAssertTrue(attempts.allSatisfy { $0.status == .succeeded })
        // Definitions were frozen before any attempt.
        let definitions = try await journal.loadDefinitions(runID: identity.runID)
        XCTAssertEqual(definitions?.graph.nodes.count, fixture.graph.nodes.count)
        XCTAssertEqual(definitions?.configuration.identity, identity)
    }

    func testDuplicateAttemptAfterRestartReusesHostWork() async throws {
        // Same attempt ID regenerated after restart must be served from the
        // journal, not resubmitted.
        let executor = TestStepExecutor()
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)
        let runtime1 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime1.startRun(
            compiled: try await runtime1.compile(fixture.graph),
            configuration: configuration)
        let submissionsBefore = await executor.submissionCount()

        // Simulate a crash AFTER the run completed but where a duplicate
        // request replays: restarting and resuming a terminal run must not
        // resubmit anything.
        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID)
        let replayCount = await executor.submissionCount()
        XCTAssertEqual(replayCount, submissionsBefore)
        let replayPhase = await runtime2.status(runID: identity.runID)?.phase
        XCTAssertEqual(replayPhase, .completed)
    }

    // MARK: Unconfirmed submissions stay pending

    func testUnconfirmedSubmissionWaitsForReconcileNeverResubmits() async throws {
        let fixture = chainGraph()
        // Pre-mark every attempt as unconfirmed; the driver returns
        // `.unknown` without recording a result.
        let executor = TestStepExecutor(unconfirmedAttempts: []) // none pre-marked;
        // holdAll + manual completion models the ambiguous window instead.
        await executor.setHoldAll(true)
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)
        let runtime = FlowRuntimeService(executor: executor, journal: journal)
        let runTask = Task {
            try await runtime.startRun(
                compiled: try await runtime.compile(fixture.graph),
                configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        // Checkpoint via pause, then kill the process with the submission
        // unconfirmed. `pause` returns only after the checkpoint is durable,
        // so the resumed runtime deterministically restores the held attempt
        // as pending-reconcile instead of re-scheduling it.
        await runtime.pause(runID: identity.runID)
        let journal = self.journal!
        let pauseSnapshot = try await journal.loadCheckpoint(runID: identity.runID)
        XCTAssertEqual(pauseSnapshot?.phase, .paused)
        _ = runTask
        _ = runtime

        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID)
        // Query cannot resolve (driver has no result): stays pending, and
        // no resubmission happened.
        let pendingCount = await executor.submissionCount()
        XCTAssertEqual(pendingCount, 1)
        let pending = await runtime2.status(runID: identity.runID)?.pendingReconciliations
        XCTAssertEqual(pending, 1)
    }
}
