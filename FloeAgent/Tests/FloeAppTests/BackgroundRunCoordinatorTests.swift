// FloeAppTests — Background run coordinator contract.
//
// The coordinator is app-target code, so its pure decisions live here: the
// system continued-processing lifecycle, the completion-dwell captions, the
// notification authorization mapping, the deep-link routing identity and the
// foreground banner surface.

#if canImport(UIKit)
import Foundation
import Testing
import SwiftUI
import UIKit
import UserNotifications
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence
import GRDB
@testable import FloeApp

@Suite("FloeApp.BackgroundRunCoordinator")
@MainActor
struct BackgroundRunCoordinatorTests {

    @Test("Both notification delegate callbacks are completion-handler selectors")
    func notificationDelegateSelectorsAreExplicit() {
        // Build 271 aborted on the compiler-generated bridge of the `async`
        // delegate convenience (`didReceive`); the response path moved to the
        // completion-handler selector. The foreground presentation callback is
        // the same class of surface and must not keep an `async` bridge
        // either — implementing both selectors directly keeps every delegate
        // callback on a plain Objective-C entry point.
        #expect(BackgroundRunCoordinator.instancesRespond(
            to: NSSelectorFromString(
                "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"
            )
        ))
        #expect(BackgroundRunCoordinator.instancesRespond(
            to: NSSelectorFromString(
                "userNotificationCenter:willPresentNotification:withCompletionHandler:"
            )
        ))
    }

    @Test("Only an explicit foreground user action may submit a continued task")
    func continuedProcessingLifecycle() {
        for origin in ContinuedProcessingStartOrigin.allCases {
            let allowed = BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
                for: .standard,
                launchPreferencesLoaded: true,
                origin: origin,
                hasAggregateForegroundScene: true
            )
            #expect(allowed == (origin == .explicitUserAction), "origin \(origin.rawValue)")
        }
        // Automatic work never upgrades itself into a system Live Activity.
        #expect(!ContinuedProcessingStartOrigin.foregroundRecovery.allowsContinuedSubmission)
        #expect(!ContinuedProcessingStartOrigin.scheduledTask.allowsContinuedSubmission)
        #expect(!ContinuedProcessingStartOrigin.goalContinuation.allowsContinuedSubmission)
        #expect(!ContinuedProcessingStartOrigin.queuedInput.allowsContinuedSubmission)
        #expect(!ContinuedProcessingStartOrigin.externalAutomation.allowsContinuedSubmission)
        #expect(!ContinuedProcessingStartOrigin.automaticTool.allowsContinuedSubmission)
    }

    @Test("A background wake and an unloaded preference both fail closed")
    func continuedProcessingFailsClosed() {
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: true,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: false
        ))
        // Launch preference restoration must not submit for the in-memory
        // default before the stored preference is known.
        #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessing(
            for: .standard,
            launchPreferencesLoaded: false,
            origin: .explicitUserAction,
            hasAggregateForegroundScene: true
        ))
    }

    @Test("Visual modes own distinct surfaces and none request a hidden consent")
    func visualSurfaceTransitions() {
        let standard = BackgroundRunCoordinator.visualSurfaceTransition(for: .standard)
        #expect(standard.stopsPictureInPicture)
        #expect(standard.stopsScreenShare)
        #expect(!standard.preparesPictureInPicture)

        let pip = BackgroundRunCoordinator.visualSurfaceTransition(for: .pictureInPicture)
        #expect(!pip.stopsPictureInPicture)
        #expect(pip.stopsScreenShare)
        #expect(pip.preparesPictureInPicture)

        let share = BackgroundRunCoordinator.visualSurfaceTransition(for: .screenShare)
        #expect(share.stopsPictureInPicture)
        #expect(!share.stopsScreenShare)
        #expect(!share.preparesPictureInPicture)
        // ReplayKit consent is never requested from a settings transition.
        for transition in [standard, pip, share] {
            #expect(!transition.requestsScreenShareAuthorization)
        }
    }

    @Test("A Linux keep-alive is its own explicit request, independent of the chat surface")
    func linuxSessionContinuedProcessingLifecycle() {
        // The user's explicit toggle in a foreground, preference-loaded app may
        // submit the system task even when the chat surface is a visual mode.
        #expect(BackgroundRunCoordinator.shouldSubmitLinuxSessionContinuedProcessing(
            origin: .explicitUserAction,
            launchPreferencesLoaded: true,
            hasAggregateForegroundScene: true
        ))
        #expect(!BackgroundRunCoordinator.shouldSubmitLinuxSessionContinuedProcessing(
            origin: .explicitUserAction,
            launchPreferencesLoaded: false,
            hasAggregateForegroundScene: true
        ))
        #expect(!BackgroundRunCoordinator.shouldSubmitLinuxSessionContinuedProcessing(
            origin: .explicitUserAction,
            launchPreferencesLoaded: true,
            hasAggregateForegroundScene: false
        ))
        // No automatic origin may create one.
        for origin in ContinuedProcessingStartOrigin.allCases where origin != .explicitUserAction {
            #expect(!BackgroundRunCoordinator.shouldSubmitLinuxSessionContinuedProcessing(
                origin: origin,
                launchPreferencesLoaded: true,
                hasAggregateForegroundScene: true
            ), "origin \(origin.rawValue)")
        }
    }

    @Test("Media generation never submits a continued-processing task")
    func mediaNeverSubmitsContinuedTask() {
        for origin in ContinuedProcessingStartOrigin.allCases {
            #expect(!BackgroundRunCoordinator.shouldSubmitContinuedProcessingForMediaGeneration(
                origin: origin
            ))
        }
    }

    @Test("Only the loaded standard preference keeps continued processing")
    func continuedProcessingPreferenceGating() {
        #expect(BackgroundRunCoordinator.shouldRequestContinuedProcessing(for: .standard))
        #expect(!BackgroundRunCoordinator.shouldRequestContinuedProcessing(for: .pictureInPicture))
        #expect(!BackgroundRunCoordinator.shouldRequestContinuedProcessing(for: .screenShare))
        #expect(BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: .standard, launchPreferencesLoaded: true
        ))
        #expect(!BackgroundRunCoordinator.shouldKeepContinuedProcessing(
            for: .standard, launchPreferencesLoaded: false
        ))
    }

    @Test("Only the retained or active conversation exposes a visual control")
    func visualSurfaceControlOwnership() {
        let conversationID = UUID()
        let other = UUID()
        #expect(BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [conversationID],
            retainedConversationID: nil
        ))
        #expect(BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [],
            retainedConversationID: conversationID
        ))
        #expect(!BackgroundRunCoordinator.shouldOfferVisualSurfaceControl(
            conversationID: conversationID,
            activeConversationIDs: [other],
            retainedConversationID: other
        ))
        #expect(BackgroundRunCoordinator.shouldReconcileVisualSurface(
            hasActiveRuns: false, hasRetainedPausedRun: true
        ))
        #expect(!BackgroundRunCoordinator.shouldReconcileVisualSurface(
            hasActiveRuns: false, hasRetainedPausedRun: false
        ))
    }

    @Test("A temporary run never touches the shared work registry or the notification outbox across its whole lifecycle")
    func temporaryRunLifecycleWritesNoHistory() async throws {
        let defaultsKey = TaskNotificationOutboxStore.defaultsKey
        let priorOutboxData = UserDefaults.standard.data(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        defer {
            if let priorOutboxData {
                UserDefaults.standard.set(priorOutboxData, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
        let environment = AppEnvironment.preview()
        let coordinator = BackgroundRunCoordinator(environment: environment)
        let runID = UUID()
        let conversationID = UUID()
        let sentinel = "TEMP-SENTINEL-\(UUID().uuidString.prefix(8))"

        coordinator.didStart(
            conversationID: conversationID,
            runID: runID,
            title: sentinel,
            origin: .explicitUserAction,
            publishesContent: false
        )
        coordinator.didUpdateProgress(runID: runID, stage: "stage-\(sentinel)", progress: 42)
        coordinator.didSuspend(runID: runID, message: "suspend-\(sentinel)")
        coordinator.didRequireApproval(conversationID: conversationID, runID: runID, toolName: "web.fetch")
        coordinator.didFinish(runID: runID, succeeded: true, message: "done-\(sentinel)")
        // The finish path removes the work record asynchronously; give it a
        // beat before asserting emptiness.
        try await Task.sleep(for: .milliseconds(150))

        let registrySnapshot = await BackgroundWorkRegistry.shared.snapshot(id: runID)
        #expect(registrySnapshot == nil)
        let persisted = TaskNotificationOutboxStore.load()
        #expect(persisted.pending.allSatisfy { event in
            !event.title.contains(sentinel) && !event.body.contains(sentinel)
        })
        // The suspension text never reaches the diagnostics buffer either:
        // temporary content stays out of every durable surface.
        let logged = FloeLogger.buffer.recentEntries.filter { $0.message.contains(sentinel) }
        #expect(logged.isEmpty)
    }

    @Test("An ordinary run publishes its work record through the same lifecycle")
    func ordinaryRunLifecyclePublishesHistory() async throws {
        let environment = AppEnvironment.preview()
        let coordinator = BackgroundRunCoordinator(environment: environment)
        let runID = UUID()
        let conversationID = UUID()

        coordinator.didStart(
            conversationID: conversationID,
            runID: runID,
            title: "Ordinary task",
            origin: .explicitUserAction,
            publishesContent: true
        )
        coordinator.didUpdateProgress(runID: runID, stage: "working", progress: 30)
        try await Task.sleep(for: .milliseconds(150))

        let registrySnapshot = await BackgroundWorkRegistry.shared.snapshot(id: runID)
        #expect(registrySnapshot != nil)
        #expect(registrySnapshot?.state == .running)
        coordinator.didFinish(runID: runID, succeeded: true, message: nil)
        try await Task.sleep(for: .milliseconds(150))
        // Content-publishing runs keep an honest terminal record.
        let finishedSnapshot = await BackgroundWorkRegistry.shared.snapshot(id: runID)
        #expect(finishedSnapshot?.state == .completed)
    }

    @Test("The completion dwell caption reports the real outcome and duration")
    func completionDwellCaption() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let text = BackgroundRunCoordinator.completedSurfaceText(
            for: (title: "整理周报", startedAt: start),
            now: start.addingTimeInterval(125)
        )
        #expect(text.contains("整理周报"))
        #expect(text.contains("已完成"))
        #expect(text.contains("2 分 5 秒"))

        let short = BackgroundRunCoordinator.completedSurfaceText(
            for: (title: "快速任务", startedAt: start),
            now: start.addingTimeInterval(9)
        )
        #expect(short.contains("9 秒"))
        // A clock skew never produces a negative duration.
        let skewed = BackgroundRunCoordinator.completedSurfaceText(
            for: (title: "任务", startedAt: start),
            now: start.addingTimeInterval(-30)
        )
        #expect(skewed.contains("0 秒"))
    }

    @Test("System authorization status maps onto the platform-independent state")
    func authorizationMapping() {
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.authorized) == .authorized)
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.denied) == .denied)
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.provisional) == .provisional)
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.ephemeral) == .ephemeral)
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.notDetermined) == .notDetermined)
    }

    @Test("Conversation deep links route to exactly one conversation")
    func conversationDeepLinkRouting() {
        let conversationID = UUID()
        let runID = UUID()
        let captured = CapturedNotification()
        let token = NotificationCenter.default.addObserver(
            forName: .floeOpenConversation, object: nil, queue: nil
        ) { captured.store($0) }
        defer { NotificationCenter.default.removeObserver(token) }

        BackgroundRunCoordinator.route(deepLink: BackgroundWorkDeepLink(
            kind: .modelRun,
            conversationID: conversationID,
            runID: runID
        ))
        #expect(captured.userInfo?["conversationID"] as? UUID == conversationID)
        #expect(captured.count == 1)
    }

    @Test("A model-run link without a conversation routes nowhere")
    func conversationDeepLinkNeedsIdentity() {
        let captured = CapturedNotification()
        let token = NotificationCenter.default.addObserver(
            forName: .floeOpenConversation, object: nil, queue: nil
        ) { captured.store($0) }
        defer { NotificationCenter.default.removeObserver(token) }

        BackgroundRunCoordinator.route(deepLink: BackgroundWorkDeepLink(kind: .modelRun, runID: UUID()))
        #expect(captured.count == 0)
    }

    @Test("Linux deep links route to the execution surface with their identity")
    func linuxDeepLinkRouting() {
        let captured = CapturedNotification()
        let token = NotificationCenter.default.addObserver(
            forName: .floeOpenExecutionEnvironment, object: nil, queue: nil
        ) { captured.store($0) }
        defer { NotificationCenter.default.removeObserver(token) }

        let jobID = UUID()
        BackgroundRunCoordinator.route(deepLink: BackgroundWorkDeepLink(
            kind: .linuxService,
            environmentID: "env-7",
            serviceJobID: jobID
        ))
        #expect(captured.count == 1)
        #expect(captured.userInfo?["workKind"] as? String == "linuxService")
        #expect(captured.userInfo?["environmentID"] as? String == "env-7")
        #expect(captured.userInfo?["serviceJobID"] as? String == jobID.uuidString)

        // A session link carries no conversation: it must never open a chat.
        let conversationCount = CapturedNotification()
        let conversationToken = NotificationCenter.default.addObserver(
            forName: .floeOpenConversation, object: nil, queue: nil
        ) { conversationCount.store($0) }
        defer { NotificationCenter.default.removeObserver(conversationToken) }
        BackgroundRunCoordinator.route(deepLink: BackgroundWorkDeepLink(
            kind: .linuxSession,
            environmentID: "env-7"
        ))
        #expect(conversationCount.count == 0)
    }

    @Test("A legacy notification payload still opens its conversation")
    func legacyNotificationRouting() {
        let conversationID = UUID()
        let link = BackgroundWorkDeepLink.parse(["conversationID": conversationID.uuidString])
        #expect(link != nil)
        let captured = CapturedNotification()
        let token = NotificationCenter.default.addObserver(
            forName: .floeOpenConversation, object: nil, queue: nil
        ) { captured.store($0) }
        defer { NotificationCenter.default.removeObserver(token) }
        if let link {
            BackgroundRunCoordinator.route(deepLink: link)
        }
        #expect(captured.userInfo?["conversationID"] as? UUID == conversationID)
    }

    @Test("The foreground banner shows one event and dismisses cleanly")
    func foregroundBannerLifecycle() {
        let center = TaskBannerCenter.shared
        center.dismiss()
        #expect(center.banner == nil)

        let link = BackgroundWorkDeepLink(kind: .modelRun, conversationID: UUID())
        center.present(title: "本轮已结束", body: "打开任务查看结果。", deepLink: link)
        #expect(center.banner?.title == "本轮已结束")
        #expect(center.banner?.deepLink == link)

        center.dismiss(id: center.banner?.id)
        #expect(center.banner == nil)
    }

    @Test("A pass drains Run-now and after-success instances, not only calendar ones")
    func pendingNonCalendarOccurrencesAreDrained() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let coordinator = environment.backgroundRunCoordinator

        // Run now: a manual instance whose calendar occurrence is unrelated.
        let scheduled = TaskScheduleRecord(
            title: "Daily", prompt: "report", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(6 * 3_600))
        try await store.save(scheduled)
        let manual = try #require(try await store.runNow(id: scheduled.id, at: Date()))
        #expect(manual.state == .pending)

        // After success: a successful upstream completion enqueues the one
        // instance the calendar can never derive.
        let afterSuccess = TaskScheduleRecord(
            title: "Follow-up", prompt: "publish", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: UUID())
        try await store.save(afterSuccess)
        let afterSuccessUpstream = try #require(afterSuccess.upstreamRunID)
        let upstreamOccurrence = try #require(try await store.recordRunCompletion(
            runID: afterSuccessUpstream,
            succeeded: true, cancelled: false, summary: "done", at: Date()).first)

        // A stale upstream instance on a schedule edited away from
        // after-success must be settled, never launched.
        var stale = TaskScheduleRecord(
            title: "Stale", prompt: "go", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: UUID())
        try await store.save(stale)
        stale.cadence = .daily
        try await store.save(stale)
        let staleKey = "upstream:\(UUID().uuidString)"
        let staleOccurrence = TaskScheduleOccurrence(
            id: TaskScheduleOccurrence.stableID(scheduleID: stale.id, dedupeKey: staleKey),
            scheduleID: stale.id, scheduledFor: Date(), dedupeKey: staleKey)
        _ = try await store.enqueueOccurrence(staleOccurrence)

        await coordinator.runDueSchedulesNow()

        // Every non-calendar instance left the pending state: no model is
        // configured in this preview environment, so the launch revalidation
        // records the honest failure instead of leaving it pending forever.
        #expect(try await store.occurrence(id: manual.id)?.state != .pending)
        #expect(try await store.occurrence(id: upstreamOccurrence)?.state != .pending)
        let settledStale = try #require(try await store.occurrence(id: staleOccurrence.id))
        #expect(settledStale.state == .skipped)
    }

    // MARK: - Background location assist inputs

    private func activeRun(
        media: Bool = false,
        awaitingUser: Bool = false,
        pendingApproval: String? = nil
    ) -> BackgroundRunCoordinator.ActiveRun {
        BackgroundRunCoordinator.ActiveRun(
            conversationID: nil,
            title: "Location task",
            continuedProcessingOrigin: .explicitUserAction,
            allowsContinuedProcessing: true,
            retainsSurfaceOnFailure: true,
            sendsTerminalNotification: true,
            publishesContent: true,
            isProviderRemoteMediaWork: media,
            isAwaitingUserAttention: awaitingUser,
            pendingApprovalToolName: pendingApproval
        )
    }

    @Test("Background location support is the OR of the honored existing capabilities")
    func backgroundLocationSupportFollowsHonoredCapabilities() {
        #expect(BackgroundRunCoordinator.backgroundLocationSupportEnabled(
            for: BackgroundExecutionOptions(
                enhancedBackgroundEnabled: true,
                pictureInPictureEnabled: false,
                screenFeedbackEnabled: false
            )
        ))
        #expect(BackgroundRunCoordinator.backgroundLocationSupportEnabled(
            for: BackgroundExecutionOptions(
                enhancedBackgroundEnabled: false,
                pictureInPictureEnabled: true,
                screenFeedbackEnabled: false
            )
        ))
        #expect(BackgroundRunCoordinator.backgroundLocationSupportEnabled(
            for: BackgroundExecutionOptions(
                enhancedBackgroundEnabled: false,
                pictureInPictureEnabled: false,
                screenFeedbackEnabled: true
            )
        ))
        #expect(!BackgroundRunCoordinator.backgroundLocationSupportEnabled(
            for: BackgroundExecutionOptions(
                enhancedBackgroundEnabled: false,
                pictureInPictureEnabled: false,
                screenFeedbackEnabled: false
            )
        ))

        // The status-PiP release gate strips the visual flags (never the
        // enhanced flag), so an ungated visual choice cannot re-enable the
        // assist by itself.
        let visualOnly = BackgroundExecutionOptions(
            enhancedBackgroundEnabled: false,
            pictureInPictureEnabled: true,
            screenFeedbackEnabled: true
        )
        #expect(!BackgroundRunCoordinator.backgroundLocationSupportEnabled(
            for: BackgroundRunCoordinator.honoredOptions(visualOnly, statusPiPEnabled: false)
        ))
        let enhanced = BackgroundExecutionOptions(enhancedBackgroundEnabled: true)
        #expect(BackgroundRunCoordinator.backgroundLocationSupportEnabled(
            for: BackgroundRunCoordinator.honoredOptions(enhanced, statusPiPEnabled: false)
        ))
    }

    @Test("Only actual local execution is eligible location work")
    func locationWorkEligibilityExcludesWaitingStates() {
        let options = BackgroundExecutionOptions(enhancedBackgroundEnabled: true)
        func inputs(
            runs: [BackgroundRunCoordinator.ActiveRun],
            enabled: [String] = [],
            held: [String] = [],
            running: [String] = [],
            scene: ScenePhase = .active
        ) -> BackgroundRunCoordinator.BackgroundLocationInputs {
            BackgroundRunCoordinator.backgroundLocationInputs(
                options: options,
                statusPiPEnabled: true,
                runs: runs,
                enabledLinuxEnvironmentIDs: enabled,
                heldLinuxEnvironmentIDs: held,
                runningLinuxEnvironmentIDs: running,
                aggregateScenePhase: scene
            )
        }

        #expect(inputs(runs: [activeRun()]).workEligible)
        // Executing before the first model token is still real work.
        #expect(inputs(runs: [activeRun()], scene: .active).workEligible)
        #expect(!inputs(runs: []).workEligible)
        #expect(!inputs(runs: [activeRun(media: true)]).workEligible)
        #expect(!inputs(runs: [activeRun(awaitingUser: true)]).workEligible)
        #expect(!inputs(runs: [activeRun(pendingApproval: "web.fetch")]).workEligible)
        // One ordinary run among ineligible ones keeps the assist on.
        #expect(inputs(runs: [
            activeRun(media: true),
            activeRun(awaitingUser: true),
            activeRun()
        ]).workEligible)
        // A user-permitted Linux guest that is really running is work too.
        #expect(inputs(runs: [], enabled: ["env-1"], held: ["env-1"], running: ["env-1"]).workEligible)
        #expect(inputs(runs: [], enabled: ["env-1"], running: ["env-1"]).workEligible)
        // A guest the user never enabled for background running is not work,
        // even when it is really running or has a stale hold.
        #expect(!inputs(runs: [], running: ["env-1"]).workEligible)
        #expect(!inputs(runs: [], held: ["env-1"], running: ["env-1"]).workEligible)
        #expect(!inputs(runs: [], enabled: ["env-2"], running: ["env-1"]).workEligible)
        // Support and the aggregate scene are independent facts.
        #expect(inputs(runs: [activeRun()]).supportEnabled)
        #expect(inputs(runs: [activeRun()], scene: .background).fullyBackgroundScene)
        #expect(!inputs(runs: [activeRun()], scene: .inactive).fullyBackgroundScene)
        #expect(!inputs(runs: [activeRun()], scene: .active).fullyBackgroundScene)
    }

    @Test("Only an enabled AND actually running guest retains the location assist")
    func linuxGuestAuthorityFiltering() {
        let filtered = BackgroundRunCoordinator.locationEligibleLinuxEnvironmentIDs(
            heldEnvironmentIDs: ["env-a", "env-b"],
            runningEnvironmentIDs: ["env-a", "env-b"],
            enabledEnvironmentIDs: ["env-b"]
        )
        #expect(filtered.held == ["env-b"])
        #expect(filtered.running == ["env-b"])

        // A stale hold for a guest that is no longer running is not authority.
        let staleHold = BackgroundRunCoordinator.locationEligibleLinuxEnvironmentIDs(
            heldEnvironmentIDs: ["env-b"],
            runningEnvironmentIDs: [],
            enabledEnvironmentIDs: ["env-b"]
        )
        #expect(staleHold.held.isEmpty)
        #expect(staleHold.running.isEmpty)

        let options = BackgroundExecutionOptions(enhancedBackgroundEnabled: true)
        func inputs(running: [String], held: [String] = []) -> BackgroundRunCoordinator.BackgroundLocationInputs {
            BackgroundRunCoordinator.backgroundLocationInputs(
                options: options,
                statusPiPEnabled: true,
                runs: [],
                enabledLinuxEnvironmentIDs: ["env-b"],
                heldLinuxEnvironmentIDs: held,
                runningLinuxEnvironmentIDs: running,
                aggregateScenePhase: .active
            )
        }
        // The permitted guest is running: eligible.
        #expect(inputs(running: ["env-b"]).workEligible)
        // A running, NON-enabled guest alone never keeps the assist alive.
        #expect(!inputs(running: ["env-a"]).workEligible)
        // The last permitted guest stops: the assist must clear, and a stale
        // hold cannot resurrect it.
        #expect(!inputs(running: []).workEligible)
        #expect(!inputs(running: [], held: ["env-b"]).workEligible)
    }

    @Test("Multiwindow aggregation: inactive alone never counts as background")
    func multiwindowSceneAggregation() {
        #expect(BackgroundRunCoordinator.aggregateScenePhase([:]) == .background)
        #expect(BackgroundRunCoordinator.aggregateScenePhase(
            ["a": .active, "b": .background]
        ) == .active)
        #expect(BackgroundRunCoordinator.aggregateScenePhase(
            ["a": .active, "b": .inactive]
        ) == .active)
        #expect(BackgroundRunCoordinator.aggregateScenePhase(
            ["a": .inactive, "b": .inactive]
        ) == .inactive)
        #expect(BackgroundRunCoordinator.aggregateScenePhase(
            ["a": .background, "b": .background]
        ) == .background)
    }

    #if DEBUG
    @Test("Real run transitions drive location eligibility until the last run ends")
    func runTransitionsDriveLocationEligibility() {
        let environment = AppEnvironment.preview()
        let coordinator = BackgroundRunCoordinator(environment: environment)
        let first = UUID()

        coordinator.didStart(
            conversationID: UUID(),
            runID: first,
            title: "Weather lookup",
            origin: .explicitUserAction,
            publishesContent: true
        )
        #expect(coordinator.locationAssistWorkEligibleForTesting)

        // Suspended runs stay in `activeRuns`; they are not executing work.
        coordinator.didSuspend(runID: first, message: "Waiting for you")
        #expect(!coordinator.locationAssistWorkEligibleForTesting)

        // A real progress event proves the run resumed.
        coordinator.didUpdateProgress(runID: first, stage: "Resumed", progress: 40)
        #expect(coordinator.locationAssistWorkEligibleForTesting)

        // Awaiting an approval is not execution.
        coordinator.didUpdatePendingApproval(runID: first, toolName: "web.fetch")
        #expect(!coordinator.locationAssistWorkEligibleForTesting)
        coordinator.didUpdatePendingApproval(runID: first, toolName: nil)
        #expect(coordinator.locationAssistWorkEligibleForTesting)

        // A second ordinary run keeps the assist alive when the first ends.
        let second = UUID()
        coordinator.didStart(
            conversationID: UUID(),
            runID: second,
            title: "Nearby search",
            origin: .explicitUserAction,
            publishesContent: true
        )
        coordinator.didFinish(runID: first, succeeded: true, message: nil)
        #expect(coordinator.locationAssistWorkEligibleForTesting)
        coordinator.didFinish(runID: second, succeeded: true, message: nil)
        #expect(!coordinator.locationAssistWorkEligibleForTesting)
    }

    @Test("Provider media work never holds background location by itself")
    func providerMediaWorkIsNotLocalExecution() {
        let environment = AppEnvironment.preview()
        let coordinator = BackgroundRunCoordinator(environment: environment)
        coordinator.didStartMediaGeneration(workID: UUID(), title: "Canvas image")
        #expect(!coordinator.locationAssistWorkEligibleForTesting)

        // An ordinary agent run beside it is still real local execution.
        coordinator.didStart(
            conversationID: UUID(),
            runID: UUID(),
            title: "Weather lookup",
            origin: .explicitUserAction,
            publishesContent: true
        )
        #expect(coordinator.locationAssistWorkEligibleForTesting)
    }

    @Test("Suspension clears again on real tool activity")
    func suspensionClearsOnToolActivity() {
        let environment = AppEnvironment.preview()
        let coordinator = BackgroundRunCoordinator(environment: environment)
        let runID = UUID()
        coordinator.didStart(
            conversationID: UUID(),
            runID: runID,
            title: "Weather lookup",
            origin: .explicitUserAction,
            publishesContent: true
        )
        coordinator.didSuspend(runID: runID, message: "Waiting for you")
        #expect(!coordinator.locationAssistWorkEligibleForTesting)
        coordinator.didUpdateTool(runID: runID, name: "web.search", outcome: .started)
        #expect(coordinator.locationAssistWorkEligibleForTesting)
    }
    #endif
}

