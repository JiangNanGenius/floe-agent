#if canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks
import CryptoKit
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence
import FloeProviders
import FloeSync
import FloeTools
import FloeAgentRuntime

extension Notification.Name {
    static let floeOpenConversation = Notification.Name("org.floeagent.open-conversation")
    /// Deep link for Linux session/service work: the app presents the
    /// execution-environment surface (optionally focused on one environment).
    /// `userInfo` carries the raw `BackgroundWorkDeepLink` payload keys.
    static let floeOpenExecutionEnvironment = Notification.Name("org.floeagent.open-execution-environment")
}

/// Exponential media-refresh backoff: 15s doubling per retry, capped at 30
/// minutes. Extracted because two scheduling paths previously duplicated the
/// same formula.
enum MediaRetryBackoff {
    static let maximum: TimeInterval = 30 * 60

    static func delay(afterRetryCount count: Int) -> TimeInterval {
        min(maximum, pow(2, Double(min(count, 8))) * 15)
    }
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
        /// When this workload first reported itself; used for the completion
        /// dwell's honest elapsed-time caption.
        var startedAt = Date()
        let continuedProcessingOrigin: ContinuedProcessingStartOrigin
        let allowsContinuedProcessing: Bool
        let retainsSurfaceOnFailure: Bool
        let sendsTerminalNotification: Bool
        var stage: String = "正在运行"
        var progress: Int64 = 5
        var stageStartedAt = Date()
        var lastActivityAt = Date()
        var outputWindowStartedAt = Date()
        var outputCharacters = 0
        var reportedTokensPerSecond: Double?
        var isGenerating = false
        var checklist: TaskChecklist?
        /// Live tool activity for the floating surface: what is running right
        /// now and how the run's tool calls have fared so far.
        var currentToolName: String?
        var pendingApprovalToolName: String?
        var toolCallCount = 0
        var toolFailureCount = 0

