// Focused regression for WhisperDownloadCoordinator's migration to the
// shared FloeCore background settlement primitive. These drive the REAL
// entry points — `registerBackgroundCompletion`, the actual URLSession
// delegate callbacks, `cancelAndRemovePendingTransfer`, the `download`
// ledger seam exactly as `install()` uses it (create ledger → pass to
// download → drain once at the operation tail), and the real primitive
// behind `WhisperDownloadCoordinator.settlement` — instead of duplicating
// the drain:
//   • the launch bootstrap is registered BEFORE the stored handler, so a
//     late handler cannot fire immediately past the pending bootstrap lease;
//   • an underway transfer settle holds the NEXT wake until the install
//     tail drains it (the premature-OS-completion bug);
//   • failed and retired transfers settle through the same pairing;
//   • a stale duplicate finish cannot pre-satisfy the next wake;
//   • a resume after the operation tail cannot strand a future wake;
//   • every wake releases exactly once, on main.
//
// Ledger state is test-owned per scenario (the production code path is
// identical: `install()` creates its ledger and drains it in a `defer`),
// so the coordinator singleton is only touched through its real entries.
// The suite is `.serialized`: the coordinator is a process-wide singleton
// with one settlement, so the wake sequence is asserted end-to-end in one
// deterministic order.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(UIKit)
import Foundation
import CryptoKit
import Testing
// `settlementStateForTesting` is internal to FloeCore; @testable is
// required to read the primitive's diagnostics tuple.
@testable import FloeCore
import FloeLocalModelCatalog
@testable import FloeApp

private final class FireTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var firedCount = 0
    private var mainThread = false
    var count: Int { lock.withLock { firedCount } }
    var onMain: Bool { lock.withLock { mainThread } }
    func record() { lock.withLock { firedCount += 1; mainThread = Thread.isMainThread } }
}

private struct SettleTimeout: Error {}

private func settleWait(
    _ predicate: @escaping @Sendable () -> Bool,
    timeoutMilliseconds: Int = 3_000
) async throws {
    var waited = 0
    while !predicate() {
        if waited >= timeoutMilliseconds { throw SettleTimeout() }
        try await Task.sleep(for: .milliseconds(5))
        waited += 5
    }
}

private func transferKey(_ url: URL) -> String {
    SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
}

