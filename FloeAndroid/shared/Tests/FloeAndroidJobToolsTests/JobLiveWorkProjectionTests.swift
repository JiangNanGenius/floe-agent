// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: the REAL-processor live-work projection
// (Core FGS lane inputs) and the ORIGINAL terminal/dependency mappings the
// job closure preserves (job-a16c9976985f40b2). Only live processor
// ownership counts: a durable "running" row after process death is not
// here — this index starts empty every launch by construction.
import XCTest
import Foundation
import FloeCore
import FloeTools
import FloePersistence
@testable import FloeAndroidJobTools

final class JobLiveWorkProjectionTests: XCTestCase {

    private func descriptor(_ name: String) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(name: name, toolDescription: "test \(name)",
                               riskLabels: [], isSideEffecting: false)
    }

    // MARK: - Index discipline

    func testBeginSettleTrackOnlyRealProcessors() async throws {
        let index = JobLiveWorkIndex()
        let job = UUID()
        let idleInitial = await index.isIdle()
        XCTAssertTrue(idleInitial)
        try await index.begin(jobID: job, targetTool: "exec.shell")
        let countOne = await index.count
        XCTAssertEqual(countOne, 1)
        let entries = await index.live()
        XCTAssertEqual(entries.first?.jobID, job)
        XCTAssertEqual(entries.first?.targetTool, "exec.shell")
        await index.settle(jobID: job)
        let idleSettled = await index.isIdle()
        XCTAssertTrue(idleSettled)
        // Idempotent settle: a late second settle is a no-op, never negative.
        await index.settle(jobID: job)
        let countZero = await index.count
        XCTAssertEqual(countZero, 0)
    }

    func testReBeginKeepsTheFirstStartAndProcessDeathStartsEmpty() async throws {
        let index = JobLiveWorkIndex()
        let job = UUID()
        try await index.begin(jobID: job, targetTool: "exec.shell")
        let first = await index.live()
        try await Task.sleep(nanoseconds: 20_000_000)
        try await index.begin(jobID: job, targetTool: "exec.shell")
        let second = await index.live()
        XCTAssertEqual(first.first?.startedAt, second.first?.startedAt,
                       "a re-begin must not look newer than the durable record claims")
        // Fresh process = fresh actor: nothing is restored from the store.
        let relaunched = JobLiveWorkIndex()
        let relaunchedIdle = await relaunched.isIdle()
        XCTAssertTrue(relaunchedIdle)
    }

    func testObserverNotifiesOnlyOnRealTransitionsAndDrainIsHonest() async throws {
        let index = JobLiveWorkIndex()
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
            var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let counter = Counter()
        await index.setObserver { count in counter.append(count) }
        let job = UUID()
        try await index.begin(jobID: job, targetTool: "web.fetch")
        _ = await jobWaitUntil { counter.all.contains(1) }
        await index.settle(jobID: job)
        _ = await jobWaitUntil { counter.all.contains(0) }
        XCTAssertEqual(counter.all.first, 1)
        XCTAssertTrue(counter.all.contains(0))
        // Bounded drain: busy index never claims drained on timeout.
        try await index.begin(jobID: UUID(), targetTool: "exec.shell")
        let drained = await index.waitForIdle(timeoutMillis: 80)
        XCTAssertFalse(drained)
        // Empty index answers drained immediately.
        let other = JobLiveWorkIndex()
        let fast = await other.waitForIdle(timeoutMillis: 0)
        XCTAssertTrue(fast)
    }

    // MARK: - Tracking wrapper around the ORIGINAL runner

    func testTrackedRunnerCountsExactlyTheDispatchSpanAndSettlesOnThrow() async throws {
        let index = JobLiveWorkIndex()
        let started = AsyncSemaphore()
        let release = AsyncSemaphore()
        let inner = AnyAgentTool(descriptor: descriptor("web.fetch"),
                                 run: { _, context in
            XCTAssertEqual(context.toolCallID?.hasPrefix("jobs."), true)
            started.signal()
            try await release.wait()
            return ToolExecutionOutput(digesting: "done", exitStatus: 0)
        })
        let tracked = makeJobTrackedRunner(inner: inner, index: index)
        let job = UUID()
        let context = ToolContext(runID: UUID(), toolCallID: "jobs.\(job.uuidString)",
                                  scope: .local, allowedWorkspacePaths: [],
                                  cancellation: CancellationToken())
        let task = Task { try await tracked.run(Data("{}".utf8), context) }
        try await started.wait()
        let liveDuringDispatch = await index.count
        XCTAssertEqual(liveDuringDispatch, 1, "live processor counted DURING the dispatch")
        release.signal()
        _ = try? await task.value
        let liveAfterReturn = await index.live()
        XCTAssertTrue(liveAfterReturn.isEmpty, "settle ran on the real return")

        // A throwing processor also settles (the live view must not leak),
        // and the error propagates UNCHANGED (the wrapper never absorbs it).
        let boom = AnyAgentTool(descriptor: descriptor("web.fetch"), run: { _, _ in
            throw FloeError.validationFailed("boom")
        })
        let trackedBoom = makeJobTrackedRunner(inner: boom, index: index)
        let keep = UUID()
        try await index.begin(jobID: keep, targetTool: "exec.shell") // a distinct live entry
        do {
            _ = try await trackedBoom.run(Data("{}".utf8), context)
            XCTFail("expected the inner failure to propagate unchanged")
        } catch let error as FloeError {
            XCTAssertEqual(error, .validationFailed("boom"))
        }
        let survivingCount = await index.count
        XCTAssertEqual(survivingCount, 1,
                       "only the boom job's own entry was removed; unrelated live work stands")
        await index.settle(jobID: keep)
        let finalCount = await index.count
        XCTAssertEqual(finalCount, 0)
    }

    func testNonJobCallIdsAreNeverGuessedIntoTheLiveView() async throws {
        let index = JobLiveWorkIndex()
        let inner = AnyAgentTool(descriptor: descriptor("web.fetch"), run: { _, _ in
            ToolExecutionOutput(digesting: "ok", exitStatus: 0)
        })
        let tracked = makeJobTrackedRunner(inner: inner, index: index)
        for callID in ["call-1", "shell.open:whatever", "jobs.not-a-uuid", nil] {
            let context = ToolContext(runID: UUID(), toolCallID: callID, scope: .local,
                                      allowedWorkspacePaths: [], cancellation: CancellationToken())
            _ = try await tracked.run(Data("{}".utf8), context)
        }
        let untrackedIdle = await index.isIdle()
        XCTAssertTrue(untrackedIdle,
                      "a context that is not the exact jobs.<uuid> shape is never tracked")
    }

    // MARK: - ORIGINAL terminal/dependency mappings preserved through the port

    func testDependencyStateMappingIsTheOriginalOne() {
        XCTAssertEqual(BackgroundJobService.dependencyState(for: .completed), .resolved)
        XCTAssertEqual(BackgroundJobService.dependencyState(for: .failed), .failed)
        XCTAssertEqual(BackgroundJobService.dependencyState(for: .cancelled), .cancelled)
        XCTAssertEqual(BackgroundJobService.dependencyState(for: .interrupted), .interrupted)
        XCTAssertEqual(BackgroundJobService.dependencyState(for: .queued), .pending)
        XCTAssertEqual(BackgroundJobService.dependencyState(for: .running), .pending)
    }

    func testJobProcessorIdentityParsing() {
        let id = UUID()
        XCTAssertEqual(JobProcessorIdentity.jobID(fromToolCallID: "jobs.\(id.uuidString)"), id)
        XCTAssertNil(JobProcessorIdentity.jobID(fromToolCallID: "call-1"))
        XCTAssertNil(JobProcessorIdentity.jobID(fromToolCallID: nil))
        XCTAssertNil(JobProcessorIdentity.jobID(fromToolCallID: "jobs.garbage"))
    }

    func testTextLimitsBoundWithoutHidingIdentifiers() {
        let long = String(repeating: "x", count: 5_000)
        let bounded = NativeJobTextLimits.bounded(long)
        XCTAssertLessThan(bounded.count, 5_000)
        XCTAssertTrue(bounded.contains("truncated"))
        XCTAssertEqual(NativeJobTextLimits.bounded("short"), "short")
    }
}

/// Tiny test-only semaphore (structured waits without polling races).
final class AsyncSemaphore: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var signals = 0
    func wait() async throws {
        // NSLock may not be touched lexically inside an async function
        // (Swift 6 noasync-locking): every critical section lives in a
        // synchronous helper below.
        if takeSignalLocked() { return }
        await withCheckedContinuation { continuation in enqueueLocked(continuation) }
    }
    func signal() {
        releaseOrHoldLocked()
    }

    private func takeSignalLocked() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if signals > 0 { signals -= 1; return true }
        return false
    }
    private func enqueueLocked(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock(); waiters.append(continuation); lock.unlock()
    }
    private func releaseOrHoldLocked() {
        lock.lock()
        if !waiters.isEmpty {
            let waiting = waiters.removeFirst()
            lock.unlock()
            waiting.resume()
        } else {
            signals += 1
            lock.unlock()
        }
    }
}
