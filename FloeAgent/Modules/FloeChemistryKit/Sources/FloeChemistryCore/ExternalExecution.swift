import Foundation

/// Supplied by the host from an existing authorized task and durable execution run.
/// Project contents and model arguments are never an execution authority.
public struct ChemistryExecutionOwner: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let hostRunID: UUID
    public init(taskID: UUID, hostRunID: UUID) {
        self.taskID = taskID; self.hostRunID = hostRunID
    }
}

public struct ChemistryExecutionIdentity: Codable, Sendable, Equatable {
    public let projectID: UUID
    public let runID: UUID
    public let objectID: UUID
    public let objectRevision: UInt64
    public let inputDigest: String
    public let taskID: UUID
    public let hostRunID: UUID
    public let environmentID: String
    public let attemptID: UUID

    public var owner: ChemistryExecutionOwner { .init(taskID: taskID, hostRunID: hostRunID) }
    public init(projectID: UUID, run: ChemistryRun, owner: ChemistryExecutionOwner, attemptID: UUID = UUID()) {
        self.projectID = projectID; runID = run.id; objectID = run.input.id
        objectRevision = run.input.revision; inputDigest = run.inputDigest
        taskID = owner.taskID; hostRunID = owner.hostRunID
        environmentID = run.environmentID; self.attemptID = attemptID
    }
}

/// A frozen request and optional verified job receipt. Loading this record never resubmits it.
public struct ChemistryExternalExecution: Codable, Sendable, Equatable {
    public let identity: ChemistryExecutionIdentity
    public let requestJSON: String
    public let requestDigest: String
    public var jobID: UUID?
    public init(identity: ChemistryExecutionIdentity, requestJSON: String, requestDigest: String) {
        self.identity = identity; self.requestJSON = requestJSON; self.requestDigest = requestDigest
    }
}
