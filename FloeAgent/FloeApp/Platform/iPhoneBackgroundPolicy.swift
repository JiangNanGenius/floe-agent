// FloeApp — iPhone background policy (single scene).
// supportsMultipleScenes=false on iPhone: scene phase == app phase.
// On .background: save RemoteRun output cursors + agent checkpoints,
// begin ≤30s completion window, suspend SSH/VNC, allow suspension.
// Resume reconnects helper-managed sessions via output cursor.

#if canImport(UIKit)
import UIKit
import BackgroundTasks

@MainActor
public final class iPhoneBackgroundPolicy: PlatformBackgroundPolicy, @unchecked Sendable {

    /// `BGTaskScheduler` rejects duplicate registrations with an Objective-C
    /// exception. More than one router may exist in previews or hosted tests,
    /// therefore registration must be process-wide rather than per instance.
    private static var didRegisterTasks = false

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
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in BackgroundPolicyRegistry.shared.handleRefreshTask(task) }
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
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in
                    BackgroundPolicyRegistry.shared.handleContinuedTask(task)
                }
            }
        }
    }

    public func scheduleRefresh(earliest: Date) {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskKind.refresh.rawValue)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    public func requestContinuedProcessing(_ kind: BackgroundTaskKind) {
        if #available(iOS 26.0, *), kind == .continued {
            let request = BGContinuedProcessingTaskRequest(
                identifier: kind.submissionIdentifier,
                title: "Floe Agent task",
                subtitle: "Continuing in the background"
            )
            try? BGTaskScheduler.shared.submit(request)
        } else {
            // Fallback: plain processing task.
            let request = BGProcessingTaskRequest(identifier: BackgroundTaskKind.processing.rawValue)
            try? BGTaskScheduler.shared.submit(request)
        }
    }

    public func beginShortCompletion(name: String) -> BackgroundExecutionLease {
        var identifier: UIBackgroundTaskIdentifier = .invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Expiration: end immediately (≤30s budget enforced by system).
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
        // Single scene: scene background == app background.
        switch phase {
        case .background:
            // M2 wiring: persist RemoteRun output cursors + agent
            // checkpoints, then beginShortCompletion and suspend SSH/VNC.
            break
        case .active, .inactive:
            break
        }
    }

    public func longLivedConnectionPolicy(for kind: ConnectionKind) -> ConnectionPolicy {
        switch kind {
        case .ssh, .vnc:
            return ConnectionPolicy(
                suspendOnSceneBackground: true,
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