/// Synchronous notification observer capture. `NotificationCenter.post` is
/// synchronous, so no waiting is required after `route`.
private final class CapturedNotification: @unchecked Sendable {
    private let lock = NSLock()
    private var info: [AnyHashable: Any]?
    private var events = 0

    func store(_ notification: Notification) {
        lock.lock()
        info = notification.userInfo
        events += 1
        lock.unlock()
    }

    var userInfo: [AnyHashable: Any]? {
        lock.lock(); defer { lock.unlock() }
        return info
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

/// Scriptable guest applier. Mirrors the engine's active state: `applied`
/// holds the forwards currently bound in the guest, because the center
/// clears and reapplies the whole rule set on every rule change
/// (`applyRulesOnce` → `clearEngineForwards` → full re-apply). Reapplying an
/// identical (environment, forward) is idempotent and `remove` retires the
/// forward from the active view. The raw sequences are still available
/// separately: `applyHistory` records every successful apply call in order
/// and `removed` records every remove call, for tests that need the call
/// trace rather than the live set. A rejected host port throws exactly like
/// the engine does when another process already owns the port.
actor FakePortForwardApplier: LinuxPortForwardApplying {
    struct Applied: Sendable, Equatable {
        var environmentID: String
        var forward: LinuxGuestServiceForward
    }

    private(set) var applied: [Applied] = []
    private(set) var applyHistory: [Applied] = []
    private(set) var removed: [Applied] = []
    var running = true
    var rejectedHostPorts: Set<UInt16> = []

    func setRunning(_ value: Bool) { running = value }
    func setRejected(_ ports: Set<UInt16>) { rejectedHostPorts = ports }

    func guestIsRunning(environmentID: String) async -> Bool { running }

    func apply(environmentID: String, forward: LinuxGuestServiceForward) async throws {
        if rejectedHostPorts.contains(forward.hostPort) {
            throw LinuxGuestError.serviceForwardingUnavailable(
                "host port \(forward.hostPort) is already bound"
            )
        }
        let entry = Applied(environmentID: environmentID, forward: forward)
        applyHistory.append(entry)
        if !applied.contains(entry) {
            applied.append(entry)
        }
    }

    func remove(environmentID: String, forward: LinuxGuestServiceForward) async {
        let entry = Applied(environmentID: environmentID, forward: forward)
        removed.append(entry)
        applied.removeAll { $0 == entry }
    }
}

/// Ephemeral UserDefaults suite so port-rule persistence never touches the
/// app's real store.
private struct TempDefaults {
    let name: String
    let defaults: UserDefaults

    init(_ label: String) {
        let suite = "floe.apptests.\(label).\(UUID().uuidString)"
        self.name = suite
        self.defaults = UserDefaults(suiteName: suite)!
        self.defaults.removePersistentDomain(forName: suite)
    }

    func cleanup() {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

@Suite("FloeApp.LinuxPortForwardCenter")
@MainActor
struct LinuxPortForwardCenterTests {

    @Test("Rules apply through the guest controller inside the managed range")
    func appliesRules() async throws {
        let temp = TempDefaults("pf.apply")
        defer { temp.cleanup() }
        let applier = FakePortForwardApplier()
        let center = LinuxPortForwardCenter(
            applier: applier,
            defaults: temp.defaults,
            deviceAddressProvider: { "192.168.1.20" }
        )
        try await center.addRule(
            environmentID: "env-1",
            guestPort: 8080,
            requestedHostPort: 50_000,
            label: "web"
        )
        try await center.addRule(
            environmentID: "env-1",
            guestPort: 3000,
            requestedHostPort: nil,
            label: "api"
        )
        let applied = await applier.applied
        #expect(applied.count == 2)
        #expect(applied[0].forward.hostAddress == LinuxPortForwardLimits.defaultBindAddress)
        #expect(applied[0].forward.hostPort == 50_000)
        #expect(applied[0].forward.guestPort == 8080)
        // The dynamic rule takes the lowest free port in the range.
        #expect(applied[1].forward.hostPort == 49_152)
        #expect(applied[1].forward.guestPort == 3000)
    }

    @Test("An occupied fixed port is remapped and reported")
    func conflictRemap() async throws {
        let temp = TempDefaults("pf.conflict")
        defer { temp.cleanup() }
        let applier = FakePortForwardApplier()
        await applier.setRejected([50_000])
        let center = LinuxPortForwardCenter(
            applier: applier,
            defaults: temp.defaults,
            deviceAddressProvider: { "192.168.1.20" }
        )
        try await center.addRule(
            environmentID: "env-1",
            guestPort: 8080,
            requestedHostPort: 50_000,
            label: "web"
        )
        let applied = await applier.applied
        #expect(applied.count == 1)
        #expect(applied[0].forward.hostPort == 49_152)
        #expect(center.lastConflictNotice != nil)
        let preview = center.previews(environmentID: "env-1").first
        #expect(preview?.plan.wasRemapped == true)
    }

    @Test("A stopped VM keeps its rules and clears the applied view")
    func stopKeepsRules() async throws {
        let temp = TempDefaults("pf.stop")
        defer { temp.cleanup() }
        let applier = FakePortForwardApplier()
        let center = LinuxPortForwardCenter(
            applier: applier,
            defaults: temp.defaults,
            deviceAddressProvider: { "192.168.1.20" }
        )
        try await center.addRule(
            environmentID: "env-1",
            guestPort: 8080,
            requestedHostPort: nil,
            label: "web"
        )
        #expect(!center.plans(environmentID: "env-1").isEmpty)
        center.guestStopped(environmentID: "env-1")
        #expect(center.plans(environmentID: "env-1").isEmpty)
        #expect(center.rules(environmentID: "env-1").count == 1)
        // The preview still shows the planned port, marked as not applied.
        let preview = center.previews(environmentID: "env-1").first
        #expect(preview?.isApplied == false)
        #expect(preview?.plan.hostPort == 49_152)
    }

    @Test("Rules persist per environment and restore on a new instance")
    func persistence() async throws {
        let temp = TempDefaults("pf.persist")
        defer { temp.cleanup() }
        let applier = FakePortForwardApplier()
        let center = LinuxPortForwardCenter(
            applier: applier,
            defaults: temp.defaults,
            deviceAddressProvider: { "192.168.1.20" }
        )
        try await center.addRule(
            environmentID: "env-1",
            guestPort: 8080,
            requestedHostPort: 50_010,
            label: "web"
        )
        try await center.addRule(
            environmentID: "env-2",
            guestPort: 5000,
            requestedHostPort: nil,
            label: "other"
        )
        let restored = LinuxPortForwardCenter(
            applier: applier,
            defaults: temp.defaults,
            deviceAddressProvider: { "192.168.1.20" }
        )
        #expect(restored.rules(environmentID: "env-1").first?.guestPort == 8080)
        #expect(restored.rules(environmentID: "env-2").first?.requestedHostPort == nil)
        // Restoring applies through the controller again (restart restoration).
        await restored.applyRules(environmentID: "env-1")
        let applied = await applier.applied
        #expect(applied.contains { $0.forward.hostPort == 50_010 })
    }

    @Test("LAN URL and QR payload use only the local address")
    func urls() async throws {
        let temp = TempDefaults("pf.url")
        defer { temp.cleanup() }
        let applier = FakePortForwardApplier()
        let center = LinuxPortForwardCenter(
            applier: applier,
            defaults: temp.defaults,
            deviceAddressProvider: { "192.168.1.20" }
        )
        try await center.addRule(
            environmentID: "env-1",
            guestPort: 8080,
            requestedHostPort: 50_000,
            label: "web"
        )
        let preview = try #require(center.previews(environmentID: "env-1").first)
        #expect(preview.lanURL?.absoluteString == "http://192.168.1.20:50000")
        #expect(preview.loopbackURL?.absoluteString == "http://127.0.0.1:50000")
        #expect(preview.qrPayload == "http://192.168.1.20:50000")
    }

    @Test("The per-VM cap is enforced before anything reaches the guest")
    func capEnforced() async throws {
        let temp = TempDefaults("pf.cap")
        defer { temp.cleanup() }
        let applier = FakePortForwardApplier()
        let center = LinuxPortForwardCenter(
            applier: applier,
            defaults: temp.defaults,
            deviceAddressProvider: { nil }
        )
        for index in 0..<LinuxPortForwardLimits.maximumRulesPerEnvironment {
            try await center.addRule(
                environmentID: "env-1",
                guestPort: 8000 + index,
                requestedHostPort: nil,
                label: "svc-\(index)"
            )
        }
        await #expect(throws: LinuxPortForwardRuleError.ruleCapReached(
            limit: LinuxPortForwardLimits.maximumRulesPerEnvironment
        )) {
            try await center.addRule(
                environmentID: "env-1",
                guestPort: 9000,
                requestedHostPort: nil,
                label: "overflow"
            )
        }
        #expect(center.enabledRuleCount(environmentID: "env-1")
            == LinuxPortForwardLimits.maximumRulesPerEnvironment)
    }

    @Test("A stopped VM records no rule as applied and deletes cleanly")
    func stoppedEnvironment() async throws {
        let temp = TempDefaults("pf.stopped")
        defer { temp.cleanup() }
        let applier = FakePortForwardApplier()
        await applier.setRunning(false)
        let center = LinuxPortForwardCenter(
            applier: applier,
            defaults: temp.defaults,
            deviceAddressProvider: { nil }
        )
        try await center.addRule(
            environmentID: "env-1",
            guestPort: 8080,
            requestedHostPort: nil,
            label: "web"
        )
        #expect(await applier.applied.isEmpty)
        #expect(center.rules(environmentID: "env-1").count == 1)
        await center.forget(environmentID: "env-1")
        #expect(center.rules(environmentID: "env-1").isEmpty)
        #expect(center.previews(environmentID: "env-1").isEmpty)
    }
}

@Suite("FloeApp.SelectedScheduleRun")
@MainActor
struct SelectedScheduleRunTests {

