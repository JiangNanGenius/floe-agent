// FloeApp — iPhone background policy (single scene).
// supportsMultipleScenes=false on iPhone: scene phase == app phase.
// On .background: save RemoteRun output cursors + agent checkpoints,
// begin ≤30s completion window, suspend SSH/VNC, allow suspension.
// Resume reconnects helper-managed sessions via output cursor.

#if canImport(UIKit)
import UIKit
import BackgroundTasks
import FloeCore

@MainActor
public final class iPhoneBackgroundPolicy: PlatformBackgroundPolicy, @unchecked Sendable {

    private var expirationHandlers: [String: UIBackgroundTaskIdentifier] = [:]
    private let lock = NSLock()

    public init() {}

    public func registerTasks() {
        _ = BackgroundTaskRegistrar.register(
            identifier: BackgroundTaskKind.refresh.rawValue
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in BackgroundPolicyRegistry.shared.handleRefreshTask(task) }
        }
        _ = BackgroundTaskRegistrar.register(
            identifier: BackgroundTaskKind.processing.rawValue
        ) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in BackgroundPolicyRegistry.shared.handleProcessingTask(task) }
        }
        _ = BackgroundTaskRegistrar.register(identifier: BackgroundTaskKind.mediaRefresh.rawValue) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false); return
            }
            Task { @MainActor in BackgroundPolicyRegistry.shared.handleMediaRefreshTask(task) }
        }
        _ = BackgroundTaskRegistrar.register(identifier: BackgroundTaskKind.mediaProcessing.rawValue) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false); return
            }
            Task { @MainActor in BackgroundPolicyRegistry.shared.handleMediaProcessingTask(task) }
        }
    }

    public func scheduleRefresh(earliest: Date) {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskKind.refresh.rawValue)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    public func scheduleMediaRefresh(earliest: Date) {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundTaskKind.mediaRefresh.rawValue)
        request.earliestBeginDate = earliest
        try? BGTaskScheduler.shared.submit(request)
    }

    public func scheduleMediaProcessing(earliest: Date) {
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskKind.mediaProcessing.rawValue)
        request.earliestBeginDate = earliest
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    public func requestContinuedProcessing(_ kind: BackgroundTaskKind) {
        if #available(iOS 26.0, *), kind == .continued {
            let identifier = kind.submissionIdentifier
            let didRegister = BackgroundTaskRegistrar.register(identifier: identifier) { task in
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                Task { @MainActor in
                    BackgroundPolicyRegistry.shared.handleContinuedTask(task)
                }
            }
            guard didRegister else {
                FloeLogger(category: .app).error(
                    "backgroundTaskRegistrationFailed kind=continued"
                )
                return
            }
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: "Floe Agent task",
                subtitle: "Continuing in the background"
            )
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                FloeLogger(category: .app).warning(
                    "backgroundTaskSubmissionFailed kind=continued error=\(error.localizedDescription)"
                )
            }
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
