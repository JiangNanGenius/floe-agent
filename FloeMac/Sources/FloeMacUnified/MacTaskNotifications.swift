// SPDX-License-Identifier: MPL-2.0

import Combine
import FloeModels
import UserNotifications

@MainActor
final class MacTaskNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = MacTaskNotifications()
    enum Event: String {
        case started, approval, completed, failed, cancelled

        var title: String {
            switch self {
            case .started: MacPermissionsText.t("定时任务已开始", "Scheduled Task Started")
            case .approval: MacPermissionsText.t("任务等待审批", "Task Needs Approval")
            case .completed: MacPermissionsText.t("任务已完成", "Task Completed")
            case .failed: MacPermissionsText.t("任务需要检查", "Task Needs Attention")
            case .cancelled: MacPermissionsText.t("任务已停止", "Task Stopped")
            }
        }
    }

    @Published private(set) var authorization: NotificationAuthorizationState = .notDetermined
    private var openTask: ((UUID) -> Void)?
    private var isInstalled = false

    func install(openTask: @escaping (UUID) -> Void) {
        self.openTask = openTask
        UNUserNotificationCenter.current().delegate = self
        isInstalled = true
    }

    func updateAuthorization() async {
        guard isInstalled else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized: authorization = .authorized
        case .provisional: authorization = .provisional
        @unknown default: authorization = .denied
        }
    }

    func requestAuthorization() async {
        guard isInstalled else { return }
        try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await updateAuthorization()
    }

    func post(_ event: Event, taskID: UUID, key: String, title: String? = nil) {
        guard isInstalled else { return }
        Task {
            await updateAuthorization()
            guard authorization.canPresentAlert else { return }
            let content = UNMutableNotificationContent()
            content.title = event.title
            // iPad parity: the alert names the task so a terminal/approval
            // notification is actionable from the banner alone. A missing
            // title (e.g. a just-created conversation not yet reloaded) keeps
            // the honest generic body instead of guessing.
            if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                content.body = trimmed
            } else {
                content.body = MacPermissionsText.t("打开 Floe 查看任务。", "Open Floe to view the task.")
            }
            content.threadIdentifier = taskID.uuidString
            content.userInfo = ["taskID": taskID.uuidString]
            content.sound = .default
            let request = UNNotificationRequest(identifier: "floe.task.\(event.rawValue).\(key)", content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content.userInfo["taskID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { openTask?(id) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
