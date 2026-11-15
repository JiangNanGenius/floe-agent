// SPDX-License-Identifier: MPL-2.0
//
// G03-R4 — automatic continuation trigger. AUTHORED, NOT EXECUTED here. The
// port is a fake; every durable decision is re-proven by the run domain (the
// real path is covered by RunDomainParkedDependencyTests).
import XCTest
import Foundation
import FloePersistence
@testable import FloeAndroidCore

private actor RecordingContinuationPort: JobDependencyContinuationPort {
    struct Call: Sendable, Equatable {
        var runID: UUID
        var conversationID: UUID
    }
    private(set) var calls: [Call] = []
    var result: JobDependencyResumeResult = .resumed
    var gate: RunGateBox?

    func set(result: JobDependencyResumeResult) { self.result = result }
    func setGate(_ gate: RunGateBox?) { self.gate = gate }
    func recorded() -> [Call] { calls }

    func resumeAwaitingDependency(runID: UUID,
                                  conversationID: UUID) async -> JobDependencyResumeResult {
        calls.append(Call(runID: runID, conversationID: conversationID))
        if let gate { await gate.waitThroughCancellation() }
        return result
    }
}

private final class TestEpochBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?
    init(_ value: UInt64?) { self.value = value }
    func set(_ next: UInt64?) { lock.lock(); value = next; lock.unlock() }
    func get() -> UInt64? { lock.lock(); defer { lock.unlock() }; return value }
}

final class JobDependencyContinuationTests: XCTestCase {
    private let conversationID = UUID()
    private let runID = UUID()

    private func job(target: String = "exec.shell") -> BackgroundJob {
        BackgroundJob(conversationID: conversationID, runID: runID,
                      kind: .tool, targetTool: target,
                      payloadJSON: Data("{}".utf8))
    }

    private func makeContinuation(epoch: UInt64 = 7,
                                  port: RecordingContinuationPort)
        -> (JobDependencyContinuation, TestEpochBox) {
        let box = TestEpochBox(epoch)
        let continuation = JobDependencyContinuation(liveEpoch: { box.get() })
        return (continuation, box)
    }

    func testTerminalCallbackResumesTheExactRunOnce() async {
        let port = RecordingContinuationPort()
        let (continuation, _) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port)
        await continuation.jobTerminal(job())
        let calls = await port.recorded()
        XCTAssertEqual(calls, [.init(runID: runID,
                                    conversationID: conversationID)])
    }

    func testDuplicateCallbacksDoNotOverlapTheSameRun() async {
        let port = RecordingContinuationPort()
        let gate = RunGateBox()
        await port.setGate(gate)
        let (continuation, _) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port)
        let firstJob = job()
        let first = Task { await continuation.jobTerminal(firstJob) }
        // Wait for the REAL port entry before the duplicate.
        let entered = await waitUntil { await port.recorded().count == 1 }
        XCTAssertTrue(entered)
        await continuation.jobTerminal(job())
        let overlapped = (await port.recorded()).count
        XCTAssertEqual(overlapped, 1,
                       "the in-flight reservation must collapse a duplicate callback")
        gate.release()
        _ = await first.value
        // A later duplicate may re-ask the domain; the domain answers
        // notAwaiting/resumed idempotently. It must not be an overlapping call.
        await continuation.jobTerminal(job())
        let afterLateDuplicate = (await port.recorded()).count
        XCTAssertEqual(afterLateDuplicate, 2)
    }

    func testSecondJobCallbackReachesTheDomainForTheSameParkedRun() async {
        let port = RecordingContinuationPort()
        await port.set(result: .waiting([UUID()]))
        let (continuation, _) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port)
        await continuation.jobTerminal(job())
        await port.set(result: .resumed)
        await continuation.jobTerminal(job())
        let calls = await port.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.runID == runID })
    }

    func testStandaloneServiceTerminalNeverWakesAChatRun() async {
        let port = RecordingContinuationPort()
        let (continuation, _) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port)
        await continuation.jobTerminal(job(target: "exec.localService"))
        await continuation.jobTerminal(job(target: "exec.shell"))
        // Only the finite job asked the domain; the service did not.
        let calls = await port.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.runID, runID)
    }

    func testServiceReadinessWakesTheWaitingParent() async {
        let port = RecordingContinuationPort()
        let service = job(target: "exec.localService")
        let (continuation, _) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port,
                                   jobLookup: { id in id == service.id ? service : nil })
        await continuation.serviceReady(jobID: service.id)
        let calls = await port.recorded()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.runID, runID)
    }

    func testServiceReadinessIgnoresAFiniteJobIdentity() async {
        let port = RecordingContinuationPort()
        let finite = job()
        let (continuation, _) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port,
                                   jobLookup: { id in id == finite.id ? finite : nil })
        await continuation.serviceReady(jobID: finite.id)
        let records = await port.recorded()
        XCTAssertTrue(records.isEmpty)
    }

    func testStaleEpochCallbackIsIgnored() async {
        let port = RecordingContinuationPort()
        let (continuation, box) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port)
        box.set(8)
        await continuation.jobTerminal(job())
        box.set(nil)
        await continuation.jobTerminal(job())
        let records = await port.recorded()
        XCTAssertTrue(records.isEmpty)
    }

    func testUninstalledCoordinatorNeverResumes() async {
        let port = RecordingContinuationPort()
        let (continuation, _) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port)
        await continuation.uninstall(epoch: 7)
        await continuation.jobTerminal(job())
        let records = await port.recorded()
        XCTAssertTrue(records.isEmpty)
    }

    func testLaunchReconciliationRunsOnlySettledJobEdges() async {
        let port = RecordingContinuationPort()
        let (continuation, _) = makeContinuation(port: port)
        await continuation.install(epoch: 7, port: port)
        let readyService = JobDependencyLaunchCandidate(
            runID: runID, conversationID: conversationID,
            jobs: [.init(jobID: UUID(), dependencyKind: "service",
                         dependencyState: .resolved, jobState: .running)])
        let stoppedService = JobDependencyLaunchCandidate(
            runID: UUID(), conversationID: conversationID,
            jobs: [.init(jobID: UUID(), dependencyKind: "service",
                         dependencyState: .interrupted, jobState: .interrupted)])
        let finite = JobDependencyLaunchCandidate(
            runID: UUID(), conversationID: conversationID,
            jobs: [.init(jobID: UUID(), dependencyKind: "job",
                         dependencyState: .resolved, jobState: .completed)])
        let interruptedJob = JobDependencyLaunchCandidate(
            runID: UUID(), conversationID: UUID(),
            jobs: [.init(jobID: UUID(), dependencyKind: "job",
                         dependencyState: .interrupted, jobState: .interrupted)])
        await continuation.reconcileAtLaunch(
            [readyService, stoppedService, finite, interruptedJob])
        let calls = await port.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls.contains { $0.runID == stoppedService.runID },
                       "a stopped standalone service must not start a chat model")
        XCTAssertFalse(calls.contains { $0.runID == interruptedJob.runID },
                       "an interrupted old outcome must not auto-start a model")
    }

    private func waitUntil(timeoutSeconds: Double = 3,
                           _ condition: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }
}
