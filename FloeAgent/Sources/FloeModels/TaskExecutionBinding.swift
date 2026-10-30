import Foundation

/// Trusted execution identity. Providers and Skill manifests cannot mint a binding.
public struct TaskExecutionTarget: Codable, Sendable, Hashable, Identifiable {
    public enum Backend: String, Codable, Sendable { case linuxVM, macBridge, remoteSSH }
    public var id: String { environmentID }
    public var environmentID: String
    public var backend: Backend
    public var remoteHostID: UUID?
    public var remoteRootPath: String?
    public var operatingSystem: String
    public var architecture: String
    /// Actual boot/bridge identity; nil is unknown, never a fabricated generation.
    public var runtimeGeneration: String?

    public init(environmentID: String, backend: Backend, remoteHostID: UUID? = nil,
                remoteRootPath: String? = nil, operatingSystem: String,
                architecture: String, runtimeGeneration: String? = nil) {
        self.environmentID = environmentID; self.backend = backend
        self.remoteHostID = remoteHostID; self.remoteRootPath = remoteRootPath
        self.operatingSystem = operatingSystem; self.architecture = architecture
        self.runtimeGeneration = runtimeGeneration
    }
}

public struct TaskExecutionBinding: Codable, Sendable, Hashable {
    public var conversationID: UUID
    public var target: TaskExecutionTarget
    public var generation: Int64
    public var updatedAt: Date

    public func encoded() throws -> String {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    public static func decoded(_ json: String) throws -> Self {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Self.self, from: Data(json.utf8))
    }

    public init(conversationID: UUID, target: TaskExecutionTarget,
                generation: Int64 = 1, updatedAt: Date = Date()) {
        self.conversationID = conversationID; self.target = target
        self.generation = generation; self.updatedAt = updatedAt
    }
}

public struct TaskEnvironmentMigration: Codable, Sendable, Hashable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case checking, waiting, preparing, verifying, verified, committed, completed, failed, cancelled
        public var isTerminal: Bool { self == .completed || self == .cancelled }
        public var isCommitted: Bool { self == .committed || self == .completed }
    }
    public var id: UUID
    public var source: TaskExecutionBinding
    public var target: TaskExecutionTarget
    public var phase: Phase
    public var revision: Int64
    public var preparedFileCount: Int
    public var preparedBytes: Int64
    public var manifestDigest: String?
    public var skillDigests: [String: String]?
    public var dependencyReceiptDigest: String?
    public var cancellationRequested: Bool?
    public var preparationOutcomeUnknown: Bool?
    public var preparationOperationIDs: [UUID]?
    public var acceptedCapabilityLosses: [String]?
    public var requiredSkillIDs: [String]?
    public var failure: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), source: TaskExecutionBinding, target: TaskExecutionTarget) {
        self.id = id; self.source = source; self.target = target; phase = .checking
        revision = 1; preparedFileCount = 0; preparedBytes = 0
        createdAt = Date(); updatedAt = createdAt
    }
}
