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

extension BackgroundRunCoordinator {
    /// How long a finished task keeps its name and result on the surface
    /// before teardown. Ten honest seconds — long enough to read the outcome,
    /// short enough not to pretend the work is still running.
    nonisolated static let terminalStateDwell: TimeInterval = 10
    /// Repeat taps of the same notification within this window route once.
    nonisolated static let duplicateNotificationRouteWindow: TimeInterval = 2.5
    /// Freshness window for a published guest metrics sample; older samples
    /// render "暂无" instead of a stale number.
    nonisolated static let linuxMetricsSampleValidity: TimeInterval = LinuxGuestMetricsSampler.sampleValidity
}

struct BackgroundExecutionSurfaceTransition: Sendable, Equatable {
    var stopsPictureInPicture: Bool
    var stopsScreenShare: Bool
    var preparesPictureInPicture: Bool
    var requestsScreenShareAuthorization: Bool
}

/// Unified per-environment runtime snapshot. Assembled once per refresh so
/// the PiP pager, the settings surface and notifications read exactly the
/// same truth: identity (kernel, actual core count, RAM), live counts
/// (commands, terminals, services, ports), the latest bounded resource
/// sample with its freshness, and the launch generation that separates this
/// boot from stale records of a previous one. Every optional value renders
/// "暂无" when unknown, never an invented zero.
struct LinuxEnvironmentRuntimeSnapshot: Sendable, Equatable {
    var environmentID: String
    var title: String
    var state: BackgroundWorkState
    var startedAt: Date?
    /// `uname -sr` of the running guest kernel. Environment-detail material
    /// for the settings surface, not the small PiP frame.
    var kernelVersion: String?
    /// Actual vCPUs reported by the running guest kernel.
    var coreCount: Int?
    /// Granted vCPU allocation from the runtime owner's own session state
    /// (`runtimeStates()`), not a guest measurement and not inferred from a
    /// conversation or a hold. Unknown stays nil.
    var allocatedVCPUs: Int?
    /// Freshly measured guest memory (nil when the sample is stale — a stale
    /// reading must render unknown, never as current usage).
    var memoryUsedMB: Int?
    /// Freshly measured guest memory total, nil when stale.
    var memoryTotalMB: Int?
    /// Configured RAM allocation from the runtime tier. Allocation fact, not
    /// a measurement; it stays labelled as allocation on settings surfaces.
    var ramConfiguredMB: Int?
    var commandCount: Int?
    /// Interactive terminal sessions. The runtime exposes no session-count
    /// interface yet; nil renders "暂无" until it does (reported to B).
    var terminalCount: Int?
    var serviceCount: Int?
    var portCount: Int?
    var guestCPUFraction: Double?
    /// Host emulator-thread occupancy, always labelled as the host thread.
    var hostThreadCPUFraction: Double?
    var sampledAt: Date?
    var sampleIsFresh: Bool
    /// Authoritative runtime identity for this boot; both fields stay unknown
    /// until the runtime owner exposes the lease token (B2/D contract).
    var runtimeID: String?
    var launchGeneration: UInt64?
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
    struct ActiveRun {
        let conversationID: UUID?
        let title: String
        /// When this workload first reported itself; used for the completion
        /// dwell's honest elapsed-time caption.
        var startedAt = Date()
        let continuedProcessingOrigin: ContinuedProcessingStartOrigin
        let allowsContinuedProcessing: Bool
        let retainsSurfaceOnFailure: Bool
        let sendsTerminalNotification: Bool
        /// False for temporary (ephemeral) chat runs: the shared run-work
        /// history (BackgroundWorkRegistry) and its outbox entries must
        /// never carry temporary content — not at start, not on progress
        /// updates, suspension, approval, error or finish. In-memory
        /// activity/PiP tracking is unaffected.
        let publishesContent: Bool
        /// Provider/remote media generation resumes through the durable media
        /// job machinery; it is not local model/tool execution and must never
        /// hold a background-location session.
        var isProviderRemoteMediaWork = false
        /// A suspended run (checkpointed, waiting for the user) stays in
        /// `activeRuns`, but it is not executing work. Only a real resumed
        /// activity/progress/tool event clears this.
        var isAwaitingUserAttention = false
        var stage: String = FloeL10n.l("platform.background_run_coordinator.running")
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

        /// True only for actual local execution: an ordinary agent run that
        /// is not waiting on an approval and not suspended awaiting the user.
        var isEligibleForBackgroundLocationAssist: Bool {
            !isProviderRemoteMediaWork
                && pendingApprovalToolName == nil
                && !isAwaitingUserAttention
        }

        func presentation(now: Date = Date()) -> String {
            let elapsed = max(0, Int(now.timeIntervalSince(stageStartedAt)))
            let idle = max(0, Int(now.timeIntervalSince(lastActivityAt)))
            // The speed figure is the model's decode rate only; it never
            // appears during tool phases and never counts tool output bytes.
            let speed: String
            if isGenerating, let rate = reportedTokensPerSecond, rate.isFinite, rate >= 0, idle < 5 {
                speed = String(format: FloeL10n.l("platform.background_run_coordinator.model_tokens_s"), rate)
            } else if isGenerating, outputCharacters > 0, idle < 5 {
                speed = String(format: FloeL10n.l("platform.background_run_coordinator.chars_sec"), Double(outputCharacters) / max(1, now.timeIntervalSince(outputWindowStartedAt)))
            } else { speed = "" }
            let activity = idle < 3 ? FloeL10n.l("platform.background_run_coordinator.just_received_activity") : FloeL10n.l("platform.background_run_coordinator.sec_since_last_activity", idle)
            // Bound the step caption so long titles leave room for real activity.
            let step = checklist?.currentStep.map { String($0.title.prefix(20)).replacingOccurrences(of: "\n", with: " ") }
            let task = checklist.map { "\n\($0.progressSummary)" + (step.map { FloeL10n.l("chat.thread_detail_view.current", $0) } ?? "") } ?? ""
            var toolLine = ""
            if let pending = pendingApprovalToolName {
                toolLine = FloeL10n.l("platform.background_run_coordinator.waiting_for_approval", pending)
            } else if let tool = currentToolName {
                let failures = toolFailureCount > 0 ? FloeL10n.l("platform.background_run_coordinator.failed", toolFailureCount) : ""
                toolLine = FloeL10n.l("platform.background_run_coordinator.tool_call", tool, toolCallCount, failures)
            } else if toolCallCount > 0 {
                let failures = toolFailureCount > 0 ? FloeL10n.l("platform.background_run_coordinator.failed", toolFailureCount) : ""
                toolLine = FloeL10n.plural("platform.background_run_coordinator.tool_calls", count: toolCallCount, failures)
            }
            return FloeL10n.l("platform.background_run_coordinator.this_stage_sec", stage, elapsed, speed, activity, task, toolLine)
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
    /// including CPU, memory and the command/service/port counts. This is a
    /// DISPLAY cache: it is never authority for whether work is still alive.
    private var linuxSurfaceEntries: [String: LinuxBackgroundSurfaceEntry] = [:]
    /// The only Linux environments that count as background-location work: the
    /// user permitted them AND the runtime owner reported them actually
    /// running at the last authoritative read. A display entry, a durable
    /// permission or an old hold alone never qualifies, so a guest that died
    /// outside the coordinator cannot keep the assist alive.
    private var locationLiveLinuxEnvironmentIDs: Set<String> = []
    /// Bumped by every explicit stop, delete or preference-off transition. An
    /// in-flight live read taken before that change is discarded instead of
    /// being applied afterwards, so a late snapshot can never resurrect
    /// stopped work.
    private var locationAuthorityGeneration: UInt64 = 0
    /// Monotonic epoch of authority reads: only the newest STARTED read may
    /// apply, so two overlapping reads cannot reorder into a stale `running`
    /// answer overwriting a newer `stopped` one.
    private var locationAuthorityQueryEpoch: UInt64 = 0
    /// Environments whose physical stop is in flight. The runtime may still
    /// report them running until the engine leaves, so they are excluded from
    /// every read until the stop actually completes.
    private var locationStoppingLinuxEnvironmentIDs: Set<String> = []
    /// Multi-VM pager for the floating surface (one VM per page).
    private var linuxSurfacePager = LinuxBackgroundSurfacePager()
    /// Per-environment port count published from the active forward plans.
    private var linuxPortCounts: [String: Int] = [:]
    /// Bounded probe result for runner-owned guest commands; nil = unknown.
    private var linuxCommandCounts: [String: Int] = [:]
    /// Durable terminal-event outbox: the first-authorization race queues an
    /// event instead of dropping it.
    /// True after the one-time launch reconciliation of schedule occurrences
    /// (claimed/running rows left by a dead process are marked interrupted; a
    /// never-launched one-shot is re-armed).
    private var didReconcileScheduleOccurrences = false
    /// The single in-flight startup reconcile shared by concurrent first
    /// callers. Without it, two callers passing the `didReconcile…` guard
    /// before either `await` returns would each enqueue a physical
    /// reconciliation, and the second one could interrupt an occurrence a
    /// live executor claimed right after the first succeeded. Cleared on
    /// failure so the next caller retries; readiness publishes only on
    /// success.
    private var scheduleOccurrenceReconcileTask: Task<Void, Error>?
    /// One in-flight explicit selected-schedule launch attempt. The key is
    /// the ACTUAL occurrence identity, never the schedule: simultaneous
    /// callbacks for one logical instance await this attempt and share its
    /// exact run, while two different due instances of the same schedule
    /// never merge. The creating caller is the only owner that clears its
    /// entry — identity-checked against `id` so a delayed clearer can never
    /// delete a newer attempt — on BOTH success and failure. The entry
    /// therefore lives only for the attempt: no finished receipt is cached,
    /// and a transient storage/launch failure is retried by the next caller
    /// instead of replaying the old error.
    private struct SelectedScheduleAttempt {
        let id: UUID
        let task: Task<FloeSelectedScheduleRunReceipt, Error>
    }
    private var selectedScheduleAttempts: [UUID: SelectedScheduleAttempt] = [:]
    /// Schedules with a registered insurance reminder right now (diagnostic
    /// only; the system's pending set remains the authority).
    private var scheduleReminderScheduleIDs: Set<UUID> = []
    private var notificationOutbox = TaskNotificationOutbox()
    private var notificationAuthorization: NotificationAuthorizationState = .notDetermined
    private var linuxPortCenter: LinuxPortForwardCenter { .shared }
    private var linuxMetricsSamplers: [String: LinuxGuestMetricsSampler] = [:]
    private var linuxMetricsTasks: [String: Task<Void, Never>] = [:]
    /// Latest unified runtime sample per environment; the single source the
    /// PiP pager, the settings surface and notifications read from. The
    /// sample carries the runtime identity (runtime id + launch generation)
    /// issued by the runtime lease — never a locally observed increment.
    private var linuxLastRuntimeSamples: [String: LinuxGuestRuntimeSample] = [:]
    // Report an invalid sampling interval once, not every three seconds.
    // Repeated idle samples must not evict useful crash/installation evidence.
    private var linuxUnverifiedMetricsReported: Set<String> = []
    /// Latest authoritative runtime state per environment (identity,
    /// liveness, granted shape) read from the runtime owner's session table.
    /// Surfaces list and label VMs from this — never from conversations,
    /// holds or the coordinator's expected subset.
    private var linuxRuntimeStates: [String: LinuxGuestRuntimeState] = [:]
    /// Managed interactive terminal count per environment; nil = unavailable
    /// (an environment the runtime does not own), never a fabricated zero.
    private var linuxTerminalCounts: [String: Int] = [:]
    /// Bounded record of unexpected service stops already surfaced as
    /// terminal events. Keyed by the supervisor's per-start token, so a
    /// repeated probe or a second observation of the same handle can never
    /// alert twice. Explicit host stops are never recorded here: they never
    /// produce a failure notification.
    private var surfacedLinuxServiceStops: Set<String> = []
    /// One app-lifetime observation of the supervisor's bounded lifecycle
    /// stream (not one per view). Started from AppEnvironment.bootstrap()
    /// after the environment exists.
    private var linuxServiceLifecycleTask: Task<Void, Never>?
    /// Notification-route bookkeeping: duplicate-tap suppression and the
    /// user-handled identifiers that a late scheduling error must not
    /// resurrect. The deferred-route slot itself is owned by
    /// `notificationRouteRequest`, so a superseding tap cannot leave an older
    /// route behind.
    private var recentNotificationRoutes: [String: Date] = [:]
    private var userHandledNotificationIdentifiers: [String: Date] = [:]
    /// Monotonic route-request generation and the single deferred-route slot.
    /// An async target-existence check that finishes after a newer tap started
    /// must not navigate: the stale completion is dropped when its generation
    /// is no longer current. A deferred route carries the generation of the
    /// tap that created it, so its retry is rejected once a newer tap
    /// superseded it.
    private var notificationRouteRequest = TaskDeepLinkRouteRequest()
    /// Environment-owned persistence readiness for the notification route
    /// gate. The app reads the real migrated-database state; the focused route
    /// regressions in the App-hosted bundle run against an in-memory database
    /// that never goes through `AppEnvironment.bootstrap()`, so a DEBUG build
    /// may pin exactly this one fact. The active scene and the mounted
    /// subscribers still come from the real `handleScenePhase` /
    /// `reconcileSchedulesAfterLaunch` calls, and Release reads only the
    /// environment.
    private var notificationRoutePersistenceReady: Bool {
        #if DEBUG
        if let notificationRoutePersistenceOverride { return notificationRoutePersistenceOverride }
        #endif
        return environment.persistenceReady
    }
    #if DEBUG
    private var notificationRoutePersistenceOverride: Bool?
    /// Pins the environment-owned persistence fact for the focused route
    /// regressions; `nil` restores the real environment value.
    func setNotificationRoutePersistenceOverrideForTesting(_ ready: Bool?) {
        notificationRoutePersistenceOverride = ready
    }
    #endif
    /// Actual "the navigation subscribers are mounted" evidence. Persistence
    /// plus an active scene only prove the hierarchy may exist; the
    /// `.floeOpenConversation` / `.floeOpenExecutionEnvironment` subscribers
    /// live in the root view, and a route posted before they mount goes
    /// nowhere while consuming the durable event. `reconcileSchedulesAfterLaunch`
    /// is invoked exactly by that root view's launch `.task`, so it is the
    /// app's real subscriber-installed signal.
    private var navigationSubscribersReady = false
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
    /// Fenced generation bookkeeping for the BGAppRefresh lifecycle. The
    /// scheduler races each task instance's expiration callback against the
    /// work body (and a second delivery defensively supersedes an unfinished
    /// generation); every cancel/clear/complete/claim step re-checks this
    /// fence so a stale or expired refresh can never touch a newer
    /// generation and no instance is ever completed twice (a second
    /// `setTaskCompleted` is an OS exception).
    private var refreshGeneration = BackgroundRefreshGenerationFence()
    /// The system task owned by the CURRENT refresh generation. Cleared
    /// together with the fence, so a completion always targets the instance
    /// whose generation still owns the slot.
    private weak var activeRefreshTask: BGAppRefreshTask?
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

    /// The explicit foreground work session (Task Center control). Lazy so
    /// a launch that never touches the session constructs no observation
    /// graph; the seams read ONLY existing durable stores and reuse the
    /// existing finite due pass plus the EXISTING continued-processing
    /// lifecycle — there is no second scheduler, no parallel claim path
    /// and no parallel background mechanism.
    lazy var workSession: BackgroundWorkSessionController = {
        let controller = BackgroundWorkSessionController(
            countsProvider: { [weak self] in
                guard let self else {
                    // The coordinator owning the durable stores is gone: the
                    // facts are UNKNOWN — never an "empty queue" answer.
                    throw BackgroundWorkSessionCountsUnknownError(component: "coordinator")
                }
                return try await self.workSessionCounts()
            },
            runDuePass: { [weak self] in
                await self?.runDueSchedulesNow()
            },
            onOwnershipChanged: { [weak self] snapshot in
                await self?.workSessionOwnershipChanged(snapshot)
            }
        )
        controller.qualificationContext = { [weak self] in
            guard let self else { return (foreground: false, loaded: false) }
            return (
                foreground: self.hasAggregateForegroundScene,
                loaded: self.environment.settingsCenter.launchPreferencesLoaded
            )
        }
        controller.submitQualification = { [weak self] stage, progress in
            self?.submitWorkSessionQualification(stage: stage, progress: progress) ?? false
        }
        controller.updateQualification = { [weak self] stage, progress in
            guard let self else { return }
            if #available(iOS 26.0, *) {
                self.updateContinuedTask(title: "Floe Agent", stage: stage, progress: progress)
            }
        }
        controller.releaseQualification = { [weak self] in
            self?.releaseWorkSessionQualification()
        }
        return controller
    }()

    /// Reserved eligibility identity for the work session inside the SAME
    /// `ContinuedProcessingEligibilityState` bookkeeping real runs use. A
    /// fixed nil-UUID is reserved for production runs, so this marker can
    /// never collide with a real run registration.
    static let workSessionEligibilityID = UUID(uuidString: "5E5510FF-10FF-4551-80FF-5E55100000A1")!

    /// Real framework submission through the ONE existing path. The origin
    /// is `.explicitUserAction` because the controller only calls this from
    /// a current-process foreground user start with admitted work; the
    /// shared path re-checks foreground, loaded preferences and the
    /// enhanced capability, so nothing is minted on a wake or a restored
    /// flag even if a caller lied.
    private func submitWorkSessionQualification(stage: String, progress: Int64) -> Bool {
        continuedEligibility.registerRun(
            Self.workSessionEligibilityID, origin: .explicitUserAction)
        return requestContinuedProcessingIfEligible(
            origin: .explicitUserAction,
            workload: "workSession",
            title: "Floe Agent",
            stage: stage,
            progress: progress
        )
    }

    /// Releases ONLY the session's own eligibility. A real run that still
    /// holds explicit-user eligibility keeps the shared continued task; the
    /// system task is finished only when the session was the last owner.
    private func releaseWorkSessionQualification() {
        continuedEligibility.finishRun(Self.workSessionEligibilityID)
        guard !continuedEligibility.hasEligibleWork else { return }
        if #available(iOS 26.0, *) {
            finishContinuedTasks(success: true)
        }
    }

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

    // MARK: - Independent-options policy

    /// Enhanced background processing is an INDEPENDENT capability: it is
    /// kept/submitted regardless of the visual surfaces, and only its own
    /// toggle (or unloaded launch preferences) withholds it. Turning it off
    /// stops/refrains the optional continued-processing task while ordinary
    /// finite completion/recovery (lease, BGProcessing, refresh) stays.
    nonisolated static func shouldKeepContinuedProcessing(
        for options: BackgroundExecutionOptions,
        launchPreferencesLoaded: Bool
    ) -> Bool {
        launchPreferencesLoaded && options.enhancedBackgroundEnabled
    }

    nonisolated static func shouldSubmitContinuedProcessing(
        for options: BackgroundExecutionOptions,
        launchPreferencesLoaded: Bool,
        origin: ContinuedProcessingStartOrigin,
        hasAggregateForegroundScene: Bool
    ) -> Bool {
        origin.allowsContinuedSubmission
            && hasAggregateForegroundScene
            && shouldKeepContinuedProcessing(
                for: options,
                launchPreferencesLoaded: launchPreferencesLoaded
            )
    }

    /// Independent surface transition: the PiP flag alone prepares/stops the
    /// PiP surface, and the screen-feedback flag alone stops the broadcast.
    /// A settings change NEVER requests ReplayKit consent — that stays tied
    /// to the actual run-start user action in
    /// `applyBackgroundExecutionPreference`.
    nonisolated static func visualSurfaceTransition(
        for options: BackgroundExecutionOptions
    ) -> BackgroundExecutionSurfaceTransition {
        BackgroundExecutionSurfaceTransition(
            stopsPictureInPicture: !options.pictureInPictureEnabled,
            stopsScreenShare: !options.screenFeedbackEnabled,
            preparesPictureInPicture: options.pictureInPictureEnabled,
            requestsScreenShareAuthorization: false
        )
    }

    /// Pure gate rule: a disabled status-PiP release gate strips both visual
    /// capabilities; enhanced background processing is never gated.
    nonisolated static func honoredOptions(
        _ options: BackgroundExecutionOptions,
        statusPiPEnabled: Bool
    ) -> BackgroundExecutionOptions {
        guard !statusPiPEnabled else { return options }
        // The gate degrades the app to the compliant standard path: the
        // audio surface and both visual surfaces are stripped together
        // (an ungated status PiP with a silent audio session was the
        // audited 2.5.4 problem). Enhanced processing stays independent
        // and is never gated, and the Live Activity choice is outside the
        // hierarchy, so honoring neither strips nor implies it.
        return BackgroundExecutionOptions(
            enhancedBackgroundEnabled: options.enhancedBackgroundEnabled,
            audioEnabled: false,
            pictureInPictureEnabled: false,
            screenFeedbackEnabled: false,
            taskLiveActivityEnabled: options.taskLiveActivityEnabled
        )
    }

    /// The exact three facts the coordinator pushes to the shared location
    /// service. Kept as a value so regressions assert the ACTUAL production
    /// decision (capability OR, real-work eligibility, multiwindow scene
    /// aggregation) instead of a mirrored formula.
    struct BackgroundLocationInputs: Sendable, Equatable {
        var supportEnabled: Bool
        var workEligible: Bool
        var fullyBackgroundScene: Bool
    }

    nonisolated static func backgroundLocationInputs(
        options: BackgroundExecutionOptions,
        statusPiPEnabled: Bool,
        runs: [ActiveRun],
        enabledLinuxEnvironmentIDs: [String],
        heldLinuxEnvironmentIDs: [String],
        runningLinuxEnvironmentIDs: [String],
        aggregateScenePhase: ScenePhase
    ) -> BackgroundLocationInputs {
        let honored = honoredOptions(options, statusPiPEnabled: statusPiPEnabled)
        let eligibleLinux = locationEligibleLinuxEnvironmentIDs(
            heldEnvironmentIDs: heldLinuxEnvironmentIDs,
            runningEnvironmentIDs: runningLinuxEnvironmentIDs,
            enabledEnvironmentIDs: enabledLinuxEnvironmentIDs
        )
        return BackgroundLocationInputs(
            supportEnabled: backgroundLocationSupportEnabled(for: honored),
            workEligible: hasLocationEligibleWork(
                runs: runs,
                heldLinuxEnvironmentIDs: eligibleLinux.held,
                runningLinuxEnvironmentIDs: eligibleLinux.running
            ),
            fullyBackgroundScene: aggregateScenePhase == .background
        )
    }

    /// Background location has NO separate switch. It follows the EXISTING
    /// honored background capabilities: when the app already promises that
    /// real work may continue, an explicit weather/nearby lookup may also
    /// finish. A disabled status-PiP release gate strips the visual flags via
    /// `honoredOptions`, so those already-downgraded choices cannot silently
    /// re-enable the assist.
    nonisolated static func backgroundLocationSupportEnabled(
        for honored: BackgroundExecutionOptions
    ) -> Bool {
        honored.enhancedBackgroundEnabled
            || honored.audioEnabled
            || honored.pictureInPictureEnabled
            || honored.screenFeedbackEnabled
    }

    /// Eligible work is actual local execution:
    ///  • an ordinary agent run that is not waiting on approval and not
    ///    suspended awaiting the user, or
    ///  • a Linux guest the user explicitly allowed to run in the background
    ///    and that is really running/held.
    /// Provider/remote media jobs are durable work recovered by the media job
    /// machinery, not local execution. Pending or future schedule plans have no
    /// entry here at all.
    nonisolated static func hasLocationEligibleWork(
        runs: [ActiveRun],
        heldLinuxEnvironmentIDs: [String],
        runningLinuxEnvironmentIDs: [String]
    ) -> Bool {
        if !runningLinuxEnvironmentIDs.isEmpty { return true }
        if !heldLinuxEnvironmentIDs.isEmpty { return true }
        return runs.contains { $0.isEligibleForBackgroundLocationAssist }
    }

    /// A guest only counts as eligible work when the user explicitly allowed
    /// THAT environment to run in the background AND the guest is actually
    /// running/held. A running VM the user never enabled for background work
    /// (or a stale surface entry) must not retain the location assist.
    nonisolated static func locationEligibleLinuxEnvironmentIDs(
        heldEnvironmentIDs: [String],
        runningEnvironmentIDs: [String],
        enabledEnvironmentIDs: [String]
    ) -> (held: [String], running: [String]) {
        let enabled = Set(enabledEnvironmentIDs)
        let runningEligible = runningEnvironmentIDs.filter(enabled.contains)
        let runningSet = Set(runningEligible)
        // A hold is authority only for a guest that is still both permitted
        // and actually running; a stale hold cannot keep the assist alive.
        let heldEligible = heldEnvironmentIDs.filter {
            enabled.contains($0) && runningSet.contains($0)
        }
        return (held: heldEligible, running: runningEligible)
    }

    /// Multiwindow aggregation: a single active scene keeps the app
    /// foreground. Inactive alone (Control Center, a system sheet, a scene
    /// handoff) is NOT background. Only every-window-background is.
    nonisolated static func aggregateScenePhase(
        _ phases: [String: ScenePhase]
    ) -> ScenePhase {
        if phases.values.contains(.active) { return .active }
        if phases.values.contains(.inactive) { return .inactive }
        return .background
    }

