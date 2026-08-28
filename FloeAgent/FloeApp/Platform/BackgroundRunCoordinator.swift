#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import CryptoKit
import FloeCore
import FloePersistence
import FloeProviders

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
    private var mediaRefreshWork: Task<Void, Never>?
    private var mediaProcessingWork: Task<Void, Never>?
    private var pipCarouselTask: Task<Void, Never>?
    /// SwiftUI reports lifecycle independently for every window. Reconcile
    /// those reports before touching the app-wide PiP surface so a secondary
    /// scene cannot repeatedly start/retract it while another scene is active.
    private var scenePhases: [String: ScenePhase] = [:]
    private var effectiveScenePhase: ScenePhase = .active
    private var activeProcessingTaskID: UUID?
    private lazy var mediaDownloads = MediaArtifactDownloadCoordinator(database: environment.database)
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
        BackgroundPolicyRegistry.shared.installMediaRefreshTaskHandler { [weak self] task in
            self?.acceptMediaRefreshTask(task)
        }
        BackgroundPolicyRegistry.shared.installMediaProcessingTaskHandler { [weak self] task in
            self?.acceptMediaProcessingTask(task)
        }
        UNUserNotificationCenter.current().delegate = self
    }

    func didStart(conversationID: UUID, runID: UUID, title: String) {
        // Session publication and launch recovery can report the same durable
        // run more than once. Re-preparing PiP for that duplicate stopped the
        // player that was still loading, so no generation ever reached ready.
        guard activeRuns[runID] == nil else {
            FloeLogger(category: .app).debug(
                "backgroundRunStartIgnored run=\(runID.uuidString) reason=alreadyActive"
            )
            return
        }
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
                await self?.reconcilePendingMediaJobs()
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
            await self.reconcilePendingMediaJobs()
            await self.environment.canvasCloudAssetService.releasePending()
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
        // Media results may expire before the device is connected to power.
        // The same processing slot therefore stays network-only; memory work
        // is opportunistic after urgent media reconciliation.
        request.requiresExternalPower = false
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
            await self.reconcilePendingMediaJobs()
            await self.environment.canvasCloudAssetService.releasePending()
            await self.runDueSchedules()
            let cancelled = Task.isCancelled
            task?.setTaskCompleted(success: !cancelled)
            self.refreshWork = nil
        }
    }

    private func acceptMediaRefreshTask(_ task: BGAppRefreshTask) {
        mediaRefreshWork?.cancel()
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                self?.mediaRefreshWork?.cancel()
                task?.setTaskCompleted(success: false)
            }
        }
        mediaRefreshWork = Task { [weak self, weak task] in
            guard let self else { return }
            await self.reconcilePendingMediaJobs()
            let cancelled = Task.isCancelled
            task?.setTaskCompleted(success: !cancelled)
            self.mediaRefreshWork = nil
        }
    }

    private func acceptMediaProcessingTask(_ task: BGProcessingTask) {
        mediaProcessingWork?.cancel()
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                self?.mediaProcessingWork?.cancel()
                task?.setTaskCompleted(success: false)
            }
        }
        mediaProcessingWork = Task { [weak self, weak task] in
            guard let self else { return }
            await self.reconcilePendingMediaJobs()
            await self.environment.canvasCloudAssetService.releasePending()
            let cancelled = Task.isCancelled
            task?.setTaskCompleted(success: !cancelled)
            self.mediaProcessingWork = nil
        }
    }

    func reconcileSchedulesAfterLaunch() async {
        await reconcilePendingMediaJobs()
        await runDueSchedules()
    }

    /// The app owns exactly one background URLSession for generated media.
    /// Reusing it avoids two delegates competing for the same persistent
    /// session identifier during launch restoration.
    func startMediaArtifactDownload(jobID: UUID, remoteURL: URL) async {
        await mediaDownloads.start(jobID: jobID, remoteURL: remoteURL)
    }

    /// One reconciliation path shared by launch, foreground, refresh and
    /// processing wakeups. Provider task IDs are already durable before this
    /// method runs, so cancellation can only delay progress, not lose work.
    func reconcilePendingMediaJobs(now: Date = Date()) async {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let jobs = try? await store.dueJobs(at: now) else { return }
        for job in jobs where !Task.isCancelled {
            guard let provider = try? await environment.configurationStore.provider(id: job.providerID),
                  let model = try? await environment.configurationStore.model(id: job.modelID),
                  let adapter = VideoProviderAdapterFactory().adapter(for: provider),
                  let taskID = job.providerTaskID else { continue }
            let apiKey = job.credentialReference.flatMap { reference in
                try? environment.keychain.read(account: reference.keychainAccount)
            }.flatMap { String(data: $0, encoding: .utf8) }
            do {
                let status = try await adapter.status(
                    taskID: taskID, modelRemoteID: model.remoteModelID,
                    provider: provider, credentials: ProviderCredentials(apiKey: apiKey)
                )
                switch status.state {
                case .completed:
                    guard let resultURL = status.resultURL else {
                        _ = try await store.transition(id: job.id, to: .failed) {
                            $0.lastError = "供应商报告完成，但没有返回可下载的视频地址。"
                        }
                        continue
                    }
                    let retainedState: MediaGenerationJobState = job.state == .downloading
                        ? .downloading : .completed
                    let completed = try await store.transition(id: job.id, to: retainedState) {
                        $0.lastPolledAt = now
                        $0.resultURL = resultURL
                        $0.resultURLExpiresAt = status.resultURLExpiresAt
                        $0.nextPollAt = nil
                    }
                    if completed.state != .downloading {
                        _ = try await store.transition(id: completed.id, to: .downloading)
                    }
                    await mediaDownloads.start(jobID: job.id, remoteURL: resultURL)
                case .failed, .cancelled, .expired:
                    _ = try await store.transition(id: job.id, to: status.state) {
                        $0.lastPolledAt = now
                        $0.lastError = status.error
                        $0.nextPollAt = nil
                    }
                default:
                    _ = try await store.transition(id: job.id, to: .running) {
                        $0.lastPolledAt = now
                        $0.retryCount = 0
                        $0.lastError = nil
                        $0.nextPollAt = Self.nextMediaPollDate(job: $0, now: now)
                    }
                }
            } catch {
                _ = try? await store.transition(id: job.id, to: job.state) {
                    $0.lastPolledAt = now
                    $0.retryCount += 1
                    $0.lastError = error.localizedDescription
                    let delay = min(30 * 60.0, pow(2, Double(min($0.retryCount, 8))) * 15)
                    $0.nextPollAt = now.addingTimeInterval(delay)
                }
            }
        }
        if let next = (try? await store.dueJobs(at: .distantFuture, limit: 100))?
            .compactMap(\.nextPollAt).min() {
            BackgroundPolicyRegistry.shared.scheduleMediaRefresh(
                earliest: max(next, Date().addingTimeInterval(60))
            )
        }
    }

    nonisolated private static func nextMediaPollDate(job: MediaGenerationJob, now: Date) -> Date {
        if let estimate = job.estimatedCompletionAt, estimate > now {
            return min(estimate, now.addingTimeInterval(5 * 60))
        }
        return now.addingTimeInterval(60)
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

final class MediaArtifactBackgroundEvents: @unchecked Sendable {
    static let shared = MediaArtifactBackgroundEvents()
    private let lock = NSLock()
    private var completion: (() -> Void)?

    private init() {}

    func register(_ completion: @escaping () -> Void) {
        lock.lock(); self.completion = completion; lock.unlock()
    }

    func finish() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        DispatchQueue.main.async { callback?() }
    }
}

