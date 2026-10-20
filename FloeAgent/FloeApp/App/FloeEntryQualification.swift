// FloeApp — DEBUG-only deterministic controls for the hosted actual App/Intent
// entry acceptance (S3-A). None of this exists in a Release build.
//
// A hosted test launches the real App with `FLOE_S3A_ENTRY_QUALIFICATION=1`.
// The ordinary scene `.task` parks BEFORE bootstrap, so the test can drive the
// actual legacy App Intents through a cold production readiness failure and a
// normal retry before any scene startup work has run. The test releases the
// barrier in `defer`, and the normal scene startup then joins the cached
// successful bootstrap.

#if DEBUG
import Foundation

/// Non-isolated launch-environment check shared by the scene call site and the
/// hosted test trait. The control state below is main-actor isolated.
enum FloeEntryQualificationSupport {
    static let launchEnvironmentKey = "FLOE_S3A_ENTRY_QUALIFICATION"

    static var isRequested: Bool {
        ProcessInfo.processInfo.environment[launchEnvironmentKey] == "1"
    }
}

@MainActor
enum FloeEntryQualification {
    /// Existing recovery copy; the injected fault needs no new user-facing
    /// English and no localization catalog change.
    static let injectedBootstrapFailure =
        "Durable storage is unavailable. Floe Agent is in recovery mode."

    private static var sceneBarrierReached = false
    private static var sceneBarrierReleased = false
    private static var sceneBarrierWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private static var sceneBootstrapReturns = 0
    private static var bootstrapFailureArmed = false

    /// Scene `.task` entry: hold the entire scene startup before bootstrap or
    /// any other follow-up when the qualification launch requested it.
    static func awaitSceneBootstrapBarrierIfRequested() async {
        guard FloeEntryQualificationSupport.isRequested else { return }
        sceneBarrierReached = true
        guard !sceneBarrierReleased else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if sceneBarrierReleased {
                continuation.resume()
            } else {
                sceneBarrierWaiters[UUID()] = continuation
            }
        }
    }

    /// Bounded test-side wait for the scene task to be parked. Returns false
    /// with a clear failure instead of hanging the hosted suite.
    static func waitForSceneBootstrapBarrier() async -> Bool {
        for _ in 0..<500 {
            if sceneBarrierReached { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return sceneBarrierReached
    }

    /// Idempotent release; safe on every test exit path.
    static func releaseSceneBootstrapBarrier() {
        sceneBarrierReleased = true
        let waiters = sceneBarrierWaiters
        sceneBarrierWaiters.removeAll()
        for waiter in waiters.values { waiter.resume() }
    }

    /// Called after the ordinary scene `.task` returns from `bootstrap()`.
    static func noteSceneBootstrapReturned() {
        guard FloeEntryQualificationSupport.isRequested else { return }
        sceneBootstrapReturns += 1
    }

    /// Proves the released scene task joined the cached successful bootstrap
    /// and did not start a duplicate launch body.
    static func waitForSceneBootstrapReturn() async -> Bool {
        for _ in 0..<500 {
            if sceneBootstrapReturns > 0 { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return sceneBootstrapReturns > 0
    }

    /// Arm exactly one injected cold-start failure. Inert unless the explicit
    /// qualification launch environment is present.
    static func armBootstrapFailureOnce() {
        guard FloeEntryQualificationSupport.isRequested else { return }
        bootstrapFailureArmed = true
    }

    /// Consume the armed fault once, at the very start of `performBootstrap`
    /// and before database/shared launch maintenance.
    static func consumeBootstrapFailureOnce() -> Bool {
        guard FloeEntryQualificationSupport.isRequested, bootstrapFailureArmed else {
            return false
        }
        bootstrapFailureArmed = false
        return true
    }
}
#endif
