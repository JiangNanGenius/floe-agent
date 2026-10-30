// FloeAppTests — task-scoped Linux preparation wait ownership.
//
// Source-stage focused regressions for the shared image job's per-waiter
// leases. They run against the REAL `EnvironmentPackageJobs` attempt table,
// `CancellationToken` and `TaskRuntimePreparationCenter` — no fake downloader,
// no network and no image storage. The actual downloader/installer is not
// exercised here; the service-owned cancellation contract it observes is the
// same `CancellationToken` the job passes into its operation.
//
// Adopt into `FloeAgent/Tests/FloeAppTests/` and run with the focused
// `FloeApp.SetupDownloadOwnerHooks`-style suite command at integration.
// This file lives in the lane directory because the worker's write scope does
// not include the AppTests target/project.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
import FloeTools

@Suite("FloeApp.TaskRuntimePreparationOwnership")
@MainActor
struct TaskRuntimePreparationOwnershipTests {

    private actor TestGate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var opened = false

        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            opened = true
            let pending = waiters
            waiters = []
            for continuation in pending { continuation.resume() }
        }
    }

    private actor TestCounter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private enum TestFailure: Error {
        case timeout(String)
    }

    private func waitUntil(
        _ description: String = "condition",
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TestFailure.timeout(description)
    }

    private func isCancelled(_ result: Result<String, Error>) -> Bool {
        guard case .failure(let error) = result else { return false }
        return error is CancellationError
    }

    private func value(of result: Result<String, Error>) -> String? {
        guard case .success(let value) = result else { return nil }
        return value
    }

    private func uniqueJobID(_ tag: String) -> String {
        "linux-image:ownership-\(tag)-\(UUID().uuidString)"
    }

    // MARK: - Per-waiter leases

    @Test("Cancelling one waiter keeps the shared attempt alive for the other")
    func perWaiterCancellationKeepsJob() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueJobID("per-waiter")
        let gate = TestGate()
        let started = TestCounter()
        let tokenA = CancellationToken()
        let tokenB = CancellationToken()

        let a = Task { () -> Result<String, Error> in
            do {
                let value = try await jobs.runShared(
                    id: id, title: "shared", cancellation: tokenA, activityID: nil
                ) { _, jobToken in
                    await started.increment()
                    await gate.wait()
                    try Task.checkCancellation()
                    if jobToken.isCancelled { throw CancellationError() }
                    return "installed"
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil("first waiter registered") {
            await started.value == 1 && jobs.running.contains(id)
        }

        let b = Task { () -> Result<String, Error> in
            do {
                let value = try await jobs.runShared(
                    id: id, title: "shared", cancellation: tokenB, activityID: nil
                ) { _, jobToken in
                    // This closure must not run: B joins A's live attempt.
                    await started.increment()
                    await gate.wait()
                    if jobToken.isCancelled { throw CancellationError() }
                    return "second-operation"
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await started.value == 1, "the second caller must join, not start a second download")
        #expect(jobs.running.contains(id))

        tokenA.cancel()
        let resultA = await a.value
        #expect(isCancelled(resultA), "the cancelled waiter returns cancellation")
        #expect(jobs.running.contains(id), "one waiter leaving must not stop the shared job")

        await gate.open()
        let resultB = await b.value
        #expect(value(of: resultB) == "installed", "the remaining waiter still completes the real job")
        try await waitUntil("job terminal") { !jobs.running.contains(id) }
        #expect(await started.value == 1)
    }

    @Test("Cancelling the LAST waiter stops the shared attempt")
    func lastWaiterCancellationStopsJob() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueJobID("last-waiter")
        let started = TestCounter()
        let token = CancellationToken()

        let job = Task { () -> Result<String, Error> in
            do {
                let value = try await jobs.runShared(
                    id: id, title: "last", cancellation: token, activityID: nil
                ) { _, jobToken in
                    await started.increment()
                    while !jobToken.isCancelled {
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    throw CancellationError()
                }
                return .success(value)
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil("job started") { await started.value == 1 && jobs.running.contains(id) }

        token.cancel()
        let result = await job.value
        #expect(isCancelled(result))
        try await waitUntil("job terminal") { !jobs.running.contains(id) }
    }

    @Test("Global cancel resumes EVERY waiter and stops the attempt")
    func globalCancelResumesAllWaiters() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueJobID("global")
        let started = TestCounter()
        let tokenA = CancellationToken()
        let tokenB = CancellationToken()

        let operation: @Sendable (UUID, CancellationToken) async throws -> String = { _, jobToken in
            await started.increment()
            while !jobToken.isCancelled {
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        }
        let a = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "global", cancellation: tokenA, activityID: nil, operation: operation
                ))
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil("job started") { await started.value == 1 && jobs.running.contains(id) }
        let b = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "global", cancellation: tokenB, activityID: nil, operation: operation
                ))
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(150))

        jobs.cancelSharedJob(id: id)
        let resultA = await a.value
        let resultB = await b.value
        #expect(isCancelled(resultA), "the global cancel reaches the first waiter")
        #expect(isCancelled(resultB), "the global cancel reaches the second waiter")
        try await waitUntil("job terminal") { !jobs.running.contains(id) }
    }

    @Test("A cancelled waiter never resumes from the attempt's late success")
    func cancelledWaiterNeverReceivesLateSuccess() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueJobID("late-success")
        let gate = TestGate()
        let started = TestCounter()
        let tokenA = CancellationToken()
        let tokenB = CancellationToken()

        // The operation deliberately does NOT observe cancellation: this is
        // the late-success race (a valid atomic promotion already completed
        // before the cancel was observed). A is removed from the lease table
        // at cancel, so only B may receive the result.
        let a = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "late", cancellation: tokenA, activityID: nil
                ) { _, _ in
                    await started.increment()
                    await gate.wait()
                    return "installed"
                })
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil("job started") { await started.value == 1 }
        let b = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "late", cancellation: tokenB, activityID: nil
                ) { _, _ in
                    await started.increment()
                    await gate.wait()
                    return "second-operation"
                })
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await started.value == 1)

        tokenA.cancel()
        let resultA = await a.value
        #expect(isCancelled(resultA), "A returns cancellation before the operation finishes")

        await gate.open()
        let resultB = await b.value
        #expect(value(of: resultB) == "installed", "B still observes the real late success")
        #expect(isCancelled(resultA), "A is never revived by the late success")
        try await waitUntil("job terminal") { !jobs.running.contains(id) }
    }

    @Test("Repeated entry joins the actual same attempt and epoch")
    func repeatedEntryJoinsSameAttempt() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueJobID("join")
        let gate = TestGate()
        let started = TestCounter()
        let tokenA = CancellationToken()
        let tokenB = CancellationToken()

        let a = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "join", cancellation: tokenA, activityID: nil
                ) { _, _ in
                    await started.increment()
                    await gate.wait()
                    return "installed"
                })
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil("job started") { await started.value == 1 }
        let epoch = jobs.attemptEpoch(id: id)
        #expect(epoch != nil)

        let b = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "join", cancellation: tokenB, activityID: nil
                ) { _, _ in
                    await started.increment()
                    return "second-operation"
                })
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(jobs.attemptEpoch(id: id) == epoch, "the second entry joins the same live attempt")
        #expect(await started.value == 1)

        await gate.open()
        let resultA = await a.value
        let resultB = await b.value
        #expect(value(of: resultA) == "installed")
        #expect(value(of: resultB) == "installed")
        try await waitUntil("job terminal") { !jobs.running.contains(id) }
    }

    @Test("A view teardown leaves the resource job running; a later entry joins it")
    func viewTeardownKeepsResourceJob() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueJobID("teardown")
        let gate = TestGate()
        let started = TestCounter()
        let tokenA = CancellationToken()
        let tokenB = CancellationToken()

        let a = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "teardown", cancellation: tokenA, activityID: nil
                ) { _, jobToken in
                    await started.increment()
                    await gate.wait()
                    if jobToken.isCancelled { throw CancellationError() }
                    return "installed"
                })
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil("job started") { await started.value == 1 }
        let epoch = jobs.attemptEpoch(id: id)

        // Simulate the view/task going away without an explicit user cancel.
        a.cancel()
        let resultA = await a.value
        #expect(isCancelled(resultA), "the detached caller unwinds")
        #expect(jobs.running.contains(id), "the service-owned resource job persists")
        #expect(jobs.attemptEpoch(id: id) == epoch, "the same attempt still owns the download")

        let b = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "teardown", cancellation: tokenB, activityID: nil
                ) { _, _ in
                    await started.increment()
                    return "second-operation"
                })
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await started.value == 1, "the later entry joins the real job, never starts a second download")

        await gate.open()
        let resultB = await b.value
        #expect(value(of: resultB) == "installed")
        try await waitUntil("job terminal") { !jobs.running.contains(id) }
    }

    @Test("A retry after cancel waits for the real teardown, then starts a fresh attempt")
    func retryAfterCancelWaitsForTeardown() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueJobID("retry-after-cancel")
        let gate = TestGate()
        let started = TestCounter()
        let tokenA = CancellationToken()
        let tokenB = CancellationToken()

        let a = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "retry", cancellation: tokenA, activityID: nil
                ) { _, jobToken in
                    await started.increment()
                    // Hold the real cancellation checkpoint at the gate so the
                    // store observes a genuinely unwinding attempt.
                    await gate.wait()
                    if jobToken.isCancelled { throw CancellationError() }
                    return "first"
                })
            } catch {
                return .failure(error)
            }
        }
        try await waitUntil("old attempt started") { await started.value == 1 }
        tokenA.cancel()
        let resultA = await a.value
        #expect(isCancelled(resultA), "the old waiter returns cancellation")
        #expect(jobs.running.contains(id), "the old attempt is still unwinding")

        let b = Task { () -> Result<String, Error> in
            do {
                return .success(try await jobs.runShared(
                    id: id, title: "retry", cancellation: tokenB, activityID: nil
                ) { _, _ in
                    await started.increment()
                    return "second"
                })
            } catch {
                return .failure(error)
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(await started.value == 1, "a new entry must wait for the old teardown")

        await gate.open()
        let resultB = await b.value
        #expect(value(of: resultB) == "second", "the new attempt starts after teardown")
        #expect(await started.value == 2, "exactly one fresh operation")
        try await waitUntil("job terminal") { !jobs.running.contains(id) }
    }

    // MARK: - Activity ownership / binding

    @Test("A run's preparation activity cancels only that run's wait token")
    func activityCancellationIsRunScoped() async {
        let center = TaskRuntimePreparationCenter.shared
        let runA = UUID()
        let runB = UUID()
        let tokenA = CancellationToken()
        let tokenB = CancellationToken()
        let activityA = center.begin(
            runID: runA, imageID: "img-a", environmentID: "env-a", waitToken: tokenA
        )
        let activityB = center.begin(
            runID: runB, imageID: "img-b", environmentID: "env-b", waitToken: tokenB
        )
        #expect(activityA != nil)
        #expect(activityB != nil)
        guard let activityA, let activityB else { return }

        center.cancelAll(runID: runA)
        #expect(tokenA.isCancelled, "the task banner stops its own wait")
        #expect(!tokenB.isCancelled, "another task's wait is untouched")
        #expect(center.isCancelling(activityA.id))
        #expect(!center.isCancelling(activityB.id))

        center.end(activityA.id)
        #expect(!center.activities.contains { $0.id == activityA.id }, "end removes its exact generation")
        #expect(center.activities.contains { $0.id == activityB.id })
        center.end(activityB.id)
        #expect(!center.isCancelling(activityB.id))
    }

    @Test("Activities bind to the exact joined attempt epoch; nil run gets no banner")
    func activityBindsAttemptEpoch() async {
        let center = TaskRuntimePreparationCenter.shared
        let run = UUID()
        let token = CancellationToken()
        guard let activity = center.begin(
            runID: run, imageID: "img-bind", environmentID: "env-bind", waitToken: token
        ) else {
            Issue.record("activity was not created")
            return
        }
        let epoch = UUID()
        center.bind(activity.id, attemptEpoch: epoch)
        let bound = center.activities.first { $0.id == activity.id }
        #expect(bound?.attemptEpoch == epoch, "the banner is bound to the exact live attempt")
        #expect(bound?.runID == run)
        #expect(bound?.environmentID == "env-bind")
        center.end(activity.id)
        #expect(!center.activities.contains { $0.id == activity.id })

        let none = center.begin(
            runID: nil, imageID: "img-none", environmentID: nil, waitToken: CancellationToken()
        )
        #expect(none == nil, "settings/card callers have no task banner activity")
    }
}
#endif
