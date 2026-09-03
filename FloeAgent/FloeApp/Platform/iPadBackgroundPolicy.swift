// FloeApp — iPad background policy (multi scene).
// Per-scene accounting: one scene backgrounding is NOT the app
// backgrounding. Long connections stay up while any scene is active; the
// iPhone wrap-up runs only when every scene leaves .active. Pointer and
// keyboard commands (⌘W) affect scenes, never connection policy.

#if canImport(UIKit)
import UIKit
import BackgroundTasks
import FloeCore

@MainActor
public final class iPadBackgroundPolicy: PlatformBackgroundPolicy, @unchecked Sendable {

    /// sceneID → latest known phase.
    private var scenePhases: [String: PolicyScenePhase] = [:]
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

    @discardableResult
    public func requestContinuedProcessing(_ kind: BackgroundTaskKind) -> String? {
        // The initiating scene's window may already be closed; progress is
        // presented via Live Activity and the Runs list (GRDB polling),
        // never bound to a single scene.
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
                return nil
            }
            let request = ContinuedProcessingRequestFactory.make(
                identifier: identifier,
                title: "Floe Agent task",
                subtitle: "Continuing in the background"
            )
            do {
                try BGTaskScheduler.shared.submit(request)
                FloeLogger(category: .app).info(
                    "backgroundTaskSubmissionSucceeded kind=continued identifier=\(identifier)"
                )
                return identifier
            } catch {
                FloeLogger(category: .app).warning(
                    "backgroundTaskSubmissionFailed kind=continued error=\(error.localizedDescription)"
                )
                return nil
            }
        } else {
            let request = BGProcessingTaskRequest(identifier: BackgroundTaskKind.processing.rawValue)
            do {
                try BGTaskScheduler.shared.submit(request)
                return request.identifier
            } catch {
                return nil
            }
        }
    }

    public func cancelContinuedProcessingRequests(
        _ identifiers: Set<String>,
        discoverUntrackedRequests: Bool
    ) {
        for identifier in identifiers {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        guard discoverUntrackedRequests else { return }
        let prefix = BackgroundTaskKind.continued.submissionIdentifierPrefix
        BGTaskScheduler.shared.getPendingTaskRequests { requests in
            let candidateIdentifiers = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(prefix) }
            // Requests can outlive the process that submitted them. Discover
            // only Floe's continued namespace; never use cancelAllTaskRequests,
            // which would also remove refresh/media recovery work.
            Task { @MainActor in
                for identifier in candidateIdentifiers where
                    BackgroundPolicyRegistry.shared
                        .shouldCancelDiscoveredContinuedProcessingRequest(identifier) {
                    BGTaskScheduler.shared.cancel(
                        taskRequestWithIdentifier: identifier
                    )
                }
            }
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
