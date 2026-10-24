// FloeAppTests — Enhanced recognition model warm residency.
//
// SPDX-License-Identifier: MPL-2.0
//
// These tests drive the REAL `SpeechRecognitionRuntime` (the service-owned
// warm lease behind dictation and continuous voice) with a controlled loader
// and model seam: no microphone, no WhisperKit weights, no Speech framework.
// They pin the user-facing contract:
//   - the first actual request mounts once and later sessions reuse it;
//   - a live session keeps its decoder (a second request fails fast, parity
//     with the old single store lease);
//   - a finishing session is joined before the next lease (the
//     VoiceConversationLiveStack.deactivate seam);
//   - cancelled waiters never consume a lease, coalesced cold loads never
//     orphan another waiter, and a retired mount is never installed;
//   - background, memory pressure and pack management release an idle warm
//     model but never unmount a live successor, and an idle warm lease never
//     keeps removal "busy";
//   - a real decoder fault retires the model, a cancelled session does not.
//
// A Foundation-only host harness also exercises the production runtime
// with controlled model and cancellation seams.

#if canImport(UIKit)
import XCTest
import Foundation
@testable import FloeApp

final class SpeechRecognitionResidencyTests: XCTestCase {

    // MARK: - Scripted loader / model seam

    private enum ResidencyStubError: Error { case loadFailed, unmounted, externalLeaseHeld }

    private final class ResidencyLoader: @unchecked Sendable {
        private let lock = NSLock()
        private var identityStorage: String? = "rev-a"
        private var loadDelayMillisecondsStorage = 0
        private var identityDelayMillisecondsStorage = 0
        private var unmountDelayMillisecondsStorage = 0
        private var failNextLoadStorage = false
        private var ignoreCancellationStorage = false
        private var unmountInFlightStorage = false
        private var mountOverlapsUnmountStorage = 0
        private var mountedIDs: Set<UUID> = []
        private var nextMountIdentityStorage: String?
        private var externalLeaseHeldStorage = false
        private var selfRetirementAttemptsStorage = 0
        private var loadCountStorage = 0
        private var unmountCountStorage = 0
        private var releaseCountStorage = 0
        private var concurrentTranscribesStorage = 0
        private var maxConcurrentTranscribesStorage = 0

        var identity: String? { lock.withLock { identityStorage } }
        var loadCount: Int { lock.withLock { loadCountStorage } }
        var unmountCount: Int { lock.withLock { unmountCountStorage } }
        var releaseCount: Int { lock.withLock { releaseCountStorage } }
        var maxConcurrentTranscribes: Int { lock.withLock { maxConcurrentTranscribesStorage } }
        var mountOverlapsUnmount: Int { lock.withLock { mountOverlapsUnmountStorage } }
        var unmountDelayMilliseconds: Int { lock.withLock { unmountDelayMillisecondsStorage } }
        var selfRetirementAttempts: Int { lock.withLock { selfRetirementAttemptsStorage } }

        func setExternalLeaseHeld(_ held: Bool) { lock.withLock { externalLeaseHeldStorage = held } }

        func setIdentity(_ value: String?) { lock.withLock { identityStorage = value } }
        func setNextMountIdentity(_ value: String?) { lock.withLock { nextMountIdentityStorage = value } }

        func configure(delayMilliseconds: Int = 0, identityDelayMilliseconds: Int = 0,
                       unmountDelayMilliseconds: Int = 0, failNextLoad: Bool = false,
                       ignoreCancellation: Bool = false) {
            lock.withLock {
                loadDelayMillisecondsStorage = delayMilliseconds
                identityDelayMillisecondsStorage = identityDelayMilliseconds
                unmountDelayMillisecondsStorage = unmountDelayMilliseconds
                failNextLoadStorage = failNextLoad
                ignoreCancellationStorage = ignoreCancellation
            }
        }

