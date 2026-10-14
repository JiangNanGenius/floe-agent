// FloeApp — DEBUG-only system-notification qualification fixture.
//
// SPDX-License-Identifier: MPL-2.0
//
// This hook prepares ONE clearly synthetic task and publishes ONE real terminal
// notification through the PRODUCTION posting path
// (`BackgroundRunCoordinator.enqueueTerminalNotification` →
// `UNUserNotificationCenter.add`). It never taps, routes or completes anything
// itself: the alert must be delivered by the system and the tap must arrive
// through the production `userNotificationCenter(_:didReceive:
// withCompletionHandler:)` delegate selector on the real app. The durable
// redacted stage trail (`notificationResponseStage …`) then names exactly what
// happened, and the host verifies the intended conversation route.
//
// Gated on `-ui-testing` + an explicit launch argument, simulator only. The
// synthetic task record uses one fixed identity and a namespaced title, so a
// repeated run replaces nothing and never touches user notes/tasks.
#if DEBUG
import Foundation
import FloeCore
import FloePersistence
import UserNotifications

@MainActor
enum NotificationQualificationFixture {
    static let launchArgument = "--ui-test-notification-fixture"
    static let identifierEnvironmentKey = "FLOE_NOTIFICATION_QUALIFICATION_ID"
    /// Fixed synthetic task identity (namespaced; never user data).
    static let conversationID = UUID(uuidString: "9F2C41B7-5A3D-4E68-9C10-2B7D5E6A8F31")!
    static let taskTitle = "通知路由合成任务"
    static let defaultIdentifier = "floe.qualification.notification.tap"

    static func seedIfRequested(environment: AppEnvironment) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-ui-testing"), arguments.contains(launchArgument) else { return }
        #if targetEnvironment(simulator)
        let identifier = ProcessInfo.processInfo.environment[identifierEnvironmentKey]
            ?? defaultIdentifier
        let conversationID = self.conversationID
        // The route target must be a real persisted task; create it once with a
        // fixed identity (a second launch reuses the same record).
        if (try? await environment.conversationStore.conversation(id: conversationID)) == nil {
            try? await environment.conversationStore.saveConversation(ConversationRecord(
                id: conversationID,
                title: taskTitle,
                createdAt: Date(),
                updatedAt: Date()))
        }
        // Real permission request — the same system API the first task start
        // uses. The system prompt is answered through the UI; nothing is
        // assumed authorized.
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        let coordinator = environment.backgroundRunCoordinator
        await coordinator.refreshNotificationAuthorizationAndFlush()
        let authorization = await BackgroundRunCoordinator.currentNotificationAuthorization()
        FloeLogger(category: .app).warning(
            "notificationQualification authorization=\(authorization.rawValue) identifier=\(identifier)")
        // The REAL posting path: durable event → outbox → system alert. The
        // event carries only the synthetic identity; the alert body is fixed
        // and content-free of user data.
        coordinator.enqueueTerminalNotification(event: TaskTerminalEvent(
            identifier: identifier,
            kind: .completed,
            title: taskTitle,
            body: "合成任务已完成；轻点返回该任务。",
            deepLink: BackgroundWorkDeepLink(
                kind: .modelRun,
                conversationID: conversationID,
                runID: UUID())))
        #endif
    }
}
#endif
