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
import FloeExecution
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

/// Scriptable guest applier. Records every forward the center publishes and
/// can be told to reject specific host ports, exactly like the engine does
/// when another process already owns the port.
actor FakePortForwardApplier: LinuxPortForwardApplying {
    struct Applied: Sendable, Equatable {
        var environmentID: String
        var forward: LinuxGuestServiceForward
    }

    private(set) var applied: [Applied] = []
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
        applied.append(Applied(environmentID: environmentID, forward: forward))
    }

    func remove(environmentID: String, forward: LinuxGuestServiceForward) async {
        removed.append(Applied(environmentID: environmentID, forward: forward))
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

#endif
