// FloeAppTests — Setup download owner hooks (source stage; NOT yet compiled or run).
//
// Deterministic focused regressions for the two owner-service hooks the
// non-blocking setup plan requires. Everything runs against the REAL owner
// gates — the production `LinuxGuestImageJobProgress` epoch/sequence gate and
// the shared `SpeedEstimator` window — with no network, no downloader and no
// whole-suite dependency.
//
// Hook 1 (Linux image byte/rate publication):
//   * epoch fencing, same-phase sequence regression dropped, late reports
//     after the terminal transition ignored, new attempt starts clean;
//   * unknown total keeps `totalBytes == nil`, publishes the real counter and
//     never invents a fraction;
//   * the rate baseline is the first sample (no speed from one point), a full
//     window of REAL growth measures the exact bytes/second, a duplicate or
//     reordered sample can never regress the counter or move the rate;
//   * only the live `.downloading` phase publishes; a phase change or a
//     non-download phase clears the snapshot; the counter re-baselines when
//     the asset scale changes;
//   * cancellation drops the snapshot immediately and in-flight samples of
//     the cancelled attempt cannot repopulate it; the note is BOUND to the
//     attempt epoch, so a cancelled attempt's delayed note arriving while a
//     NEWER attempt is live is dropped whole and never suppresses it;
//     suppression ends with the attempt.
//
// Hook 2 (per-content install/cancel ownership):
//   * one live transaction per content id, second caller joins it;
//   * cancellation before the fence aborts without promoting;
//   * an atomic promotion completed despite the cancel reports the installed
//     truth (`promoted`), not a fake cancellation;
//   * per-id failure vs normal cancellation are distinct; retry clears
//     exactly that id's old error; a new attempt owns only its own id;
//   * cancelling a DIFFERENT id touches nothing;
//   * the awaiting caller's own teardown never cancels the service task;
//   * legacy no-feed failure still records real blocked truth;
//   * a tail failure or a late cancel AFTER the atomic promotion keeps the
//     promotion receipt truthful while the real error stays visible.
//
// Not covered here (disclosed, cannot run offline): the signed-feed fetch
// inside `commitEntries` (real hub bytes require signature verification) —
// the fences/phases it adds are the same fence primitives exercised through
// the fake transaction operations below.

#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
import FloeExecution
import FloeSkills

@Suite("FloeApp.SetupDownloadOwnerHooks")
@MainActor
struct SetupDownloadOwnerHooksTests {

    // MARK: - Hook 1 helpers

    /// Renders one published snapshot deterministically for trace asserts.
    /// A missing total renders explicitly as `t-nil` (dash-prefixed) so it can
    /// never be confused with a real byte total.
    private static func render(_ snapshot: LinuxImageTransferSnapshot?) -> String {
        guard let snapshot else { return "nil" }
        let total = snapshot.totalBytes.map(String.init) ?? "-nil"
        return "r\(snapshot.receivedBytes),t\(total),b\(snapshot.bytesPerSecond)"
    }

    @MainActor
    private static func trace(_ lines: [String]) -> String { lines.joined(separator: ";") }

    private func uniqueImageJobID(_ tag: String) -> String {
        "linux-image:\(tag)-\(UUID().uuidString)"
    }

    // MARK: - Hook 1: Linux image byte/rate publication

