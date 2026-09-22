// FloeAppTests — Background run coordinator contract.
//
// The coordinator is app-target code, so its pure decisions live here: the
// system continued-processing lifecycle, the completion-dwell captions, the
// notification authorization mapping, the deep-link routing identity and the
// foreground banner surface.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import UserNotifications
import FloeCore
import FloeModels
@testable import FloeApp

@Suite("FloeApp.BackgroundRunCoordinator")
@MainActor
struct BackgroundRunCoordinatorTests {

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
#endif
