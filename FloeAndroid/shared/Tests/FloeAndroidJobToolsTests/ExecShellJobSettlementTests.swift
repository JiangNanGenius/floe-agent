// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: the durable exec.shell JOB settlement rules
// (job-a16c9976985f40b2). NOT executed by the authoring job; host-runnable
// once Main adds the `FloeAndroidJobToolsTests` target. Every assertion is
// about HONEST TERMINALIZATION: a job processor must not return (and the
// ORIGINAL service must therefore not settle a terminal state) until the
// engine proves `leaseReleased`, the trusted host gate proves whole-UID
// quiescence / the released terminal fields, or the bounded reconciliation
// ceiling throws the ORIGINAL `NativeJobSafetyFailure` (the honest
// "unsafe resource state, not a clean cancellation" path). No fixture ever
// fakes a success, and no fixture answers for an unproven state.
//
import XCTest
import Foundation
import FloeCore
import FloeTools
import FloeAndroidShellTools
@testable import FloeAndroidJobTools

/// Captures the dispatch outcome INSIDE the task body so a cancelled
/// dispatch task's successful completion is observable without relying on
/// value-rethrow subtleties (the merged shape must complete regardless).
actor DispatchResultBox {
    private var outcome: Result<ToolExecutionOutput, Error>?
    func store(_ outcome: Result<ToolExecutionOutput, Error>) { self.outcome = outcome }
    func take() -> Result<ToolExecutionOutput, Error>? { outcome }
}

final class ExecShellJobSettlementTests: XCTestCase {

    // MARK: - Retained lease: nonterminal until the engine release proof

    func testHeldLeaseIsNotTerminalizedUntilLeaseReleased() async throws {
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate() // default .unconfirmed: if the adapter
        // consulted the gate for a VISIBLE lease it would stall forever —
        // the release must come from the transport poll, and queries must
        // stay empty.
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        let releaseAt = Date().addingTimeInterval(1.2)
        transport.pollScript = { session, cursor, _ in
            if Date() >= releaseAt {
                return FakeJobShellTransport.page(session: session, cursor: cursor, text: "",
                                                  state: .terminated, released: true,
                                                  cancelled: true, stopReason: "timeout")
            }
            return FakeJobShellTransport.page(session: session, cursor: cursor, text: "")
        }
        let runID = UUID(), jobID = UUID()
        let token = CancellationToken()
        let started = Date()
        let output = try await runner.run(jobPayload(), jobContext(
            runID: runID, jobID: jobID, root: root, cancellation: token))
        let duration = Date().timeIntervalSince(started)
        XCTAssertEqual(output.exitStatus, 124)
        XCTAssertTrue(output.summary.contains("engine terminal (reconciled after local wait)"),
                      "the settled output must show the engine-truth section")
        XCTAssertTrue(output.summary.contains("leaseReleased=true"), output.summary)
        XCTAssertTrue(output.summary.contains("timeoutStop"), output.summary)
        XCTAssertGreaterThanOrEqual(duration, 1.0,
            "the processor held the job nonterminal until the release proof, "
            + "not the local wait deadline (\(duration)s)")
        XCTAssertGreaterThanOrEqual(transport.recordedCancelCount, 1,
            "the timeout handoff requested the REAL remote stop through the typed transport")
        XCTAssertEqual(gate.queryCount, 0,
            "a visible unreconciled lease is settled by the engine poll itself; "
            + "the gate is only for the start-window/post-fence truth")
        // Live-work: the processor span is over after the return.
        let live = await index.live()
        XCTAssertTrue(live.isEmpty)
    }

