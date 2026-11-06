import Foundation
import XCTest
@testable import FloeCanvasCore
@testable import FloeCanvasIntegration
@testable import FloeCanvasFlow

/// Crash-recovery semantics (P2d): durable pause acknowledgement, truthful
/// checkpoint-write failure, and coordinate-exact resume reconstruction.
/// Every scenario is deterministic — no polls around crash boundaries, no
/// fake journal or driver success; process death is modelled by dropping the
/// first runtime while the shared driver/journal keep the durable facts.
final class FlowCheckpointRecoveryTests: XCTestCase {

    private var root: URL!
    private var journal: FlowRunJournal!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-flow-recovery-\(UUID().uuidString)")
        journal = try FlowRunJournal(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func chainGraph()
        -> (graph: FlowGraph, source: FlowNode, ext: FlowNode, ext2: FlowNode, out: FlowNode) {
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
        return (graph, source.node, ext.node, ext2.node, out.node)
    }

    // MARK: 1. Durable pause acknowledgement

    func testPauseWhileReconcilingDoesNotScheduleAfterUnknownResolves() async throws {
        let fixture = chainGraph()
        let firstID = fixture.ext.id
        let executor = TestStepExecutor(outcomeForNode: { id in
            id == firstID ? .init(status: .unknown) : .init(status: .succeeded, outputs: ["out": .string("done")])
        })
        let runtime = FlowRuntimeService(executor: executor, journal: journal)
        let runID = try await runtime.startRun(
            compiled: try await runtime.compile(fixture.graph),
            configuration: GraphFactory.makeConfiguration(identity: GraphFactory.makeIdentity()))
        let waiting = await runtime.status(runID: runID)?.phase
        XCTAssertEqual(waiting, .waitingReconcile)
        await runtime.pause(runID: runID)
        let checkpoint = try await journal.loadCheckpoint(runID: runID)
        XCTAssertEqual(checkpoint?.phase, .paused)
        let attempts = await executor.performedAttemptIDs
        let attempt = try XCTUnwrap(attempts.first)
        try await executor.complete(attemptID: attempt,
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime.externalStepDidFinish(runID: runID, attemptID: attempt)
        let paused = await runtime.status(runID: runID)?.phase
        let downstream = await executor.submissionCount(forNode: fixture.ext2.id)
        XCTAssertEqual(paused, .paused)
        XCTAssertEqual(downstream, 0, "resolving an unknown attempt must preserve the user's pause intent")
        await runtime.resume(runID: runID)
        let completed = await runtime.status(runID: runID)?.phase
        let total = await executor.submissionCount()
        XCTAssertEqual(completed, .completed)
        XCTAssertEqual(total, 2)
    }

    /// `pause` returns only after its checkpoint is durable: the process may
    /// die the moment it returns and a resume must see the paused state.
    func testPauseAcknowledgesDurableCheckpointBeforeReturning() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let runtime = FlowRuntimeService(executor: executor, journal: journal)
        let runTask = Task {
            try await runtime.startRun(
                compiled: try await runtime.compile(fixture.graph),
                configuration: GraphFactory.makeConfiguration(identity: identity))
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime.pause(runID: identity.runID)
        // No timing fence: the acknowledgement IS the durable write.
        let snapshot = try await journal.loadCheckpoint(runID: identity.runID)
        XCTAssertEqual(snapshot?.phase, .paused)
        let extKey = "/#\(fixture.ext.id.uuidString)"
        XCTAssertEqual(snapshot?.nodeStates[extKey]?.kind, .running)
        // The attempt was persisted before submission, so it is durable too.
        let attempts = try await journal.loadAttempts(runID: identity.runID)
        XCTAssertEqual(attempts.count, 1)
        _ = runTask
    }

    // MARK: 2. Stale checkpoint + newer durable records: query/adopt, never re-perform

    /// The host finishes the held attempt AFTER the pause checkpoint was
    /// written (the checkpoint still shows the unit `.running` and the disk
    /// record `.running`). Resume must query/adopt the host's completed
    /// result and schedule only the downstream unit — the unit is NEVER
    /// re-submitted.
    func testResumeAdoptsHostCompletedAttemptBehindStaleCheckpoint() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        let runtime1 = FlowRuntimeService(executor: executor, journal: journal)
        let runTask = Task {
            try await runtime1.startRun(
                compiled: try await runtime1.compile(fixture.graph),
                configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)
        let pauseSnapshot = try await journal.loadCheckpoint(runID: identity.runID)
        XCTAssertEqual(pauseSnapshot?.phase, .paused)
        // Process dies here, but the host completes the work after the
        // checkpoint: the driver holds a newer terminal fact than the journal.
        let attempts = try await journal.loadAttempts(runID: identity.runID)
        XCTAssertEqual(attempts.count, 1)
        let heldAttempt = attempts[0].attemptID
        try await executor.complete(
            attemptID: heldAttempt,
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))

        // Process 2 resumes from the journal only.
        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID)
        // Zero re-perform: the held coordinate was queried/adopted, not re-run.
        let extSubmissions = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extSubmissions, 1)
        // The adopted result unblocked exactly one new submission.
        let ext2Submissions = await executor.submissionCount(forNode: fixture.ext2.id)
        XCTAssertEqual(ext2Submissions, 1)
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
        let extFinal = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extFinal, 1)
        _ = runTask
    }

    /// Even staler: the checkpoint still shows the unit `.pending` (written
    /// before the pump even marked it running), while the attempt ledger has
    /// a terminal record. Resume must adopt the terminal record — the unit is
    /// never executed again.
    func testResumeAdoptsTerminalRecordBehindStalePendingCheckpoint() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        let runtime1 = FlowRuntimeService(executor: executor, journal: journal)
        let runTask = Task {
            try await runtime1.startRun(
                compiled: try await runtime1.compile(fixture.graph),
                configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)

        // Age the journal past the checkpoint: a terminal record replaces the
        // open one, and the checkpoint is rewritten with the unit `.pending`.
        let attempts = try await journal.loadAttempts(runID: identity.runID)
        var terminal = attempts[0]
        terminal.status = .succeeded
        terminal.outputs = ["out": .string("ok")]
        terminal.updatedAt = terminal.updatedAt.addingTimeInterval(10)
        try await journal.persistAttempt(terminal)
        let stale = try await journal.loadCheckpoint(runID: identity.runID)
        var mutated = try XCTUnwrap(stale)
        mutated.nodeStates["/#\(fixture.ext.id.uuidString)"] = .init(
            kind: .pending, outputs: [:], attempt: 1)
        try await journal.saveCheckpoint(mutated)
        // Process dies here.

        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID)
        // The pending-looking unit was adopted from the ledger: zero new
        // submissions for its coordinate.
        let extSubmissions = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extSubmissions, 1)
        let ext2Submissions = await executor.submissionCount(forNode: fixture.ext2.id)
        XCTAssertEqual(ext2Submissions, 1)
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
        let extFinal = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extFinal, 1)
        _ = runTask
    }

    /// A newer `.submitted` record behind a stale checkpoint must be queued
    /// for host reconcile — never re-submitted.
    func testResumeReconcilesNewerSubmittedRecordBehindStaleCheckpoint() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        let runtime1 = FlowRuntimeService(executor: executor, journal: journal)
        let runTask = Task {
            try await runtime1.startRun(
                compiled: try await runtime1.compile(fixture.graph),
                configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)

        // The durable ledger now knows the submission was confirmed by the
        // host (`.submitted`), newer than the checkpoint's `.running` view.
        let attempts = try await journal.loadAttempts(runID: identity.runID)
        var submitted = attempts[0]
        submitted.status = .submitted
        submitted.updatedAt = submitted.updatedAt.addingTimeInterval(10)
        try await journal.persistAttempt(submitted)
        // Process dies here.

        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID)
        // Query could not resolve (driver still holds, no result): the unit
        // stays pending-reconcile and NO second submission happened.
        let total = await executor.submissionCount()
        XCTAssertEqual(total, 1)
        let extSubmissions = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extSubmissions, 1)
        let pending = await runtime2.status(runID: identity.runID)?.pendingReconciliations
        XCTAssertEqual(pending, 1)
        // Once the host answers, the run proceeds without any re-perform.
        let performed = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: performed[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime2.externalStepDidFinish(
            runID: identity.runID, attemptID: performed[0])
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
        _ = runTask
    }

    /// A newer `.unknown` record (submission could not be confirmed) behind a
    /// stale checkpoint stays pending-reconcile — query only, never resubmit.
    func testResumeReconcilesNewerUnknownRecordBehindStaleCheckpoint() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        let runtime1 = FlowRuntimeService(executor: executor, journal: journal)
        let runTask = Task {
            try await runtime1.startRun(
                compiled: try await runtime1.compile(fixture.graph),
                configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)

        let attempts = try await journal.loadAttempts(runID: identity.runID)
        var unknown = attempts[0]
        unknown.status = .unknown
        unknown.updatedAt = unknown.updatedAt.addingTimeInterval(10)
        try await journal.persistAttempt(unknown)
        // The driver genuinely cannot resolve the attempt either.
        let performed = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: performed[0],
            outcome: .init(status: .unknown))
        // Process dies here.

        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID)
        let total = await executor.submissionCount()
        XCTAssertEqual(total, 1)
        let pending = await runtime2.status(runID: identity.runID)?.pendingReconciliations
        XCTAssertEqual(pending, 1)
        // Later the host resolves it; the run continues with zero re-perform.
        try await executor.complete(
            attemptID: performed[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime2.externalStepDidFinish(
            runID: identity.runID, attemptID: performed[0])
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
        let extFinal = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extFinal, 1)
        _ = runTask
    }

    /// A `.persisted`-only record (crash between the pre-submit persist and
    /// the status update) is queried first; a host that holds the attempt
    /// answers the query, so no second submission ever happens.
    func testResumeQueriesHostForPersistedRecordWithoutSecondPaidCall() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        let runtime1 = FlowRuntimeService(executor: executor, journal: journal)
        let runTask = Task {
            try await runtime1.startRun(
                compiled: try await runtime1.compile(fixture.graph),
                configuration: configuration)
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)

        // Roll the durable record back to `.persisted`: the submission DID
        // reach the driver, but the post-submit status write was lost.
        let attempts = try await journal.loadAttempts(runID: identity.runID)
        var persisted = attempts[0]
        persisted.status = .persisted
        try await journal.persistAttempt(persisted)
        // Process dies here.

        let runtime2 = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime2.resumeRun(runID: identity.runID)
        // The reconcile query found the held attempt on the host: still one
        // unique performed attempt, still waiting on its result.
        let extSubmissions = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extSubmissions, 1)
        let performed = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: performed[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime2.externalStepDidFinish(
            runID: identity.runID, attemptID: performed[0])
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
        let extFinal = await executor.submissionCount(forNode: fixture.ext.id)
        XCTAssertEqual(extFinal, 1)
        _ = runTask
    }

    // MARK: 3. Call-path / iteration coordinate isolation

    /// Two instances of one template share the inner node ID but live at
    /// distinct call paths. A late host answer for the first instance must
    /// adopt only into its own coordinate; the second instance performs its
    /// own attempt and produces its own value.
    func testNestedTemplateInstancesRestoreCoordinatesIndependently() async throws {
        let innerExt = GraphFactory.external(
            name: "inner", inputs: [], outputs: [("text", .string)])
        let innerOut = GraphFactory.output(
            inputs: [("text", .string)], resultKey: "text")
        let templateGraph = FlowGraph(nodes: [innerExt.node, innerOut.node], edges: [
            GraphFactory.edge(from: innerExt.outPorts[0], node: innerExt.node,
                              to: innerOut.inPorts[0], node: innerOut.node),
        ])
        let template = FlowSubgraphTemplate(
            id: UUID(), name: "scripted", graph: templateGraph,
            exposedPorts: [FlowPort(name: "text", dataType: .string, direction: .output)])
        func instance(_ name: String) -> FlowNode {
            FlowNode(
                id: UUID(uuidString: name == "first"
                    ? "00000000-0000-0000-0000-000000000001"
                    : "00000000-0000-0000-0000-000000000002")!,
                kind: .subgraph, name: name,
                ports: [FlowPort(name: "text", dataType: .string, direction: .output)],
                subgraphTemplateID: template.id)
        }
        let first = instance("first")
        let second = instance("second")
        let out = GraphFactory.output(
            inputs: [("a", .string), ("b", .string)], resultKey: nil)
        let graph = FlowGraph(nodes: [first, second, out.node], edges: [
            GraphFactory.edge(from: first.ports[0], node: first,
                              to: out.inPorts[0], node: out.node),
            GraphFactory.edge(from: second.ports[0], node: second,
                              to: out.inPorts[1], node: out.node),
        ])

        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let identity = GraphFactory.makeIdentity()
        let configuration = GraphFactory.makeConfiguration(identity: identity)

        let runtime1 = FlowRuntimeService(
            executor: executor, journal: journal,
            nativeRegistry: TestNativeHandlers.makeRegistry(),
            subgraphTemplates: [template])
        let runTask = Task {
            try await runtime1.startRun(
                compiled: try await runtime1.compile(graph), configuration: configuration)
        }
        // Only the first instance's inner attempt exists; the second has not
        // been scheduled (sequential scheduler parks on the held attempt).
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        await runtime1.pause(runID: identity.runID)
        let pauseSnapshot = try await journal.loadCheckpoint(runID: identity.runID)
        XCTAssertEqual(pauseSnapshot?.phase, .paused)
        let firstAttempt = (await executor.performedAttemptIDs)[0]
        try await executor.complete(
            attemptID: firstAttempt,
            outcome: .init(status: .succeeded, outputs: ["text": .string("A")]))
        // Process dies here.

        let runtime2 = FlowRuntimeService(
            executor: executor, journal: journal,
            nativeRegistry: TestNativeHandlers.makeRegistry())
        try await runtime2.resumeRun(runID: identity.runID)
        // The first coordinate was adopted from the ledger; the second
        // instance then performed exactly one new attempt of its own.
        let totalAfterResume = await executor.submissionCount()
        XCTAssertEqual(totalAfterResume, 2)
        let secondAttempt = (await executor.performedAttemptIDs)[1]
        XCTAssertNotEqual(firstAttempt, secondAttempt)
        try await executor.complete(
            attemptID: secondAttempt,
            outcome: .init(status: .succeeded, outputs: ["text": .string("B")]))
        await runtime2.externalStepDidFinish(
            runID: identity.runID, attemptID: secondAttempt)
        await XCTAssertEventually({
            await runtime2.status(runID: identity.runID)?.phase == .completed
        })
        let result = await runtime2.result(runID: identity.runID)
        // Per-coordinate adoption: each instance kept its own value.
        XCTAssertEqual(result?.runOutputs["a"], .string("A"))
        XCTAssertEqual(result?.runOutputs["b"], .string("B"))
        let totalFinal = await executor.submissionCount()
        XCTAssertEqual(totalFinal, 2)
        _ = runTask
    }

    // MARK: 4. Truthful checkpoint-write failure

    /// Real file failure fixture: `checkpoint.json` pre-exists as a
    /// DIRECTORY, so the atomic rename fails. The run must surface the
    /// failure (`checkpointFailed` + `.failed`), must never announce
    /// `checkpointSaved`, and must not schedule any work afterwards.
    func testCheckpointWriteFailureFailsRunTruthfullyAndStopsScheduling() async throws {
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        // Block the checkpoint destination before anything runs.
        let runDirectory = root.appendingPathComponent(
            "runs/\(identity.runID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runDirectory.appendingPathComponent("checkpoint.json", isDirectory: true),
            withIntermediateDirectories: true)

        let executor = TestStepExecutor()
        let runtime = FlowRuntimeService(executor: executor, journal: journal)
        try await runtime.startRun(
            compiled: try await runtime.compile(fixture.graph),
            configuration: GraphFactory.makeConfiguration(identity: identity))
        // Subscribe after the fact: the stream replays the retained history.
        let stream = await runtime.events(runID: identity.runID)
        let collect = Task { () -> [FlowRuntimeEvent] in
            var events: [FlowRuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if case .runFinished = event { break }
            }
            return events
        }
        let events = await collect.value
        func has(_ event: FlowRuntimeEvent) -> Bool { events.contains(event) }
        XCTAssertTrue(has(.runStarted(runID: identity.runID, revisionKeyBound: true)))
        XCTAssertTrue(has(.checkpointFailed(
            runID: identity.runID,
            error: events.compactMap { event in
                if case .checkpointFailed(_, let error) = event { return error }
                return nil
            }.first ?? "")))
        // The lie is gone: no success announcement for a failed write.
        XCTAssertFalse(has(.checkpointSaved(runID: identity.runID)))
        XCTAssertTrue(has(.runFinished(runID: identity.runID, phase: .failed)))
        // No work was scheduled as though the state were recoverable.
        let submissions = await executor.submissionCount()
        XCTAssertEqual(submissions, 0)
        let status = await runtime.status(runID: identity.runID)
        XCTAssertEqual(status?.phase, .failed)
        XCTAssertNotNil(status?.checkpointFailure)
        // The host was never asked to cancel anything.
        let cancels = await executor.cancelRunCalls
        XCTAssertEqual(cancels, [])
        let result = await runtime.result(runID: identity.runID)
        XCTAssertEqual(result?.terminalStatus, .failed)
    }

    /// A checkpoint write that fails DURING pause fails the run truthfully:
    /// the pause acknowledgement is the point of no return. Already-submitted
    /// work is retained for reconciliation (never cancelled, never dropped).
    func testCheckpointWriteFailureDuringPauseFailsRunAndRetainsSubmittedWork() async throws {
        let executor = TestStepExecutor()
        await executor.setHoldAll(true)
        let fixture = chainGraph()
        let identity = GraphFactory.makeIdentity()
        let runtime = FlowRuntimeService(executor: executor, journal: journal)
        let runTask = Task {
            try await runtime.startRun(
                compiled: try await runtime.compile(fixture.graph),
                configuration: GraphFactory.makeConfiguration(identity: identity))
        }
        await XCTAssertEventually({ await executor.submissionCount() == 1 })
        // Initial checkpoint succeeded; now replace the file with a directory
        // so the pause checkpoint's atomic rename fails for real.
        let checkpointURL = root.appendingPathComponent(
            "runs/\(identity.runID.uuidString)/checkpoint.json")
        try FileManager.default.removeItem(at: checkpointURL)
        try FileManager.default.createDirectory(
            at: checkpointURL, withIntermediateDirectories: false)

        await runtime.pause(runID: identity.runID)
        // Subscribe after the fact: the stream replays the retained history.
        let stream = await runtime.events(runID: identity.runID)
        let collect = Task { () -> [FlowRuntimeEvent] in
            var events: [FlowRuntimeEvent] = []
            for await event in stream {
                events.append(event)
                if case .runFinished = event { break }
            }
            return events
        }
        let status = await runtime.status(runID: identity.runID)
        XCTAssertEqual(status?.phase, .failed)
        XCTAssertNotNil(status?.checkpointFailure)
        // Exactly one submission so far and no new scheduling after the failure.
        let submissions = await executor.submissionCount()
        XCTAssertEqual(submissions, 1)
        let cancels = await executor.cancelRunCalls
        XCTAssertEqual(cancels, [])

        // The submitted attempt is retained for reconciliation: when the host
        // answers, it is adopted into the durable record even though the run
        // has already failed honestly.
        let performed = await executor.performedAttemptIDs
        try await executor.complete(
            attemptID: performed[0],
            outcome: .init(status: .succeeded, outputs: ["out": .string("ok")]))
        await runtime.externalStepDidFinish(
            runID: identity.runID, attemptID: performed[0])
        let records = await runtime.stepRecords(runID: identity.runID)
        XCTAssertTrue(records.contains {
            $0.nodeID == fixture.ext.id && $0.status == .succeeded
        })
        let statusAfter = await runtime.status(runID: identity.runID)
        XCTAssertEqual(statusAfter?.phase, .failed)

        let events = await collect.value
        XCTAssertTrue(events.contains {
            if case .checkpointFailed(let runID, _) = $0 { return runID == identity.runID }
            return false
        })
        XCTAssertTrue(events.contains {
            $0 == .runFinished(runID: identity.runID, phase: .failed)
        })
        _ = runTask
    }
}
