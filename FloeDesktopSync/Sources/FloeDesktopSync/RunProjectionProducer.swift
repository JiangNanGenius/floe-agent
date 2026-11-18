import Foundation

/// An explicit, host-classified source event. Unknown event kinds must be
/// `.unsupported`, not discarded. Raw RunStore payloads are never accepted.
/// A message reference must come from a durable mapping to its canonical ID;
/// a streamed assistant-text segment alone does not provide such a mapping.
public struct ProjectionSourceEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case canonicalMessage(EntityID)
        /// Reasoning is intentionally excluded from this minimal projection.
        case excludedReasoning
        case unsupported
    }

    public let taskID: TaskID
    public let runID: RunID
    public let sequence: Int64
    public let kind: Kind

    public init(taskID: TaskID, runID: RunID, sequence: Int64, kind: Kind) {
        self.taskID = taskID
        self.runID = runID
        self.sequence = sequence
        self.kind = kind
    }
}

/// The supported subset of a canonical message. The trusted host must reject
/// unsupported parts instead of silently dropping them before returning it.
/// Text is user content and may itself contain sensitive data; this type does
/// not sanitize it or confer authorization to synchronize it.
public struct ProjectionCanonicalMessage: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }
    public let id: EntityID
    public let taskID: TaskID
    public let runID: RunID
    public let role: Role
    public let text: String

    public init(id: EntityID, taskID: TaskID, runID: RunID, role: Role, text: String) {
        self.id = id
        self.taskID = taskID
        self.runID = runID
        self.role = role
        self.text = text
    }
}

/// Implemented only by an already-authorized local host, with durable,
/// ordered, gap-free event reads and canonical-message lookup. This protocol
/// is a seam, not a RunStore adapter or an authentication mechanism. It must
/// not expose ephemeral/temporary conversations to this producer.
public protocol RunProjectionSource: Sendable {
    func events(taskID: TaskID, runID: RunID, afterSequence: Int64, limit: Int) async throws -> [ProjectionSourceEvent]
    func message(id: EntityID) async throws -> ProjectionCanonicalMessage?
}

public enum RunProjectionProducerError: Error, Equatable, Sendable {
    case invalidPageLimit
    case executionBindingMismatch
    case checkpointBindingMismatch
    case oversizedPage
    case sourceSequenceMismatch
    case sourceBindingMismatch
    case unsupportedEvent
    case canonicalMessageMissing
    case canonicalMessageMismatch
    case messageTooLarge
    case incompatibleStoredMessage
    case revisionOverflow
}

/// Projects at most one bounded source page per call. The saved local cursor
/// and records advance atomically; network publication is a separate concern.
/// A caller may invoke it again after restart. No task execution is started.
public struct RunProjectionProducer: Sendable {
    public static let maximumPageSize = 128
    public static let maximumMessageBytes = 64 * 1_024
    public let store: SyncStore
    public let source: any RunProjectionSource

    public init(store: SyncStore, source: any RunProjectionSource) {
        self.store = store
        self.source = source
    }

    @discardableResult
    public func projectNextPage(taskID: TaskID, runID: RunID, executionEpoch: ExecutionEpoch,
                                limit: Int = 64) async throws -> RunProjectionCommit? {
        guard (1...Self.maximumPageSize).contains(limit) else {
            throw RunProjectionProducerError.invalidPageLimit
        }
        try Task.checkCancellation()
        guard let head = try await store.executionHead(for: runID),
              head.taskID == taskID, head.epoch == executionEpoch,
              head.ownerDeviceID == store.deviceID else {
            throw RunProjectionProducerError.executionBindingMismatch
        }
        let checkpoint = try await store.runProjectionCheckpoint(for: runID)
        if let checkpoint {
            guard checkpoint.taskID == taskID, checkpoint.ownerDeviceID == store.deviceID,
                  checkpoint.executionEpoch == executionEpoch else {
                throw RunProjectionProducerError.checkpointBindingMismatch
            }
        }
        let after = checkpoint?.sourceSequence ?? 0
        let page = try await source.events(taskID: taskID, runID: runID, afterSequence: after, limit: limit)
        guard page.count <= limit else { throw RunProjectionProducerError.oversizedPage }
        guard !page.isEmpty else { return nil }

        var previous = after
        var messageIDs: [EntityID] = []
        var seen = Set<EntityID>()
        for event in page {
            guard event.taskID == taskID, event.runID == runID else {
                throw RunProjectionProducerError.sourceBindingMismatch
            }
            guard previous < Int64.max, event.sequence == previous + 1 else {
                throw RunProjectionProducerError.sourceSequenceMismatch
            }
            previous = event.sequence
            switch event.kind {
            case .canonicalMessage(let id):
                if seen.insert(id).inserted { messageIDs.append(id) }
            case .excludedReasoning:
                break
            case .unsupported:
                throw RunProjectionProducerError.unsupportedEvent
            }
        }

        var records: [SyncRecord] = []
        for id in messageIDs {
            try Task.checkCancellation()
            guard let message = try await source.message(id: id) else {
                throw RunProjectionProducerError.canonicalMessageMissing
            }
            guard message.id == id, message.taskID == taskID, message.runID == runID else {
                throw RunProjectionProducerError.canonicalMessageMismatch
            }
            guard message.text.utf8.count <= Self.maximumMessageBytes else {
                throw RunProjectionProducerError.messageTooLarge
            }
            let payload: JSONValue = .object([
                "runID": .string(runID.canonical),
                "role": .string(message.role.rawValue),
                "text": .string(message.text)
            ])
            let existing = try await store.storedRecord(kind: .message, entityID: id)
            if let existing {
                guard existing.record.taskID == taskID, existing.record.workspaceID == nil,
                      existing.record.originDeviceID == store.deviceID, !existing.record.deleted else {
                    throw RunProjectionProducerError.incompatibleStoredMessage
                }
            }
            let unchanged = existing?.record.payload == payload
            let revision: Revision
            if let existing, unchanged {
                revision = existing.record.revision
            } else if let existing {
                guard existing.record.revision.rawValue < Int64.max else {
                    throw RunProjectionProducerError.revisionOverflow
                }
                revision = try Revision(existing.record.revision.rawValue + 1)
            } else {
                revision = try Revision(1)
            }
            records.append(SyncRecord(kind: .message, entityID: id, taskID: taskID,
                                      revision: revision,
                                      baseRevision: unchanged ? nil : existing?.record.revision,
                                      baseDigest: unchanged ? nil : existing?.payloadDigest,
                                      originDeviceID: store.deviceID, payload: payload))
        }
        try Task.checkCancellation()
        return try await store.applyLocalRunProjection(LocalRunProjectionBatch(
            taskID: taskID, runID: runID, executionEpoch: executionEpoch,
            afterSequence: after, throughSequence: previous, records: records))
    }
}
