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

struct BackgroundExecutionSurfaceTransition: Sendable, Equatable {
    var stopsPictureInPicture: Bool
    var stopsScreenShare: Bool
    var preparesPictureInPicture: Bool
    var requestsScreenShareAuthorization: Bool
}

/// Why a provider/media workload began. Continued-processing requests are
/// legal only for work that still traces to an explicit in-app user action;
/// every launch, schedule and automatic continuation path fails closed.
enum ContinuedProcessingStartOrigin: String, Sendable, CaseIterable, Equatable {
    case explicitUserAction
    case foregroundRecovery
    case scheduledTask
    case goalContinuation
    case queuedInput
    case externalAutomation
    case automaticTool

    var allowsContinuedSubmission: Bool { self == .explicitUserAction }
}

/// Pure bookkeeping used by the coordinator and its regression tests. The
/// first registration owns a run's origin so a duplicate recovery callback
/// cannot upgrade automatic work into user-eligible work.
struct ContinuedProcessingEligibilityState<RunID: Hashable> {
    private(set) var runOrigins: [RunID: ContinuedProcessingStartOrigin] = [:]

    @discardableResult
    mutating func registerRun(
        _ id: RunID,
        origin: ContinuedProcessingStartOrigin
    ) -> Bool {
        guard runOrigins[id] == nil else { return false }
        runOrigins[id] = origin
        return true
    }

    mutating func finishRun(_ id: RunID) { runOrigins[id] = nil }

    func origin(forRun id: RunID) -> ContinuedProcessingStartOrigin? {
        runOrigins[id]
    }

    var hasEligibleWork: Bool {
        runOrigins.values.contains(where: \.allowsContinuedSubmission)
    }
}

/// Enforces the scheduler expiration ordering without depending on a system-
/// constructed BGTask in tests. The managed check and sibling completion stay
/// in one synchronous closure; persistence is deliberately the first await.
@MainActor
enum ContinuedProcessingExpirationSequence {
    @discardableResult
    static func runIfManaged(
        drainAndCompleteIfManaged: () -> Bool,
        persistRecoveryPoints: () async -> Void
    ) async -> Bool {
        guard drainAndCompleteIfManaged() else { return false }
        await persistRecoveryPoints()
        return true
    }
}

