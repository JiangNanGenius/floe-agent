import Foundation

/// The notification-worthy lifecycle event.
public enum TaskNotificationEvent: String, Sendable, Codable, Hashable {
    /// Run finished, either successfully or with a failure.
    case terminal
    /// A stage/checkpoint reached while the run continues.
    case stage
    /// A tool call is waiting for approval.
    case approval
}

/// The outcome the app layer should perform. Posting a system notification
/// and showing an in-app banner are separate so the foreground banner can
/// replace (never duplicate) a system alert.
public struct TaskNotificationDecision: Sendable, Equatable {
    public enum Delivery: String, Sendable, Equatable {
        /// Do nothing (policy off, or event not allowed).
        case none
        /// Submit a system notification (only meaningful in the background or
        /// when the app can present it).
        case system
        /// Foreground: show the in-app banner instead of a system alert.
        case inAppBanner
        /// Authorization is missing/denied: surface state in the UI and still
        /// show the banner in foreground; in background nothing can appear.
        case blockedByAuthorization
    }

    public var delivery: Delivery
    /// True when the system center should be asked to present the alert while
    /// the app is foreground (avoids double display with the banner).
    public var presentSystemInForeground: Bool

    public init(delivery: Delivery, presentSystemInForeground: Bool = false) {
        self.delivery = delivery
        self.presentSystemInForeground = presentSystemInForeground
    }

    /// Pure decision used by both the coordinator and tests.
    /// - Parameters:
    ///   - policy: the persisted per-conversation notification policy.
    ///   - event: the lifecycle event.
    ///   - succeeded: for terminal events, whether the run succeeded.
    ///   - authorization: real notification authorization state.
    ///   - appIsForeground: whether any scene is currently foreground.
    public static func resolve(
        policy: TaskNotificationPolicy?,
        event: TaskNotificationEvent,
        succeeded: Bool = true,
        authorization: NotificationAuthorizationState,
        appIsForeground: Bool
    ) -> TaskNotificationDecision {
        let policy = policy ?? .stages
        let policyAllows: Bool
        switch event {
        case .terminal:
            policyAllows = policy.shouldNotifyTerminal(succeeded: succeeded)
        case .stage:
            policyAllows = policy.shouldNotifyStages
        case .approval:
            policyAllows = policy.shouldNotifyApproval
        }
        guard policyAllows else { return TaskNotificationDecision(delivery: .none) }

        // Foreground: never duplicate a system alert; use the in-app banner.
        if appIsForeground {
            return TaskNotificationDecision(delivery: .inAppBanner)
        }
        // Background: need real authorization to post a system notification.
        // Provisional is authorized (delivered quietly). notDetermined means
        // the user has never been asked — treat as blocked and surface it.
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            return TaskNotificationDecision(delivery: .system)
        case .denied, .notDetermined:
            return TaskNotificationDecision(delivery: .blockedByAuthorization)
        }
    }
}
