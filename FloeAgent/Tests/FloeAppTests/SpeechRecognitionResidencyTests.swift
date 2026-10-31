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
//     orphan another waiter, a retired mount is never installed, and the
//     pending acquisition fails rather than remounting while a fresh
//     acquisition after the retirement still mounts;
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
        private var loadStartedStorage = 0
        private var unmountCountStorage = 0
        private var releaseCountStorage = 0
        private var concurrentTranscribesStorage = 0
        private var maxConcurrentTranscribesStorage = 0
        private var unmountOverlappedTranscribeStorage = 0

        var identity: String? { lock.withLock { identityStorage } }
        var loadCount: Int { lock.withLock { loadCountStorage } }
        var loadStartedCount: Int { lock.withLock { loadStartedStorage } }
        var unmountCount: Int { lock.withLock { unmountCountStorage } }
        var releaseCount: Int { lock.withLock { releaseCountStorage } }
        var maxConcurrentTranscribes: Int { lock.withLock { maxConcurrentTranscribesStorage } }
        var unmountOverlappedTranscribe: Int { lock.withLock { unmountOverlappedTranscribeStorage } }
        var mountOverlapsUnmount: Int { lock.withLock { mountOverlapsUnmountStorage } }
        var unmountInFlight: Bool { lock.withLock { unmountInFlightStorage } }
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
        func beginUnmount() {
            lock.withLock {
                if concurrentTranscribesStorage > 0 { unmountOverlappedTranscribeStorage += 1 }
                unmountInFlightStorage = true
            }
        }
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
            lock.withLock {
                loadStartedStorage += 1
                if unmountInFlightStorage { mountOverlapsUnmountStorage += 1 }
            }
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

        func waitForLoadStart(_ minimum: Int = 1) async throws {
            for _ in 0..<600 {
                if loadStartedCount >= minimum { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTFail("the cold mount did not start")
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

        func transcribeTimed(audio: [Float], decoding: SpeechRecognitionDecoding) async throws -> [SpeechRecognitionTimedSegment] {
            guard loader.isMounted(mountID) else { throw ResidencyStubError.unmounted }
            let overlapped = loader.beginTranscribe()
            try? await Task.sleep(for: .milliseconds(5))
            loader.endTranscribe()
            if overlapped { throw ResidencyStubError.unmounted }
            return [SpeechRecognitionTimedSegment(start: 0.1, end: 0.5, text: "file", words: [])]
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
        XCTAssertEqual(loader.loadCount, 1, "the retired acquisition did not mount again")

        // The pending acquisition must not retry by itself. A fresh explicit
        // acquisition after the retirement is the only retry that may mount.
        let fresh = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 2, "a fresh acquisition mounted the model again")
        XCTAssertEqual(fresh.model.identity, "rev-a", "the fresh acquisition mounted the installed revision")
        await (await startSession(fresh)).value
        XCTAssertEqual(loader.unmountCount, 1, "the healthy fresh session kept the replacement warm")
    }

    /// Reentrancy boundary: a retirement that starts while a stale-identity
    /// mount is being discarded must be terminal for the pending acquisition.
    /// The generation is checked again after the unmount/lease awaits, so the
    /// waiter cannot retry and mount after the retirement window closes.
    func testRetirementDuringStaleIdentityDiscardFailsThePendingAcquire() async throws {
        let loader = ResidencyLoader()
        loader.configure(unmountDelayMilliseconds: 300)
        loader.setNextMountIdentity("rev-stale")
        let runtime = runtime(loader)

        let loading = Task { try await runtime.acquire() }
        var attempts = 0
        while !loader.unmountInFlight && attempts < 400 {
            try await Task.sleep(for: .milliseconds(5))
            attempts += 1
        }
        XCTAssertTrue(loader.unmountInFlight, "the stale-identity mount reached its discard unmount")

        let released = await runtime.releaseForModelManagement()
        XCTAssertTrue(released, "retiring the stale-identity discard succeeds")

        switch await loading.result {
        case .success: XCTFail("a stale mount retired during its discard must never be handed out")
        case .failure: break
        }
        XCTAssertEqual(loader.loadCount, 1, "the pending acquisition did not mount again")
        XCTAssertEqual(loader.unmountCount, 1, "the stale mount was unmounted exactly once")
        XCTAssertEqual(loader.releaseCount, 1, "the stale mount returned its file lease exactly once")
        XCTAssertEqual(loader.mountOverlapsUnmount, 0, "no mount overlapped the stale discard")

        let fresh = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 2, "a fresh explicit acquisition mounted the installed revision")
        XCTAssertEqual(fresh.model.identity, "rev-a")
        await (await startSession(fresh)).value
        XCTAssertEqual(loader.unmountCount, 1, "the healthy fresh session kept the replacement warm")
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

    // MARK: - Optional model preload

    func testWarmUpConsumesNoSessionLeaseAndReusesItsMount() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)

        let warmed = await runtime.warmUp()
        XCTAssertTrue(warmed)
        XCTAssertEqual(loader.loadCount, 1, "preload mounted the installed model")
        // If warmUp had consumed a session lease this would throw .busy.
        let lease = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 1, "the first real session reused the preload mount")
        await (await startSession(lease)).value
        XCTAssertEqual(loader.unmountCount, 0, "ordinary end kept the foreground model warm")
    }

    func testWarmUpAndAcquireCoalesceOneColdMount() async throws {
        let loader = ResidencyLoader()
        loader.configure(delayMilliseconds: 250)
        let runtime = runtime(loader)

        let warm = Task { await runtime.warmUp() }
        try await Task.sleep(for: .milliseconds(60))
        let lease = try await runtime.acquire()
        let warmed = await warm.value
        XCTAssertTrue(warmed)
        XCTAssertEqual(loader.loadCount, 1, "warm-up and acquire shared one verification/mount")
        XCTAssertEqual(loader.unmountCount, 0)
        await (await startSession(lease)).value
        XCTAssertEqual(loader.unmountCount, 0)
    }

    func testWarmUpJoinsAnAcquireStartedColdMount() async throws {
        let loader = ResidencyLoader()
        loader.configure(delayMilliseconds: 220)
        let runtime = runtime(loader)

        let acquire = Task { try await runtime.acquire() }
        try await loader.waitForLoadStart()
        let warm = Task { await runtime.warmUp() }
        let lease = try await acquire.value
        let warmed = await warm.value
        XCTAssertTrue(warmed)
        XCTAssertEqual(loader.loadCount, 1)
        XCTAssertEqual(loader.unmountCount, 0)
        await (await startSession(lease)).value
    }

    func testCancelledWarmUpDiscardsUnusedSpeculativeMount() async throws {
        let loader = ResidencyLoader()
        loader.configure(delayMilliseconds: 200, unmountDelayMilliseconds: 30, ignoreCancellation: true)
        let runtime = runtime(loader)

        let warm = Task { await runtime.warmUp() }
        try await loader.waitForLoadStart()
        warm.cancel()
        let warmed = await warm.value
        XCTAssertFalse(warmed, "a cancelled preload must not claim success")
        XCTAssertEqual(loader.loadCount, 1, "the discarded mount was built once")
        XCTAssertEqual(loader.unmountCount, 1, "unused speculative mount was unmounted")
        XCTAssertEqual(loader.releaseCount, 1, "the discarded mount returned its file lease")
        XCTAssertEqual(loader.mountOverlapsUnmount, 0, "no mount overlapped the discard")

        let lease = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 2, "a later explicit acquire mounted again")
        await (await startSession(lease)).value
    }

    func testCancelledWarmUpKeepsLoadForWaitingAcquire() async throws {
        let loader = ResidencyLoader()
        loader.configure(delayMilliseconds: 220)
        let runtime = runtime(loader)

        let warm = Task { await runtime.warmUp() }
        try await loader.waitForLoadStart()
        let acquire = Task { try await runtime.acquire() }
        try await Task.sleep(for: .milliseconds(80))
        warm.cancel()
        let warmed = await warm.value
        XCTAssertFalse(warmed, "the cancelled preload did not claim success")
        let lease = try await acquire.value
        XCTAssertEqual(loader.loadCount, 1, "real demand kept the single mount")
        XCTAssertEqual(loader.unmountCount, 0, "speculative cancellation never failed a real waiter")
        await (await startSession(lease)).value
    }

    func testDisableCancelsAnInFlightSpeculativeMount() async throws {
        let loader = ResidencyLoader()
        loader.configure(delayMilliseconds: 180, ignoreCancellation: true)
        let runtime = runtime(loader)
        let warm = Task { await runtime.warmUp() }
        try await loader.waitForLoadStart()
        let cancelled = await runtime.cancelSpeculativeWarmUp()
        XCTAssertTrue(cancelled)
        let warmed = await warm.value
        XCTAssertFalse(warmed, "in-flight preload did not install a disabled model")
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.releaseCount, 1)
    }

    func testWarmUpDoesNotMountWhileBackgrounded() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        await runtime.setForeground(false)
        let warmed = await runtime.warmUp()
        XCTAssertFalse(warmed)
        XCTAssertEqual(loader.loadCount, 0)
    }

    func testDisableFencesAWarmUpSuspendedBeforeItsColdLoad() async throws {
        let loader = ResidencyLoader()
        loader.configure(identityDelayMilliseconds: 220)
        let runtime = runtime(loader)
        let warm = Task { await runtime.warmUp() }
        try await Task.sleep(for: .milliseconds(60))
        let cancelled = await runtime.cancelSpeculativeWarmUp()
        XCTAssertFalse(cancelled, "nothing was mounted yet to discard")
        let warmed = await warm.value
        XCTAssertFalse(warmed, "disabled warm-up did not mount after the identity await")
        XCTAssertEqual(loader.loadCount, 0)
        await runtime.allowSpeculativeWarmUp()
        let reenabled = await runtime.warmUp()
        XCTAssertTrue(reenabled)
        XCTAssertEqual(loader.loadCount, 1)
    }

    func testDisableRetiresIdleSpeculativeWarmButNotLiveSession() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let firstWarm = await runtime.warmUp()
        XCTAssertTrue(firstWarm)
        let disabled = await runtime.cancelSpeculativeWarmUp()
        XCTAssertTrue(disabled, "disabling released the idle preload")
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.releaseCount, 1)

        await runtime.allowSpeculativeWarmUp()
        let secondWarm = await runtime.warmUp()
        XCTAssertTrue(secondWarm)
        let lease = try await runtime.acquire()
        let worker = Task<Void, Never> {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { }
        }
        await lease.attachWorker(worker)
        let cancelWhileLive = await runtime.cancelSpeculativeWarmUp()
        XCTAssertFalse(cancelWhileLive, "a live session is never cancelled")
        XCTAssertEqual(loader.unmountCount, 1)
        await lease.beginFinishing()
        await worker.value
        await lease.sessionEnded(healthy: true)
        XCTAssertEqual(loader.unmountCount, 1, "a real-use warm model is not speculative")
    }

    func testWarmUpIsSuppressedAfterMemoryPressureUntilExplicitlyReenabled() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let initialWarm = await runtime.warmUp()
        XCTAssertTrue(initialWarm)
        await runtime.handleMemoryWarning()
        XCTAssertEqual(loader.unmountCount, 1)
        let suppressed = await runtime.warmUp()
        XCTAssertFalse(suppressed, "speculation must not undo a memory-pressure release")
        XCTAssertEqual(loader.loadCount, 1)

        let lease = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 2, "explicit acquisition still mounts after pressure")
        await (await startSession(lease)).value
        await runtime.allowSpeculativeWarmUp()
        let rearmed = await runtime.warmUp()
        XCTAssertTrue(rearmed, "explicit enable re-arms preload")
        XCTAssertEqual(loader.loadCount, 2, "already-warm model is reused")
    }

    func testWarmUpRetriesStaleIdentityAndReturnsTheStaleLease() async throws {
        let loader = ResidencyLoader()
        loader.setNextMountIdentity("rev-stale")
        let runtime = runtime(loader)

        let warmed = await runtime.warmUp()
        XCTAssertTrue(warmed)
        XCTAssertEqual(loader.loadCount, 2, "stale mount then current revision")
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.releaseCount, 1)
        XCTAssertEqual(loader.mountOverlapsUnmount, 0)
        let lease = try await runtime.acquire()
        XCTAssertEqual(lease.model.identity, "rev-a")
        XCTAssertEqual(loader.loadCount, 2)
        await (await startSession(lease)).value
    }

    func testWarmUpRetiresAWarmModelWhenTheInstalledIdentityMoves() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let initial = await runtime.warmUp()
        XCTAssertTrue(initial)
        loader.setIdentity("rev-b")
        let rewarmed = await runtime.warmUp()
        XCTAssertTrue(rewarmed)
        XCTAssertEqual(loader.loadCount, 2)
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.releaseCount, 1)
        let lease = try await runtime.acquire()
        XCTAssertEqual(lease.model.identity, "rev-b")
        XCTAssertEqual(loader.loadCount, 2)
        await (await startSession(lease)).value
    }

    func testWarmUpRetirementIsTerminalAndReturnsTheLease() async throws {
        let loader = ResidencyLoader()
        loader.configure(delayMilliseconds: 180, unmountDelayMilliseconds: 40, ignoreCancellation: true)
        let runtime = runtime(loader)

        let warm = Task { await runtime.warmUp() }
        try await loader.waitForLoadStart()
        let released = await runtime.releaseForModelManagement()
        XCTAssertTrue(released)
        let warmed = await warm.value
        XCTAssertFalse(warmed, "a retired speculative mount is never installed")
        XCTAssertEqual(loader.unmountCount, 1)
        XCTAssertEqual(loader.releaseCount, 1)
        XCTAssertEqual(loader.mountOverlapsUnmount, 0)

        let lease = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 2, "a fresh acquire mounts after retirement")
        await (await startSession(lease)).value
    }

    func testTimedFileLeaseSharesTheModelAndSerializesWithVoice() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let initialWarm = await runtime.warmUp()
        XCTAssertTrue(initialWarm)
        let fileLease = try await runtime.acquireForTimedTranscription()
        XCTAssertEqual(loader.loadCount, 1, "file pass reused the warm mount")
        let segments = try await fileLease.model.transcribeTimed(
            audio: [0.1], decoding: SpeechRecognitionDecoding(languageCode: "en", detectLanguage: false))
        XCTAssertEqual(segments.count, 1)
        XCTAssertLessThan(segments[0].start, segments[0].end)

        do {
            _ = try await runtime.acquire()
            XCTFail("a live timed file lease must not be stolen")
        } catch SpeechRecognitionRuntime.Failure.busy {
            // Expected.
        }
        await fileLease.beginFinishing()
        await fileLease.sessionEnded(healthy: true)
        XCTAssertEqual(loader.unmountCount, 0, "healthy file end kept the warm model")
        let voice = try await runtime.acquire()
        XCTAssertEqual(loader.loadCount, 1, "voice reused the same mounted model")
        await (await startSession(voice)).value
        XCTAssertEqual(loader.maxConcurrentTranscribes, 1)
    }

    func testTimedFileWorkerIsJoinedBeforeMemoryPressureUnmount() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let warmed = await runtime.warmUp()
        XCTAssertTrue(warmed)
        let lease = try await runtime.acquireForTimedTranscription()
        let cancelled = ResidencyFlag()
        let worker = Task {
            while !Task.isCancelled {
                _ = try? await lease.model.transcribeTimed(
                    audio: [0.1], decoding: SpeechRecognitionDecoding(languageCode: "en", detectLanguage: false))
                try? await Task.sleep(for: .milliseconds(5))
            }
            cancelled.set()
        }
        await lease.attachWorker(worker)
        try await Task.sleep(for: .milliseconds(40))
        await runtime.handleMemoryWarning()
        XCTAssertTrue(cancelled.value, "the timed file worker observed cancellation")
        XCTAssertEqual(loader.unmountCount, 1, "unmount happened only after the worker exited")
        XCTAssertEqual(loader.maxConcurrentTranscribes, 1, "retirement never overlapped timed inference")
        XCTAssertEqual(loader.unmountOverlappedTranscribe, 0, "unmount happened only after the timed worker exited")

        let successor = try await runtime.acquire()
        await lease.sessionEnded(healthy: false)
        XCTAssertEqual(loader.unmountCount, 1, "a late file callback cannot release the successor")
        await (await startSession(successor)).value
        XCTAssertEqual(loader.unmountCount, 1, "successor stayed mounted")
    }

    func testBackgroundKeepsLiveTimedFileWorkerMountedUntilExit() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let warmed = await runtime.warmUp()
        XCTAssertTrue(warmed)
        let lease = try await runtime.acquireForTimedTranscription()
        let worker = Task {
            while !Task.isCancelled {
                _ = try? await lease.model.transcribeTimed(
                    audio: [0.1], decoding: SpeechRecognitionDecoding(languageCode: "en", detectLanguage: false))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await lease.attachWorker(worker)
        await runtime.setForeground(false)
        XCTAssertEqual(loader.unmountCount, 0, "background never unmounted under the live file worker")
        XCTAssertEqual(loader.unmountOverlappedTranscribe, 0, "background did not overlap the timed worker")
        await lease.beginFinishing()
        worker.cancel()
        await worker.value
        await lease.sessionEnded(healthy: true)
        XCTAssertEqual(loader.unmountCount, 1, "background retired only after the file worker ended")
        await runtime.setForeground(true)
    }

    func testPackManagementIsBusyForALiveTimedFileWorker() async throws {
        let loader = ResidencyLoader()
        let runtime = runtime(loader)
        let warmed = await runtime.warmUp()
        XCTAssertTrue(warmed)
        let lease = try await runtime.acquireForTimedTranscription()
        let worker = Task {
            while !Task.isCancelled {
                _ = try? await lease.model.transcribeTimed(
                    audio: [0.1], decoding: SpeechRecognitionDecoding(languageCode: "en", detectLanguage: false))
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await lease.attachWorker(worker)
        let busy = await runtime.releaseForModelManagement()
        XCTAssertFalse(busy, "a live timed file worker reports busy")
        XCTAssertEqual(loader.unmountCount, 0, "pack management did not unmount under the worker")
        XCTAssertEqual(loader.unmountOverlappedTranscribe, 0, "pack management did not overlap the timed worker")
        await lease.beginFinishing()
        worker.cancel()
        await worker.value
        await lease.sessionEnded(healthy: true)
        let released = await runtime.releaseForModelManagement()
        XCTAssertTrue(released, "idle warm model is retired for management")
        XCTAssertEqual(loader.unmountCount, 1)
    }

    func testTimedMappingKeepsRealTimingAndDropsInvalidAlignment() {
        let raw = [
            SpeechRecognitionTimedMapping.RawSegment(start: -0.5, end: 2.5, text: " hello ",
                words: [.init(start: -1, end: 1, text: "hello")]),
            SpeechRecognitionTimedMapping.RawSegment(start: 5, end: 9, text: "outside", words: nil),
            SpeechRecognitionTimedMapping.RawSegment(start: 0, end: 0, text: "zero", words: nil),
            SpeechRecognitionTimedMapping.RawSegment(start: .nan, end: 1, text: "nan", words: nil),
            SpeechRecognitionTimedMapping.RawSegment(start: 1, end: 2, text: "   ", words: nil)
        ]
        let mapped = SpeechRecognitionTimedMapping.relativeSegments(raw: raw, duration: 4)
        XCTAssertEqual(mapped.count, 1)
        XCTAssertEqual(mapped[0].start, 0)
        XCTAssertEqual(mapped[0].end, 2.5)
        XCTAssertEqual(mapped[0].text, "hello")
        XCTAssertEqual(mapped[0].words.count, 1)
        XCTAssertEqual(mapped[0].words[0].start, 0)
        XCTAssertEqual(mapped[0].words[0].end, 1)
        let shifted = mapped[0].offsetting(by: 25)
        XCTAssertEqual(shifted.start, 25)
        XCTAssertEqual(shifted.end, 27.5)
        XCTAssertEqual(shifted.words[0].start, 25)
        XCTAssertEqual(shifted.words[0].end, 26)
    }
}


final class VoiceRecognitionPreloadPolicyTests: XCTestCase {
    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "org.floeagent.preload.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testDefaultIsOffForEveryRouteAndObservationNeverEnables() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))
        let routes = [
            VoiceRecognitionPreloadPolicy.primaryIdentity(method: "enhanced"),
            VoiceRecognitionPreloadPolicy.primaryIdentity(method: "openai", provider: "p1", profile: "f1"),
            VoiceRecognitionPreloadPolicy.primaryIdentity(method: "volcengine", provider: "p2", profile: "f2"),
            VoiceRecognitionPreloadPolicy.primaryIdentity(method: "alibaba", provider: "p3", profile: "f3")
        ]
        for _ in routes {
            XCTAssertFalse(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))
        }
        let route = VoiceRecognitionPreloadPolicy.primaryIdentity(method: "enhanced")
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.observePrimaryIdentity(route, defaults: defaults), .recorded)
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.primaryIdentity(defaults: defaults), route)
    }

    func testExplicitOnPersistsAcrossDefaultsInstanceAndSettingsEntry() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = VoiceRecognitionPreloadPolicy.primaryIdentity(method: "enhanced")
        VoiceRecognitionPreloadPolicy.setEnabled(true, primaryIdentity: route, defaults: defaults)
        defaults.synchronize()
        let relaunched = UserDefaults(suiteName: suite)!
        XCTAssertTrue(VoiceRecognitionPreloadPolicy.isEnabled(defaults: relaunched))
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.observePrimaryIdentity(route, defaults: relaunched), .unchanged)
        XCTAssertTrue(VoiceRecognitionPreloadPolicy.isEnabled(defaults: relaunched))
    }

    func testPrimaryRouteChangeResetsOnAndDoesNotAutoRestore() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = VoiceRecognitionPreloadPolicy.primaryIdentity(method: "automatic")
        let second = VoiceRecognitionPreloadPolicy.primaryIdentity(method: "openai", provider: "p1", profile: "f1")
        VoiceRecognitionPreloadPolicy.setEnabled(true, primaryIdentity: first, defaults: defaults)
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.observePrimaryIdentity(second, defaults: defaults), .reset)
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))
        VoiceRecognitionPreloadPolicy.setEnabled(true, primaryIdentity: second, defaults: defaults)
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.observePrimaryIdentity(first, defaults: defaults), .reset)
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))

        let providerA = VoiceRecognitionPreloadPolicy.primaryIdentity(method: "openai", provider: "p1", profile: "f1")
        let providerB = VoiceRecognitionPreloadPolicy.primaryIdentity(method: "openai", provider: "p2", profile: "f1")
        VoiceRecognitionPreloadPolicy.setEnabled(true, primaryIdentity: providerA, defaults: defaults)
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.observePrimaryIdentity(providerB, defaults: defaults), .reset)
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))
    }

    func testLanguageModelAndCredentialChangesDoNotReset() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let route = VoiceRecognitionPreloadPolicy.primaryIdentity(method: "enhanced")
        VoiceRecognitionPreloadPolicy.setEnabled(true, primaryIdentity: route, defaults: defaults)
        defaults.set("zh-CN", forKey: "org.floeagent.voice.recognitionLanguage")
        defaults.set("small", forKey: "voice.local.model.parameter")
        defaults.set(true, forKey: "voice.provider.credential.changed")
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.observePrimaryIdentity(route, defaults: defaults), .unchanged)
        XCTAssertTrue(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))
    }

    func testUnboundOnResetsAndSchedulingRequiresEveryGate() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        VoiceRecognitionPreloadPolicy.setEnabled(true, primaryIdentity: nil, defaults: defaults)
        XCTAssertTrue(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.observePrimaryIdentity(nil, defaults: defaults), .reset)
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults))

        XCTAssertFalse(VoiceRecognitionPreloadPolicy.shouldWarm(isEnabled: false, isForeground: true, isInstalled: true))
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.shouldWarm(isEnabled: true, isForeground: false, isInstalled: true))
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.shouldWarm(isEnabled: true, isForeground: true, isInstalled: false))
        XCTAssertFalse(VoiceRecognitionPreloadPolicy.shouldWarm(isEnabled: true, isForeground: true, isInstalled: true, isReady: false))
        XCTAssertTrue(VoiceRecognitionPreloadPolicy.shouldWarm(isEnabled: true, isForeground: true, isInstalled: true))
    }

    func testPrimaryIdentityIsStableAndTrimmed() {
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.primaryIdentity(method: " enhanced "),
                       "enhanced\u{1F}\u{1F}")
        XCTAssertEqual(VoiceRecognitionPreloadPolicy.primaryIdentity(method: "openai", provider: " p1 ", profile: " f1 "),
                       "openai\u{1F}p1\u{1F}f1")
    }
}
#endif