@MainActor
final class MediaGenerationService {
    private unowned let environment: AppEnvironment

    init(environment: AppEnvironment) { self.environment = environment }

    func generateImage(
        prompt: String,
        options: ImageGenerationOptions = .init()
    ) async throws -> CanvasAssetReference {
        let center = environment.conversationCenter
        guard let (provider, model) = center.auxiliaryProviderAndModel(for: .generate),
              let adapter = ImageProviderAdapterFactory().adapter(for: provider),
              adapter.supports(.generate, for: provider) else {
            throw FloeError.invalidConfiguration("请先在辅助模型中选择可用的生图模型。")
        }
        let result = try await adapter.perform(
            RemoteImageRequest(
                operation: .generate, prompt: prompt,
                sizeHint: options.size ?? options.aspectRatio,
                count: max(1, min(options.count, 4)),
                modelRemoteID: model.remoteModelID
            ),
            provider: provider,
            credentials: center.resolveCredentials(for: provider)
        )
        guard let data = result.images.first else {
            throw RemoteImageError.invalidResponse("供应商没有返回图片。")
        }
        guard data.count <= 24 * 1_024 * 1_024 else {
            throw FloeError.validationFailed("生成图片超过 24 MiB。")
        }
        let assetID = UUID()
        let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let fileExtension = isPNG ? "png" : "jpg"
        let relativePath = "Materials/\(assetID.uuidString)-generated.\(fileExtension)"
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let destination = support.appendingPathComponent("FloeAgent/\(relativePath)")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try await environment.creativeAssetStore.save(CreativeAssetRecord(
            id: assetID, contentHash: hash, kind: .image,
            displayName: "生成图片", mimeType: isPNG ? "image/png" : "image/jpeg",
            localRelativePath: relativePath, cloudRecordName: nil,
            byteCount: Int64(data.count), sourceURL: nil,
            license: nil, tags: ["生成内容"], referenceCount: 0,
            createdAt: Date(), updatedAt: Date()
        ))
        return CanvasAssetReference(
            id: assetID, contentHash: hash,
            localRelativePath: relativePath,
            mimeType: isPNG ? "image/png" : "image/jpeg",
            byteCount: Int64(data.count), sourceURL: nil,
            license: nil
        )
    }

