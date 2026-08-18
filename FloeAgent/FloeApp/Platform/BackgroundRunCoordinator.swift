#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import FloePersistence

extension Notification.Name {
    static let floeOpenConversation = Notification.Name("org.floeagent.open-conversation")
}

/// App-lifetime owner for provider runs while views come and go. It writes
/// recovery points before suspension, requests real iOS continued processing,
/// and routes notification taps back to the durable task.
@MainActor
final class BackgroundRunCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private unowned let environment: AppEnvironment
    private var activeRuns: [UUID: UUID] = [:]
    private var notifiedApprovalRuns: Set<UUID> = []
    private var lease: BackgroundExecutionLease?
    private var refreshWork: Task<Void, Never>?
    private var processingWork: Task<Void, Never>?
    private var activeProcessingTaskID: UUID?
    @available(iOS 26.0, *)
    private var continuedTask: BGContinuedProcessingTask?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
        if #available(iOS 26.0, *) {
            BackgroundPolicyRegistry.shared.installContinuedTaskHandler { [weak self] task in
                self?.acceptContinuedTask(task)
            }
        }
        BackgroundPolicyRegistry.shared.installRefreshTaskHandler { [weak self] task in
            self?.acceptRefreshTask(task)
        }
        BackgroundPolicyRegistry.shared.installProcessingTaskHandler { [weak self] task in
            self?.acceptProcessingTask(task)
        }
        UNUserNotificationCenter.current().delegate = self
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    func didStart(conversationID: UUID, runID: UUID, title: String) {
        activeRuns[runID] = conversationID
        if #available(iOS 26.0, *) {
            updateContinuedTask(title: title, stage: "正在运行", progress: 5)
        }
        BackgroundPolicyRegistry.shared.requestContinuedProcessing()
        applyBackgroundExecutionPreference(runTitle: title)
    }

    func didFinish(runID: UUID, succeeded: Bool, message: String?) {
        guard let conversationID = activeRuns.removeValue(forKey: runID) else { return }
        notifiedApprovalRuns.remove(runID)
        Task { [weak self] in
            guard let self else { return }
            let policy = try? await SQLiteWorkspaceStore(database: environment.database)
                .taskPolicy(conversationID: conversationID)
            let shouldNotify = switch policy?.notificationPolicy {
            case .off: false
            case .critical: !succeeded
            case .terminal, .stages, nil: true
            }
            guard shouldNotify else { return }
            self.postNotification(
                identifier: "run.\(runID.uuidString)",
                conversationID: conversationID,
                title: succeeded ? "任务已完成" : "任务失败",
                body: message ?? (succeeded ? "Floe Agent 已完成任务。" : "打开任务查看并恢复。")
            )
        }
        if #available(iOS 26.0, *), activeRuns.isEmpty {
            finishContinuedTask(success: succeeded)
        }
        if activeRuns.isEmpty {
            tearDownBackgroundExecutionPreference()
        }
    }

    /// Applies the user's background-execution choice when a run starts.
    /// `standard` relies on the 30s lease + continued task (no extra UI);
    /// `pictureInPicture` starts the progress video; `screenShare` expects the
    /// user to have started broadcasting from the thread's share entry.
    private func applyBackgroundExecutionPreference(runTitle: String) {
        switch environment.settingsCenter.backgroundExecution {
        case .standard:
            break
        case .pictureInPicture:
            Task { [weak self] in
                await self?.environment.backgroundVideoService.begin(
                    title: runTitle,
                    initialProgress: "正在运行"
                )
            }
        case .screenShare:
            break
        }
    }

    private func tearDownBackgroundExecutionPreference() {
        environment.backgroundVideoService.stop()
    }

    func didRequireApproval(conversationID: UUID, runID: UUID, toolName: String) {
        guard notifiedApprovalRuns.insert(runID).inserted else { return }
        if #available(iOS 26.0, *) {
            updateContinuedTask(title: "Floe Agent", stage: "等待你的审批", progress: 60)
        }
        Task { [weak self] in
            guard let self else { return }
            let policy = try? await SQLiteWorkspaceStore(database: environment.database)
                .taskPolicy(conversationID: conversationID)
            guard policy?.notificationPolicy != .off,
                  policy?.notificationPolicy != .terminal else { return }
            self.postNotification(
                identifier: "approval.\(runID.uuidString)",
                conversationID: conversationID,
                title: "任务等待审批",
                body: "需要确认：\(toolName)"
            )
        }
    }

    private func postNotification(
        identifier: String,
        conversationID: UUID,
        title: String,
        body: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["conversationID": conversationID.uuidString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: identifier, content: content, trigger: nil
        ))
    }

    @available(iOS 26.0, *)
    private func acceptContinuedTask(_ task: BGContinuedProcessingTask) {
        continuedTask = task
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = activeRuns.isEmpty ? 100 : 5
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self else { return }
                await self.environment.conversationCenter.persistActiveRecoveryPoints()
                task?.setTaskCompleted(success: false)
                if self.continuedTask === task { self.continuedTask = nil }
            }
        }
        if activeRuns.isEmpty {
            finishContinuedTask(success: true)
        } else {
            task.updateTitle("Floe Agent", subtitle: "正在后台继续任务")
        }
    }

    @available(iOS 26.0, *)
    private func updateContinuedTask(title: String, stage: String, progress: Int64) {
        continuedTask?.updateTitle(title, subtitle: stage)
        continuedTask?.progress.completedUnitCount = min(95, max(1, progress))
    }

    @available(iOS 26.0, *)
    private func finishContinuedTask(success: Bool) {
        continuedTask?.progress.completedUnitCount = 100
        continuedTask?.setTaskCompleted(success: success)
        continuedTask = nil
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            lease = BackgroundPolicyRegistry.shared.beginShortCompletion(name: "Keep agent run active")
            Task { [weak self] in
                guard let self else { return }
                await self.environment.conversationCenter.persistActiveRecoveryPoints()
                // Provider-backed memory/profile work is not safe inside the
                // short pre-suspension lease. Schedule it as processing work.
                self.scheduleMemoryDeepSleep()
                // Hold the lease for the full 30s window while a run is still
                // streaming, so short replies finish before suspension instead
                // of being cut the instant the app backgrounds. The system's
                // expiration handler ends the lease when the window closes.
                if self.activeRuns.isEmpty {
                    self.lease?.release()
                    self.lease = nil
                }
            }
        case .active:
            lease?.release()
            lease = nil
            Task { [weak self] in
                await self?.environment.conversationCenter.resumeSafeRunsAfterForeground()
                await self?.runDueSchedules()
                // ④ catch-up dream on foreground resume (gated internally).
                await self?.environment.memoryDreamService.deepDream()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func acceptProcessingTask(_ task: BGProcessingTask) {
        processingWork?.cancel()
        let taskID = UUID()
        activeProcessingTaskID = taskID
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, self.activeProcessingTaskID == taskID else { return }
                self.activeProcessingTaskID = nil
                self.processingWork?.cancel()
                self.processingWork = nil
                task?.setTaskCompleted(success: false)
            }
        }
        processingWork = Task { [weak self, weak task] in
            guard let self else { return }
            // ③ deep sleep: regenerate profile/SOUL when due and distill
            // memory from the most recent conversation.
            await self.environment.memoryDreamService.deepDream()
            guard !Task.isCancelled, self.activeProcessingTaskID == taskID else { return }
            self.activeProcessingTaskID = nil
            task?.setTaskCompleted(success: true)
            self.processingWork = nil
        }
    }

    private func scheduleMemoryDeepSleep() {
        let request = BGProcessingTaskRequest(identifier: BackgroundTaskKind.processing.rawValue)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = true
        try? BGTaskScheduler.shared.submit(request)
    }

    private func acceptRefreshTask(_ task: BGAppRefreshTask) {
        refreshWork?.cancel()
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                self?.refreshWork?.cancel()
                task?.setTaskCompleted(success: false)
            }
        }
        refreshWork = Task { [weak self, weak task] in
            guard let self else { return }
            await self.runDueSchedules()
            let cancelled = Task.isCancelled
            task?.setTaskCompleted(success: !cancelled)
            self.refreshWork = nil
        }
    }

    func reconcileSchedulesAfterLaunch() async {
        await runDueSchedules()
    }

    private func runDueSchedules() async {
        let store = SQLiteTaskScheduleStore(database: environment.database)
        guard let due = try? await store.due(at: Date()) else { return }
        let center = environment.conversationCenter
        if let (provider, model) = center.providerAndModel(
            modelID: center.modelPreferences.defaultAgentModelID
        ) {
            for schedule in due where !Task.isCancelled {
                do {
                    _ = try await center.startTask(
                        goal: schedule.prompt,
                        title: schedule.title,
                        provider: provider,
                        model: model,
                        workspaceID: schedule.workspaceID
                    )
                    try await store.markStarted(id: schedule.id, at: Date())
                } catch {
                    continue
                }
            }
        }
        let allSchedules = (try? await store.schedules()) ?? []
        if let next = allSchedules.filter(\.isEnabled).compactMap(\.nextExpectedAt).min() {
            let earliest = max(next, Date().addingTimeInterval(due.isEmpty ? 60 : 15 * 60))
            BackgroundPolicyRegistry.shared.scheduleRefresh(earliest: earliest)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["conversationID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .floeOpenConversation,
                object: nil,
                userInfo: ["conversationID": id]
            )
        }
    }
}
#endif