        func presentation(now: Date = Date()) -> String {
            let elapsed = max(0, Int(now.timeIntervalSince(stageStartedAt)))
            let idle = max(0, Int(now.timeIntervalSince(lastActivityAt)))
            // The speed figure is the model's decode rate only; it never
            // appears during tool phases and never counts tool output bytes.
            let speed: String
            if isGenerating, let rate = reportedTokensPerSecond, rate.isFinite, rate >= 0, idle < 5 {
                speed = String(format: " · 模型 %.1f tokens/s", rate)
            } else if isGenerating, outputCharacters > 0, idle < 5 {
                speed = String(format: " · %.1f 字符/秒", Double(outputCharacters) / max(1, now.timeIntervalSince(outputWindowStartedAt)))
            } else { speed = "" }
            let activity = idle < 3 ? "刚收到活动" : "距上次活动 \(idle) 秒"
            // Bound the step caption so long titles leave room for real activity.
            let step = checklist?.currentStep.map { String($0.title.prefix(20)).replacingOccurrences(of: "\n", with: " ") }
            let task = checklist.map { "\n\($0.progressSummary)" + (step.map { "\n当前：\($0)" } ?? "") } ?? ""
            var toolLine = ""
            if let pending = pendingApprovalToolName {
                toolLine = "\n等待审批：\(pending)"
            } else if let tool = currentToolName {
                let failures = toolFailureCount > 0 ? " · 失败 \(toolFailureCount)" : ""
                toolLine = "\n工具：\(tool) · 第 \(toolCallCount) 次调用\(failures)"
            } else if toolCallCount > 0 {
                let failures = toolFailureCount > 0 ? " · 失败 \(toolFailureCount)" : ""
                toolLine = "\n工具调用 \(toolCallCount) 次\(failures)"
            }
            return "\(stage)\n本阶段 \(elapsed) 秒\(speed)\n\(activity)\(task)\(toolLine)"
        }
    }
    private var activeRuns: [UUID: ActiveRun] = [:]
    /// Successfully finished run shown for the completion dwell. Never
    /// restorable after the dwell: the owner removes the work record.
    private var dwellCompletedRun: (id: UUID, run: ActiveRun)?
    /// Monotonic generation of the current visual-surface owner. A newer run
    /// bumps it so a delayed teardown from an older run cannot close the
    /// surface that now belongs to the new one.
    private var visualSurfaceGeneration: UInt64 = 0
    private var visualSurfaceTeardownTask: Task<Void, Never>?
    /// One durable "allow background running" preference per Linux
    /// environment. Build 221 stored only a bare list of environment ids; the
    /// v2 record keeps the same user choice and migrates once.
    private var linuxBackgroundPreferences: [String: LinuxBackgroundRunPreference] = [:]
    /// Pure state machine for the PiP hold. A user PiP close ends the current
    /// hold (and the VM is stopped) but never clears the preference.
    private var linuxBackgroundHold = LinuxBackgroundHoldPolicy()
    /// Point-in-time surface data for every running/held Linux environment,
    /// including CPU, memory and the command/service/port counts.
    private var linuxSurfaceEntries: [String: LinuxBackgroundSurfaceEntry] = [:]
    /// Multi-VM pager for the floating surface (one VM per page).
    private var linuxSurfacePager = LinuxBackgroundSurfacePager()
    /// Per-environment port count published from the active forward plans.
    private var linuxPortCounts: [String: Int] = [:]
    /// Bounded probe result for runner-owned guest commands; nil = unknown.
    private var linuxCommandCounts: [String: Int] = [:]
    /// Durable terminal-event outbox: the first-authorization race queues an
    /// event instead of dropping it.
    private var notificationOutbox = TaskNotificationOutbox()
    private var notificationAuthorization: NotificationAuthorizationState = .notDetermined
    private var linuxPortCenter: LinuxPortForwardCenter { .shared }
    private var linuxMetricsSamplers: [String: LinuxGuestMetricsSampler] = [:]
    private var linuxMetricsTasks: [String: Task<Void, Never>] = [:]
    private var lastSkippedContinuedUpdateAt: Date = .distantPast
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
        database: environment.database,
        onReady: { [weak self] jobID in
            guard let self else { return }
            await self.environment.mediaGenerationService.deliverReadyMediaJob(jobID: jobID)
        }
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

    /// A Linux background session is its own explicit user request for the
    /// system continued-processing mechanism. The conversation surface
    /// preference (standard/PiP/screen share) governs the optional PiP
    /// surface, never whether the user's Linux keep-alive task exists.
    nonisolated static func shouldSubmitLinuxSessionContinuedProcessing(
        origin: ContinuedProcessingStartOrigin,
        launchPreferencesLoaded: Bool,
        hasAggregateForegroundScene: Bool
    ) -> Bool {
        origin.allowsContinuedSubmission
            && launchPreferencesLoaded
            && hasAggregateForegroundScene
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
        // The release gate may downgrade a PiP choice to the standard path;
        // reconcile against what the app actually honors.
        let honored = StatusPiPReleaseGate.effectivePreference(
            preference,
            statusPiPEnabled: StatusPiPReleaseGate.isEnabled
        )
        if #available(iOS 26.0, *) {
            let launchPreferencesLoaded = environment.settingsCenter.launchPreferencesLoaded
            let keepsConversationTask = Self.shouldKeepContinuedProcessing(
                for: honored,
                launchPreferencesLoaded: launchPreferencesLoaded
            )
            let keepsLinuxSessionTask = launchPreferencesLoaded && !linuxBackgroundEnabledEnvironmentIDs().isEmpty
            if keepsConversationTask || keepsLinuxSessionTask {
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
                } else if !keepsLinuxSessionTask {
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
        let transition = Self.visualSurfaceTransition(for: honored)
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
                progress: candidate.value.presentation(),
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

    /// The execution preference the app may actually honor. Status PiP is an
    /// opt-in surface behind `StatusPiPReleaseGate`; when the gate is
    /// disabled, a PiP choice degrades to the compliant standard path (30s
    /// lease + system continued processing) instead of creating a controller.
    private var effectiveBackgroundExecutionPreference: BackgroundExecutionPreference {
        StatusPiPReleaseGate.effectivePreference(
            environment.settingsCenter.backgroundExecution,
            statusPiPEnabled: StatusPiPReleaseGate.isEnabled
        )
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
        let preference = effectiveBackgroundExecutionPreference
        let loaded = environment.settingsCenter.launchPreferencesLoaded
        guard Self.shouldSubmitContinuedProcessing(
            for: preference,
            launchPreferencesLoaded: loaded,
            origin: origin,
            hasAggregateForegroundScene: hasAggregateForegroundScene
        ) else {
            let keepsConversationTask = Self.shouldKeepContinuedProcessing(
                for: preference,
                launchPreferencesLoaded: loaded
            )
            // An enabled Linux background session keeps its own system task,
            // even while the chat surface preference is a visual mode.
            let keepsLinuxSessionTask = loaded && !linuxBackgroundEnabledEnvironmentIDs().isEmpty
            if !keepsConversationTask, !keepsLinuxSessionTask, #available(iOS 26.0, *) {
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
        // Build 222: one durable per-environment preference. The legacy
        // keep-alive list is imported once and then removed.
        LinuxBackgroundRunPreferences.migrateLegacyIfNeeded()
        self.linuxBackgroundPreferences = LinuxBackgroundRunPreferences.load()
        self.notificationOutbox = TaskNotificationOutboxStore.load()
        super.init()
        Task { [weak self] in
            await self?.refreshNotificationAuthorizationAndFlush()
        }
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
            Task { [weak self] in
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                // The answer resolves the first-authorization race: anything
                // queued while it was pending is flushed now.
                await self?.refreshNotificationAuthorizationAndFlush()
            }
        }
        visualSurfacePolicy.beginRun(
            runID, currentlyActiveRunIDs: Set(activeRuns.keys)
        )
        persistVisualSurfacePolicy()
        retainedPausedRun = nil
        // A new run owns the surface again: cancel and invalidate any pending
        // success teardown from the previous run.
        invalidateVisualSurfaceTeardown()
        dwellCompletedRun = nil
        let run = ActiveRun(
            conversationID: conversationID,
            title: title,
            continuedProcessingOrigin: origin,
            allowsContinuedProcessing: true,
            retainsSurfaceOnFailure: true,
            sendsTerminalNotification: true
        )
        activeRuns[runID] = run
        _ = continuedEligibility.registerRun(runID, origin: origin)
        publishRunWork(
            runID: runID,
            title: title,
            conversationID: conversationID,
            startedAt: run.startedAt,
            state: .running,
            progressText: "正在运行"
        )
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
        // Media work takes the surface too: invalidate any pending success
        // teardown from a run that just finished.
        invalidateVisualSurfaceTeardown()
        dwellCompletedRun = nil
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
    /// Only actual runtime/provider events advance activity. Rendering a PiP
    /// frame never implies that a tool or the remote model made progress.
    func didReceiveActivity(runID: UUID, at date: Date = Date(), characters: Int = 0, tokensPerSecond: Double? = nil) {
        guard var active = activeRuns[runID] else { return }
        active.lastActivityAt = max(active.lastActivityAt, date)
        if characters > 0 {
            if date.timeIntervalSince(active.outputWindowStartedAt) > 5 {
                active.outputWindowStartedAt = date
                active.outputCharacters = 0
            }
            active.outputCharacters += characters
        }
        if let tokensPerSecond { active.reportedTokensPerSecond = tokensPerSecond }
        activeRuns[runID] = active
    }

    /// Live tool activity for the floating surface. `finished` clears the
    /// "currently running" tool; failures bump the visible failure counter.
    func didUpdateTool(runID: UUID, name: String, outcome: ToolSurfaceOutcome) {
        guard var active = activeRuns[runID] else { return }
        switch outcome {
        case .started:
            active.currentToolName = name
            active.toolCallCount += 1
            active.lastActivityAt = Date()
        case .finished(let failed):
            if active.currentToolName == name { active.currentToolName = nil }
            if failed { active.toolFailureCount += 1 }
            active.lastActivityAt = Date()
        }
        activeRuns[runID] = active
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: active.presentation())
        }
    }

    func didUpdatePendingApproval(runID: UUID, toolName: String?) {
        guard var active = activeRuns[runID] else { return }
        guard active.pendingApprovalToolName != toolName else { return }
        active.pendingApprovalToolName = toolName
        activeRuns[runID] = active
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: active.presentation())
        }
    }

    enum ToolSurfaceOutcome: Sendable, Equatable {
        case started
        case finished(failed: Bool)
    }

    /// Checklist revisions are shared with chat. This is plan bookkeeping,
    /// not a provider heartbeat and not evidence that the overall Goal is done.
    func didUpdateChecklist(runID: UUID, checklist: TaskChecklist) {
        guard var active = activeRuns[runID],
              checklist.canReplace(active.checklist, conversationID: active.conversationID) else { return }
        active.checklist = checklist
        activeRuns[runID] = active
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: active.presentation())
        }
    }

    func didUpdateProgress(runID: UUID, stage: String, progress: Int64, isGenerating: Bool = false) {
        guard var active = activeRuns[runID] else { return }
        if active.stage != stage {
            active.stageStartedAt = Date()
            active.outputWindowStartedAt = Date()
            active.outputCharacters = 0
            active.reportedTokensPerSecond = nil
        }
        active.stage = stage
        active.isGenerating = isGenerating
        active.progress = progress
        activeRuns[runID] = active
        if #available(iOS 26.0, *),
           active.allowsContinuedProcessing,
           active.continuedProcessingOrigin.allowsContinuedSubmission {
            updateContinuedTask(title: "Floe Agent", stage: stage, progress: progress)
        }
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: active.presentation())
        }
        publishRunWork(
            runID: runID,
            title: active.title,
            conversationID: active.conversationID,
            startedAt: active.startedAt,
            state: .running,
            progress: Double(active.progress) / 100,
            progressText: stage
        )
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
        publishRunWork(
            runID: runID,
            title: active.title,
            conversationID: active.conversationID,
            startedAt: active.startedAt,
            state: .suspended,
            interruption: .checkpointed,
            progress: Double(active.progress) / 100,
            progressText: message
        )
    }

    /// The three terminal outcomes a provider run can reach. Cancellation is
    /// its own kind so a policy that only reports failures stays quiet and the
    /// durable event still records what really happened.
    enum TerminalOutcome: Sendable, Equatable {
        case succeeded
        case failed
        case cancelled

        var succeeded: Bool { self == .succeeded }

        var state: BackgroundWorkState {
            switch self {
            case .succeeded: .completed
            case .failed: .failed
            case .cancelled: .cancelled
            }
        }

        var interruption: BackgroundWorkInterruption {
            switch self {
            case .succeeded, .cancelled: .none
            case .failed: .checkpointed
            }
        }
    }

    func didFinish(runID: UUID, succeeded: Bool, message: String?) {
        finishRun(
            runID: runID,
            outcome: succeeded ? .succeeded : .failed,
            message: message
        )
    }

    /// The user (or the system) cancelled the run. The work record and the
    /// durable notification both report cancellation instead of a failure.
    func didCancel(runID: UUID, message: String?) {
        finishRun(runID: runID, outcome: .cancelled, message: message)
    }

    private func finishRun(runID: UUID, outcome: TerminalOutcome, message: String?) {
        guard let finished = activeRuns.removeValue(forKey: runID) else { return }
        let succeeded = outcome.succeeded
        continuedEligibility.finishRun(runID)
        visualSurfacePolicy.finishRun(runID)
        persistVisualSurfacePolicy()
        FloeLogger(category: .app).info(
            "backgroundRunFinished run=\(runID.uuidString) succeeded=\(succeeded) remainingRuns=\(activeRuns.count)"
        )
        let conversationID = finished.conversationID
        notifiedApprovalRuns.remove(runID)
        if finished.sendsTerminalNotification, let conversationID {
            notifyTerminal(
                conversationID: conversationID,
                runID: runID,
                outcome: outcome,
                message: message
            )
        }
        if #available(iOS 26.0, *), !continuedEligibility.hasEligibleWork {
            finishContinuedTasks(success: succeeded)
        }
        finishRunWork(
            runID: runID,
            title: finished.title,
            conversationID: conversationID,
            startedAt: finished.startedAt,
            outcome: outcome,
            message: message
        )
        // The completion policy decides the surface's terminal behavior. A
        // newer run bumps the generation, so a delayed teardown scheduled
        // here can only close the surface it was scheduled for.
        let plan = BackgroundSurfaceCompletionPolicy.plan(
            succeeded: succeeded,
            // A cancellation is user intent, not a recoverable failure: only
            // a real failure keeps the recovery surface alive.
            retainsSurfaceOnFailure: outcome == .failed && finished.retainsSurfaceOnFailure,
            generation: bumpVisualSurfaceGeneration()
        )
        let wasSurfaced = surfacedRunID == runID
        switch plan.disposition {
        case .dwellThenTearDown:
            if activeRuns.isEmpty, linuxBackgroundHold.hasActiveHold {
                // A held Linux VM owns the surface now: hand it back instead
                // of tearing the surface down under the user.
                dwellCompletedRun = nil
                surfacedRunID = nil
                resumeBackgroundSurfaceIfNeeded()
            } else if activeRuns.isEmpty {
                dwellCompletedRun = (runID, finished)
                retainedPausedRun = nil
                if wasSurfaced {
                    environment.backgroundVideoService.update(
                        title: finished.title,
                        progress: Self.completedSurfaceText(for: finished)
                    )
                }
                scheduleSuccessSurfaceTeardown(generation: plan.generation, dwell: plan.delay)
            } else {
                dwellCompletedRun = nil
                if wasSurfaced {
                    surfacedRunID = nil
                    resumeBackgroundSurfaceIfNeeded()
                }
            }
        case .retainForRecovery:
            dwellCompletedRun = nil
            if activeRuns.isEmpty {
                // A failed/checkpointed task is paused work, not completed
                // work. Keep the user-owned surface alive with the real
                // failure reason and the recovery action so reopening the
                // task offers a path forward instead of a silent
                // disappearance.
                surfacedRunID = runID
                retainedPausedRun = (runID, finished)
                environment.backgroundVideoService.update(
                    title: finished.title,
                    progress: Self.failedSurfaceText(for: finished, message: message)
                )
                FloeLogger(category: .app).info(
                    "backgroundSurfaceRetained reason=unfinishedRun run=\(runID.uuidString)"
                )
            } else if wasSurfaced {
                surfacedRunID = nil
                resumeBackgroundSurfaceIfNeeded()
            }
        case .tearDownImmediately:
            dwellCompletedRun = nil
            if activeRuns.isEmpty, linuxBackgroundHold.hasActiveHold {
                retainedPausedRun = nil
                surfacedRunID = nil
                resumeBackgroundSurfaceIfNeeded()
            } else if activeRuns.isEmpty {
                retainedPausedRun = nil
                tearDownBackgroundExecutionPreference()
            } else if wasSurfaced {
                surfacedRunID = nil
                resumeBackgroundSurfaceIfNeeded()
            }
        }
    }

    /// Honest success caption for the completion dwell: the real outcome and
    /// the run's measured elapsed time. No invented progress.
    nonisolated static func completedSurfaceText(for run: (title: String, startedAt: Date), now: Date = Date()) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(run.startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let duration = minutes > 0 ? "\(minutes) 分 \(seconds) 秒" : "\(seconds) 秒"
        return "\(run.title)\n已完成 · 用时 \(duration)"
    }

    private nonisolated static func completedSurfaceText(for run: ActiveRun) -> String {
        completedSurfaceText(for: (title: run.title, startedAt: run.startedAt))
    }

    /// Actionable failure caption: the failure reason plus what the user can
    /// do. The durable recovery point is written by ConversationCenter; this
    /// text never claims the run is still working.
    private nonisolated static func failedSurfaceText(for run: ActiveRun, message: String?) -> String {
        var lines = [run.title, "运行失败 · 打开 Floe 可恢复"]
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(String(message.prefix(80)))
        }
        return lines.joined(separator: "\n")
    }

    /// Invalidates any pending success teardown and returns the new
    /// generation for the caller to schedule against.
    @discardableResult
    private func bumpVisualSurfaceGeneration() -> UInt64 {
        visualSurfaceGeneration &+= 1
        visualSurfaceTeardownTask?.cancel()
        visualSurfaceTeardownTask = nil
        return visualSurfaceGeneration
    }

    private func invalidateVisualSurfaceTeardown() {
        _ = bumpVisualSurfaceGeneration()
    }

    /// Success dwell: keep the Completed state visible for the policy's dwell,
    /// then tear the surface down — but only while this schedule is still the
    /// current generation. A newer run cancels the task and bumps the
    /// generation, so a stale timer can never close the new surface.
    private func scheduleSuccessSurfaceTeardown(generation: UInt64, dwell: TimeInterval) {
        visualSurfaceTeardownTask?.cancel()
        visualSurfaceTeardownTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(0, dwell)))
            } catch {
                return
            }
            guard let self else { return }
            guard BackgroundSurfaceCompletionPolicy.teardownIsCurrent(
                scheduledGeneration: generation,
                currentGeneration: self.visualSurfaceGeneration
            ) else {
                FloeLogger(category: .app).info(
                    "backgroundSurfaceTeardownSkipped reason=staleGeneration scheduled=\(generation) current=\(self.visualSurfaceGeneration)"
                )
                return
            }
            self.visualSurfaceTeardownTask = nil
            if let completed = self.dwellCompletedRun {
                self.dwellCompletedRun = nil
                Task { await BackgroundWorkRegistry.shared.remove(id: completed.id) }
            }
            self.tearDownBackgroundExecutionPreference()
        }
    }

    // MARK: - Shared background-work records

    /// Publishes a conversation-run snapshot into the app-wide registry so the
    /// status surface, notifications and diagnostics read one model.
    private func publishRunWork(
        runID: UUID,
        title: String,
        conversationID: UUID?,
        startedAt: Date,
        state: BackgroundWorkState,
        interruption: BackgroundWorkInterruption = .none,
        progress: Double? = nil,
        progressText: String,
        activeCommandCount: Int = 0
    ) {
        let snapshot = BackgroundWorkSnapshot(
            id: runID,
            kind: .modelRun,
            title: title,
            state: state,
            interruption: interruption,
            progress: progress,
            progressText: progressText,
            startedAt: startedAt,
            activeCommandCount: activeCommandCount,
            deepLink: BackgroundWorkDeepLink(
                kind: .modelRun,
                conversationID: conversationID,
                runID: runID
            )
        )
        Task { await BackgroundWorkRegistry.shared.register(snapshot) }
    }

    /// Records the terminal state. A failed run keeps its record (deep link +
    /// recovery) until the user resolves it; a completed run's record is
    /// removed after the completion dwell; a cancelled run keeps a plainly
    /// labelled terminal record.
    private func finishRunWork(
        runID: UUID,
        title: String,
        conversationID: UUID?,
        startedAt: Date,
        outcome: TerminalOutcome,
        message: String?
    ) {
        let succeeded = outcome.succeeded
        let text: String
        switch outcome {
        case .succeeded:
            text = Self.completedSurfaceText(for: (title: title, startedAt: startedAt))
        case .cancelled:
            text = message ?? "已取消 · 检查点已保留"
        case .failed:
            text = Self.failedSurfaceText(
                for: ActiveRun(
                    conversationID: conversationID,
                    title: title,
                    startedAt: startedAt,
                    continuedProcessingOrigin: .automaticTool,
                    allowsContinuedProcessing: false,
                    retainsSurfaceOnFailure: true,
                    sendsTerminalNotification: false
                ),
                message: message
            )
        }
        let snapshot = BackgroundWorkSnapshot(
            id: runID,
            kind: .modelRun,
            title: title,
            state: outcome.state,
            interruption: outcome.interruption,
            progress: succeeded ? 1 : nil,
            progressText: text,
            startedAt: startedAt,
            deepLink: BackgroundWorkDeepLink(
                kind: .modelRun,
                conversationID: conversationID,
                runID: runID
            )
        )
        Task { await BackgroundWorkRegistry.shared.register(snapshot) }
    }

    // MARK: - Notifications

    /// Maps the system authorization status into the platform-independent
    /// state the pure decision uses.
    nonisolated static func notificationAuthorizationState(
        _ status: UNAuthorizationStatus
    ) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .notDetermined
        }
    }

    /// Reads the real system authorization state. Never assumes authorized.
    static func currentNotificationAuthorization() async -> NotificationAuthorizationState {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(
                    returning: Self.notificationAuthorizationState(settings.authorizationStatus)
                )
            }
        }
    }

    /// Maps a persisted per-conversation policy onto the durable terminal-event
    /// vocabulary. Cancellation and action-required have their own rules; the
    /// default (missing policy) is the documented `.stages`.
    nonisolated static func eventGate(
        for policy: TaskNotificationPolicy?
    ) -> TaskNotificationEventGate {
        let policy = policy ?? .stages
        return TaskNotificationEventGate(
            notifiesCompleted: policy.shouldNotifyTerminal(succeeded: true),
            notifiesFailed: policy.shouldNotifyTerminal(succeeded: false),
            notifiesCancelled: policy.shouldNotifyCancellation,
            notifiesActionRequired: policy.shouldNotifyActionRequired
        )
    }

    /// Reads the real authorization state and flushes anything the
    /// first-authorization race queued. Called at launch, on foreground and
    /// after the system permission prompt resolves, so a terminal event that
    /// arrived before the answer is still delivered.
    func refreshNotificationAuthorizationAndFlush() async {
        let state = await Self.currentNotificationAuthorization()
        notificationAuthorization = state
        let presentable = notificationOutbox.takePresentable(canPresent: state.canPresentAlert)
        for event in presentable {
            post(event)
        }
        if !state.canPresentAlert, let first = notificationOutbox.pending.first {
            notificationOutbox.recordSchedulingFailure(
                identifier: first.identifier,
                reason: "notification authorization is \(state.rawValue)",
                wasAuthorizationBlocked: true
            )
        }
        persistNotificationOutbox()
    }

    /// Durable terminal event. Policy gates creation, authorization gates
    /// delivery: while authorization is missing the event stays queued and is
    /// flushed by `refreshNotificationAuthorizationAndFlush`, never dropped.
    /// Foreground and background both go through UNUserNotificationCenter; in
    /// the foreground `willPresent` shows the system banner.
    func enqueueTerminalNotification(
        kind: TaskTerminalEventKind,
        title: String,
        body: String,
        identifier: String,
        deepLink: BackgroundWorkDeepLink,
        policy: TaskNotificationPolicy? = nil
    ) {
        let gate = Self.eventGate(for: policy)
        guard gate.allows(kind) else { return }
        let event = TaskTerminalEvent(
            identifier: identifier,
            kind: kind,
            title: title,
            body: body,
            createdAt: Date(),
            deepLink: deepLink
        )
        let disposition = notificationOutbox.enqueue(
            event,
            canPresent: notificationAuthorization.canPresentAlert
        )
        switch disposition {
        case .presentNow:
            post(event)
        case .queuedForAuthorization, .replacedQueuedEvent:
            notificationOutbox.recordSchedulingFailure(
                identifier: identifier,
                reason: "notification authorization is \(notificationAuthorization.rawValue); event queued",
                wasAuthorizationBlocked: true
            )
            FloeLogger(category: .app).info(
                "notificationQueued identifier=\(identifier) authorization=\(self.notificationAuthorization.rawValue) pending=\(self.notificationOutbox.pendingCount)"
            )
        }
        persistNotificationOutbox()
    }

    private func post(_ event: TaskTerminalEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.userInfo = event.deepLink.userInfo
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: event.identifier, content: content, trigger: nil
        )) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.notificationOutbox.recordSchedulingFailure(
                        identifier: event.identifier,
                        reason: error.localizedDescription,
                        wasAuthorizationBlocked: false
                    )
                    // A system-side scheduling error must not lose the event:
                    // keep it queued for the next flush attempt.
                    _ = self.notificationOutbox.enqueue(event, canPresent: false)
                    FloeLogger(category: .app).warning(
                        "notificationSchedulingFailed identifier=\(event.identifier) reason=\(error.localizedDescription)"
                    )
                } else {
                    self.notificationOutbox.recordSchedulingSuccess(identifier: event.identifier)
                }
                self.persistNotificationOutbox()
            }
        }
    }

    private func persistNotificationOutbox() {
        TaskNotificationOutboxStore.save(notificationOutbox)
    }

    /// Real authorization plus the last scheduling failure/success for the
    /// diagnostics surface. Never assumes authorization.
    func notificationDiagnostics() -> TaskNotificationDiagnostics {
        TaskNotificationDiagnostics.make(
            outbox: notificationOutbox,
            authorization: notificationAuthorization.rawValue,
            canPresentAlert: notificationAuthorization.canPresentAlert
        )
    }

    /// Foreground delivery is a system notification too (no duplicated
    /// in-app banner): the system presents it because the delegate asks for it.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A finish reported as a failure may actually be a user/system
    /// cancellation. The durable run record is the authority: its terminal
    /// state is written by the run service, so nothing is inferred from a
    /// message string.
    private func resolvedTerminalOutcome(
        _ outcome: TerminalOutcome,
        runID: UUID
    ) async -> TerminalOutcome {
        guard outcome == .failed else { return outcome }
        guard let record = try? await environment.runStore.run(id: runID) else {
            return outcome
        }
        switch record.state.lowercased() {
        case "cancelled", "canceled", "aborted":
            return .cancelled
        default:
            return outcome
        }
    }

    /// Terminal notification for a conversation run: the policy is read from
    /// the durable task record, the deep link identity is shared with the work
    /// record, and delivery is queued when authorization is missing.
    private func notifyTerminal(
        conversationID: UUID,
        runID: UUID,
        outcome: TerminalOutcome,
        message: String?
    ) {
        Task { [weak self] in
            guard let self else { return }
            let policy = try? await SQLiteWorkspaceStore(database: self.environment.database)
                .taskPolicy(conversationID: conversationID)
            let outcome = await self.resolvedTerminalOutcome(outcome, runID: runID)
            if outcome == .cancelled {
                // Keep the durable work record truthful for a cancellation the
                // caller reported as a failure.
                let existing = await BackgroundWorkRegistry.shared.snapshot(id: runID)
                if let existing, existing.state != .cancelled {
                    var snapshot = existing
                    snapshot.state = .cancelled
                    snapshot.interruption = .none
                    snapshot.progressText = message ?? "已取消 · 检查点已保留"
                    snapshot.activeCommandCount = 0
                    await BackgroundWorkRegistry.shared.register(snapshot)
                }
            }
            let kind: TaskTerminalEventKind = switch outcome {
            case .succeeded: .completed
            case .failed: .failed
            case .cancelled: .cancelled
            }
            let title: String = switch outcome {
            case .succeeded: "本轮已结束"
            case .failed: "本轮运行失败"
            case .cancelled: "本轮已取消"
            }
            let fallbackBody: String = switch outcome {
            case .succeeded: "打开任务查看本轮结果与待办进度。"
            case .failed: "打开任务查看并恢复。"
            case .cancelled: "任务已停止，检查点已保留，可重新开始或继续。"
            }
            self.enqueueTerminalNotification(
                kind: kind,
                title: title,
                body: message ?? fallbackBody,
                identifier: "run.\(runID.uuidString).terminal",
                deepLink: BackgroundWorkDeepLink(
                    kind: .modelRun,
                    conversationID: conversationID,
                    runID: runID
                ),
                policy: policy?.notificationPolicy
            )
        }
    }

    // MARK: - Linux background sessions

    /// True when the user explicitly allowed this environment to run in the
    /// background. The guest never outlives the process; this preference
    /// governs the system continued-processing request, the optional PiP
    /// status surface and metrics sampling.
    func linuxBackgroundSessionIsEnabled(environmentID: String) -> Bool {
        LinuxBackgroundRunPreferences.isEnabled(
            environmentID: environmentID,
            in: linuxBackgroundPreferences
        )
    }

    /// Every environment the user allowed to run in the background, in a
    /// stable order. Used by diagnostics and test hooks.
    func linuxBackgroundEnabledEnvironmentIDs() -> [String] {
        LinuxBackgroundRunPreferences.enabledEnvironmentIDs(in: linuxBackgroundPreferences)
    }

    /// Explicit user control: allow (or stop allowing) a Linux environment to
    /// keep running while the user leaves the app. This is a *preference*: it
    /// is preserved when the VM stops and when the user closes PiP. The guest
    /// lifecycle stays truthful — iOS may still terminate the process, and a
    /// relaunch always starts from the durable disk.
    func setLinuxBackgroundSessionEnabled(
        _ enabled: Bool,
        environmentID: String,
        title: String
    ) {
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        if enabled {
            linuxBackgroundPreferences[environmentID] = LinuxBackgroundRunPreference(
                environmentID: environmentID,
                isEnabled: true
            )
            persistLinuxBackgroundPreferences()
            let deepLink = BackgroundWorkDeepLink(
                kind: .linuxSession,
                environmentID: environmentID
            )
            let snapshot = BackgroundWorkSnapshot(
                id: workID,
                kind: .linuxSession,
                title: title,
                state: .running,
                progressText: "后台允许运行",
                deepLink: deepLink
            )
            Task { await BackgroundWorkRegistry.shared.register(snapshot) }
            // The user's explicit toggle is the only origin allowed to submit;
            // the registry coalesces concurrent submissions.
            _ = continuedEligibility.registerRun(workID, origin: .explicitUserAction)
            if #available(iOS 26.0, *) {
                if Self.shouldSubmitLinuxSessionContinuedProcessing(
                    origin: .explicitUserAction,
                    launchPreferencesLoaded: environment.settingsCenter.launchPreferencesLoaded,
                    hasAggregateForegroundScene: hasAggregateForegroundScene
                ) {
                    updateContinuedTask(title: title, stage: "Linux 环境后台运行", progress: 10)
                    BackgroundPolicyRegistry.shared.requestContinuedProcessing()
                } else {
                    FloeLogger(category: .app).info(
                        "continuedProcessingSkipped workload=linuxBackgroundSession reason=lifecycleGate"
                    )
                }
            }
            startLinuxMetricsSampling(environmentID: environmentID)
            Task { [weak self] in
                await self?.reconcileLinuxBackgroundHold()
            }
            FloeLogger(category: .app).info(
                "linuxBackgroundSessionEnabled environment=\(environmentID)"
            )
        } else {
            linuxBackgroundPreferences[environmentID] = LinuxBackgroundRunPreference(
                environmentID: environmentID,
                isEnabled: false
            )
            persistLinuxBackgroundPreferences()
            continuedEligibility.finishRun(workID)
            stopLinuxMetricsSampling(environmentID: environmentID)
            linuxBackgroundHold.preferenceDisabled(environmentID)
            linuxSurfaceEntries.removeValue(forKey: environmentID)
            publishLinuxSurfacePager()
            Task { await BackgroundWorkRegistry.shared.remove(id: workID) }
            if #available(iOS 26.0, *), !continuedEligibility.hasEligibleWork {
                finishContinuedTasks(success: true)
            }
            FloeLogger(category: .app).info(
                "linuxBackgroundSessionDisabled environment=\(environmentID)"
            )
        }
    }

    /// The shared work record for a Linux environment, when one exists.
    func linuxBackgroundSessionWork(environmentID: String) async -> BackgroundWorkSnapshot? {
        await BackgroundWorkRegistry.shared.snapshot(
            id: BackgroundWorkSnapshot.stableID(for: environmentID)
        )
    }

    private func persistLinuxBackgroundPreferences() {
        LinuxBackgroundRunPreferences.save(linuxBackgroundPreferences)
    }

    // MARK: - Linux background hold (PiP lifecycle)

    /// Running VMs the user allowed to run in the background, in a stable
    /// order. This is the eligibility input of the hold policy.
    func backgroundEligibleEnvironmentIDs() async -> [String] {
        let controller = FloePlatformServices.shared.linuxGuestController()
        var eligible: [String] = []
        for environmentID in linuxBackgroundEnabledEnvironmentIDs() {
            guard let controller else { continue }
            if await controller.guestIsRunning(environmentID: environmentID) {
                eligible.append(environmentID)
            }
        }
        return eligible
    }

    /// Reconciles the PiP hold with the live VM set. Called on a background
    /// transition, on a preference change, and whenever a VM starts or stops.
    func reconcileLinuxBackgroundHold() async {
        let eligible = await backgroundEligibleEnvironmentIDs()
        await refreshLinuxSurfaceEntries(environmentIDs: eligible)
        guard isAppInBackground else {
            // Foreground: keep the hold membership current but never prepare
            // the floating surface; the next background transition does.
            linuxBackgroundHold.updateForegroundEligibleEnvironmentIDs(eligible)
            publishLinuxSurfacePager()
            return
        }
        let decision = linuxBackgroundHold.updateEligibleEnvironmentIDs(eligible)
        switch decision {
        case .none:
            break
        case .prepareSurface(let environmentID):
            linuxBackgroundHold.surfaceChanged(to: environmentID)
            prepareLinuxSurfaceIfPossible(environmentID: environmentID)
        case .endHoldAndStop(let environmentID):
            await stopAndFlushLinuxEnvironment(environmentID: environmentID, reason: "用户关闭了画中画")
        case .retractSurface:
            environment.backgroundVideoService.update(
                title: "Floe 已回到前台",
                progress: "Linux 环境继续运行；返回后台时状态画中画会重新出现。"
            )
        }
        for environmentID in linuxBackgroundHold.heldEnvironmentIDs {
            await publishLinuxSurfaceWork(environmentID: environmentID)
        }
    }

    /// Prepares the supported PiP surface for one held VM and arms AVKit's
    /// automatic inline transition. The release gate still applies.
    private func prepareLinuxSurfaceIfPossible(environmentID: String) {
        // The opt-in release gate owns whether any status PiP controller may
        // exist; a disabled gate degrades to the compliant system path.
        guard StatusPiPReleaseGate.isEnabled else {
            FloeLogger(category: .app).info(
                "linuxBackgroundSurfaceSkipped reason=statusPiPDisabled environment=\(environmentID)"
            )
            return
        }
        linuxSurfacePager.reconcile(with: linuxBackgroundHold.heldEnvironmentIDs.compactMap {
            linuxSurfaceEntries[$0]
        })
        linuxSurfacePager.select(environmentID: environmentID)
        let text = linuxSurfacePager.surfaceText()
        let title = linuxSurfacePager.current?.title ?? "Linux 环境"
        environment.backgroundVideoService.setRunContext(
            title: title,
            progress: text,
            automaticallyStartsFromInline: true
        )
        startPiPCarousel()
        FloeLogger(category: .app).info(
            "linuxBackgroundSurfacePrepared environment=\(environmentID) held=\(self.linuxBackgroundHold.heldEnvironmentIDs.count)"
        )
    }

    /// Ends the hold for one VM: stop the guest safely (the engine flushes its
    /// disk on stop), drop its applied forwards and publish an honest terminal
    /// state. The per-environment preference is deliberately untouched.
    func stopAndFlushLinuxEnvironment(environmentID: String, reason: String) async {
        linuxBackgroundHold.environmentStopped(environmentID)
        await linuxPortCenter.clearEngineForwards(environmentID: environmentID)
        linuxPortCenter.guestStopped(environmentID: environmentID)
        linuxPortCounts.removeValue(forKey: environmentID)
        stopLinuxMetricsSampling(environmentID: environmentID)
        let title = linuxSurfaceEntries[environmentID]?.title ?? "Linux 环境"
        linuxSurfaceEntries.removeValue(forKey: environmentID)
        publishLinuxSurfacePager()
        await FloePlatformServices.shared.stopLinuxGuest(id: environmentID)
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        let snapshot = BackgroundWorkSnapshot(
            id: workID,
            kind: .linuxSession,
            title: title,
            state: .cancelled,
            interruption: .none,
            progressText: "\(reason)；环境已安全停止并刷新磁盘，后台运行偏好保留",
            deepLink: BackgroundWorkDeepLink(kind: .linuxSession, environmentID: environmentID)
        )
        await BackgroundWorkRegistry.shared.register(snapshot)
        if #available(iOS 26.0, *), !continuedEligibility.hasEligibleWork {
            finishContinuedTasks(success: true)
        }
        enqueueTerminalNotification(
            kind: .cancelled,
            title: "Linux 环境已停止",
            body: "\(reason)。磁盘已保留，可再次启动。",
            identifier: "linux.session.\(environmentID).terminal",
            deepLink: BackgroundWorkDeepLink(kind: .linuxSession, environmentID: environmentID)
        )
        FloeLogger(category: .app).info(
            "linuxBackgroundHoldEnded environment=\(environmentID) reason=\(reason)"
        )
    }

    /// The user stopped the VM from the environment screen. The hold and the
    /// applied forwards are cleared and an honest suspended record is kept,
    /// but the durable per-environment preference is preserved so a later
    /// start restores background running.
    func linuxEnvironmentDidStop(environmentID: String, title: String) async {
        linuxBackgroundHold.environmentStopped(environmentID)
        await linuxPortCenter.clearEngineForwards(environmentID: environmentID)
        linuxPortCenter.guestStopped(environmentID: environmentID)
        linuxPortCounts.removeValue(forKey: environmentID)
        linuxCommandCounts.removeValue(forKey: environmentID)
        linuxSurfaceEntries.removeValue(forKey: environmentID)
        stopLinuxMetricsSampling(environmentID: environmentID)
        publishLinuxSurfacePager()
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        continuedEligibility.finishRun(workID)
        if #available(iOS 26.0, *), !continuedEligibility.hasEligibleWork {
            finishContinuedTasks(success: true)
        }
        guard linuxBackgroundSessionIsEnabled(environmentID: environmentID) else {
            await BackgroundWorkRegistry.shared.remove(id: workID)
            return
        }
        let snapshot = BackgroundWorkSnapshot(
            id: workID,
            kind: .linuxSession,
            title: title,
            state: .suspended,
            interruption: .checkpointed,
            progressText: "环境已停止；后台运行偏好保留，重新启动后继续生效",
            deepLink: BackgroundWorkDeepLink(kind: .linuxSession, environmentID: environmentID)
        )
        await BackgroundWorkRegistry.shared.register(snapshot)
        FloeLogger(category: .app).info(
            "linuxEnvironmentStopped environment=\(environmentID) preferenceKept=true"
        )
    }

    /// One bounded surface sample per environment: metrics from the sampler,
    /// services from the supervisor, ports from the applied forward plans and
    /// commands from the bounded /proc probe.
    func refreshLinuxSurfaceEntries(environmentIDs: [String]) async {
        let serviceController = FloePlatformServices.shared.linuxLocalServiceController()
        let runner = FloePlatformServices.shared.linuxCommandRunner()
        for environmentID in environmentIDs {
            // A VM that started while the app was already running must still
            // restore its persisted forwards; a hold reconcile is the moment
            // the app re-reads the live VM set.
            if linuxPortCenter.plans(environmentID: environmentID).isEmpty,
               linuxPortCenter.enabledRuleCount(environmentID: environmentID) > 0 {
                await linuxPortCenter.applyRules(environmentID: environmentID)
            }
            let existing = linuxSurfaceEntries[environmentID]
            let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
            let work = await BackgroundWorkRegistry.shared.snapshot(id: workID)
            var entry = LinuxBackgroundSurfaceEntry(
                environmentID: environmentID,
                title: work?.title ?? existing?.title ?? "Linux 环境",
                state: work?.state ?? .running,
                emulatorCPUFraction: work?.metrics?.emulatorCPUFraction ?? existing?.emulatorCPUFraction,
                guestCPUFraction: work?.metrics?.guestCPUFraction ?? existing?.guestCPUFraction,
                memoryUsedMB: work?.metrics?.guestMemoryUsedMB ?? existing?.memoryUsedMB,
                memoryTotalMB: work?.metrics?.guestMemoryTotalMB ?? existing?.memoryTotalMB,
                activeCommandCount: linuxCommandCounts[environmentID] ?? existing?.activeCommandCount,
                activeServiceCount: existing?.activeServiceCount ?? 0,
                portForwardCount: linuxPortCounts[environmentID] ?? existing?.portForwardCount,
                startedAt: work?.startedAt ?? existing?.startedAt,
                updatedAt: Date()
            )
            if let serviceController {
                entry.activeServiceCount = await serviceController.activeLocalServiceCount(
                    environmentID: environmentID
                )
            }
            if let runner {
                if let owned = await LinuxGuestSurfaceProbe.runnerOwnedProcessCount(
                    runner: runner,
                    environmentID: environmentID
                ) {
                    let services = entry.activeServiceCount ?? 0
                    let commands = max(0, owned - services)
                    linuxCommandCounts[environmentID] = commands
                    entry.activeCommandCount = commands
                } else {
                    linuxCommandCounts.removeValue(forKey: environmentID)
                    entry.activeCommandCount = nil
                }
            } else {
                entry.activeCommandCount = nil
            }
            entry.portForwardCount = linuxPortCenter.enabledRuleCount(environmentID: environmentID)
            linuxPortCounts[environmentID] = entry.portForwardCount
            linuxSurfaceEntries[environmentID] = entry
        }
        publishLinuxSurfacePager()
    }

    /// Keeps the pager's entry set in step with the held VMs and updates an
    /// already-visible surface without reopening it.
    private func publishLinuxSurfacePager() {
        linuxSurfacePager.reconcile(
            with: linuxBackgroundHold.heldEnvironmentIDs.compactMap { linuxSurfaceEntries[$0] }
        )
    }

    /// Publishes the surface state into the shared work registry so the PiP,
    /// the settings screen and notifications read one model.
    private func publishLinuxSurfaceWork(environmentID: String) async {
        guard let entry = linuxSurfaceEntries[environmentID] else { return }
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        var snapshot = await BackgroundWorkRegistry.shared.snapshot(id: workID)
            ?? BackgroundWorkSnapshot(
                id: workID,
                kind: .linuxSession,
                title: entry.title,
                state: entry.state,
                progressText: "后台保持运行",
                startedAt: entry.startedAt ?? Date(),
                deepLink: BackgroundWorkDeepLink(kind: .linuxSession, environmentID: environmentID)
            )
        snapshot.metrics = BackgroundWorkMetrics(
            emulatorCPUFraction: entry.emulatorCPUFraction,
            guestCPUFraction: entry.guestCPUFraction,
            guestMemoryUsedMB: entry.memoryUsedMB,
            guestMemoryTotalMB: entry.memoryTotalMB,
            gpu: .unavailableNativeOnly
        )
        snapshot.activeCommandCount = entry.activeCommandCount ?? 0
        snapshot.activeServiceCount = entry.activeServiceCount ?? 0
        snapshot.portForwardCount = entry.portForwardCount ?? 0
        snapshot.progressText = entry.caption()
        await BackgroundWorkRegistry.shared.register(snapshot)
    }

    /// Snapshot for diagnostics/tests: the current page and every entry.
    func linuxBackgroundSurfaceSnapshot() -> (entries: [LinuxBackgroundSurfaceEntry], pager: LinuxBackgroundSurfacePager) {
        (linuxSurfacePager.entries, linuxSurfacePager)
    }

    /// The PiP page for a held environment, used by the carousel.
    private func linuxSurfacePage(environmentID: String) -> String? {
        linuxSurfacePager.select(environmentID: environmentID)
        return linuxSurfacePager.current == nil ? nil : linuxSurfacePager.surfaceText()
    }


    /// Metrics sampling is bounded: one short bounded guest read per interval,
    /// only while a consumer is registered, and only while a scene is in the
    /// foreground. The last sample stays visible (with `updatedAt`) after
    /// sampling stops.
    private func startLinuxMetricsSampling(environmentID: String) {
        guard linuxMetricsTasks[environmentID] == nil else { return }
        guard let service = environment.linuxGuestService else { return }
        let sampler = linuxMetricsSamplers[environmentID] ?? LinuxGuestMetricsSampler(
            environmentID: environmentID,
            commandRunner: service,
            emulatorSampleProvider: { id in
                await service.emulatorThreadCPUSample(environmentID: id)
            }
        )
        linuxMetricsSamplers[environmentID] = sampler
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        linuxMetricsTasks[environmentID] = Task { [weak self] in
            for await metrics in await sampler.metrics() {
                guard !Task.isCancelled else { return }
                await self?.applyLinuxMetrics(metrics, workID: workID)
            }
        }
    }

    private func stopLinuxMetricsSampling(environmentID: String) {
        linuxMetricsTasks[environmentID]?.cancel()
        linuxMetricsTasks[environmentID] = nil
    }

    private func pauseLinuxMetricsSampling() {
        for environmentID in Array(linuxMetricsTasks.keys) {
            stopLinuxMetricsSampling(environmentID: environmentID)
        }
    }

    private func resumeLinuxMetricsSampling() {
        guard hasAggregateForegroundScene else { return }
        for environmentID in linuxBackgroundEnabledEnvironmentIDs() {
            startLinuxMetricsSampling(environmentID: environmentID)
        }
    }

    private func applyLinuxMetrics(_ metrics: BackgroundWorkMetrics, workID: UUID) async {
        let existing = await BackgroundWorkRegistry.shared.snapshot(id: workID)
        guard var snapshot = existing else { return }
        snapshot.metrics = metrics
        await BackgroundWorkRegistry.shared.register(snapshot)
        guard let environmentID = existing?.deepLink.environmentID else { return }
        var entry = linuxSurfaceEntries[environmentID] ?? LinuxBackgroundSurfaceEntry(
            environmentID: environmentID,
            title: existing?.title ?? "Linux 环境",
            startedAt: existing?.startedAt
        )
        entry.emulatorCPUFraction = metrics.emulatorCPUFraction ?? entry.emulatorCPUFraction
        entry.guestCPUFraction = metrics.guestCPUFraction ?? entry.guestCPUFraction
        entry.memoryUsedMB = metrics.guestMemoryUsedMB ?? entry.memoryUsedMB
        entry.memoryTotalMB = metrics.guestMemoryTotalMB ?? entry.memoryTotalMB
        entry.updatedAt = Date()
        linuxSurfaceEntries[environmentID] = entry
        publishLinuxSurfacePager()
        if linuxBackgroundHold.surfacedEnvironmentID == environmentID, isAppInBackground {
            // Refresh the visible page, but never create a surface from a
            // metric tick.
            environment.backgroundVideoService.update(progress: linuxSurfacePager.surfaceText())
        }
    }

    /// A manual/system PiP close is respected for the current active batch.
    /// A later newly-started task will call `didStart` and request PiP again.
    /// For a Linux background hold the close ends that hold: the VM the
    /// surface showed is stopped and flushed safely, while the durable
    /// per-environment "allow background running" preference is preserved.
    func didClosePictureInPicture() {
        let holdDecision = linuxBackgroundHold.userClosedPictureInPicture()
        if case .endHoldAndStop(let environmentID) = holdDecision {
            linuxSurfaceEntries.removeValue(forKey: environmentID)
            linuxCommandCounts.removeValue(forKey: environmentID)
            linuxPortCounts.removeValue(forKey: environmentID)
            publishLinuxSurfacePager()
            Task { [weak self] in
                await self?.stopAndFlushLinuxEnvironment(
                    environmentID: environmentID,
                    reason: "用户关闭了画中画"
                )
            }
        }
        surfacedRunID = nil
        // A scene cycle is not fresh user intent. Keep this decision for the
        // current task batch even if the user reopens Floe and leaves again.
        // A genuinely new run clears it in didStart. Screen sharing may keep
        // running; only its optional progress PiP is suppressed.
        visualSurfacePolicy.userClosedPictureInPicture()
        persistVisualSurfacePolicy()
        FloeLogger(category: .app).info(
            "pictureInPictureClosedByUser activeRuns=\(activeRuns.count) linuxHold=\(self.linuxBackgroundHold.heldEnvironmentIDs.count)"
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
        let preference = effectiveBackgroundExecutionPreference
        guard visualSurfacePolicy.allowsVisualSurface(
            for: preference
        ) else {
            if preference == .standard, !linuxBackgroundHold.hasActiveHold {
                // Mode changes can happen while a failed run's visual surface
                // is retained. Standard mode owns only its continued task and
                // must not inherit an earlier PiP controller or broadcast —
                // but a held Linux VM keeps its own prepared surface.
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
                  for: effectiveBackgroundExecutionPreference
              ) else { return }
        let candidate = activeRuns.first.map { (id: $0.key, run: $0.value) }
            ?? retainedPausedRun
        guard let (runID, run) = candidate else {
            // No provider run owns the surface: a held Linux VM still may.
            if linuxBackgroundHold.hasActiveHold,
               let environmentID = linuxBackgroundHold.surfacedEnvironmentID {
                prepareLinuxSurfaceIfPossible(environmentID: environmentID)
            }
            return
        }
        surfacedRunID = runID
        environment.backgroundVideoService.update(
            title: run.title,
            progress: run.presentation()
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

    private struct SurfaceCarouselItem {
        var id: UUID
        var title: String
        var text: String
    }

    /// One page per active provider run, then one page per held Linux VM.
    /// Linux pages carry the environment's VM identity, CPU, memory and
    /// command/service/port counts, so several background VMs stay readable
    /// without cramming them into one video frame.
    private func surfaceCarouselItems() -> [SurfaceCarouselItem] {
        let runs = activeRuns.sorted { $0.key.uuidString < $1.key.uuidString }
        if runs.isEmpty,
           linuxBackgroundHold.heldEnvironmentIDs.isEmpty,
           let retained = retainedPausedRun {
            return [SurfaceCarouselItem(
                id: retained.id,
                title: retained.run.title,
                text: retained.run.presentation()
            )]
        }
        var items = runs.map {
            SurfaceCarouselItem(
                id: $0.key,
                title: $0.value.title,
                text: $0.value.presentation()
            )
        }
        for environmentID in linuxBackgroundHold.heldEnvironmentIDs {
            guard let entry = linuxSurfaceEntries[environmentID] else { continue }
            items.append(SurfaceCarouselItem(
                id: BackgroundWorkSnapshot.stableID(for: environmentID),
                title: entry.title,
                text: linuxSurfacePage(environmentID: environmentID) ?? entry.caption()
            ))
        }
        return items
    }

    /// Keep a multi-task/multi-VM PiP useful without cramming several
    /// unreadable rows into a phone-sized video. Cycle the real active pages
    /// and show the current index. A single page remains stable.
    private func startPiPCarousel() {
        guard pipCarouselTask == nil else { return }
        pipCarouselTask = Task { [weak self] in
            var cursor = 0
            while !Task.isCancelled {
                guard let self, self.isAppInBackground else { return }
                let candidates = self.surfaceCarouselItems()
                guard !candidates.isEmpty else { return }
                let item = candidates[cursor % candidates.count]
                self.surfacedRunID = item.id
                let prefix = candidates.count > 1
                    ? "\((cursor % candidates.count) + 1)/\(candidates.count) · " : ""
                self.environment.backgroundVideoService.update(
                    title: item.title,
                    progress: "\(prefix)\(item.text)"
                )
                cursor += 1
                try? await Task.sleep(for: .seconds(candidates.count > 1 ? 4 : 1))
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
            let policy = try? await SQLiteWorkspaceStore(database: self.environment.database)
                .taskPolicy(conversationID: conversationID)
            self.enqueueTerminalNotification(
                kind: .actionRequired,
                title: "任务等待审批",
                body: "需要确认：\(toolName)",
                identifier: "approval.\(runID.uuidString).terminal",
                deepLink: BackgroundWorkDeepLink(
                    kind: .modelRun,
                    conversationID: conversationID,
                    runID: runID
                ),
                policy: policy?.notificationPolicy
            )
        }
    }

    @available(iOS 26.0, *)
    private func acceptContinuedTask(_ task: BGContinuedProcessingTask) {
        let handleID = ObjectIdentifier(task)
        var handles = continuedTasksByIdentifier[task.identifier] ?? [:]
        guard handles[handleID] == nil else { return }
        handles[handleID] = task
        continuedTasksByIdentifier[task.identifier] = handles

        let launchPreferencesLoaded = environment.settingsCenter.launchPreferencesLoaded
        let keepsConversationTask = Self.shouldKeepContinuedProcessing(
            for: effectiveBackgroundExecutionPreference,
            launchPreferencesLoaded: launchPreferencesLoaded
        )
        let keepsLinuxSessionTask = launchPreferencesLoaded && !linuxBackgroundEnabledEnvironmentIDs().isEmpty
        guard keepsConversationTask || keepsLinuxSessionTask,
              continuedEligibility.hasEligibleWork else {
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
            if Date().timeIntervalSince(lastSkippedContinuedUpdateAt) >= 60 {
                lastSkippedContinuedUpdateAt = Date()
                FloeLogger(category: .app).debug(
                    "continuedProcessingUpdateSkipped reason=visualBackgroundPreference preference=\(environment.settingsCenter.backgroundExecution.rawValue)"
                )
            }
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
            // A backgrounded app must not spend cycles reading guest /proc
            // files: sampling is a foreground-only, consumer-bounded loop.
            pauseLinuxMetricsSampling()
            resumeBackgroundSurfaceIfNeeded()
            lease = BackgroundPolicyRegistry.shared.beginShortCompletion(name: "Keep agent run active")
            Task { [weak self] in
                guard let self else { return }
                // An active VM whose per-environment preference allows
                // background running gets the supported PiP surface prepared
                // (or re-prepared) for this background transition.
                await self.reconcileLinuxBackgroundHold()
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
            resumeLinuxMetricsSampling()
            pipCarouselTask?.cancel()
            pipCarouselTask = nil
            environment.backgroundVideoService.retractForForeground()
            _ = linuxBackgroundHold.enteredForeground()
            if visualSurfacePolicy.allowsVisualSurface(
                for: effectiveBackgroundExecutionPreference
            ) {
                prepareBackgroundSurfaceIfNeeded()
            }
            lease?.release()
            lease = nil
            Task { [weak self] in
                guard let self else { return }
                // The authorization answer may have arrived while the app was
                // away: flush anything the first-authorization race queued.
                await self.refreshNotificationAuthorizationAndFlush()
                await self.reconcileLinuxBackgroundHold()
                await self.environment.conversationCenter.resumeSafeRunsAfterForeground()
                await self.reconcilePendingMediaJobs()
                await self.runDueSchedules()
                // ④ catch-up dream on foreground resume (gated internally).
                await self.environment.memoryDreamService.deepDream()
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
                  for: effectiveBackgroundExecutionPreference
              ),
              !environment.backgroundVideoService.isPreparingPiP else { return }
        let candidate = activeRuns.first.map { (id: $0.key, run: $0.value) }
            ?? retainedPausedRun
        guard let (runID, run) = candidate else { return }
        surfacedRunID = runID
        environment.backgroundVideoService.setRunContext(
            title: run.title,
            progress: run.presentation(),
            automaticallyStartsFromInline:
                effectiveBackgroundExecutionPreference == .pictureInPicture
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
        await reconcileLinuxBackgroundSessionsAfterLaunch()
    }

    /// A TinyEMU guest cannot outlive the process, so a persisted "running in
    /// the background" record is stale by definition after a relaunch. Report
    /// the truth (interrupted by the system; durable disk preserved), keep the
    /// user's setting, and never claim the guest survived.
    func reconcileLinuxBackgroundSessionsAfterLaunch() async {
        let enabled = linuxBackgroundEnabledEnvironmentIDs()
        guard !enabled.isEmpty else { return }
        for environmentID in enabled {
            let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
            let existing = await BackgroundWorkRegistry.shared.snapshot(id: workID)
            let title = existing?.title ?? "Linux 环境"
            let snapshot = BackgroundWorkSnapshot(
                id: workID,
                kind: .linuxSession,
                title: title,
                state: .interrupted,
                interruption: .terminatedBySystem,
                progressText: "应用已退出，Linux 环境已停止；打开后可重新启动并继续",
                deepLink: BackgroundWorkDeepLink(
                    kind: .linuxSession,
                    environmentID: environmentID
                )
            )
            await BackgroundWorkRegistry.shared.register(snapshot)
        }
        FloeLogger(category: .app).info(
            "linuxBackgroundSessionsReconciled count=\(enabled.count) reason=processRelaunch"
        )
    }

    /// The app owns exactly one background URLSession for generated media.
    /// Reusing it avoids two delegates competing for the same persistent
    /// session identifier during launch restoration.
    func startMediaArtifactDownload(jobID: UUID, remoteURL: URL, headers: [String: String] = [:]) async {
        await mediaDownloads.start(jobID: jobID, remoteURL: remoteURL, headers: headers)
    }

    /// One reconciliation path shared by launch, foreground, refresh and
    /// processing wakeups. Provider task IDs are already durable before this
    /// method runs, so cancellation can only delay progress, not lose work.
    /// Restoring this on relaunch is what makes chat-submitted video jobs
    /// survive a process death.
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
        // A crash between the provider call and the task-ID write leaves a
        // `preparing` row with no task ID. Automatic retry is unsafe (the
        // provider may have accepted the request and would charge twice), so
        // the job is closed truthfully and the user is told to verify.
        if let stale = try? await store.stalePreparingJobs(before: now.addingTimeInterval(-10 * 60)) {
            for job in stale where !Task.isCancelled {
                _ = try? await store.transition(id: job.id, to: .failed) {
                    $0.nextPollAt = nil
                    $0.lastError = "提交在保存供应商任务 ID 之前中断；供应商是否已受理未知。不会自动重复提交，请核对供应商控制台后再决定是否重试。"
                }
            }
        }
        guard let jobs = try? await store.dueOwnedJobs(at: now) else { return }
        for job in jobs where !Task.isCancelled {
            // One polling owner: the media service implements the state
            // machine and the provider/credential handling.
            try? await environment.mediaGenerationService.pollMediaJob(job, store: store, now: now)
        }
        if let next = (try? await store.dueJobs(at: .distantFuture, limit: 100))?
            .compactMap(\.nextPollAt).min() {
            BackgroundPolicyRegistry.shared.scheduleMediaRefresh(
                earliest: max(next, Date().addingTimeInterval(60))
            )
        }
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
        let payload = response.notification.request.content.userInfo
        // The deep-link payload is the routing contract. Parsing is shared
        // with the in-app banner, and legacy notifications that carried only
        // a conversation id still route to their conversation.
        guard let link = BackgroundWorkDeepLink.parse(payload) else { return }
        // The parsed identity is `Sendable`; only its string payload crosses to
        // the main actor, never the raw `Any`-valued notification dictionary.
        // Routing reads exactly these keys, so the rebuilt payload is the same
        // contract the notification carried.
        let forwarded = link.userInfo
        let identifier = response.notification.request.identifier
        await MainActor.run { [weak self] in
            Self.route(deepLink: link, userInfo: forwarded)
            // The user acted on this event: it no longer needs to stay queued
            // (a flushing duplicate would otherwise alert twice).
            self?.notificationOutbox.discard(identifier: identifier)
            self?.persistNotificationOutbox()
        }
    }

    /// Routes a deep link to exactly one destination. The payload identity
    /// (kind + ids) decides where it goes; nothing is inferred from titles.
    nonisolated static func route(deepLink: BackgroundWorkDeepLink, userInfo: [AnyHashable: Any] = [:]) {
        switch deepLink.kind {
        case .modelRun:
            guard let conversationID = deepLink.conversationID else { return }
            NotificationCenter.default.post(
                name: .floeOpenConversation,
                object: nil,
                userInfo: ["conversationID": conversationID]
            )
        case .linuxSession, .linuxService:
            var payload = userInfo
            payload["workKind"] = deepLink.kind.rawValue
            if let environmentID = deepLink.environmentID { payload["environmentID"] = environmentID }
            if let serviceJobID = deepLink.serviceJobID { payload["serviceJobID"] = serviceJobID.uuidString }
            NotificationCenter.default.post(
                name: .floeOpenExecutionEnvironment,
                object: nil,
                userInfo: payload
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
    var modelID: UUID? = nil
    var providerID: UUID? = nil
    var selection: ImageGenerationSelection? = nil
    var fallbackUsed = false
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

/// Result of an owner-aware media submission. `deduplicated` is true when an
/// identical active job already existed and no provider call was made.
struct MediaGenerationSubmission: Sendable {
    var job: MediaGenerationJob
    var deduplicated: Bool
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
        owner: GeneratedImageReservationOwner,
        agentInitiated: Bool = false
    ) async throws -> ReservedGeneratedImageBatch {
        let center = environment.conversationCenter
        let operation: RemoteImageOperation = sourceImages.isEmpty ? .generate : .edit
        let selected = modelID.flatMap { center.mediaProviderAndModel(modelID: $0) }
            ?? center.auxiliaryProviderAndModel(for: operation == .generate ? .generate : .edit)
        guard var (provider, model) = selected,
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
        var selection = ImageGenerationSelection(
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
            if agentInitiated {
                let routed = try await center.performAgentImage(operation: operation, prompt: prompt,
                    sourceImages: sourceImages, modelID: model.id, selection: selection, count: requestedOutputCount)
                result = routed.0; provider = routed.1; model = routed.2
                selection = ImageGenerationPresetResolver.applyingDefaults(selection, provider: provider, model: model, operation: operation)
            } else {
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
            }
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
            assets: assets, modelID: model.id, providerID: provider.id, selection: selection,
            fallbackUsed: result.metadata["fallbackUsed"] == "true"
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
        let submission = try await submitVideo(
            modelID: modelID,
            owner: .canvas(canvasID),
            originRunID: nil,
            sourceNodeIDs: sourceNodeIDs,
            resultNodeID: resultNodeID,
            request: request,
            canvasDocumentID: documentID
        )
        return submission.job
    }

    /// Owner-aware submission used by ordinary chat and the legacy canvas
    /// path. An identical active operation is returned instead of paying for a
    /// second submission (`idempotencyKey` identifies the submitting tool
    /// call; canvas keeps the legacy exact-request comparison); the provider
    /// call happens only after the local row is durable. The dedupe lookup and
    /// the insert share one transaction, so concurrent identical submissions
    /// cannot both reach the provider.
    func submitVideo(
        modelID: UUID,
        owner: MediaJobOwner,
        originRunID: UUID?,
        sourceNodeIDs: [UUID] = [],
        resultNodeID: UUID = UUID(),
        request: RemoteVideoRequest,
        canvasDocumentID: UUID? = nil,
        idempotencyKey: String? = nil
    ) async throws -> MediaGenerationSubmission {
        guard let model = try await environment.configurationStore.model(id: modelID),
              let provider = try await environment.configurationStore.provider(id: model.providerID),
              model.isEnabled, provider.isEnabled,
              let adapter = VideoProviderAdapterFactory().adapter(for: provider) else {
            throw RemoteVideoError.unsupportedProvider
        }
        let store = MediaGenerationJobStore(database: environment.database)
        // Canonical key order keeps the legacy request comparison stable across
        // process launches and encoder invocations.
        let requestEncoder = JSONEncoder()
        requestEncoder.outputFormatting = [.sortedKeys]
        let requestJSON = try requestEncoder.encode(request)
        // Conversation jobs must not invent a canvas/document identity; the
        // canvas path keeps its real one.
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .video,
            credentialReference: provider.secretRef,
            canvasID: owner.kind == .canvas ? owner.id : nil,
            documentID: owner.kind == .canvas ? (canvasDocumentID ?? owner.id) : nil,
            sourceNodeIDs: sourceNodeIDs,
            resultNodeID: resultNodeID, requestJSON: requestJSON
        )
        let creation = try await store.createJob(
            job, owner: owner, originRunID: originRunID,
            idempotencyKey: idempotencyKey
        )
        if creation.deduplicated {
            return MediaGenerationSubmission(job: creation.job, deduplicated: true)
        }
        let key = videoCredential(for: job)
        FloeLogger(category: .providers).info(
            "videoSubmitAuthenticated providerID=\(provider.id.uuidString) model=\(model.remoteModelID) keyPresent=\(key != nil)"
        )
        do {
            let submission = try await adapter.submit(
                request, provider: provider, credentials: ProviderCredentials(apiKey: key)
            )
            let targetState: MediaGenerationJobState =
                submission.resultURL != nil ? .downloading : .submitted
            let updated: MediaGenerationJob
            do {
                updated = try await store.transition(id: job.id, to: targetState) { current in
                    current.providerTaskID = submission.providerTaskID
                    current.estimatedCompletionAt = submission.estimatedCompletionAt
                    current.resultRetentionExpiresAt = submission.resultRetentionExpiresAt
                    current.resultURL = submission.resultURL
                    current.resultURLExpiresAt = submission.resultURLExpiresAt
                    current.nextPollAt = submission.resultURL == nil
                        ? Date().addingTimeInterval(30) : nil
                }
            } catch let storeError as MediaGenerationJobStoreError {
                // The user cancelled while the provider request was in
                // flight. The local record already owns the truth; ask the
                // provider to cancel the task it accepted and report that
                // instead of resurrecting the cancelled job. Any other store
                // error is rethrown unchanged.
                guard case .invalidStateTransition = storeError else { throw storeError }
                try? await adapter.cancel(
                    taskID: submission.providerTaskID, provider: provider,
                    credentials: ProviderCredentials(apiKey: key)
                )
                throw RemoteVideoError.requestFailed(
                    "任务在供应商确认前已被取消，已尝试取消供应商任务。"
                )
            }
            if let resultURL = updated.resultURL {
                await startMediaDownload(jobID: updated.id, remoteURL: resultURL, provider: provider, credential: key)
            }
            BackgroundPolicyRegistry.shared.scheduleMediaRefresh(
                earliest: updated.nextPollAt ?? Date().addingTimeInterval(60)
            )
            BackgroundPolicyRegistry.shared.scheduleMediaProcessing(
                earliest: Date().addingTimeInterval(60)
            )
            return MediaGenerationSubmission(job: updated, deduplicated: false)
        } catch {
            _ = try? await store.transition(id: job.id, to: .failed) {
                $0.lastError = error.localizedDescription
            }
            throw error
        }
    }

    /// Reads the job's provider credential at the call site only. Resolves
    /// through `KeychainSecretStore.readSecret(reference:)` — the same
    /// secrets namespace and synchronizable fallback as the chat, image
    /// generation and speed-test paths. The legacy `environment.keychain`
    /// namespace is deliberately not consulted: no provider write path stores
    /// secrets there, so reading it silently dropped the Authorization header
    /// and the provider rejected the request with HTTP 401. Only provider/
    /// model identifiers and key existence are logged, never secret bytes.
    private func videoCredential(for job: MediaGenerationJob) -> String? {
        guard let reference = job.credentialReference else {
            FloeLogger(category: .providers).warning(
                "videoCredentialMissing providerID=\(job.providerID.uuidString) modelID=\(job.modelID.uuidString) reason=noSecretReference"
            )
            return nil
        }
        let key = KeychainSecretStore()
            .readSecret(reference: reference)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap { value in
                value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
            }
        if key == nil {
            FloeLogger(category: .providers).warning(
                "videoCredentialMissing providerID=\(job.providerID.uuidString) modelID=\(job.modelID.uuidString) account=\(reference.keychainAccount) synchronizable=\(reference.synchronizable)"
            )
        }
        return key
    }

    /// Starts the single background URLSession download for a result URL.
    /// Google file URLs require the API key header; Ark and DashScope return
    /// pre-signed URLs and need no extra header. The Google key is attached
    /// only when the result host is a Google media surface, so a malformed or
    /// hostile result URL can never receive the credential.
    private func startMediaDownload(
        jobID: UUID,
        remoteURL: URL,
        provider: ProviderProfile,
        credential: String?
    ) async {
        var headers: [String: String] = [:]
        if provider.kind == .googleGemini,
           let credential, !credential.isEmpty,
           let host = remoteURL.host,
           VideoDownloadRedirectPolicy.isAllowedMediaRedirectHost(host) {
            headers["x-goog-api-key"] = credential
        }
        await environment.backgroundRunCoordinator.startMediaArtifactDownload(
            jobID: jobID, remoteURL: remoteURL, headers: headers
        )
    }

    /// Polls one durable job exactly once and applies the truthful state.
    /// Shared by launch/foreground reconciliation and `video.status`.
    @discardableResult
    func refreshVideoJob(jobID: UUID) async throws -> MediaGenerationJob? {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let owned = try await store.ownedJob(id: jobID) else { return nil }
        try await pollMediaJob(owned, store: store, now: Date())
        return try await store.job(id: jobID)
    }

    /// Next poll instant for a running job, derived from the provider's own
    /// estimate but bounded so a stale estimate cannot delay progress.
    nonisolated static func nextMediaPollDate(job: MediaGenerationJob, now: Date) -> Date {
        if let estimate = job.estimatedCompletionAt, estimate > now {
            return min(estimate, now.addingTimeInterval(5 * 60))
        }
        return now.addingTimeInterval(60)
    }

    /// Polls one owned durable job. Visible to the coordinator's
    /// reconciliation loop so there is exactly one polling state machine.
    func pollMediaJob(
        _ owned: OwnedMediaGenerationJob,
        store: MediaGenerationJobStore,
        now: Date
    ) async throws {
        let job = owned.job
        guard let provider = try? await environment.configurationStore.provider(id: job.providerID),
              let model = try? await environment.configurationStore.model(id: job.modelID),
              let adapter = VideoProviderAdapterFactory().adapter(for: provider) else { return }
        let apiKey = videoCredential(for: job)
        // A relaunch can lose the in-flight background task; restart the
        // download from the persisted result URL instead of waiting. A result
        // URL past its documented expiry can never be downloaded again, so it
        // is closed truthfully instead of retrying a dead link.
        if job.state == .downloading, let resultURL = job.resultURL {
            if let expiry = job.resultURLExpiresAt, expiry <= now {
                _ = try await store.transition(id: job.id, to: .expired) {
                    $0.lastPolledAt = now
                    $0.lastError = "结果下载地址已在有效期（24 小时）后过期，请重新生成。"
                    $0.nextPollAt = nil
                }
                return
            }
            await startMediaDownload(jobID: job.id, remoteURL: resultURL, provider: provider, credential: apiKey)
            return
        }
        guard let taskID = job.providerTaskID else { return }
        do {
            let status = try await adapter.status(
                taskID: taskID, modelRemoteID: model.remoteModelID,
                provider: provider, credentials: ProviderCredentials(apiKey: apiKey)
            )
            switch status.state {
            case .completed:
                guard let resultURL = status.resultURL else {
                    _ = try await store.transition(id: job.id, to: .failed) {
                        $0.lastPolledAt = now
                        $0.lastError = "供应商报告完成，但没有返回可下载的视频地址。"
                        $0.nextPollAt = nil
                    }
                    return
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
                await startMediaDownload(jobID: job.id, remoteURL: resultURL, provider: provider, credential: apiKey)
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
                $0.nextPollAt = now.addingTimeInterval(MediaRetryBackoff.delay(afterRetryCount: $0.retryCount))
            }
        }
    }


    /// Truthful cancellation. A terminal job is an error, not a silent no-op;
    /// a provider cancel that races with completion reports the real outcome;
    /// a failed provider cancel keeps the job alive with its error visible so
    /// a later poll can still collect the result.
    func cancelVideo(jobID: UUID) async throws {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let owned = try await store.ownedJob(id: jobID) else {
            throw MediaGenerationJobStoreError.missingJob(jobID)
        }
        let job = owned.job
        guard !job.state.isTerminal else {
            throw RemoteVideoError.invalidRequest(
                "该任务已结束（\(job.state.rawValue)），无法取消。使用 video.status 查看最终状态。"
            )
        }
        guard let taskID = job.providerTaskID else {
            // The provider call was never confirmed locally. Never claim a
            // remote cancellation; close the durable job honestly.
            _ = try await store.transition(id: jobID, to: .cancelled) {
                $0.nextPollAt = nil
                $0.lastError = "取消时尚未保存供应商任务 ID；供应商是否已受理未知，请在需要时核对供应商控制台。"
            }
            return
        }
        guard let provider = try await environment.configurationStore.provider(id: job.providerID),
              let adapter = VideoProviderAdapterFactory().adapter(for: provider) else {
            throw RemoteVideoError.unsupportedProvider
        }
        let key = videoCredential(for: job)
        do {
            try await adapter.cancel(
                taskID: taskID,
                provider: provider,
                credentials: ProviderCredentials(apiKey: key)
            )
            _ = try await store.transition(id: jobID, to: .cancelled) {
                $0.nextPollAt = nil
                $0.lastError = nil
            }
        } catch {
            // Ask the provider what actually happened before deciding.
            if let model = try? await environment.configurationStore.model(id: job.modelID),
               let status = try? await adapter.status(
                   taskID: taskID, modelRemoteID: model.remoteModelID,
                   provider: provider, credentials: ProviderCredentials(apiKey: key)
               ) {
                switch status.state {
                case .completed:
                    if let resultURL = status.resultURL {
                        let completed = try await store.transition(id: jobID, to: .downloading) {
                            $0.resultURL = resultURL
                            $0.resultURLExpiresAt = status.resultURLExpiresAt
                            $0.nextPollAt = nil
                        }
                        await startMediaDownload(
                            jobID: completed.id, remoteURL: resultURL,
                            provider: provider, credential: key
                        )
                    }
                    throw RemoteVideoError.requestFailed("任务在取消前已完成，结果正在下载。")
                case .failed, .cancelled, .expired:
                    _ = try await store.transition(id: jobID, to: status.state) {
                        $0.lastError = status.error ?? error.localizedDescription
                        $0.nextPollAt = nil
                    }
                    return
                default:
                    break
                }
            }
            _ = try await store.transition(id: jobID, to: job.state) {
                $0.retryCount += 1
                $0.lastError = "取消失败：\(error.localizedDescription)"
                $0.nextPollAt = Date().addingTimeInterval(MediaRetryBackoff.delay(afterRetryCount: $0.retryCount))
            }
            throw error
        }
    }

    /// A retry is always a new provider job so the original terminal record
    /// remains auditable. The retry is a distinct operation, so it does not
    /// reuse the original idempotency key; an active duplicate request still
    /// attaches to the existing job through the legacy comparison. Callers
    /// must obtain explicit user confirmation first because the provider may
    /// charge for the new submission.
    func retryVideo(jobID: UUID) async throws -> MediaGenerationJob {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let original = try await store.ownedJob(id: jobID) else {
            throw MediaGenerationJobStoreError.missingJob(jobID)
        }
        let request = try JSONDecoder().decode(RemoteVideoRequest.self, from: original.job.requestJSON)
        let submission = try await submitVideo(
            modelID: original.job.modelID,
            owner: original.owner,
            originRunID: original.originRunID,
            sourceNodeIDs: original.job.sourceNodeIDs,
            resultNodeID: original.job.resultNodeID,
            request: request,
            canvasDocumentID: original.documentID
        )
        return submission.job
    }

    /// Delivers a job that just became ready. Conversation-owned results are
    /// copied into the conversation workspace (GeneratedMedia) and announced
    /// as a steer/queued input; canvas jobs keep their canvas UI path. Every
    /// completion still posts a local notification.
    func deliverReadyMediaJob(jobID: UUID) async {
        let store = MediaGenerationJobStore(database: environment.database)
        // Only a job whose durable state is `ready` is delivered; a cancelled
        // or failed job can never be announced as a finished video.
        guard let owned = try? await store.ownedJob(id: jobID),
              owned.job.state == .ready else { return }
        var detail = "生成结果已保存到素材库，并会在画布中恢复。"
        if owned.owner.kind == .conversation {
            detail = await deliverConversationResult(owned)
        }
        let content = UNMutableNotificationContent()
        content.title = "视频已准备好"
        content.body = detail
        content.sound = .default
        content.userInfo = ["mediaJobID": jobID.uuidString]
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "media.\(jobID.uuidString)", content: content, trigger: nil
        ))
    }

    private func deliverConversationResult(_ owned: OwnedMediaGenerationJob) async -> String {
        guard let localAssetID = owned.job.localAssetID,
              let asset = try? await environment.creativeAssetStore.asset(id: localAssetID),
              let relative = asset.localRelativePath else {
            return "生成结果已保存到素材库（jobID \(owned.job.id.uuidString)）。"
        }
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        guard let source = support?.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative),
              FileManager.default.fileExists(atPath: source.path) else {
            return "生成结果已保存到素材库（\(relative)）。"
        }
        var delivered: String?
        var note: String?
        let reattacher = WorkspaceRootReattacher(
            store: SQLiteWorkspaceStore(database: environment.database)
        )
        if let lease = await reattacher.acquireRoot(conversationID: owned.owner.id) {
            defer { lease.release() }
            let directory = lease.url.appendingPathComponent("GeneratedMedia", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(
                    "\(owned.job.id.uuidString)-\(source.lastPathComponent)"
                )
                let staging = directory.appendingPathComponent(".floe-deliver-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: staging) }
                if FileManager.default.fileExists(atPath: staging.path) {
                    try FileManager.default.removeItem(at: staging)
                }
                try FileManager.default.copyItem(at: source, to: staging)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try FileManager.default.moveItem(at: staging, to: destination)
                }
                delivered = "GeneratedMedia/\(destination.lastPathComponent)"
            } catch {
                note = "对话工作区写入失败：\(error.localizedDescription)；结果保留在素材库（\(relative)）。"
                FloeLogger(category: .app).warning(
                    "mediaJobWorkspaceDeliveryFailed job=\(owned.job.id.uuidString)"
                )
            }
        } else {
            note = "对话工作区当前不可用；结果保留在素材库（\(relative)）。"
        }
        let location = delivered ?? relative
        if note == nil {
            note = "已保存到对话工作区：\(location)"
        }
        let content = "视频已生成并保存到 \(location)（jobID \(owned.job.id.uuidString)）。 \(note ?? "")"
        // A live run receives the result as a steer. Otherwise the message is
        // queued and stays visible without auto-launching a new agent turn.
        let activeOriginRun = owned.originRunID.flatMap { runID in
            environment.conversationCenter.hasActiveRun(runID) ? runID : nil
        }
        try? await environment.conversationCenter.submitRunningInput(
            content: content,
            in: owned.owner.id,
            // A live run receives this as a steer; otherwise it is queued for
            // the user. The random fallback never matches a run.
            expectedRunID: activeOriginRun ?? owned.originRunID ?? UUID(),
            mode: activeOriginRun == nil ? .queue : .steer,
            selectedModelID: nil,
            workspaceID: environment.workspaceCenter.workspaceID(for: owned.owner.id),
            executionMode: .agent,
            attachments: []
        )
        return note ?? "已保存到对话工作区：\(location)"
    }
}

/// Background network-process owner for short-lived provider result URLs.
/// Files move into the durable material library before a job becomes ready.
/// The completed download is staged, size-verified and committed atomically;
/// failures keep a truthful job state and never leave a half-written result.
final class MediaArtifactDownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let sessionIdentifier = "org.floeagent.media-artifacts"
    /// Hard ceiling for one generated video download.
    static let maximumDownloadBytes: Int64 = 4 * 1024 * 1024 * 1024

    private let database: DatabaseManager
    private let onReady: (@Sendable (UUID) async -> Void)?
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    init(database: DatabaseManager, onReady: (@Sendable (UUID) async -> Void)? = nil) {
        self.database = database
        self.onReady = onReady
        super.init()
        _ = session
    }

    func start(jobID: UUID, remoteURL: URL, headers: [String: String] = [:]) async {
        guard remoteURL.scheme?.lowercased() == "https",
              remoteURL.user == nil, remoteURL.password == nil,
              remoteURL.host != nil, !remoteURL.isLocalOrPrivateNetwork else {
            await fail(jobID: jobID, message: "供应商返回了不安全的下载地址。")
            return
        }
        let tasks = await session.allTasks
        if tasks.contains(where: { $0.taskDescription == jobID.uuidString }) { return }
        var request = URLRequest(url: remoteURL)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.downloadTask(with: request)
        task.taskDescription = jobID.uuidString
        task.priority = URLSessionTask.highPriority
        task.resume()
    }

    /// Provider downloads may legitimately redirect (Google serves generated
    /// files through a separate media host), but the credential header must
    /// not leak to an arbitrary third party. Cross-host redirects are only
    /// followed for the documented Google media hosts, and only after the
    /// credential header is stripped; every other cross-host redirect is
    /// refused.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let originalHost = task.originalRequest?.url?.host,
              let target = request.url,
              target.user == nil, target.password == nil,
              !target.isLocalOrPrivateNetwork,
              VideoDownloadRedirectPolicy.allowsRedirect(from: originalHost, to: target) else {
            completionHandler(nil)
            return
        }
        if (target.host ?? "").caseInsensitiveCompare(originalHost) == .orderedSame {
            completionHandler(request)
            return
        }
        var sanitized = request
        sanitized.setValue(nil, forHTTPHeaderField: "x-goog-api-key")
        sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
        completionHandler(sanitized)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let raw = downloadTask.taskDescription, let jobID = UUID(uuidString: raw) else { return }
        do {
            // The system deletes `location` when this delegate returns, so move
            // it to a durable staging path synchronously and verify/commit in
            // a task.
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let stagingDirectory = support.appendingPathComponent("FloeAgent/MediaStaging", isDirectory: true)
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            let staging = stagingDirectory.appendingPathComponent("\(jobID.uuidString)-\(UUID().uuidString).download")
            if FileManager.default.fileExists(atPath: staging.path) {
                try FileManager.default.removeItem(at: staging)
            }
            try FileManager.default.moveItem(at: location, to: staging)
            // Extract Sendable scalars before crossing into the settle task;
            // URLResponse itself must not cross isolation.
            let statusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            let mimeType = downloadTask.response?.mimeType
            let suggestedExtension = downloadTask.response?.suggestedFilename
                .flatMap { URL(fileURLWithPath: $0).pathExtension }
                .flatMap { $0.isEmpty ? nil : $0 }
            let sourceURL = downloadTask.originalRequest?.url
            Task {
                await self.settle(
                    jobID: jobID, staging: staging, statusCode: statusCode,
                    mimeType: mimeType, suggestedExtension: suggestedExtension,
                    sourceURL: sourceURL
                )
            }
        } catch {
            Task { await fail(jobID: jobID, message: error.localizedDescription) }
        }
    }

    private func settle(
        jobID: UUID,
        staging: URL,
        statusCode: Int,
        mimeType: String?,
        suggestedExtension: String?,
        sourceURL: URL?
    ) async {
        let fileManager = FileManager.default
        let store = MediaGenerationJobStore(database: database)
        guard let job = try? await store.job(id: jobID), !job.state.isTerminal else {
            try? fileManager.removeItem(at: staging)
            return
        }
        let size = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else {
            try? fileManager.removeItem(at: staging)
            await fail(jobID: jobID, message: "供应商下载结果为空文件。")
            return
        }
        guard size <= Self.maximumDownloadBytes else {
            try? fileManager.removeItem(at: staging)
            await fail(jobID: jobID, message: "下载结果超过 \(Self.maximumDownloadBytes) 字节上限。")
            return
        }
        if statusCode != 0, !(200..<300).contains(statusCode) {
            try? fileManager.removeItem(at: staging)
            await fail(jobID: jobID, message: "下载返回 HTTP \(statusCode)")
            return
        }
        do {
            let support = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let directory = support.appendingPathComponent("FloeAgent/Materials", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let assetID = UUID()
            let extensionName = suggestedExtension ?? "mp4"
            let destination = directory.appendingPathComponent("\(assetID.uuidString)-generated.\(extensionName)")
            let receipt = try AtomicFileCommitter.commit(
                stagedFile: staging,
                to: destination,
                policy: FileCommitPolicy(
                    conflict: .failIfExists,
                    maxBytes: Int(Self.maximumDownloadBytes),
                    verifyBeforeCommit: { staged in
                        let stagedSize = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        guard stagedSize > 0 else {
                            throw FloeError.validationFailed("Downloaded media is empty")
                        }
                    }
                )
            )
            let hash = receipt.sha256
            let assetStore = CreativeAssetStore(database: database)
            try? await assetStore.save(CreativeAssetRecord(
                id: assetID, contentHash: hash, kind: .video,
                displayName: destination.deletingPathExtension().lastPathComponent,
                mimeType: mimeType ?? "video/mp4",
                localRelativePath: "Materials/\(destination.lastPathComponent)",
                cloudRecordName: nil, byteCount: size,
                sourceURL: sourceURL,
                license: nil, tags: ["生成内容"], referenceCount: 0,
                createdAt: Date(), updatedAt: Date()
            ))
            // The job may have been cancelled while the download was in
            // flight; a terminal job must never be announced as ready. The
            // material stays in the library (it is already on disk), but no
            // conversation input or notification claims success.
            let ready = try? await store.transition(id: jobID, to: .ready) {
                $0.localAssetID = assetID
                $0.lastError = nil
            }
            guard ready?.state == .ready else {
                FloeLogger(category: .app).warning(
                    "mediaJobDownloadDeliveredAfterTerminal job=\(jobID.uuidString)"
                )
                return
            }
            await onReady?(jobID)
        } catch {
            try? fileManager.removeItem(at: staging)
            await fail(jobID: jobID, message: error.localizedDescription)
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
                $0.nextPollAt = now.addingTimeInterval(MediaRetryBackoff.delay(afterRetryCount: $0.retryCount))
            }
        }
    }
}
#endif