    func testReleasedWithoutCancelledReportsRealExitNotAFakeFailure() async throws {
        // The engine ranks truth over the local timeout intent: a released
        // lease WITHOUT `cancelled` is a real exit — here exit 0. This is
        // engine PROVEN, never a fabricated success.
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate()
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        let releaseAt = Date().addingTimeInterval(0.8)
        transport.pollScript = { session, cursor, _ in
            if Date() >= releaseAt {
                return FakeJobShellTransport.page(session: session, cursor: cursor, text: "",
                                                  state: .terminated, released: true,
                                                  cancelled: false, exit: 0)
            }
            return FakeJobShellTransport.page(session: session, cursor: cursor, text: "")
        }
        let output = try await runner.run(jobPayload(), jobContext(
            runID: UUID(), jobID: UUID(), root: root, cancellation: CancellationToken()))
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("status=reconciledExit"), output.summary)
        XCTAssertTrue(output.summary.contains("leaseReleased=true"), output.summary)
    }

    func testEngineProvenTimedOutPassesThroughWithoutDoubleAnnotation() async throws {
        // The backend proves the release inside its own bounded wait
        // (release visible from the first poll): the ORIGINAL tool output
        // already carries the engine truth and must pass through WITHOUT
        // the reconciliation re-annotation and without any gate query.
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate()
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        transport.pollScript = { session, cursor, _ in
            FakeJobShellTransport.page(session: session, cursor: cursor, text: "",
                                       state: .terminated, released: true,
                                       cancelled: true, stopReason: "timeout")
        }
        let output = try await runner.run(jobPayload(), jobContext(
            runID: UUID(), jobID: UUID(), root: root, cancellation: CancellationToken()))
        XCTAssertEqual(output.exitStatus, 124)
        XCTAssertFalse(output.summary.contains("engine terminal (reconciled after local wait)"),
                       "engine-proven timeouts already settle in the delivered backend; "
                       + "the wait extension must not re-annotate a proven terminal")
        XCTAssertEqual(gate.queryCount, 0)
    }

    // MARK: - Cancellation routes the REAL stop, not only the Task token

    func testCancelDuringExtendedWaitRoutesRealStopAndAwaitsRelease() async throws {
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate()
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        // The engine releases (with user-stop truth) only once TWO real
        // stops have been requested: the backend's timeout handoff stop and
        // the wait extension's own stop after the job cancellation arrives.
        transport.scriptReleaseAfterCancels(2, cancelled: true, stopReason: "user-stop")
        let token = CancellationToken()
        let context = jobContext(runID: UUID(), jobID: UUID(), root: root, cancellation: token)
        let runTask = Task { try await runner.run(jobPayload(), context) }
        // Let the backend hand off after its local deadline + grace (~0.35s),
        // then cancel the JOB: the extended wait must route a real stop for
        // the exact live session and keep the job nonterminal until release.
        try? await Task.sleep(nanoseconds: 450_000_000)
        token.cancel()
        let output = try await runTask.value
        XCTAssertEqual(output.exitStatus, 130, output.summary)
        XCTAssertTrue(output.summary.contains("engineTruth=userStop"), output.summary)
        XCTAssertTrue(output.summary.contains("leaseReleased=true"), output.summary)
        XCTAssertGreaterThanOrEqual(transport.recordedCancelCount, 2,
            "the wait extension routed the REAL stop for the exact session (beyond the "
            + "backend's own timeout stop)")
        let liveAfter = await index.live()
        XCTAssertTrue(liveAfter.isEmpty)
    }

    // MARK: - Uncertain-start window: REQUIRED gate answers, never assumed

    func testUncertainStartHoldsUntilGateProvesQuiescence() async throws {
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate(answers: [
            .unconfirmed(reason: "receipt still claimed"),
            .unconfirmed(reason: "stop requested, census pending"),
            .quiescent(note: "UID census proves idle; start never materialized into a lease"),
        ])
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        transport.startError = LinuxShellTransportError.waitBudgetExpired
        let output = try await runner.run(jobPayload(), jobContext(
            runID: UUID(), jobID: UUID(), root: root, cancellation: CancellationToken()))
        XCTAssertEqual(transport.recordedStartCount, 1,
            "a claimed start is NEVER replayed while unresolved")
        XCTAssertEqual(output.exitStatus, 125, "the local answer stands; quiescence is not a success")
        XCTAssertTrue(output.summary.contains("quiescent=true"), output.summary)
        let queries = gate.recordedQueries
        XCTAssertGreaterThanOrEqual(queries.count, 3)
        XCTAssertTrue(queries.allSatisfy { $0.intent == .unclassified })
        XCTAssertTrue(queries.allSatisfy { $0.lastKnownSessionID == nil })
        XCTAssertTrue(queries.allSatisfy { $0.toolCallID?.hasPrefix("jobs.") == true })
    }

    func testUncertainStartGateReleasedCarriesRealTerminal() async throws {
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate(answers: [
            .unconfirmed(reason: "preparation live"),
            .released(sessionID: "lease-1", cancelled: false, stopReason: nil,
                      exitCode: 0, termSig: nil, waitErrno: nil, workspaceStatus: "synced"),
        ])
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        transport.startError = LinuxShellTransportError.hostFenced
        let output = try await runner.run(jobPayload(), jobContext(
            runID: UUID(), jobID: UUID(), root: root, cancellation: CancellationToken()))
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("status=reconciledExit"), output.summary)
    }

    func testUncertainStartUnconfirmedUntilCeilingThrowsSafetyFailure() async throws {
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate() // .unconfirmed forever
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index,
                                                          ceiling: 0.4)
        transport.startError = LinuxShellTransportError.waitBudgetExpired
        do {
            _ = try await runner.run(jobPayload(), jobContext(
                runID: UUID(), jobID: UUID(), root: root, cancellation: CancellationToken()))
            XCTFail("an unproven claimed start must NOT terminalize into a fake answer")
        } catch let failure as NativeJobSafetyFailure {
            XCTAssertTrue(failure.isUnsafeResourceState)
            XCTAssertTrue(failure.reason.contains("reconciliation window"), failure.reason)
        }
        // The ceiling throw settles the LIVE view (the processor is done in
        // this process); lease/receipt ownership stays with the host census.
        let live = await index.live()
        XCTAssertTrue(live.isEmpty)
        XCTAssertGreaterThanOrEqual(gate.queryCount, 2)
    }

    // MARK: - Swift Task cancellation boundary (Main's merged shape)

    func testSwiftTaskCancelDuringExtendedWaitKeepsReconcilerBoundedAndSettles() async throws {
        // Pins Main's 2026-10-22 ownership merge into execute(): the
        // reconcile runs in an awaited Task.detached, so a Swift
        // Task.cancel on the dispatching task CANNOT turn the extended
        // wait into a busy-loop (in a cancelled task `Task.sleep` returns
        // immediately) nor cancel every mailbox submit — while the
        // ORIGINAL processor span and the live-work index still await
        // the real settlement. Independently verified on this host with
        // an isolated runtime probe (awaited detached completes; a
        // cancelled task whose body succeeded delivers its value).
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate()
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index,
                                                         ceiling: 5)
        let releaseAt = Date().addingTimeInterval(1.1)
        transport.pollScript = { session, cursor, _ in
            if Date() >= releaseAt {
                return FakeJobShellTransport.page(session: session, cursor: cursor, text: "",
                                                  state: .terminated, released: true,
                                                  cancelled: true, stopReason: "timeout")
            }
            return FakeJobShellTransport.page(session: session, cursor: cursor, text: "")
        }
        let jobID = UUID()
        let context = jobContext(runID: UUID(), jobID: jobID, root: root,
                                 cancellation: CancellationToken())
        let box = DispatchResultBox()
        let dispatch = Task {
            let outcome: Result<ToolExecutionOutput, Error>
            do { outcome = .success(try await runner.run(jobPayload(), context)) }
            catch { outcome = .failure(error) }
            await box.store(outcome)
        }
        // Cancel the Swift task AFTER the backend hands the lease to
        // reconciliation (~0.35s) but long BEFORE the engine release (~1.1s):
        // pre-fix this made the loop busy-spin with cancelled submits;
        // merged shape must keep bounded backoff and settle with truth.
        try? await Task.sleep(nanoseconds: 450_000_000)
        dispatch.cancel()
        _ = await dispatch.value
        let outcome = await box.take()
        switch outcome {
        case .success(let output):
            XCTAssertEqual(output.exitStatus, 124, output.summary)
            XCTAssertTrue(output.summary.contains("engine terminal (reconciled after local wait)"),
                          output.summary)
            XCTAssertTrue(output.summary.contains("leaseReleased=true"), output.summary)
        case .failure(let error):
            XCTFail("a parent Task.cancel must not leak a failure or early-terminalize: \(error)")
        case nil:
            XCTFail("the processor span must complete (the detached reconcile is awaited)")
        }
        // Bounded, NOT a busy-loop: ~0.65s of extended waiting at the
        // configured 5ms poll plus the backend's own bounded loops.
        XCTAssertLessThan(transport.recordedPollTotal, 600,
                          "cancelled-parent sleep no-op would spin far beyond this bound")
        XCTAssertGreaterThanOrEqual(transport.recordedCancelCount, 1,
                                    "the timeout handoff still requested the REAL remote stop")
        XCTAssertEqual(gate.queryCount, 0, "a visible lease is settled by the engine poll")
        let live = await index.live()
        XCTAssertTrue(live.isEmpty, "the awaited span settled the live-work index exactly once")
    }

    // MARK: - Durable progress: real facts only through the ORIGINAL channel

    func testReconcileWaitReportsRealProgressStageNotInventedPercentage() async throws {
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate(answers: [.quiescent(note: "census idle")])
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        transport.startError = LinuxShellTransportError.waitBudgetExpired
        let progress = RecordingJobProgress()
        _ = try await runner.run(jobPayload(), jobContext(
            runID: UUID(), jobID: UUID(), root: root,
            cancellation: CancellationToken(), taskProgress: progress))
        let updates = progress.recorded
        XCTAssertFalse(updates.isEmpty, "the durable progress channel must observe the reconcile phase")
        XCTAssertTrue(updates.contains { $0.phase == "engineLeaseReconcile" })
        XCTAssertTrue(updates.allSatisfy { $0.completedUnits == nil && $0.totalUnits == nil },
                      "no percentage is invented for a wait the processor cannot measure")
    }
}
