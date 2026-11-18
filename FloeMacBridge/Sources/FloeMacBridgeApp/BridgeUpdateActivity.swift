#if os(macOS)
import Foundation
import FloeMacBridgeProtocol

/// One synchronous admission point shared by service, PTY jobs and reply
/// delivery. No actor hop occurs between observing idle and closing admission.
final class BridgeUpdateActivity: @unchecked Sendable {
    enum Kind: Sendable { case request, job, transfer, consent, maintenance }
    struct Lease: Hashable, Sendable { fileprivate let id: UUID }
    struct Installation: Hashable, Sendable { fileprivate let id: UUID }
    private let lock = NSLock()
    private var active: [Lease: Kind] = [:]
    private var installation: Installation?
    private var admissionClosedReason: String?

    func begin(_ kind: Kind) throws -> Lease {
        try lock.withLock {
            guard installation == nil else {
                throw BridgeFailure.remote(admissionClosedReason
                    ?? String(localized: "Floe Bridge is installing an update. Reconnect shortly."))
            }
            let lease = Lease(id: UUID()); active[lease] = kind; return lease
        }
    }
    func finish(_ lease: Lease) { lock.withLock { _ = active.removeValue(forKey: lease) } }
    /// The same atomic idle check used by update installation. A shutdown uses
    /// it too: once this returns a token, no request, job, transfer or consent
    /// can be admitted, and the caller retains the token through listener
    /// closure and process exit.
    func reserveInstallationIfIdle(reason: String = String(localized: "Floe Bridge is installing an update. Reconnect shortly.")) -> Installation? {
        lock.withLock {
            guard installation == nil, active.isEmpty else { return nil }
            let token = Installation(id: UUID())
            installation = token
            admissionClosedReason = reason
            return token
        }
    }
    func owns(_ token: Installation) -> Bool { lock.withLock { installation == token } }
    func resume(after token: Installation) {
        lock.withLock {
            if installation == token {
                installation = nil
                admissionClosedReason = nil
            }
        }
    }
    var activityCount: Int { lock.withLock { active.count } }
    var isAdmissionClosed: Bool { lock.withLock { installation != nil } }
}

/// Main-actor callbacks remain owned until Sparkle either installs or aborts.
/// A reserved process exit remains closed for the life of the process.
/// A handler is always invoked after its delegate method has returned YES.
@MainActor
final class BridgeUpdateInstallation {
    let activity: BridgeUpdateActivity
    private var reservation: BridgeUpdateActivity.Installation?
    private var pending: (() -> Void)?
    private var generation = UUID()
    private var waiter: Task<Void, Never>?
    private let polling: Bool
    private var reserveInstallation: @Sendable () -> BridgeUpdateActivity.Installation?
    var stateChanged: (() -> Void)?
    private(set) var waitingForIdle = false

    init(activity: BridgeUpdateActivity, polling: Bool = true) {
        self.activity = activity; self.polling = polling
        self.reserveInstallation = { activity.reserveInstallationIfIdle() }
    }
    func useServiceAdmission(_ service: BridgeService) {
        precondition(service.updateActivity === activity)
        reserveInstallation = { service.reserveUpdateInstallationIfIdle() }
    }
    func postpone(_ handler: @escaping () -> Void) {
        waiter?.cancel()
        generation = UUID(); pending = handler
        let expected = generation
        waitingForIdle = true; stateChanged?()
        guard polling, generation == expected, pending != nil else { return }
        waiter = Task { @MainActor [weak self] in
            // Prevent re-entering Sparkle before its delegate returns YES.
            await Task.yield()
            while !Task.isCancelled {
                guard let self, self.generation == expected else { return }
                if self.tryPendingInstallation() { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
    @discardableResult
    func tryPendingInstallation() -> Bool {
        guard let callback = pending else { return false }
        guard reserveForTerminationIfIdle() else { return false }
        let expected = generation
        pending = nil; waitingForIdle = false
        callback()
        if generation == expected { stateChanged?() }
        // Hold admission closed through Sparkle's termination/relaunch. A
        // second Sparkle callback for this installation reuses the same token.
        return true
    }
    func reserveForTerminationIfIdle() -> Bool {
        if let reservation, activity.owns(reservation) { return true }
        guard let token = reserveInstallation() else { return false }
        reservation = token; return true
    }
    func updaterDidFail() {
        generation = UUID(); waiter?.cancel(); waiter = nil; pending = nil
        // Sparkle's error callbacks do not identify the installation that
        // acquired the exit reservation. After handoff (or an accepted quit),
        // opening admission here could race an installer still replacing us.
        waitingForIdle = false; stateChanged?()
    }
}
#endif
