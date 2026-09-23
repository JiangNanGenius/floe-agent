import Foundation
import FloeCore

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

/// Authoritative existence/liveness answer for one notification deep-link
/// target. The answer comes from the environment registry and the runtime's
/// ownership seam — never from "is it running?", because a stopped-but-present
/// Linux environment is existence, not deletion, and an unreadable registry is
/// unknown, not deletion.
public enum TaskDeepLinkTargetState: String, Sendable, Equatable, CaseIterable {
    /// Exists and can be opened directly: a live conversation, a running
    /// Linux guest.
    case exists
    /// The record exists but nothing is running for it (a stopped Linux
    /// environment). The safe list surface may focus it; nothing is deleted.
    case existsStopped
    /// The authoritative environment record is gone.
    case missing
    /// Existence/liveness could not be determined (no runtime seam injected,
    /// or the registry did not load). Never reported as deleted.
    case unknown
}

public extension TaskDeepLinkTargetState {
    /// Classifies a Linux environment target from the authoritative reads the
    /// app can perform without starting a guest:
    /// - `recordExists`: `EnvironmentRegistry.record(id:) != nil`; nil means
    ///   the registry could not be read (unknown, not deleted).
    /// - `ownedByRuntime`: `ownsLinuxEnvironment(id:)` — true while the guest
    ///   is stopped too; nil means no Linux runtime is injected in this build.
    /// - `guestIsRunning`: live guest truth; only meaningful while owned.
    static func linuxEnvironment(
        recordExists: Bool?,
        ownedByRuntime: Bool?,
        guestIsRunning: Bool?
    ) -> TaskDeepLinkTargetState {
        if ownedByRuntime == true {
            // Ownership survives a stop, so this is the authoritative
            // exists-vs-running answer.
            guard let guestIsRunning else { return .unknown }
            return guestIsRunning ? .exists : .existsStopped
        }
        // A loaded registry that no longer holds the record is the only
        // authoritative deletion answer; a failed read (nil) is not.
        if recordExists == false { return .missing }
        return .unknown
    }
}

/// Where a notification-driven deep link may go. The pure decision keeps the
/// coordinator's tap handler honest on cold launches (database, scene and the
/// navigation subscribers not ready yet), on duplicate taps, and when the
/// target task or environment was deleted or is merely stopped: route exactly
/// once, never crash into a missing target, never claim deletion for a
/// stopped environment.
public enum TaskDeepLinkRouting: String, Sendable, Equatable {
    /// Persistence, a foreground scene and the root view's deep-link
    /// subscribers are ready and the target exists: route on the main actor
    /// now.
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
    /// The environment record still exists but nothing is running for it:
    /// present a neutral "stopped" note and open the safe list focused on it.
    /// Stopped is existence, not deletion.
    case promptStoppedTarget
    /// Existence could not be determined: present a neutral note and open the
    /// safe list. Never claims deletion.
    case promptUnavailableTarget
}

public extension TaskDeepLinkRouting {
    /// The target state whose prompt this outcome presents; nil for outcomes
    /// that navigate, wait or suppress.
    var promptedTargetState: TaskDeepLinkTargetState? {
        switch self {
        case .promptMissingTarget: .missing
        case .promptStoppedTarget: .existsStopped
        case .promptUnavailableTarget: .unknown
        case .routeNow, .deferUntilReady, .ignoreDuplicate: nil
        }
    }

    /// True when the app consumed the durable notification event: it either
    /// performed the user's intent or told the user why it could not. A
    /// deferred route or a suppressed duplicate keeps the event queued for a
    /// later attempt.
    var consumesDurableEvent: Bool {
        self == .routeNow || promptedTargetState != nil
    }
}

/// Monotonic request generation for notification deep-link routing. The app
/// begins one request per user tap; an async target check may only complete
/// while its generation is still current, so a slower earlier tap can never
/// navigate after a newer tap started. A deferred retry reuses the current
/// generation (the original attempt already owned it) instead of inventing a
/// new one.
public struct TaskDeepLinkRouteRequest: Sendable, Equatable {
    public private(set) var current: UInt64

    public init(current: UInt64 = 0) {
        self.current = current
    }

    /// Starts a new request and returns its generation.
    public mutating func begin() -> UInt64 {
        current &+= 1
        return current
    }

    /// True while a completion carrying this generation may still act.
    public func accepts(generation: UInt64) -> Bool {
        generation == current
    }
}

extension TaskNotificationDecision {
    /// Pure routing gate for a parsed notification deep link.
    /// - Parameters:
    ///   - persistenceReady: the durable database (and therefore the task /
    ///     environment records) has finished opening and initial reload.
    ///   - hasActiveScene: at least one scene has reported an active phase, so
    ///     a navigation mutation lands in a live SwiftUI stack.
    ///   - navigationSubscribersReady: the root view that hosts the
    ///     `.floeOpenConversation` / `.floeOpenExecutionEnvironment`
    ///     subscribers has actually been installed. Persistence plus an active
    ///     scene only prove the hierarchy may exist; posting a route before
    ///     the subscribers mount goes nowhere while consuming the event.
    ///   - isDuplicate: true when the same route identity was already executed
    ///     within the coordinator's dedup window.
    ///   - target: the authoritative existence/liveness answer for the target.
    public static func resolveRouting(
        persistenceReady: Bool,
        hasActiveScene: Bool,
        navigationSubscribersReady: Bool,
        isDuplicate: Bool,
        target: TaskDeepLinkTargetState
    ) -> TaskDeepLinkRouting {
        if isDuplicate { return .ignoreDuplicate }
        guard persistenceReady, hasActiveScene, navigationSubscribersReady else {
            return .deferUntilReady
        }
        switch target {
        case .exists: return .routeNow
        case .existsStopped: return .promptStoppedTarget
        case .missing: return .promptMissingTarget
        case .unknown: return .promptUnavailableTarget
        }
    }

    /// True when an unreachable notification for this family has a real safe
    /// destination the app can open: the execution-environment list for the
    /// Linux families. A model-run route has no task-list listener in this
    /// build (the family-only link would no-op), so its prompt stays
    /// banner-only instead of promising a destination that never opens.
    public static func hasSafeListFallback(kind: BackgroundWorkKind) -> Bool {
        switch kind {
        case .linuxSession, .linuxService: true
        case .modelRun: false
        }
    }
}
