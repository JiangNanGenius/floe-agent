// FloeApp — iPad background policy (multi scene).
// Per-scene accounting: one scene backgrounding is NOT the app
// backgrounding. Long connections stay up while any scene is active; the
// iPhone wrap-up runs only when every scene leaves .active. Pointer and
// keyboard commands (⌘W) affect scenes, never connection policy.

#if canImport(UIKit)
import UIKit
import BackgroundTasks

@MainActor
public final class iPadBackgroundPolicy: PlatformBackgroundPolicy, @unchecked Sendable {

    /// `BGTaskScheduler` permits each identifier to be registered only once
    /// per process. SwiftUI previews, hosted unit tests, and scene recovery can
    /// legitimately construct more than one router/policy instance, so keep
    /// registration process-wide and idempotent.
    private static var didRegisterTasks = false

    /// sceneID → latest known phase.
    private var scenePhases: [String: PolicyScenePhase] = [:]
    private var expirationHandlers: [String: UIBackgroundTaskIdentifier] = [:]
    private let lock = NSLock()

    public init() {}

    public func registerTasks() {
        guard !Self.didRegisterTasks else { return }
        Self.didRegisterTasks = true
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskKind.refresh.rawValue,
            using: nil
        ) { task in
            task.setTaskCompleted(success: true)
        }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: BackgroundTaskKind.processing.rawValue,
            using: nil
        ) { task in
            task.setTaskCompleted(success: true)
        }
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(
                forTaskWithIdentifier: BackgroundTaskKind.continued.rawValue,
                using: nil
            ) { task in
                guard task is BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                task.setTaskCompleted(success: true)
            }
        }
    }

    public func scheduleRefresh(earliest: Date) {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskKind.refresh.rawValue)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    public func requestContinuedProcessing(_ kind: BackgroundTaskKind) {
        // The initiating scene's window may already be closed; progress is
        // presented via Live Activity and the Runs list (GRDB polling),
        // never bound to a single scene.
        if #available(iOS 26.0, *), kind == .continued {
            let request = BGContinuedProcessingTaskRequest(
                identifier: kind.rawValue,
                title: "Floe Agent task",
                subtitle: "Continuing in the background"
            )
            try? BGTaskScheduler.shared.submit(request)
        } else {
            let request = BGProcessingTaskRequest(identifier: BackgroundTaskKind.processing.rawValue)
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    public func beginShortCompletion(name: String) -> BackgroundExecutionLease {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.endTask(named: name) }
        }
        lock.lock()
        expirationHandlers[name] = identifier
        lock.unlock()
        return BackgroundExecutionLease(
            name: name,
            expiresAt: Date().addingTimeInterval(30)
        ) { [weak self] in
            self?.endTask(named: name)
        }
    }

    public func handleScenePhase(_ phase: PolicyScenePhase, sceneID: String) {
        lock.lock()
        scenePhases[sceneID] = phase
        let anyActive = scenePhases.values.contains(.active)
        let anyForeground = scenePhases.values.contains { $0 != .background }
        lock.unlock()

        if phase == .background && !anyActive && !anyForeground {
            // Every scene backgrounded == app backgrounded: run the
            // iPhone-style wrap-up (cursor save, checkpoint, ≤30s window).
            // M2 wiring lands with the runs/SSH modules.
        }
    }

    public func longLivedConnectionPolicy(for kind: ConnectionKind) -> ConnectionPolicy {
        switch kind {
        case .ssh, .vnc:
            // Connections stay alive while ANY scene is active; they do not
            // follow the owning scene into the background.
            return ConnectionPolicy(
                suspendOnSceneBackground: false,
                suspendOnAppBackground: true,
                resumeViaCursor: true
            )
        case .providerStream:
            return ConnectionPolicy(
                suspendOnSceneBackground: false,
                suspendOnAppBackground: true,
                resumeViaCursor: false
            )
        }
    }

    private func endTask(named name: String) {
        lock.lock()
        let identifier = expirationHandlers.removeValue(forKey: name)
        lock.unlock()
        if let identifier, identifier != .invalid {
            UIApplication.shared.endBackgroundTask(identifier)
        }
    }
}
#endif
