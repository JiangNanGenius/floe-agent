#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import FloeCore
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
    private struct ActiveRun {
        let conversationID: UUID
        let title: String
        var stage: String = "正在运行"
        var progress: Int64 = 5
    }
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var surfacedRunID: UUID?
    private var retainedPausedRun: (id: UUID, run: ActiveRun)?
    private var isAppInBackground = false
    private var pipSuppressedForCurrentBatch = false
    private var notifiedApprovalRuns: Set<UUID> = []
    private var lease: BackgroundExecutionLease?
    private var refreshWork: Task<Void, Never>?
    private var processingWork: Task<Void, Never>?
    private var pipCarouselTask: Task<Void, Never>?
    /// SwiftUI reports lifecycle independently for every window. Reconcile
    /// those reports before touching the app-wide PiP surface so a secondary
    /// scene cannot repeatedly start/retract it while another scene is active.
    private var scenePhases: [String: ScenePhase] = [:]
    private var effectiveScenePhase: ScenePhase = .active
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
    }

    func didStart(conversationID: UUID, runID: UUID, title: String) {
        // Ask for notification permission in direct response to starting the
        // first task, never during a cold app launch. This keeps onboarding,
        // App Intents discovery and settings inspection free of an unrelated
        // system prompt.
        if activeRuns.isEmpty {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
        // A newly-created task starts a new eligibility window after a user
        // manually dismissed PiP or stopped the previous broadcast.
        pipSuppressedForCurrentBatch = false
        retainedPausedRun = nil
        activeRuns[runID] = ActiveRun(conversationID: conversationID, title: title)
        FloeLogger(category: .app).info(
            "backgroundRunStarted run=\(runID.uuidString) conversation=\(conversationID.uuidString) preference=\(environment.settingsCenter.backgroundExecution.rawValue) activeRuns=\(activeRuns.count)"
        )
        if #available(iOS 26.0, *) {
            updateContinuedTask(title: title, stage: "正在运行", progress: 5)
        }
        BackgroundPolicyRegistry.shared.requestContinuedProcessing()
        applyBackgroundExecutionPreference(
            runID: runID,
            conversationID: conversationID,
            runTitle: title
        )
    }

    /// Pushes a progress stage update to the active background surface (the
    /// continued task's Live Activity subtitle, and the PiP progress video).
    func didUpdateProgress(runID: UUID, stage: String, progress: Int64) {
        guard var active = activeRuns[runID] else { return }
        active.stage = stage
        active.progress = progress
        activeRuns[runID] = active
        if #available(iOS 26.0, *) {
            updateContinuedTask(title: "Floe Agent", stage: stage, progress: progress)
        }
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: stage)
        }
    }

    /// Keeps a durable, user-resumable run visible without turning the
    /// checkpoint into a failure notification or tearing down PiP. Browser
    /// takeover and other explicit user-action boundaries use this path.
    func didSuspend(runID: UUID, message: String) {
        guard var active = activeRuns[runID] else { return }
        active.stage = message
        active.progress = max(active.progress, 60)
        activeRuns[runID] = active
        retainedPausedRun = (runID, active)
        if #available(iOS 26.0, *) {
            updateContinuedTask(title: active.title, stage: message, progress: active.progress)
        }
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(title: active.title, progress: message)
        }
        FloeLogger(category: .app).info(
            "backgroundRunSuspended run=\(runID.uuidString) message=\(message) activeRuns=\(activeRuns.count)"
        )
    }

    func didFinish(runID: UUID, succeeded: Bool, message: String?) {
        guard let finished = activeRuns.removeValue(forKey: runID) else { return }
        FloeLogger(category: .app).info(
            "backgroundRunFinished run=\(runID.uuidString) succeeded=\(succeeded) remainingRuns=\(activeRuns.count)"
        )
        let conversationID = finished.conversationID
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
        if surfacedRunID == runID, !activeRuns.isEmpty {
            surfacedRunID = nil
            resumeBackgroundSurfaceIfNeeded()
        }
        if activeRuns.isEmpty, succeeded {
            retainedPausedRun = nil
            tearDownBackgroundExecutionPreference()
        } else if activeRuns.isEmpty {
            // A failed/checkpointed task is paused work, not completed work.
            // Keep the user-owned PiP/screen-share surface alive so reopening
            // the task offers a recovery path instead of silently disappearing.
            surfacedRunID = runID
            retainedPausedRun = (runID, finished)
            environment.backgroundVideoService.update(
                title: finished.title,
                progress: "任务已暂停，打开 Floe 可继续"
            )
            FloeLogger(category: .app).info(
                "backgroundSurfaceRetained reason=unfinishedRun run=\(runID.uuidString)"
            )
        }
    }

    /// A manual/system PiP close is respected for the current active batch.
    /// A later newly-started task will call `didStart` and request PiP again.
    func didClosePictureInPicture() {
        surfacedRunID = nil
        // Respect the close while the app stays in the background. Once the
        // user returns to Floe, the next departure is a fresh explicit PiP
        // attempt and must not remain permanently suppressed.
        pipSuppressedForCurrentBatch = isAppInBackground
        FloeLogger(category: .app).info(
            "pictureInPictureClosedByUser activeRuns=\(activeRuns.count)"
        )
        if !isAppInBackground {
            // The AVKit stop callback has already released the old controller.
            // Rebuild while a key window exists so the next app departure is
            // not stuck with no prepared source.
            prepareBackgroundSurfaceIfNeeded()
        }
    }

    /// Applies the user's background-execution choice when a run starts.
    /// `standard` relies on the 30s lease + continued task (no extra UI);
    /// Both visual modes prepare a real task-progress PiP. It is started only
    /// after the scene enters background. Screen-share mode
    /// additionally asks the matching thread to present ReplayKit's system
    /// consent flow as soon as the task starts.
    private func applyBackgroundExecutionPreference(
        runID: UUID,
        conversationID: UUID,
        runTitle: String
    ) {
        switch environment.settingsCenter.backgroundExecution {
        case .standard:
            FloeLogger(category: .app).info(
                "backgroundSurfaceSkipped run=\(runID.uuidString) reason=standardPreference"
            )
            break
        case .pictureInPicture:
            FloeLogger(category: .app).info(
                "backgroundSurfaceRequested run=\(runID.uuidString) mode=pictureInPicture"
            )
            surfacedRunID = runID
            if environment.backgroundVideoService.isPiPPrepared {
                environment.backgroundVideoService.update(
                    title: runTitle,
                    progress: "正在运行"
                )
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    await self.environment.backgroundVideoService.begin(
                        title: runTitle,
                        initialProgress: "正在运行",
                        startImmediately: self.isAppInBackground
                    )
                }
            }
        case .screenShare:
            FloeLogger(category: .app).info(
                "backgroundSurfaceRequested run=\(runID.uuidString) mode=screenShare sharing=\(environment.screenShareCenter.isSharing)"
            )
            surfacedRunID = runID
            if environment.backgroundVideoService.isPiPPrepared {
                environment.backgroundVideoService.update(
                    title: runTitle,
                    progress: environment.screenShareCenter.isSharing
                        ? "正在共享屏幕" : "任务正在运行"
                )
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    await self.environment.backgroundVideoService.begin(
                        title: runTitle,
                        initialProgress: "任务正在运行",
                        startImmediately: self.isAppInBackground
                    )
                }
            }
            if !environment.screenShareCenter.isSharing {
                environment.screenShareCenter.requestBroadcast(for: conversationID)
            }
        }
    }

    private func tearDownBackgroundExecutionPreference() {
        FloeLogger(category: .app).info("backgroundSurfaceStopped reason=allRunsFinished")
        surfacedRunID = nil
        pipCarouselTask?.cancel()
        pipCarouselTask = nil
        environment.backgroundVideoService.stop()
        if environment.screenShareCenter.isSharing
            || environment.screenShareCenter.isWaitingForBroadcast {
            environment.screenShareCenter.stopSharing()
        }
    }

    /// If the run currently represented by PiP finishes while another run is
    /// still active, move the surface to a real remaining run instead of
    /// leaving the completed title frozen indefinitely.
    private func resumeBackgroundSurfaceIfNeeded() {
        guard isAppInBackground,
              !pipSuppressedForCurrentBatch,
              environment.settingsCenter.backgroundExecution != .standard else { return }
        let candidate = activeRuns.first.map { (id: $0.key, run: $0.value) }
            ?? retainedPausedRun
        guard let (runID, run) = candidate else { return }
        surfacedRunID = runID
        startPiPCarousel()
        if environment.backgroundVideoService.isPiPActive {
            environment.backgroundVideoService.update(
                title: run.title,
                progress: "正在运行"
            )
            return
        }
        if environment.backgroundVideoService.isPiPPrepared {
            environment.backgroundVideoService.startPreparedPictureInPicture()
            return
        }
        if environment.backgroundVideoService.isPreparingPiP {
            // The foreground preparation already owns the source view and
            // encoder. Mark it to start when ready; beginning again here would
            // cancel it after the scene has lost its attachable key window.
            environment.backgroundVideoService.startPreparedPictureInPicture()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.environment.backgroundVideoService.begin(
                title: run.title,
                initialProgress: "正在运行",
                startImmediately: true
            )
        }
    }

    /// Keep a multi-task PiP useful without cramming several unreadable rows
    /// into a phone-sized video. Cycle the real active tasks and show the
    /// current index, stage and progress. A single task remains stable.
    private func startPiPCarousel() {
        guard pipCarouselTask == nil else { return }
        pipCarouselTask = Task { [weak self] in
            var cursor = 0
            while !Task.isCancelled {
                guard let self, self.isAppInBackground else { return }
                let runs = self.activeRuns.sorted { $0.key.uuidString < $1.key.uuidString }
                let candidates = runs.isEmpty
                    ? self.retainedPausedRun.map { [($0.id, $0.run)] } ?? []
                    : runs
                guard !candidates.isEmpty else { return }
                let item = candidates[cursor % candidates.count]
                self.surfacedRunID = item.0
                let prefix = candidates.count > 1
                    ? "\((cursor % candidates.count) + 1)/\(candidates.count) · " : ""
                self.environment.backgroundVideoService.update(
                    title: item.1.title,
                    progress: "\(prefix)\(item.1.stage) · \(item.1.progress)%"
                )
                cursor += 1
                try? await Task.sleep(for: .seconds(candidates.count > 1 ? 4 : 12))
            }
        }
    }

    func didRequireApproval(conversationID: UUID, runID: UUID, toolName: String) {
        guard notifiedApprovalRuns.insert(runID).inserted else { return }
        if #available(iOS 26.0, *) {
            updateContinuedTask(title: "Floe Agent", stage: "等待你的审批", progress: 60)
        }
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: "等待你的审批")
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

    func handleScenePhase(_ phase: ScenePhase, sceneID: String) {
        scenePhases[sceneID] = phase
        let effective: ScenePhase
        if scenePhases.values.contains(.active) {
            effective = .active
        } else if scenePhases.values.contains(.inactive) {
            effective = .inactive
        } else {
            effective = .background
        }
        guard effective != effectiveScenePhase else { return }
        effectiveScenePhase = effective
        FloeLogger(category: .app).info(
            "scenePhaseReconciled scene=\(sceneID) reported=\(String(describing: phase)) effective=\(String(describing: effective)) scenes=\(scenePhases.count)"
        )
        switch effective {
        case .background:
            isAppInBackground = true
            resumeBackgroundSurfaceIfNeeded()
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
            isAppInBackground = false
            pipSuppressedForCurrentBatch = false
            pipCarouselTask?.cancel()
            pipCarouselTask = nil
            environment.backgroundVideoService.retractForForeground()
            prepareBackgroundSurfaceIfNeeded()
            lease?.release()
            lease = nil
            Task { [weak self] in
                await self?.environment.conversationCenter.resumeSafeRunsAfterForeground()
                await self?.runDueSchedules()
                // ④ catch-up dream on foreground resume (gated internally).
                await self?.environment.memoryDreamService.deepDream()
            }
        case .inactive:
            // iPadOS may move directly through inactive while automatic PiP
            // begins and delay/omit the SwiftUI background callback. Request
            // the controller during this transition while the source view is
            // still attached to a foreground window. If video synthesis is
            // still running, the service records the deferred start instead
            // of losing this only reliable lifecycle signal.
            if !pipSuppressedForCurrentBatch,
               !activeRuns.isEmpty,
               environment.settingsCenter.backgroundExecution != .standard {
                environment.backgroundVideoService.startPreparedPictureInPicture()
            }
        @unknown default:
            break
        }
    }

    /// A user/system close destroys AVKit's controller. Rebuild it while a
    /// foreground key window exists so the next background transition can
    /// start immediately; attempting this only after entering background
    /// cannot attach the required inline player layer.
    private func prepareBackgroundSurfaceIfNeeded() {
        guard environment.settingsCenter.backgroundExecution != .standard,
              !environment.backgroundVideoService.isPiPPrepared,
              !environment.backgroundVideoService.isPreparingPiP else { return }
        let candidate = activeRuns.first.map { (id: $0.key, run: $0.value) }
            ?? retainedPausedRun
        guard let (runID, run) = candidate else { return }
        surfacedRunID = runID
        Task { [weak self] in
            guard let self else { return }
            await self.environment.backgroundVideoService.begin(
                title: run.title,
                initialProgress: "\(run.stage) · \(run.progress)%",
                startImmediately: false
            )
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