    private func makeEnvironment() async throws -> AppEnvironment {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        // The production Shortcuts service factory joins durable readiness,
        // which must observe the isolated graph as launched instead of
        // re-running real bootstrap against shared roots.
        environment.markIsolatedLaunchReadyForTesting()
        return environment
    }

    /// Seeds one enabled provider+model and reloads the environment's center
    /// so the production `providerAndModel(modelID:)` resolution path sees it.
    private func seedModel(_ environment: AppEnvironment) async throws -> ModelProfile {
        let configuration = ModelConfigurationStore(database: environment.database)
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://selected-schedule.example/v1")!)
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "selected-schedule-model",
            displayName: "Selected Schedule Model",
            limits: .init(contextTokens: 4_096, maxOutputTokens: 1_024),
            capabilities: [.text, .tools])
        try await configuration.saveProvider(provider)
        try await configuration.saveModel(model)
        await environment.conversationCenter.reload()
        return model
    }

    private func dueOnceSchedule(
        title: String = "Morning report",
        modelID: UUID? = nil,
        environmentID: String? = nil,
        permissionJSON: String? = nil
    ) -> TaskScheduleRecord {
        TaskScheduleRecord(
            title: title,
            prompt: "Write the morning report",
            workspaceID: nil,
            cadence: .once,
            scheduledAt: Date().addingTimeInterval(-60),
            isEnabled: true,
            modelID: modelID,
            environmentID: environmentID,
            permissionJSON: permissionJSON)
    }