    @Test("Unknown total publishes the real counter, no fabricated total, fraction or rate")
    func unknownTotalRealBytes() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueImageJobID("unknown")
        let trace = try await jobs.runShared(id: id, title: "trace") { epoch in
            await MainActor.run {
                var lines: [String] = []
                jobs.reportBytes(id: id, epoch: epoch, sequence: 1, phase: .downloading,
                                 received: 500, expected: -1, now: 1_000)
                lines.append("down:\(Self.render(jobs.transfers[id]))")
                // The fraction channel is unchanged: unknown total => none.
                lines.append("fraction:\(jobs.fractions[id].map(String.init) ?? "nil")")
                jobs.reportBytes(id: id, epoch: epoch, sequence: 2, phase: .downloading,
                                 received: 900, expected: -1, now: 1_001)
                lines.append("grown:\(Self.render(jobs.transfers[id]))")
                return Self.trace(lines)
            }
        }
        #expect(trace == "down:r500,t-nil,b0;fraction:nil;grown:r900,t-nil,b400",
                "unknown totals publish real bytes only: the first sample is baseline (no rate), then a full window of REAL growth measures exactly 400 B/s — never a rate derived from a fraction or cached count")
        // Terminal transition clears everything.
        #expect(jobs.transfers[id] == nil)
        #expect(jobs.fractions[id] == nil)
        #expect(!jobs.running.contains(id))
    }

    @Test("Rate baseline is the first sample; a full real-growth window measures the exact speed")
    func rateBaselineThenMeasuredWindow() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueImageJobID("rate")
        let trace = try await jobs.runShared(id: id, title: "trace") { epoch in
            await MainActor.run {
                var lines: [String] = []
                // First sample: baseline only — no speed can come from one point.
                jobs.reportBytes(id: id, epoch: epoch, sequence: 1, phase: .downloading,
                                 received: 100_000_000, expected: 1_000_000_000, now: 1_000)
                lines.append("baseline:\(Self.render(jobs.transfers[id]))")
                // 30 MB of real growth over 0.6 s == 50 MB/s exactly.
                jobs.reportBytes(id: id, epoch: epoch, sequence: 2, phase: .downloading,
                                 received: 130_000_000, expected: 1_000_000_000, now: 1_000.6)
                lines.append("window:\(Self.render(jobs.transfers[id]))")
                // The fraction channel behaves exactly as the stamped progress API.
                lines.append("fraction:\(jobs.fractions[id].map(String.init) ?? "nil")")
                return Self.trace(lines)
            }
        }
        #expect(trace.contains("baseline:r100000000,t1000000000,b0"),
                "the first sample must not manufacture a rate")
        #expect(trace.contains("window:r130000000,t1000000000,b50000000"),
                "the rate is measured from real cumulative growth over the estimator window")
        #expect(trace.contains("fraction:0.13"), "known totals still drive the existing fraction channel")
    }

    @Test("Duplicate and reordered same-phase samples cannot regress the counter or move the rate")
    func monotonicCounterUnderReordering() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueImageJobID("mono")
        let trace = try await jobs.runShared(id: id, title: "trace") { epoch in
            await MainActor.run {
                var lines: [String] = []
                jobs.reportBytes(id: id, epoch: epoch, sequence: 1, phase: .downloading,
                                 received: 100_000_000, expected: 1_000_000_000, now: 1_000)
                jobs.reportBytes(id: id, epoch: epoch, sequence: 2, phase: .downloading,
                                 received: 130_000_000, expected: 1_000_000_000, now: 1_000.6)
                // A delayed hop of an older sample (same phase, same total):
                // the published counter holds its high-water value.
                jobs.reportBytes(id: id, epoch: epoch, sequence: 3, phase: .downloading,
                                 received: 110_000_000, expected: 1_000_000_000, now: 1_000.7)
                lines.append("clamped:\(Self.render(jobs.transfers[id]))")
                // A repeated final sample is not new network progress either.
                jobs.reportBytes(id: id, epoch: epoch, sequence: 4, phase: .downloading,
                                 received: 130_000_000, expected: 1_000_000_000, now: 1_000.8)
                lines.append("repeat:\(Self.render(jobs.transfers[id]))")
                return Self.trace(lines)
            }
        }
        #expect(trace.contains("clamped:r130000000,t1000000000,b50000000"))
        #expect(trace.contains("repeat:r130000000,t1000000000,b50000000"))
    }

    @Test("Only the live downloading phase publishes; phase changes clear and re-baseline")
    func phaseRules() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueImageJobID("phase")
        let trace = try await jobs.runShared(id: id, title: "trace") { epoch in
            await MainActor.run {
                var lines: [String] = []
                jobs.reportBytes(id: id, epoch: epoch, sequence: 1, phase: .downloading,
                                 received: 400_000_000, expected: 1_000_000_000, now: 1_000)
                lines.append("down:\(Self.render(jobs.transfers[id]))")
                // A phase change clears both the fraction and the byte truth.
                jobs.reportPhase(id: id, epoch: epoch, sequence: 2, phase: .verifyingArchive)
                lines.append("cleared:\(jobs.transfers[id] == nil ? "nil" : "leaked")")
                lines.append("fraction:\(jobs.fractions[id] == nil ? "nil" : "leaked")")
                // Hashing bytes are real but NOT a download: no snapshot, no rate.
                jobs.reportBytes(id: id, epoch: epoch, sequence: 3, phase: .verifyingArchive,
                                 received: 100_000_000, expected: 100_000_000, now: 1_000.4)
                lines.append("verify:\(jobs.transfers[id] == nil ? "nil" : "leaked")")
                // Back to downloading (mirror retry): new scale, new baseline.
                jobs.reportBytes(id: id, epoch: epoch, sequence: 4, phase: .downloading,
                                 received: 60_000_000, expected: 120_000_000, now: 1_000.8)
                lines.append("redownload:\(Self.render(jobs.transfers[id]))")
                return Self.trace(lines)
            }
        }
        #expect(trace.contains("down:r400000000,t1000000000,b0"))
        #expect(trace.contains("cleared:nil"))
        #expect(trace.contains("fraction:nil"))
        #expect(trace.contains("verify:nil"))
        #expect(trace.contains("redownload:r60000000,t120000000,b0"),
                "re-entering download starts a fresh counter/rate baseline; no stale high-water leaks across the boundary")
    }

    @Test("Epoch and order fencing: wrong epoch, regressed sequence and post-terminal reports are dropped")
    func epochAndOrderFencing() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueImageJobID("fence")
        let alienEpoch = UUID()
        let payload = try await jobs.runShared(id: id, title: "trace") { epoch in
            await MainActor.run {
                var lines: [String] = []
                jobs.reportBytes(id: id, epoch: alienEpoch, sequence: 99, phase: .downloading,
                                 received: 700_000_000, expected: 1_000_000_000, now: 1_000)
                lines.append("alien:\(jobs.transfers[id] == nil ? "nil" : "leaked")")
                jobs.reportBytes(id: id, epoch: epoch, sequence: 5, phase: .downloading,
                                 received: 100_000_000, expected: 1_000_000_000, now: 1_000)
                // Same epoch, OLDER sequence: a reordered hop of a previous
                // state must not move the published truth at all.
                jobs.reportBytes(id: id, epoch: epoch, sequence: 4, phase: .downloading,
                                 received: 20_000_000, expected: 1_000_000_000, now: 1_001)
                lines.append("staleSeq:\(Self.render(jobs.transfers[id]))")
                // Return the attempt's real epoch out-of-band (no mutable
                // capture crosses the task boundary).
                return "epoch:\(epoch.uuidString)|" + Self.trace(lines)
            }
        }
        let pieces = payload.split(separator: "|", maxSplits: 1)
        let firstAttemptEpoch = UUID(uuidString: String(pieces[0].dropFirst("epoch:".count)))
        #expect(firstAttemptEpoch != nil)
        #expect(String(pieces[1]) == "alien:nil;staleSeq:r100000000,t1000000000,b0")
        // The attempt ended; a late MainActor hop from THAT attempt is gone.
        if let firstAttemptEpoch {
            jobs.reportBytes(id: id, epoch: firstAttemptEpoch, sequence: 50, phase: .downloading,
                             received: 900_000_000, expected: 1_000_000_000, now: 1_002)
            #expect(jobs.transfers[id] == nil, "finished jobs never resurrect a byte snapshot")

            // A new attempt starts clean and lifts the previous attempt's rules.
            let trace2 = try await jobs.runShared(id: id, title: "retry") { epoch in
                await MainActor.run {
                    var lines: [String] = []
                    lines.append("fresh:\(jobs.transfers[id] == nil ? "nil" : "leaked")")
                    jobs.reportBytes(id: id, epoch: epoch, sequence: 1, phase: .downloading,
                                     received: 10_000_000, expected: 1_000_000_000, now: 1_003)
                    lines.append("new:\(Self.render(jobs.transfers[id]))")
                    // The old epoch cannot touch the new attempt either.
                    jobs.reportBytes(id: id, epoch: firstAttemptEpoch, sequence: 99, phase: .downloading,
                                     received: 800_000_000, expected: 1_000_000_000, now: 1_004)
                    lines.append("oldEpoch:\(Self.render(jobs.transfers[id]))")
                    return Self.trace(lines)
                }
            }
            #expect(trace2 == "fresh:nil;new:r10000000,t1000000000,b0;oldEpoch:r10000000,t1000000000,b0")
        }
    }

    @Test("Cancellation drops the snapshot immediately; in-flight samples of the cancelled attempt cannot repopulate")
    func cancellationSuppressesBytes() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueImageJobID("cancel")
        let trace = try await jobs.runShared(id: id, title: "trace") { epoch in
            await MainActor.run {
                var lines: [String] = []
                jobs.reportBytes(id: id, epoch: epoch, sequence: 1, phase: .downloading,
                                 received: 100_000_000, expected: 1_000_000_000, now: 1_000)
                lines.append("live:\(Self.render(jobs.transfers[id]))")
                jobs.noteCancellation(id: id, epoch: epoch)
                lines.append("cancelled:\(jobs.transfers[id] == nil ? "nil" : "leaked")")
                // The transfer is still unwinding and delivers one more real
                // sample of the SAME download attempt: the rate/speed row
                // stays dropped (fractions keep their existing behaviour).
                jobs.reportBytes(id: id, epoch: epoch, sequence: 2, phase: .downloading,
                                 received: 140_000_000, expected: 1_000_000_000, now: 1_000.6)
                lines.append("inflight:\(jobs.transfers[id] == nil ? "nil" : "leaked")")
                lines.append("fractionStillReal:\(jobs.fractions[id] == nil ? "gone" : "kept")")
                return Self.trace(lines)
            }
        }
        #expect(trace == "live:r100000000,t1000000000,b0;cancelled:nil;inflight:nil;fractionStillReal:kept")
        // Suppression ends with the attempt: a new job publishes again normally.
        let trace2 = try await jobs.runShared(id: id, title: "retry") { epoch in
            await MainActor.run {
                jobs.reportBytes(id: id, epoch: epoch, sequence: 1, phase: .downloading,
                                 received: 5_000_000, expected: 1_000_000_000, now: 1_005)
                return Self.render(jobs.transfers[id])
            }
        }
        #expect(trace2 == "r5000000,t1000000000,b0")
    }

    @Test("A cancelled attempt's DELAYED note can never suppress a newer attempt (cancel → new-attempt race)")
    func lateCancelNoteCannotSuppressNewAttempt() async throws {
        let jobs = EnvironmentPackageJobs.shared
        let id = uniqueImageJobID("late-note")
        // Attempt A: publish bytes, then record its cancellation note with
        // the correct epoch. The note is accepted for THIS attempt.
        let payloadA = try await jobs.runShared(id: id, title: "A") { epochA in
            await MainActor.run {
                jobs.reportBytes(id: id, epoch: epochA, sequence: 1, phase: .downloading,
                                 received: 100, expected: 1_000, now: 1_000)
                jobs.noteCancellation(id: id, epoch: epochA)
                let cleared = jobs.transfers[id] == nil
                return "\(epochA.uuidString)|\(cleared ? "cleared" : "leaked")"
            }
        }
        let staleEpoch = UUID(uuidString: String(payloadA.split(separator: "|").first ?? ""))
        #expect(staleEpoch != nil)
        #expect(payloadA.hasSuffix("|cleared"), "the live note drops the cancelled attempt's snapshot")
        guard let staleEpoch else { return }

        // Attempt B is LIVE when A's cancellation note would finally arrive
        // (the delayed main-actor hop): the stale note must be dropped whole,
        // and B's byte truth must keep flowing under its own epoch.
        let traceB = try await jobs.runShared(id: id, title: "B") { epochB in
            await MainActor.run {
                var lines: [String] = []
                jobs.reportBytes(id: id, epoch: epochB, sequence: 1, phase: .downloading,
                                 received: 50, expected: 1_000, now: 1_001)
                lines.append("before:\(Self.render(jobs.transfers[id]))")
                jobs.noteCancellation(id: id, epoch: staleEpoch)
                jobs.reportBytes(id: id, epoch: epochB, sequence: 2, phase: .downloading,
                                 received: 110, expected: 1_000, now: 1_001.6)
                lines.append("after:\(Self.render(jobs.transfers[id]))")
                return Self.trace(lines)
            }
        }
        #expect(traceB == "before:r50,t1000,b0;after:r110,t1000,b100",
                "the old attempt's note never suppresses the newer attempt's bytes or rate")
    }

    // MARK: - Hook 2 helpers

    /// Deterministic one-way gate for fake transactions.
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

    private actor TestBox {
        private(set) var transactionsStarted = 0
        private(set) var reachedAfterFence = false
        func startTransaction() { transactionsStarted += 1 }
        func markReached() { reachedAfterFence = true }
        var started: Int { transactionsStarted }
        var reached: Bool { reachedAfterFence }
    }

    private func makeCenter() -> ContentUpdateCenter {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-owner-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return ContentUpdateCenter.forImmutableCommit(
            String(repeating: "a", count: 40),
            root: root
        ) { _, _, _, _ in Data() }
    }

    private func waitForInstalling(_ center: ContentUpdateCenter, _ id: String) async throws {
        var waited = 0
        while !center.installingIDs.contains(id) {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
            if waited > 500 { throw TestFailure(detail: "install attempt for \(id) never registered") }
        }
    }

    private enum TestFailure: Error { case detail(String) }

    // MARK: - Hook 2: per-entry install ownership

    @Test("Multiple callers coalesce into ONE live transaction per content id")
    func coalescingSingleLiveTransaction() async throws {
        let center = makeCenter()
        let id = "floe.test.coalesce"
        let gate = TestGate()
        let box = TestBox()
        let first = Task {
            await center.performAttempt(id: id) { _ in
                await box.startTransaction()
                await gate.wait()
            }
        }
        try await waitForInstalling(center, id)
        let firstToken = center.installStates[id]?.attempt
        // The second caller joins the live attempt; its own operation never
        // runs (and if the join contract were broken, a NEW token plus a
        // second `startTransaction` would fail this test).
        let second = Task {
            await center.performAttempt(id: id) { _ in
                await box.startTransaction()
            }
        }
        try await Task.sleep(for: .milliseconds(60))
        #expect(center.installStates[id]?.attempt == firstToken,
                "the second caller must join the SAME live attempt, never create a second one")
        await gate.open()
        let joined = await second.value
        _ = await first.value
        let state = center.installStates[id]
        #expect(await box.started == 1, "a second download for the same id must never start")
        #expect(state?.running == false)
        #expect(state?.promoted == true, "the joined caller observes the real completion")
        #expect(state?.failure == nil)
        #expect(state?.wasCancelled == false)
        #expect(center.installingIDs.isEmpty)
        #expect(joined?.attempt == firstToken)
    }

    @Test("Cancel before the pre-commit fence: the job ends as a normal cancellation with no promotion")
    func cancelBeforeFenceNeverPromotes() async throws {
        let center = makeCenter()
        let id = "floe.test.cancel-fence"
        let gate = TestGate()
        let box = TestBox()
        let runner = Task {
            await center.performAttempt(id: id) { _ in
                await gate.wait()
                // The exact fence commitEntries keeps before store.commit.
                try Task.checkCancellation()
                await box.markReached()
            }
        }
        try await waitForInstalling(center, id)
        center.cancelInstall(id)
        #expect(center.installStates[id]?.cancelling == true, "cancel feedback is immediate")
        #expect(center.installStates[id]?.running == true, "the service task is still unwinding")
        await gate.open()
        _ = await runner.value
        let state = center.installStates[id]
        #expect(await box.reached == false, "the fence stopped the transaction before promotion")
        #expect(state?.running == false)
        #expect(state?.wasCancelled == true)
        #expect(state?.cancelling == false)
        #expect(state?.failure == nil, "a normal cancellation is not an error")
        #expect(state?.promoted == false)
        #expect(center.errorMessage == nil, "cancellation never pollutes the global error")
        #expect(center.installingIDs.isEmpty)
        // A follow-up cancel of the finished job is a clean no-op (no live task).
        center.cancelInstall(id)
        #expect(center.installStates[id]?.wasCancelled == true)
    }

    @Test("Atomic promotion completed despite cancel reports the real installed truth")
    func promotionAfterCancelReportsInstalledTruth() async throws {
        let center = makeCenter()
        let id = "floe.test.late-success"
        let gate = TestGate()
        let box = TestBox()
        let runner = Task {
            await center.performAttempt(id: id) { _ in
                await gate.wait()
                // Past the last fence: the store transaction is already
                // running; nothing here observes cancellation (mirrors the
                // post-commit section of commitEntries).
                await box.markReached()
            }
        }
        try await waitForInstalling(center, id)
        center.cancelInstall(id)
        await gate.open()
        _ = await runner.value
        let state = center.installStates[id]
        #expect(await box.reached == true, "the promotion completed")
        #expect(state?.promoted == true, "installed truth wins over the stale cancel request")
        #expect(state?.wasCancelled == false)
        #expect(state?.failure == nil)
        #expect(state?.cancelling == false)
        #expect(center.installingIDs.isEmpty)
    }

    @Test("A tail failure AFTER the atomic promotion keeps the installed receipt truthful")
    func postPromotionTailFailureKeepsInstalledTruth() async throws {
        let center = makeCenter()
        let id = "floe.test.tail-truth"
        let boom = ContentUpdateStoreError.persistence("refresh failed")
        _ = await center.performAttempt(id: id) { attempt in
            // Mirrors commitEntries: the store transaction returned, the
            // receipt is recorded, THEN the mirroring/refresh tail fails.
            center.recordPromotion(attempt)
            throw boom
        }
        let state = center.installStates[id]
        #expect(state?.promoted == true, "the promotion receipt survives the later failure")
        #expect(state?.wasCancelled == false)
        #expect(state?.cancelling == false)
        #expect(state?.failure == ContentUpdateCenter.describe(boom), "the real error stays visible")
        #expect(center.errorMessage == state?.failure)
        #expect(center.installingIDs.isEmpty)
    }

    @Test("A cancel arriving during the post-promotion tail never overwrites the promotion truth")
    func cancelDoesNotOverwritePromotionTruth() async throws {
        let center = makeCenter()
        let id = "floe.test.cancel-after-promotion"
        let gate = TestGate()
        let boom = ContentUpdateStoreError.persistence("refresh failed")
        let runner = Task {
            await center.performAttempt(id: id) { attempt in
                center.recordPromotion(attempt)
                await gate.wait()
                // Tail error after the receipt, with a cancel request in the
                // meantime: both the promotion AND the error are real.
                throw boom
            }
        }
        try await waitForInstalling(center, id)
        center.cancelInstall(id)
        await gate.open()
        _ = await runner.value
        let state = center.installStates[id]
        #expect(state?.promoted == true, "installed truth beats a too-late cancellation")
        #expect(state?.wasCancelled == false, "a completed promotion is never a fake cancellation")
        #expect(state?.cancelling == false)
        #expect(state?.failure == ContentUpdateCenter.describe(boom))
        #expect(center.installingIDs.isEmpty)
    }

    @Test("Per-id failure truth: retry clears exactly the matching old error; other ids keep theirs")
    func perIDFailureAndRetryClearsMatchingError() async throws {
        let center = makeCenter()
        let idA = "floe.test.retry-a"
        let idB = "floe.test.retry-b"
        let boom = ContentUpdateStoreError.conflict("boom")
        _ = await center.performAttempt(id: idA) { _ in throw boom }
        let failedA = center.installStates[idA]
        #expect(failedA?.running == false)
        #expect(failedA?.failure == ContentUpdateCenter.describe(boom))
        #expect(failedA?.wasCancelled == false)
        #expect(center.errorMessage == ContentUpdateCenter.describe(boom),
                "legacy global error stays populated for existing views")

        _ = await center.performAttempt(id: idB) { _ in }
        #expect(center.installStates[idB]?.promoted == true)
        #expect(center.installStates[idB]?.failure == nil)
        // The other id's real failure is untouched by an unrelated success.
        #expect(center.installStates[idA]?.failure == ContentUpdateCenter.describe(boom))

        // Retry clears the matching old error and starts a distinct attempt.
        _ = await center.performAttempt(id: idA) { _ in }
        let retriedA = center.installStates[idA]
        #expect(retriedA?.failure == nil, "a new attempt replaces that id's stale error")
        #expect(retriedA?.promoted == true)
        #expect(retriedA?.attempt != failedA?.attempt, "the new attempt owns its own token")
        #expect(center.installingIDs.isEmpty)
    }

    @Test("Cancel targets exactly one job; another id's live transaction is untouched")
    func cancelIsScopedToItsJob() async throws {
        let center = makeCenter()
        let idA = "floe.test.scope-a"
        let idB = "floe.test.scope-b"
        let gate = TestGate()
        let runner = Task {
            await center.performAttempt(id: idA) { _ in await gate.wait() }
        }
        try await waitForInstalling(center, idA)
        center.cancelInstall(idB)
        #expect(center.installStates[idA]?.cancelling == false, "only id A's job exists; B's cancel is a no-op")
        #expect(center.installStates[idB] == nil, "cancelling an unknown id never creates phantom state")
        await gate.open()
        _ = await runner.value
        #expect(center.installStates[idA]?.promoted == true)
        #expect(center.installStates[idA]?.wasCancelled == false)
    }

    @Test("The awaiting caller's teardown never cancels the service-owned transaction")
    func uiTeardownDoesNotCancel() async throws {
        let center = makeCenter()
        let id = "floe.test.teardown"
        let gate = TestGate()
        let box = TestBox()
        let caller = Task {
            await center.performAttempt(id: id) { _ in
                await gate.wait()
                try Task.checkCancellation()
                await box.markReached()
            }
        }
        try await waitForInstalling(center, id)
        caller.cancel()  // navigation teardown: the VIEW task dies, the job does not.
        await gate.open()
        _ = await caller.value
        #expect(await box.reached == true, "the service task completed despite the caller being cancelled")
        let state = center.installStates[id]
        #expect(state?.promoted == true)
        #expect(state?.wasCancelled == false)
        #expect(state?.cancelling == false)
        #expect(center.errorMessage == nil)
    }

    @Test("Legacy install and non-blocking begin without a verified feed record real blocked truth")
    func blockedFeedRecordsTruthNotPhantomRunning() async {
        let center = makeCenter()
        let legacyID = "floe.test.legacy-nofeed"
        await center.install(legacyID)
        let legacy = center.installStates[legacyID]
        #expect(legacy?.running == false, "never a phantom running task")
        #expect(legacy?.failure != nil, "the real reason (no verified feed) is recorded per id")
        #expect(center.errorMessage == legacy?.failure,
                "the legacy global-error contract is preserved and carries the same truth")
        #expect(center.installingIDs.isEmpty)

        // beginInstall for a DIFFERENT id is per-id and does not clear or
        // overwrite another id's recorded failure.
        await center.beginInstall("floe.test.begin-nofeed")
        #expect(center.installStates[legacyID]?.failure == legacy?.failure)
        #expect(center.installStates["floe.test.begin-nofeed"]?.failure != nil)
    }
}
#endif
