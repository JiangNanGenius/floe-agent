import Foundation

public enum TaskScheduleCadence: String, Sendable, Codable, CaseIterable, Hashable {
    case once
    case daily
    case weekly
}

public struct TaskScheduleRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var prompt: String
    public var workspaceID: UUID?
    public var cadence: TaskScheduleCadence
    public var scheduledAt: Date
    public var weekday: Int?
    public var isEnabled: Bool
    public var lastStartedAt: Date?
    public var nextExpectedAt: Date?
    public var policyJSON: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        prompt: String,
        workspaceID: UUID? = nil,
        cadence: TaskScheduleCadence,
        scheduledAt: Date,
        weekday: Int? = nil,
        isEnabled: Bool = true,
        lastStartedAt: Date? = nil,
        nextExpectedAt: Date? = nil,
        policyJSON: String = "{}",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.cadence = cadence
        self.scheduledAt = scheduledAt
        self.weekday = weekday
        self.isEnabled = isEnabled
        self.lastStartedAt = lastStartedAt
        self.nextExpectedAt = nextExpectedAt ?? scheduledAt
        self.policyJSON = policyJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