/// Deterministic gate for the bounded-bootstrap test: the lease stays
/// pending until the test opens it, so "no fire while readiness runs" has
/// no scheduler race.
private final class GateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func openGate() { lock.withLock { isOpen = true } }
    func waitUntilOpen() async {
        while !(lock.withLock { isOpen }) {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

@Suite("FloeApp.WhisperBackgroundSettlement", .serialized)
struct WhisperBackgroundSettlementTests {
    @Test("Bootstrap registers before the handler; an underway transfer holds the next wake until the install tail drains")
    func bootstrapThenSettleScenario() async throws {
        let coordinator = WhisperDownloadCoordinator.shared
        let defaults = UserDefaults.standard
        let requestedKey = "whisper.installation.requested"
        let saved = defaults.object(forKey: requestedKey)
        defaults.set(false, forKey: requestedKey)
        defer {
            if let saved { defaults.set(saved, forKey: requestedKey) } else { defaults.removeObject(forKey: requestedKey) }
        }
        let running = await WhisperModelStore.shared.installationState().running
        try #require(!running, "this scenario owns the shared wake sequence; no installation may be running")

        // ── wake 1: the system finish for the wake arrives BEFORE the
        // launch handler registers. A naive register would fire the stored
        // handler immediately (the wake looks drained+finished); the fix is
        // that registerBackgroundCompletion tracks the bounded bootstrap
        // lease FIRST, so the release decision is deferred.
        coordinator.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        let fire1 = FireTracker()
        coordinator.registerBackgroundCompletion { fire1.record() }
        // Deterministic discriminator for the ordering fix: if the handler
        // had been stored BEFORE the bootstrap lease, the drained+finished
        // wake would have been consumed and released inside the register
        // call itself (the wake fired, and the bootstrap `beginEvent` then
        // rolled a NEW wake generation). Because the lease is registered
        // first, the release decision defers on the SAME wake generation
        // the handler was stored on.
        var state = coordinator.settlement.settlementStateForTesting
        #expect(state.wakeGeneration == 1, "a late handler must not fire immediately past the pending bootstrap lease")
        #expect(state.hasHandler || state.fired)
        try await settleWait { fire1.count == 1 }
        #expect(!defaults.bool(forKey: requestedKey), "A TTS wake must not request an ASR download")
        #expect(!(await WhisperModelStore.shared.installationState().running))
        #expect(fire1.onMain)
        #expect(fire1.count == 1)

        // A stale duplicate finish after the release is ignored (it must
        // never pre-satisfy the NEXT wake).
        coordinator.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)

        // ── wake 2: an in-memory installation is underway. Reproduce the
        // production seam exactly as `install()` uses it: create the
        // operation ledger, pass it into `download`, and drain it once at
        // the tail.
        let ledger = ModelDownloadSettlementLedger()
        let url = URL(string: "https://example.invalid/whisper-drain-\(UUID().uuidString).bin")!
        let key = transferKey(url)
        let child: Task<Error?, Never> = Task {
            do { _ = try await coordinator.download(url, ledger: ledger, progress: { _ in }); return nil }
            catch { return error }
        }
        try await Task.sleep(for: .milliseconds(80)) // waiter registration
        let failedTask = URLSession.shared.downloadTask(with: url)
        failedTask.taskDescription = key
        coordinator.urlSession(URLSession.shared, task: failedTask, didCompleteWithError: URLError(.networkConnectionLost))
        failedTask.cancel()
        let thrown = await child.value
        #expect(thrown != nil, "the installer unwinds with the transfer error")

        // The callback's settle began on a FIRED wake → it rolled a NEW wake
        // whose system side is NOT satisfied by the earlier stale duplicate.
        state = coordinator.settlement.settlementStateForTesting
        #expect(state.wakeGeneration == 2)
        #expect(state.fired == false, "the underway settle keeps the new wake open")
        #expect(state.pending >= 1)
        #expect(state.systemDone == false, "the stale duplicate finish must not pre-satisfy the next wake")

        let fire2 = FireTracker()
        coordinator.registerBackgroundCompletion { fire2.record() } // wake 2 handler (+ bootstrap lease)
        coordinator.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared) // wake 2 real finish
        try await Task.sleep(for: .milliseconds(80))
        #expect(fire2.count == 0, "OS completion must not fire while the installer's verification/commit settle is underway")

        // Install tail: durable cleanup/commit finished → the single drain
        // (install()'s `defer { ledger.drain() }`) releases.
        ledger.drain()
        try await settleWait { fire2.count == 1 }
        #expect(fire2.onMain)
        state = coordinator.settlement.settlementStateForTesting
        #expect(state.fired)
        #expect(state.pending == 0)
    }

    @Test("A failed transfer begun while the operation is open settles exactly once; retirement keeps its fence")
    func failedAndRetiredTransferSettlesOnce() async throws {
        let coordinator = WhisperDownloadCoordinator.shared
        let state0 = coordinator.settlement.settlementStateForTesting
        #expect(state0.fired, "the previous scenario left the shared settlement settled")

        let ledger = ModelDownloadSettlementLedger()
        let url = URL(string: "https://example.invalid/whisper-retire-\(UUID().uuidString).bin")!
        let key = transferKey(url)
        let child: Task<Bool, Never> = Task {
            do { _ = try await coordinator.download(url, ledger: ledger, progress: { _ in }); return false }
            catch is CancellationError { return true }
            catch { return true }
        }
        try await Task.sleep(for: .milliseconds(80)) // waiter registration

        // Real failure callback acquires the waiter and registers the settle
        // synchronously (exactly-once acquire semantics).
        let failedTask = URLSession.shared.downloadTask(with: url)
        failedTask.taskDescription = key
        coordinator.urlSession(URLSession.shared, task: failedTask, didCompleteWithError: URLError(.cannotConnectToHost))
        failedTask.cancel()
        let unwound = await child.value
        #expect(unwound, "the installer unwinds on the failed transfer")

        // The retirement fence still clears artifacts for the URL even after
        // the waiter is gone (late callbacks cannot recreate them, and a
        // waiter-less retirement begins no extra event).
        await coordinator.cancelAndRemovePendingTransfer(for: url)

        // One wake release, only at the operation tail.
        let fire3 = FireTracker()
        coordinator.registerBackgroundCompletion { fire3.record() }
        coordinator.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        try await Task.sleep(for: .milliseconds(80))
        #expect(fire3.count == 0, "the settle is held until the drain")
        ledger.drain()
        try await settleWait { fire3.count == 1 }
        #expect(fire3.onMain)
        #expect(fire3.count == 1)
        let endState = coordinator.settlement.settlementStateForTesting
        #expect(endState.pending == 0)
    }

    @Test("An external bounded bootstrap from the launch hook is tracked alongside Whisper's own restore, both before the handler")
    func externalBootstrapLeaseIsTrackedBeforeHandler() async throws {
        let coordinator = WhisperDownloadCoordinator.shared
        let defaults = UserDefaults.standard
        let requestedKey = "whisper.installation.requested"
        let saved = defaults.object(forKey: requestedKey)
        defaults.set(false, forKey: requestedKey)
        defer {
            if let saved { defaults.set(saved, forKey: requestedKey) } else { defaults.removeObject(forKey: requestedKey) }
        }
        let running = await WhisperModelStore.shared.installationState().running
        #expect(!running, "no installation may be running while this scenario owns the wake")

        let gate = GateFlag()
        let fired = FireTracker()
        coordinator.registerBackgroundCompletion({ fired.record() }, bootstrap: {
            await gate.waitUntilOpen()
        })
        // Both leases (Whisper restore + the external bounded scan) were
        // registered as pending BEFORE the handler was stored, so the wake
        // cannot release while Main's bounded readiness work runs.
        var state = coordinator.settlement.settlementStateForTesting
        #expect(state.hasHandler)
        #expect(state.fired == false, "the external bootstrap lease must hold the wake")
        coordinator.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        try await Task.sleep(for: .milliseconds(60))
        #expect(fired.count == 0, "OS completion must not fire while the bounded bootstrap is underway")

        gate.openGate()
        try await settleWait { fired.count == 1 }
        #expect(fired.onMain)
        #expect(fired.count == 1)
        state = coordinator.settlement.settlementStateForTesting
        #expect(state.pending == 0)
        #expect(state.fired)
    }

    @Test("Resumes after the operation tail cannot strand a future wake")
    func postTailResumeIsDefensivelySelfPaired() async throws {
        let coordinator = WhisperDownloadCoordinator.shared
        let state0 = coordinator.settlement.settlementStateForTesting
        #expect(state0.fired)

        // Open a production-shaped operation, settle one real transfer
        // failure through it, then drain at the tail.
        let ledger = ModelDownloadSettlementLedger()
        let url = URL(string: "https://example.invalid/whisper-late-\(UUID().uuidString).bin")!
        let key = transferKey(url)
        let child: Task<Bool, Never> = Task {
            do { _ = try await coordinator.download(url, ledger: ledger, progress: { _ in }); return false }
            catch { return true }
        }
        try await Task.sleep(for: .milliseconds(80))
        let failedTask = URLSession.shared.downloadTask(with: url)
        failedTask.taskDescription = key
        coordinator.urlSession(URLSession.shared, task: failedTask, didCompleteWithError: URLError(.timedOut))
        failedTask.cancel()
        let unwound = await child.value
        #expect(unwound)
        ledger.drain()

        // A duplicate late callback finds no waiter and begins nothing
        // further; a defensive `began` after a drained ledger self-pairs.
        let lateTask = URLSession.shared.downloadTask(with: url)
        lateTask.taskDescription = key
        coordinator.urlSession(URLSession.shared, task: lateTask, didCompleteWithError: URLError(.timedOut))
        lateTask.cancel()
        #expect(coordinator.settlement.settlementStateForTesting.pending == 0)
        ledger.began(coordinator.settlement)
        #expect(coordinator.settlement.settlementStateForTesting.pending == 0)

        let fire4 = FireTracker()
        coordinator.registerBackgroundCompletion { fire4.record() }
        coordinator.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        try await settleWait { fire4.count == 1 } // wake not stranded
        #expect(fire4.onMain)
    }
}
#endif
