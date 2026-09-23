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

/// Where a notification-driven deep link may go. The pure decision keeps the
/// coordinator's tap handler honest on cold launches (database, scene and
/// navigation not ready yet), on duplicate taps, and when the target task or
/// environment was deleted: route exactly once, never crash into a missing
/// target.
public enum TaskDeepLinkRouting: String, Sendable, Equatable {
    /// Persistence and a foreground scene are ready and the target exists:
    /// route on the main actor now.
    case routeNow
    /// Cold launch (or a pre-ready foreground transition): hold the route and
    /// retry on the next ready transition instead of navigating into a
    /// half-built stack.
    case deferUntilReady
    /// The same route was performed within the dedup window: drop the repeat
    /// tap without touching navigation or the outbox.
    case ignoreDuplicate
    /// The conversation/environment no longer exists: present the unreachable
    /// prompt; never route into a deleted target.
    case promptMissingTarget
}

extension TaskNotificationDecision {
    /// Pure routing gate for a parsed notification deep link.
    /// - Parameters:
    ///   - persistenceReady: the durable database (and therefore the task /
    ///     environment records) has finished opening and initial reload.
    ///   - hasActiveScene: at least one scene has reported an active phase, so
    ///     a navigation mutation lands in a live SwiftUI stack.
    ///   - isDuplicate: true when the same route identity was already executed
    ///     within the coordinator's dedup window.
    ///   - targetExists: the conversation/environment record still exists.
    public static func resolveRouting(
        persistenceReady: Bool,
        hasActiveScene: Bool,
        isDuplicate: Bool,
        targetExists: Bool
    ) -> TaskDeepLinkRouting {
        if isDuplicate { return .ignoreDuplicate }
        guard persistenceReady, hasActiveScene else { return .deferUntilReady }
        guard targetExists else { return .promptMissingTarget }
        return .routeNow
    }
}
