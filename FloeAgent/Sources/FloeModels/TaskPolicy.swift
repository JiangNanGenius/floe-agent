import Foundation

public enum TaskRecoveryPolicy: String, Sendable, Codable, CaseIterable, Hashable {
    case safePoint
    case alwaysRetry
}

public enum TaskNotificationPolicy: String, Sendable, Codable, CaseIterable, Hashable {
    case off
    case terminal
    case critical
    case stages
}

public extension TaskNotificationPolicy {
    /// Whether a terminal (completed/failed) notification is sent.
    func shouldNotifyTerminal(succeeded: Bool) -> Bool {
        switch self {
        case .off: false
        case .terminal, .stages: true
        case .critical: !succeeded
        }
    }

    /// Mid-run stage/checkpoint notifications (`.stages` only).
    var shouldNotifyStages: Bool { self == .stages }

    /// Approval-required notifications: the task cannot continue without the
    /// user, so `.critical` and `.stages` both surface them.
    var shouldNotifyApproval: Bool {
        switch self {
        case .off, .terminal: false
        case .critical, .stages: true
        }
    }

    /// Cancellation is a terminal outcome, not a failure: `.critical`
    /// ("failures only") stays quiet, while `.terminal` and `.stages` report
    /// the real end of the run so the durable terminal event is not lost.
    var shouldNotifyCancellation: Bool {
        switch self {
        case .off, .critical: false
        case .terminal, .stages: true
        }
    }

    /// Action-required is the approval rule under the Build 222 durable-event
    /// vocabulary; it must not drift from `shouldNotifyApproval`.
    var shouldNotifyActionRequired: Bool { shouldNotifyApproval }
}

/// Platform-independent notification authorization state, mapped from
/// UNUserNotificationCenter in the app layer so the decision/policy logic
/// stays testable off-device.
public enum NotificationAuthorizationState: String, Sendable, Codable, Hashable {
    case notDetermined
    case denied
    /// Authorized normally (alert/sound may be delivered in the background).
    case authorized
    /// Provisional authorization: notifications arrive quietly.
    case provisional
    case ephemeral

    /// Whether a posted notification can be presented as a user-visible alert.
    public var canPresentAlert: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .denied, .notDetermined: false
        }
    }
}

public enum ConversationTitleOrigin: String, Sendable, Codable, CaseIterable, Hashable {
    case autoPending
    case automatic
    case manual
}

/// User-facing approval choice. Detailed capability and path fields remain
/// internal ceilings; the task UI intentionally exposes only these modes.
public enum TaskApprovalMode: String, Sendable, Codable, CaseIterable, Hashable {
    case ask
    case automatic
    case fullAccess
}

/// Policy selected before the first message creates a durable task.
public struct DraftTaskPolicy: Sendable, Codable, Hashable {
    public var approvalMode: TaskApprovalMode
    public var recoveryPolicy: TaskRecoveryPolicy
    public var notificationPolicy: TaskNotificationPolicy

    public init(
        approvalMode: TaskApprovalMode = .ask,
        recoveryPolicy: TaskRecoveryPolicy = .safePoint,
        notificationPolicy: TaskNotificationPolicy = .stages
    ) {
        self.approvalMode = approvalMode
        self.recoveryPolicy = recoveryPolicy
        self.notificationPolicy = notificationPolicy
    }
}

public struct TaskPolicy: Sendable, Codable, Hashable {
    public var conversationID: UUID
    public var approvalMode: String?
    public var allowedToolNames: Set<String>?
    public var filePaths: [String]
    public var networkAllowed: Bool?
    public var browserControlAllowed: Bool?
    public var uploadAllowed: Bool?
    public var credentialsAllowed: Bool?
    public var remoteExecutionAllowed: Bool?
    public var recoveryPolicy: TaskRecoveryPolicy
    public var notificationPolicy: TaskNotificationPolicy
    public var updatedAt: Date

    public var resolvedApprovalMode: TaskApprovalMode {
        guard let approvalMode else { return .ask }
        switch approvalMode {
        case TaskApprovalMode.automatic.rawValue, "approvalModel": return .automatic
        case TaskApprovalMode.fullAccess.rawValue, "fullControl": return .fullAccess
        default: return .ask
        }
    }

    public init(
        conversationID: UUID,
        approvalMode: String? = nil,
        allowedToolNames: Set<String>? = nil,
        filePaths: [String] = [],
        networkAllowed: Bool? = nil,
        browserControlAllowed: Bool? = nil,
        uploadAllowed: Bool? = nil,
        credentialsAllowed: Bool? = nil,
        remoteExecutionAllowed: Bool? = nil,
        recoveryPolicy: TaskRecoveryPolicy = .safePoint,
        notificationPolicy: TaskNotificationPolicy = .stages,
        updatedAt: Date = Date()
    ) {
        self.conversationID = conversationID
        self.approvalMode = approvalMode
        self.allowedToolNames = allowedToolNames
        self.filePaths = filePaths
        self.networkAllowed = networkAllowed
        self.browserControlAllowed = browserControlAllowed
        self.uploadAllowed = uploadAllowed
        self.credentialsAllowed = credentialsAllowed
        self.remoteExecutionAllowed = remoteExecutionAllowed
        self.recoveryPolicy = recoveryPolicy
        self.notificationPolicy = notificationPolicy
        self.updatedAt = updatedAt
    }
}
