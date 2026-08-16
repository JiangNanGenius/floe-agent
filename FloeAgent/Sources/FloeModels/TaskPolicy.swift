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

public enum ConversationTitleOrigin: String, Sendable, Codable, CaseIterable, Hashable {
    case autoPending
    case automatic
    case manual
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