    /// Submits a video job using a write-before-publish protocol. The returned
    /// job always has a durable provider task ID and can be reconciled after a
    /// process death before the UI reports that generation started.
    func submitVideo(
        modelID: UUID, canvasID: UUID, documentID: UUID,
        sourceNodeIDs: [UUID], resultNodeID: UUID,
        request: RemoteVideoRequest
    ) async throws -> MediaGenerationJob {
        guard let model = try await environment.configurationStore.model(id: modelID),
              let provider = try await environment.configurationStore.provider(id: model.providerID),
              let adapter = VideoProviderAdapterFactory().adapter(for: provider) else {
            throw RemoteVideoError.unsupportedProvider
        }
        let store = MediaGenerationJobStore(database: environment.database)
        let requestJSON = try JSONEncoder().encode(request)
        var job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .video,
            credentialReference: provider.secretRef, canvasID: canvasID,
            documentID: documentID, sourceNodeIDs: sourceNodeIDs,
            resultNodeID: resultNodeID, requestJSON: requestJSON
        )
        try await store.save(job)
        let key = provider.secretRef.flatMap { try? environment.keychain.read(account: $0.keychainAccount) }
            .flatMap { String(data: $0, encoding: .utf8) }
        do {
            let submission = try await adapter.submit(
                request, provider: provider, credentials: ProviderCredentials(apiKey: key)
            )
            job.providerTaskID = submission.providerTaskID
            job.state = .submitted
            job.estimatedCompletionAt = submission.estimatedCompletionAt
            job.resultRetentionExpiresAt = submission.resultRetentionExpiresAt
            job.resultURL = submission.resultURL
            job.resultURLExpiresAt = submission.resultURLExpiresAt
            if submission.resultURL != nil {
                job.state = .downloading
                job.nextPollAt = nil
            } else {
                job.nextPollAt = Date().addingTimeInterval(30)
            }
            job.updatedAt = Date()
            try await store.save(job)
            if let resultURL = submission.resultURL {
                await environment.backgroundRunCoordinator.startMediaArtifactDownload(
                    jobID: job.id, remoteURL: resultURL
                )
            }
            BackgroundPolicyRegistry.shared.requestContinuedProcessing()
            BackgroundPolicyRegistry.shared.scheduleMediaRefresh(
                earliest: job.nextPollAt ?? Date().addingTimeInterval(60)
            )
            BackgroundPolicyRegistry.shared.scheduleMediaProcessing(
                earliest: Date().addingTimeInterval(60)
            )
            return job
        } catch {
            _ = try? await store.transition(id: job.id, to: .failed) {
                $0.lastError = error.localizedDescription
            }
            throw error
        }
    }

    func cancelVideo(jobID: UUID) async throws {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let job = try await store.job(id: jobID) else {
            throw MediaGenerationJobStoreError.missingJob(jobID)
        }
        guard !job.state.isTerminal else { return }
        guard let taskID = job.providerTaskID,
              let provider = try await environment.configurationStore.provider(id: job.providerID),
              let adapter = VideoProviderAdapterFactory().adapter(for: provider) else {
            throw RemoteVideoError.unsupportedProvider
        }
        let key = job.credentialReference.flatMap {
            try? environment.keychain.read(account: $0.keychainAccount)
        }.flatMap { String(data: $0, encoding: .utf8) }
        try await adapter.cancel(
            taskID: taskID,
            provider: provider,
            credentials: ProviderCredentials(apiKey: key)
        )
        _ = try await store.transition(id: jobID, to: .cancelled) {
            $0.nextPollAt = nil
            $0.lastError = nil
        }
    }

    /// A retry is always a new provider job so the original terminal record
    /// remains auditable. Callers must obtain explicit user confirmation first
    /// because the provider may charge for the new submission.
    func retryVideo(jobID: UUID) async throws -> MediaGenerationJob {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let original = try await store.job(id: jobID) else {
            throw MediaGenerationJobStoreError.missingJob(jobID)
        }
        let request = try JSONDecoder().decode(RemoteVideoRequest.self, from: original.requestJSON)
        return try await submitVideo(
            modelID: original.modelID,
            canvasID: original.canvasID,
            documentID: original.documentID,
            sourceNodeIDs: original.sourceNodeIDs,
            resultNodeID: original.resultNodeID,
            request: request
        )
    }
}