/// App-lifetime owner for provider runs while views come and go. It writes
/// recovery points before suspension, requests real iOS continued processing,
/// and routes notification taps back to the durable task.
@MainActor
final class BackgroundRunCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private unowned let environment: AppEnvironment
    private struct ActiveRun {
        let conversationID: UUID?
        let title: String
        let continuedProcessingOrigin: ContinuedProcessingStartOrigin
        let allowsContinuedProcessing: Bool
        let retainsSurfaceOnFailure: Bool
        let sendsTerminalNotification: Bool
        var stage: String = "正在运行"
        var progress: Int64 = 5
    }
    private var activeRuns: [UUID: ActiveRun] = [:]
    private var continuedEligibility = ContinuedProcessingEligibilityState<UUID>()
    private var surfacedRunID: UUID?
    private var retainedPausedRun: (id: UUID, run: ActiveRun)?
    // Match the fail-closed aggregate scene phase until SwiftUI reports a
    // real active window. A first background callback may legitimately be a
    // no-op transition, so both pieces of lifecycle state must start aligned.
    private var isAppInBackground = true
    private var visualSurfacePolicy: BackgroundVisualSurfacePolicy
    private static let visualSurfacePolicyDefaultsKey = "backgroundVisualSurfacePolicy.v2"
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
    // Fail closed until at least one real SwiftUI scene reports foreground.
    // Background wakes and cold-launch restoration happen before that report.
    private var effectiveScenePhase: ScenePhase = .background
    private var activeProcessingTaskID: UUID?
    private lazy var mediaDownloads = MediaArtifactDownloadCoordinator(
        database: environment.database
    )
    @available(iOS 26.0, *)
    private var continuedTasksByIdentifier:
        [String: [ObjectIdentifier: BGContinuedProcessingTask]] = [:]

    nonisolated static func shouldRequestContinuedProcessing(
        for preference: BackgroundExecutionPreference
    ) -> Bool {
        preference == .standard
    }

    nonisolated static func shouldKeepContinuedProcessing(
        for preference: BackgroundExecutionPreference,
        launchPreferencesLoaded: Bool
    ) -> Bool {
        launchPreferencesLoaded
            && shouldRequestContinuedProcessing(for: preference)
    }

    nonisolated static func shouldSubmitContinuedProcessing(
        for preference: BackgroundExecutionPreference,
        launchPreferencesLoaded: Bool,
        origin: ContinuedProcessingStartOrigin,
        hasAggregateForegroundScene: Bool
    ) -> Bool {
        origin.allowsContinuedSubmission
            && hasAggregateForegroundScene
            && shouldKeepContinuedProcessing(
                for: preference,
                launchPreferencesLoaded: launchPreferencesLoaded
            )
    }

    /// Provider media jobs are durable and resume through BGAppRefresh,
    /// BGProcessing and the background URLSession. They do not expose real
    /// continuous progress, so they must never create or retain a system
    /// continued-processing Live Activity, regardless of their caller.
    nonisolated static func shouldSubmitContinuedProcessingForMediaGeneration(
        origin: ContinuedProcessingStartOrigin
    ) -> Bool {
        _ = origin
        return false
    }

    nonisolated static func visualSurfaceTransition(
        for preference: BackgroundExecutionPreference
    ) -> BackgroundExecutionSurfaceTransition {
        switch preference {
        case .standard:
            BackgroundExecutionSurfaceTransition(
                stopsPictureInPicture: true,
                stopsScreenShare: true,
                preparesPictureInPicture: false,
                requestsScreenShareAuthorization: false
            )
        case .pictureInPicture:
            BackgroundExecutionSurfaceTransition(
                stopsPictureInPicture: false,
                stopsScreenShare: true,
                preparesPictureInPicture: true,
                requestsScreenShareAuthorization: false
            )
        case .screenShare:
            BackgroundExecutionSurfaceTransition(
                stopsPictureInPicture: true,
                stopsScreenShare: false,
                preparesPictureInPicture: false,
                requestsScreenShareAuthorization: false
            )
        }
    }

    nonisolated static func shouldReconcileVisualSurface(
        hasActiveRuns: Bool,
        hasRetainedPausedRun: Bool
    ) -> Bool {
        hasActiveRuns || hasRetainedPausedRun
    }

    nonisolated static func shouldOfferVisualSurfaceControl(
        conversationID: UUID,
        activeConversationIDs: [UUID?],
        retainedConversationID: UUID?
    ) -> Bool {
        retainedConversationID == conversationID
            || activeConversationIDs.contains { $0 == conversationID }
    }

    /// Ordinary chat can leave a failed or checkpointed run intentionally
    /// retained after `ConversationCenter` stops reporting it as running. The
    /// PiP source host must follow this coordinator-owned lifetime, otherwise
    /// the inline AVKit source disappears before iOS can detach it into PiP.
    func shouldOfferVisualSurfaceControl(conversationID: UUID) -> Bool {
        Self.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: activeRuns.values.map(\.conversationID),
            retainedConversationID: retainedPausedRun?.run.conversationID
        )
    }

    /// Settings are live, not just launch defaults. A continued-processing
    /// task is a system Live Activity, so changing to either visual mode must
    /// complete an already accepted task immediately.
    func backgroundExecutionPreferenceDidChange(
        to preference: BackgroundExecutionPreference
    ) {
        if #available(iOS 26.0, *) {
            if Self.shouldKeepContinuedProcessing(
                for: preference,
                launchPreferencesLoaded:
                    environment.settingsCenter.launchPreferencesLoaded
            ) {
                if let active = activeRuns.values.first(where: {
                    $0.allowsContinuedProcessing
                        && $0.continuedProcessingOrigin.allowsContinuedSubmission
                }) {
                    requestContinuedProcessingIfEligible(
                        origin: active.continuedProcessingOrigin,
                        workload: "settingsRunReconcile",
                        title: active.title,
                        stage: active.stage,
                        progress: active.progress
                    )
                } else {
                    // Preference restoration and automatic-only workloads
                    // cannot retain a stale Live Activity from another run.
                    finishContinuedTasks(success: true)
                }
            } else {
                finishContinuedTasks(success: true)
                FloeLogger(category: .app).info(
                    "continuedProcessingFinished reason=preferenceChanged preference=\(preference.rawValue)"
                )
            }
        }

        // With no active or resumable workload there cannot be a live surface
        // to reconcile. Besides being a no-op, touching the lazy screen-share
        // stack during launch preference restoration could construct the
        // conversation center while AppEnvironment is still warming up.
        guard Self.shouldReconcileVisualSurface(
            hasActiveRuns: !activeRuns.isEmpty,
            hasRetainedPausedRun: retainedPausedRun != nil
        ) else { return }

        // Reconcile the visual surface in the same main-actor turn as the
        // preference publication. Changing settings never starts PiP and never
        // presents ReplayKit authorization; it only prepares/stops surfaces the
        // user has already selected.
        let transition = Self.visualSurfaceTransition(for: preference)
        if transition.stopsPictureInPicture {
            surfacedRunID = nil
            pipCarouselTask?.cancel()
            pipCarouselTask = nil
            environment.backgroundVideoService.stop()
        }
        if transition.stopsScreenShare {
            if environment.screenShareCenter.isSharing
                || environment.screenShareCenter.isWaitingForBroadcast {
                environment.screenShareCenter.stopSharing()
            }
        }
        if transition.preparesPictureInPicture {
            guard let candidate = activeRuns.sorted(by: {
                $0.key.uuidString < $1.key.uuidString
            }).first else { return }
            surfacedRunID = candidate.key
            environment.backgroundVideoService.setRunContext(
                title: candidate.value.title,
                progress: "\(candidate.value.stage) · \(candidate.value.progress)%",
                automaticallyStartsFromInline: true
            )
        }
        assert(!transition.requestsScreenShareAuthorization)
        // Deliberately do not call requestBroadcast here. ReplayKit's system
        // consent remains tied to a subsequent explicit run action.
    }

    private var hasAggregateForegroundScene: Bool {
        effectiveScenePhase == .active && scenePhases.values.contains(.active)
    }

    func continuedProcessingOrigin(forRunID runID: UUID) -> ContinuedProcessingStartOrigin {
        continuedEligibility.origin(forRun: runID) ?? .automaticTool
    }

    /// The only path that may submit a BGContinuedProcessingRequest. Keeping
    /// the origin and aggregate-scene checks together prevents a future
    /// caller from accidentally treating a background wake as user intent.
    @discardableResult
    func requestContinuedProcessingIfEligible(
        origin: ContinuedProcessingStartOrigin,
        workload: String,
        title: String? = nil,
        stage: String = "正在运行",
        progress: Int64 = 5
    ) -> Bool {
        let preference = environment.settingsCenter.backgroundExecution
        let loaded = environment.settingsCenter.launchPreferencesLoaded
        guard Self.shouldSubmitContinuedProcessing(
            for: preference,
            launchPreferencesLoaded: loaded,
            origin: origin,
            hasAggregateForegroundScene: hasAggregateForegroundScene
        ) else {
            if !Self.shouldKeepContinuedProcessing(
                for: preference,
                launchPreferencesLoaded: loaded
            ), #available(iOS 26.0, *) {
                finishContinuedTasks(success: true)
            }
            FloeLogger(category: .app).info(
                "continuedProcessingSkipped workload=\(workload) origin=\(origin.rawValue) foreground=\(hasAggregateForegroundScene) preference=\(preference.rawValue) loaded=\(loaded)"
            )
            return false
        }
        if #available(iOS 26.0, *), let title {
            updateContinuedTask(title: title, stage: stage, progress: progress)
        }
        BackgroundPolicyRegistry.shared.requestContinuedProcessing()
        return true
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        if let data = UserDefaults.standard.data(
            forKey: Self.visualSurfacePolicyDefaultsKey
        ), let restored = try? JSONDecoder().decode(
            BackgroundVisualSurfacePolicy.self, from: data
        ) {
            self.visualSurfacePolicy = restored
        } else {
            self.visualSurfacePolicy = BackgroundVisualSurfacePolicy()
        }
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

    func didStart(
        conversationID: UUID,
        runID: UUID,
        title: String,
        origin: ContinuedProcessingStartOrigin
    ) {
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
        if activeRuns.isEmpty,
           origin.allowsContinuedSubmission,
           hasAggregateForegroundScene {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
        visualSurfacePolicy.beginRun(
            runID, currentlyActiveRunIDs: Set(activeRuns.keys)
        )
        persistVisualSurfacePolicy()
        retainedPausedRun = nil
        activeRuns[runID] = ActiveRun(
            conversationID: conversationID,
            title: title,
            continuedProcessingOrigin: origin,
            allowsContinuedProcessing: true,
            retainsSurfaceOnFailure: true,
            sendsTerminalNotification: true
        )
        _ = continuedEligibility.registerRun(runID, origin: origin)
        FloeLogger(category: .app).info(
            "backgroundRunStarted run=\(runID.uuidString) conversation=\(conversationID.uuidString) origin=\(origin.rawValue) preference=\(environment.settingsCenter.backgroundExecution.rawValue) activeRuns=\(activeRuns.count)"
        )
        requestContinuedProcessingIfEligible(
            origin: origin,
            workload: "conversationRun",
            title: title
        )
        applyBackgroundExecutionPreference(
            runID: runID,
            conversationID: conversationID,
            runTitle: title
        )
    }

    /// A user-started Canvas image request is also a long provider workload.
    /// Register it with the same lifecycle owner as conversation runs so
    /// leaving the Canvas does not make the coordinator report zero active
    /// work and tear down continued processing/PiP underneath the request.
    func didStartMediaGeneration(workID: UUID, title: String) {
        guard activeRuns[workID] == nil else { return }
        visualSurfacePolicy.beginRun(
            workID, currentlyActiveRunIDs: Set(activeRuns.keys)
        )
        persistVisualSurfacePolicy()
        retainedPausedRun = nil
        activeRuns[workID] = ActiveRun(
            conversationID: nil,
            title: title,
            continuedProcessingOrigin: .explicitUserAction,
            allowsContinuedProcessing: false,
            retainsSurfaceOnFailure: false,
            sendsTerminalNotification: false,
            stage: "正在生成媒体",
            progress: 10
        )
        FloeLogger(category: .app).info(
            "backgroundMediaStarted work=\(workID.uuidString) activeRuns=\(activeRuns.count)"
        )
        // A continued-processing task is the top-right system Live Activity
        // users reported as a false PiP surface. Canvas media owns a real
        // AVKit PiP context instead and must never submit that request.
        assert(!Self.shouldSubmitContinuedProcessingForMediaGeneration(
            origin: .explicitUserAction
        ))
        FloeLogger(category: .app).info(
            "continuedProcessingSkipped workload=canvasMediaGeneration reason=mediaUsesDurableRecoveryOrPiP"
        )
        applyBackgroundExecutionPreference(
            runID: workID,
            conversationID: nil,
            runTitle: title
        )
    }

    func didFinishMediaGeneration(
        workID: UUID,
        succeeded: Bool,
        message: String?
    ) {
        didFinish(runID: workID, succeeded: succeeded, message: message)
    }

    /// Pushes a progress stage update to the active background surface (the
    /// continued task's Live Activity subtitle, and the PiP progress video).
    func didUpdateProgress(runID: UUID, stage: String, progress: Int64) {
        guard var active = activeRuns[runID] else { return }
        active.stage = stage
        active.progress = progress
        activeRuns[runID] = active
        if #available(iOS 26.0, *),
           active.allowsContinuedProcessing,
           active.continuedProcessingOrigin.allowsContinuedSubmission {
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
        if #available(iOS 26.0, *),
           active.allowsContinuedProcessing,
           active.continuedProcessingOrigin.allowsContinuedSubmission {
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
        continuedEligibility.finishRun(runID)
        visualSurfacePolicy.finishRun(runID)
        persistVisualSurfacePolicy()
        FloeLogger(category: .app).info(
            "backgroundRunFinished run=\(runID.uuidString) succeeded=\(succeeded) remainingRuns=\(activeRuns.count)"
        )
        let conversationID = finished.conversationID
        notifiedApprovalRuns.remove(runID)
        if finished.sendsTerminalNotification, let conversationID {
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
        }
        if #available(iOS 26.0, *), !continuedEligibility.hasEligibleWork {
            finishContinuedTasks(success: succeeded)
        }
        if surfacedRunID == runID, !activeRuns.isEmpty {
            surfacedRunID = nil
            resumeBackgroundSurfaceIfNeeded()
        }
        if activeRuns.isEmpty,
           succeeded || !finished.retainsSurfaceOnFailure {
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
        // A scene cycle is not fresh user intent. Keep this decision for the
        // current task batch even if the user reopens Floe and leaves again.
        // A genuinely new run clears it in didStart. Screen sharing may keep
        // running; only its optional progress PiP is suppressed.
        visualSurfacePolicy.userClosedPictureInPicture()
        persistVisualSurfacePolicy()
        FloeLogger(category: .app).info(
            "pictureInPictureClosedByUser activeRuns=\(activeRuns.count)"
        )
        // Do not recreate PiP under the user's close gesture or a later scene
        // transition in the same batch.
    }

    /// Applies the user's background-execution choice when a run starts.
    /// `standard` relies on the 30s lease + continued task (no extra UI);
    /// Both visual modes expose real task-progress content from the existing
    /// task/canvas toolbar. PiP lets AVKit automatically enter when the user
    /// leaves an inline player, while scene transitions never call `start`.
    /// Screen-share mode additionally asks the matching thread to present
    /// ReplayKit's system consent flow.
    private func applyBackgroundExecutionPreference(
        runID: UUID,
        conversationID: UUID?,
        runTitle: String
    ) {
        let preference = environment.settingsCenter.backgroundExecution
        guard visualSurfacePolicy.allowsVisualSurface(
            for: preference
        ) else {
            if preference == .standard {
                // Mode changes can happen while a failed run's visual surface
                // is retained. Standard mode owns only its continued task and
                // must not inherit an earlier PiP controller or broadcast.
                surfacedRunID = nil
                environment.backgroundVideoService.stop()
                if environment.screenShareCenter.isSharing
                    || environment.screenShareCenter.isWaitingForBroadcast {
                    environment.screenShareCenter.stopSharing()
                }
            }
            FloeLogger(category: .app).info(
                "backgroundSurfaceSkipped run=\(runID.uuidString) reason=preferenceOrBatchSuppression batch=\(visualSurfacePolicy.batchID.uuidString)"
            )
            return
        }
        switch preference {
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
            environment.backgroundVideoService.setRunContext(
                title: runTitle,
                progress: "正在运行",
                automaticallyStartsFromInline: true
            )
        case .screenShare:
            guard let conversationID else {
                FloeLogger(category: .app).info(
                    "backgroundSurfaceSkipped run=\(runID.uuidString) reason=canvasMediaHasNoConversationForScreenShare"
                )
                break
            }
            FloeLogger(category: .app).info(
                "backgroundSurfaceRequested run=\(runID.uuidString) mode=screenShare sharing=\(environment.screenShareCenter.isSharing)"
            )
            surfacedRunID = runID
            environment.backgroundVideoService.setRunContext(
                title: runTitle,
                progress: environment.screenShareCenter.isSharing
                    ? "正在共享屏幕" : "任务正在运行"
            )
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
        guard visualSurfacePolicy.allowsVisualSurface(
                  for: environment.settingsCenter.backgroundExecution
              ) else { return }
        let candidate = activeRuns.first.map { (id: $0.key, run: $0.value) }
            ?? retainedPausedRun
        guard let (runID, run) = candidate else { return }
        surfacedRunID = runID
        environment.backgroundVideoService.update(
            title: run.title,
            progress: "\(run.stage) · \(run.progress)%"
        )
        if isAppInBackground {
            startPiPCarousel()
        }
        guard !environment.backgroundVideoService.isPiPActive else { return }
        // Prepared inline content is handed to AVKit, which owns the automatic
        // Home/app-switch transition. The scene callback never invokes start;
        // it only preserves checkpoints under the short completion lease.
        FloeLogger(category: .app).debug(
            "pictureInPictureBackgroundTransitionNoStart state=\(environment.backgroundVideoService.preparationState.rawValue)"
        )
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
        if #available(iOS 26.0, *),
           activeRuns[runID]?.continuedProcessingOrigin.allowsContinuedSubmission == true {
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
        let handleID = ObjectIdentifier(task)
        var handles = continuedTasksByIdentifier[task.identifier] ?? [:]
        guard handles[handleID] == nil else { return }
        handles[handleID] = task
        continuedTasksByIdentifier[task.identifier] = handles

        guard Self.shouldKeepContinuedProcessing(
            for: environment.settingsCenter.backgroundExecution,
            launchPreferencesLoaded:
                environment.settingsCenter.launchPreferencesLoaded
        ), continuedEligibility.hasEligibleWork else {
            // A cold-launch callback can arrive while SettingsCenter still has
            // its in-memory `.standard` default. Fail closed until the stored
            // preference has been restored so no transient Live Activity is
            // shown for a PiP/screen-share user.
            finishContinuedTasks(success: true)
            FloeLogger(category: .app).info(
                "backgroundTaskAcceptanceSkipped kind=continued reason=noEligibleUserWorkOrPreference preference=\(environment.settingsCenter.backgroundExecution.rawValue) loaded=\(environment.settingsCenter.launchPreferencesLoaded)"
            )
            return
        }
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = continuedEligibility.hasEligibleWork ? 5 : 100
        FloeLogger(category: .app).info(
            "backgroundTaskAccepted kind=continued identifier=\(task.identifier) activeRuns=\(activeRuns.count) handles=\(continuedTaskHandleCount)"
        )
        task.expirationHandler = { [weak self, weak task] in
            Task { @MainActor in
                guard let self, let task else { return }
                await ContinuedProcessingExpirationSequence.runIfManaged(
                    drainAndCompleteIfManaged: {
                        guard self.containsContinuedTask(task) else {
                            // A sibling expiration or another terminal path
                            // already drained this handle. Repeated callbacks
                            // are intentionally idempotent.
                            return false
                        }
                        // The scheduler may deliver more than one legacy or
                        // racing identifier. Complete every sibling before the
                        // first suspension point so no Live Activity can be
                        // orphaned by slow/hung recovery-point persistence.
                        self.finishContinuedTasks(success: false)
                        return true
                    },
                    persistRecoveryPoints: { [weak self] in
                        guard let self else { return }
                        await self.environment.conversationCenter
                            .persistActiveRecoveryPoints()
                    }
                )
            }
        }
        if !continuedEligibility.hasEligibleWork {
            finishContinuedTasks(success: true)
        } else {
            task.updateTitle("Floe Agent", subtitle: "正在后台继续任务")
        }
    }

    @available(iOS 26.0, *)
    private func updateContinuedTask(title: String, stage: String, progress: Int64) {
        guard Self.shouldKeepContinuedProcessing(
            for: environment.settingsCenter.backgroundExecution,
            launchPreferencesLoaded:
                environment.settingsCenter.launchPreferencesLoaded
        ) else {
            // Every update site shares this last-line gate. A stale callback
            // from progress/suspension/approval therefore cannot resurrect or
            // keep updating a Live Activity after the mode changed.
            finishContinuedTasks(success: true)
            FloeLogger(category: .app).debug(
                "continuedProcessingUpdateSkipped reason=visualBackgroundPreference preference=\(environment.settingsCenter.backgroundExecution.rawValue)"
            )
            return
        }
        for task in continuedTasksByIdentifier.values.flatMap(\.values) {
            task.updateTitle(title, subtitle: stage)
            task.progress.completedUnitCount = min(95, max(1, progress))
        }
    }

    @available(iOS 26.0, *)
    private var continuedTaskHandleCount: Int {
        continuedTasksByIdentifier.values.reduce(0) { $0 + $1.count }
    }

    @available(iOS 26.0, *)
    private func containsContinuedTask(_ task: BGContinuedProcessingTask) -> Bool {
        continuedTasksByIdentifier[task.identifier]?[ObjectIdentifier(task)] != nil
    }

    @available(iOS 26.0, *)
    private func finishContinuedTasks(success: Bool) {
        let tasks = continuedTasksByIdentifier.values.flatMap(\.values)
        continuedTasksByIdentifier.removeAll()
        _ = BackgroundPolicyRegistry.shared.completeAllContinuedTaskHandles()
        for task in tasks {
            task.progress.totalUnitCount = 100
            task.progress.completedUnitCount = 100
            task.setTaskCompleted(success: success)
        }
        // Also cancel submitted-but-not-yet-accepted requests, including stale
        // concrete identifiers discoverable from a previous process.
        BackgroundPolicyRegistry.shared.cancelContinuedProcessingRequests()
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
        let pipPhase: BackgroundPiPEffectiveScenePhase = switch effective {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
        // Publish the reconciled app-wide phase before SwiftUI dismantles an
        // inline source host during the same transition.
        environment.backgroundVideoService.updateEffectiveScenePhase(pipPhase)
        guard effective != effectiveScenePhase else { return }
        effectiveScenePhase = effective
        visualSurfacePolicy.recordSceneTransition()
        persistVisualSurfacePolicy()
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
            pipCarouselTask?.cancel()
            pipCarouselTask = nil
            environment.backgroundVideoService.retractForForeground()
            if visualSurfacePolicy.allowsVisualSurface(
                for: environment.settingsCenter.backgroundExecution
            ) {
                prepareBackgroundSurfaceIfNeeded()
            }
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
            // Inactive can mean Control Center, a notification, scene handoff,
            // or the start of backgrounding. None is explicit PiP intent.
            FloeLogger(category: .app).debug(
                "pictureInPictureInactiveTransitionNoStart activeRuns=\(activeRuns.count)"
            )
        @unknown default:
            break
        }
    }

    private func persistVisualSurfacePolicy() {
        guard let data = try? JSONEncoder().encode(visualSurfacePolicy) else { return }
        UserDefaults.standard.set(data, forKey: Self.visualSurfacePolicyDefaultsKey)
    }

    /// Keeps the latest run available to the PiP toolbar control. In PiP mode
    /// the inline host arms AVKit for the user's later Home/app-switch gesture;
    /// this method itself never starts PiP from a scene-phase callback.
    private func prepareBackgroundSurfaceIfNeeded() {
        guard visualSurfacePolicy.allowsVisualSurface(
                  for: environment.settingsCenter.backgroundExecution
              ),
              !environment.backgroundVideoService.isPreparingPiP else { return }
        let candidate = activeRuns.first.map { (id: $0.key, run: $0.value) }
            ?? retainedPausedRun
        guard let (runID, run) = candidate else { return }
        surfacedRunID = runID
        environment.backgroundVideoService.setRunContext(
            title: run.title,
            progress: "\(run.stage) · \(run.progress)%",
            automaticallyStartsFromInline:
                environment.settingsCenter.backgroundExecution == .pictureInPicture
        )
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
        // Generated-image reservations share this retry path with durable
        // provider jobs. A Canvas or database that is temporarily unavailable
        // at launch is therefore retried on foreground, refresh and processing
        // wakeups instead of waiting for the next process launch. The media
        // service skips batches that are still active in this process, and its
        // reconciliation does not call back into this coordinator.
        await environment.mediaGenerationService
            .reconcileGeneratedAssetReservations()
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
                        workspaceID: schedule.workspaceID,
                        startOrigin: .scheduledTask
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

/// Validates provider cardinality before image bytes can reach the file system
/// or asset database. In particular, an unexpected fifth image is an error,
/// not something callers are allowed to silently truncate.
enum MediaGenerationImageBatchContract {
    static let maximumImageBytes = 24 * 1_024 * 1_024

    static func validatedImages(
        _ images: [Data],
        requestedOutputCount: Int
    ) throws -> [Data] {
        let expected = max(1, min(requestedOutputCount, 4))
        guard images.count == expected else {
            throw FloeError.validationFailed(
                "图片服务应返回 \(expected) 张图片，但实际返回 \(images.count) 张；本次没有保存部分结果，请从配置节点重试。"
            )
        }
        guard images.allSatisfy({ $0.count <= maximumImageBytes }) else {
            throw FloeError.validationFailed("生成图片超过 24 MiB。")
        }
        return images
    }
}

enum MediaGenerationAssetReusePolicy {
    static func generatedRelativePath(assetID: UUID, isPNG: Bool) -> String {
        "Materials/\(assetID.uuidString)-generated.\(isPNG ? "png" : "jpg")"
    }

    static func localURL(
        relativePath: String,
        applicationSupportRoot: URL
    ) throws -> URL {
        let root = applicationSupportRoot.appendingPathComponent(
            "FloeAgent", isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(relativePath)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains(".."),
              url.path.hasPrefix(root.path + "/") else {
            throw FloeError.validationFailed(
                "Generated asset path escapes application support"
            )
        }
        return url
    }

    static func usesThrowawayCandidatePath(
        record: CreativeAssetRecord,
        candidateID: UUID,
        candidateRelativePath: String
    ) -> Bool {
        record.id != candidateID
            && record.localRelativePath == candidateRelativePath
    }

    static func localReferenceIfAvailable(
        for record: CreativeAssetRecord,
        applicationSupportRoot: URL,
        fileManager: FileManager = .default
    ) -> CanvasAssetReference? {
        guard let relativePath = record.localRelativePath,
              let url = try? localURL(
                relativePath: relativePath,
                applicationSupportRoot: applicationSupportRoot
              ),
              fileManager.fileExists(atPath: url.path) else { return nil }
        return CanvasAssetReference(
            id: record.id,
            contentHash: record.contentHash,
            localRelativePath: relativePath,
            mimeType: record.mimeType,
            byteCount: record.byteCount,
            sourceURL: record.sourceURL,
            license: record.license
        )
    }
}

/// Tracks ownership of newly-created hash rows across interleaved generation
/// requests. A reused provisional asset is deleted only after every request
/// that received it has independently abandoned its claim.
struct ProvisionalGeneratedAssetClaims {
    private struct Entry {
        var count: Int
        var wasCommitted: Bool
        var canonicalAssetID: UUID?
        var wasCreatedByService: Bool
    }

    private var entries: [String: Entry] = [:]
    var pendingClaims: [String: Int] { entries.mapValues(\.count) }

    /// Registers all output hashes synchronously before the first persistence
    /// await, closing the gap where another request could abandon and delete
    /// a canonical row while this request is still resolving it.
    mutating func registerReturnedHashes(_ contentHashes: [String]) {
        for contentHash in contentHashes {
            var entry = entries[contentHash] ?? Entry(
                count: 0,
                wasCommitted: false,
                canonicalAssetID: nil,
                wasCreatedByService: false
            )
            entry.count += 1
            entries[contentHash] = entry
        }
    }

    mutating func bindCanonicalAsset(
        contentHash: String,
        assetID: UUID,
        wasInserted: Bool
    ) {
        guard var entry = entries[contentHash] else { return }
        entry.canonicalAssetID = assetID
        entry.wasCreatedByService = entry.wasCreatedByService || wasInserted
        entries[contentHash] = entry
    }

    /// Resolves one claim per returned hash. Duplicate bytes in a batch
    /// deliberately create multiple claims for the same canonical asset row.
    mutating func resolveReturnedHashes(
        _ contentHashes: [String],
        deleteWhenUnclaimed: Bool
    ) -> Set<UUID> {
        var deletable = Set<UUID>()
        for contentHash in contentHashes {
            guard var entry = entries[contentHash], entry.count > 0 else { continue }
            if !deleteWhenUnclaimed { entry.wasCommitted = true }
            if entry.count == 1 {
                entries.removeValue(forKey: contentHash)
                if deleteWhenUnclaimed,
                   !entry.wasCommitted,
                   entry.wasCreatedByService,
                   let assetID = entry.canonicalAssetID {
                    deletable.insert(assetID)
                }
            } else {
                entry.count -= 1
                entries[contentHash] = entry
            }
        }
        return deletable
    }
}

struct GeneratedImageReservationOwner: Sendable, Hashable {
    var canvasID: UUID
    var documentID: UUID
    var configurationNodeID: UUID
    var generationAttemptID: String
    var resultNodeIDs: [UUID]
}

struct ReservedGeneratedImageBatch: Sendable, Hashable {
    var reservationID: UUID
    var assets: [CanvasAssetReference]
}

enum GeneratedAssetReservationRecoveryDecision: Sendable, Hashable {
    case finalize
    case abandon
    case retain
}

enum GeneratedAssetReservationRecoveryPolicy {
    static func decision(
        batch: GeneratedAssetReservationBatchRecord,
        project: CanvasProject
    ) -> GeneratedAssetReservationRecoveryDecision {
        guard project.id == batch.canvasID else { return .retain }
        guard let document = project.documents.first(where: {
            $0.id == batch.documentID
        }) else { return .abandon }

        let nodesByID = Dictionary(
            uniqueKeysWithValues: document.nodes.map { ($0.id, $0) }
        )
        let exactMatches = batch.slots.filter { slot in
            guard let canonicalAssetID = slot.canonicalAssetID,
                  let node = nodesByID[slot.resultNodeID] else { return false }
            return node.asset?.id == canonicalAssetID
                && node.metadata["generationAttemptID"]
                    == batch.generationAttemptID
        }.count
        if batch.slots.count == batch.expectedCount,
           exactMatches == batch.expectedCount {
            return .finalize
        }
        if exactMatches > 0 { return .retain }

        // A ready owner with no exact results is internally inconsistent, not
        // proof that the reservation is unused. Preserve it for diagnosis.
        if let configuration = nodesByID[batch.configurationNodeID],
           configuration.metadata["generationAttemptID"]
                == batch.generationAttemptID,
           configuration.metadata["generationState"]
                == CanvasGenerationTaskState.ready.rawValue {
            return .retain
        }
        return .abandon
    }
}

/// Main-actor activity guard for the actor-reentrant gap while the durable
/// batch insert awaits the database. Registration happens synchronously before
/// `persist` can suspend; a successful begin stays active until the caller
/// explicitly finalizes or abandons the batch.
@MainActor
final class GeneratedAssetReservationActivityRegistry {
    private var activeIDs = Set<UUID>()

    func begin(
        id: UUID,
        persist: @MainActor () async throws -> Void
    ) async throws {
        activeIDs.insert(id)
        do {
            try await persist()
        } catch {
            activeIDs.remove(id)
            throw error
        }
    }

    func finish(id: UUID) {
        activeIDs.remove(id)
    }

    func shouldReconcile(id: UUID) -> Bool {
        !activeIDs.contains(id)
    }
}

@MainActor
final class MediaGenerationService {
    private unowned let environment: AppEnvironment
    private let generatedAssetReservationActivity =
        GeneratedAssetReservationActivityRegistry()

    init(environment: AppEnvironment) { self.environment = environment }

    /// Generates or edits one exact-cardinality image batch and persists it.
    /// The returned reservation token must be finalized only after the Canvas
    /// project-file commit, or abandoned when publication fails.
    func generateImages(
        prompt: String,
        options: ImageGenerationOptions = .init(),
        sourceImages: [Data] = [],
        modelID: UUID? = nil,
        owner: GeneratedImageReservationOwner
    ) async throws -> ReservedGeneratedImageBatch {
        let center = environment.conversationCenter
        let operation: RemoteImageOperation = sourceImages.isEmpty ? .generate : .edit
        let selected = modelID.flatMap { center.mediaProviderAndModel(modelID: $0) }
            ?? center.auxiliaryProviderAndModel(for: operation == .generate ? .generate : .edit)
        guard let (provider, model) = selected,
              let adapter = ImageProviderAdapterFactory().adapter(for: provider),
              adapter.supports(operation, for: provider) else {
            throw FloeError.invalidConfiguration(
                operation == .generate
                    ? "请先在辅助模型中选择可用的生图模型。"
                    : "所选模型或服务商不支持参考图编辑。"
            )
        }
        let traceID = UUID()
        let startedAt = Date()
        let maximumReferences = operation == .generate ? 0
            : ImageReferenceCapabilityResolver.maximumReferenceImages(
                provider: provider,
                model: model
            )
        guard sourceImages.count <= maximumReferences else {
            throw FloeError.validationFailed(
                "所选图片模型最多支持 \(maximumReferences) 张参考图；当前有 \(sourceImages.count) 张。请减少连接到生成节点的参考图，或改用支持更多参考图的模型。"
            )
        }
        let requestedOutputCount = max(1, min(options.count, 4))
        guard owner.resultNodeIDs.count == requestedOutputCount,
              !owner.generationAttemptID.isEmpty,
              Set(owner.resultNodeIDs).count == requestedOutputCount else {
            throw FloeError.validationFailed(
                "Generated asset reservation owner does not match the requested output count"
            )
        }
        let maximumOutputs = max(1, adapter.maximumOutputImages(
            modelRemoteID: model.remoteModelID
        ))
        guard requestedOutputCount <= maximumOutputs else {
            throw FloeError.validationFailed(
                "所选图片模型单次最多生成 \(maximumOutputs) 张图片；当前请求 \(requestedOutputCount) 张。请减少生成数量，或改用支持多图输出的模型。"
            )
        }
        let qualityLooksLikeResolution = options.quality.map {
            ["1K", "2K", "4K"].contains($0.uppercased())
        } ?? false
        let selection = ImageGenerationSelection(
            aspectRatio: options.aspectRatio,
            resolution: options.resolution ?? (qualityLooksLikeResolution ? options.quality : nil),
            quality: qualityLooksLikeResolution ? nil : options.quality,
            nativeSizeOverride: options.size
        )
        let resolvedSize = try ImageGenerationPresetResolver.nativeSize(
            provider: provider.kind, modelRemoteID: model.remoteModelID,
            operation: operation, selection: selection
        )
        let referenceBytes = sourceImages.reduce(0) { $0 + $1.count }
        FloeLogger(category: .providers).info(
            "imageGenerationStarted trace=\(traceID.uuidString) operation=\(operation.rawValue) provider=\(String(describing: provider.kind)) model=\(model.remoteModelID) aspect=\(selection.aspectRatio ?? "auto") size=\(resolvedSize ?? selection.resolution ?? "auto") references=\(sourceImages.count) referenceBytes=\(referenceBytes) count=\(requestedOutputCount)"
        )
        let result: RemoteImageResult
        do {
            result = try await adapter.perform(
                RemoteImageRequest(
                    operation: operation, prompt: prompt,
                    sourceImages: sourceImages,
                    selection: selection,
                    count: requestedOutputCount,
                    modelRemoteID: model.remoteModelID
                ),
                provider: provider,
                credentials: center.resolveCredentials(for: provider)
            )
        } catch {
            let nsError = error as NSError
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
            FloeLogger(category: .providers).warning(
                "imageGenerationFailed trace=\(traceID.uuidString) operation=\(operation.rawValue) provider=\(String(describing: provider.kind)) references=\(sourceImages.count) durationMs=\(elapsed) domain=\(nsError.domain) code=\(nsError.code)"
            )
            throw error
        }
        FloeLogger(category: .providers).info(
            "imageGenerationCompleted trace=\(traceID.uuidString) operation=\(operation.rawValue) provider=\(String(describing: provider.kind)) images=\(result.images.count) durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1_000))"
        )
        // This must remain above every file/database write. Otherwise a short
        // or oversized provider response leaves zero-reference orphan assets.
        let returnedImages = try MediaGenerationImageBatchContract.validatedImages(
            result.images,
            requestedOutputCount: requestedOutputCount
        )
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let reservationID = UUID()
        let preparedImages = returnedImages.enumerated().map { index, data in
            let candidateID = UUID()
            let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            return (
                index: index,
                data: data,
                contentHash: SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined(),
                isPNG: isPNG,
                candidateID: candidateID,
                candidateRelativePath: MediaGenerationAssetReusePolicy
                    .generatedRelativePath(
                        assetID: candidateID,
                        isPNG: isPNG
                    )
            )
        }
        try await generatedAssetReservationActivity.begin(id: reservationID) {
            try await environment.creativeAssetStore
                .beginGeneratedAssetReservationBatch(
                    id: reservationID,
                    canvasID: owner.canvasID,
                    documentID: owner.documentID,
                    configurationNodeID: owner.configurationNodeID,
                    generationAttemptID: owner.generationAttemptID,
                    slots: preparedImages.map { prepared in
                        GeneratedAssetReservationSlotDraft(
                            index: prepared.index,
                            resultNodeID: owner.resultNodeIDs[prepared.index],
                            candidateAssetID: prepared.candidateID,
                            contentHash: prepared.contentHash,
                            candidateRelativePath: prepared.candidateRelativePath
                        )
                    }
                )
        }
        var assets: [CanvasAssetReference] = []
        var writtenURLs: [URL] = []
        do {
            for prepared in preparedImages {
                let candidateDestination = try MediaGenerationAssetReusePolicy.localURL(
                    relativePath: prepared.candidateRelativePath,
                    applicationSupportRoot: support
                )
                try FileManager.default.createDirectory(
                    at: candidateDestination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try prepared.data.write(to: candidateDestination, options: .atomic)
                writtenURLs.append(candidateDestination)
                var canonical = try await environment.creativeAssetStore
                    .reserveGeneratedAsset(
                        batchID: reservationID,
                        slotIndex: prepared.index,
                        candidate: CreativeAssetRecord(
                    id: prepared.candidateID,
                    contentHash: prepared.contentHash,
                    kind: .image,
                    displayName: result.images.count > 1
                        ? "生成图片 \(prepared.index + 1)" : "生成图片",
                    mimeType: prepared.isPNG ? "image/png" : "image/jpeg",
                    localRelativePath: prepared.candidateRelativePath,
                    byteCount: Int64(prepared.data.count),
                    tags: ["生成内容"],
                    referenceCount: 0
                ))
                if canonical.id == prepared.candidateID {
                    // The durable reservation now owns this canonical file.
                    // Batch abandonment/reconciliation decides its cleanup.
                    writtenURLs.removeAll { $0 == candidateDestination }
                }

                let mustCanonicalizeCandidatePath = MediaGenerationAssetReusePolicy
                    .usesThrowawayCandidatePath(
                        record: canonical,
                        candidateID: prepared.candidateID,
                        candidateRelativePath: prepared.candidateRelativePath
                    )
                var reference = mustCanonicalizeCandidatePath ? nil
                    : MediaGenerationAssetReusePolicy.localReferenceIfAvailable(
                        for: canonical,
                        applicationSupportRoot: support
                    )
                if reference != nil {
                    if canonical.id != prepared.candidateID {
                        try FileManager.default.removeItem(at: candidateDestination)
                        writtenURLs.removeAll { $0 == candidateDestination }
                    }
                } else {
                    // A reused row may outlive a missing local copy. Repair it
                    // at the canonical asset ID path, never at this request's
                    // throwaway candidate UUID path.
                    let canonicalRelativePath = MediaGenerationAssetReusePolicy
                        .generatedRelativePath(
                            assetID: canonical.id,
                            isPNG: prepared.isPNG
                        )
                    let canonicalDestination = try MediaGenerationAssetReusePolicy.localURL(
                        relativePath: canonicalRelativePath,
                        applicationSupportRoot: support
                    )
                    if canonicalDestination != candidateDestination {
                        if FileManager.default.fileExists(
                            atPath: canonicalDestination.path
                        ) {
                            try FileManager.default.removeItem(at: canonicalDestination)
                        }
                        try FileManager.default.moveItem(
                            at: candidateDestination,
                            to: canonicalDestination
                        )
                        writtenURLs.removeAll { $0 == candidateDestination }
                        writtenURLs.append(canonicalDestination)
                    }
                    canonical.localRelativePath = canonicalRelativePath
                    canonical.mimeType = prepared.isPNG ? "image/png" : "image/jpeg"
                    canonical.byteCount = Int64(prepared.data.count)
                    try await environment.creativeAssetStore.save(canonical)
                    writtenURLs.removeAll { $0 == canonicalDestination }
                    reference = CanvasAssetReference(
                        id: canonical.id,
                        contentHash: canonical.contentHash,
                        localRelativePath: canonicalRelativePath,
                        mimeType: canonical.mimeType,
                        byteCount: canonical.byteCount,
                        sourceURL: canonical.sourceURL,
                        license: canonical.license
                    )
                }
                guard let reference else {
                    throw FloeError.storageCorrupted(
                        "Generated image canonical asset has no readable local copy"
                    )
                }
                assets.append(reference)
            }
        } catch {
            await abandonGeneratedAssetReservation(id: reservationID)
            for url in writtenURLs where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        return ReservedGeneratedImageBatch(
            reservationID: reservationID,
            assets: assets
        )
    }

    func markGeneratedAssetsReferenced(
        _ batch: ReservedGeneratedImageBatch
    ) async {
        defer {
            generatedAssetReservationActivity.finish(id: batch.reservationID)
        }
        do {
            try await environment.creativeAssetStore
                .finalizeGeneratedAssetReservationBatch(
                    id: batch.reservationID
                )
        } catch {
            // The Canvas file is already authoritative. Keep the ledger pending
            // so launch recovery can finalize it without decrementing a live
            // reference.
            FloeLogger(category: .providers).warning(
                "generatedAssetReservationFinalizeDeferred batch=\(batch.reservationID.uuidString)"
            )
        }
    }

    func discardUnreferencedGeneratedAssets(
        _ batch: ReservedGeneratedImageBatch
    ) async {
        await abandonGeneratedAssetReservation(id: batch.reservationID)
    }

    func reconcileGeneratedAssetReservations() async {
        let batches: [GeneratedAssetReservationBatchRecord]
        do {
            batches = try await environment.creativeAssetStore
                .pendingGeneratedAssetReservationBatches()
        } catch {
            FloeLogger(category: .providers).warning(
                "generatedAssetReservationReconcileDeferred reason=storeUnreadable"
            )
            return
        }
        for batch in batches where generatedAssetReservationActivity
            .shouldReconcile(id: batch.id) {
            let project: CanvasProject
            do {
                project = try WorkspaceCanvasRegistry.project(
                    canvasID: batch.canvasID
                )
            } catch {
                // A missing or unreadable Canvas is ambiguous until workspace
                // and cloud restoration have completed. Retaining a reservation
                // is safer than deleting a potentially live generated file.
                FloeLogger(category: .providers).warning(
                    "generatedAssetReservationRetained batch=\(batch.id.uuidString) reason=canvasUnreadable"
                )
                continue
            }
            switch GeneratedAssetReservationRecoveryPolicy.decision(
                batch: batch,
                project: project
            ) {
            case .finalize:
                do {
                    try await environment.creativeAssetStore
                        .finalizeGeneratedAssetReservationBatch(id: batch.id)
                } catch {
                    FloeLogger(category: .providers).warning(
                        "generatedAssetReservationReconcileDeferred batch=\(batch.id.uuidString) action=finalize"
                    )
                }
            case .abandon:
                await abandonGeneratedAssetReservation(id: batch.id)
            case .retain:
                FloeLogger(category: .providers).warning(
                    "generatedAssetReservationRetained batch=\(batch.id.uuidString) reason=partialOrInconsistentCanvas"
                )
            }
        }
    }

    private func abandonGeneratedAssetReservation(id: UUID) async {
        defer { generatedAssetReservationActivity.finish(id: id) }
        let abandonment: GeneratedAssetReservationAbandonment
        do {
            abandonment = try await environment.creativeAssetStore
                .abandonGeneratedAssetReservationBatch(id: id)
        } catch {
            FloeLogger(category: .providers).warning(
                "generatedAssetReservationReleaseDeferred batch=\(id.uuidString) reason=storageRejected"
            )
            return
        }
        await cleanupAbandonedGeneratedAssetReservation(
            abandonment
        )
    }

    private func cleanupAbandonedGeneratedAssetReservation(
        _ abandonment: GeneratedAssetReservationAbandonment
    ) async {
        guard !abandonment.slots.isEmpty
                || !abandonment.deletedLocalRelativePaths.isEmpty else { return }
        let support: URL
        do {
            support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false
            )
        } catch {
            return
        }
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .standardizedFileURL

        // Unbound and losing-deduplication candidates can never be a canonical
        // Canvas reference. Their durable slot path makes post-crash cleanup
        // deterministic.
        for slot in abandonment.slots
        where slot.canonicalAssetID != slot.candidateAssetID {
            guard !slot.candidateRelativePath.contains("..") else { continue }
            let url = root.appendingPathComponent(
                slot.candidateRelativePath
            ).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }

        // The persistence transaction already proved provenance, zero
        // references, and absence of committed owners before deleting each
        // catalog row. Only those returned paths may now be unlinked.
        for relativePath in abandonment.deletedLocalRelativePaths {
            guard !relativePath.contains("..") else { continue }
            let url = root.appendingPathComponent(relativePath).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                FloeLogger(category: .providers).warning(
                    "generatedAssetCleanupDeferred reason=fileRemovalFailed"
                )
            }
        }
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
        guard !job.state.isTerminal else {
            return
        }
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
