import Foundation
import UIKit
import BridgeCore

/// Service-owned process/scene liveness recorder.
///
/// It is started once from the app delegate and is not owned by a view. The
/// main-run-loop timer records MainActor/RunLoop service; the independent
/// dispatch timer records that the process itself still runs. Both write a
/// small bounded file that the read-only status surfaces interpret as
/// current/stale/missing/unknown.
@MainActor
final class BridgeLivenessMonitor {
    static let shared = BridgeLivenessMonitor()

    private let store = BridgeLivenessStore()
    private var mainTimer: Timer?
    private var dispatchQueue: DispatchQueue?
    private var dispatchTimer: DispatchSourceTimer?
    private var started = false
    private var protectedDataObservers: [NSObjectProtocol] = []

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        observeProtectedData()
        store.recordTransition(
            source: "app",
            name: "liveness-monitor-started",
            applicationState: appStateName(),
            sceneState: sceneStateName(nil)
        )
        store.recordProtectedData(
            available: UIApplication.shared.isProtectedDataAvailable,
            initial: true,
            event: nil,
            applicationState: appStateName(),
            sceneState: sceneStateName(nil)
        )
        recordMainBeat()

        let timer = Timer(
            timeInterval: BridgeLivenessPolicy.mainBeatIntervalSeconds,
            repeats: true
        ) { [weak self] _ in
            // The timer is scheduled on the main run loop; this assertion makes
            // the main-thread contract explicit instead of reading UIKit from
            // an arbitrary queue.
            MainActor.assumeIsolated {
                self?.recordMainBeat()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        mainTimer = timer

        let queue = DispatchQueue(
            label: "org.floeagent.iosbridge.liveness.dispatch",
            qos: .utility
        )
        let dispatchTimer = DispatchSource.makeTimerSource(queue: queue)
        dispatchTimer.schedule(
            deadline: .now(),
            repeating: BridgeLivenessPolicy.dispatchBeatIntervalSeconds,
            leeway: .milliseconds(200)
        )
        let store = self.store
        // The legacy DispatchSource callback type can inherit this method's
        // MainActor isolation. Give the callback an explicitly Sendable,
        // nonisolated function type before erasing it to the dispatch handler.
        let heartbeat: @Sendable () -> Void = {
            store.recordDispatchBeat()
        }
        dispatchTimer.setEventHandler(handler: heartbeat)
        dispatchTimer.resume()
        dispatchQueue = queue
        self.dispatchTimer = dispatchTimer
    }

    /// UIKit's protected-data notifications are an observable protection-state
    /// signal. They are not a definitive lock-state or causal claim; the event
    /// name and the boolean read at callback time are recorded independently.
    private func observeProtectedData() {
        let center = NotificationCenter.default
        protectedDataObservers.append(center.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordProtectedDataEvent("did-become-available")
            }
        })
        protectedDataObservers.append(center.addObserver(
            forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordProtectedDataEvent("will-become-unavailable")
            }
        })
    }

    private func recordProtectedDataEvent(_ event: String) {
        store.recordProtectedData(
            available: UIApplication.shared.isProtectedDataAvailable,
            initial: false,
            event: event,
            applicationState: appStateName(),
            sceneState: sceneStateName(nil)
        )
    }

    func recordAppTransition(_ name: String) {
        store.recordTransition(
            source: "app",
            name: name,
            applicationState: appStateName(),
            sceneState: sceneStateName(nil)
        )
    }

    func recordSceneTransition(_ name: String, scene: UIScene) {
        store.recordTransition(
            source: "scene",
            name: name,
            applicationState: appStateName(),
            sceneState: sceneStateName(scene)
        )
    }

    private func recordMainBeat() {
        store.recordMainBeat(
            applicationState: appStateName(),
            sceneState: sceneStateName(nil),
            protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
        )
    }

    private func appStateName() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    private func sceneStateName(_ scene: UIScene?) -> String {
        if let scene { return activationName(scene.activationState) }
        let states = UIApplication.shared.connectedScenes.map { $0.activationState }
        if states.isEmpty { return "none" }
        if states.contains(.foregroundActive) { return "foregroundActive" }
        if states.contains(.foregroundInactive) { return "foregroundInactive" }
        if states.contains(.background) { return "background" }
        return "unattached"
    }

    private func activationName(_ state: UIScene.ActivationState) -> String {
        switch state {
        case .foregroundActive: return "foregroundActive"
        case .foregroundInactive: return "foregroundInactive"
        case .background: return "background"
        case .unattached: return "unattached"
        @unknown default: return "unknown"
        }
    }
}

/// Thread-safe bounded store for the two beats and the scene/app transition
/// history. Writes are serialized under the lock so an older main-beat payload
/// cannot overwrite a newer dispatch-beat payload.
private final class BridgeLivenessStore: @unchecked Sendable {
    private let lock = NSLock()
    private let processIdentifier = Int32(ProcessInfo.processInfo.processIdentifier)
    private let startedAt = BridgeClock.timestamp()