        func dependencies() -> SpeechRecognitionRuntime.Dependencies {
            SpeechRecognitionRuntime.Dependencies(
                installedIdentity: { [self] in await installedIdentityValue() },
                load: { [self] in try await mount() },
                releaseLease: { [self] _ in lock.withLock { releaseCountStorage += 1 } },
                installResidencyHook: { _ in })
        }

        func installedIdentityValue() async -> String? {
            let (delay, value) = lock.withLock { (identityDelayMillisecondsStorage, identityStorage) }
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            return value
        }

        func markMounted(_ id: UUID) { lock.withLock { _ = mountedIDs.insert(id) } }
        func evict(_ id: UUID) { lock.withLock { _ = mountedIDs.remove(id) } }
        func isMounted(_ id: UUID) -> Bool { lock.withLock { mountedIDs.contains(id) } }
        func beginUnmount() { lock.withLock { unmountInFlightStorage = true } }
        func finishUnmount() {
            lock.withLock {
                unmountInFlightStorage = false
                unmountCountStorage += 1
            }
        }

        func mount() async throws -> SpeechRecognitionRuntime.Loaded {
            let (delay, fail, ignore, external) = lock.withLock {
                (loadDelayMillisecondsStorage, failNextLoadStorage, ignoreCancellationStorage, externalLeaseHeldStorage)
            }
            // The resident's own mount must fail fast while an external
            // (file/caption) lease is held and never take the retirement
            // branch — that branch would wait on this very load.
            switch SpeechModelLeaseArbitration.decision(for: .resident, heldLeases: external ? 1 : 0) {
            case .proceed: break
            case .unavailable: throw ResidencyStubError.externalLeaseHeld
            case .retireResident:
                lock.withLock { selfRetirementAttemptsStorage += 1 }
                throw ResidencyStubError.externalLeaseHeld
            }
            // A mount that starts while an unmount is still running is the
            // overlapping file access the retirement window must prevent.
            lock.withLock { if unmountInFlightStorage { mountOverlapsUnmountStorage += 1 } }
            if delay > 0 {
                let duration = Duration.milliseconds(delay)
                if ignore { try? await Task.sleep(for: duration) } else { try await Task.sleep(for: duration) }
            }
            if !ignore { try Task.checkCancellation() }
            if fail {
                lock.withLock { failNextLoadStorage = false }
                throw ResidencyStubError.loadFailed
            }
            let mountedIdentity = lock.withLock { () -> String in
                loadCountStorage += 1
                let override = nextMountIdentityStorage
                nextMountIdentityStorage = nil
                return override ?? identityStorage ?? "unknown"
            }
            let model = ResidencyModel(loader: self, identity: mountedIdentity)
            markMounted(model.mountID)
            return SpeechRecognitionRuntime.Loaded(model: model, leaseID: UUID())
        }

        func beginTranscribe() -> Bool {
            lock.withLock {
                let overlap = concurrentTranscribesStorage > 0
                concurrentTranscribesStorage += 1
                maxConcurrentTranscribesStorage = max(maxConcurrentTranscribesStorage, concurrentTranscribesStorage)
                return overlap
            }
        }
        func endTranscribe() { lock.withLock { concurrentTranscribesStorage -= 1 } }
    }

    private struct ResidencyModel: SpeechRecognitionModelInstance, @unchecked Sendable {
        let loader: ResidencyLoader
        let identity: String
        let mountID = UUID()

        func transcribe(audio: [Float], decoding: SpeechRecognitionDecoding) async throws -> [String] {
            guard loader.isMounted(mountID) else { throw ResidencyStubError.unmounted }
            let overlapped = loader.beginTranscribe()
            try? await Task.sleep(for: .milliseconds(5))
            loader.endTranscribe()
            if overlapped { throw ResidencyStubError.unmounted }
            return ["ok"]
        }

        func unmount() async {
            loader.evict(mountID)
            loader.beginUnmount()
            let delay = loader.unmountDelayMilliseconds
            if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
            loader.finishUnmount()
        }
    }