    /// Automatic inline arming is owned by the PiP capability ALONE: screen
    /// feedback runs concurrently and must never downgrade PiP to a
    /// manual-only surface. The legacy `.screenShare` projection therefore
    /// must not drive this decision. Existing explicit-origin and batch
    /// suppression gates are applied by the callers, unchanged.
    nonisolated static func shouldArmAutomaticInlineStart(
        for options: BackgroundExecutionOptions
    ) -> Bool {
        options.pictureInPictureEnabled
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

    /// Legacy entry point kept for existing callers/tests: projects the old
    /// mutually-exclusive choice onto the current independent options and
    /// reconciles through the real options path. Under the prerequisite
    /// chain, enabling a visual pulls in its prerequisites (audio,
    /// enhanced); the DEEPEST capability is set first so a projection to
    /// `.standard`/`.pictureInPicture` is never refused by an active
    /// dependent (screen feedback is cleared before PiP). Production
    /// settings drive `backgroundExecutionOptionsDidChange` directly.
    func backgroundExecutionPreferenceDidChange(
        to preference: BackgroundExecutionPreference
    ) {
        var options = environment.settingsCenter.backgroundExecutionOptions
        options.setScreenFeedbackEnabled(preference == .screenShare)
        options.setPictureInPictureEnabled(preference != .standard)
        backgroundExecutionOptionsDidChange(to: options)
    }

    /// Settings are live, not just launch defaults. The three capabilities
    /// reconcile independently: enhanced background keeps/finishes the
    /// system continued-processing task regardless of the visual surfaces,
    /// while PiP/screen-feedback only prepare or stop their own surfaces.
    /// Changing settings never starts PiP playback, never presents ReplayKit
    /// authorization, and never starts task audio — those stay bound to real
    /// run/owner actions.
    func backgroundExecutionOptionsDidChange(
        to options: BackgroundExecutionOptions
    ) {
        // The release gate may downgrade the visual choices to the standard
        // path; reconcile against what the app actually honors.
        let honored = Self.honoredOptions(
            options,
            statusPiPEnabled: StatusPiPReleaseGate.isEnabled
        )
        // Background location follows the honored capability OR; a settings
        // change re-evaluates it immediately (including in the background).
        reconcileLocationAssist()
        // The standalone audio owner is a capability AND real-work fact:
        // an existing batch can start or stop owning the service session
        // when the user turns the capability on/off; the capability alone
        // never starts playback with no live task.
        reconcileStandaloneAudioOwner()
        // The task Live Activity is independent: this only makes the switch's
        // new value take effect (ending promptly when it was turned off).
        taskLiveActivityCoordinator().preferencesDidChange()
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
                    "continuedProcessingFinished reason=preferenceChanged enhanced=\(honored.enhancedBackgroundEnabled)"
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

        // Reconcile the visual surfaces in the same main-actor turn as the
        // preference publication.
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
                automaticallyStartsFromInline: Self.shouldArmAutomaticInlineStart(for: honored)
            )
        }
        assert(!transition.requestsScreenShareAuthorization)
        // Deliberately do not call requestBroadcast here. ReplayKit's system
        // consent remains tied to a subsequent explicit run action.
    }

    private var hasAggregateForegroundScene: Bool {
        effectiveScenePhase == .active && scenePhases.values.contains(.active)
    }

    /// The execution options the app may actually honor. Status PiP is an
    /// opt-in surface behind `StatusPiPReleaseGate`; when the gate is
    /// disabled, the visual capabilities degrade to the compliant standard
    /// path (30s lease + system continued processing) instead of creating a
    /// controller. Enhanced background processing is never gated.
    private var effectiveBackgroundExecutionOptions: BackgroundExecutionOptions {
        Self.honoredOptions(
            environment.settingsCenter.backgroundExecutionOptions,
            statusPiPEnabled: StatusPiPReleaseGate.isEnabled
        )
    }

    /// Compatibility projection of the honored options for the surfaces that
    /// still reason in the legacy vocabulary (visual-surface batch policy,
    /// automatic-inline arming, diagnostics).
    private var effectiveBackgroundExecutionPreference: BackgroundExecutionPreference {
        effectiveBackgroundExecutionOptions.legacyPreference
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
        stage: String = FloeL10n.l("platform.background_run_coordinator.running"),
        progress: Int64 = 5
    ) -> Bool {
        let options = effectiveBackgroundExecutionOptions
        let loaded = environment.settingsCenter.launchPreferencesLoaded
        guard Self.shouldSubmitContinuedProcessing(
            for: options,
            launchPreferencesLoaded: loaded,
            origin: origin,
            hasAggregateForegroundScene: hasAggregateForegroundScene
        ) else {
            let keepsConversationTask = Self.shouldKeepContinuedProcessing(
                for: options,
                launchPreferencesLoaded: loaded
            )
            // An enabled Linux background session keeps its own system task,
            // even while the chat surface preference is a visual mode.
            let keepsLinuxSessionTask = loaded && !linuxBackgroundEnabledEnvironmentIDs().isEmpty
            if !keepsConversationTask, !keepsLinuxSessionTask, #available(iOS 26.0, *) {
                finishContinuedTasks(success: true)
            }
            FloeLogger(category: .app).info(
                "continuedProcessingSkipped workload=\(workload) origin=\(origin.rawValue) foreground=\(hasAggregateForegroundScene) enhanced=\(options.enhancedBackgroundEnabled) preference=\(options.legacyPreference.rawValue) loaded=\(loaded)"
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
        origin: ContinuedProcessingStartOrigin,
        /// False for temporary (ephemeral) chat runs: no content-bearing work
        /// record, no terminal notification/outbox entry and no continued-task
        /// registration; in-memory activity/PiP tracking still runs.
        publishesContent: Bool = true
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
        // first CONTENT-PUBLISHING task, never during a cold app launch and
        // never from a temporary (ephemeral) run — no notification
        // infrastructure engages for a conversation whose content must stay
        // out of history, work records and the outbox.
        if activeRuns.isEmpty,
           publishesContent,
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
            allowsContinuedProcessing: publishesContent,
            retainsSurfaceOnFailure: true,
            sendsTerminalNotification: publishesContent,
            publishesContent: publishesContent
        )
         activeRuns[runID] = run
        // A genuinely new run re-arms task ambience inside a continuing owner
        // session. With the standalone audio capability the run batch IS the
        // owner (service/task-owned, no PiP view required); without it,
        // ownership stays bound to the real PiP surface. A start never
        // enables any capability as a side effect.
        environment.pipAudioService.handleRunStarted()
        reconcileStandaloneAudioOwner()
        // A live work session tracks the real admitted work; later work
        // joins only an actual valid session (refreshIfLive no-ops
        // otherwise) and can never revive a stopped/interrupted record.
        Task { [weak self] in await self?.workSession.refreshIfLive() }
        if publishesContent {
            _ = continuedEligibility.registerRun(runID, origin: origin)
            publishRunWork(
                runID: runID,
                title: title,
                conversationID: conversationID,
                startedAt: run.startedAt,
                state: .running,
                progressText: FloeL10n.l("platform.background_run_coordinator.running")
            )
        }
        FloeLogger(category: .app).info(
            "backgroundRunStarted run=\(runID.uuidString) conversation=\(conversationID.uuidString) origin=\(origin.rawValue) preference=\(environment.settingsCenter.backgroundExecution.rawValue) activeRuns=\(activeRuns.count) contentSurfaces=\(publishesContent)"
        )
        if publishesContent {
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
        reconcileLocationAssist()
        reconcileTaskLiveActivity(reason: "runStart")
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
            // Media generation is ordinary, durable product work: its
            // progress and terminal state belong in the shared work history
            // (Canvas/media task status). Only the system notification is
            // suppressed for media; the record itself is content-published.
            publishesContent: true,
            isProviderRemoteMediaWork: true,
            stage: FloeL10n.l("platform.background_run_coordinator.generating_media"),
            progress: 10
        )
        FloeLogger(category: .app).info(
            "backgroundMediaStarted work=\(workID.uuidString) activeRuns=\(activeRuns.count)"
        )
        environment.pipAudioService.handleRunStarted()
        reconcileStandaloneAudioOwner()
        Task { [weak self] in await self?.workSession.refreshIfLive() }
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
        reconcileLocationAssist()
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
        let wasAwaitingUserAttention = active.isAwaitingUserAttention
        if let tokensPerSecond { active.reportedTokensPerSecond = tokensPerSecond }
        if active.isAwaitingUserAttention { active.isAwaitingUserAttention = false }
        activeRuns[runID] = active
        reconcileLocationAssist()
        // Only a suspended run actually resuming is visible; ordinary
        // per-token activity never reaches the Live Activity owner.
        if wasAwaitingUserAttention {
            reconcileTaskLiveActivity(reason: "resumed")
        }
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
        if active.isAwaitingUserAttention { active.isAwaitingUserAttention = false }
        activeRuns[runID] = active
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: active.presentation())
        }
        reconcileLocationAssist()
        reconcileTaskLiveActivity(reason: "toolEvent")
    }

    func didUpdatePendingApproval(runID: UUID, toolName: String?) {
        guard var active = activeRuns[runID] else { return }
        guard active.pendingApprovalToolName != toolName else { return }
        active.pendingApprovalToolName = toolName
        activeRuns[runID] = active
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: active.presentation())
        }
        reconcileLocationAssist()
        reconcileTaskLiveActivity(reason: "approval")
        // The central approval-paused ↔ approval-cleared flip (both
        // directions pass the real-change guard above) moves the counts
        // behind the session's waitReason (.approvals): let a live work
        // session re-derive its state immediately instead of waiting for a
        // Home manual pull. A non-live record is never revived.
        Task { [weak self] in await self?.workSession.refreshIfLive() }
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
        if active.isAwaitingUserAttention { active.isAwaitingUserAttention = false }
        activeRuns[runID] = active
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: active.presentation())
        }
        reconcileLocationAssist()
        reconcileTaskLiveActivity(reason: "checklist")
    }

    func didUpdateProgress(runID: UUID, stage: String, progress: Int64, isGenerating: Bool = false) {
        guard var active = activeRuns[runID] else { return }
        let stageChanged = active.stage != stage
        let wasAwaitingUserAttention = active.isAwaitingUserAttention
        if stageChanged {
            active.stageStartedAt = Date()
            active.outputWindowStartedAt = Date()
            active.outputCharacters = 0
            active.reportedTokensPerSecond = nil
        }
        active.stage = stage
        active.isGenerating = isGenerating
        active.progress = progress
        // Real progress proves the run resumed after a suspension.
        active.isAwaitingUserAttention = false
        activeRuns[runID] = active
        if #available(iOS 26.0, *),
           active.allowsContinuedProcessing,
           active.continuedProcessingOrigin.allowsContinuedSubmission {
            updateContinuedTask(title: "Floe Agent", stage: stage, progress: progress)
        }
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: active.presentation())
        }
        reconcileLocationAssist()
        // Temporary runs never enter the shared work history — not on
        // progress updates either.
        if active.publishesContent {
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
        // Only a visible change (stage text, or resuming from a suspension)
        // reaches the Live Activity; progress percentages alone never do.
        if stageChanged || wasAwaitingUserAttention {
            reconcileTaskLiveActivity(reason: "progress")
        }
        // Real progress is proof the run resumed after a suspension: on
        // exactly that transition, let a live work session re-derive its
        // counts/waitReason immediately (no Home manual pull; per-token
        // percentages never reach this).
        if wasAwaitingUserAttention {
            Task { [weak self] in await self?.workSession.refreshIfLive() }
        }
    }

    /// Keeps a durable, user-resumable run visible without turning the
    /// checkpoint into a failure notification or tearing down PiP. Browser
    /// takeover and other explicit user-action boundaries use this path.
    func didSuspend(runID: UUID, message: String) {
        guard var active = activeRuns[runID] else { return }
        active.stage = message
        active.progress = max(active.progress, 60)
        // A suspension is the run waiting for the user: it stays visible in
        // `activeRuns` but is no longer executing work of its own.
        active.isAwaitingUserAttention = true
        activeRuns[runID] = active
        retainedPausedRun = (runID, active)
        // A suspension is a real user-action boundary (browser takeover and
        // friends): the sound surface treats it as "needs input", throttled.
        environment.pipAudioService.handleTaskEvent(.needsInput, runID: runID)
        if #available(iOS 26.0, *),
           active.allowsContinuedProcessing,
           active.continuedProcessingOrigin.allowsContinuedSubmission {
            updateContinuedTask(title: active.title, stage: message, progress: active.progress)
        }
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(title: active.title, progress: message)
        }
        // Temporary runs never enter the shared work history — suspension
        // included; their suspension text is also content and stays out of
        // the diagnostics buffer.
        FloeLogger(category: .app).info(
            "backgroundRunSuspended run=\(runID.uuidString) message=\(active.publishesContent ? message : "redacted") activeRuns=\(activeRuns.count)"
        )
        if active.publishesContent {
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
        reconcileLocationAssist()
        reconcileTaskLiveActivity(reason: "suspended")
        // The central suspension transition puts the run into
        // waiting-for-the-user: re-derive a live session's counts/waitReason
        // immediately (armed/idle records stay untouched by refreshIfLive).
        Task { [weak self] in await self?.workSession.refreshIfLive() }
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
        // Durable schedule-completion bridge BEFORE the work record is torn
        // down: a scheduled run's real terminal state settles its occurrence,
        // and only a SUCCESSFUL upstream run enqueues after-success work.
        Task { [weak self] in
            await self?.recordScheduleRunCompletion(
                runID: runID, succeeded: succeeded, message: message)
        }
        finishRun(
            runID: runID,
            outcome: succeeded ? .succeeded : .failed,
            message: message
        )
    }

    /// The user (or the system) cancelled the run. The work record and the
    /// durable notification both report cancellation instead of a failure.
    func didCancel(runID: UUID, message: String?) {
        Task { [weak self] in
            await self?.recordScheduleRunCompletion(
                runID: runID, succeeded: false, message: message, cancelled: true)
        }
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
        // Typed terminal stage for the PiP sound surface. Ambient teardown is
        // decided by the BATCH, not by this run: with parallel runs still
        // active, run A finishing keeps run B's ambience; only an emptied
        // batch stops the loop (queued terminal speech/cue stay bounded).
        let audioStage: PiPAudioTaskStage
        switch outcome {
        case .succeeded: audioStage = .completed
        case .failed: audioStage = .failed
        case .cancelled: audioStage = .cancelled
        }
        environment.pipAudioService.handleTaskEvent(audioStage, runID: runID)
        if activeRuns.isEmpty {
            environment.pipAudioService.handleRunBatchTerminal()
        }
        reconcileStandaloneAudioOwner()
        // A finished run changes the admitted-work counts; a live session
        // re-derives its honest state (and releases its qualification when
        // nothing admitted remains). Non-live records are untouched.
        Task { [weak self] in await self?.workSession.refreshIfLive() }
        let conversationID = finished.conversationID
        notifiedApprovalRuns.remove(runID)
        if finished.sendsTerminalNotification, let conversationID {
            notifyTerminal(
                conversationID: conversationID,
                runID: runID,
                title: finished.title,
                outcome: outcome,
                message: message
            )
        }
        if #available(iOS 26.0, *), !continuedEligibility.hasEligibleWork {
            finishContinuedTasks(success: succeeded)
        }
        // The content flag decides the work record's fate: content-publishing
        // runs (ordinary conversations, media generation) keep an honest
        // terminal record; temporary runs never registered one and the
        // removal is a fail-closed no-op for any residue.
        if finished.publishesContent {
            finishRunWork(
                runID: runID,
                title: finished.title,
                conversationID: conversationID,
                startedAt: finished.startedAt,
                outcome: outcome,
                message: message
            )
        } else {
            // Temporary runs never registered a work record; nothing to finish.
            Task { await BackgroundWorkRegistry.shared.remove(id: runID) }
        }
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
                // The terminal state (task name + result) owns the frame for
                // the whole dwell; a live carousel would overwrite it on its
                // next tick and make a finished task look still running.
                pipCarouselTask?.cancel()
                pipCarouselTask = nil
                if wasSurfaced {
                    environment.backgroundVideoService.update(
                        title: finished.title,
                        progress: Self.completedSurfaceText(for: finished, message: message)
                    )
                }
                scheduleSuccessSurfaceTeardown(
                    generation: plan.generation,
                    dwell: max(plan.delay, Self.terminalStateDwell)
                )
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
                // disappearance. The recovery frame is static: no carousel
                // page may overwrite it.
                pipCarouselTask?.cancel()
                pipCarouselTask = nil
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
        // The last local run ended. A guest can stop without any coordinator
        // stop callback (engine stop from the environment card, delete, arbiter
        // release, crash), so this existing terminal route re-verifies the
        // cached live set with the runtime owner instead of leaving it armed.
        if activeRuns.isEmpty, !locationLiveLinuxEnvironmentIDs.isEmpty {
            Task { [weak self] in
                await self?.reconcileLinuxBackgroundHold()
            }
        }
        reconcileLocationAssist()
        reconcileTaskLiveActivity(reason: "runFinish")
    }

    /// Honest success caption for the completion dwell: the task name, the
    /// real result message and the measured elapsed time. No invented
    /// progress. The caption stays on screen for `terminalStateDwell`.
    nonisolated static func completedSurfaceText(
        for run: (title: String, startedAt: Date),
        message: String? = nil,
        now: Date = Date()
    ) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(run.startedAt)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let duration = minutes > 0
            ? String(
                format: String(localized: "background.surface.duration.minutes_seconds"),
                minutes,
                seconds
            )
            : String(
                format: String(localized: "background.surface.duration.seconds"),
                seconds
            )
        var lines = [
            run.title,
            String(
                format: String(localized: "background.surface.completed_duration"),
                duration
            ),
        ]
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append(String(message.prefix(120)))
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func completedSurfaceText(for run: ActiveRun, message: String? = nil) -> String {
        completedSurfaceText(for: (title: run.title, startedAt: run.startedAt), message: message)
    }

    /// Actionable failure caption: the failure reason plus what the user can
    /// do. The durable recovery point is written by ConversationCenter; this
    /// text never claims the run is still working.
    private nonisolated static func failedSurfaceText(for run: ActiveRun, message: String?) -> String {
        var lines = [run.title, FloeL10n.l("platform.background_run_coordinator.run_failed_open_floe_to_recover")]
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
            if self.linuxBackgroundHold.hasActiveHold {
                // A held VM kept running (its background services are real
                // work): hand the surface back to it instead of tearing the
                // frame down and faking a stop.
                self.resumeBackgroundSurfaceIfNeeded()
            } else {
                self.tearDownBackgroundExecutionPreference()
            }
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
            text = Self.completedSurfaceText(
                for: (title: title, startedAt: startedAt),
                message: message
            )
        case .cancelled:
            text = message ?? FloeL10n.l("platform.background_run_coordinator.canceled_checkpoint_kept")
        case .failed:
            text = Self.failedSurfaceText(
                for: ActiveRun(
                    conversationID: conversationID,
                    title: title,
                    startedAt: startedAt,
                    continuedProcessingOrigin: .automaticTool,
                    allowsContinuedProcessing: false,
                    retainsSurfaceOnFailure: true,
                    sendsTerminalNotification: false,
                    publishesContent: false
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
            notifiesActionRequired: policy.shouldNotifyActionRequired,
            // The one-time long-run duration advisory is a mid-run
            // checkpoint while the work continues: it follows the user's
            // stage-notification preference (default policy `.stages` keeps
            // the human-policy reminder on).
            notifiesDurationAdvisory: policy.shouldNotifyStages
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
            if event.kind == .durationAdvisory {
                // A QUEUED duration advisory is re-validated against the
                // CURRENT target liveness before it may post: a reminder
                // whose work actually finished while notification
                // authorization was missing is expired and must never be
                // delivered late (no stale "still running" alert after real
                // completion/cancel). The dropped event is not re-queued.
                if await queuedAdvisoryIsStillLive(event) {
                    post(event)
                } else {
                    notificationOutbox.discard(identifier: event.identifier)
                    persistNotificationOutbox()
                    FloeLogger(category: .app).info(
                        "durationAdvisoryExpired identifier=\(event.identifier)")
                }
                continue
            }
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
        // The authorization answer may resolve while a deferred notification
        // route is waiting for the same readiness.
        flushPendingNotificationRoute()
    }

    /// Durable terminal event. Policy gates creation, authorization gates
    /// delivery: while authorization is missing the event stays queued and is
    /// flushed by `refreshNotificationAuthorizationAndFlush`, never dropped.
    /// Foreground and background both go through UNUserNotificationCenter; in
    /// the foreground `willPresent` shows the system banner.
    @discardableResult
    func enqueueTerminalNotification(
        event: TaskTerminalEvent,
        policy: TaskNotificationPolicy? = nil
    ) -> Bool {
        let gate = Self.eventGate(for: policy)
        guard gate.allows(event.kind) else { return false }
        let disposition = notificationOutbox.enqueue(
            event,
            canPresent: notificationAuthorization.canPresentAlert
        )
        switch disposition {
        case .presentNow:
            post(event)
        case .queuedForAuthorization, .replacedQueuedEvent:
            notificationOutbox.recordSchedulingFailure(
                identifier: event.identifier,
                reason: "notification authorization is \(notificationAuthorization.rawValue); event queued",
                wasAuthorizationBlocked: true
            )
            FloeLogger(category: .app).info(
                "notificationQueued identifier=\(event.identifier) authorization=\(self.notificationAuthorization.rawValue) pending=\(self.notificationOutbox.pendingCount)"
            )
        }
        persistNotificationOutbox()
        switch disposition {
        case .presentNow: return true
        case .queuedForAuthorization, .replacedQueuedEvent:
            return notificationOutbox.pending.contains { $0.identifier == event.identifier }
        }
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
                    // A system-side scheduling error must not lose the event —
                    // unless the user already acted on it (tap → discard), in
                    // which case resurrecting the queue entry would alert a
                    // second time.
                    if self.userHandledNotificationIdentifiers[event.identifier] == nil {
                        _ = self.notificationOutbox.enqueue(event, canPresent: false)
                    } else {
                        FloeLogger(category: .app).info(
                            "notificationResurrectionSkipped identifier=\(event.identifier) reason=alreadyHandled"
                        )
                    }
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

    /// Recheck queued reminders against their own operation, never merely
    /// against a parent run which can outlive an individual command.
    private func queuedAdvisoryIsStillLive(_ event: TaskTerminalEvent) async -> Bool {
        let prefix = "duration.advisory."
        guard event.identifier.hasPrefix(prefix) else { return false }
        let ownershipKey = String(event.identifier.dropFirst(prefix.count))
        if ownershipKey.hasPrefix("shell.") {
            return await environment.durationAdvisoryWorkIsActive(ownershipKey: ownershipKey)
        }
        if let groupID = event.durationTargetGroupID {
            guard let service = environment.backgroundJobService else { return false }
            return await service.advisoryGroupIsLive(groupID: groupID)
        }
        if let jobID = event.durationTargetJobID {
            guard let service = environment.backgroundJobService else { return false }
            return await service.advisoryKeyIsLive(jobID)
        }
        if ownershipKey.hasPrefix("job."),
           let uuid = UUID(uuidString: String(ownershipKey.dropFirst("job.".count))) {
            guard let service = environment.backgroundJobService else { return false }
            return await service.advisoryKeyIsLive(uuid)
        }
        return false
    }

    /// One-time long-run duration advisory (new time policy: default
    /// execution is unlimited; ONE reminder at 600 seconds of host monotonic
    /// elapsed execution while the work simply continues). The caller
    /// (AppEnvironment's sink) has already applied the liveness gate, so this
    /// never alerts for finished/cancelled work. Policy gates creation and
    /// authorization gates delivery through the SAME durable outbox as
    /// terminal events: the stable `duration.advisory.<ownershipKey>`
    /// identifier replaces instead of stacks, a blocked authorization queues
    /// the reminder for the next flush, and permission/storage failures stay
    /// diagnostics — the running job is never touched.
    @discardableResult
    func enqueueDurationAdvisory(
        ownershipKey: String,
        conversationID: UUID?,
        runID: UUID?,
        jobID: UUID?,
        advisoryGroupID: UUID?,
        deliveryFence: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        guard let conversationID else {
            FloeLogger(category: .app).info(
                "durationAdvisoryDropped reason=noConversation key=\(ownershipKey)")
            return false
        }
        let policy = try? await SQLiteWorkspaceStore(database: environment.database)
            .taskPolicy(conversationID: conversationID)
        guard await deliveryFence() else { return false }
        return enqueueTerminalNotification(
            event: .durationAdvisory(
                ownershipKey: ownershipKey,
                title: FloeL10n.l("app.app_environment.background_task_still_running_title"),
                body: FloeL10n.l("app.app_environment.background_task_still_running_body"),
                deepLink: BackgroundWorkDeepLink(
                    kind: .modelRun,
                    conversationID: conversationID,
                    runID: runID
                ),
                // Backward-compatible re-validation targets for the queued
                // advisory flush (no identifier parsing needed).
                jobID: jobID,
                advisoryGroupID: advisoryGroupID
            ),
            policy: policy?.notificationPolicy
        )
    }

    /// Withdraws a still-QUEUED (authorization-blocked) duration advisory
    /// for one ownership key when its owning operation reaches its terminal
    /// close, so a late "still running" reminder never outlives the actual
    /// end of the work. An alert already handed to the OS is the accepted
    /// non-atomic window; this forbids only KNOWN-terminal late delivery.
    /// Ordinary terminal notifications are never touched.
    func discardPendingDurationAdvisory(ownershipKey: String) {
        let identifier = "duration.advisory.\(ownershipKey)"
        let before = notificationOutbox.pendingCount
        notificationOutbox.discard(identifier: identifier)
        if notificationOutbox.pendingCount != before {
            persistNotificationOutbox()
            FloeLogger(category: .app).info(
                "durationAdvisoryWithdrawn identifier=\(identifier)")
        }
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
    ///
    /// This is the completion-handler selector implemented directly, for the
    /// same reason as `didReceive` below: Build 271 aborted on the
    /// compiler-generated Objective-C bridge of the `async` delegate
    /// convenience when a framework-raised exception crossed it uncaught, and
    /// `willPresent` was the one remaining delegate callback still on that
    /// bridge. The presentation answer is a constant, so nothing is deferred:
    /// the completion handler is invoked synchronously and exactly once.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
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

    /// App-layer outcome caption for a terminal event. The core layer stays
    /// locale-neutral; the wording lives here with the rest of the surface
    /// copy and resolves through the App's en/zh-Hans catalog.
    nonisolated static func terminalEventBody(
        kind: TaskTerminalEventKind,
        resultMessage: String?,
        fallbackBody: String
    ) -> String {
        let label: String = switch kind {
        case .completed: String(localized: "background.event.completed")
        case .failed: String(localized: "background.event.failed")
        case .cancelled: String(localized: "background.event.cancelled")
        case .actionRequired: String(localized: "background.event.approval")
        case .durationAdvisory: FloeL10n.l("app.app_environment.background_task_still_running_title")
        }
        let detail: String
        if let trimmed = resultMessage?
            .trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            detail = trimmed
        } else {
            detail = fallbackBody
        }
        return "\(label) · \(detail)"
    }

    /// Terminal notification for a conversation run: the policy is read from
    /// the durable task record, the persistent alert carries the task name and
    /// the real result, the deep link identity is shared with the work
    /// record, and delivery is queued when authorization is missing.
    private func notifyTerminal(
        conversationID: UUID,
        runID: UUID,
        title: String,
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
                    snapshot.progressText = message ?? FloeL10n.l("platform.background_run_coordinator.canceled_checkpoint_kept")
                    snapshot.activeCommandCount = 0
                    await BackgroundWorkRegistry.shared.register(snapshot)
                }
            }
            let kind: TaskTerminalEventKind = switch outcome {
            case .succeeded: .completed
            case .failed: .failed
            case .cancelled: .cancelled
            }
            let fallbackBody: String = switch outcome {
            case .succeeded: String(localized: "background.run.success_body")
            case .failed: String(localized: "background.run.failure_body")
            case .cancelled: String(localized: "background.run.cancelled_body")
            }
            self.enqueueTerminalNotification(
                event: .modelRunTerminal(
                    runID: runID,
                    conversationID: conversationID,
                    taskName: title,
                    kind: kind,
                    body: Self.terminalEventBody(
                        kind: kind,
                        resultMessage: message,
                        fallbackBody: fallbackBody
                    )
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
            // A fresh explicit start/enable ends any earlier in-flight-stop
            // fence for this environment.
            finishLocationLinuxStop(environmentID: environmentID)
            let deepLink = BackgroundWorkDeepLink(
                kind: .linuxSession,
                environmentID: environmentID
            )
            let snapshot = BackgroundWorkSnapshot(
                id: workID,
                kind: .linuxSession,
                title: title,
                state: .running,
                progressText: FloeL10n.l("platform.background_run_coordinator.allowed_to_run_in_background"),
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
                    updateContinuedTask(title: title, stage: FloeL10n.l("platform.background_run_coordinator.run_linux_environment_in_background"), progress: 10)
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
            reconcileLocationAssist()
        } else {
            linuxBackgroundPreferences[environmentID] = LinuxBackgroundRunPreference(
                environmentID: environmentID,
                isEnabled: false
            )
            persistLinuxBackgroundPreferences()
            continuedEligibility.finishRun(workID)
            stopLinuxMetricsSampling(environmentID: environmentID)
            linuxBackgroundHold.preferenceDisabled(environmentID)
            invalidateLocationLinuxAuthority(environmentID: environmentID)
            linuxSurfaceEntries.removeValue(forKey: environmentID)
            linuxUnverifiedMetricsReported.remove(environmentID)
            publishLinuxSurfacePager()
            Task { await BackgroundWorkRegistry.shared.remove(id: workID) }
            if #available(iOS 26.0, *), !continuedEligibility.hasEligibleWork {
                finishContinuedTasks(success: true)
            }
            FloeLogger(category: .app).info(
                "linuxBackgroundSessionDisabled environment=\(environmentID)"
            )
            reconcileLocationAssist()
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
    /// order. This is the eligibility input of the hold policy and of
    /// background-location work.
    func backgroundEligibleEnvironmentIDs() async -> [String] {
        let enabled = linuxBackgroundEnabledEnvironmentIDs()
        #if DEBUG
        // Coordinator-decision tests supply their own live truth; shipping
        // code never sets this, so the runtime owner stays the only authority.
        if let override = linuxLiveGuestEnvironmentIDsOverrideForTesting {
            return await override(enabled)
        }
        #endif
        let controller = FloePlatformServices.shared.linuxGuestController()
        var eligible: [String] = []
        for environmentID in enabled {
            guard let controller else { continue }
            if await controller.guestIsRunning(environmentID: environmentID) {
                eligible.append(environmentID)
            }
        }
        return eligible
    }

    /// One authoritative read result. `generation`/`epoch` fence the snapshot:
    /// it may only be applied while both still match the coordinator, so a
    /// stop or a newer read that landed after this one started wins.
    private struct LocationAuthoritySnapshot {
        let environmentIDs: [String]
        let generation: UInt64
        let epoch: UInt64
    }

    /// Reads the live guest authority and makes it the only Linux fact behind
    /// background-location eligibility and the PiP hold. A guest the user
    /// allowed to run in the background is included only while the runtime
    /// owner reports it actually running; a display entry, a durable
    /// permission or an old hold alone never qualifies.
    ///
    /// The same read evicts cache entries for guests that stopped outside the
    /// coordinator (engine stop from the environment card, a deleted
    /// environment, the heavy-runtime arbiter, a guest crash) — those paths
    /// never call a stop callback here, so this reconciliation is what ends
    /// their background eligibility and location assist.
    ///
    /// Concurrency: every read takes a fresh epoch and only the newest started
    /// read may apply, so two reads cannot finish out of order. A stop/delete
    /// that lands while a read is awaiting bumps the generation; the snapshot
    /// is discarded (never re-read) and the stop path's already-pruned set is
    /// kept, so a guest whose physical stop is still pending can never be
    /// re-added from a runtime that has not finished stopping.
    private func refreshLocationLinuxAuthority() async -> LocationAuthoritySnapshot? {
        let generation = locationAuthorityGeneration
        locationAuthorityQueryEpoch &+= 1
        let epoch = locationAuthorityQueryEpoch
        let live = await backgroundEligibleEnvironmentIDs()
        // A newer read started while this one was awaiting: only its answer
        // may be applied.
        guard epoch == locationAuthorityQueryEpoch else { return nil }
        // An explicit stop/delete/preference change landed during the read.
        // The runtime may still report a stopping guest as running, so this
        // snapshot is not trustworthy and must not be re-read.
        guard generation == locationAuthorityGeneration else {
            let current = prunedLocationLinuxAuthority()
            locationLiveLinuxEnvironmentIDs = current
            evictStaleLinuxSurfaceEntries(keeping: current)
            return nil
        }
        var liveSet = Set(live)
        // A tombstone still reported running means the stop is genuinely in
        // flight; one the runtime no longer reports running has completed (or
        // was interrupted), so the tombstone is finished.
        locationStoppingLinuxEnvironmentIDs.formIntersection(liveSet)
        liveSet.subtract(locationStoppingLinuxEnvironmentIDs)
        locationLiveLinuxEnvironmentIDs = liveSet
        evictStaleLinuxSurfaceEntries(keeping: liveSet)
        return LocationAuthoritySnapshot(
            environmentIDs: liveSet.sorted(),
            generation: generation,
            epoch: epoch
        )
    }

    /// The currently applied authority, re-derived from the durable permission
    /// and the in-flight-stop tombstones. Used when a read must be discarded:
    /// it never adds an environment the last verified read did not include.
    private func prunedLocationLinuxAuthority() -> Set<String> {
        let permitted = Set(linuxBackgroundEnabledEnvironmentIDs())
        return locationLiveLinuxEnvironmentIDs
            .intersection(permitted)
            .subtracting(locationStoppingLinuxEnvironmentIDs)
    }

    /// The snapshot may still be applied only while no newer read started and
    /// no stop/delete/preference change landed since it was taken.
    private func isCurrent(_ snapshot: LocationAuthoritySnapshot) -> Bool {
        snapshot.epoch == locationAuthorityQueryEpoch
            && snapshot.generation == locationAuthorityGeneration
    }

    /// Drops every cached surface/projection for an environment the runtime no
    /// longer reports running, so a stale `.running` display entry can neither
    /// render a dead VM nor feed an eligibility decision. The stop paths that
    /// own the durable work record and the terminal event still run when the
    /// coordinator itself stops a guest; this only forgets the display cache.
    private func evictStaleLinuxSurfaceEntries(keeping eligible: Set<String>) {
        let stale = linuxSurfaceEntries.keys.filter { !eligible.contains($0) }
        guard !stale.isEmpty else { return }
        for environmentID in stale {
            linuxSurfaceEntries.removeValue(forKey: environmentID)
            linuxRuntimeStates.removeValue(forKey: environmentID)
            linuxLastRuntimeSamples.removeValue(forKey: environmentID)
            linuxUnverifiedMetricsReported.remove(environmentID)
            linuxCommandCounts.removeValue(forKey: environmentID)
            linuxPortCounts.removeValue(forKey: environmentID)
            linuxTerminalCounts.removeValue(forKey: environmentID)
            stopLinuxMetricsSampling(environmentID: environmentID)
            linuxBackgroundHold.environmentStopped(environmentID)
        }
        publishLinuxSurfacePager()
        FloeLogger(category: .app).info(
            "linuxBackgroundAuthorityEvicted count=\(stale.count)"
        )
    }

    /// An explicit stop/delete/preference-off whose physical stop has already
    /// completed (or is not the coordinator's to observe): the environment
    /// stops counting as live work immediately, and any in-flight authority
    /// read that began before this point is invalidated.
    private func invalidateLocationLinuxAuthority(environmentID: String) {
        locationAuthorityGeneration &+= 1
        locationLiveLinuxEnvironmentIDs.remove(environmentID)
        locationStoppingLinuxEnvironmentIDs.remove(environmentID)
    }

    /// The coordinator is about to stop the guest physically. It leaves
    /// eligibility now and is fenced out of every read until the stop
    /// completes, because the runtime can still report it running.
    private func beginLocationLinuxStop(environmentID: String) {
        locationAuthorityGeneration &+= 1
        locationLiveLinuxEnvironmentIDs.remove(environmentID)
        locationStoppingLinuxEnvironmentIDs.insert(environmentID)
    }

    /// The physical stop completed: a later start may become eligible again.
    private func finishLocationLinuxStop(environmentID: String) {
        locationStoppingLinuxEnvironmentIDs.remove(environmentID)
    }

    /// Reconciles the PiP hold with the live VM set. Called on a background
    /// transition, on a preference change, and whenever a VM starts or stops.
    func reconcileLinuxBackgroundHold() async {
        guard let authority = await refreshLocationLinuxAuthority() else {
            // A newer read or an explicit stop owns the outcome. Applying this
            // older snapshot could re-arm a guest whose stop is still pending.
            reconcileLocationAssist()
            return
        }
        await refreshLinuxSurfaceEntries(environmentIDs: authority.environmentIDs)
        // The surface refresh awaited, so a stop or a newer read may have
        // landed. Never apply this snapshot's ids or hold decision then, and
        // drop anything that refresh re-created for a no-longer-live guest.
        guard isCurrent(authority) else {
            evictStaleLinuxSurfaceEntries(keeping: locationLiveLinuxEnvironmentIDs)
            reconcileLocationAssist()
            return
        }
        let eligible = authority.environmentIDs
        guard isAppInBackground else {
            // Foreground: keep the hold membership current but never prepare
            // the floating surface; the next background transition does.
            linuxBackgroundHold.updateForegroundEligibleEnvironmentIDs(eligible)
            publishLinuxSurfacePager()
            reconcileLocationAssist()
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
            await stopAndFlushLinuxEnvironment(
                environmentID: environmentID,
                reason: String(localized: "background.linux.stop_reason.pip_closed")
            )
        case .retractSurface:
            environment.backgroundVideoService.update(
                title: FloeL10n.l("platform.background_run_coordinator.floe_returned_to_the_foreground"),
                progress: FloeL10n.l("platform.background_run_coordinator.the_linux_environment_keeps_running_the")
            )
        }
        for environmentID in linuxBackgroundHold.heldEnvironmentIDs {
            await publishLinuxSurfaceWork(environmentID: environmentID)
        }
        reconcileLocationAssist()
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
        // The first frame comes from the unified snapshot; the carousel owns
        // every subsequent frame, so a metric tick can never repage it.
        let title = linuxSurfacePager.current?.title ?? FloeL10n.l("exec.linux.env_title")
        let text = linuxEnvironmentRuntimeSnapshot(environmentID: environmentID)
            .map { Self.linuxSurfacePageText(for: $0) } ?? String(localized: "background.linux.surface_running")
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
        // The engine may keep reporting the guest running until it leaves, so
        // fence the environment out of every authority read until the physical
        // stop below completes.
        beginLocationLinuxStop(environmentID: environmentID)
        await linuxPortCenter.clearEngineForwards(environmentID: environmentID)
        linuxPortCenter.guestStopped(environmentID: environmentID)
        linuxPortCounts.removeValue(forKey: environmentID)
        linuxCommandCounts.removeValue(forKey: environmentID)
        linuxTerminalCounts.removeValue(forKey: environmentID)
        linuxRuntimeStates.removeValue(forKey: environmentID)
        stopLinuxMetricsSampling(environmentID: environmentID)
        let title = linuxSurfaceEntries[environmentID]?.title ?? FloeL10n.l("exec.linux.env_title")
        linuxSurfaceEntries.removeValue(forKey: environmentID)
        linuxUnverifiedMetricsReported.remove(environmentID)
        publishLinuxSurfacePager()
        await FloePlatformServices.shared.stopLinuxGuest(id: environmentID)
        finishLocationLinuxStop(environmentID: environmentID)
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        let snapshot = BackgroundWorkSnapshot(
            id: workID,
            kind: .linuxSession,
            title: title,
            state: .cancelled,
            interruption: .none,
            progressText: String(
                format: String(localized: "background.linux.stop_detail"),
                reason
            ),
            deepLink: BackgroundWorkDeepLink(kind: .linuxSession, environmentID: environmentID)
        )
        await BackgroundWorkRegistry.shared.register(snapshot)
        if #available(iOS 26.0, *), !continuedEligibility.hasEligibleWork {
            finishContinuedTasks(success: true)
        }
        enqueueTerminalNotification(
            event: .linuxSessionTerminal(
                environmentID: environmentID,
                environmentTitle: title,
                kind: .cancelled,
                body: Self.terminalEventBody(
                    kind: .cancelled,
                    resultMessage: String(
                        format: String(localized: "background.linux.disk_preserved"),
                        reason
                    ),
                    fallbackBody: String(localized: "background.linux.stopped_body")
                ),
                launchGeneration: linuxEnvironmentRuntimeSnapshot(environmentID: environmentID)?
                    .launchGeneration
            )
        )
        FloeLogger(category: .app).info(
            "linuxBackgroundHoldEnded environment=\(environmentID) reason=\(reason)"
        )
    }

    /// A managed guest service terminated abnormally. Shares the durable
    /// terminal-event pipeline with task failures — one vocabulary, one
    /// queue, one authorization gate — so a service end is surfaced like a
    /// task failure instead of vanishing silently. The persistent alert is
    /// emitted immediately; the shared work record follows the VM (a service
    /// that ended inside a still-running guest must not claim the whole
    /// environment failed).
    func linuxEnvironmentServiceDidFail(
        environmentID: String,
        title: String,
        serviceName: String,
        message: String
    ) {
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        let progressText = "\(serviceName) · \(message)"
        Task { [weak self] in
            guard let self else { return }
            let guestRunning = await self.environment.linuxGuestService?
                .guestIsRunning(environmentID: environmentID) ?? false
            if !guestRunning {
                // The terminal route proved the guest is gone: no cached live
                // authority may outlive it.
                self.invalidateLocationLinuxAuthority(environmentID: environmentID)
                self.reconcileLocationAssist()
            }
            let snapshot = BackgroundWorkSnapshot(
                id: workID,
                kind: .linuxSession,
                title: title,
                state: guestRunning ? .running : .failed,
                interruption: guestRunning ? .none : .checkpointed,
                progressText: progressText,
                deepLink: BackgroundWorkDeepLink(
                    kind: .linuxSession,
                    environmentID: environmentID
                )
            )
            await BackgroundWorkRegistry.shared.register(snapshot)
        }
        enqueueTerminalNotification(
            event: .linuxSessionTerminal(
                environmentID: environmentID,
                environmentTitle: "\(title) · \(serviceName)",
                kind: .failed,
                body: Self.terminalEventBody(
                    kind: .failed,
                    resultMessage: message,
                    fallbackBody: String(localized: "background.linux.service_exited_body")
                ),
                launchGeneration: linuxEnvironmentRuntimeSnapshot(environmentID: environmentID)?
                    .launchGeneration
            )
        )
        FloeLogger(category: .app).warning(
            "linuxEnvironmentServiceFailed environment=\(environmentID) service=\(serviceName)"
        )
    }

    // MARK: - Linux guest service lifecycle observation

    /// Starts the single app-lifetime observation of the supervisor's
    /// acknowledged service lifecycle stream. Called once from
    /// `AppEnvironment.bootstrap` after the environment is fully initialized;
    /// a second call is a no-op and no view ever creates its own monitor.
    /// Explicit host stops are ignored here (their own stop paths write the
    /// terminal record), while an observed end without a stop order is
    /// surfaced once with the real environment/service identity through the
    /// durable terminal pipeline. Every event is acknowledged only after the
    /// durable pipeline accepted it, so an unacknowledged observed end stays
    /// in the supervisor's bounded store and is replayed to a later
    /// observation instead of being lost.
    func startLinuxGuestServiceLifecycleObservation() {
        guard linuxServiceLifecycleTask == nil else { return }
        guard let service = environment.linuxGuestService else { return }
        linuxServiceLifecycleTask = Task { [weak self] in
            for await event in await service.localServiceLifecycleEvents() {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.linuxGuestServiceLifecycleObserved(event)
                await service.acknowledgeLocalServiceLifecycleEvent(event)
            }
        }
        FloeLogger(category: .app).info("linuxServiceLifecycleObservationStarted")
    }

    /// Test/diagnostic hook: cancels the observation. Never called by a view.
    func stopLinuxGuestServiceLifecycleObservation() {
        linuxServiceLifecycleTask?.cancel()
        linuxServiceLifecycleTask = nil
    }

    /// Locale-neutral service identity for surfaces: runtime name and the
    /// loopback port the service published. The pid is deliberately not
    /// user-facing.
    nonisolated static func linuxServiceDisplayName(
        for handle: LinuxGuestLocalServiceHandle
    ) -> String {
        let runtime = handle.runtime == .node ? "Node" : "Python"
        return "\(runtime) :\(handle.port)"
    }

    /// One observed end of a managed service. Explicit host stops return
    /// early (never a crash alert). An observed end is recorded and surfaced
    /// exactly once per service start token; the token is minted once per
    /// start, so the bounded dedupe set can never suppress a future service.
    /// The caller acknowledges the event only after this handler returned —
    /// i.e. after `linuxEnvironmentServiceDidFail` durably enqueued the
    /// terminal notification — so an unacknowledged end is replayed rather
    /// than lost, and a replay is idempotent through this dedupe set and the
    /// outbox's replace-by-identifier.
    private func linuxGuestServiceLifecycleObserved(
        _ event: LinuxGuestLocalServiceLifecycleEvent
    ) async {
        guard !event.reason.isExplicitHostStop else { return }
        // A managed service that ended because its environment vanished proves
        // the guest itself is gone. That is an observed guest end (not only a
        // service end), so drop the environment's background eligibility and
        // re-push the honest location answer now instead of waiting for the
        // next scene transition.
        if event.reason == .environmentGone {
            invalidateLocationLinuxAuthority(environmentID: event.handle.environmentID)
            reconcileLocationAssist()
        }
        let handle = event.handle
        let key = "\(handle.environmentID)#\(handle.token)"
        guard !surfacedLinuxServiceStops.contains(key) else { return }
        if surfacedLinuxServiceStops.count >= 128 {
            surfacedLinuxServiceStops.removeAll()
        }
        surfacedLinuxServiceStops.insert(key)
        let message = event.reason == .environmentGone
            ? String(localized: "background.linux.service_environment_gone_detail")
            : String(localized: "background.linux.service_unexpected_stop_detail")
        linuxEnvironmentServiceDidFail(
            environmentID: handle.environmentID,
            title: await linuxSurfaceTitle(environmentID: handle.environmentID),
            serviceName: Self.linuxServiceDisplayName(for: handle),
            message: message
        )
    }

    /// The user stopped the VM from the environment screen. The hold and the
    /// applied forwards are cleared and an honest suspended record is kept,
    /// but the durable per-environment preference is preserved so a later
    /// start restores background running.
    func linuxEnvironmentDidStop(environmentID: String, title: String) async {
        linuxBackgroundHold.environmentStopped(environmentID)
        invalidateLocationLinuxAuthority(environmentID: environmentID)
        await linuxPortCenter.clearEngineForwards(environmentID: environmentID)
        linuxPortCenter.guestStopped(environmentID: environmentID)
        linuxPortCounts.removeValue(forKey: environmentID)
        linuxCommandCounts.removeValue(forKey: environmentID)
        linuxTerminalCounts.removeValue(forKey: environmentID)
        linuxRuntimeStates.removeValue(forKey: environmentID)
        linuxSurfaceEntries.removeValue(forKey: environmentID)
        linuxUnverifiedMetricsReported.remove(environmentID)
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
            progressText: FloeL10n.l("platform.background_run_coordinator.the_environment_stopped_the_background_run"),
            deepLink: BackgroundWorkDeepLink(kind: .linuxSession, environmentID: environmentID)
        )
        await BackgroundWorkRegistry.shared.register(snapshot)
        FloeLogger(category: .app).info(
            "linuxEnvironmentStopped environment=\(environmentID) preferenceKept=true"
        )
    }

    /// A guest ended outside the coordinator: an engine stop from the
    /// environment card, a deleted environment, a heavy-runtime arbiter release
    /// or a crash. Those call sites are outside this file; they must invoke
    /// this only after the physical stop has resolved. The environment leaves
    /// background-location eligibility and the PiP hold immediately, its
    /// display cache is dropped and the honest "no work" answer is pushed; no
    /// durable work record or terminal notification is fabricated here because
    /// the owning stop path decides that.
    func linuxEnvironmentRuntimeEnded(environmentID: String) {
        invalidateLocationLinuxAuthority(environmentID: environmentID)
        linuxBackgroundHold.environmentStopped(environmentID)
        linuxSurfaceEntries.removeValue(forKey: environmentID)
        linuxUnverifiedMetricsReported.remove(environmentID)
        linuxCommandCounts.removeValue(forKey: environmentID)
        linuxPortCounts.removeValue(forKey: environmentID)
        linuxTerminalCounts.removeValue(forKey: environmentID)
        linuxRuntimeStates.removeValue(forKey: environmentID)
        linuxLastRuntimeSamples.removeValue(forKey: environmentID)
        stopLinuxMetricsSampling(environmentID: environmentID)
        publishLinuxSurfacePager()
    }

    /// One bounded surface sample per environment: metrics from the sampler,
    /// services from the supervisor, ports from the applied forward plans and
    /// commands from the bounded /proc probe. Runtime identity and the
    /// granted vCPU shape come from the runtime owner's session table
    /// (`runtimeStates()`), not from any surface's expectation.
    func refreshLinuxSurfaceEntries(environmentIDs: [String]) async {
        #if DEBUG
        // Coordinator-decision tests can interleave a stop with this awaited
        // refresh; shipping code never sets it.
        if let barrier = linuxSurfaceRefreshBarrierForTesting {
            await barrier()
        }
        #endif
        let serviceController = FloePlatformServices.shared.linuxLocalServiceController()
        let runner = FloePlatformServices.shared.linuxCommandRunner()
        let guestController = FloePlatformServices.shared.linuxGuestController()
        let guestService = environment.linuxGuestService
        var statesByEnvironment: [String: LinuxGuestRuntimeState] = [:]
        if let guestService {
            for state in await guestService.runtimeStates() {
                statesByEnvironment[state.environmentID] = state
            }
        }
        for environmentID in environmentIDs {
            // A VM that started while the app was already running must still
            // restore its persisted forwards; a hold reconcile is the moment
            // the app re-reads the live VM set.
            if linuxPortCenter.plans(environmentID: environmentID).isEmpty,
               linuxPortCenter.enabledRuleCount(environmentID: environmentID) > 0 {
                await linuxPortCenter.applyRules(environmentID: environmentID)
            }
            // Authoritative identity/shape for this environment: a session
            // the runtime still owns replaces the cached state; a runtime
            // without a session clears it so a stopped VM never keeps a
            // stale identity that would falsely pair with a new boot.
            let previousRuntimeState = linuxRuntimeStates[environmentID]
            if let state = statesByEnvironment[environmentID] {
                linuxRuntimeStates[environmentID] = state
            } else {
                linuxRuntimeStates.removeValue(forKey: environmentID)
            }
            // Managed interactive terminals: a real count when this runtime
            // owns the environment, unavailable otherwise.
            if let guestService, let terminals = await guestService.activeSessionCount(environmentID: environmentID) {
                linuxTerminalCounts[environmentID] = terminals
            } else {
                linuxTerminalCounts.removeValue(forKey: environmentID)
            }
            let existing = linuxSurfaceEntries[environmentID]
            let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
            let work = await BackgroundWorkRegistry.shared.snapshot(id: workID)
            // Configured RAM backs the total when the guest meminfo read has
            // not succeeded yet; the measured total wins once available.
            let configuredRAMMB = await guestController?
                .guestStatus(environmentID: environmentID).ramMB
            var entry = LinuxBackgroundSurfaceEntry(
                environmentID: environmentID,
                title: work?.title ?? existing?.title ?? FloeL10n.l("exec.linux.env_title"),
                state: work?.state ?? .running,
                emulatorCPUFraction: work?.metrics?.emulatorCPUFraction ?? existing?.emulatorCPUFraction,
                guestCPUFraction: work?.metrics?.guestCPUFraction ?? existing?.guestCPUFraction,
                memoryUsedMB: work?.metrics?.guestMemoryUsedMB ?? existing?.memoryUsedMB,
                memoryTotalMB: work?.metrics?.guestMemoryTotalMB
                    ?? existing?.memoryTotalMB ?? configuredRAMMB,
                activeCommandCount: linuxCommandCounts[environmentID] ?? existing?.activeCommandCount,
                // Unknown services stay unknown — never a fabricated zero.
                activeServiceCount: existing?.activeServiceCount,
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
                // The probe counts every runner-owned guest process. Without a
                // known service count the commands cannot be separated from
                // services, so the honest answer is unknown — never a count
                // that silently absorbs them.
                if let services = entry.activeServiceCount,
                   let owned = await LinuxGuestSurfaceProbe.runnerOwnedProcessCount(
                       runner: runner,
                       environmentID: environmentID
                   ) {
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
            // A restart rotates the runtime identity. Measured values (and the
            // last published sample) belong to the boot that produced them, so
            // they are cleared here: neither the surface entry nor the durable
            // work record may keep attaching the previous boot's numbers to
            // the new VM. The live snapshot projection enforces the same rule
            // independently; this keeps the durable projection honest too.
            if let previousRuntimeState, let state = statesByEnvironment[environmentID],
               LinuxGuestRuntimeIdentity.match(
                   sample: previousRuntimeState.identity, live: state.identity
               ) == .differentBoot {
                linuxLastRuntimeSamples.removeValue(forKey: environmentID)
                entry.emulatorCPUFraction = nil
                entry.guestCPUFraction = nil
                entry.memoryUsedMB = nil
                entry.memoryTotalMB = nil
                linuxSurfaceEntries[environmentID] = entry
                await publishLinuxSurfaceWork(environmentID: environmentID)
                FloeLogger(category: .app).info(
                    "linuxRuntimeGenerationRotated environment=\(environmentID) metricsCleared=true"
                )
            }
        }
        publishLinuxSurfacePager()
    }

    /// Keeps the pager's entry set in step with the held VMs and updates an
    /// already-visible surface without reopening it.
    private func publishLinuxSurfacePager() {
        linuxSurfacePager.reconcile(
            with: linuxBackgroundHold.heldEnvironmentIDs.compactMap { linuxSurfaceEntries[$0] }
        )
        // A VM stop/removal publishes here; the last real guest work ending
        // must clear the location assist immediately instead of relying on a
        // later unrelated transition.
        reconcileLocationAssist()
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
                progressText: FloeL10n.l("platform.background_run_coordinator.keep_running_in_background"),
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
        // Only measured counts are written. The shared work record cannot
        // represent "unknown", so an unavailable count leaves the record's
        // previous value instead of overwriting it with a fabricated zero.
        if let commands = entry.activeCommandCount { snapshot.activeCommandCount = commands }
        if let services = entry.activeServiceCount { snapshot.activeServiceCount = services }
        if let ports = entry.portForwardCount { snapshot.portForwardCount = ports }
        snapshot.progressText = entry.caption()
        await BackgroundWorkRegistry.shared.register(snapshot)
    }

    /// Snapshot for diagnostics/tests: the current page and every entry.
    func linuxBackgroundSurfaceSnapshot() -> (entries: [LinuxBackgroundSurfaceEntry], pager: LinuxBackgroundSurfacePager) {
        (linuxSurfacePager.entries, linuxSurfacePager)
    }

    /// The unified runtime snapshot for one held environment, when known.
    /// Freshness is evaluated at call time so every consumer sees the same
    /// "暂无" decision for an aged sample.
    func linuxEnvironmentRuntimeSnapshot(
        environmentID: String,
        now: Date = Date()
    ) -> LinuxEnvironmentRuntimeSnapshot? {
        guard let entry = linuxSurfaceEntries[environmentID] else { return nil }
        return makeLinuxEnvironmentRuntimeSnapshot(
            environmentID: environmentID,
            entry: entry,
            runtimeState: linuxRuntimeStates[environmentID],
            now: now
        )
    }

    /// Snapshots for the requested environment ids, in stable id order. The
    /// default is every environment the coordinator currently tracks (the
    /// background-held subset). For the authoritative *all running* list use
    /// `linuxRunningEnvironmentRuntimeSnapshots()`, which enumerates the
    /// runtime owner's own sessions instead of this tracker.
    func linuxEnvironmentRuntimeSnapshots(
        environmentIDs: [String]? = nil,
        now: Date = Date()
    ) -> [LinuxEnvironmentRuntimeSnapshot] {
        let ids = environmentIDs ?? linuxSurfaceEntries.keys.sorted()
        return ids.compactMap {
            linuxEnvironmentRuntimeSnapshot(environmentID: $0, now: now)
        }
    }

    /// Every environment the runtime owner currently reports as running, in
    /// stable id order. This is the authoritative list for surfaces that must
    /// show all VMs: it comes from `runtimeStates()` (the registry's own
    /// session table), never from conversations, background holds, work
    /// records or the coordinator's expected subset. Identity, granted vCPU
    /// shape and start time come from the same state; counts and metrics stay
    /// whatever has really been measured (unknown renders "暂无").
    func linuxRunningEnvironmentRuntimeSnapshots(
        now: Date = Date()
    ) async -> [LinuxEnvironmentRuntimeSnapshot] {
        guard let guestService = environment.linuxGuestService else { return [] }
        var snapshots: [LinuxEnvironmentRuntimeSnapshot] = []
        for state in await guestService.runtimeStates() where state.running {
            linuxRuntimeStates[state.environmentID] = state
            let entry: LinuxBackgroundSurfaceEntry
            if let existing = linuxSurfaceEntries[state.environmentID] {
                entry = existing
            } else {
                entry = LinuxBackgroundSurfaceEntry(
                    environmentID: state.environmentID,
                    title: await linuxSurfaceTitle(environmentID: state.environmentID),
                    state: .running,
                    startedAt: state.startedAt
                )
            }
            snapshots.append(
                makeLinuxEnvironmentRuntimeSnapshot(
                    environmentID: state.environmentID,
                    entry: entry,
                    runtimeState: state,
                    now: now
                )
            )
        }
        return snapshots.sorted { $0.environmentID < $1.environmentID }
    }

    /// Human-facing title for an environment the coordinator has no surface
    /// entry for: the durable work record's title when one exists, else the
    /// neutral fallback — never a conversation or task name.
    private func linuxSurfaceTitle(environmentID: String) async -> String {
        if let title = linuxSurfaceEntries[environmentID]?.title { return title }
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        if let title = await BackgroundWorkRegistry.shared.snapshot(id: workID)?.title {
            return title
        }
        return FloeL10n.l("exec.linux.env_title")
    }

    /// Single assembly point for the unified snapshot. Measured values come
    /// from the shared production projection: a sample may only contribute
    /// when its runtime identity proves it belongs to the live boot
    /// (`LinuxGuestRuntimeMetricsProjection.resolve`). Without such a sample
    /// the live runtime state supplies the identity while every measured
    /// value renders unknown — a delayed sample from a previous boot is never
    /// shown under a newer boot's identity, and an unknown identity never
    /// yields fabricated numbers (nil renders "暂无", never 0).
    private func makeLinuxEnvironmentRuntimeSnapshot(
        environmentID: String,
        entry: LinuxBackgroundSurfaceEntry,
        runtimeState: LinuxGuestRuntimeState?,
        now: Date
    ) -> LinuxEnvironmentRuntimeSnapshot {
        let projection = LinuxGuestRuntimeMetricsProjection.resolve(
            sample: linuxLastRuntimeSamples[environmentID],
            liveIdentity: runtimeState?.identity ?? LinuxGuestRuntimeIdentity(),
            now: now,
            validity: Self.linuxMetricsSampleValidity
        )
        return LinuxEnvironmentRuntimeSnapshot(
            environmentID: environmentID,
            title: entry.title,
            state: entry.state,
            startedAt: entry.startedAt ?? runtimeState?.startedAt,
            kernelVersion: projection.kernelVersion,
            coreCount: projection.coreCount,
            allocatedVCPUs: runtimeState?.vcpus,
            memoryUsedMB: projection.guestMemoryUsedMB,
            memoryTotalMB: projection.guestMemoryTotalMB,
            ramConfiguredMB: runtimeState?.ramMB ?? entry.memoryTotalMB,
            commandCount: entry.activeCommandCount,
            terminalCount: linuxTerminalCounts[environmentID],
            serviceCount: entry.activeServiceCount,
            portCount: entry.portForwardCount,
            guestCPUFraction: projection.guestCPUFraction,
            hostThreadCPUFraction: projection.hostThreadCPUFraction,
            sampledAt: projection.sampledAt,
            sampleIsFresh: projection.sampleIsFresh,
            runtimeID: projection.identity.runtimeID,
            launchGeneration: projection.identity.launchGeneration
        )
    }

    /// One Linux page for the floating surface, built from the unified
    /// snapshot so the PiP, settings and notifications read one truth. The
    /// small frame stays readable: title, state and a short stable VM
    /// identity first, then CPU and memory, then the command/service/port
    /// counts. Kernel version and elapsed time are environment-detail
    /// material for the settings surface, not the PiP. Guest CPU and
    /// host-thread occupancy are always separate labelled values; anything
    /// unknown or stale renders "暂无".
    nonisolated static func linuxSurfacePageText(
        for snapshot: LinuxEnvironmentRuntimeSnapshot,
        now: Date = Date()
    ) -> String {
        func countText(_ value: Int?) -> String {
            value.map(String.init) ?? String(localized: "background.value.unavailable")
        }
        func percentText(_ value: Double?) -> String {
            guard let value else { return String(localized: "background.value.unavailable") }
            return String(format: "%.0f%%", value * 100)
        }
        // Short, stable VM identity: the runtime token when the lease
        // exposes one, else the environment id — never a full uuid.
        let identitySource = snapshot.runtimeID ?? snapshot.environmentID
        let shortIdentity = identitySource.prefix(6)
        var lines: [String] = []
        lines.append(
            "\(snapshot.title) · \(snapshot.state.surfaceLabel)"
                + " · VM \(shortIdentity)"
        )
        lines.append(
            String(
                format: String(localized: "background.pip.cpu_guest"),
                percentText(snapshot.guestCPUFraction)
            )
                + " · " + String(
                    format: String(localized: "background.pip.host_thread"),
                    percentText(snapshot.hostThreadCPUFraction)
                )
                + " · " + (snapshot.coreCount.map {
                    String(format: String(localized: "background.pip.cores"), $0)
                } ?? String(localized: "background.value.unavailable"))
        )
        let memory: String
        if let used = snapshot.memoryUsedMB, let total = snapshot.memoryTotalMB {
            memory = "\(used)/\(total) MB"
        } else {
            memory = String(localized: "background.value.unavailable")
        }
        lines.append(String(format: String(localized: "background.pip.memory"), memory))
        lines.append(
            String(
                format: String(localized: "background.pip.commands"),
                countText(snapshot.commandCount)
            )
                + " · " + String(
                    format: String(localized: "background.pip.terminals"),
                    countText(snapshot.terminalCount)
                )
                + " · " + String(
                    format: String(localized: "background.pip.services"),
                    countText(snapshot.serviceCount)
                )
                + " · " + String(
                    format: String(localized: "background.pip.ports"),
                    countText(snapshot.portCount)
                )
        )
        return lines.joined(separator: "\n")
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
            },
            // Authoritative identity from the runtime owner's own session
            // table: the Runtime v2 runtimeID plus the registry's per-start
            // launch generation. A restart therefore changes the identity
            // and resets the sampler's delta baselines instead of pairing
            // two boots; unknown stays nil, never a locally invented value.
            runtimeIdentityProvider: { id in
                await service.runtimeIdentity(environmentID: id)
            }
        )
        linuxMetricsSamplers[environmentID] = sampler
        let workID = BackgroundWorkSnapshot.stableID(for: environmentID)
        linuxMetricsTasks[environmentID] = Task { [weak self] in
            for await sample in await sampler.runtimeSamples() {
                guard !Task.isCancelled else { return }
                await self?.applyLinuxMetrics(sample, workID: workID)
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

    /// Applies one sampler result. The live runtime state is re-read first:
    /// a sample whose runtime identity does not prove it belongs to the live
    /// boot (a delayed in-flight read that crossed a restart, or one taken
    /// when the runtime had no verifiable identity) is discarded entirely —
    /// it must not overwrite the new boot's metrics, identity or durable work
    /// record, and it is dropped from the last-sample cache so the snapshot
    /// projection cannot pick it up either.
    private func applyLinuxMetrics(_ sample: LinuxGuestRuntimeSample, workID: UUID) async {
        guard let existing = await BackgroundWorkRegistry.shared.snapshot(id: workID) else { return }
        guard let environmentID = existing.deepLink.environmentID else { return }
        var liveState: LinuxGuestRuntimeState?
        if let guestService = environment.linuxGuestService {
            liveState = await guestService.runtimeStates().first {
                $0.environmentID == environmentID
            }
        }
        let liveIdentity = liveState?.identity ?? LinuxGuestRuntimeIdentity()
        guard LinuxGuestRuntimeIdentity.match(sample: sample.runtimeIdentity, live: liveIdentity) == .sameBoot else {
            if let cached = linuxLastRuntimeSamples[environmentID],
               LinuxGuestRuntimeIdentity.match(sample: cached.runtimeIdentity, live: liveIdentity) != .sameBoot {
                linuxLastRuntimeSamples.removeValue(forKey: environmentID)
            }
            if linuxUnverifiedMetricsReported.insert(environmentID).inserted {
                FloeLogger(category: .app).info(
                    "linuxMetricsSampleDiscarded environment=\(environmentID) reason=runtimeIdentityUnverified"
                )
            }
            return
        }
        linuxUnverifiedMetricsReported.remove(environmentID)
        if let liveState {
            // Keep the cached live state (identity + granted shape) in step
            // with the sample that was just proven to belong to it, so the
            // snapshot never pairs a rotated sample with an ageing identity.
            linuxRuntimeStates[environmentID] = liveState
        }
        var snapshot = existing
        snapshot.metrics = sample.metrics
        await BackgroundWorkRegistry.shared.register(snapshot)
        // The unified sample is the single source of truth; a failed guest
        // read keeps the last identity values but its freshness gate expires.
        linuxLastRuntimeSamples[environmentID] = sample
        var entry = linuxSurfaceEntries[environmentID] ?? LinuxBackgroundSurfaceEntry(
            environmentID: environmentID,
            title: existing.title,
            startedAt: existing.startedAt
        )
        if sample.guestReadSucceeded {
            entry.emulatorCPUFraction = sample.emulatorCPUFraction ?? entry.emulatorCPUFraction
            entry.guestCPUFraction = sample.guestCPUFraction ?? entry.guestCPUFraction
            entry.memoryUsedMB = sample.guestMemoryUsedMB ?? entry.memoryUsedMB
            entry.memoryTotalMB = sample.guestMemoryTotalMB ?? entry.memoryTotalMB
        }
        entry.updatedAt = sample.sampledAt
        linuxSurfaceEntries[environmentID] = entry
        publishLinuxSurfacePager()
        // Refresh the visible frame only when no carousel owns it and the
        // currently surfaced page is this environment's. Rendering goes
        // through the same unified page builder, so a metric tick updates the
        // numbers without changing which page is shown.
        if isAppInBackground, surfacedRunID == workID, pipCarouselTask == nil,
           let snapshot = linuxEnvironmentRuntimeSnapshot(environmentID: environmentID) {
            environment.backgroundVideoService.update(
                title: entry.title,
                progress: Self.linuxSurfacePageText(for: snapshot)
            )
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
            // The physical stop starts in the Task below; fence the id now so a
            // read cannot re-add it in between.
            beginLocationLinuxStop(environmentID: environmentID)
            linuxSurfaceEntries.removeValue(forKey: environmentID)
            linuxUnverifiedMetricsReported.remove(environmentID)
            linuxCommandCounts.removeValue(forKey: environmentID)
            linuxPortCounts.removeValue(forKey: environmentID)
            publishLinuxSurfacePager()
            Task { [weak self] in
                await self?.stopAndFlushLinuxEnvironment(
                    environmentID: environmentID,
                    reason: String(localized: "background.linux.stop_reason.pip_closed")
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

    /// Applies the user's independent background capabilities when a run
    /// starts. Enhanced processing relies on the 30s lease + continued task
    /// (requested separately, no extra UI); the PiP capability exposes real
    /// task-progress content from the existing task/canvas toolbar and lets
    /// AVKit automatically enter when the user leaves the inline player,
    /// while scene transitions never call `start`. Screen feedback
    /// additionally asks the matching thread to present ReplayKit's system
    /// consent flow — this run-start path is that explicit user action; a
    /// settings toggle never requests consent.
    private func applyBackgroundExecutionPreference(
        runID: UUID,
        conversationID: UUID?,
        runTitle: String
    ) {
        let options = effectiveBackgroundExecutionOptions
        guard visualSurfacePolicy.allowsVisualSurface(
            for: options.legacyPreference
        ) else {
            if !options.pictureInPictureEnabled, !linuxBackgroundHold.hasActiveHold {
                // Mode changes can happen while a failed run's visual surface
                // is retained. A PiP-off configuration owns only its
                // continued task and must not inherit an earlier PiP
                // controller or broadcast — but a held Linux VM keeps its
                // own prepared surface.
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
        // Reaching this point means the PiP capability is enabled (screen
        // feedback implies PiP through the Core model).
        surfacedRunID = runID
        if options.screenFeedbackEnabled {
            FloeLogger(category: .app).info(
                "backgroundSurfaceRequested run=\(runID.uuidString) mode=screenFeedback sharing=\(environment.screenShareCenter.isSharing)"
            )
            environment.backgroundVideoService.setRunContext(
                title: runTitle,
                progress: environment.screenShareCenter.isSharing
                    ? FloeL10n.l("platform.background_run_coordinator.sharing_screen")
                    : FloeL10n.l("platform.background_run_coordinator.task_is_running"),
                // Screen feedback runs CONCURRENTLY with automatic PiP
                // arming; it never downgrades PiP to manual-only.
                automaticallyStartsFromInline: Self.shouldArmAutomaticInlineStart(for: options)
            )
            guard let conversationID else {
                FloeLogger(category: .app).info(
                    "backgroundSurfaceScreenShareSkipped run=\(runID.uuidString) reason=canvasMediaHasNoConversationForScreenShare"
                )
                return
            }
            if !environment.screenShareCenter.isSharing {
                environment.screenShareCenter.requestBroadcast(for: conversationID)
            }
        } else {
            FloeLogger(category: .app).info(
                "backgroundSurfaceRequested run=\(runID.uuidString) mode=pictureInPicture"
            )
            environment.backgroundVideoService.setRunContext(
                title: runTitle,
                progress: FloeL10n.l("platform.background_run_coordinator.running"),
                automaticallyStartsFromInline: true
            )
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
            guard let snapshot = linuxEnvironmentRuntimeSnapshot(environmentID: environmentID)
            else { continue }
            items.append(SurfaceCarouselItem(
                id: BackgroundWorkSnapshot.stableID(for: environmentID),
                title: snapshot.title,
                text: Self.linuxSurfacePageText(for: snapshot)
            ))
        }
        return items
    }

    /// Keep a multi-task/multi-VM PiP useful without cramming several
    /// unreadable rows into a phone-sized video. Items rotate in stable order
    /// every four seconds (a single page keeps a one-second heartbeat); the
    /// cursor follows the item identity so an item set that shrinks or grows
    /// never jumps the user to an arbitrary page.
    private func startPiPCarousel() {
        guard pipCarouselTask == nil else { return }
        pipCarouselTask = Task { [weak self] in
            // Whatever makes the loop exit — foreground return, an empty item
            // set or external cancellation — the stored handle must be
            // cleared so a later background transition rebuilds the carousel.
            // A stale non-nil handle used to freeze the pager on the last
            // rendered page (device report: "2/2" forever, no rotation).
            defer {
                self?.pipCarouselTask = nil
            }
            var currentItemID: UUID? = nil
            var lastIndex = 0
            while !Task.isCancelled {
                guard let self, self.isAppInBackground else { return }
                let candidates = self.surfaceCarouselItems()
                guard !candidates.isEmpty else { return }
                let index: Int
                if let currentItemID,
                   let existing = candidates.firstIndex(where: { $0.id == currentItemID }) {
                    index = (existing + 1) % candidates.count
                } else {
                    // The page we showed has gone (finished run, stopped VM):
                    // land on the same numeric slot when possible instead of
                    // restarting from an arbitrary position.
                    index = min(lastIndex, candidates.count - 1)
                }
                let item = candidates[index]
                currentItemID = item.id
                lastIndex = index
                self.surfacedRunID = item.id
                let prefix = candidates.count > 1
                    ? "\(index + 1)/\(candidates.count) · " : ""
                self.environment.backgroundVideoService.update(
                    title: item.title,
                    progress: "\(prefix)\(item.text)"
                )
                try? await Task.sleep(for: .seconds(candidates.count > 1 ? 4 : 1))
            }
        }
    }

    func didRequireApproval(conversationID: UUID, runID: UUID, toolName: String) {
        // Temporary (ephemeral) runs never publish approval notifications:
        // the durable outbox and any system task must not carry their
        // content. The in-app approval UI still surfaces the request.
        guard activeRuns[runID]?.publishesContent != false else { return }
        guard notifiedApprovalRuns.insert(runID).inserted else { return }
        // Typed attention event for the PiP sound surface (generic wording,
        // deduped and throttled inside the audio service).
        environment.pipAudioService.handleTaskEvent(.needsInput, runID: runID)
        if #available(iOS 26.0, *),
           activeRuns[runID]?.continuedProcessingOrigin.allowsContinuedSubmission == true {
            updateContinuedTask(title: "Floe Agent", stage: FloeL10n.l("platform.background_run_coordinator.waiting_for_your_approval"), progress: 60)
        }
        if surfacedRunID == runID {
            environment.backgroundVideoService.update(progress: FloeL10n.l("platform.background_run_coordinator.waiting_for_your_approval"))
        }
        reconcileTaskLiveActivity(reason: "approvalRequired")
        // The central needsInput surface: once the request is published (the
        // per-run dedupe guard above passed), a live work session re-reads
        // its real counts immediately so counts/waitReason flip to
        // "awaiting approval" without a Home manual pull. Non-live records
        // are untouched; this never writes to the conversation center.
        Task { [weak self] in await self?.workSession.refreshIfLive() }
        let taskName = activeRuns[runID]?.title ?? String(localized: "background.task.name_fallback")
        Task { [weak self] in
            guard let self else { return }
            let policy = try? await SQLiteWorkspaceStore(database: self.environment.database)
                .taskPolicy(conversationID: conversationID)
            self.enqueueTerminalNotification(
                event: .modelRunTerminal(
                    runID: runID,
                    conversationID: conversationID,
                    taskName: taskName,
                    kind: .actionRequired,
                    body: Self.terminalEventBody(
                        kind: .actionRequired,
                        resultMessage: String(
                            format: String(localized: "background.approval.result"),
                            toolName
                        ),
                        fallbackBody: String(localized: "background.approval.body")
                    )
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
            for: effectiveBackgroundExecutionOptions,
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
            task.updateTitle("Floe Agent", subtitle: FloeL10n.l("platform.background_run_coordinator.resuming_task_in_background"))
            // REAL framework acceptance: the work session's qualification
            // display flips only here, never at submission time. The
            // controller fences late/stale acceptances itself.
            workSession.handleQualificationAccepted()
        }
    }

    @available(iOS 26.0, *)
    private func updateContinuedTask(title: String, stage: String, progress: Int64) {
        guard Self.shouldKeepContinuedProcessing(
            for: environment.settingsCenter.backgroundExecutionOptions,
            launchPreferencesLoaded:
                environment.settingsCenter.launchPreferencesLoaded
        ) else {
            // Every update site shares this last-line gate. A stale callback
            // from progress/suspension/approval therefore cannot resurrect or
            // keep updating a Live Activity after the user turned enhanced
            // background processing off.
            finishContinuedTasks(success: true)
            if Date().timeIntervalSince(lastSkippedContinuedUpdateAt) >= 60 {
                lastSkippedContinuedUpdateAt = Date()
                FloeLogger(category: .app).debug(
                    "continuedProcessingUpdateSkipped reason=enhancedBackgroundOff enhanced=\(environment.settingsCenter.backgroundExecutionOptions.enhancedBackgroundEnabled)"
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
        // The shared continued task is the session's real qualification: any
        // finish (explicit release, expiration, preference-off) returns the
        // session's displayed state to truth. Idempotent and seam-free, so
        // this cannot recurse into the release path.
        workSession.handleQualificationLost()
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
        let effective = Self.aggregateScenePhase(scenePhases)
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
        reconcileLocationAssist()
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
                // A previous process may have left an activity behind; end it
                // and reflect only work this process can prove is running.
                self.reconcileTaskLiveActivityForForeground()
                // The authorization answer may have arrived while the app was
                // away: flush anything the first-authorization race queued.
                await self.refreshNotificationAuthorizationAndFlush()
                // A notification tap that launched the app routes only now,
                // once the database and this scene are both ready.
                self.flushPendingNotificationRoute()
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

    // MARK: - Ordinary-task Live Activity (independent)

    /// The single owner of the ordinary-task Live Activity. Created on first
    /// use, so a launch that never runs a task touches no ActivityKit state.
    private var taskLiveActivities: TaskLiveActivityCoordinator?

    private func taskLiveActivityCoordinator() -> TaskLiveActivityCoordinator {
        if let existing = taskLiveActivities { return existing }
        let coordinator = TaskLiveActivityCoordinator(
            snapshotProvider: { [weak self] _ in
                guard let self else { return .empty }
                return TaskLiveActivityProjection.snapshot(
                    from: self.taskLiveActivityCandidates()
                )
            },
            isEnabledProvider: { [weak self] in
                self?.environment.settingsCenter.backgroundExecutionOptions
                    .taskLiveActivityEnabled ?? false
            },
            logger: { message in
                FloeLogger(category: .app).debug(message)
            }
        )
        taskLiveActivities = coordinator
        return coordinator
    }

    /// Marks the real run state dirty for the Live Activity owner. The owner
    /// coalesces passes, so repeated lifecycle events never stack work. This
    /// is deliberately not called from the per-token activity callback.
    private func reconcileTaskLiveActivity(reason: String) {
        taskLiveActivityCoordinator().noteTasksChanged(reason: reason)
    }

    private func reconcileTaskLiveActivityForForeground() {
        taskLiveActivityCoordinator().reconcileForForeground()
    }

    /// Only runs that own an ordinary conversation and may publish content
    /// qualify: temporary sessions and route-less media work never reach a
    /// Lock Screen.
    private func taskLiveActivityCandidates() -> [TaskLiveActivityProjection.Candidate] {
        activeRuns.map { runID, run in
            TaskLiveActivityProjection.Candidate(
                runID: runID,
                conversationID: run.conversationID,
                title: run.title,
                stage: run.stage,
                pendingApprovalToolName: run.pendingApprovalToolName,
                isAwaitingUserAttention: run.isAwaitingUserAttention,
                startedAt: run.startedAt,
                publishesContent: run.publishesContent
            )
        }
    }

    /// Standalone audio ownership: with the honored audio capability, the
    /// REAL run batch owns the service-managed ambient/task-speech session;
    /// no PiP view is involved, and no settings change alone can start or
    /// stop it. Temporary (ephemeral) chat runs never own task audio. The
    /// PiP surface, when present, is the service's other owner input; the
    /// service OR-merges them into one generation-guarded owner.
    private func reconcileStandaloneAudioOwner() {
        let honored = effectiveBackgroundExecutionOptions
        let hasOwnedTaskWork = activeRuns.values.contains { run in
            run.publishesContent
        }
        environment.pipAudioService.handleStandaloneAudioOwnerChanged(
            honored.audioEnabled && hasOwnedTaskWork
        )
    }

    // MARK: - Work session seams (real stores only; no second machinery)

    /// The exact durable facts behind every session display. These are the
    /// SAME stores the background passes use: live runs from the coordinator
    /// itself, jobs from `BackgroundJobStore.activeJobs()`, schedule rows
    /// from `SQLiteTaskScheduleStore` (whose occurrences the due pass
    /// claims ATOMICALLY — the session never claims anything itself, so the
    /// existing env-claim/permission machinery dedupes every wake against
    /// every other executor by construction).
    /// A failed store read THROWS: unknown must stay distinct from empty, so
    /// a DB failure can never fabricate a drained queue, fake a progress
    /// ratio or release a real qualification. The controller preserves the
    /// last valid counts and defers until the next confirmed read.
    private func workSessionCounts() async throws -> BackgroundWorkSessionCounts {
        let runs = Array(activeRuns.values)
        let liveRuns = runs.filter { run in
            run.publishesContent
                && run.pendingApprovalToolName == nil
                && !run.isAwaitingUserAttention
        }.count
        let pendingApprovals = runs.filter { run in
            run.pendingApprovalToolName != nil || run.isAwaitingUserAttention
        }.count
        let jobStore = BackgroundJobStore(database: environment.database)
        let activeJobs = try await checkedCountsRead("activeJobs") {
            try await jobStore.activeJobs()
        }
        let runningJobs = activeJobs.filter { $0.state == .running }.count
        let queuedJobs = activeJobs.filter { $0.state == .queued }.count
        let scheduleStore = SQLiteTaskScheduleStore(database: environment.database)
        let schedules = try await checkedCountsRead("schedules") {
            try await scheduleStore.schedules()
        }
        let enabledSchedules = schedules.filter(\.isEnabled).count
        let recent = try await checkedCountsRead("recentOccurrences") {
            try await scheduleStore.recentOccurrences(limit: 200)
        }
        let claimedOccurrences = recent.filter {
            $0.state == .claimed || $0.state == .running
        }.count
        return BackgroundWorkSessionCounts(
            liveRuns: liveRuns,
            pendingApprovals: pendingApprovals,
            runningJobs: runningJobs,
            queuedJobs: queuedJobs,
            claimedScheduleOccurrences: claimedOccurrences,
            enabledSchedules: enabledSchedules,
            heldEnvironmentClaims: linuxBackgroundHold.heldEnvironmentIDs.count
        )
    }

    /// One counts-store read: any failure is logged and surfaced as the
    /// shared unknown-facts error (never silently substituted with zeros).
    private func checkedCountsRead<T>(
        _ component: String,
        _ read: () async throws -> T
    ) async throws -> T {
        do {
            return try await read()
        } catch {
            FloeLogger(category: .persistence).info(
                "workSessionCountsReadFailed component=\(component) detail=\(String(describing: type(of: error)))"
            )
            throw BackgroundWorkSessionCountsUnknownError(component: component)
        }
    }

    /// Persist the session record and re-push the shared ownership facts.
    /// The background-location release itself is decided by the shared
    /// location service from the real task/server/accepted-work inputs: this
    /// only guarantees it re-evaluates the moment the session's claim
    /// changes (including a stop leaving no other owner).
    private func workSessionOwnershipChanged(_ snapshot: BackgroundWorkSessionSnapshot) async {
        do {
            try await environment.settingsCenter.saveBackgroundWorkSession(snapshot)
        } catch {
            // Honest persistence failure: the surface still shows the live
            // facts, but the wake-restore record is knowingly absent.
            FloeLogger(category: .persistence).warning(
                "workSessionSnapshotPersistFailed state=\(snapshot.state.rawValue)"
            )
        }
        reconcileLocationAssist()
        reconcileStandaloneAudioOwner()
        reconcileTaskLiveActivity(reason: "workSessionChanged")
    }

    /// Restore the session record after ANY launch/wake. Metadata only:
    /// running/waiting become interrupted, and no continued background
    /// execution is reacquired — `mayAutoAcquireContinuedBackground` is the
    /// fail-closed answer for every wake kind. The existing finite passes
    /// (`runDueSchedules` inside the refresh task, the media/claim
    /// reconciliation) continue to run under their own machinery; the
    /// session merely reports what actually happened.
    private func restoreWorkSession(afterWake wake: BackgroundWorkWakeKind) async {
        let persisted = await environment.settingsCenter.loadBackgroundWorkSession()
        if let persisted {
            await workSession.restoreFromPersistence(
                persisted: persisted, afterWake: wake)
        }
        await workSession.refresh()
    }

    /// Bounded download-wake bootstrap. Main wires it through the facade's
    /// ATOMIC `register(_:bootstrap:)` in
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// so the bootstrap is a tracked settlement event: the stored system
    /// completion cannot fire before it drains, and it is NEVER an
    /// untracked Task spawned after register.
    ///
    /// Cold-wake readiness follows Main's 2026-10-27 contract: FIRST invoke
    /// `AppEnvironment.startBackgroundDownloadInitialization()` — Main's
    /// service-owned single-flight task running the EXISTING
    /// `ensureReadyForExternalAutomation` (bootstrap + run recovery +
    /// center reload + provider/model configuration; it never starts the
    /// agent itself and never creates a second graph) — then bounded-wait
    /// (≤5s) on the read-only `backgroundDownloadAutomationReady` flag
    /// (externalAutomationReady && launchPrefsLoaded && durableReady).
    /// Polling only `launchPreferencesLoaded` is NOT sufficient:
    /// `runDueSchedules` → `executeScheduleOccurrence` reads
    /// `conversationCenter.providerAndModel`/model preferences, so a due
    /// occurrence could otherwise be permanently failed as
    /// `modelUnavailable` before the center reload lands.
    ///
    /// Deadline behavior is FAIL-CLOSED DEFER: no metadata claim, no due
    /// pass, no occurrence failed from uninitialized configuration; the
    /// shared initialization keeps running for its foreground caller, and
    /// the next wake/foreground launch picks due work up through the same
    /// existing atomic-claim path. No continued-processing qualification
    /// is ever minted from a wake (`mayAutoAcquireContinuedBackground` is
    /// false for every wake kind).
    ///
    /// Contract signatures expected on AppEnvironment (Main-owned, landing
    /// in the same batch): `func startBackgroundDownloadInitialization()`
    /// (synchronous kickoff of the service-owned single-flight task) and
    /// `var backgroundDownloadAutomationReady: Bool { get }`.
    func runDownloadWakeBootstrap() async {
        environment.startBackgroundDownloadInitialization()
        let ready = await waitForBackgroundDownloadAutomationReady(deadlineSeconds: 5)
        guard ready else {
            FloeLogger(category: .app).warning(
                "downloadWakeBootstrapDeferred reason=automationReadyDeadline persistenceReady=\(environment.persistenceReady) prefsLoaded=\(environment.settingsCenter.launchPreferencesLoaded)"
            )
            return
        }
        // Ready: restore the session metadata honestly (interrupted/armed —
        // never start authority), then run ONE finite existing due pass.
        await restoreWorkSession(afterWake: .downloadRelaunch)
        await runDueSchedulesNow()
    }

    /// Bounded wait on Main's read-only cold-wake readiness flag. Polls the
    /// flag only — it never awaits the shared initialization task itself,
    /// so the foreground caller keeps that task's lifecycle and the wake
    /// can neither extend nor cancel it.
    private func waitForBackgroundDownloadAutomationReady(deadlineSeconds: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while !environment.backgroundDownloadAutomationReady, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return environment.backgroundDownloadAutomationReady
    }

    /// Every lifecycle transition that can change local work, background
    /// support or the aggregate scene phase pushes the same three facts to the
    /// shared location service. The service owns the actual session/update
    /// lifecycle and never infers work from stage text or run counts. Linux
    /// eligibility comes from the last authoritative runtime read, never from
    /// the display cache or the durable permission alone.
    private func reconcileLocationAssist() {
        let inputs = Self.backgroundLocationInputs(
            options: environment.settingsCenter.backgroundExecutionOptions,
            statusPiPEnabled: StatusPiPReleaseGate.isEnabled,
            runs: Array(activeRuns.values),
            enabledLinuxEnvironmentIDs: linuxBackgroundEnabledEnvironmentIDs(),
            heldLinuxEnvironmentIDs: linuxBackgroundHold.heldEnvironmentIDs,
            runningLinuxEnvironmentIDs: locationLiveLinuxEnvironmentIDs.sorted(),
            aggregateScenePhase: effectiveScenePhase
        )
        LocationServicesCenter.shared.applyBackgroundLocationInputs(
            supportEnabled: inputs.supportEnabled,
            workEligible: inputs.workEligible,
            fullyBackgroundScene: inputs.fullyBackgroundScene
        )
    }

    private func hasLocationEligibleWork() -> Bool {
        let eligibleLinux = Self.locationEligibleLinuxEnvironmentIDs(
            heldEnvironmentIDs: linuxBackgroundHold.heldEnvironmentIDs,
            runningEnvironmentIDs: locationLiveLinuxEnvironmentIDs.sorted(),
            enabledEnvironmentIDs: linuxBackgroundEnabledEnvironmentIDs()
        )
        return Self.hasLocationEligibleWork(
            runs: Array(activeRuns.values),
            heldLinuxEnvironmentIDs: eligibleLinux.held,
            runningLinuxEnvironmentIDs: eligibleLinux.running
        )
    }

    #if DEBUG
    /// Focused regressions assert the ACTUAL eligibility decision without
    /// starting a location session or synthesizing scene side effects.
    var locationAssistWorkEligibleForTesting: Bool { hasLocationEligibleWork() }

    /// Runs the same reconciliation the lifecycle paths run, after a test has
    /// swapped in a controlled-driver service.
    func reconcileLocationAssistForTesting() { reconcileLocationAssist() }

    /// Controlled live-guest truth for coordinator-decision tests: it replaces
    /// only the runtime probe, returning the eligible subset of the enabled
    /// environments. Shipping code never sets it, so the runtime owner remains
    /// the sole authority in the app.
    var linuxLiveGuestEnvironmentIDsOverrideForTesting: (@MainActor ([String]) async -> [String])?

    /// Coordinator-decision tests pause the awaited surface refresh here to
    /// prove a stop that lands during it is not applied afterwards. Shipping
    /// code never sets it.
    var linuxSurfaceRefreshBarrierForTesting: (@MainActor () async -> Void)?

    // MARK: BGAppRefresh wake seams — MOCKED-FLOW only.
    // These drive/record the REAL fenced refresh sequence (`startRefresh-
    // Generation` → `performRefreshWork` → `finishRefreshGeneration`) so the
    // readiness defer, generation fences and at-most-once completion are
    // behavior-testable in-process. They do NOT prove the real OS layer:
    // actual BGAppRefreshTask delivery, expiration firing and
    // `setTaskCompleted` remain device/simulator-only Main acceptance.
    // Shipping code never sets any of them.

    /// Replaces the readiness step (kickoff + ≤5s bounded wait) with a
    /// controllable gate.
    var refreshReadinessForTesting: (@MainActor () async -> Bool)?

    /// Records every step the fenced body actually runs for a generation:
    /// `restore` / `maintenance` / `dueScan` / `deferred:*`.
    var refreshWakeStepsForTesting: (@MainActor (_ taskID: UUID, _ step: String) -> Void)?

    /// Replaces `setTaskCompleted` on the generation's own task handle.
    var refreshCompletionsForTesting: (@MainActor (_ taskID: UUID, _ success: Bool) -> Void)?

    /// Readback: the refresh generation currently owning the slot.
    var activeRefreshGenerationIDForTesting: UUID? { refreshGeneration.activeID }

    /// Drives the real supersede/begin scheduling without a system task
    /// instance. Returns the new generation id.
    @discardableResult
    func beginRefreshWakeForTesting(taskID: UUID = UUID()) -> UUID {
        startRefreshGeneration(taskID, task: nil)
        return taskID
    }

    /// Fires the same fenced path the real `expirationHandler` runs.
    func expireRefreshGenerationForTesting(taskID: UUID) {
        expireRefreshGeneration(taskID: taskID)
    }

    /// Awaits the currently scheduled refresh body (test quiescence).
    func awaitRefreshWorkForTesting() async {
        if let refreshWork { await refreshWork.value }
    }

    /// Drives the REAL `executeScheduleOccurrence` claim → revalidate →
    /// launch route exactly as the background pass calls it, so focused
    /// tests can prove the pre-claim and pre-launch cancellation fences at
    /// the actual seam against a controlled store.
    func executeScheduleOccurrenceForTesting(
        _ occurrence: TaskScheduleOccurrence,
        schedule: TaskScheduleRecord,
        store: SQLiteTaskScheduleStore
    ) async -> ScheduleOccurrenceLaunchResult {
        await executeScheduleOccurrence(
            occurrence, schedule: schedule, store: store, now: Date())
    }

    /// Launch-boundary pause consumed directly before the pre-launch
    /// cancellation fence (see `executeScheduleOccurrence`). Shipping code
    /// never sets it.
    var occurrencePrelaunchBarrierForTesting: (@MainActor () async -> Void)?
    #endif

    private func persistVisualSurfacePolicy() {
        guard let data = try? JSONEncoder().encode(visualSurfacePolicy) else { return }
        UserDefaults.standard.set(data, forKey: Self.visualSurfacePolicyDefaultsKey)
    }

    /// Keeps the latest run available to the PiP toolbar control. Whenever
    /// the PiP capability is on, the inline host arms AVKit for the user's
    /// later Home/app-switch gesture — including while screen feedback runs
    /// concurrently; this method itself never starts PiP from a scene-phase
    /// callback.
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
            automaticallyStartsFromInline: Self.shouldArmAutomaticInlineStart(
                for: effectiveBackgroundExecutionOptions
            )
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
        startRefreshGeneration(UUID(), task: task)
    }

    /// The fenced BGAppRefresh lifecycle, shared by the real task delivery
    /// and the DEBUG behavior-test driver.
    ///
    /// COLD-WAKE READINESS (2026-10-27 repair): the pre-existing body ran
    /// `runDueSchedules` directly, so on a COLD refresh wake a due occurrence
    /// could be claimed and permanently failed `modelUnavailable` before
    /// Main's center reload + provider/model configuration landed. The body
    /// now follows the SAME contract as `runDownloadWakeBootstrap`: kick the
    /// EXISTING single-flight `AppEnvironment.startBackgroundDownloadInitialization()`
    /// and bounded-wait (≤5s) the read-only `backgroundDownloadAutomationReady`
    /// flag. Not ready within the bound = FAIL-CLOSED DEFER: nothing is
    /// claimed and no occurrence is failed from uninitialized configuration;
    /// the shared initialization keeps running for its owner and the next
    /// wake/foreground launch picks the due work up through the same
    /// existing atomic-claim path. No second graph, scheduler, claim route or
    /// continued-processing qualification is involved.
    private func startRefreshGeneration(_ taskID: UUID, task: BGAppRefreshTask?) {
        // Supersede an unfinished previous generation (defensive; the
        // scheduler normally delivers one refresh instance at a time): cancel
        // ITS work and close ITS own task exactly once through the fence.
        // After the release neither its body nor its late expiration callback
        // can cancel, clear or complete anything belonging to this new
        // generation.
        refreshWork?.cancel()
        if let staleID = refreshGeneration.activeID, staleID != taskID {
            finishRefreshGeneration(taskID: staleID, success: false)
        }
        refreshGeneration.begin(taskID)
        activeRefreshTask = task
        task?.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.expireRefreshGeneration(taskID: taskID)
            }
        }
        refreshWork = Task { [weak self] in
            guard let self else { return }
            await self.performRefreshWork(taskID: taskID)
        }
    }

    /// The expiration side of the fence: only the generation still owning the
    /// slot may cancel its own work and complete its own task. A stale or
    /// already-closed generation's late callback is a hard no-op.
    private func expireRefreshGeneration(taskID: UUID) {
        guard refreshGeneration.owns(taskID) else { return }
        refreshWork?.cancel()
        finishRefreshGeneration(taskID: taskID, success: false)
    }

    /// Fenced completion of the generation's own system task. The first
    /// owning path (body end, expiration, supersede) wins and releases the
    /// slot; every later call for that generation is a no-op, so the OS
    /// never sees a second `setTaskCompleted` and a dropped generation never
    /// completes or clears a newer one.
    private func finishRefreshGeneration(taskID: UUID, success: Bool) {
        guard refreshGeneration.complete(taskID) else { return }
        let task = activeRefreshTask
        activeRefreshTask = nil
        #if DEBUG
        if let sink = refreshCompletionsForTesting {
            sink(taskID, success)
            return
        }
        #endif
        task?.setTaskCompleted(success: success)
    }

    /// One refresh wake body. The step order is the repair contract; each
    /// phase re-checks the generation fence + cooperative cancellation
    /// BEFORE claiming or maintaining anything, so an expired/cancelled/
    /// superseded generation cannot continue claiming after expiration.
    private func performRefreshWork(taskID: UUID) async {
        traceRefreshWakeStep(taskID, "readiness")
        let ready = await refreshWakeAutomationReady()
        guard ready, !Task.isCancelled, refreshGeneration.owns(taskID) else {
            // Honest defer: no metadata claim, no maintenance scan, no due
            // pass — nothing was completed, so the task reports failure and
            // the next wake/foreground launch picks the work up.
            let reason = ready
                ? "generationCancelledOrSuperseded"
                : "automationReadyDeadline"
            FloeLogger(category: .app).warning(
                "refreshWakeDeferred reason=\(reason) persistenceReady=\(environment.persistenceReady) prefsLoaded=\(environment.settingsCenter.launchPreferencesLoaded)"
            )
            traceRefreshWakeStep(taskID, "deferred:\(reason)")
            finishRefreshGeneration(taskID: taskID, success: false)
            return
        }
        // A refresh wake is NOT session start authority: restore the record
        // honestly (interrupted/armed) and let the EXISTING finite pass below
        // run. The session never auto-reacquires continued background
        // execution from here.
        traceRefreshWakeStep(taskID, "restore")
        await restoreWorkSession(afterWake: .backgroundRefresh)
        // The other real maintenance stays exactly where it was: durable
        // media reconciliation and the canvas reservation release do not
        // read provider/model configuration.
        traceRefreshWakeStep(taskID, "maintenance")
        await reconcilePendingMediaJobs()
        await environment.canvasCloudAssetService.releasePending()
        // Check cancellation/expiration immediately BEFORE claiming due
        // occurrences; the pass itself keeps its per-item atomic-claim
        // fences (a claimed occurrence is settled by its owner).
        guard !Task.isCancelled, refreshGeneration.owns(taskID) else {
            traceRefreshWakeStep(taskID, "deferred:beforeScan")
            finishRefreshGeneration(taskID: taskID, success: false)
            return
        }
        traceRefreshWakeStep(taskID, "dueScan")
        await runDueSchedules()
        // Success only for a still-open, uncancelled generation that
        // actually ran the pass; losers are fenced no-ops (see
        // `finishRefreshGeneration`).
        finishRefreshGeneration(taskID: taskID, success: !Task.isCancelled)
    }

    /// Kick + bounded wait, or the injected DEBUG gate. Production always
    /// takes the real Main-owned readiness (no second mechanism).
    private func refreshWakeAutomationReady() async -> Bool {
        #if DEBUG
        if let gate = refreshReadinessForTesting {
            return await gate()
        }
        #endif
        environment.startBackgroundDownloadInitialization()
        return await waitForBackgroundDownloadAutomationReady(deadlineSeconds: 5)
    }

    private func traceRefreshWakeStep(_ taskID: UUID, _ step: String) {
        #if DEBUG
        refreshWakeStepsForTesting?(taskID, step)
        #endif
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
        // Only the root view's launch `.task` calls this, and SwiftUI runs it
        // after that root view — the host of the `.floeOpenConversation` and
        // `.floeOpenExecutionEnvironment` subscribers — has been installed in
        // a window. Record that real subscriber evidence before a deferred
        // notification route is flushed, instead of trusting persistence plus
        // scene phase as a proxy.
        navigationSubscribersReady = true
        // Restore the work-session record FIRST: this is the one launch
        // path with a real installed UI scene, so it names the wake. The
        // restore is metadata-only (interrupted/armed) and grants no
        // background execution authority.
        await restoreWorkSession(afterWake: .foregroundLaunch)
        await reconcilePendingMediaJobs()
        await runDueSchedules()
        await reconcileLinuxBackgroundSessionsAfterLaunch()
        // Launch reconciliation runs exactly when persistence became ready:
        // the moment a notification-launched cold start may route.
        flushPendingNotificationRoute()
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
            let title = existing?.title ?? FloeL10n.l("exec.linux.env_title")
            let snapshot = BackgroundWorkSnapshot(
                id: workID,
                kind: .linuxSession,
                title: title,
                state: .interrupted,
                interruption: .terminatedBySystem,
                progressText: FloeL10n.l("platform.background_run_coordinator.the_app_exited_and_the_linux"),
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
                    $0.lastError = FloeL10n.l("platform.background_run_coordinator.submission_was_interrupted_before_the_provider")
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

    /// Runs one schedule pass immediately (an explicit user/agent "run now"
    /// or an upstream-success trigger). Same claim semantics as any wakeup.
    func runDueSchedulesNow() async {
        await runDueSchedules()
    }

    /// One truthful startup reconciliation, shared by the background pass and
    /// the explicit selected-schedule route. Concurrent first callers
    /// coalesce onto ONE in-flight physical reconcile: every awaiter observes
    /// the same success or failure, the task is cleared on failure so the
    /// next call retries, and the readiness flag is set ONLY after the write
    /// succeeds — no caller ever proceeds under false readiness, and a second
    /// reconcile can never interrupt an occurrence claimed while the first
    /// was in flight. The reconciliation itself is unchanged — stale
    /// `claimed`/`running` rows from a dead process become `interrupted` and
    /// are never restarted.
    private func reconcileScheduleOccurrencesOnce(
        store: SQLiteTaskScheduleStore,
        now: Date
    ) async throws {
        if didReconcileScheduleOccurrences { return }
        if let scheduleOccurrenceReconcileTask {
            // Share the in-flight reconcile rather than starting a second
            // physical pass over the same rows.
            try await scheduleOccurrenceReconcileTask.value
            return
        }
        // The assignment happens before the first await, so any caller that
        // enters after this point awaits this same task (MainActor isolation
        // serializes entry; the task is created unstructured so its store
        // work is not tied to this actor's turn).
        let task: Task<Void, Error> = Task {
            _ = try await store.reconcileInterruptedOccurrences(at: now)
        }
        scheduleOccurrenceReconcileTask = task
        do {
            try await task.value
            didReconcileScheduleOccurrences = true
            scheduleOccurrenceReconcileTask = nil
        } catch {
            // Publish no readiness and release the failure so the next call
            // performs a real retry.
            scheduleOccurrenceReconcileTask = nil
            throw error
        }
    }

    /// One schedule pass. Execution instances are claimed ATOMICALLY before a
    /// task is launched, so foreground/background/notification wakeups can
    /// never launch the same logical occurrence twice; a crash between claim
    /// and launch is reconciled honestly by `reconcileInterruptedOccurrences`.
    /// Missed fire times coalesce to the most recent due occurrence (earlier
    /// ones are recorded as explicit `skipped` history), daily/weekly times
    /// stay anchored to the schedule's calendar timezone, and an
    /// after-success trigger fires only from a recorded SUCCESSFUL upstream
    /// run.
    private func runDueSchedules() async {
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let now = Date()
        // Best-effort pass, but never launch while the startup state is
        // ambiguous: a failed reconciliation means dead-process boundaries
        // are unproven, so the whole pass defers to the next wake (the
        // reconcile stays retryable because readiness publishes only on
        // success).
        do {
            try await reconcileScheduleOccurrencesOnce(store: store, now: now)
        } catch {
            return
        }
        // Drain NON-calendar durable pending instances first. `runNow` creates
        // a `manual:<uuid>` instance and a successful upstream run creates an
        // `upstream:<runID>` instance; neither is re-derived from the calendar,
        // so without this drain they stay pending forever (Run now appears to
        // do nothing; after-success chains never fire). Calendar instances keep
        // their materialize/coalesce policy in the loop below.
        await drainPendingOccurrences(store: store, now: now)
        guard let schedules = try? await store.schedules() else { return }
        for schedule in schedules where schedule.isEnabled && !Task.isCancelled {
            let due = TaskSchedulePlanner.dueFireTimes(record: schedule, now: now)
            guard !due.isEmpty else { continue }
            // Materialize every logical instance (idempotent by stable id).
            for fireTime in due {
                let key = TaskSchedulePlanner.dedupeKey(for: fireTime, record: schedule)
                let occurrence = TaskScheduleOccurrence(
                    id: TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: key),
                    scheduleID: schedule.id,
                    scheduledFor: fireTime,
                    dedupeKey: key)
                _ = try? await store.enqueueOccurrence(occurrence)
            }
            // Default catch-up policy: execute the MOST RECENT due instance;
            // older missed ones become explicit skipped history. The instance
            // is CLAIMED before it is settled: `finishOccurrence` only settles
            // claimed/running rows (so a concurrent claim can never be
            // overwritten by a skip), and the claim also guarantees nothing
            // else can launch a coalesced instance.
            for fireTime in due.dropLast() {
                let key = TaskSchedulePlanner.dedupeKey(for: fireTime, record: schedule)
                let id = TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: key)
                if let existing = try? await store.occurrence(id: id), existing.state == .pending,
                   (try? await store.claimOccurrence(id: id, at: now)) == true {
                    try? await store.finishOccurrence(
                        id: id, state: .skipped,
                        summary: "Coalesced into the most recent due occurrence", errorText: nil,
                        at: now)
                }
            }
            let key = TaskSchedulePlanner.dedupeKey(for: due[due.count - 1], record: schedule)
            let occurrenceID = TaskScheduleOccurrence.stableID(scheduleID: schedule.id, dedupeKey: key)
            guard let occurrence = try? await store.occurrence(id: occurrenceID),
                  occurrence.state == .pending else { continue }
            _ = await executeScheduleOccurrence(
                occurrence, schedule: schedule, store: store, now: now)
        }
        // Insurance reminder set follows the same pass: one pending reminder
        // per enabled schedule at its next expected fire, removed for
        // disabled/finished/event-armed schedules and bounded by capacity.
        await reconcileScheduleReminders(now: now)
        // Future schedules never pin the VM or PiP: the only effect of a
        // pending schedule is a best-effort BG refresh request.
        let allSchedules = (try? await store.schedules()) ?? []
        if let next = allSchedules.filter(\.isEnabled).compactMap(\.nextExpectedAt).min() {
            let earliest = max(next, Date().addingTimeInterval(60))
            BackgroundPolicyRegistry.shared.scheduleRefresh(earliest: earliest)
        }
    }

    /// Claims and executes durable PENDING instances that the calendar loop
    /// does not re-derive: `manual:<uuid>` (Run now) and `upstream:<runID>`
    /// (a successful upstream completion). Each is claimed atomically inside
    /// `executeScheduleOccurrence`, so overlapping foreground/background passes
    /// cannot double-launch, and its launch identity stays the predetermined
    /// stable id. An instance whose schedule was deleted or disabled, or whose
    /// after-success binding was edited away, is settled honestly instead of
    /// launching.
    private func drainPendingOccurrences(store: SQLiteTaskScheduleStore, now: Date) async {
        guard let pending = try? await store.pendingOccurrences(limit: 200) else { return }
        for occurrence in pending where !Task.isCancelled {
            let isManual = occurrence.dedupeKey.hasPrefix("manual:")
            let isUpstream = occurrence.dedupeKey.hasPrefix("upstream:")
            guard isManual || isUpstream else { continue }
            // Settling a pending instance requires claiming it first:
            // `finishOccurrence` only settles claimed/running rows, and the
            // claim also prevents a concurrent pass from launching it after
            // this decision.
            func settle(_ state: TaskScheduleOccurrenceState, _ summary: String) async {
                guard (try? await store.claimOccurrence(id: occurrence.id, at: now)) == true else { return }
                try? await store.finishOccurrence(
                    id: occurrence.id, state: state, summary: summary, errorText: nil, at: now)
            }
            guard let schedule = try? await store.schedule(id: occurrence.scheduleID) else {
                await settle(.cancelled, "The schedule was deleted before this instance ran")
                continue
            }
            guard schedule.isEnabled else {
                await settle(.cancelled, "The schedule was disabled before this instance ran")
                continue
            }
            if isUpstream, schedule.cadence != .afterSuccess {
                // The schedule no longer follows an upstream run (its binding
                // was edited away): a stale instance must not launch.
                await settle(.skipped, "The schedule no longer follows an upstream run")
                continue
            }
            _ = await executeScheduleOccurrence(
                occurrence, schedule: schedule, store: store, now: now)
        }
    }

    /// Typed result of one atomic claim → revalidate → launch → bind attempt.
    /// The background pass ignores the payload (its bookkeeping is the
    /// durable ledger itself); an explicit caller (the selected-schedule
    /// automation route) maps every case to an accurate outcome instead of
    /// guessing from silence.
    enum ScheduleOccurrenceLaunchResult: Sendable, Equatable {
        /// A new task was launched and the occurrence is bound to it.
        case launched(runID: UUID, conversationID: UUID)
        /// The predetermined run was already committed (a retry after a crash
        /// between commit and binding) and the occurrence now names it.
        case boundToExisting(runID: UUID, conversationID: UUID)
        /// The durable launch committed but the occurrence could not be
        /// bound. A real bind-write error leaves the row `claimed` so a
        /// retry rebinds the SAME run; a ledger that moved under us
        /// (disabled/cancelled/reconciled) is left exactly as the mover
        /// wrote it. The run continues as an ordinary run, unbound — and a
        /// committed active launch is NEVER settled as a prelaunch failure.
        case launchCommittedButUnbound(runID: UUID, conversationID: UUID)
        /// Another executor claimed the instance before this attempt.
        case claimMissed
        /// The schedule was deleted between materialization and launch.
        case scheduleDeleted
        /// The schedule was disabled before the launch revalidation.
        case scheduleDisabled
        /// The frozen execution-environment binding no longer resolves.
        case environmentUnavailable
        /// The frozen (or default) model binding no longer resolves.
        case modelUnavailable
        /// The launch failed with no durable run; the text is the honest
        /// occurrence error.
        case launchFailed(String)
        /// A durable store write/read failed; nothing was launched.
        case storageFailed
        /// A PRESENT frozen permission policy failed to decode. An absent
        /// (nil) legacy policy keeps the settings default; an invalid one
        /// must never degrade into fallback permissions.
        case permissionUnavailable
        /// The executing pass was ALREADY cancelled (an explicit session
        /// Stop or an expired/ superseded refresh) before claiming: nothing
        /// was claimed and the instance stays `pending`, so the next wake or
        /// foreground launch picks it up through the same atomic-claim route.
        case passCancelledBeforeClaim
        /// A Stop/expiration landed AFTER the claim and BEFORE launch.
        /// Nothing was launched and the claimed instance was honestly
        /// settled `cancelled` (future fire times are separate instances);
        /// no run exists to reference.
        case cancelledBeforeLaunch
    }

    /// Machine-readable refusal reasons of the explicit selected-schedule
    /// route. The intent layer maps each case to concise bilingual copy; no
    /// internal identifier reaches the user.
    enum FloeSelectedScheduleFailure: Error, Equatable, Sendable {
        case scheduleDeleted
        case scheduleDisabled
        case noDueOccurrence(eventDriven: Bool)
        case concurrentlyClaimed
        case environmentUnavailable
        case modelUnavailable
        case storageUnavailable
        case launchFailed(String)
        /// The returned run could not be proven to belong to the selected
        /// schedule's occurrence (ledger mismatch and not the schedule's
        /// predetermined identity). Never fabricate a reference.
        case runReferenceMismatch
        /// The schedule's stored permission policy is present but invalid;
        /// nothing may launch under fallback permissions.
        case permissionUnavailable
    }

    /// The exact run a selected-schedule execution produced (or the one the
    /// due occurrence already owned). Typed for the App Intent layer, which
    /// projects it through the same exact-run snapshot/ownership path as the
    /// other run actions.
    struct FloeSelectedScheduleRunReceipt: Sendable, Equatable {
        var runID: UUID
        var conversationID: UUID
        /// True when THIS call launched the task; false when the returned
        /// reference names a run an earlier claim/launch (or a duplicate
        /// callback) already committed.
        var freshlyLaunched: Bool
    }

    /// Atomic claim → revalidate → launch → bind. The launch identity is
    /// PREDETERMINED from the logical occurrence, so a crash between the
    /// durable run's commit and the occurrence binding is reconciled by
    /// binding the existing run instead of re-launching (no duplicate,
    /// invisible task). An explicit binding that can no longer be satisfied
    /// fails the occurrence with its reason; nothing falls back silently.
    private func executeScheduleOccurrence(
        _ occurrence: TaskScheduleOccurrence,
        schedule: TaskScheduleRecord,
        store: SQLiteTaskScheduleStore,
        now: Date
    ) async -> ScheduleOccurrenceLaunchResult {
        // Cancellation fence BEFORE claiming (2026-10-27 Stop/expiration
        // contract): a cancelled session pass or refresh body must not move
        // a fresh instance out of `pending` at all — the next wake or
        // foreground launch picks it up through this same atomic-claim route.
        guard !Task.isCancelled else {
            return .passCancelledBeforeClaim
        }
        // Claim BEFORE anything else: exactly one executor (a background
        // pass, an explicit selected-schedule call, a duplicate automation
        // callback) can move this instance out of `pending`, so the task can
        // never launch twice for one logical occurrence.
        do {
            guard try await store.claimOccurrence(id: occurrence.id, at: now) else {
                return .claimMissed
            }
        } catch {
            return .storageFailed
        }
        // Revalidate the FROZEN binding after the claim: a disabled schedule
        // must not launch.
        let fresh: TaskScheduleRecord?
        do {
            fresh = try await store.schedule(id: schedule.id)
        } catch {
            return .storageFailed
        }
        guard let fresh, fresh.isEnabled else {
            try? await store.finishOccurrence(
                id: occurrence.id, state: .cancelled, summary: nil,
                errorText: "The schedule was disabled before this occurrence launched", at: Date())
            return fresh == nil ? .scheduleDeleted : .scheduleDisabled
        }
        // The bound environment must really exist and not be deleting; it is
        // then passed to the launched task (never only checked here).
        if let environmentID = fresh.environmentID {
            let record = await environment.environmentRegistry.record(id: environmentID)
            guard let record, record.state != .deleting else {
                try? await store.finishOccurrence(
                    id: occurrence.id, state: .failed, summary: nil,
                    errorText: "The bound execution environment is unavailable; nothing was launched.",
                    at: Date())
                postSchedulePendingNotification(schedule: fresh, occurrence: occurrence)
                return .environmentUnavailable
            }
        }
        let center = environment.conversationCenter
        // An EXPLICIT model binding that no longer resolves (deleted or
        // disabled) fails honestly. Only an intentionally unbound record
        // (created with the creation-time default) resolves the current
        // default — never a silent fallback for a missing bound model.
        let resolved: (ProviderProfile, ModelProfile)?
        if let modelID = fresh.modelID {
            resolved = center.providerAndModel(modelID: modelID)
        } else {
            resolved = center.providerAndModel(modelID: center.modelPreferences.defaultAgentModelID)
        }
        guard let resolved else {
            try? await store.finishOccurrence(
                id: occurrence.id, state: .failed, summary: nil,
                errorText: fresh.modelID == nil
                    ? "No provider/model is available for this scheduled task"
                    : "The model bound to this schedule is no longer available or is disabled; nothing was launched.",
                at: Date())
            postSchedulePendingNotification(schedule: fresh, occurrence: occurrence)
            return .modelUnavailable
        }
        var policy: DraftTaskPolicy?
        if let json = fresh.permissionJSON {
            // An intentionally ABSENT legacy binding (nil) keeps the settings
            // default; a PRESENT-but-invalid policy must refuse accurately
            // instead of launching under silently degraded permissions.
            guard let decoded = try? JSONDecoder().decode(
                DraftTaskPolicy.self, from: Data(json.utf8)) else {
                try? await store.finishOccurrence(
                    id: occurrence.id, state: .failed, summary: nil,
                    errorText: "The permission policy bound to this schedule is invalid; nothing was launched.",
                    at: Date())
                postSchedulePendingNotification(schedule: fresh, occurrence: occurrence)
                return .permissionUnavailable
            }
            policy = decoded
        }
        // Predetermined launch identity: a retry after a crash between commit
        // and binding converges on the SAME durable run.
        let conversationID = TaskScheduleOccurrence.stableID(
            scheduleID: fresh.id, dedupeKey: "conversation:\(occurrence.id.uuidString)")
        let runID = TaskScheduleOccurrence.stableID(
            scheduleID: fresh.id, dedupeKey: "run:\(occurrence.id.uuidString)")
        // A trustworthy read decides between recovery and a fresh launch: on
        // ambiguous storage this executor must NOT assume "no run" and launch
        // a possible second copy of the predetermined identity.
        let preexistingRun: RunRecord?
        do {
            preexistingRun = try await environment.runStore.run(id: runID)
        } catch {
            return .storageFailed
        }
        if let existing = preexistingRun {
            // The predetermined run already exists (a retry after a crash
            // between commit and binding). Bind it truthfully: only a real
            // bind may report `boundToExisting`.
            let bindOutcome: Bool
            do {
                bindOutcome = try await store.markOccurrenceRunning(
                    id: occurrence.id, runID: runID,
                    conversationID: existing.conversationID, at: Date())
            } catch {
                // Real bind-write error: the committed run is untouched and
                // the occurrence stays `claimed` so a retry rebinds the SAME
                // run — never settle a committed active launch as a prelaunch
                // failure.
                return .launchCommittedButUnbound(
                    runID: runID, conversationID: existing.conversationID)
            }
            if bindOutcome {
                try? await store.markStarted(id: fresh.id, at: Date())
                // The run may have finished between the pre-bind read and
                // this bind: the completion callback then saw no `run_id`
                // and could not settle the row. Refresh the durable state
                // after binding so that ordering converges too.
                await settleBoundRunIfTerminalAfterBind(
                    store: store, occurrenceID: occurrence.id, runID: runID,
                    conversationID: existing.conversationID)
                return .boundToExisting(runID: runID, conversationID: existing.conversationID)
            }
            // The ledger moved under us (disabled/cancelled/reconciled): the
            // run is real but stays unbound; the mover's row is left exactly
            // as written instead of being overwritten with a false failure.
            return .launchCommittedButUnbound(
                runID: runID, conversationID: existing.conversationID)
        }
        #if DEBUG
        // Test-only launch-boundary pause (existing seam idiom): lets a
        // focused test cancel the executing pass AFTER the claim awaits and
        // directly before the fence below, proving it. Shipping code never
        // sets it.
        if let barrier = occurrencePrelaunchBarrierForTesting {
            await barrier()
        }
        #endif
        // Cancellation fence IMMEDIATELY BEFORE launching new work: a Stop
        // or refresh expiration that landed after the claim must not start a
        // new agent. The claimed instance is settled honestly as `cancelled`
        // (nothing was started; future fire times are separate instances),
        // the same recoverable settle the disabled-schedule path uses. A
        // predetermined run that already committed above is NEVER touched:
        // bind-recovery is not new work, and an ordinary foreground run is
        // never cancelled from here.
        if Task.isCancelled {
            try? await store.finishOccurrence(
                id: occurrence.id, state: .cancelled, summary: nil,
                errorText: "The background pass was cancelled before this occurrence launched; nothing was started.",
                at: Date())
            return .cancelledBeforeLaunch
        }
        do {
            let started = try await center.startTask(
                goal: fresh.prompt,
                title: fresh.title,
                provider: resolved.0,
                model: resolved.1,
                workspaceID: fresh.workspaceID,
                executionMode: .agent,
                initialPolicy: policy,
                newConversationID: conversationID,
                newRunID: runID,
                executionEnvironmentID: fresh.environmentID,
                startOrigin: .scheduledTask
            )
            // Bind the just-committed launch. A bind-write error and a ledger
            // that moved under us are DIFFERENT states and must not share the
            // historical "settle as failed with no run" fall-through: the
            // durable run is already committed and active.
            let bound: Bool
            do {
                bound = try await store.markOccurrenceRunning(
                    id: occurrence.id,
                    runID: started.run.runID,
                    conversationID: started.conversationID,
                    at: Date())
            } catch {
                // Real bind-write error: leave the occurrence `claimed` so a
                // retry rebinds this SAME run; the launched task continues as
                // an ordinary run.
                return .launchCommittedButUnbound(
                    runID: started.run.runID, conversationID: started.conversationID)
            }
            guard bound else {
                // The ledger moved under us (disabled/cancelled/reconciled
                // between claim and bind): never claim a launch that was not
                // recorded and never overwrite the mover's row with a false
                // failure. The started task continues as an ordinary run.
                return .launchCommittedButUnbound(
                    runID: started.run.runID, conversationID: started.conversationID)
            }
            try? await store.markStarted(id: fresh.id, at: Date())
            // Same post-bind convergence for a launch so fast that it
            // reached a terminal state before the binding write.
            await settleBoundRunIfTerminalAfterBind(
                store: store, occurrenceID: occurrence.id,
                runID: started.run.runID,
                conversationID: started.conversationID)
            return .launched(runID: started.run.runID, conversationID: started.conversationID)
        } catch {
            // A failure AFTER the durable launch committed leaves the
            // predetermined run behind: bind it instead of reporting a clean
            // failure (the task may still be running). Only a failure with
            // no durable run is reported as failed.
            let committedRun: RunRecord?
            do {
                committedRun = try await environment.runStore.run(id: runID)
            } catch {
                // Ambiguous storage: never guess "no run", never settle a
                // committed launch as a prelaunch failure.
                return .storageFailed
            }
            if let existing = committedRun {
                // Same-run recovery: bind the predetermined run instead of
                // reporting a clean failure (the task may still be running).
                let bindOutcome: Bool
                do {
                    bindOutcome = try await store.markOccurrenceRunning(
                        id: occurrence.id, runID: runID,
                        conversationID: existing.conversationID, at: Date())
                } catch {
                    // Real bind-write error: leave the occurrence `claimed`
                    // so a retry rebinds this SAME run; never settle the
                    // committed active launch as a prelaunch failure.
                    return .launchCommittedButUnbound(
                        runID: runID, conversationID: existing.conversationID)
                }
                if bindOutcome {
                    try? await store.markStarted(id: fresh.id, at: Date())
                    await settleBoundRunIfTerminalAfterBind(
                        store: store, occurrenceID: occurrence.id, runID: runID,
                        conversationID: existing.conversationID)
                    return .boundToExisting(runID: runID, conversationID: existing.conversationID)
                }
                // The ledger moved under us: the run is real but stays
                // unbound; the mover's row is left exactly as written.
                return .launchCommittedButUnbound(
                    runID: runID, conversationID: existing.conversationID)
            }
            let message = String(error.localizedDescription.prefix(1_024))
            try? await store.finishOccurrence(
                id: occurrence.id, state: .failed, summary: nil,
                errorText: message, at: Date())
            return .launchFailed(message)
        }
    }

    /// Runs ONE explicitly selected schedule's actual due occurrence through
    /// the SAME atomic claim → revalidate → launch → bind route the
    /// background pass uses, and returns the exact run the occurrence owns.
    /// No second scheduler, no unbound Start(prompt), no random manual
    /// instance: duplicate/concurrent callbacks converge on the
    /// predetermined run identity instead of double-launching, and every
    /// refusal is typed (deleted/disabled/not-due/unavailable/
    /// concurrently-claimed/storage/launch failure) instead of a silent nil.
    /// Simultaneous callbacks for the SAME due occurrence coalesce onto one
    /// bounded in-flight attempt (keyed by occurrence, never by schedule) and
    /// return its exact run; the atomic SQLite claim still fences every other
    /// coordinator and process. Ordinary passes, after-success arming and
    /// Run-now semantics are untouched: this route never reads another
    /// schedule's rows.
    func runSelectedSchedule(
        scheduleID: UUID
    ) async throws -> FloeSelectedScheduleRunReceipt {
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let now = Date()
        // The explicit route surfaces an honest storage failure instead of
        // proceeding under a falsely-ready flag: the reconcile stays
        // retryable because the flag is only set on success.
        do {
            try await reconcileScheduleOccurrencesOnce(store: store, now: now)
        } catch {
            throw FloeSelectedScheduleFailure.storageUnavailable
        }
        let schedule: TaskScheduleRecord?
        do {
            schedule = try await store.schedule(id: scheduleID)
        } catch {
            throw FloeSelectedScheduleFailure.storageUnavailable
        }
        guard let schedule else { throw FloeSelectedScheduleFailure.scheduleDeleted }
        // The planner's coalesced most-recent-due target; event-armed
        // after-success schedules have no time-based occurrence.
        guard let target = TaskSchedulePlanner.selectedRunTarget(record: schedule, now: now)
        else {
            throw FloeSelectedScheduleFailure.noDueOccurrence(
                eventDriven: schedule.cadence == .afterSuccess)
        }
        // Simultaneous callbacks for this SAME logical occurrence share ONE
        // in-flight launch attempt instead of one of them losing the durable
        // claim race and reporting a false concurrency refusal. The attempt
        // covers enqueue → claim → launch → bind and reuses the exact
        // existing route; the atomic SQLite claim below remains the
        // authority across coordinators/processes.
        return try await coalescedSelectedScheduleAttempt(
            schedule: schedule, target: target, store: store, now: now)
    }

    /// Joins the in-flight attempt for `target.occurrenceID`, or starts (and
    /// owns) the single attempt every simultaneous caller awaits. The
    /// attempt is an unstructured main-actor task, so one waiter's
    /// cancellation never cancels the caller-owned launch: awaiting its
    /// value does not propagate cancellation, and only the creating caller
    /// removes the entry once the attempt actually finishes. A joiner never
    /// deletes the entry (the identity check would refuse a newer attempt
    /// anyway). Failures are evicted exactly like successes, keeping the
    /// existing storage-fault retry semantics: the next call performs a real
    /// retry instead of replaying a stale error.
    private func coalescedSelectedScheduleAttempt(
        schedule: TaskScheduleRecord,
        target: (fireTime: Date, dedupeKey: String, occurrenceID: UUID),
        store: SQLiteTaskScheduleStore,
        now: Date
    ) async throws -> FloeSelectedScheduleRunReceipt {
        let occurrenceID = target.occurrenceID
        if let inFlight = selectedScheduleAttempts[occurrenceID] {
            var receipt = try await inFlight.task.value
            // The run is shared, but THIS call joined another caller's
            // attempt: it did not launch the task.
            receipt.freshlyLaunched = false
            return receipt
        }
        let attemptID = UUID()
        let task = Task { @MainActor in
            try await self.performSelectedScheduleAttempt(
                schedule: schedule, target: target, store: store, now: now)
        }
        // Registration happens in the same main-actor turn as the emptiness
        // check above (no suspension between them), so two callers can never
        // both create an attempt for one occurrence.
        selectedScheduleAttempts[occurrenceID] = SelectedScheduleAttempt(id: attemptID, task: task)
        do {
            let receipt = try await task.value
            clearSelectedScheduleAttempt(occurrenceID: occurrenceID, attemptID: attemptID)
            return receipt
        } catch {
            clearSelectedScheduleAttempt(occurrenceID: occurrenceID, attemptID: attemptID)
            throw error
        }
    }

    /// Identity-safe ownership of the in-flight table: a clearer only removes
    /// the attempt it created, never a newer replacement.
    private func clearSelectedScheduleAttempt(occurrenceID: UUID, attemptID: UUID) {
        guard selectedScheduleAttempts[occurrenceID]?.id == attemptID else { return }
        selectedScheduleAttempts[occurrenceID] = nil
    }

    /// The one mutable attempt behind a selected-schedule call: enqueue the
    /// coalesced occurrence, recover/bind an already committed run, or run
    /// the shared atomic claim → revalidate → launch → bind route. It is
    /// never entered concurrently for the same occurrence inside one
    /// coordinator; cross-coordinator safety remains the SQLite claim.
    private func performSelectedScheduleAttempt(
        schedule: TaskScheduleRecord,
        target: (fireTime: Date, dedupeKey: String, occurrenceID: UUID),
        store: SQLiteTaskScheduleStore,
        now: Date
    ) async throws -> FloeSelectedScheduleRunReceipt {
        do {
            _ = try await store.enqueueOccurrence(TaskScheduleOccurrence(
                id: target.occurrenceID,
                scheduleID: schedule.id,
                scheduledFor: target.fireTime,
                dedupeKey: target.dedupeKey))
        } catch {
            throw FloeSelectedScheduleFailure.storageUnavailable
        }
        let occurrence: TaskScheduleOccurrence
        do {
            guard let stored = try await store.occurrence(id: target.occurrenceID) else {
                throw FloeSelectedScheduleFailure.storageUnavailable
            }
            occurrence = stored
        } catch {
            throw FloeSelectedScheduleFailure.storageUnavailable
        }
        // The occurrence already owns a committed run (an earlier callback, a
        // pass, or a crash-retry binding): return that EXACT reference.
        if let runID = occurrence.runID, let conversationID = occurrence.conversationID {
            return try await verifiedReceipt(
                store: store, scheduleID: schedule.id, occurrenceID: target.occurrenceID,
                runID: runID, conversationID: conversationID, freshlyLaunched: false)
        }
        guard schedule.isEnabled else { throw FloeSelectedScheduleFailure.scheduleDisabled }
        if occurrence.state == .claimed {
            // A prior claim committed the predetermined durable run but its
            // bind write failed transiently (or the process died between
            // launch and bind): recover and rebind that SAME run. Never
            // relaunch, and never reset another live claim — the rebind only
            // wins from the still-claimed state, and a concurrent binder
            // binds the identical predetermined identity.
            let expectedRunID = TaskScheduleOccurrence.stableID(
                scheduleID: schedule.id, dedupeKey: "run:\(occurrence.id.uuidString)")
            let expectedConversationID = TaskScheduleOccurrence.stableID(
                scheduleID: schedule.id, dedupeKey: "conversation:\(occurrence.id.uuidString)")
            // A trustworthy read decides recovery from a live foreign claim:
            // ambiguous storage must NOT masquerade as "no run" (which would
            // fabricate a concurrency outcome).
            let committedRun: RunRecord?
            do {
                committedRun = try await environment.runStore.run(id: expectedRunID)
            } catch {
                throw FloeSelectedScheduleFailure.storageUnavailable
            }
            guard let committedRun else {
                // No committed run: the claim is owned by a live executor
                // that has not committed anything yet.
                throw FloeSelectedScheduleFailure.concurrentlyClaimed
            }
            guard committedRun.conversationID == expectedConversationID else {
                // A run under the predetermined identity whose owner
                // conversation does not match is corrupt: refuse the
                // reference instead of exposing it.
                throw FloeSelectedScheduleFailure.runReferenceMismatch
            }
            let bound: Bool
            do {
                bound = try await store.markOccurrenceRunning(
                    id: occurrence.id, runID: expectedRunID,
                    conversationID: expectedConversationID, at: Date())
            } catch {
                throw FloeSelectedScheduleFailure.storageUnavailable
            }
            if bound {
                try? await store.markStarted(id: schedule.id, at: Date())
                return try await verifiedReceipt(
                    store: store, scheduleID: schedule.id, occurrenceID: occurrence.id,
                    runID: expectedRunID, conversationID: expectedConversationID,
                    freshlyLaunched: false)
            }
            // CAS miss: another writer moved the row between the read and the
            // rebind. Converge on the run the winning writer bound, or refuse
            // with the accurate settled/live state — never guess.
            let moved: TaskScheduleOccurrence?
            do {
                moved = try await store.occurrence(id: occurrence.id)
            } catch {
                throw FloeSelectedScheduleFailure.storageUnavailable
            }
            if let moved, let runID = moved.runID, let conversationID = moved.conversationID {
                return try await verifiedReceipt(
                    store: store, scheduleID: schedule.id, occurrenceID: occurrence.id,
                    runID: runID, conversationID: conversationID, freshlyLaunched: false)
            }
            if moved?.state == .claimed {
                throw FloeSelectedScheduleFailure.concurrentlyClaimed
            }
            // Settled by another writer without a run: nothing here may
            // launch or restart.
            throw FloeSelectedScheduleFailure.noDueOccurrence(eventDriven: false)
        }
        guard occurrence.state == .pending else {
            // Settled history without a run: nothing here may launch.
            throw FloeSelectedScheduleFailure.noDueOccurrence(eventDriven: false)
        }
        switch await executeScheduleOccurrence(
            occurrence, schedule: schedule, store: store, now: now) {
        case .launched(let runID, let conversationID),
             .launchCommittedButUnbound(let runID, let conversationID):
            // launchCommittedButUnbound still names a REAL durable run that
            // continues as an ordinary run; the reference is truthful.
            return try await verifiedReceipt(
                store: store, scheduleID: schedule.id, occurrenceID: target.occurrenceID,
                runID: runID, conversationID: conversationID, freshlyLaunched: true)
        case .boundToExisting(let runID, let conversationID):
            return try await verifiedReceipt(
                store: store, scheduleID: schedule.id, occurrenceID: target.occurrenceID,
                runID: runID, conversationID: conversationID, freshlyLaunched: false)
        case .claimMissed:
            // Re-read once to converge on the run the winning claim bound; a
            // read failure is storage truth, not concurrency.
            let winner: TaskScheduleOccurrence?
            do {
                winner = try await store.occurrence(id: occurrence.id)
            } catch {
                throw FloeSelectedScheduleFailure.storageUnavailable
            }
            if let settled = winner,
               let runID = settled.runID, let conversationID = settled.conversationID {
                return try await verifiedReceipt(
                    store: store, scheduleID: schedule.id, occurrenceID: target.occurrenceID,
                    runID: runID, conversationID: conversationID, freshlyLaunched: false)
            }
            throw FloeSelectedScheduleFailure.concurrentlyClaimed
        case .scheduleDeleted:
            throw FloeSelectedScheduleFailure.scheduleDeleted
        case .scheduleDisabled:
            throw FloeSelectedScheduleFailure.scheduleDisabled
        case .environmentUnavailable:
            throw FloeSelectedScheduleFailure.environmentUnavailable
        case .modelUnavailable:
            throw FloeSelectedScheduleFailure.modelUnavailable
        case .launchFailed(let message):
            throw FloeSelectedScheduleFailure.launchFailed(message)
        case .storageFailed:
            throw FloeSelectedScheduleFailure.storageUnavailable
        case .permissionUnavailable:
            throw FloeSelectedScheduleFailure.permissionUnavailable
        case .passCancelledBeforeClaim:
            // The route's OWN Task was cancelled before claiming: nothing
            // launched and the due instance stays pending for the next pass.
            // The typed refusal is truthful; no run may be referenced.
            throw FloeSelectedScheduleFailure.launchFailed(
                "The request was cancelled before this occurrence was claimed.")
        case .cancelledBeforeLaunch:
            // Cancelled after the claim and before launch; the instance was
            // honestly settled `cancelled` above — nothing was started.
            throw FloeSelectedScheduleFailure.launchFailed(
                "The request was cancelled before this occurrence launched.")
        }
    }

    /// Authoritative ownership proof for a selected-schedule receipt. A
    /// durable tie must exist first — the occurrence ledger names
    /// (scheduleID, runID, conversationID), or the reference equals the
    /// schedule's predetermined stable launch identity derived from
    /// (schedule, occurrence) — AND the actual persisted run must exist with
    /// exactly this owner conversation. The arithmetic identity alone is not
    /// proof (anyone can recompute it); a matching ledger naming a missing or
    /// foreign run is corrupt. Anything else is refused rather than exposed
    /// to Shortcuts; a storage read failure is reported as storage truth,
    /// never as absence or mismatch.
    private func verifiedReceipt(
        store: SQLiteTaskScheduleStore,
        scheduleID: UUID,
        occurrenceID: UUID,
        runID: UUID,
        conversationID: UUID,
        freshlyLaunched: Bool
    ) async throws -> FloeSelectedScheduleRunReceipt {
        let ledger: TaskScheduleOccurrence?
        do {
            ledger = try await store.occurrence(id: occurrenceID)
        } catch {
            throw FloeSelectedScheduleFailure.storageUnavailable
        }
        let ledgerProvesOwnership = ledger?.scheduleID == scheduleID
            && ledger?.runID == runID
            && ledger?.conversationID == conversationID
        let predeterminedRunID = TaskScheduleOccurrence.stableID(
            scheduleID: scheduleID, dedupeKey: "run:\(occurrenceID.uuidString)")
        let predeterminedConversationID = TaskScheduleOccurrence.stableID(
            scheduleID: scheduleID, dedupeKey: "conversation:\(occurrenceID.uuidString)")
        let identityProvesOwnership = runID == predeterminedRunID
            && conversationID == predeterminedConversationID
        guard ledgerProvesOwnership || identityProvesOwnership else {
            throw FloeSelectedScheduleFailure.runReferenceMismatch
        }
        // The decisive owner proof: the receipt must name a REAL persisted
        // run whose conversation is exactly the claimed owner. A missing run
        // is a corrupt reference; a foreign conversation is someone else's
        // run. Read failure is storage truth, not "no run".
        let durable: RunRecord?
        do {
            durable = try await environment.runStore.run(id: runID)
        } catch {
            throw FloeSelectedScheduleFailure.storageUnavailable
        }
        guard let durable, durable.conversationID == conversationID else {
            throw FloeSelectedScheduleFailure.runReferenceMismatch
        }
        // A terminal run may have finished BEFORE its occurrence was bound —
        // the bind write failed after the launch committed, or the run's
        // completion callback raced the bind and could not find a `run_id`.
        // The live completion bridge settles occurrences by `run_id`, so an
        // unbound claim is invisible to it. Once this receipt proves the
        // ledger now names that exact run, settle the occurrence through the
        // SAME completion service instead of leaving a finished task recorded
        // as `running` forever. Only an already-bound occurrence is eligible;
        // an unbound claim must first be bound by the caller/retry, and a row
        // settled by another owner is never overwritten (the store's own
        // `claimed`/`running` guard applies).
        if ledgerProvesOwnership {
            _ = try await settleOccurrenceIfRunAlreadyTerminal(
                store: store,
                occurrenceID: occurrenceID,
                runID: runID,
                conversationID: conversationID,
                durableRun: durable,
                at: Date())
        }
        return FloeSelectedScheduleRunReceipt(
            runID: runID, conversationID: conversationID, freshlyLaunched: freshlyLaunched)
    }

    /// The durable run states that are a SCHEDULE outcome. `checkpointed` and
    /// `interrupted` are terminal for the run row but are deliberate park /
    /// unknown states, not success, failure or cancellation: they must never
    /// be rewritten into a fabricated occurrence outcome. `cancelled` is kept
    /// for the existing cancellation vocabulary even though the current
    /// runtime's explicit cancel parks as `checkpointed`.
    private static func scheduleCompletionOutcome(
        forDurableRunState state: String
    ) -> (succeeded: Bool, cancelled: Bool)? {
        switch state {
        case "completed": return (true, false)
        case "failed": return (false, false)
        case "cancelled": return (false, true)
        default: return nil
        }
    }

    /// Settles the occurrence this receipt names when the durable run has
    /// ALREADY reached a completion that the live bridge could not record
    /// while the occurrence was unbound. Uses the existing
    /// `recordRunCompletion` service, so the terminal vocabulary (including
    /// the default failure/cancel text) and the idempotent `ON CONFLICT`
    /// after-success arming are exactly the live bridge's. It never binds,
    /// launches, resets a claim, or invents an outcome:
    ///
    /// - a still-live, `checkpointed` or `interrupted` run is left alone;
    /// - an occurrence that does not name this run (unbound claim) is left
    ///   alone — binding owns that transition;
    /// - an occurrence another writer already settled is left alone;
    /// - a completion write failure is surfaced as storage truth so a caller
    ///   never sees a settlement claim that did not persist. The next retry
    ///   re-reads the same terminal run and converges without a new launch.
    ///
    /// Dependents are enqueued idempotently by the completion service but are
    /// NOT drained here: the explicit selected route must not launch unrelated
    /// schedules; the ordinary due pass owns that execution.
    @discardableResult
    private func settleOccurrenceIfRunAlreadyTerminal(
        store: SQLiteTaskScheduleStore,
        occurrenceID: UUID,
        runID: UUID,
        conversationID: UUID,
        durableRun: RunRecord,
        at now: Date
    ) async throws -> Bool {
        guard durableRun.id == runID,
              durableRun.conversationID == conversationID,
              let outcome = Self.scheduleCompletionOutcome(
                forDurableRunState: durableRun.state)
        else { return false }
        // Re-read the ledger immediately before the terminal write: only a
        // bound, still-open occurrence may be settled. A concurrent writer
        // that already settled it (or a cold-start reconcile that marked it
        // interrupted) is preserved, not overwritten.
        let ledger: TaskScheduleOccurrence?
        do {
            ledger = try await store.occurrence(id: occurrenceID)
        } catch {
            throw FloeSelectedScheduleFailure.storageUnavailable
        }
        guard let ledger,
              ledger.runID == runID,
              ledger.conversationID == conversationID,
              ledger.state == .running || ledger.state == .claimed
        else { return false }
        do {
            _ = try await store.recordRunCompletion(
                runID: runID,
                succeeded: outcome.succeeded,
                cancelled: outcome.cancelled,
                summary: nil,
                at: now)
        } catch {
            throw FloeSelectedScheduleFailure.storageUnavailable
        }
        FloeLogger(category: .app).info(
            "scheduleOccurrenceSettledFromDurableRun run=\(runID.uuidString) state=\(durableRun.state) occurrence=\(occurrenceID.uuidString)"
        )
        return true
    }

    /// Post-bind convergence for the background/selected launch paths: read
    /// the durable run AFTER the occurrence was bound, because a completion
    /// that landed between the launch commit and the bind is invisible to
    /// the live bridge (the occurrence had no `run_id` when it ran). This is
    /// best-effort for the launch result: the launch itself is real and is
    /// never downgraded by a bookkeeping read/write failure, while an
    /// explicit receipt still re-reads and reports storage truth.
    private func settleBoundRunIfTerminalAfterBind(
        store: SQLiteTaskScheduleStore,
        occurrenceID: UUID,
        runID: UUID,
        conversationID: UUID
    ) async {
        let run: RunRecord?
        do {
            run = try await environment.runStore.run(id: runID)
        } catch {
            FloeLogger(category: .app).error(
                "scheduleBindSettlementReadDeferred run=\(runID.uuidString)")
            return
        }
        guard let run, run.conversationID == conversationID else { return }
        do {
            _ = try await settleOccurrenceIfRunAlreadyTerminal(
                store: store,
                occurrenceID: occurrenceID,
                runID: runID,
                conversationID: conversationID,
                durableRun: run,
                at: Date())
        } catch {
            FloeLogger(category: .app).error(
                "scheduleBindSettlementWriteDeferred run=\(runID.uuidString)")
        }
    }

    /// One pending-schedule notification per logical occurrence. A
    /// notification is informational only: it never keeps the app alive and
    /// is never scheduled repeatedly.
    private func postSchedulePendingNotification(
        schedule: TaskScheduleRecord,
        occurrence: TaskScheduleOccurrence
    ) {
        guard notificationAuthorization.canPresentAlert else { return }
        let content = UNMutableNotificationContent()
        // Inline bilingual fallback: these keys may not have reached the
        // central catalog yet, and a raw key must never reach a notification.
        content.title = FloeL10n.isChinese ? "定时任务待执行" : "Scheduled task pending"
        content.body = FloeL10n.isChinese
            ? "\(schedule.title) 已到执行时间，但尚未运行。打开 Floe 立即执行。"
            : "\(schedule.title) is due but Floe has not run it yet. Open Floe to run it."
        // The payload carries the real identity; the conversation key is
        // OMITTED (never an empty string) when no task was launched, so the
        // tap path can distinguish "route to the pending run" from "no run".
        var payload: [String: String] = [
            "workKind": BackgroundWorkKind.schedule.rawValue,
            "scheduleID": schedule.id.uuidString,
            "occurrenceID": occurrence.id.uuidString
        ]
        if let conversationID = occurrence.conversationID {
            payload["conversationID"] = conversationID.uuidString
        }
        if let runID = occurrence.runID {
            payload["runID"] = runID.uuidString
        }
        content.userInfo = payload
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "schedule.pending.\(occurrence.id.uuidString)",
            content: content,
            trigger: nil
        ))
    }

    /// Stable identifier of a schedule's ONE insurance reminder.
    static func scheduleReminderIdentifier(scheduleID: UUID) -> String {
        "schedule.reminder.\(scheduleID.uuidString)"
    }

    /// Resolves a schedule reminder link to the CONCRETE run it should open:
    /// the occurrence the reminder named, or the schedule's newest
    /// claimed/running occurrence, and only when the owning conversation is
    /// still present. Nil means there is nothing real to open.
    private func resolveScheduleRunLink(
        _ link: BackgroundWorkDeepLink
    ) async -> BackgroundWorkDeepLink? {
        guard let scheduleID = link.scheduleID else { return nil }
        let store = SQLiteTaskScheduleStore(database: environment.database)
        func concrete(_ occurrence: TaskScheduleOccurrence) -> BackgroundWorkDeepLink? {
            guard let runID = occurrence.runID,
                  let conversationID = occurrence.conversationID,
                  environment.conversationCenter.conversations.contains(where: { $0.id == conversationID })
            else { return nil }
            return BackgroundWorkDeepLink(
                kind: .modelRun, conversationID: conversationID, runID: runID)
        }
        if let occurrenceID = link.occurrenceID,
           let occurrence = try? await store.occurrence(id: occurrenceID),
           let resolved = concrete(occurrence) {
            return resolved
        }
        let occurrences = (try? await store.occurrences(scheduleID: scheduleID, limit: 10)) ?? []
        for occurrence in occurrences where occurrence.state == .claimed || occurrence.state == .running {
            if let resolved = concrete(occurrence) { return resolved }
        }
        return nil
    }

    /// Reconciles the insurance reminder set with the durable schedules:
    /// exactly one future reminder per enabled schedule (the next expected
    /// fire), removed when disabled/finished/event-armed or beyond the
    /// bounded capacity. Called on save/enable/disable/delete (through the
    /// ordinary due pass) and after every execution, before and after launch.
    private func reconcileScheduleReminders(now: Date = Date()) async {
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let schedules = (try? await store.schedules()) ?? []
        let candidates = schedules.map { record in
            let key: String
            if let next = record.nextExpectedAt {
                key = TaskSchedulePlanner.dedupeKey(for: next, record: record)
            } else {
                key = record.cadence == .afterSuccess ? "afterSuccess" : "once"
            }
            return ScheduleReminderCandidate(
                scheduleID: record.id,
                title: record.title,
                isEnabled: record.isEnabled,
                nextFireAt: record.nextExpectedAt,
                occurrenceKey: key
            )
        }
        let plan = ScheduleReminderPlanner.plan(candidates: candidates, now: now)
        let desired = Dictionary(
            uniqueKeysWithValues: plan.register.map { ($0.scheduleID, $0) })

        // Remove pending reminders that are no longer wanted (disabled,
        // finished, event-armed or trimmed by capacity). Read the actual
        // pending set so a reminder from a previous process lifetime is
        // covered too.
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        for request in pending where request.identifier.hasPrefix("schedule.reminder.") {
            guard let scheduleID = UUID(
                uuidString: String(request.identifier.dropFirst("schedule.reminder.".count))
            ), desired[scheduleID] == nil else { continue }
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: [request.identifier])
        }
        // Routed/consumed reminders must not be replayed from Notification
        // Center after they were superseded.
        if !plan.removeScheduleIDs.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: plan.removeScheduleIDs.map(Self.scheduleReminderIdentifier))
        }
        guard notificationAuthorization.canPresentAlert else { return }
        for entry in plan.register {
            let content = UNMutableNotificationContent()
            content.title = FloeL10n.isChinese ? "定时任务提醒" : "Scheduled task reminder"
            content.body = FloeL10n.isChinese
                ? "\(entry.title) 即将到执行时间。iOS 可能不会唤醒应用；打开 Floe 以确保执行。"
                : "\(entry.title) is due soon. iOS may not wake the app; open Floe to make sure it runs."
            content.userInfo = BackgroundWorkDeepLink(
                kind: .schedule,
                scheduleID: entry.scheduleID,
                occurrenceID: TaskScheduleOccurrence.stableID(
                    scheduleID: entry.scheduleID, dedupeKey: entry.occurrenceKey)
            ).userInfo
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: entry.fireAt)
            let request = UNNotificationRequest(
                identifier: Self.scheduleReminderIdentifier(scheduleID: entry.scheduleID),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
        scheduleReminderScheduleIDs = Set(plan.register.map(\.scheduleID))
    }

    /// Durable completion bridge: a scheduled run's REAL terminal state
    /// settles its occurrence, and ONLY a successful upstream run enqueues
    /// the schedules bound to it (one logical instance per upstream run).
    private func recordScheduleRunCompletion(
        runID: UUID,
        succeeded: Bool,
        message: String?,
        cancelled: Bool = false
    ) async {
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let enqueued = (try? await store.recordRunCompletion(
            runID: runID, succeeded: succeeded, cancelled: cancelled,
            summary: message, at: Date())) ?? []
        guard !enqueued.isEmpty else { return }
        // An upstream success fired after-success schedules: run the same
        // pass so they start now rather than waiting for the next wakeup.
        await runDueSchedules()
    }

    /// The system's completion-handler selector, implemented directly.
    ///
    /// Build 271 evidence (private `CRASH-271-SYMBOLICATED.md`): the faulting
    /// thread ran `@objc closure #1 in ...userNotificationCenter(_:didReceive:)`
    /// — the compiler-generated bridge of the Swift `async` convenience — when
    /// an exception raised from Foundation inside the completion path went
    /// uncaught. This method is that same Objective-C selector without the
    /// continuation bridging: the payload is parsed here (the raw dictionary
    /// never crosses an actor), the route gate runs on the main actor, and the
    /// completion handler is invoked exactly once on the main actor by
    /// `NotificationResponseIntake`, never across the route's reload/target
    /// work. The exception itself is a framework-raised Objective-C exception;
    /// this bridge makes our side of the boundary explicit and observable, it
    /// does not claim to catch a framework exception.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        NotificationResponseIntake.accept(
            identifier: request.identifier,
            payload: request.content.userInfo,
            completion: completionHandler,
            routing: self
        )
    }

    /// Routes one parsed notification deep link behind four gates: duplicate
    /// suppression, cold-launch readiness (database + active scene + mounted
    /// navigation subscribers) and authoritative target existence.
    /// `isRetry` is true for a deferred route being flushed: it skips the
    /// dedup window, which the original attempt already consumed, and must
    /// carry the generation of the tap that created it. A retry whose
    /// generation a newer tap superseded is rejected here, before any
    /// dedup/readiness/target work.
    @MainActor
    private func handleNotificationRoute(
        key: String,
        link: BackgroundWorkDeepLink,
        identifier: String,
        isRetry: Bool = false,
        retryGeneration: UInt64? = nil
    ) {
        if !isRetry, let last = recentNotificationRoutes[key],
           Date().timeIntervalSince(last) < Self.duplicateNotificationRouteWindow {
            // A repeat tap of the route that is already being handled. It must
            // not supersede the in-flight request: the request owns the single
            // durable event and will consume it exactly once when it finishes.
            NotificationResponseTrace.mark(.suppressed, kind: link.kind)
            FloeLogger(category: .app).info(
                "notificationRouteIgnored reason=duplicate key=\(key)"
            )
            return
        }
        let generation: UInt64
        if isRetry {
            // A deferred route keeps the generation of the tap that created
            // it. Once a newer genuine tap began, the stale route must not
            // navigate under that newer generation.
            guard let retryGeneration,
                  notificationRouteRequest.accepts(generation: retryGeneration) else {
                NotificationResponseTrace.mark(.suppressed, kind: link.kind)
                FloeLogger(category: .app).info(
                    "notificationRouteIgnored reason=staleDeferredGeneration key=\(key)"
                )
                return
            }
            generation = retryGeneration
        } else {
            // A genuine new tap begins a new generation and supersedes any
            // still-deferred route from an older tap.
            generation = notificationRouteRequest.begin()
        }
        guard notificationRoutePersistenceReady, effectiveScenePhase == .active,
              navigationSubscribersReady else {
            // Cold launch (or a transition that has not produced a mounted,
            // active root view yet): hold the single pending slot and retry
            // when the app is actually ready. Persistence + active scene alone
            // are a proxy; `navigationSubscribersReady` is the real evidence
            // that the root view hosting the deep-link subscribers exists.
            notificationRouteRequest.deferRoute(
                key: key,
                link: link,
                identifier: identifier,
                generation: generation
            )
            NotificationResponseTrace.mark(.deferred, kind: link.kind)
            FloeLogger(category: .app).info(
                "notificationRouteDeferred key=\(key) generation=\(generation) persistenceReady=\(self.notificationRoutePersistenceReady) scene=\(String(describing: self.effectiveScenePhase)) navigationReady=\(self.navigationSubscribersReady)"
            )
            return
        }
        recentNotificationRoutes[key] = Date()
        pruneNotificationRouteBookkeeping()
        Task { [weak self] in
            guard let self else { return }
            // A foreground launch reloads the task list before this check so
            // a just-restored conversation is not mistaken for a deleted one.
            await self.environment.conversationCenter.reload()
            // A schedule reminder routes to its ACTUAL pending/running task.
            // The tap itself is a real user action: give the due occurrence
            // one execution chance before concluding there is nothing to
            // open. Never a false destination.
            var effectiveLink = link
            if effectiveLink.kind == .schedule {
                if let resolved = await self.resolveScheduleRunLink(effectiveLink) {
                    effectiveLink = resolved
                } else {
                    await self.runDueSchedulesNow()
                    if let resolved = await self.resolveScheduleRunLink(effectiveLink) {
                        effectiveLink = resolved
                    }
                }
            }
            let target = await self.resolveDeepLinkTarget(effectiveLink)
            await MainActor.run {
                // A newer tap supersedes this in-flight check: navigating
                // now would race the newer route.
                guard self.notificationRouteRequest.accepts(generation: generation) else {
                    NotificationResponseTrace.mark(.suppressed, kind: link.kind)
                    FloeLogger(category: .app).info(
                        "notificationRouteIgnored reason=staleGeneration key=\(key)"
                    )
                    return
                }
                self.finishNotificationRoute(
                    key: key,
                    link: effectiveLink,
                    identifier: identifier,
                    target: target,
                    generation: generation
                )
            }
        }
    }

    /// Resolves whether a notification's target can still be opened, using
    /// only authoritative registry/runtime reads:
    /// - the environment registry record store (D side) answers existence;
    /// - the Linux runtime's ownership seam (B2, `ownsLinuxEnvironment`)
    ///   answers existence while stopped.
    /// Neither read starts a guest. A stopped environment is existence; an
    /// unreadable seam is unknown — never deleted.
    private func resolveDeepLinkTarget(_ link: BackgroundWorkDeepLink) async -> TaskDeepLinkTargetState {
        switch link.kind {
        case .modelRun:
            guard let conversationID = link.conversationID else {
                // No identity to open. The event is still consumed with an
                // honest "cannot open" note instead of posting a dead route.
                return .unknown
            }
            // A deleted conversation must prompt, never route: the workbench
            // selection would point at a record the UI cannot load.
            let exists = environment.conversationCenter.conversations
                .contains { $0.id == conversationID }
            return exists ? .exists : .missing
        case .schedule:
            // Reached only when no concrete run could be resolved (the link
            // is normally rewritten to .modelRun first); there is no separate
            // schedule destination to promise.
            return .unknown
        case .linuxSession, .linuxService:
            // No environment id: the family-level link opens the environment
            // list, which always exists. Nothing about a stopped/deleted
            // environment is claimed.
            guard let environmentID = link.environmentID else { return .exists }
            // Authoritative record read first: it is what separates a deleted
            // environment from a stopped one. `nil` means the registry could
            // not answer, so deletion must not be claimed.
            let recordExists = await environmentRecordExists(environmentID: environmentID)
            guard let controller = FloePlatformServices.shared.linuxGuestController() else {
                // No Linux runtime in this build: the registry still proves
                // existence, but liveness is unknown, so nothing is reported
                // as running or stopped.
                return TaskDeepLinkTargetState.linuxEnvironment(
                    recordExists: recordExists,
                    ownedByRuntime: nil,
                    guestIsRunning: nil
                )
            }
            let owned = await FloePlatformServices.shared
                .linuxEnvironmentOwned(id: environmentID)
            var running: Bool?
            if owned {
                // Status for an owned environment is a read on the runtime's
                // registry; it never starts a guest just to answer.
                running = await controller.guestStatus(environmentID: environmentID).running
            }
            return TaskDeepLinkTargetState.linuxEnvironment(
                recordExists: recordExists,
                ownedByRuntime: owned,
                guestIsRunning: running
            )
        }
    }

    /// Authoritative environment-record read (D side). Loads the registry the
    /// same idempotent way every environment surface does; the load never
    /// starts a guest. `nil` means the read failed and the caller must not
    /// claim deletion.
    private func environmentRecordExists(environmentID: String) async -> Bool? {
        do {
            try await environment.environmentRegistry.prepare()
        } catch {
            FloeLogger(category: .app).warning(
                "notificationRouteEnvironmentRegistryUnavailable error=\(error.localizedDescription)"
            )
            return nil
        }
        return await environment.environmentRegistry.record(id: environmentID) != nil
    }

    @MainActor
    private func finishNotificationRoute(
        key: String,
        link: BackgroundWorkDeepLink,
        identifier: String,
        target: TaskDeepLinkTargetState,
        generation: UInt64
    ) {
        let routing = TaskNotificationDecision.resolveRouting(
            persistenceReady: notificationRoutePersistenceReady,
            hasActiveScene: effectiveScenePhase == .active,
            navigationSubscribersReady: navigationSubscribersReady,
            isDuplicate: false,
            target: target
        )
        switch routing {
        case .routeNow:
            Self.route(deepLink: link)
            NotificationResponseTrace.mark(.routed, kind: link.kind)
        case .deferUntilReady:
            // The route stays owned by the tap that created it, so a newer
            // tap supersedes it instead of letting it replay later.
            let stored = notificationRouteRequest.deferRoute(
                key: key,
                link: link,
                identifier: identifier,
                generation: generation
            )
            NotificationResponseTrace.mark(.deferred, kind: link.kind)
            if !stored {
                FloeLogger(category: .app).info(
                    "notificationRouteDeferredRejected reason=staleGeneration key=\(key)"
                )
            }
        case .ignoreDuplicate:
            NotificationResponseTrace.mark(.suppressed, kind: link.kind)
        case .promptMissingTarget, .promptStoppedTarget, .promptUnavailableTarget:
            // The user is told why the target cannot open; nothing claims a
            // navigation that did not happen.
            NotificationResponseTrace.mark(.unreachableTarget, kind: link.kind)
            presentUnreachableTargetPrompt(
                link: link,
                target: routing.promptedTargetState ?? .unknown,
                identifier: identifier
            )
        }
        // One durable-event rule for every outcome: an outcome that navigated
        // or told the user why it could not consumes the event; a deferred or
        // suppressed outcome keeps it queued for a later attempt (a flushing
        // duplicate would otherwise alert twice).
        if routing.consumesDurableEvent {
            notificationOutbox.discard(identifier: identifier)
            userHandledNotificationIdentifiers[identifier] = Date()
            persistNotificationOutbox()
        }
    }

    /// Retries the deferred notification route once the database, an active
    /// scene and the mounted navigation subscribers are all ready. Call sites:
    /// foreground transition, authorization refresh and the end of launch
    /// reconciliation. A not-ready flush leaves the deferred route untouched;
    /// a ready flush hands it off only while its originating generation is
    /// still current, so a route a newer tap superseded can never replay.
    @MainActor
    private func flushPendingNotificationRoute() {
        let ready = notificationRoutePersistenceReady
            && effectiveScenePhase == .active
            && navigationSubscribersReady
        let hadPending = notificationRouteRequest.pending != nil
        guard let pending = notificationRouteRequest.takePendingForRetry(ready: ready) else {
            if hadPending, ready {
                // The deferred route was superseded by a newer tap: it is
                // dropped rather than replayed under the newer generation.
                FloeLogger(category: .app).info(
                    "notificationRouteDropped reason=supersededByNewerTap"
                )
            }
            return
        }
        handleNotificationRoute(
            key: pending.key,
            link: pending.link,
            identifier: pending.identifier,
            isRetry: true,
            retryGeneration: pending.generation
        )
    }

    private func pruneNotificationRouteBookkeeping() {
        let cutoff = Date().addingTimeInterval(-Self.duplicateNotificationRouteWindow)
        recentNotificationRoutes = recentNotificationRoutes.filter { $0.value > cutoff }
        userHandledNotificationIdentifiers = userHandledNotificationIdentifiers.filter { $0.value > cutoff }
    }

    /// A notification pointed at a target that cannot be opened right now.
    /// Three honest answers, never a crash and never a false deletion claim:
    /// - missing: the authoritative record is gone;
    /// - stopped: the environment exists but nothing is running for it;
    /// - unknown: existence could not be confirmed.
    /// The alert carries the safe identity (never the dead target) so tapping
    /// it repeats exactly this safe behavior. Families with a real list
    /// listener open that list — focused on the environment only while it is
    /// known to exist; a route with no listener stays banner-only instead of
    /// promising a destination that never opens.
    @MainActor
    private func presentUnreachableTargetPrompt(
        link: BackgroundWorkDeepLink,
        target: TaskDeepLinkTargetState,
        identifier: String
    ) {
        let title: String
        let body: String
        switch link.kind {
        case .schedule:
            title = String(localized: "notification.unreachable.task.title")
            body = FloeL10n.isChinese
                ? "该定时任务当前没有运行中的任务。打开 Floe 查看它的计划与历史。"
                : "The scheduled task is not running right now. Open Floe to see its schedule and history."
        case .modelRun:
            title = String(localized: "notification.unreachable.task.title")
            body = String(localized: "notification.unreachable.task.body")
        case .linuxSession, .linuxService:
            title = String(localized: "notification.unreachable.environment.title")
            switch target {
            case .missing:
                body = String(localized: "notification.unreachable.environment.deleted_body")
            case .existsStopped:
                body = String(localized: "notification.unreachable.environment.stopped_body")
            case .exists, .unknown:
                body = String(localized: "notification.unreachable.environment.unknown_body")
            }
        }
        // Focus the list on the environment only when it is known to exist;
        // a deleted or unconfirmed id is opened as an unfocused list.
        let focusedEnvironmentID = target == .existsStopped ? link.environmentID : nil
        let hasListFallback = TaskNotificationDecision.hasSafeListFallback(kind: link.kind)
        let safeLink = BackgroundWorkDeepLink(
            kind: link.kind,
            environmentID: hasListFallback ? focusedEnvironmentID : nil
        )
        TaskBannerCenter.shared.present(
            title: title,
            body: body,
            deepLink: safeLink
        )
        if hasListFallback {
            Self.route(deepLink: safeLink)
        }
        FloeLogger(category: .app).warning(
            "notificationRouteUnreachable identifier=\(identifier) kind=\(link.kind.rawValue) target=\(target.rawValue)"
        )
    }

    /// Routes a deep link to exactly one destination. The payload identity
    /// (kind + ids) decides where it goes; nothing is inferred from titles.
    nonisolated static func route(deepLink: BackgroundWorkDeepLink, userInfo: [AnyHashable: Any] = [:]) {
        switch deepLink.kind {
        case .schedule:
            // No separate destination: a schedule reminder is always resolved
            // to its concrete run first; an unresolved one opens the app,
            // which is already on Home.
            return
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

extension BackgroundRunCoordinator: NotificationResponseRouting {
    /// Main-actor conformance driven by `NotificationResponseIntake`: the real
    /// duplicate suppression, cold-launch readiness, generation ownership and
    /// authoritative target lookup run here, exactly as before. Only the
    /// parsed `Sendable` route reaches this method — never the raw `Any`-valued
    /// notification dictionary and never the `UNNotificationResponse`.
    func routeNotificationResponse(
        key: String,
        link: BackgroundWorkDeepLink,
        identifier: String
    ) {
        handleNotificationRoute(key: key, link: link, identifier: identifier)
    }
}

/// Holds the system completion handler for the media-artifact background
/// session until the system finish event HAS arrived AND every async
/// settle/fail the coordinator registered has drained; the completion then
/// runs exactly once on the main thread (`BackgroundDownloadEventSettlement`).
/// The launch hook keeps calling `register` unchanged; the coordinator drives
/// event accounting through `settlement`.
final class MediaArtifactBackgroundEvents: @unchecked Sendable {
    static let shared = MediaArtifactBackgroundEvents()
    let settlement = BackgroundDownloadEventSettlement(name: "media-artifacts")

    private init() {}

    func register(_ completion: @escaping () -> Void) {
        settlement.registerSystemCompletionHandler(completion)
    }

    /// Atomic register + bounded tracked bootstrap (see
    /// `BackgroundDownloadEventSettlement.registerSystemCompletionHandler(_:bootstrap:)`).
    func register(
        _ completion: @escaping () -> Void,
        bootstrap: @escaping @Sendable () async -> Void
    ) {
        settlement.registerSystemCompletionHandler(completion, bootstrap: bootstrap)
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
            throw FloeError.validationFailed(FloeL10n.l("platform.background_run_coordinator.the_image_service_should_return_images", expected, images.count)
            )
        }
        guard images.allSatisfy({ $0.count <= maximumImageBytes }) else {
            throw FloeError.validationFailed(FloeL10n.l("platform.background_run_coordinator.the_generated_image_exceeds_24_mib"))
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

/// Frozen identity of ONE design-creative first-result submission. Every
/// field is captured BEFORE the provider call: the durable job row stores the
/// original target owner/environment/task identity, and reopening the design
/// workflow reconstructs the same idempotency key from the durable creative
/// request so the SAME original job is found instead of a second paid submit.
struct DesignCreativeImageSubmission: Sendable {
    var targetStableKey: String
    var ownerID: String
    var requestID: String
    var environmentID: String?
    var originConversationID: UUID?
    var originRunID: UUID?
    var owner: MediaJobOwner
    var providerID: UUID
    var modelID: UUID
    var prompt: String
    var selection: ImageGenerationSelection
    var displayNameStem: String
    var idempotencyKey: String
    /// The owner envelope revision the user confirmed at SUBMISSION time.
    /// Persisted on the job row so a later reopen binds against the ORIGINAL
    /// revision instead of silently capturing whatever the owner holds now.
    var frozenOwnerRevision: Int64
}

/// Honest result of one durable design-creative image submission.
struct DesignCreativeImageOutcome: Sendable {
    var job: MediaGenerationJob
    /// The REAL content-addressed library asset, present only once the output
    /// was validated and committed. nil with `awaitingUnknownOutcome` means an
    /// earlier submission of this exact operation exists whose remote outcome
    /// is unknown: it must never be resubmitted automatically.
    var asset: CreativeAssetRecord?
    var deduplicated: Bool
    var awaitingUnknownOutcome: Bool
    /// True when the job records a published result (terminal `.ready` or a
    /// recorded `localAssetID`) whose asset row/file no longer resolves. The
    /// caller must show an explicit recovery state; no bind is ever claimed
    /// from a stale identity and no new provider call happens automatically.
    var resultMissing: Bool = false
}

/// The exact frozen request persisted on the durable job row (audit/readback;
/// the same target identity is reconstructible from the owner envelope).
struct DesignCreativeImageRequestPayload: Codable, Sendable {
    var targetStableKey: String
    var ownerID: String
    var requestID: String
    var environmentID: String?
    var originConversationID: String?
    var providerID: UUID
    var modelID: UUID
    var prompt: String
    var selection: ImageGenerationSelection
    /// The owner envelope revision confirmed at submission time. A reopen
    /// binds against THIS revision; if the owner moved meanwhile the bind
    /// conflicts and the result stays retained for explicit resolution.
    var frozenOwnerRevision: Int64
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
                    ? FloeL10n.l("platform.background_run_coordinator.choose_a_usable_image_generation_model")
                    : FloeL10n.l("platform.background_run_coordinator.the_selected_model_or_provider_does")
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
            throw FloeError.validationFailed(FloeL10n.l("platform.background_run_coordinator.the_selected_image_model_supports_up", maximumReferences, sourceImages.count)
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
            throw FloeError.validationFailed(FloeL10n.l("platform.background_run_coordinator.the_selected_image_model_can_generate", maximumOutputs, requestedOutputCount)
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
                        ? FloeL10n.l("platform.background_run_coordinator.generate_image", prepared.index + 1) : FloeL10n.l("files.files_view.generate_image"),
                    mimeType: prepared.isPNG ? "image/png" : "image/jpeg",
                    localRelativePath: prepared.candidateRelativePath,
                    byteCount: Int64(prepared.data.count),
                    tags: [FloeL10n.l("platform.background_run_coordinator.generate_content")],
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

    // MARK: - Design creative first result (durable job, real asset)

    /// Submits ONE design-creative first-result image through the SAME durable
    /// media job store every other provider job uses:
    ///
    /// 1. the job row (owner/origin run/idempotency key + the frozen request)
    ///    is committed BEFORE the provider call, so a process death leaves an
    ///    honest record instead of a lost submission;
    /// 2. an identical active operation is deduplicated and never paid twice;
    /// 3. the provider output is format/size validated and committed as a REAL
    ///    content-addressed `CreativeAssetStore` asset BEFORE the job becomes
    ///    `.ready`, so the caller binds an actual asset UUID;
    /// 4. a transport failure that may have reached the provider leaves the
    ///    job `.preparing` with no provider task id — an UNKNOWN outcome that
    ///    is never resubmitted automatically.
    ///
    /// `perform` is the provider-call seam: production resolves the user's
    /// configured image route through `ConversationCenter.performAgentImage`;
    /// tests inject a deterministic double (no paid call).
    func submitDesignCreativeImage(
        _ submission: DesignCreativeImageSubmission,
        replacingMissingResultOf missingJobID: UUID? = nil,
        perform: (@MainActor @Sendable (
            _ prompt: String, _ modelID: UUID,
            _ selection: ImageGenerationSelection
        ) async throws -> RemoteImageResult)? = nil
    ) async throws -> DesignCreativeImageOutcome {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let provider = try await environment.configurationStore.provider(id: submission.providerID),
              let model = try await environment.configurationStore.model(id: submission.modelID),
              provider.id == submission.providerID, model.id == submission.modelID,
              provider.isEnabled, model.isEnabled else {
            throw FloeError.invalidConfiguration(FloeL10n.l(
                "platform.background_run_coordinator.choose_a_usable_image_generation_model"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(DesignCreativeImageRequestPayload(
            targetStableKey: submission.targetStableKey,
            ownerID: submission.ownerID,
            requestID: submission.requestID,
            environmentID: submission.environmentID,
            originConversationID: submission.originConversationID?.uuidString,
            providerID: provider.id, modelID: model.id,
            prompt: submission.prompt, selection: submission.selection,
            frozenOwnerRevision: submission.frozenOwnerRevision))
        // Self-idempotency: an existing job for this EXACT operation is never
        // paid for twice. A ready result is returned, an unresolved
        // submission is reported (unknown / in flight); only a definite local
        // terminal failure — or an EXPLICIT user-acknowledged replacement of
        // a result whose asset row/file no longer resolves — may pass this
        // point.
        if let existing = try? await store.ownedJob(
            idempotencyKey: submission.idempotencyKey) {
            var proceedPastStaleResult = false
            if let missingJobID, existing.job.id == missingJobID {
                proceedPastStaleResult = await designCreativeResultIsMissing(owned: existing)
            }
            if !proceedPastStaleResult,
               existing.job.state == .ready || !existing.job.state.isTerminal {
                return try await existingDesignCreativeOutcome(owned: existing)
            }
        }
        let job = MediaGenerationJob(
            providerID: provider.id, modelID: model.id, mediaKind: .image,
            credentialReference: provider.secretRef,
            canvasID: nil, documentID: nil,
            sourceNodeIDs: [], resultNodeID: UUID(),
            requestJSON: payload)
        let creation = try await store.createJob(
            job, owner: submission.owner,
            originRunID: submission.originRunID,
            idempotencyKey: submission.idempotencyKey)
        if creation.deduplicated {
            return try await existingDesignCreativeOutcome(
                owned: creation.owned)
        }
        // A cancellation observed BEFORE the provider call proves nothing was
        // dispatched yet. A cancellation observed from the call itself is NOT
        // a provider cancellation: stop-waiting only, the remote may already
        // have generated and charged a result.
        if Task.isCancelled {
            _ = try? await store.transition(id: job.id, to: .cancelled) {
                $0.lastError = FloeL10n.l("design.owner.generate_canceled")
                $0.nextPollAt = nil
            }
            throw CancellationError()
        }
        let result: RemoteImageResult
        do {
            if let perform {
                result = try await perform(submission.prompt, model.id, submission.selection)
            } else {
                let routed = try await environment.conversationCenter.performAgentImage(
                    operation: .generate, prompt: submission.prompt, sourceImages: [],
                    modelID: model.id, selection: submission.selection, count: 1)
                result = routed.0
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                // Stop-waiting only. The request may already have reached the
                // provider, so the job stays UNRESOLVED (unknown) with the
                // honest reason; it is never resubmitted automatically and a
                // new attempt requires an explicit acknowledged discard.
                _ = try? await store.transition(id: job.id, to: .preparing) {
                    $0.lastError = FloeL10n.l("design.owner.generate_stopped_unknown")
                }
            } else if let remote = error as? RemoteImageError,
                      case .providerRejected = remote {
                // The provider answered with a definite rejection: no result
                // was produced, so the job is truthfully failed.
                _ = try? await store.transition(id: job.id, to: .failed) {
                    $0.lastError = error.localizedDescription
                    $0.nextPollAt = nil
                }
            }
            // Any other failure (transport/timeout/invalid response) leaves
            // the job `.preparing` with no provider task id: UNKNOWN, never
            // resubmitted automatically.
            throw error
        }
        let images = try MediaGenerationImageBatchContract.validatedImages(
            result.images, requestedOutputCount: 1)
        guard let data = images.first,
              let encodedFormat = Self.designCreativeImageFormat(of: data) else {
            throw FloeError.validationFailed(FloeL10n.l("design.owner.generate_unverifiable_format"))
        }
        let digest = FloeDigest.sha256Hex(data)
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let candidateID = UUID()
        let isPNG = encodedFormat == "png"
        let candidateRelative = MediaGenerationAssetReusePolicy.generatedRelativePath(
            assetID: candidateID, isPNG: isPNG)
        let candidateURL = try MediaGenerationAssetReusePolicy.localURL(
            relativePath: candidateRelative, applicationSupportRoot: support)
        // Tracks whether the candidate file is already referenced by a
        // committed canonical row (or proven removable): a later failure must
        // never delete a published asset.
        var publishedCanonical: CreativeAssetRecord?
        var candidateHandled = false
        do {
            try FileManager.default.createDirectory(
                at: candidateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: candidateURL, options: .atomic)
            // The canonical row is returned as-is: identical content already
            // in the library keeps ITS OWN id/path (no aliasing, no orphan).
            let canonical = try await environment.creativeAssetStore.saveResolvingCanonical(
                CreativeAssetRecord(
                    id: candidateID, contentHash: digest, kind: .image,
                    displayName: Self.designCreativeDisplayName(
                        stem: submission.displayNameStem, format: encodedFormat),
                    mimeType: Self.designCreativeMimeType(for: encodedFormat),
                    localRelativePath: candidateRelative,
                    byteCount: Int64(data.count),
                    tags: [FloeL10n.l("platform.background_run_coordinator.generate_content")],
                    referenceCount: 0))
            publishedCanonical = canonical
            let candidateIsCanonical = canonical.id == candidateID
                && (canonical.localRelativePath ?? "") == candidateRelative
            if candidateIsCanonical {
                // The committed row OWNS this exact file: a later failure
                // must retain it, never delete it as "unreferenced".
                candidateHandled = true
            } else {
                let canonicalRelative = canonical.localRelativePath ?? candidateRelative
                let canonicalURL = try MediaGenerationAssetReusePolicy.localURL(
                    relativePath: canonicalRelative, applicationSupportRoot: support)
                if !FileManager.default.fileExists(atPath: canonicalURL.path) {
                    try FileManager.default.createDirectory(
                        at: canonicalURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try data.write(to: canonicalURL, options: .atomic)
                }
                if canonicalURL != candidateURL,
                   FileManager.default.fileExists(atPath: candidateURL.path) {
                    try? FileManager.default.removeItem(at: candidateURL)
                    candidateHandled = true
                }
            }
            // Persist the published-result association BEFORE attempting the
            // terminal `.ready` transition: if that transition fails (a
            // concurrent close, or a store write error), the still-unresolved
            // row names the REAL asset, so a reopen reconciles the SAME
            // output without any new provider call.
            _ = try? await store.transition(id: job.id, to: .preparing) {
                $0.localAssetID = canonical.id
                $0.assetReferences = [canonical.id]
            }
            let ready = try await store.transition(id: job.id, to: .ready) {
                $0.localAssetID = canonical.id
                $0.assetReferences = [canonical.id]
                $0.lastError = nil
                $0.nextPollAt = nil
                $0.estimatedCompletionAt = Date()
            }
            return DesignCreativeImageOutcome(
                job: ready, asset: canonical,
                deduplicated: false, awaitingUnknownOutcome: false)
        } catch {
            // Remove ONLY a proven-unreferenced temp: the candidate is kept
            // when a committed canonical row points at it (or when it may be
            // the only readable copy of the published bytes).
            if !candidateHandled,
               FileManager.default.fileExists(atPath: candidateURL.path) {
                let canonicalFileElsewhere: Bool
                if let canonical = publishedCanonical,
                   let relative = canonical.localRelativePath,
                   let url = try? MediaGenerationAssetReusePolicy.localURL(
                        relativePath: relative, applicationSupportRoot: support) {
                    canonicalFileElsewhere = FileManager.default.fileExists(atPath: url.path)
                } else {
                    canonicalFileElsewhere = false
                }
                if publishedCanonical == nil || canonicalFileElsewhere {
                    try? FileManager.default.removeItem(at: candidateURL)
                }
            }
            if !(error is CancellationError) {
                // The provider DID return output; the local publish failed.
                // Keep the job unresolved with the real reason (never a
                // silently failed terminal state), but persist the PUBLISHED
                // result association (localAssetID/assetReferences) on the
                // SAME row first: a reopen can then reconcile the exact same
                // output to `.ready` without any new provider call, instead of
                // losing which asset was produced. It is not resubmitted
                // automatically, and the user may still explicitly discard it.
                let association: CreativeAssetRecord? = publishedCanonical
                _ = try? await store.transition(id: job.id, to: .preparing) {
                    if let association {
                        $0.localAssetID = association.id
                        $0.assetReferences = [association.id]
                    }
                    $0.lastError = error.localizedDescription
                }
            }
            throw error
        }
    }

    /// Result for an already-existing job with the same submitting-operation
    /// identity. A `.ready` job returns its committed asset; an UNRESOLVED
    /// job that already recorded a published `localAssetID` (the `.ready`
    /// transition failed after the asset row committed) is repaired to
    /// `.ready` and returns the SAME asset — no new provider call and no
    /// lost association. Any other non-terminal state is reported as pending
    /// with `awaitingUnknownOutcome` when no provider task id was ever
    /// recorded.
    private func existingDesignCreativeOutcome(
        owned: OwnedMediaGenerationJob
    ) async throws -> DesignCreativeImageOutcome {
        let job = owned.job
        // A job that records a published result must still RESOLVE (row + the
        // contained file). A dangling association is an explicit recoverable
        // missing-result state — never a silent re-dispatch, never a bind
        // from the stale identity.
        if let assetID = job.localAssetID {
            if let asset = try? await environment.creativeAssetStore.asset(id: assetID),
               !designCreativeAssetFileMissing(asset) {
                if job.state == .ready {
                    return DesignCreativeImageOutcome(
                        job: job, asset: asset,
                        deduplicated: true, awaitingUnknownOutcome: false)
                }
                if !job.state.isTerminal {
                    let store = MediaGenerationJobStore(database: environment.database)
                    let repaired = try? await store.transition(id: job.id, to: .ready) {
                        $0.localAssetID = asset.id
                        $0.assetReferences = [asset.id]
                        $0.lastError = nil
                        $0.nextPollAt = nil
                        $0.estimatedCompletionAt = Date()
                    }
                    return DesignCreativeImageOutcome(
                        job: repaired ?? job, asset: asset,
                        deduplicated: true, awaitingUnknownOutcome: false)
                }
                return DesignCreativeImageOutcome(
                    job: job, asset: asset,
                    deduplicated: true, awaitingUnknownOutcome: false)
            }
            return DesignCreativeImageOutcome(
                job: job, asset: nil, deduplicated: true,
                awaitingUnknownOutcome: false, resultMissing: true)
        }
        let unknown = !job.state.isTerminal && job.providerTaskID == nil
        return DesignCreativeImageOutcome(
            job: job, asset: nil,
            deduplicated: true, awaitingUnknownOutcome: unknown)
    }

    /// The contained-file half of a recorded result: a row whose local file is
    /// gone is as unusable as a deleted row.
    private func designCreativeAssetFileMissing(_ asset: CreativeAssetRecord) -> Bool {
        guard let relative = asset.localRelativePath, !relative.isEmpty,
              !relative.contains(".."),
              let root = try? FloeArtifactStore.root() else { return true }
        return !FileManager.default.fileExists(
            atPath: root.appendingPathComponent(relative).path)
    }

    /// True when the job records a published result whose row/file no longer
    /// resolves on this device. `.ready` without a readable row is missing by
    /// definition; a genuine non-terminal in-flight submission is not.
    private func designCreativeResultIsMissing(owned: OwnedMediaGenerationJob) async -> Bool {
        let job = owned.job
        guard let assetID = job.localAssetID else { return false }
        guard let asset = try? await environment.creativeAssetStore.asset(id: assetID) else {
            return true
        }
        return designCreativeAssetFileMissing(asset)
    }

    /// Explicit, user-acknowledged REPLACEMENT of a missing published result:
    /// verifies the recorded result is really unresolvable here, then performs
    /// ONE new durable submission under the SAME request identity. The stale
    /// ready row/id is never reused and this never runs automatically — the
    /// caller must have obtained the user's confirmation.
    func replaceMissingDesignCreativeResult(
        jobID: UUID,
        perform: (@MainActor @Sendable (
            _ prompt: String, _ modelID: UUID,
            _ selection: ImageGenerationSelection
        ) async throws -> RemoteImageResult)? = nil
    ) async throws -> DesignCreativeImageOutcome {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let owned = try await store.ownedJob(id: jobID) else {
            throw MediaGenerationJobStoreError.missingJob(jobID)
        }
        guard await designCreativeResultIsMissing(owned: owned) else {
            throw FloeError.validationFailed(
                FloeL10n.l("design.owner.generate_result_not_missing"))
        }
        let payload = try JSONDecoder().decode(
            DesignCreativeImageRequestPayload.self, from: owned.job.requestJSON)
        let submission = DesignCreativeImageSubmission(
            targetStableKey: payload.targetStableKey,
            ownerID: payload.ownerID,
            requestID: payload.requestID,
            environmentID: payload.environmentID,
            originConversationID: payload.originConversationID.flatMap { UUID(uuidString: $0) },
            originRunID: owned.originRunID,
            owner: owned.owner,
            providerID: payload.providerID,
            modelID: payload.modelID,
            prompt: payload.prompt,
            selection: payload.selection,
            displayNameStem: "result",
            idempotencyKey: owned.idempotencyKey
                ?? "design-creative-image-replacement-\(jobID.uuidString.lowercased())",
            frozenOwnerRevision: payload.frozenOwnerRevision)
        return try await submitDesignCreativeImage(
            submission, replacingMissingResultOf: jobID, perform: perform)
    }

    /// Explicitly ACKNOWLEDGED discard of a MISSING published result: only a
    /// job whose recorded asset row/file really no longer resolves is closed,
    /// with the honest reason. Canonical bytes and user drafts are untouched
    /// and nothing is ever resent. The terminal record is rewritten through
    /// the existing store save (the normal lifecycle guard intentionally
    /// forbids terminal → terminal transitions).
    func discardMissingDesignCreativeResult(jobID: UUID) async throws {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let owned = try await store.ownedJob(id: jobID) else {
            throw MediaGenerationJobStoreError.missingJob(jobID)
        }
        guard await designCreativeResultIsMissing(owned: owned) else {
            throw FloeError.validationFailed(
                FloeL10n.l("design.owner.generate_result_not_missing"))
        }
        var job = owned.job
        job.state = .cancelled
        job.lastError = FloeL10n.l("design.owner.generate_missing_discarded")
        job.nextPollAt = nil
        job.updatedAt = Date()
        try await store.save(
            job, owner: owned.owner, originRunID: owned.originRunID,
            idempotencyKey: owned.idempotencyKey)
    }

    /// Reconciliation entry for a reopen: loads the durable submission by its
    /// operation identity and returns its outcome WITHOUT dispatching a
    /// provider call. A published-but-unresolved record is repaired to
    /// `.ready` (same asset); nil when no job exists for the key.
    func recoverDesignCreativeImage(
        idempotencyKey: String
    ) async throws -> DesignCreativeImageOutcome? {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let existing = try await store.ownedJob(idempotencyKey: idempotencyKey) else {
            return nil
        }
        return try await existingDesignCreativeOutcome(owned: existing)
    }

    /// Explicitly ACKNOWLEDGED discard of an unresolved design-creative job
    /// (the user confirmed the duplicate-charge warning). This closes the
    /// LOCAL record only: it never claims the provider cancelled or refunded
    /// anything, and the recorded reason says so. A terminal job is refused.
    func discardUnknownDesignCreativeImage(jobID: UUID) async throws {
        let store = MediaGenerationJobStore(database: environment.database)
        guard let owned = try await store.ownedJob(id: jobID) else {
            throw MediaGenerationJobStoreError.missingJob(jobID)
        }
        guard !owned.job.state.isTerminal else {
            throw RemoteVideoError.invalidRequest(FloeL10n.l(
                "platform.background_run_coordinator.the_task_already_ended_and_cannot",
                owned.job.state.rawValue))
        }
        _ = try await store.transition(id: jobID, to: .cancelled) {
            $0.lastError = FloeL10n.l("design.owner.generate_discarded_unknown")
            $0.nextPollAt = nil
        }
    }

    /// Sniffs the REAL encoded image format from the return bytes (never from
    /// the prompt or content type).
    static func designCreativeImageFormat(of data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if data.starts(with: Array("GIF8".utf8)) { return "gif" }
        if data.count >= 12, data.starts(with: Array("RIFF".utf8)) {
            let chunk = data.subdata(in: 8..<12)
            if chunk == Data("WEBP".utf8) { return "webp" }
        }
        return nil
    }

    static func designCreativeMimeType(for format: String) -> String {
        switch format {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }

    static func designCreativeDisplayName(stem: String, format: String) -> String {
        let sanitized = stem
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(sanitized.prefix(48))
        return "\(bounded.isEmpty ? "design" : bounded).\(format)"
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
                throw RemoteVideoError.requestFailed(FloeL10n.l("platform.background_run_coordinator.the_task_was_canceled_before_provider")
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
                    $0.lastError = FloeL10n.l("platform.background_run_coordinator.the_result_download_link_has_expired")
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
                        $0.lastError = FloeL10n.l("platform.background_run_coordinator.the_provider_reported_completion_but_returned")
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
            throw RemoteVideoError.invalidRequest(FloeL10n.l("platform.background_run_coordinator.the_task_already_ended_and_cannot", job.state.rawValue)
            )
        }
        guard let taskID = job.providerTaskID else {
            // The provider call was never confirmed locally. Never claim a
            // remote cancellation; close the durable job honestly.
            _ = try await store.transition(id: jobID, to: .cancelled) {
                $0.nextPollAt = nil
                $0.lastError = FloeL10n.l("platform.background_run_coordinator.the_provider_task_id_was_not")
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
                    throw RemoteVideoError.requestFailed(FloeL10n.l("platform.background_run_coordinator.the_task_completed_before_it_was"))
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
                $0.lastError = FloeL10n.l("platform.background_run_coordinator.cancellation_failed", error.localizedDescription)
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
        var detail = FloeL10n.l("platform.background_run_coordinator.the_generation_result_was_saved_to")
        if owned.owner.kind == .conversation {
            detail = await deliverConversationResult(owned)
        }
        let content = UNMutableNotificationContent()
        content.title = FloeL10n.l("platform.background_run_coordinator.video_is_ready")
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
            return FloeL10n.l("platform.background_run_coordinator.the_generation_result_was_saved_to_2", owned.job.id.uuidString)
        }
        let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        )
        guard let source = support?.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relative),
              FileManager.default.fileExists(atPath: source.path) else {
            return FloeL10n.l("platform.background_run_coordinator.the_generation_result_was_saved_to_3", relative)
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
                note = FloeL10n.l("platform.background_run_coordinator.writing_to_the_conversation_workspace_failed", error.localizedDescription, relative)
                FloeLogger(category: .app).warning(
                    "mediaJobWorkspaceDeliveryFailed job=\(owned.job.id.uuidString)"
                )
            }
        } else {
            note = FloeL10n.l("platform.background_run_coordinator.the_conversation_workspace_is_currently_unavailable", relative)
        }
        let location = delivered ?? relative
        if note == nil {
            note = FloeL10n.l("platform.background_run_coordinator.saved_to_the_conversation_workspace", location)
        }
        let content = FloeL10n.l("platform.background_run_coordinator.the_video_was_generated_and_saved", location, owned.job.id.uuidString, note ?? "")
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
        return note ?? FloeL10n.l("platform.background_run_coordinator.saved_to_the_conversation_workspace", location)
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
    /// Service-owned drain for this background session's async settle/fail
    /// work, so the system completion runs exactly once on the main thread
    /// only after every registered follow-up has drained.
    private var settlement: BackgroundDownloadEventSettlement {
        MediaArtifactBackgroundEvents.shared.settlement
    }
    /// Ownership generation per job. Bumped when a download is handed to the
    /// background session; a settle re-checks it after every await so a
    /// relaunch `start` for a reused id can never let a stale settle announce
    /// `.ready`, and the stale settle removes ITS OWN staging file.
    private var jobGenerations: [UUID: UInt64] = [:]
    private let generationLock = NSLock()

    private func currentGeneration(_ jobID: UUID) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        return jobGenerations[jobID] ?? 0
    }

    private func bumpGeneration(_ jobID: UUID) -> UInt64 {
        generationLock.lock()
        defer { generationLock.unlock() }
        let next = (jobGenerations[jobID] ?? 0) &+ 1
        jobGenerations[jobID] = next
        return next
    }
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
            await fail(jobID: jobID, message: FloeL10n.l("platform.background_run_coordinator.the_provider_returned_an_insecure_download"))
            return
        }
        let tasks = await session.allTasks
        if tasks.contains(where: { $0.taskDescription == jobID.uuidString }) { return }
        _ = bumpGeneration(jobID)
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
            // Register the async follow-up synchronously, before this
            // callback returns, so the system completion cannot fire while
            // settle is still moving/committing/transitioning.
            settlement.beginEvent()
            let generationAtStart = currentGeneration(jobID)
            Task {
                await self.settle(
                    jobID: jobID, staging: staging, generationAtStart: generationAtStart,
                    statusCode: statusCode,
                    mimeType: mimeType, suggestedExtension: suggestedExtension,
                    sourceURL: sourceURL
                )
                self.settlement.endEvent()
            }
        } catch {
            settlement.beginEvent()
            Task {
                await self.fail(jobID: jobID, message: error.localizedDescription)
                self.settlement.endEvent()
            }
        }
    }

    private func settle(
        jobID: UUID,
        staging: URL,
        generationAtStart: UInt64,
        statusCode: Int,
        mimeType: String?,
        suggestedExtension: String?,
        sourceURL: URL?
    ) async {
        let fileManager = FileManager.default
        let store = MediaGenerationJobStore(database: database)
        // Re-check ownership after the async hop: a relaunch `start` for the
        // same job replaced this settle's authority; its staged file is ours
        // to remove, and we must never transition the durable row.
        guard generationAtStart == currentGeneration(jobID) else {
            try? fileManager.removeItem(at: staging)
            return
        }
        guard let job = try? await store.job(id: jobID), !job.state.isTerminal else {
            try? fileManager.removeItem(at: staging)
            return
        }
        let size = (try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else {
            try? fileManager.removeItem(at: staging)
            await fail(jobID: jobID, message: FloeL10n.l("platform.background_run_coordinator.the_provider_download_result_was_an"))
            return
        }
        guard size <= Self.maximumDownloadBytes else {
            try? fileManager.removeItem(at: staging)
            await fail(jobID: jobID, message: FloeL10n.l("platform.background_run_coordinator.the_download_exceeds_the_byte_limit", Self.maximumDownloadBytes))
            return
        }
        if statusCode != 0, !(200..<300).contains(statusCode) {
            try? fileManager.removeItem(at: staging)
            await fail(jobID: jobID, message: FloeL10n.l("platform.background_run_coordinator.download_returned_http", statusCode))
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
            // A durable asset-write failure is NOT readiness: the committed
            // material stays on disk (preserve the file), but the job must
            // never be marked ready carrying a `localAssetID` the library
            // cannot resolve. The historical `try?` swallowed the failure and
            // marked ready anyway.
            do {
                try await assetStore.save(CreativeAssetRecord(
                    id: assetID, contentHash: hash, kind: .video,
                    displayName: destination.deletingPathExtension().lastPathComponent,
                    mimeType: mimeType ?? "video/mp4",
                    localRelativePath: "Materials/\(destination.lastPathComponent)",
                    cloudRecordName: nil, byteCount: size,
                    sourceURL: sourceURL,
                    license: nil, tags: [FloeL10n.l("platform.background_run_coordinator.generate_content")], referenceCount: 0,
                    createdAt: Date(), updatedAt: Date()
                ))
            } catch {
                FloeLogger(category: .app).warning(
                    "mediaAssetSaveFailed job=\(jobID.uuidString) asset=\(assetID.uuidString) file preserved, job not marked ready"
                )
                await fail(
                    jobID: jobID,
                    message: "The downloaded file was kept but could not be registered in the asset library: \(error.localizedDescription)"
                )
                return
            }
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
        settlement.beginEvent()
        Task {
            await self.fail(jobID: jobID, message: error.localizedDescription)
            self.settlement.endEvent()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // System side done only; the stored completion fires after every
        // registered settle/fail event has drained (finish-before-settle
        // was the historical bug).
        MediaArtifactBackgroundEvents.shared.settlement.sessionDidFinishEvents()
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

// MARK: - BGAppRefresh generation fence

/// Fenced generation bookkeeping for the BGAppRefresh wake lifecycle, shared
/// across every task instance the coordinator accepts. The scheduler races
/// each instance's expiration callback against its work body, and a second
/// (defensive) delivery supersedes an unfinished generation; all paths race
/// to close their instance. The fence guarantees AT MOST ONE path closes a
/// generation: a stale or expired refresh can never cancel, clear or
/// complete a newer one, no instance is ever completed twice (a second
/// `setTaskCompleted` is an OS exception), and every claim/maintenance step
/// re-checks `owns`, so an expired generation stops claiming. Pure state
/// transitions — behavior tests drive the same code the coordinator uses.
struct BackgroundRefreshGenerationFence {
    private(set) var activeID: UUID?

    /// Takes the slot for a new generation.
    mutating func begin(_ id: UUID) {
        activeID = id
    }

    /// True only while `id` is the generation that owns the slot.
    func owns(_ id: UUID) -> Bool {
        activeID == id
    }

    /// Releases the slot for its owner. Returns false for a generation that
    /// no longer owns it (superseded or expired) or for every repeat call —
    /// the caller may touch the system task ONLY when this returns true.
    @discardableResult
    mutating func complete(_ id: UUID) -> Bool {
        guard activeID == id else { return false }
        activeID = nil
        return true
    }
}

// MARK: - Foreground work session controller

/// The app-side owner of the explicit foreground work session. It applies
/// exactly the FloeCore `BackgroundWorkSessionPolicy` against the REAL
/// durable counts (a snapshot provider the coordinator supplies from the
/// existing job/schedule stores, with the same atomic claim + env-claim
/// dedupe any background wake already uses), the existing finite due pass,
/// and the EXISTING BGContinuedProcessing request/acceptance/expiration/
/// progress lifecycle — the session mints no parallel background mechanism.
///
/// Qualification is real, never decorative: a submission happens only for
/// a current-process explicit foreground user start with actually admitted
/// work, the displayed qualification state follows the framework's real
/// acceptance callback, an accepted task is released the moment no
/// admitted work remains (no perpetual idle task), and every late callback
/// is fenced by the start generation. A restored saved flag, a cold start
/// or a download wake is NEVER start or qualification authority.
///
/// Isolated tests inject fake counts/pass/qualification seams so the whole
/// contract is verifiable without a device or the full app graph.
@MainActor
final class BackgroundWorkSessionController: ObservableObject {
    /// The real framework-acceptance state of the session's continued
    /// processing qualification. `.requested` means an actual
    /// BGContinuedProcessingRequest was submitted through the existing
    /// coordinator path; `.accepted` is set ONLY from the real
    /// `acceptContinuedTask` callback.
    enum Qualification: Equatable, Sendable {
        case none
        case requested
        case accepted
    }

    @Published private(set) var snapshot = BackgroundWorkSessionSnapshot()
    @Published private(set) var qualification: Qualification = .none

    /// The real durable counts behind every decision. The coordinator
    /// supplies this from the shared stores; tests substitute a fake.
    /// A failed durable read THROWS `BackgroundWorkSessionCountsUnknownError`
    /// instead of returning zeros: unknown facts must never be presented as
    /// an empty queue. On a throw the controller preserves the last VALID
    /// counts/state, updates no progress and releases no qualification.
    private let countsProvider: @MainActor () async throws -> BackgroundWorkSessionCounts
    /// One FINITE due pass reusing the existing atomic-claim
    /// `runDueSchedulesNow` (no whole-agent wait, no second manager). The
    /// coordinator supplies it; tests substitute a counter.
    private let runDuePass: @MainActor () async -> Void
    /// Called after every durable change so the coordinator can persist the
    /// record and reconcile the background-location assist and the other
    /// shared surfaces.
    private let onOwnershipChanged: @MainActor (BackgroundWorkSessionSnapshot) async -> Void

    // MARK: Qualification seams (coordinator-owned; tests inject fakes)

    /// The real current-process provenance facts: an aggregate foreground
    /// scene is active AND launch preferences are loaded. Both must hold
    /// for a user start to mint anything; a restored flag or wake never
    /// satisfies them on its own.
    var qualificationContext: (@MainActor () -> (foreground: Bool, loaded: Bool))?
    /// Submits the REAL BGContinuedProcessingRequest through the existing
    /// coordinator path (explicit-user-action origin, session workload) and
    /// reports whether the framework submission was accepted for dispatch.
    var submitQualification: (@MainActor (_ stage: String, _ progress: Int64) -> Bool)?
    /// Pushes real progress into the accepted continued task.
    var updateQualification: (@MainActor (_ stage: String, _ progress: Int64) -> Void)?
    /// Releases ONLY the session's own continued-task ownership; a real run
    /// that still holds eligibility keeps the shared task alive.
    var releaseQualification: (@MainActor () -> Void)?

    /// Injectable clock for deterministic start/wait presentation.
    var nowProvider: @MainActor () -> Date = { Date() }

    /// Single-flight: a start pressed twice coalesces onto one in-flight
    /// pass, so an overlapping foreground/wake pass can never double-launch
    /// the same logical occurrence (the durable claim already fences that).
    private var activePass: Task<Void, Never>?
    private var passToken = 0
    private var startGeneration: UInt64 = 0
    /// Real drain denominator for honest progress: the admitted-work count
    /// captured when the session (re)acquired work. Never a guess.
    private var admittedAtStart = 0
    /// True once the USER acted in this process. A wake restore then has
    /// nothing to restore: this process's live surface already beats any
    /// persisted boundary record.
    private(set) var hasUserActedThisProcess = false

    init(
        countsProvider: @MainActor @escaping () async throws -> BackgroundWorkSessionCounts,
        runDuePass: @MainActor @escaping () async -> Void,
        onOwnershipChanged: @MainActor @escaping (BackgroundWorkSessionSnapshot) async -> Void = { _ in }
    ) {
        self.countsProvider = countsProvider
        self.runDuePass = runDuePass
        self.onOwnershipChanged = onOwnershipChanged
    }

    // MARK: - User start (foreground only)

    /// The only legal way to enter a live session: an explicit foreground
    /// user action in the CURRENT process. Reads the real counts, runs one
    /// finite existing due pass, and reflects whatever actually exists.
    /// Without real foreground provenance and loaded launch preferences the
    /// start is refused outright — nothing is minted, nothing is persisted.
    func foregroundStart() async {
        guard BackgroundWorkSessionPolicy.mayStart(origin: .userInterface) else { return }
        let context = qualificationContext?() ?? (foreground: false, loaded: false)
        guard context.foreground, context.loaded else {
            FloeLogger(category: .app).info(
                "workSessionStartRefused reason=noCurrentProcessForegroundProvenance foreground=\(context.foreground) loaded=\(context.loaded)"
            )
            return
        }
        hasUserActedThisProcess = true
        startGeneration &+= 1
        let generation = startGeneration
        // Claim the single-flight pass SYNCHRONOUSLY at MainActor entry,
        // before any await: two rapid starts cannot both observe an empty
        // slot between the check and the persistence hop below.
        if let existing = activePass {
            snapshot = BackgroundWorkSessionSnapshot(
                state: .running,
                waitReason: nil,
                counts: snapshot.counts,
                startedAt: nowProvider(),
                updatedAt: nowProvider(),
                generation: snapshot.generation &+ 1
            )
            await publish()
            await existing.value
            if generation == startGeneration { await refresh() }
            return
        }
        passToken &+= 1
        let token = passToken
        // Claim the single-flight pass slot SYNCHRONOUSLY before ANY await:
        // two rapid starts cannot both observe an empty slot while the
        // first is suspended in the counts read below.
        let pass = Task { [runDuePass] in await runDuePass() }
        activePass = pass
        // Honest first counts before any state is shown: the session starts
        // from the real durable facts, not an optimistic placeholder. The
        // pass runs concurrently; the post-pass refresh below is what the
        // displayed state settles on.
        let initialCounts: BackgroundWorkSessionCounts
        do {
            initialCounts = try await countsProvider()
        } catch {
            // UNKNOWN is not EMPTY: with unreadable durable facts the start
            // cannot honestly claim a running session. The already-scheduled
            // finite pass still completes (the store's atomic claims fence
            // any duplicate), the single-flight slot is released, and the
            // record is left untouched — no state, no persistence write and
            // no qualification minted from unknown facts.
            _ = await pass.value
            if passToken == token, activePass != nil { activePass = nil }
            FloeLogger(category: .app).warning(
                "workSessionStartDeferred reason=countsUnknown detail=\(String(describing: error))"
            )
            return
        }
        guard generation == startGeneration else { return }
        admittedAtStart = initialCounts.totalAdmitted
        snapshot = BackgroundWorkSessionSnapshot(
            state: .running,
            waitReason: nil,
            counts: initialCounts,
            startedAt: nowProvider(),
            updatedAt: nowProvider(),
            generation: snapshot.generation &+ 1
        )
        await publish()
        applyQualification(generation: generation)
        await pass.value
        // Clear only our own pass slot: a stop/cancel may already have
        // replaced it.
        if passToken == token, activePass != nil { activePass = nil }
        if generation == startGeneration { await refresh() }
    }

    /// Reading the counts again without a pass (a live-run/job change). The
    /// session is live only while it is running or waiting; an idle/armed/
    /// interrupted record never gains work here — later work joins ONLY an
    /// actual valid live session.
    func refresh() async {
        let generation = startGeneration
        let counts: BackgroundWorkSessionCounts
        do {
            counts = try await countsProvider()
        } catch {
            // UNKNOWN ≠ EMPTY: preserve the last VALID counts and state —
            // no re-derived state, no progress update, no qualification
            // release and no completion claim on a failed durable read. The
            // next confirmed read (pass hook, Home appear/pull) settles the
            // truth honestly.
            FloeLogger(category: .app).info(
                "workSessionCountsUnknown path=refresh detail=\(String(describing: error))"
            )
            return
        }
        guard generation == startGeneration else { return }
        guard snapshot.state.isActiveSurface else {
            // Still update the honest counts for display, but do not change
            // a non-live state into a live one and never mint qualification.
            if counts != snapshot.counts {
                snapshot = BackgroundWorkSessionSnapshot(
                    state: snapshot.state,
                    waitReason: snapshot.waitReason,
                    counts: counts,
                    startedAt: snapshot.startedAt,
                    updatedAt: nowProvider(),
                    generation: snapshot.generation
                )
                await publish()
            }
            return
        }
        let decision = BackgroundWorkSessionPolicy.activeState(for: counts)
        snapshot = BackgroundWorkSessionSnapshot(
            state: decision.state,
            waitReason: decision.waitReason,
            counts: counts,
            startedAt: snapshot.startedAt,
            updatedAt: nowProvider(),
            generation: snapshot.generation
        )
        await publish()
        applyQualification(generation: generation)
    }

    /// Refresh only while a live session exists (run/schedule lifecycle
    /// hooks). A non-live record is never revived by background movement.
    func refreshIfLive() async {
        guard snapshot.state.isActiveSurface else { return }
        await refresh()
    }

    // MARK: - Qualification (real BGContinuedProcessing lifecycle)

    /// Submits, updates or releases the session's continued-processing
    /// qualification from the REAL counts. Submission requires admitted
    /// work plus current-process foreground provenance (the underlying
    /// coordinator path re-checks the same facts and the enhanced
    /// capability); an accepted/requested task is released the moment no
    /// admitted work remains, so the session can never hold a perpetual
    /// idle task. Fenced by the start generation: a stale refresh after a
    /// stop touches nothing.
    private func applyQualification(generation: UInt64) {
        guard generation == startGeneration, snapshot.state.isActiveSurface else { return }
        if snapshot.counts.hasAcceptedWork {
            if admittedAtStart == 0 { admittedAtStart = snapshot.counts.totalAdmitted }
            let stage = qualificationStageText()
            let progress = honestProgress()
            switch qualification {
            case .accepted:
                updateQualification?(stage, progress)
            case .requested:
                break // the framework callback decides acceptance; never re-spam
            case .none:
                let context = qualificationContext?() ?? (foreground: false, loaded: false)
                guard BackgroundWorkSessionPolicy.maySubmitQualification(
                    isForegroundActive: context.foreground,
                    launchPreferencesLoaded: context.loaded,
                    counts: snapshot.counts
                ) else { return }
                if submitQualification?(stage, progress) == true {
                    qualification = .requested
                }
            }
        } else if qualification != .none {
            releaseOwnedQualification()
        }
    }

    /// The real framework acceptance callback (coordinator's
    /// `acceptContinuedTask`). Fenced: a late acceptance after a stop, or in
    /// a process where the user never started a session, is ignored — the
    /// displayed state follows ONLY a real acceptance of a live session.
    func handleQualificationAccepted() {
        guard hasUserActedThisProcess,
              snapshot.state.isActiveSurface,
              qualification == .requested else { return }
        qualification = .accepted
        updateQualification?(qualificationStageText(), honestProgress())
    }

    /// The real release callback: the shared continued task finished,
    /// expired or was withheld (enhanced off). The session stays live in
    /// the foreground; only the qualification display returns to truth.
    func handleQualificationLost() {
        guard qualification != .none else { return }
        qualification = .none
    }

    private func releaseOwnedQualification() {
        releaseQualification?()
        qualification = .none
    }

    /// Honest progress: the real drain ratio of admitted work
    /// (admittedAtStart → remaining), clamped to 1…95 like the existing
    /// continued-task updates. No invented percentage ever leaves here.
    private func honestProgress() -> Int64 {
        guard admittedAtStart > 0 else { return 1 }
        let remaining = min(snapshot.counts.totalAdmitted, admittedAtStart)
        let drained = Double(admittedAtStart - remaining) / Double(admittedAtStart)
        return Int64(min(95, max(1, Int(drained * 100.0))))
    }

    private func qualificationStageText() -> String {
        let counts = snapshot.counts
        if let reason = snapshot.waitReason, snapshot.state == .waiting {
            switch reason {
            case .approvals:
                return FloeL10n.isChinese
                    ? "工作会话 · 等待批准 \(counts.pendingApprovals)"
                    : "Work session · awaiting \(counts.pendingApprovals) approval(s)"
            case .environmentBusy:
                return FloeL10n.isChinese
                    ? "工作会话 · 等待环境空闲"
                    : "Work session · waiting for the busy environment"
            case .network:
                return FloeL10n.isChinese ? "工作会话 · 等待网络" : "Work session · waiting for network"
            case .dueWork:
                return FloeL10n.isChinese ? "工作会话 · 等待到期任务" : "Work session · waiting for due work"
            }
        }
        let admitted = counts.totalAdmitted
        return FloeL10n.isChinese
            ? "工作会话 · \(admitted) 项进行中"
            : "Work session · \(admitted) admitted"
    }

    // MARK: - User stop / clear

    /// The user stopped the session: no new background admissions, the
    /// owned qualification is released, foreground tasks and all durable
    /// recoverable state are preserved (nothing is cancelled except this
    /// controller's own scan pass). The record survives as `armed`.
    func foregroundStop() async {
        hasUserActedThisProcess = true
        activePass?.cancel()
        activePass = nil
        startGeneration &+= 1
        releaseOwnedQualification()
        admittedAtStart = 0
        // The user's stop is honored even when a durable read fails; on an
        // UNKNOWN read the record keeps the last VALID counts (never zeros).
        let counts = (try? await countsProvider()) ?? snapshot.counts
        snapshot = BackgroundWorkSessionSnapshot(
            state: .armed,
            waitReason: nil,
            counts: counts,
            startedAt: nil,
            updatedAt: nowProvider(),
            generation: snapshot.generation &+ 1
        )
        await publish()
    }

    /// The user removed the record entirely (`idle`). Playback, claims and
    /// notifications are already gone with `foregroundStop`; this only
    /// clears the stored intent.
    func foregroundClear() async {
        hasUserActedThisProcess = true
        activePass?.cancel()
        activePass = nil
        startGeneration &+= 1
        releaseOwnedQualification()
        admittedAtStart = 0
        snapshot = BackgroundWorkSessionSnapshot(
            state: .idle,
            waitReason: nil,
            counts: BackgroundWorkSessionCounts(),
            startedAt: nil,
            updatedAt: nowProvider(),
            generation: snapshot.generation &+ 1
        )
        await publish()
    }

    // MARK: - Persistence restore (any wake)

    /// The persisted snapshot was just (re)loaded by SettingsCenter. On a
    /// wake this restores metadata ONLY: running/waiting become interrupted,
    /// armed/idle survive. It never runs a due pass, never mints
    /// qualification, and never reacquires continued background execution —
    /// a wake is not start authority, and
    /// `BackgroundWorkSessionPolicy.mayAutoAcquireContinuedBackground`
    /// answers false for every wake kind.
    func restoreFromPersistence(
        persisted: BackgroundWorkSessionSnapshot,
        afterWake wake: BackgroundWorkWakeKind
    ) async {
        guard !hasUserActedThisProcess else { return }
        // A new process never inherits acceptance or a pending request.
        qualification = .none
        admittedAtStart = 0
        guard persisted.state != .idle else {
            snapshot = persisted
            return
        }
        let restored = BackgroundWorkSessionPolicy.restoredState(
            afterWake: wake,
            previous: persisted.state
        )
        snapshot = BackgroundWorkSessionSnapshot(
            state: restored,
            waitReason: nil,
            counts: persisted.counts,
            startedAt: restored == .interrupted ? nil : persisted.startedAt,
            updatedAt: nowProvider(),
            generation: persisted.generation
        )
        await publish()
    }

    private func publish() async {
        await onOwnershipChanged(snapshot)
    }
}
#endif
