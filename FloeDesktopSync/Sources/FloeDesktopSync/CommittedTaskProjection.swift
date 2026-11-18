// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Integration layer between a committed SelfCore task (conversation + run)
/// and the local sync projection. It produces bounded, authorized snapshot and
/// incremental task updates:
///
/// 1. `bootstrapSnapshot` scans the host-owned canonical message feed with
///    bounded keyset pages and returns the committed messages plus the exact
///    replay watermark. Concurrent source edits are reconciled by replaying
///    feed changes after that watermark; a feed history rotation fails every
///    old watermark with `wrongGeneration`.
/// 2. `importSnapshot` writes the task header and the supported message
///    subset (user/assistant only) into the local `SyncStore` with the same
///    record shape the `RunProjectionProducer` produces, so a later run
///    projection coalesces revisions instead of colliding.
/// 3. `projectNextPage` advances the run-scoped projection from committed,
///    host-classified run events, resuming after the durable checkpoint
///    across restarts and refusing stale execution epochs.
/// 4. `readBack` re-reads the durable projection and re-verifies the current
///    authorization before returning it.
///
/// This layer never exports raw run events, payloads or credentials: feed
/// messages are reduced to `{runID, role, text}` records, run events reach
/// the store only as host-classified `ProjectionSourceEvent`s, and
/// authorization is limited to `(task, run, epoch)` checked against the
/// durable execution head owned by this device. It opens no sockets and
/// installs no listener; cross-device transport is a separate concern.
public enum CommittedTaskProjectionError: Error, Equatable, Sendable {
    /// No execution head was established for the run; the host must establish
    /// the current epoch before projecting.
    case executionHeadNotEstablished(runID: RunID)
    /// The durable head is bound to a different task.
    case authorizationTaskMismatch(expected: TaskID, found: TaskID)
    /// The durable head is owned by another device.
    case authorizationOwnerMismatch(expected: DeviceID, found: DeviceID)
    /// The claimed epoch is older than the durable head epoch.
    case staleAuthorization(taskID: TaskID, claimed: ExecutionEpoch, current: ExecutionEpoch)
    /// The claimed epoch is not the established one (a newer head exists and
    /// the caller did not observe it).
    case executionEpochNotCurrent(runID: RunID, claimed: ExecutionEpoch, current: ExecutionEpoch)
    /// A stored record blocks the projection shape.
    case incompatibleStoredRecord(RecordKey)
    /// The snapshot scan exceeded the page safety bound.
    case unboundedSnapshot(pages: Int)
    /// A tombstone was applied to a record that is not locally owned or is
    /// already in an inconsistent state.
    case incompatibleTombstone(UUID)
}

/// Authorized scope for projecting one committed SelfCore task. The task
/// identity is exactly the SelfCore conversation identity; the run identity
/// is the committed RunStore run; the epoch is the current execution
/// generation. Claims are checked against the durable execution head on
/// every driver entry point.
public struct CommittedTaskProjectionAuthorization: Sendable, Equatable {
    public let taskID: TaskID
    public let runID: RunID
    public let executionEpoch: ExecutionEpoch

    public init(taskID: TaskID, runID: RunID, executionEpoch: ExecutionEpoch) {
        self.taskID = taskID
        self.runID = runID
        self.executionEpoch = executionEpoch
    }
}