    private var sequence: UInt64 = 0
    private var mainCount: UInt64 = 0
    private var mainLastAt: String?
    private var dispatchCount: UInt64 = 0
    private var dispatchLastAt: String?
    private var applicationState = "unknown"
    private var sceneState = "unknown"
    private var stateObservedAt: String?
    private var transitions = BridgeLivenessTransitionLog()
    private var protectedDataInitialAvailable: Bool?
    private var protectedDataAvailable: Bool?
    private var protectedDataObservedAt: String?
    private var protectedDataLastEvent: String?
    private var protectedDataLastEventAt: String?
    private var protectedDataDidBecomeAvailableCount: UInt64 = 0
    private var protectedDataWillBecomeUnavailableCount: UInt64 = 0

    func recordMainBeat(
        applicationState: String,
        sceneState: String,
        protectedDataAvailable: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        mainCount &+= 1
        let now = BridgeClock.timestamp()
        mainLastAt = now
        self.applicationState = applicationState
        self.sceneState = sceneState
        stateObservedAt = now
        self.protectedDataAvailable = protectedDataAvailable
        protectedDataObservedAt = now
        writeLocked()
    }

    func recordProtectedData(
        available: Bool,
        initial: Bool,
        event: String?,
        applicationState: String,
        sceneState: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        if initial {
            protectedDataInitialAvailable = available
        }
        protectedDataAvailable = available
        let now = BridgeClock.timestamp()
        protectedDataObservedAt = now
        self.applicationState = applicationState
        self.sceneState = sceneState
        stateObservedAt = now
        if let event {
            protectedDataLastEvent = event
            protectedDataLastEventAt = now
            switch event {
            case "did-become-available":
                protectedDataDidBecomeAvailableCount &+= 1
            case "will-become-unavailable":
                protectedDataWillBecomeUnavailableCount &+= 1
            default:
                break
            }
            sequence &+= 1
            transitions.append(BridgeLivenessTransition(
                sequence: sequence,
                at: now,
                processIdentifier: processIdentifier,
                source: "protected-data",
                name: event,
                applicationState: applicationState,
                sceneState: sceneState
            ))
        }
        writeLocked()
    }

    func recordDispatchBeat() {
        lock.lock()
        defer { lock.unlock() }
        dispatchCount &+= 1
        dispatchLastAt = BridgeClock.timestamp()
        writeLocked()
    }

    func recordTransition(
        source: String,
        name: String,
        applicationState: String,
        sceneState: String
    ) {
        lock.lock()
        defer { lock.unlock() }
        sequence &+= 1
        let now = BridgeClock.timestamp()
        transitions.append(BridgeLivenessTransition(
            sequence: sequence,
            at: now,
            processIdentifier: processIdentifier,
            source: source,
            name: name,
            applicationState: applicationState,
            sceneState: sceneState
        ))
        self.applicationState = applicationState
        self.sceneState = sceneState
        stateObservedAt = now
        writeLocked()
    }

    private func writeLocked() {
        var mainBeat: [String: Any] = [
            "count": mainCount,
            "processIdentifier": processIdentifier,
            "source": "main-runloop-timer",
        ]
        if let mainLastAt { mainBeat["lastBeatAt"] = mainLastAt }
        var dispatchBeat: [String: Any] = [
            "count": dispatchCount,
            "processIdentifier": processIdentifier,
            "source": "process-liveness-dispatch-timer",
        ]
        if let dispatchLastAt { dispatchBeat["lastBeatAt"] = dispatchLastAt }

        var protectedData: [String: Any] = [
            "processIdentifier": processIdentifier,
            "didBecomeAvailableCount": protectedDataDidBecomeAvailableCount,
            "willBecomeUnavailableCount": protectedDataWillBecomeUnavailableCount,
            "source": "UIApplication.isProtectedDataAvailable + protected-data notifications",
        ]
        if let protectedDataInitialAvailable {
            protectedData["initialAvailable"] = protectedDataInitialAvailable
        }
        if let protectedDataAvailable {
            protectedData["currentAvailable"] = protectedDataAvailable
        }
        if let protectedDataObservedAt {
            protectedData["observedAt"] = protectedDataObservedAt
        }
        if let protectedDataLastEvent {
            protectedData["lastEvent"] = protectedDataLastEvent
        }
        if let protectedDataLastEventAt {
            protectedData["lastEventAt"] = protectedDataLastEventAt
        }

        var payload: [String: Any] = [
            "schema": BridgeLivenessPolicy.schema,
            "processIdentifier": processIdentifier,
            "startedAt": startedAt,
            "applicationState": applicationState,
            "sceneState": sceneState,
            "mainThreadBeat": mainBeat,
            "dispatchBeat": dispatchBeat,
            "protectedData": protectedData,
            "transitions": transitions.dictionaries,
            "updatedAt": BridgeClock.timestamp(),
        ]
        if let stateObservedAt { payload["stateObservedAt"] = stateObservedAt }
        BridgeAtomicFile.writeJSON(payload, to: BridgePaths.livenessFile)
    }
}