    private func predeterminedIDs(
        scheduleID: UUID, occurrenceID: UUID
    ) -> (runID: UUID, conversationID: UUID) {
        (
            TaskScheduleOccurrence.stableID(
                scheduleID: scheduleID, dedupeKey: "run:\(occurrenceID.uuidString)"),
            TaskScheduleOccurrence.stableID(
                scheduleID: scheduleID, dedupeKey: "conversation:\(occurrenceID.uuidString)")
        )
    }

    @Test("A deleted schedule is refused accurately")
    func deletedSchedule() async throws {
        let environment = try await makeEnvironment()
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.scheduleDeleted) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: UUID())
        }
    }

    @Test("A disabled schedule with no run is refused and never launches")
    func disabledSchedule() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        var schedule = dueOnceSchedule(modelID: model.id)
        schedule.isEnabled = false
        try await store.save(schedule)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.scheduleDisabled) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        // Nothing was claimed or launched; the occurrence stays pending and
        // no run exists.
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let occurrence = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(occurrence.state == .pending)
        #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
    }

    @Test("A future one-shot and an after-success schedule have no due occurrence")
    func notDueCases() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let future = TaskScheduleRecord(
            title: "Later", prompt: "p", cadence: .once,
            scheduledAt: Date().addingTimeInterval(3_600))
        try await store.save(future)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.noDueOccurrence(
            eventDriven: false)) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: future.id)
        }
        let chained = TaskScheduleRecord(
            title: "Chain", prompt: "p", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: UUID())
        try await store.save(chained)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.noDueOccurrence(
            eventDriven: true)) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: chained.id)
        }
    }

    @Test("An unavailable bound environment fails the occurrence honestly without launching")
    func invalidEnvironmentBinding() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id, environmentID: "missing-env")
        try await store.save(schedule)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.environmentUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let occurrence = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(occurrence.state == .failed)
        #expect(occurrence.errorText?.contains("environment") == true)
        #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
    }

    @Test("A missing default model and an explicitly deleted bound model both fail honestly")
    func invalidModelBindings() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        // Unbound record, no default model configured at all.
        let unbound = dueOnceSchedule()
        try await store.save(unbound)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.modelUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: unbound.id)
        }
        // Explicit frozen binding that no longer resolves must NOT fall back.
        let bound = dueOnceSchedule(modelID: UUID())
        try await store.save(bound)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.modelUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: bound.id)
        }
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: bound, now: Date()))
        let occurrence = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(occurrence.state == .failed)
        #expect(occurrence.errorText?.contains("model") == true)
    }

    @Test("An absent policy keeps the default, an invalid policy refuses accurately")
    func permissionBindingValidation() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        // Legacy absent binding (nil) still launches under the default policy.
        let legacy = dueOnceSchedule(title: "Legacy", modelID: model.id)
        try await store.save(legacy)
        let legacyReceipt = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: legacy.id)
        #expect(legacyReceipt.freshlyLaunched)
        // A PRESENT-but-invalid policy must not launch under fallback
        // permissions.
        let invalid = dueOnceSchedule(
            title: "Broken policy", modelID: model.id,
            permissionJSON: "{not-a-policy")
        try await store.save(invalid)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.permissionUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: invalid.id)
        }
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: invalid, now: Date()))
        let occurrence = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(occurrence.state == .failed)
        #expect(occurrence.errorText?.contains("permission") == true)
        #expect(try await environment.runStore.run(id: legacyReceipt.runID) != nil)
    }

    @Test("A claimed occurrence whose committed run lost its bind recovers the same run; without a run it stays concurrently claimed")
    func claimedOccurrenceRecoversCommittedRun() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        // Warmup: a successful call FIRST, so the coordinator's one startup
        // reconciliation is already done. The injected state below then
        // represents the real same-process branch (an executor claimed and
        // committed AFTER startup); a pre-startup claimed row would be stale
        // dead-process history and is covered separately.
        let warmup = dueOnceSchedule(title: "Warmup", modelID: model.id)
        try await store.save(warmup)
        _ = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: warmup.id)

        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        // Simulate the transient post-commit window: the predetermined run
        // is durably committed, the bind write failed, the occurrence is
        // still claimed with no run reference.
        try await environment.conversationStore.saveConversation(.init(
            id: expected.conversationID, title: schedule.title,
            createdAt: Date(), updatedAt: Date()))
        try await environment.runStore.saveRun(.init(
            id: expected.runID, conversationID: expected.conversationID,
            state: "preparing", goal: schedule.prompt,
            startedAt: Date(), endedAt: nil))
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID, scheduleID: schedule.id,
            scheduledFor: target.fireTime, dedupeKey: target.dedupeKey))
        try await store.claimOccurrence(id: target.occurrenceID, at: Date())

        let receipt = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        // The SAME predetermined run is rebound — never relaunched.
        #expect(receipt.runID == expected.runID)
        #expect(receipt.conversationID == expected.conversationID)
        #expect(!receipt.freshlyLaunched)
        let rebound = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(rebound.state == .running)
        #expect(rebound.runID == expected.runID)

        // Without a committed run, a claimed occurrence is a live foreign
        // claim: it must be refused, not reset and not relaunched.
        let other = dueOnceSchedule(title: "Other", modelID: model.id)
        try await store.save(other)
        let otherTarget = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: other, now: Date()))
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: otherTarget.occurrenceID, scheduleID: other.id,
            scheduledFor: otherTarget.fireTime, dedupeKey: otherTarget.dedupeKey))
        try await store.claimOccurrence(id: otherTarget.occurrenceID, at: Date())
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.concurrentlyClaimed) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: other.id)
        }
        // The foreign claim is untouched by the refusal.
        let foreign = try #require(try await store.occurrence(id: otherTarget.occurrenceID))
        #expect(foreign.state == .claimed)
        #expect(foreign.runID == nil)
    }

    @Test("A stale claimed row present BEFORE the first call is reconciled as interrupted history and never restarted")
    func firstCallReconcilesStaleClaimedHistoryWithoutRestartingIt() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        // Dead-process history: the occurrence was claimed but the process
        // exited before any launch. Seeded BEFORE the coordinator's first
        // call, so the startup reconciliation owns it.
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID, scheduleID: schedule.id,
            scheduledFor: target.fireTime, dedupeKey: target.dedupeKey))
        try await store.claimOccurrence(id: target.occurrenceID, at: Date())

        // The honest outcome: interrupted history, an explicit refusal —
        // and NO restart, NO fabricated run.
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.noDueOccurrence(
            eventDriven: false)) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        let settled = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(settled.state == .interrupted)
        #expect(settled.runID == nil)
        #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
    }

    @Test("A scheduled run answers Status/Text/Files through the production service and its fences stay closed")
    func scheduledRunAnswersThroughProductionRunService() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let receipt = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)

        // Settle the run as a real completed run with a proven final reply
        // (production event order: assistant row, assistantText, terminal).
        try await environment.runStore.saveRun(.init(
            id: receipt.runID, conversationID: receipt.conversationID,
            state: "completed", goal: schedule.prompt,
            startedAt: Date(), endedAt: Date()))
        let messageID = UUID()
        try await environment.conversationStore.appendMessage(.init(
            id: messageID, conversationID: receipt.conversationID, role: "assistant",
            content: "Scheduled answer", createdAt: Date(), runID: receipt.runID))
        _ = try await environment.runStore.appendEvent(
            runID: receipt.runID, kind: .assistantText,
            payloadJSON: "{\"text\":\"Scheduled answer\"}")
        _ = try await environment.runStore.appendEvent(
            runID: receipt.runID, kind: .terminal,
            payloadJSON: "{\"stopReason\":\"endTurn\",\"finalMessageID\":\"\(messageID.uuidString)\"}")
        _ = try await store.recordRunCompletion(
            runID: receipt.runID, succeeded: true, cancelled: false,
            summary: "done", at: Date())

        // Status: the production exact-run factory accepts the scheduled
        // run's precise identity.
        let service = environment.floeShortcutRunService()
        let status = try await service.status(runID: receipt.runID)
        #expect(status.runID == receipt.runID)
        #expect(status.conversationID == receipt.conversationID)
        #expect(status.state == .completed)
        #expect(status.isFullSuccess)

        // Text: the proven final reply of THIS run is returned.
        let text = try await service.textResult(runID: receipt.runID)
        #expect(text.text == "Scheduled answer")
        #expect(text.completeness == .complete)

        // Files: the same run reference passes ownership validation; with no
        // manifest rows the honest answer is a proven "no files".
        let files = try await service.fileResult(
            runID: receipt.runID, expectedConversationID: receipt.conversationID)
        #expect(files.status.state == .completed)
        #expect(files.files.isEmpty)

        // The App-Intent projection validates ownership the same way the
        // other actions do.
        let entity = try await FloeShortcutRunIntentBridge.snapshot(
            runID: receipt.runID,
            expectedConversationID: receipt.conversationID,
            environment: { environment })
        #expect(entity.runID == receipt.runID.uuidString)
        #expect(entity.state == .completed)

        // Fences: a mismatched conversation is refused, never silently read.
        await #expect(throws: FloeRunFilesError.ownership) {
            _ = try await service.fileResult(
                runID: receipt.runID, expectedConversationID: UUID())
        }
    }

    @Test("A due schedule launches through the shared claim/bind path with its frozen binding and deterministic identity")
    func launchesWithFrozenBinding() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let policy = DraftTaskPolicy(approvalMode: .automatic)
        let schedule = dueOnceSchedule(
            modelID: model.id,
            permissionJSON: String(decoding: try JSONEncoder().encode(policy), as: UTF8.self))
        try await store.save(schedule)

        let receipt = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        let expected = predeterminedIDs(
            scheduleID: schedule.id,
            occurrenceID: TaskScheduleOccurrence.stableID(
                scheduleID: schedule.id, dedupeKey: "once"))
        #expect(receipt.runID == expected.runID)
        #expect(receipt.conversationID == expected.conversationID)
        #expect(receipt.freshlyLaunched)

        // The occurrence ledger names the exact run (ownership proof), the
        // durable run exists, and the one-shot schedule settled as started.
        let occurrence = try #require(try await store.occurrence(id: TaskScheduleOccurrence.stableID(
            scheduleID: schedule.id, dedupeKey: "once")))
        #expect(occurrence.state == .running)
        #expect(occurrence.runID == receipt.runID)
        #expect(occurrence.conversationID == receipt.conversationID)
        #expect(try await environment.runStore.run(id: receipt.runID) != nil)
        #expect(try await environment.conversationStore
            .conversation(id: receipt.conversationID) != nil)
        let settled = try #require(try await store.schedule(id: schedule.id))
        #expect(!settled.isEnabled)
        #expect(settled.lastStartedAt != nil)
    }

    @Test("Duplicate and concurrent callbacks converge on the one committed run")
    func duplicateAndConcurrentConvergence() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)

        let first = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        // A duplicate callback returns the same reference without launching.
        let second = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        #expect(second.runID == first.runID)
        #expect(second.conversationID == first.conversationID)
        #expect(!second.freshlyLaunched)

        // Two overlapping callbacks also collapse to one run.
        let daily = TaskScheduleRecord(
            title: "Daily", prompt: "p", cadence: .daily,
            scheduledAt: Date().addingTimeInterval(-120),
            anchorTimezone: "UTC", modelID: model.id)
        try await store.save(daily)
        async let left = environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: daily.id)
        async let right = environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: daily.id)
        let (a, b) = try await (left, right)
        #expect(a.runID == b.runID)
        #expect(a.conversationID == b.conversationID)
        // One occurrence row, one durable run — no duplicate launch.
        #expect(try await store.occurrences(scheduleID: daily.id, limit: 10).count == 1)
        #expect(try await environment.runStore.run(id: a.runID) != nil)
    }

    @Test("A completed occurrence keeps returning its exact run reference")
    func completedOccurrenceReturnsSameReference() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let coordinator = environment.backgroundRunCoordinator
        let first = try await coordinator.runSelectedSchedule(scheduleID: schedule.id)
        _ = try await store.recordRunCompletion(
            runID: first.runID, succeeded: true, cancelled: false,
            summary: "done", at: Date())
        let again = try await coordinator.runSelectedSchedule(scheduleID: schedule.id)
        #expect(again.runID == first.runID)
        #expect(again.conversationID == first.conversationID)
        #expect(!again.freshlyLaunched)
    }

    @Test("The selected route never drains unrelated schedules or manual/upstream instances")
    func doesNotDrainUnrelatedWork() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let selected = dueOnceSchedule(title: "Selected", modelID: model.id)
        try await store.save(selected)
        // Another due enabled schedule, a manual instance and an armed
        // after-success instance must all survive untouched.
        let other = dueOnceSchedule(title: "Other", modelID: model.id)
        try await store.save(other)
        let manual = try #require(try await store.runNow(id: selected.id, at: Date()))
        let chained = TaskScheduleRecord(
            title: "Chain", prompt: "p", cadence: .afterSuccess,
            scheduledAt: Date(), upstreamRunID: UUID(), modelID: model.id)
        try await store.save(chained)
        let upstream = try #require(chained.upstreamRunID)
        let armed = try #require(try await store.recordRunCompletion(
            runID: upstream, succeeded: true, cancelled: false,
            summary: "done", at: Date()).first)

        _ = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: selected.id)

        #expect(try await store.occurrences(scheduleID: other.id, limit: 10).isEmpty)
        #expect(try await store.occurrence(id: manual.id)?.state == .pending)
        #expect(try await store.occurrence(id: armed)?.state == .pending)
    }

    @Test("A storage failure surfaces as storageUnavailable, not a silent nil")
    func storageFailureIsAccurate() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let schedule = dueOnceSchedule()
        try await store.save(schedule)
        try await environment.database.close()
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.storageUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
    }

    // MARK: - Post-commit recovery (PRIMARY-REJECTED branch repair)

    /// Installs a REAL scoped SQLite fault on the production occurrence
    /// table: the claimed→running bind write aborts. This is genuine fault
    /// injection at the store layer, not a stubbed coordinator seam.
    private func installBindWriteFault(_ environment: AppEnvironment) async throws {
        try await environment.database.writer { db in
            try db.execute(sql: """
                CREATE TRIGGER test_fault_block_occurrence_bind
                BEFORE UPDATE ON task_schedule_occurrences
                WHEN NEW.state = 'running'
                BEGIN
                    SELECT RAISE(ABORT, 'injected bind-write failure');
                END
                """)
        }
    }

    private func removeBindWriteFault(_ environment: AppEnvironment) async throws {
        try await environment.database.writer { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS test_fault_block_occurrence_bind")
        }
    }

    private func installReconcileWriteFault(_ environment: AppEnvironment) async throws {
        try await environment.database.writer { db in
            try db.execute(sql: """
                CREATE TRIGGER test_fault_block_reconcile
                BEFORE UPDATE ON task_schedule_occurrences
                WHEN NEW.state = 'interrupted'
                BEGIN
                    SELECT RAISE(ABORT, 'injected reconcile-write failure');
                END
                """)
        }
    }

    private func removeReconcileWriteFault(_ environment: AppEnvironment) async throws {
        try await environment.database.writer { db in
            try db.execute(sql: "DROP TRIGGER IF EXISTS test_fault_block_reconcile")
        }
    }

    /// Attaches a real GRDB statement trace to the production (in-memory)
    /// SQLite connection. The probe counts the startup reconciliation's own
    /// SELECT/JOIN, which runs once per physical pass even when it matches
    /// no rows, and holds the first SELECT inside SQLite until released.
    private func installStartupReconcileProbe(
        _ environment: AppEnvironment
    ) async throws -> StartupReconcileProbe {
        let probe = StartupReconcileProbe()
        try await environment.database.writer { db in
            db.trace(options: .statement) { event in
                guard case let .statement(statement) = event else { return }
                probe.record(sql: statement.sql)
            }
        }
        return probe
    }

    private func removeStartupReconcileProbe(
        _ environment: AppEnvironment
    ) async throws {
        try await environment.database.writer { db in
            // Documented detach form: an empty options set stops tracing.
            db.trace(options: [])
        }
    }

    private func captureSelectedRun(
        _ operation: () async throws -> BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt
    ) async -> Result<BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private func expectRefusal(
        _ result: Result<BackgroundRunCoordinator.FloeSelectedScheduleRunReceipt, Error>,
        _ failure: BackgroundRunCoordinator.FloeSelectedScheduleFailure,
        _ message: String
    ) {
        guard case .failure(let error) = result else {
            Issue.record("expected refusal but the call succeeded — \(message)")
            return
        }
        #expect(
            error as? BackgroundRunCoordinator.FloeSelectedScheduleFailure == failure,
            "\(message)")
    }

    @Test("Two simultaneous first calls coalesce onto ONE physical startup reconcile that both await")
    func concurrentFirstCallsShareOneStartupReconcile() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        // A stale claimed row forces the startup reconcile to do real work
        // (with no rows the reconcile short-circuits) and gives the two
        // racing first callers something to coalesce on.
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID, scheduleID: schedule.id,
            scheduledFor: target.fireTime, dedupeKey: target.dedupeKey))
        try await store.claimOccurrence(id: target.occurrenceID, at: Date())

        let coordinator = environment.backgroundRunCoordinator
        // The physical pass is proved on the REAL connection by counting the
        // startup reconcile's SELECT itself. A row-based BEFORE UPDATE
        // trigger cannot do this: the reconcile selects only claimed/running
        // rows, so a second physical pass that starts after the first settled
        // the only stale row matches zero rows and fires no UPDATE trigger.
        // The first SELECT is also held open inside SQLite until the second
        // caller has entered the same coordinator call — a deterministic
        // overlap barrier, not a timing or sleep-based assumption.
        let probe = try await installStartupReconcileProbe(environment)
        defer { probe.releaseFirstSelect() }

        async let left = captureSelectedRun {
            try await coordinator.runSelectedSchedule(scheduleID: schedule.id)
        }
        let firstSelectObserved = await probe.waitForFirstSelect()
        #expect(firstSelectObserved, "the startup reconcile SELECT never ran")
        guard firstSelectObserved else {
            // Swift awaits the unconsumed `left` child during scope exit
            // before running `defer`; release the SQLite barrier here so a
            // late SELECT can never hang that implicit await.
            probe.releaseFirstSelect()
            return
        }

        // The second caller starts only while the first physical reconcile is
        // provably in flight, and it reaches its first suspension (the shared
        // in-flight await) before the barrier is released.
        let secondCallerStarted = SecondCallerGate()
        async let right = captureSelectedRun { @MainActor in
            secondCallerStarted.signal()
            return try await coordinator.runSelectedSchedule(scheduleID: schedule.id)
        }
        await secondCallerStarted.waitForSignal()
        probe.releaseFirstSelect()

        let (leftResult, rightResult) = await (left, right)
        // Both callers awaited the SAME physical reconcile: both proceeded
        // past it and refused identically on the interrupted history. A
        // per-caller reconcile would have produced a second physical SELECT,
        // and the old Bool-only helper's second pass could also have
        // interrupted an occurrence claimed while the first was in flight.
        expectRefusal(
            leftResult, .noDueOccurrence(eventDriven: false), "left first call")
        expectRefusal(
            rightResult, .noDueOccurrence(eventDriven: false), "right first call")
        // Direct proof of ONE physical reconcile for the coalesced pair: the
        // startup SELECT ran exactly once even though only the first pass
        // matched a row.
        #expect(
            probe.startupSelectCount == 1,
            "the coalesced pair must perform exactly one physical startup reconcile")
        // Instrumentation sensitivity: a fresh coordinator (its own
        // one-time startup pass) runs the same SELECT over the now-settled
        // history where ZERO claimed/running rows remain. The probe still
        // counts it, which is exactly the row-blind case that made the old
        // BEFORE UPDATE trigger unable to prove a second physical pass.
        let freshCoordinator = BackgroundRunCoordinator(environment: environment)
        let zeroRowCall = await captureSelectedRun {
            try await freshCoordinator.runSelectedSchedule(scheduleID: schedule.id)
        }
        expectRefusal(zeroRowCall, .noDueOccurrence(eventDriven: false), "zero-row reconcile")
        #expect(probe.startupSelectCount == 2, "a SELECT matching zero rows is still counted")
        try await removeStartupReconcileProbe(environment)
        // Cold-start semantics preserved: settled interrupted, never
        // restarted, no run launched.
        let settled = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(settled.state == .interrupted)
        #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
    }

    @Test("Two simultaneous first calls await the same FAILED startup reconcile and both observe storageUnavailable")
    func concurrentFirstCallsShareOneReconcileFailure() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID, scheduleID: schedule.id,
            scheduledFor: target.fireTime, dedupeKey: target.dedupeKey))
        try await store.claimOccurrence(id: target.occurrenceID, at: Date())
        try await installReconcileWriteFault(environment)

        let coordinator = environment.backgroundRunCoordinator
        // Same real-connection SELECT instrumentation as the success case:
        // the shared failed reconcile must be ONE physical pass (count 1),
        // and the later retry must be a genuinely new physical pass (count 2).
        let probe = try await installStartupReconcileProbe(environment)
        defer { probe.releaseFirstSelect() }

        async let left = captureSelectedRun {
            try await coordinator.runSelectedSchedule(scheduleID: schedule.id)
        }
        let firstSelectObserved = await probe.waitForFirstSelect()
        #expect(firstSelectObserved, "the startup reconcile SELECT never ran")
        guard firstSelectObserved else {
            // Swift awaits the unconsumed `left` child during scope exit
            // before running `defer`; release the SQLite barrier here so a
            // late SELECT can never hang that implicit await.
            probe.releaseFirstSelect()
            return
        }
        let secondCallerStarted = SecondCallerGate()
        async let right = captureSelectedRun { @MainActor in
            secondCallerStarted.signal()
            return try await coordinator.runSelectedSchedule(scheduleID: schedule.id)
        }
        await secondCallerStarted.waitForSignal()
        probe.releaseFirstSelect()

        let (leftResult, rightResult) = await (left, right)
        // The failure belongs to the shared reconcile: BOTH callers observe
        // storageUnavailable, and neither proceeds under false readiness.
        expectRefusal(leftResult, .storageUnavailable, "left first call")
        expectRefusal(rightResult, .storageUnavailable, "right first call")
        // The startup SELECT ran exactly once: the failure was shared instead
        // of being retried independently by each caller.
        #expect(
            probe.startupSelectCount == 1,
            "both failing callers must share exactly one physical startup reconcile")
        // The aborted reconcile rolled back: the row is untouched.
        let untouched = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(untouched.state == .claimed)

        // The in-flight failure was released: with the fault removed, the
        // next call performs a real second physical reconcile (the SELECT is
        // counted again) and refuses honestly — retryable, never hidden.
        try await removeReconcileWriteFault(environment)
        let retry = await captureSelectedRun {
            try await coordinator.runSelectedSchedule(scheduleID: schedule.id)
        }
        expectRefusal(retry, .noDueOccurrence(eventDriven: false), "retry after fault removal")
        #expect(probe.startupSelectCount == 2, "the retry must be a second physical reconcile")
        try await removeStartupReconcileProbe(environment)
        let settled = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(settled.state == .interrupted)
    }

    @Test("A real bind-write failure after a committed launch keeps the occurrence recoverable and the retry returns the exact same run")
    func committedLaunchSurvivesTransientBindWriteFailure() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(scheduleID: schedule.id, occurrenceID: target.occurrenceID)

        try await installBindWriteFault(environment)
        let receipt = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        // The committed launch is named truthfully even though the bind write
        // failed; the run really exists and continues.
        #expect(receipt.runID == expected.runID)
        #expect(receipt.conversationID == expected.conversationID)
        #expect(receipt.freshlyLaunched)
        // The occurrence is NOT falsely settled as a prelaunch failure: it
        // stays claimed (recoverable) with no run reference yet.
        let stranded = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(stranded.state == .claimed)
        #expect(stranded.runID == nil)
        // Exactly one durable run exists — the fault caused no second launch.
        #expect(try await environment.runStore.nonTerminalRuns().count == 1)

        try await removeBindWriteFault(environment)
        // Retry recovers the SAME run + conversation; still exactly one run.
        let recovered = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        #expect(recovered.runID == expected.runID)
        #expect(recovered.conversationID == expected.conversationID)
        #expect(!recovered.freshlyLaunched)
        let rebound = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(rebound.state == .running)
        #expect(rebound.runID == expected.runID)
        #expect(rebound.conversationID == expected.conversationID)
        #expect(try await store.occurrences(scheduleID: schedule.id, limit: 10).count == 1)
        #expect(try await environment.runStore.nonTerminalRuns().count == 1)
        #expect(try await environment.runStore.run(id: expected.runID) != nil)
    }

    @Test("A bind-write failure during claimed-row recovery is storage truth, and recovery succeeds once the fault is removed")
    func claimedRecoveryBindWriteFailureSurfacesStorage() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        // Warmup completes the one startup reconciliation so the injected
        // state below is the real same-process branch.
        let warmup = dueOnceSchedule(title: "Warmup", modelID: model.id)
        try await store.save(warmup)
        _ = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: warmup.id)

        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        try await environment.conversationStore.saveConversation(.init(
            id: expected.conversationID, title: schedule.title,
            createdAt: Date(), updatedAt: Date()))
        try await environment.runStore.saveRun(.init(
            id: expected.runID, conversationID: expected.conversationID,
            state: "preparing", goal: schedule.prompt,
            startedAt: Date(), endedAt: nil))
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID, scheduleID: schedule.id,
            scheduledFor: target.fireTime, dedupeKey: target.dedupeKey))
        try await store.claimOccurrence(id: target.occurrenceID, at: Date())

        try await installBindWriteFault(environment)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.storageUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        // The claimed row is untouched by the failed write — not settled, not
        // reset, not relaunched.
        let untouched = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(untouched.state == .claimed)
        #expect(untouched.runID == nil)
        try await removeBindWriteFault(environment)

        let recovered = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: schedule.id)
        #expect(recovered.runID == expected.runID)
        #expect(recovered.conversationID == expected.conversationID)
        #expect(!recovered.freshlyLaunched)
        let rebound = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(rebound.state == .running)
        #expect(rebound.runID == expected.runID)
    }

    @Test("A failed startup reconciliation write surfaces as storage on the explicit route and stays retryable instead of being hidden")
    func startupReconciliationFailureStaysRetryable() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        // A stale claimed row forces the startup reconciliation to perform a
        // real write (with no rows the reconcile short-circuits).
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID, scheduleID: schedule.id,
            scheduledFor: target.fireTime, dedupeKey: target.dedupeKey))
        try await store.claimOccurrence(id: target.occurrenceID, at: Date())

        try await installReconcileWriteFault(environment)
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.storageUnavailable) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        // The aborted reconcile rolled back: the row is untouched, and the
        // readiness flag was NOT set (no false readiness).
        let untouched = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(untouched.state == .claimed)
        try await removeReconcileWriteFault(environment)

        // The retry truthfully performs the startup reconciliation: the stale
        // row is settled interrupted (never restarted) and the call refuses
        // honestly — proof the reconcile ran and was not permanently hidden.
        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.noDueOccurrence(
            eventDriven: false)) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        let settled = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(settled.state == .interrupted)
        #expect(try await environment.runStore.nonTerminalRuns().isEmpty)
    }

    @Test("A receipt naming no durable run is refused as a corrupt reference")
    func receiptWithMissingDurableRunIsRefused() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let warmup = dueOnceSchedule(title: "Warmup", modelID: model.id)
        try await store.save(warmup)
        _ = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: warmup.id)

        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        // Corrupt ledger tie: the occurrence names a run that does not exist.
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID, scheduleID: schedule.id,
            scheduledFor: target.fireTime, dedupeKey: target.dedupeKey))
        try await store.claimOccurrence(id: target.occurrenceID, at: Date())
        _ = try await store.markOccurrenceRunning(
            id: target.occurrenceID, runID: expected.runID,
            conversationID: expected.conversationID, at: Date())

        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.runReferenceMismatch) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        // The refusal does not mutate the corrupt row.
        let corrupt = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(corrupt.state == .running)
        #expect(corrupt.runID == expected.runID)
    }

    @Test("A receipt whose durable run belongs to a different conversation is refused as a corrupt reference")
    func receiptWithForeignConversationRunIsRefused() async throws {
        let environment = try await makeEnvironment()
        let store = SQLiteTaskScheduleStore(database: environment.database)
        let model = try await seedModel(environment)
        let warmup = dueOnceSchedule(title: "Warmup", modelID: model.id)
        try await store.save(warmup)
        _ = try await environment.backgroundRunCoordinator
            .runSelectedSchedule(scheduleID: warmup.id)

        let schedule = dueOnceSchedule(modelID: model.id)
        try await store.save(schedule)
        let target = try #require(TaskSchedulePlanner.selectedRunTarget(
            record: schedule, now: Date()))
        let expected = predeterminedIDs(scheduleID: schedule.id, occurrenceID: target.occurrenceID)
        try await store.enqueueOccurrence(TaskScheduleOccurrence(
            id: target.occurrenceID, scheduleID: schedule.id,
            scheduledFor: target.fireTime, dedupeKey: target.dedupeKey))
        try await store.claimOccurrence(id: target.occurrenceID, at: Date())
        _ = try await store.markOccurrenceRunning(
            id: target.occurrenceID, runID: expected.runID,
            conversationID: expected.conversationID, at: Date())
        // The run exists but belongs to ANOTHER conversation: owner proof
        // fails even though the ledger tie matches. The foreign conversation
        // must be a REAL row first: `runs.conversation_id` is foreign-keyed in
        // the production schema, and an impossible row would abort before the
        // tested ownership check instead of exercising it.
        let foreignConversationID = UUID()
        try await environment.conversationStore.saveConversation(.init(
            id: foreignConversationID, title: "Unrelated conversation",
            createdAt: Date(), updatedAt: Date()))
        try await environment.runStore.saveRun(.init(
            id: expected.runID, conversationID: foreignConversationID,
            state: "preparing", goal: schedule.prompt,
            startedAt: Date(), endedAt: nil))

        try await #expect(throws: BackgroundRunCoordinator.FloeSelectedScheduleFailure.runReferenceMismatch) {
            _ = try await environment.backgroundRunCoordinator
                .runSelectedSchedule(scheduleID: schedule.id)
        }
        let corrupt = try #require(try await store.occurrence(id: target.occurrenceID))
        #expect(corrupt.state == .running)
        #expect(corrupt.conversationID == expected.conversationID)
    }
}