    private final class ResidencyFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = false
        func set() { lock.withLock { stored = true } }
        var value: Bool { lock.withLock { stored } }
    }

    private func mountID(_ lease: SpeechRecognitionLease) -> UUID? {
        (lease.model as? ResidencyModel)?.mountID
    }

    /// One scripted session worker: reports completion the way the real
    /// transcriber's worker does (last step = sessionEnded).
    private func startSession(_ lease: SpeechRecognitionLease, healthy: Bool = true) async -> Task<Void, Never> {
        let worker = Task {
            _ = try? await lease.model.transcribe(audio: [0.1],
                decoding: SpeechRecognitionDecoding(languageCode: "en", detectLanguage: false))
            await lease.sessionEnded(healthy: healthy)
        }
        await lease.attachWorker(worker)
        await lease.beginFinishing()
        return worker
    }

    private func runtime(_ loader: ResidencyLoader) -> SpeechRecognitionRuntime {
        SpeechRecognitionRuntime(dependencies: loader.dependencies())
    }

    // MARK: - Reuse

    func testFirstRequestMountsOnceAndSequentialSessionsReuseIt() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        await runtime.setForeground(true)
        XCTAssertEqual(loader.loadCount, 0, "no model load before the first request")

        let first = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 1)
        let firstMount = mountID(first)
        await (await startSession(first)).value

        let second = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 1, "second session reuses the mounted model")
        XCTAssertEqual(loader.unmountCount, 0, "healthy session end keeps the model warm")
        XCTAssertEqual(mountID(second), firstMount)
        await (await startSession(second)).value
        XCTAssertEqual(loader.maxConcurrentTranscribes, 1)
    }

    func testLiveSessionIsNotStolen() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let live = try await runtime.acquire()
        let worker = Task { _ = try? await Task.sleep(for: .milliseconds(120)) }
        await live.attachWorker(worker)
        do {
            _ = try await runtime.acquire()
            XCTFail("a live session must not be stolen")
        } catch SpeechRecognitionRuntime.Failure.busy {
            // Expected: the caller keeps its existing fallback rules.
        }
        XCTAssertEqual(loader.loadCount, 1)
        XCTAssertEqual(loader.unmountCount, 0)
        await live.beginFinishing()
        await worker.value
        await live.sessionEnded(healthy: true)
    }

    /// `VoiceConversationLiveStack.deactivate()` schedules `finishAudio()`
    /// without joining it: the next lease must wait for that worker.
    func testFinishingSessionIsJoinedBeforeGrant() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let previous = try await runtime.acquire()
        let exited = ResidencyFlag()
        let worker = Task {
            try? await Task.sleep(for: .milliseconds(200))
            exited.set()
        }
        await previous.attachWorker(worker)
        await previous.beginFinishing()

        let started = DispatchTime.now().uptimeNanoseconds
        let next = try await runtime.acquire()
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        XCTAssertTrue(exited.value, "next grant waited for the previous worker")
        XCTAssertGreaterThanOrEqual(elapsed, 150)
        XCTAssertEqual(loader.loadCount, 1, "joined session reused the warm model")
        await next.beginFinishing()
        await next.sessionEnded(healthy: true)
    }

    // MARK: - Concurrency and cancellation

    func testConcurrentColdAcquiresCoalesceAndCancelledWaiterDoesNotOrphan() async throws {
        let loader = ResidencyLoader()
        loader.configure(delayMilliseconds: 250)
        let runtime = runtime(loader)

        let first = Task { try await runtime.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        let second = Task { try await runtime.acquire() }
        first.cancel()

        let firstResult = await first.result
        let secondResult = await second.result
        if case .success = firstResult { XCTFail("cancelled waiter must not receive the lease") }
        guard case .success(let lease) = secondResult else {
            return XCTFail("remaining waiter must receive the warm model")
        }
        XCTAssertEqual(loader.loadCount, 1, "concurrent cold acquires coalesced")
        XCTAssertEqual(loader.unmountCount, 0, "a cancelled waiter does not discard the mount")
        await (await startSession(lease)).value
    }

    func testCancelledWarmWaiterDoesNotConsumeTheLease() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let warm = try await runtime.acquire()
        await (await startSession(warm)).value

        loader.configure(identityDelayMilliseconds: 150)
        let cancelled = Task { try await runtime.acquire() }
        try await Task.sleep(for: .milliseconds(30))
        cancelled.cancel()
        if case .success = await cancelled.result { XCTFail("cancelled waiter took the lease") }

        loader.configure()
        let next = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 1, "cancelled waiter did not disturb the warm mount")
        _ = try await next.model.transcribe(audio: [0.1],
            decoding: SpeechRecognitionDecoding(languageCode: "en", detectLanguage: false))
        await next.beginFinishing()
        await next.sessionEnded(healthy: true)
    }

    func testRetiredColdMountIsNeverInstalledAndCanBeRetried() async throws {
        let loader = ResidencyLoader()
        loader.configure(delayMilliseconds: 200, unmountDelayMilliseconds: 60, ignoreCancellation: true)
        let runtime = runtime(loader)

        let loading = Task { try await runtime.acquire() }
        try await Task.sleep(for: .milliseconds(50))
        let released = await runtime.releaseForModelManagement()
        XCTAssertTrue(released, "retiring with no live session succeeds")
        switch await loading.result {
        case .success: XCTFail("a retired mount must never be handed out")
        case .failure: break
        }
        XCTAssertEqual(loader.unmountCount, 1, "the retired cold mount was unmounted")
        XCTAssertEqual(loader.releaseCount, 1, "the retired cold mount returned its file lease")
        XCTAssertEqual(loader.mountOverlapsUnmount, 0, "no mount overlapped the discarded unmount")
    }

    func testFailedLoadRetries() async throws {
        let loader = ResidencyLoader()
        loader.configure(failNextLoad: true)
        let runtime = runtime(loader)
        do {
            _ = try await runtime.acquire()
            XCTFail("failed load must throw")
        } catch {
            XCTAssertEqual(loader.loadCount, 0)
        }
        let lease = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 1)
        await (await startSession(lease)).value
    }

    // MARK: - Lifecycle, pressure and model management

    func testIdentityChangeRetiresTheOldMount() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let old = try await runtime.acquire()
        await (await startSession(old)).value
        XCTAssertEqual(loader.unmountCount, 0)

        loader.setIdentity("rev-b")
        let fresh = try await runtime.acquire()
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.releaseCount, 1)
        XCTAssertEqual(loader.loadCount, 2)
        XCTAssertEqual(fresh.model.identity, "rev-b")
        await (await startSession(fresh)).value
    }

    func testBackgroundReleasesIdleWarmButNotLiveSessions() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let warm = try await runtime.acquire()
        await (await startSession(warm)).value
        XCTAssertEqual(loader.unmountCount, 0)

        await runtime.setForeground(false)
        XCTAssertEqual(loader.unmountCount, 1, "background releases the idle warm model")
        XCTAssertEqual(loader.releaseCount, 1)

        await runtime.setForeground(true)
        XCTAssertEqual(loader.loadCount, 1, "returning to the foreground does not preload")

        let again = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 2, "next request after background reloads")

        let liveWorker = Task { _ = try? await Task.sleep(for: .milliseconds(120)) }
        await again.attachWorker(liveWorker)
        await runtime.setForeground(false)
        XCTAssertEqual(loader.unmountCount, 1, "a live session keeps the model across background")
        await again.beginFinishing()
        await liveWorker.value
        await again.sessionEnded(healthy: true)
        XCTAssertEqual(loader.unmountCount, 2, "background retirement waits for the session end")
        await runtime.setForeground(true)
    }

    func testMemoryPressureCancelsJoinsThenReleases() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let lease = try await runtime.acquire()
        let cancelled = ResidencyFlag()
        let worker = Task {
            while !Task.isCancelled {
                _ = try? await lease.model.transcribe(audio: [0.1],
                    decoding: SpeechRecognitionDecoding(languageCode: nil, detectLanguage: true))
                try? await Task.sleep(for: .milliseconds(10))
            }
            cancelled.set()
            await lease.sessionEnded(healthy: true)
        }
        await lease.attachWorker(worker)
        try await Task.sleep(for: .milliseconds(30))
        await runtime.handleMemoryWarning()
        XCTAssertTrue(cancelled.value)
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.maxConcurrentTranscribes, 1, "release never overlapped a decode")
    }

    func testPackManagementBusyOnlyForLiveSessions() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let lease = try await runtime.acquire()
        let rejected = await runtime.releaseForModelManagement()
        XCTAssertFalse(rejected, "a live session still reports busy")
        XCTAssertEqual(loader.unmountCount, 0)

        let worker = await startSession(lease)
        await worker.value
        let accepted = await runtime.releaseForModelManagement()
        XCTAssertTrue(accepted, "an idle warm model is retired for management")
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.releaseCount, 1)
    }

    func testLateCallbacksFromRetiredSessionAreFenced() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let stale = try await runtime.acquire()
        await (await startSession(stale)).value
        await runtime.handleMemoryWarning()
        XCTAssertEqual(loader.unmountCount, 1)

        let fresh = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 2)
        await stale.sessionEnded(healthy: false)
        XCTAssertEqual(loader.unmountCount, 1, "late failure cannot unload a newer session")
        await fresh.beginFinishing()
        await fresh.sessionEnded(healthy: true)
        XCTAssertEqual(loader.unmountCount, 1)
    }

    /// Retirement windows: no successor may be granted while an unmount runs,
    /// and a successor is never unmounted underneath.
    func testSuccessorIsNeverGrantedOrUnmountedDuringRetirement() async throws {
        let loader = ResidencyLoader()
        loader.configure(unmountDelayMilliseconds: 120)
        let runtime = runtime(loader)
        let warm = try await runtime.acquire()
        await (await startSession(warm)).value

        let pressure = Task { await runtime.handleMemoryWarning() }
        try await Task.sleep(for: .milliseconds(20))
        let granted = ResidencyFlag()
        let successor = Task { () -> SpeechRecognitionLease in
            let lease = try await runtime.acquire()
            granted.set()
            return lease
        }
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertFalse(granted.value, "no lease granted while the retirement unmount runs")
        let lease = try await successor.value
        await pressure.value
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.mountOverlapsUnmount, 0)
        _ = try await lease.model.transcribe(audio: [0.1],
            decoding: SpeechRecognitionDecoding(languageCode: "en", detectLanguage: false))
        await lease.beginFinishing()
        await lease.sessionEnded(healthy: true)
    }


    /// A claim retired between `acquire()` and worker attachment must reject
    /// the late attachment (cancelling that worker), must never register on a
    /// successor, and must never decode.
    func testLateAttachAfterRetirementIsRejected() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let stale = try await runtime.acquire()
        await runtime.handleMemoryWarning()
        XCTAssertEqual(loader.unmountCount, 1, "pressure retired the unattached claim")

        let successor = try await runtime.acquire()
        let staleCancelled = ResidencyFlag()
        let staleWorker = Task {
            for _ in 0..<100 {
                if Task.isCancelled { staleCancelled.set(); return }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let admittedStale = await stale.attachWorker(staleWorker)
        XCTAssertFalse(admittedStale, "late attach on a retired claim is rejected")
        await staleWorker.value
        XCTAssertTrue(staleCancelled.value, "the rejected worker was cancelled")
        XCTAssertEqual(loader.maxConcurrentTranscribes, 0, "a rejected worker never decodes")

        let successorWorker = Task {
            _ = try? await successor.model.transcribe(audio: [0.1],
                decoding: SpeechRecognitionDecoding(languageCode: "en", detectLanguage: false))
            await successor.sessionEnded(healthy: true)
        }
        let admittedSuccessor = await successor.attachWorker(successorWorker)
        XCTAssertTrue(admittedSuccessor, "the successor's own attach is still accepted")
        await successorWorker.value
        XCTAssertEqual(loader.maxConcurrentTranscribes, 1)
        XCTAssertEqual(loader.unmountCount, 1, "the successor model stayed mounted")
    }


    /// Store↔Runtime arbitration: the resident's own mount must fail fast
    /// while an external (file/caption) lease is held and must never call its
    /// own retirement hook; an external user still retires an idle warm model.
    func testResidentMountNeverRetiresItselfUnderAnExternalLease() async throws {
        XCTAssertEqual(SpeechModelLeaseArbitration.decision(for: .resident, heldLeases: 0), .proceed)
        XCTAssertEqual(SpeechModelLeaseArbitration.decision(for: .resident, heldLeases: 1), .unavailable)
        XCTAssertEqual(SpeechModelLeaseArbitration.decision(for: .external, heldLeases: 0), .proceed)
        XCTAssertEqual(SpeechModelLeaseArbitration.decision(for: .external, heldLeases: 1), .retireResident)

        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        loader.setExternalLeaseHeld(true)
        do {
            _ = try await runtime.acquire()
            XCTFail("resident acquisition must fail while an external lease is held")
        } catch {
            XCTAssertEqual(loader.selfRetirementAttempts, 0, "no recursive retirement hook")
            XCTAssertEqual(loader.loadCount, 0)
        }

        loader.setExternalLeaseHeld(false)
        let lease = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 1, "resident loads after the external lease is released")
        await (await startSession(lease)).value

        loader.setExternalLeaseHeld(true)
        let retired = await runtime.releaseForModelManagement()
        XCTAssertTrue(retired, "idle warm resident retired for an external exclusive user")
        XCTAssertEqual(loader.unmountCount, 1)
        do {
            _ = try await runtime.acquire()
            XCTFail("resident acquisition fails while the external lease is held")
        } catch {
            XCTAssertEqual(loader.selfRetirementAttempts, 0)
        }

        loader.setExternalLeaseHeld(false)
        let next = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 2, "resident reloads after the external handoff")
        await (await startSession(next)).value
    }


    /// A forced (pressure) cancellation is classified as an interruption, not
    /// a healthy renewal and not decoder corruption; a consumer finish stays
    /// normal so warm retention survives an ordinary stop.
    func testWorkerExitClassification() {
        XCTAssertEqual(SpeechRecognitionWorkerExit.classify(endedByConsumer: true, decoderFailed: false), .normal)
        XCTAssertEqual(SpeechRecognitionWorkerExit.classify(endedByConsumer: false, decoderFailed: false), .forcedInterruption)
        XCTAssertEqual(SpeechRecognitionWorkerExit.classify(endedByConsumer: false, decoderFailed: true), .decoderFailure)
        XCTAssertEqual(SpeechRecognitionWorkerExit.classify(endedByConsumer: true, decoderFailed: true), .decoderFailure)
    }

    func testResidencyPolicyTable() {
        XCTAssertFalse(SpeechRecognitionResidencyPolicy.unloadsAfterSessionEnd(healthy: true, isForeground: true))
        XCTAssertTrue(SpeechRecognitionResidencyPolicy.unloadsAfterSessionEnd(healthy: false, isForeground: true))
        XCTAssertTrue(SpeechRecognitionResidencyPolicy.unloadsAfterSessionEnd(healthy: true, isForeground: false))
        XCTAssertTrue(SpeechRecognitionResidencyPolicy.releasesOnIdleLifecycle(hasActiveSession: false))
        XCTAssertFalse(SpeechRecognitionResidencyPolicy.releasesOnIdleLifecycle(hasActiveSession: true))
    }
}
#endif