/// Bounded conversation header supplied by the authorized host from the
/// committed conversation row. Values are user content; they are never
/// credentials and never contain local paths.
public struct CommittedTaskConversationSummary: Sendable, Equatable {
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(title: String, createdAt: Date, updatedAt: Date) {
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Host-owned seam over the committed SelfCore database's canonical message
/// feed. The host implements it with its serialized SQLite read transactions
/// and the `FloeMacCanonicalFeedStorage` wrappers; every call runs inside the
/// host's transaction on the authoritative connection. Implementations must
/// not cache positions across calls and must not reorder messages.
public protocol CommittedCanonicalFeedSource: Sendable {
    func beginBootstrap(conversationID: UUID) async throws -> CanonicalMessageFeed.Bootstrap
    func bootstrapPage(
        _ bootstrap: CanonicalMessageFeed.Bootstrap,
        after: UUID?,
        limit: Int
    ) async throws -> CanonicalMessageFeed.BootstrapPage
    func changes(
        conversationID: UUID,
        after: CanonicalMessageFeed.Position,
        limit: Int
    ) async throws -> CanonicalMessageFeed.ChangePage
}

/// Complete bounded snapshot of one committed task's canonical messages.
public struct CommittedTaskSnapshot: Sendable, Equatable {
    public let authorization: CommittedTaskProjectionAuthorization
    /// Feed generation every page was read under. A history rotation fails
    /// every watermark of this generation with `wrongGeneration`.
    public let generation: UUID
    public let messages: [CanonicalMessageFeed.Message]
    /// Replay watermark: consume feed changes strictly after this position.
    public let resume: CanonicalMessageFeed.Position
    /// Number of bounded keyset pages scanned.
    public let pageCount: Int

    public init(
        authorization: CommittedTaskProjectionAuthorization,
        generation: UUID,
        messages: [CanonicalMessageFeed.Message],
        resume: CanonicalMessageFeed.Position,
        pageCount: Int
    ) {
        self.authorization = authorization
        self.generation = generation
        self.messages = messages
        self.resume = resume
        self.pageCount = pageCount
    }
}

/// One bounded incremental page of canonical feed changes for a committed
/// task. A change with `message == nil` is a tombstone: the message no longer
/// belongs to the conversation.
public struct CommittedTaskFeedChanges: Sendable, Equatable {
    public let changes: [CanonicalMessageFeed.Change]
    public let next: CanonicalMessageFeed.Position
    public let hasMore: Bool

    public init(changes: [CanonicalMessageFeed.Change], next: CanonicalMessageFeed.Position, hasMore: Bool) {
        self.changes = changes
        self.next = next
        self.hasMore = hasMore
    }
}

/// Receipt for a snapshot import into the local store.
public struct CommittedTaskImportReceipt: Sendable, Equatable {
    public let authorization: CommittedTaskProjectionAuthorization
    public let importedMessages: Int
    public let unchangedMessages: Int
    /// Messages whose role is outside the supported user/assistant subset;
    /// they are neither exported nor counted as imported.
    public let skippedMessages: Int
    public let taskRecordChanged: Bool
}

/// One message as verified by the durable read-back path.
public struct CommittedTaskMessageSummary: Sendable, Equatable {
    public let id: EntityID
    public let revision: Revision
    public let role: String
    public let runID: RunID?
    public let text: String
}

/// Verified local view of one committed task's projection. Every field was
/// re-read from the store after re-checking the durable execution head, so a
/// stale caller receives `staleAuthorization` instead of this value.
public struct CommittedTaskProjectionReadBack: Sendable, Equatable {
    public let authorization: CommittedTaskProjectionAuthorization
    public let conversationTitle: String?
    public let messages: [CommittedTaskMessageSummary]
    /// Durable run-projection watermark; `nil` before the first incremental
    /// projection committed.
    public let checkpointSourceSequence: Int64?
    /// Number of records appended by the last committed projection batch.
    public let checkpointAppendedRecords: Int?

    public init(
        authorization: CommittedTaskProjectionAuthorization,
        conversationTitle: String?,
        messages: [CommittedTaskMessageSummary],
        checkpointSourceSequence: Int64?,
        checkpointAppendedRecords: Int?
    ) {
        self.authorization = authorization
        self.conversationTitle = conversationTitle
        self.messages = messages
        self.checkpointSourceSequence = checkpointSourceSequence
        self.checkpointAppendedRecords = checkpointAppendedRecords
    }
}

/// Drives snapshot import, incremental projection and verified read-back for
/// committed SelfCore tasks against one local `SyncStore`. The store's
/// `deviceID` is the exclusive owner identity; every entry point re-checks
/// the durable execution head, so a stale epoch or foreign owner fails closed
/// before any record is written. Safe to reconstruct after a process restart.
public struct CommittedTaskProjectionDriver: Sendable {
    /// Hard safety bound for the snapshot keyset scan, independent of store
    /// configuration. The feed itself bounds each page to 100 messages.
    public static let maximumSnapshotPages = 4_096

    public let store: SyncStore

    public init(store: SyncStore) {
        self.store = store
    }

    // MARK: - Authorization

    /// Re-checks the durable execution head for the authorized scope. Refuses
    /// unestablished heads, task rebinding, foreign owners and stale epochs.
    public func verifyAuthorization(
        _ authorization: CommittedTaskProjectionAuthorization
    ) async throws {
        guard let head = try await store.executionHead(for: authorization.runID) else {
            throw CommittedTaskProjectionError.executionHeadNotEstablished(runID: authorization.runID)
        }
        guard head.taskID == authorization.taskID else {
            throw CommittedTaskProjectionError.authorizationTaskMismatch(
                expected: authorization.taskID,
                found: head.taskID
            )
        }
        guard head.ownerDeviceID == store.deviceID else {
            throw CommittedTaskProjectionError.authorizationOwnerMismatch(
                expected: store.deviceID,
                found: head.ownerDeviceID
            )
        }
        guard head.epoch == authorization.executionEpoch else {
            if head.epoch > authorization.executionEpoch {
                throw CommittedTaskProjectionError.staleAuthorization(
                    taskID: authorization.taskID,
                    claimed: authorization.executionEpoch,
                    current: head.epoch
                )
            }
            throw CommittedTaskProjectionError.executionEpochNotCurrent(
                runID: authorization.runID,
                claimed: authorization.executionEpoch,
                current: head.epoch
            )
        }
    }

    // MARK: - Snapshot

    /// Scans the committed canonical messages of the authorized task with
    /// bounded keyset pages and returns them with the exact replay watermark.
    /// The host must have established the execution head first; the scan does
    /// not write anything. Replaying `changes(after: snapshot.resume)`
    /// reconciles any concurrent source mutation, and a feed history rotation
    /// invalidates the watermark with `wrongGeneration`.
    public func bootstrapSnapshot(
        authorization: CommittedTaskProjectionAuthorization,
        feed: any CommittedCanonicalFeedSource,
        pageLimit: Int = 100
    ) async throws -> CommittedTaskSnapshot {
        try await verifyAuthorization(authorization)
        let bootstrap = try await feed.beginBootstrap(conversationID: authorization.taskID.rawUUID)
        var messages: [CanonicalMessageFeed.Message] = []
        var pages = 0
        var cursor: UUID? = nil
        repeat {
            try Task.checkCancellation()
            pages += 1
            guard pages <= Self.maximumSnapshotPages else {
                throw CommittedTaskProjectionError.unboundedSnapshot(pages: pages)
            }
            let page = try await feed.bootstrapPage(bootstrap, after: cursor, limit: pageLimit)
            messages.append(contentsOf: page.messages)
            cursor = page.nextMessageID
        } while cursor != nil
        return CommittedTaskSnapshot(
            authorization: authorization,
            generation: bootstrap.start.generation,
            messages: messages,
            resume: bootstrap.start,
            pageCount: pages
        )
    }

    /// Imports a previously authorized snapshot into the local store. Writes
    /// the task header plus the supported user/assistant message subset in
    /// the same record shape produced by `RunProjectionProducer`, coalescing
    /// revisions when a record already exists. Chunked by the store's batch
    /// limits; a chunk failure rolls back only that chunk, and re-importing
    /// an identical snapshot is a no-op.
    @discardableResult
    public func importSnapshot(
        _ snapshot: CommittedTaskSnapshot,
        conversation: CommittedTaskConversationSummary
    ) async throws -> CommittedTaskImportReceipt {
        try await verifyAuthorization(snapshot.authorization)
        let taskID = snapshot.authorization.taskID

        var records: [SyncRecord] = []
        records.append(
            try await coalescedRecord(
                kind: .task,
                entityID: try EntityID(validating: taskID.canonical),
                taskID: taskID,
                payload: .object([
                    "title": .string(conversation.title),
                    "createdAt": .string(SyncWireTime.rfc3339(conversation.createdAt)),
                    "updatedAt": .string(SyncWireTime.rfc3339(conversation.updatedAt)),
                ])
            )
        )
        var skipped = 0
        for message in snapshot.messages {
            guard message.conversationID == taskID.rawUUID else {
                // The feed only returns scoped rows; a mismatch means the
                // snapshot was swapped between scan and import.
                throw CommittedTaskProjectionError.incompatibleStoredRecord(
                    RecordKey(kind: .message, entityID: try EntityID(validating: message.id.uuidString))
                )
            }
            guard message.role == ProjectionCanonicalMessage.Role.user.rawValue
                    || message.role == ProjectionCanonicalMessage.Role.assistant.rawValue else {
                skipped += 1
                continue
            }
            records.append(
                try await coalescedRecord(
                    kind: .message,
                    entityID: try EntityID(validating: message.id.uuidString),
                    taskID: taskID,
                    payload: messagePayload(message: message)
                )
            )
        }

        let batchLimit = max(1, store.configuration.maxBatchRecords)
        var imported = 0
        var unchanged = 0
        var taskChanged = false
        var index = 0
        while index < records.count {
            try Task.checkCancellation()
            let end = min(index + batchLimit, records.count)
            let outcomes = try await store.commitLocalRecords(Array(records[index..<end]))
            for (offset, outcome) in outcomes.enumerated() {
                let isTaskRecord = index + offset == 0
                switch outcome {
                case .appended:
                    if isTaskRecord { taskChanged = true } else { imported += 1 }
                case .unchanged:
                    if !isTaskRecord { unchanged += 1 }
                }
            }
            index = end
        }
        return CommittedTaskImportReceipt(
            authorization: snapshot.authorization,
            importedMessages: imported,
            unchangedMessages: unchanged,
            skippedMessages: skipped,
            taskRecordChanged: taskChanged
        )
    }

    // MARK: - Incremental

    /// Reads one bounded canonical-feed change page for the authorized task.
    /// This is the conversation-level reconciliation stream (including
    /// tombstones); run-scoped record projection goes through
    /// `projectNextPage`. The caller persists `next` only after applying the
    /// page, exactly like the feed contract requires.
    public func changes(
        authorization: CommittedTaskProjectionAuthorization,
        feed: any CommittedCanonicalFeedSource,
        after: CanonicalMessageFeed.Position,
        limit: Int = 100
    ) async throws -> CommittedTaskFeedChanges {
        try await verifyAuthorization(authorization)
        let page = try await feed.changes(
            conversationID: authorization.taskID.rawUUID,
            after: after,
            limit: limit
        )
        return CommittedTaskFeedChanges(changes: page.changes, next: page.next, hasMore: page.hasMore)
    }

    /// Applies one feed tombstone (`change.message == nil`): the message no
    /// longer belongs to the committed conversation, so its local record is
    /// marked deleted with the next revision. Live-message upserts are the
    /// run projection's job and are refused here to keep one writer per
    /// record shape.
    @discardableResult
    public func applyFeedTombstone(
        _ change: CanonicalMessageFeed.Change,
        authorization: CommittedTaskProjectionAuthorization
    ) async throws -> RecordCommitOutcome {
        guard change.message == nil else {
            throw CommittedTaskProjectionError.incompatibleTombstone(change.messageID)
        }
        try await verifyAuthorization(authorization)
        let entityID = try EntityID(validating: change.messageID.uuidString)
        let existing = try await store.storedRecord(kind: .message, entityID: entityID)
        guard let existing else {
            // Nothing local to delete; the tombstone is already effective.
            return .unchanged
        }
        guard existing.record.taskID == authorization.taskID,
              existing.record.originDeviceID == store.deviceID else {
            throw CommittedTaskProjectionError.incompatibleTombstone(change.messageID)
        }
        // Replaying an already-effective tombstone (after a restart or a
        // redelivered page) is an idempotent no-op, not a conflict.
        if existing.record.deleted {
            return .unchanged
        }
        guard existing.record.revision.rawValue < Int64.max else {
            throw RunProjectionProducerError.revisionOverflow
        }
        let record = SyncRecord(
            kind: .message,
            entityID: entityID,
            taskID: authorization.taskID,
            revision: try Revision(existing.record.revision.rawValue + 1),
            baseRevision: existing.record.revision,
            baseDigest: existing.payloadDigest,
            originDeviceID: store.deviceID,
            payload: existing.record.payload,
            deleted: true
        )
        return try await store.commitLocalRecord(record)
    }

    /// Advances the run-scoped projection by one bounded page of committed,
    /// host-classified run events. The saved checkpoint and records commit
    /// atomically; after a restart the same call resumes after the durable
    /// watermark. Stale epochs and rebinding are refused both here and by
    /// the store transaction.
    @discardableResult
    public func projectNextPage(
        authorization: CommittedTaskProjectionAuthorization,
        source: any RunProjectionSource,
        limit: Int = 64
    ) async throws -> RunProjectionCommit? {
        try await verifyAuthorization(authorization)
        let producer = RunProjectionProducer(store: store, source: source)
        return try await producer.projectNextPage(
            taskID: authorization.taskID,
            runID: authorization.runID,
            executionEpoch: authorization.executionEpoch,
            limit: limit
        )
    }

    // MARK: - Read-back

    /// Re-reads the durable projection for the authorized scope and returns
    /// it only after re-verifying the current execution head. `messageIDs`
    /// are the committed message identities the caller expects (e.g. from a
    /// snapshot or an applied change page); every one must be present,
    /// locally owned, undeleted and bound to this task.
    public func readBack(
        authorization: CommittedTaskProjectionAuthorization,
        messageIDs: [EntityID]
    ) async throws -> CommittedTaskProjectionReadBack {
        try await verifyAuthorization(authorization)
        let taskID = authorization.taskID

        var title: String? = nil
        if let taskRecord = try await store.storedRecord(
            kind: .task,
            entityID: try EntityID(validating: taskID.canonical)
        ) {
            guard taskRecord.record.taskID == taskID,
                  taskRecord.record.originDeviceID == store.deviceID,
                  !taskRecord.record.deleted else {
                throw CommittedTaskProjectionError.incompatibleStoredRecord(
                    RecordKey(kind: .task, entityID: try EntityID(validating: taskID.canonical))
                )
            }
            title = taskRecord.record.payload["title"]?.stringValue
        }

        var summaries: [CommittedTaskMessageSummary] = []
        for entityID in messageIDs {
            guard let stored = try await store.storedRecord(kind: .message, entityID: entityID) else {
                throw CommittedTaskProjectionError.incompatibleStoredRecord(
                    RecordKey(kind: .message, entityID: entityID)
                )
            }
            let record = stored.record
            guard record.taskID == taskID,
                  record.originDeviceID == store.deviceID,
                  !record.deleted else {
                throw CommittedTaskProjectionError.incompatibleStoredRecord(
                    RecordKey(kind: .message, entityID: entityID)
                )
            }
            let runID: RunID?
            if let raw = record.payload["runID"]?.stringValue {
                runID = try RunID(validating: raw)
            } else {
                runID = nil
            }
            summaries.append(
                CommittedTaskMessageSummary(
                    id: entityID,
                    revision: record.revision,
                    role: record.payload["role"]?.stringValue ?? "",
                    runID: runID,
                    text: record.payload["text"]?.stringValue ?? ""
                )
            )
        }

        var checkpointSequence: Int64? = nil
        var checkpointAppended: Int? = nil
        if let checkpoint = try await store.runProjectionCheckpoint(for: authorization.runID) {
            guard checkpoint.taskID == taskID,
                  checkpoint.ownerDeviceID == store.deviceID else {
                throw CommittedTaskProjectionError.incompatibleStoredRecord(
                    RecordKey(kind: .run, entityID: try EntityID(validating: authorization.runID.canonical))
                )
            }
            checkpointSequence = checkpoint.sourceSequence
            checkpointAppended = checkpoint.appendedRecords
        }

        return CommittedTaskProjectionReadBack(
            authorization: authorization,
            conversationTitle: title,
            messages: summaries,
            checkpointSourceSequence: checkpointSequence,
            checkpointAppendedRecords: checkpointAppended
        )
    }

    // MARK: - Record construction

    /// Builds a record in the exact shape produced by `RunProjectionProducer`
    /// so snapshot import and incremental projection share one revision
    /// lineage per entity. An identical existing record is reused unchanged;
    /// a modified one gets the next revision with the observed baseline.
    private func coalescedRecord(
        kind: SyncEntityKind,
        entityID: EntityID,
        taskID: TaskID,
        payload: JSONValue
    ) async throws -> SyncRecord {
        let existing = try await store.storedRecord(kind: kind, entityID: entityID)
        if let existing {
            guard existing.record.taskID == taskID,
                  existing.record.workspaceID == nil,
                  existing.record.originDeviceID == store.deviceID,
                  !existing.record.deleted else {
                throw CommittedTaskProjectionError.incompatibleStoredRecord(
                    RecordKey(kind: kind, entityID: entityID)
                )
            }
            if existing.record.payload == payload {
                return existing.record
            }
            guard existing.record.revision.rawValue < Int64.max else {
                throw RunProjectionProducerError.revisionOverflow
            }
            return SyncRecord(
                kind: kind,
                entityID: entityID,
                taskID: taskID,
                revision: try Revision(existing.record.revision.rawValue + 1),
                baseRevision: existing.record.revision,
                baseDigest: existing.payloadDigest,
                originDeviceID: store.deviceID,
                payload: payload
            )
        }
        return SyncRecord(
            kind: kind,
            entityID: entityID,
            taskID: taskID,
            revision: try Revision(1),
            originDeviceID: store.deviceID,
            payload: payload
        )
    }

    private func messagePayload(message: CanonicalMessageFeed.Message) -> JSONValue {
        .object([
            "runID": message.runID.map { JSONValue.string($0.uuidString.lowercased()) } ?? .null,
            "role": .string(message.role),
            "text": .string(message.content),
        ])
    }
}

private extension TaskID {
    /// The SelfCore conversation identity behind a task identity.
    var rawUUID: UUID {
        guard let uuid = UUID(uuidString: canonical) else {
            // `StableIdentifier` validates the canonical form at creation.
            preconditionFailure("task identity is not a UUID: \(canonical)")
        }
        return uuid
    }
}