/// Background network-process owner for short-lived provider result URLs.
/// Files move into the durable material library before a job becomes ready.
final class MediaArtifactDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "org.floeagent.media-artifacts"

    private let database: DatabaseManager
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(database: DatabaseManager) {
        self.database = database
        super.init()
        _ = session
    }

    func start(jobID: UUID, remoteURL: URL) async {
        guard remoteURL.scheme?.lowercased() == "https",
              remoteURL.user == nil, remoteURL.password == nil,
              remoteURL.host != nil, !remoteURL.isLocalOrPrivateNetwork else {
            await fail(jobID: jobID, message: "供应商返回了不安全的下载地址。")
            return
        }
        let tasks = await session.allTasks
        if tasks.contains(where: { $0.taskDescription == jobID.uuidString }) { return }
        let task = session.downloadTask(with: remoteURL)
        task.taskDescription = jobID.uuidString
        task.priority = URLSessionTask.highPriority
        task.resume()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let raw = downloadTask.taskDescription, let jobID = UUID(uuidString: raw) else { return }
        do {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let directory = support.appendingPathComponent("FloeAgent/Materials", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let assetID = UUID()
            let extensionName = downloadTask.response?.suggestedFilename
                .flatMap { URL(fileURLWithPath: $0).pathExtension }
                .flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
            let destination = directory.appendingPathComponent("\(assetID.uuidString)-generated.\(extensionName)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
            Task {
                let store = MediaGenerationJobStore(database: database)
                let data = try? Data(contentsOf: destination, options: .mappedIfSafe)
                let hash = data.map {
                    SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
                } ?? assetID.uuidString
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init) ?? 0
                let assetStore = CreativeAssetStore(database: database)
                try? await assetStore.save(CreativeAssetRecord(
                    id: assetID, contentHash: hash, kind: .video,
                    displayName: destination.deletingPathExtension().lastPathComponent,
                    mimeType: downloadTask.response?.mimeType ?? "video/mp4",
                    localRelativePath: "Materials/\(destination.lastPathComponent)",
                    cloudRecordName: nil, byteCount: size,
                    sourceURL: downloadTask.originalRequest?.url,
                    license: nil, tags: ["生成内容"], referenceCount: 0,
                    createdAt: Date(), updatedAt: Date()
                ))
                _ = try? await store.transition(id: jobID, to: .ready) {
                    $0.localAssetID = assetID
                    $0.lastError = nil
                }
                await Self.postCompletionNotification(jobID: jobID)
            }
        } catch {
            Task { await fail(jobID: jobID, message: error.localizedDescription) }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let raw = task.taskDescription, let jobID = UUID(uuidString: raw) else { return }
        Task { await fail(jobID: jobID, message: error.localizedDescription) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MediaArtifactBackgroundEvents.shared.finish()
    }

    private func fail(jobID: UUID, message: String) async {
        let store = MediaGenerationJobStore(database: database)
        guard let job = try? await store.job(id: jobID) else { return }
        let now = Date()
        if let expires = job.resultURLExpiresAt, expires <= now {
            _ = try? await store.transition(id: jobID, to: .expired) { $0.lastError = message }
        } else {
            _ = try? await store.transition(id: jobID, to: job.state) {
                $0.retryCount += 1
                $0.lastError = message
                $0.nextPollAt = now.addingTimeInterval(min(30 * 60, pow(2, Double(min($0.retryCount, 8))) * 15))
            }
        }
    }

    private static func postCompletionNotification(jobID: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = "视频已准备好"
        content.body = "生成结果已保存到素材库，并会在画布中恢复。"
        content.sound = .default
        content.userInfo = ["mediaJobID": jobID.uuidString]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "media.\(jobID.uuidString)", content: content, trigger: nil
        ))
    }
}
#endif