@Suite("FloeApp.BackgroundNotificationGate")
@MainActor
struct BackgroundNotificationGateTests {

    @Test("The persisted policy maps onto durable terminal kinds")
    func gateMapping() {
        let terminal = BackgroundRunCoordinator.eventGate(for: .terminal)
        #expect(terminal.allows(.completed))
        #expect(terminal.allows(.failed))
        #expect(terminal.allows(.cancelled))
        #expect(!terminal.allows(.actionRequired))

        let critical = BackgroundRunCoordinator.eventGate(for: .critical)
        #expect(!critical.allows(.completed))
        #expect(critical.allows(.failed))
        #expect(!critical.allows(.cancelled))
        #expect(critical.allows(.actionRequired))

        let stages = BackgroundRunCoordinator.eventGate(for: .stages)
        #expect(stages.allows(.completed))
        #expect(stages.allows(.failed))
        #expect(stages.allows(.cancelled))
        #expect(stages.allows(.actionRequired))

        let off = BackgroundRunCoordinator.eventGate(for: .off)
        for kind in TaskTerminalEventKind.allCases {
            #expect(!off.allows(kind))
        }
        // A missing record follows the documented default (.stages).
        #expect(BackgroundRunCoordinator.eventGate(for: nil).allows(.failed))
    }

    @Test("Terminal outcomes map onto work states and interruptions")
    func terminalOutcomeMapping() {
        #expect(BackgroundRunCoordinator.TerminalOutcome.succeeded.state == .completed)
        #expect(!BackgroundRunCoordinator.TerminalOutcome.succeeded.interruption.offersRecovery)
        #expect(BackgroundRunCoordinator.TerminalOutcome.cancelled.state == .cancelled)
        #expect(BackgroundRunCoordinator.TerminalOutcome.failed.state == .failed)
        #expect(BackgroundRunCoordinator.TerminalOutcome.failed.interruption == .checkpointed)
    }

    @Test("The system authorization status maps to the platform-independent state")
    func authorizationMapping() {
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.authorized) == .authorized)
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.denied) == .denied)
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.provisional) == .provisional)
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.ephemeral) == .ephemeral)
        #expect(BackgroundRunCoordinator.notificationAuthorizationState(.notDetermined) == .notDetermined)
    }
}

/// Test-only GRDB statement trace for the one physical startup reconcile.
///
/// `SQLiteTaskScheduleStore.reconcileInterruptedOccurrences` selects only
/// `claimed`/`running` rows. A row-based BEFORE UPDATE trigger therefore
/// cannot see a second physical pass that begins after the first settled the
/// only stale row: its SELECT matches zero rows and no UPDATE fires. This
/// probe counts the reconcile's own SELECT/JOIN statement on the real SQLite
/// connection instead (regardless of matched rows), and holds the first
/// execution inside SQLite until the test releases it, so the two racing
/// callers genuinely overlap without a sleep-based assumption.
private final class StartupReconcileProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var selectCount = 0
    private var firstSelectContinuation: CheckedContinuation<Bool, Never>?
    private var firstSelectObserved = false
    private let firstSelectBarrier = DispatchSemaphore(value: 0)

    /// Normalized signature of the production startup reconcile: the only
    /// query that joins the schedule table onto occurrences with a
    /// `claimed`/`running` filter. Whitespace is collapsed because the
    /// production SQL is a multiline literal.
    private static func isStartupReconcileSelect(_ sql: String) -> Bool {
        let normalized = sql.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.hasPrefix(
            "SELECT o.id AS occurrence_id, o.schedule_id AS schedule_id,")
            && normalized.contains(
                "FROM task_schedule_occurrences o JOIN task_schedules s ON s.id = o.schedule_id")
            && normalized.contains("WHERE o.state IN ('claimed', 'running')")
    }

    func record(sql: String) {
        guard Self.isStartupReconcileSelect(sql) else { return }
        lock.lock()
        selectCount += 1
        let isFirst = selectCount == 1
        let continuation: CheckedContinuation<Bool, Never>? =
            isFirst ? firstSelectContinuation : nil
        if isFirst {
            firstSelectObserved = true
            firstSelectContinuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: true)
        if isFirst {
            // This blocks the database's serial queue, never the caller's
            // MainActor: the first reconcile cannot finish until the second
            // caller has entered the same coordinator call.
            firstSelectBarrier.wait()
        }
    }

    /// Returns once the first startup SELECT has begun. The timeout only
    /// prevents an arrangement failure from hanging the hosted suite; the
    /// assertion is the counted SELECT, never the wait itself.
    func waitForFirstSelect() async -> Bool {
        await withCheckedContinuation { continuation in
            lock.lock()
            if firstSelectObserved {
                lock.unlock()
                continuation.resume(returning: true)
                return
            }
            firstSelectContinuation = continuation
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [self] in
                lock.lock()
                let pending = firstSelectContinuation
                firstSelectContinuation = nil
                lock.unlock()
                pending?.resume(returning: false)
            }
        }
    }

    func releaseFirstSelect() {
        firstSelectBarrier.signal()
    }

    var startupSelectCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return selectCount
    }
}

/// MainActor hand-off for the second concurrent caller: it signals
/// immediately before entering the coordinator. MainActor serialization runs
/// that call until its first suspension (the shared in-flight await) before
/// the resumed test job can proceed, so the test releases the SQLite barrier
/// only after both callers are inside the shared entry.
@MainActor
private final class SecondCallerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func signal() {
        if let continuation {
            self.continuation = nil
            continuation.resume()
        } else {
            signaled = true
        }
    }

    func waitForSignal() async {
        if signaled {
            signaled = false
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }
}

#endif
