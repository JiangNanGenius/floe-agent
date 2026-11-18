import Foundation

/// Optional deterministic seams used by the package's race tests. Production
/// callers never set these; they run only after a read transaction has already
/// established its SQLite snapshot.
struct SyncStoreTestHooks: Sendable {
    var afterChangesValidation: (@Sendable () throws -> Void)?
    var afterSnapshotValidation: (@Sendable () throws -> Void)?
    /// Runs inside the page-staging write transaction after the page row and
    /// its records were inserted, but before the import counters advance.
    /// Throwing proves a half-written page rolls back as one unit.
    var afterSnapshotPageStaged: (@Sendable () throws -> Void)?
    /// Runs inside the commit transaction after visible records, conflicts and
    /// local-preservation diagnostics were written, but before the scope
    /// cursor and committed receipt are finalized. Throwing proves a crash
    /// leaves the old visible state and old cursor untouched.
    var beforeSnapshotCommitFinalize: (@Sendable () throws -> Void)?
    /// Runs inside the incremental apply transaction after every change was
    /// applied and its conflicts persisted, but before the scope cursor CAS
    /// and replay receipt. Throwing proves records, conflicts and cursor roll
    /// back together as one unit.
    var afterIncrementalRecordsApplied: (@Sendable () throws -> Void)?
    /// Fails after local projection rows and change entries have been written
    /// but before COMMIT, proving a task batch cannot become partially visible.
    var afterLocalBatchRecordsApplied: (@Sendable () throws -> Void)?
    /// Runs after projection records are written but before their source
    /// checkpoint is saved; throwing must roll back the whole transaction.
    var beforeRunProjectionCheckpoint: (@Sendable () throws -> Void)?
}

/// SQLite-backed persistence foundation for the Floe cross-device protocol.
///
/// The actor serializes all database access. Every mutating operation that
/// touches more than one row is a single `BEGIN IMMEDIATE` transaction, so a
/// crash or thrown error cannot leave a record applied without its cursor (or
/// the reverse).
public actor SyncStore {
    public nonisolated let deviceID: DeviceID
    public nonisolated let configuration: SyncStoreConfiguration

    private let connection: SQLiteConnection
    private let clock: @Sendable () -> Date
    private let testHooks: SyncStoreTestHooks
    private var sidecarsSecured = false
    /// Attached by the pairing/transport integration. When nil, every
    /// incremental batch is refused: a caller cannot opt into trust with a
    /// Boolean or a bare integrity digest.
    private var incrementalAuthenticator: (any IncrementalAuthenticator)?
    private var snapshotAuthenticator: HMACSnapshotAuthenticator?

    /// Reads are intentionally not gated by the current write-payload limit:
    /// a database created under an older limit must remain inspectable. New
    /// writes are still limited by `configuration.maxPayloadBytes`.
    private static let maximumReadBytes = 16 * 1_024 * 1_024
    static let maximumWireBytes = 17 * 1_024 * 1_024
    static let maximumWireNodes = 100_000
    static let maximumManifestBytes = 64 * 1_024 * 1_024
    static let maximumManifestNodes = 1_000_000
    /// Fixed per-entry staging accounting cost (row metadata, key text and
    /// SQLite overhead) added to canonical payload bytes. The hard metadata
    /// bound is also enforced by entry/page limits.
    static let snapshotStagingEntryOverhead = 256

    public init(
        path: String,
        deviceID: DeviceID,
        configuration: SyncStoreConfiguration = SyncStoreConfiguration(),
        clock: @escaping @Sendable () -> Date = { Date() },
        incrementalAuthenticator: (any IncrementalAuthenticator)? = nil
    ) throws {
        try self.init(
            path: path,
            deviceID: deviceID,
            configuration: configuration,
            clock: clock,
            testHooks: SyncStoreTestHooks(),
            incrementalAuthenticator: incrementalAuthenticator
        )
    }

    init(
        path: String,
        deviceID: DeviceID,
        configuration: SyncStoreConfiguration,
        clock: @escaping @Sendable () -> Date,
        testHooks: SyncStoreTestHooks,
        incrementalAuthenticator: (any IncrementalAuthenticator)? = nil
    ) throws {
        try configuration.validate()
        if configuration.enforceSecurePermissions {
            try SyncStore.prepareSecureDirectory(forDatabasePath: path)
        }
        let connection = try SQLiteConnection(path: path)
        do {
            if configuration.enforceSecurePermissions {
                // The connection enables WAL, which may already have created
                // the sidecars. Tighten them before schema writes begin.
                try SyncStore.secureDatabaseFiles(path: path)
            }
            try SyncSchema.migrateIfNeeded(connection)
            try SyncStore.ensureIdentity(
                connection,
                deviceID: deviceID,
                nowMillis: SyncStore.millis(clock())
            )
            if configuration.enforceSecurePermissions {
                try SyncStore.secureDatabaseFiles(path: path)
            }
        } catch {
            connection.close()
            throw error
        }
        self.deviceID = deviceID
        self.configuration = configuration
        self.connection = connection
        self.clock = clock
        self.testHooks = testHooks
        self.incrementalAuthenticator = incrementalAuthenticator
    }

    public func close() {
        connection.close()
    }

    /// Installs or replaces the trusted incremental authenticator after the
    /// integration has loaded pairing keys from approved storage. The default
    /// state remains fail-closed; this is an explicit trust decision by the
    /// host application, not a value supplied by an inbound batch.
    public func installIncrementalAuthenticator(
        _ authenticator: any IncrementalAuthenticator
    ) {
        incrementalAuthenticator = authenticator
    }

    /// Local pairing integration only: never install a verifier from a frame.
    public func installSnapshotAuthenticator(_ authenticator: HMACSnapshotAuthenticator) {
        snapshotAuthenticator = authenticator
    }

    private func verifySnapshotAuthentication(_ signed: AuthenticatedSnapshotManifest) throws {
        guard let snapshotAuthenticator else { throw SyncStoreError.snapshotImportUnverified }
        guard signed.manifest.pageCount <= configuration.maxSnapshotPages,
              signed.manifest.entryCount <= configuration.maxSnapshotEntries,
              signed.manifest.pageSize <= configuration.maxPageSize else {
            throw SyncStoreError.snapshotTooLarge("manifest exceeds configured limits")
        }
        if let incremental = incrementalAuthenticator as? HMACIncrementalAuthenticator {
            try snapshotAuthenticator.validatePeerKeyIsolation(from: incremental)
        }
        try snapshotAuthenticator.authenticate(signed, receiverDeviceID: deviceID)
    }

    // MARK: - Command ledger

    /// Durably accepts a command before any side effect is attempted. A retry
    /// with the same command identity and identical intent returns the stored
    /// receipt; the same identity with different intent is a conflict.
    public func accept(_ command: SyncCommand) throws -> CommandAcceptance {
        // Protocol/envelope checks still apply to every retry. Only the v2
        // target/revision pairing is deferred so a v1 command can be matched
        // by its original ID and digest below.
        try command.validateShape(allowingLegacyTarget: true)
        // Bound the canonical bytes and graph before any serialization or
        // hashing, including the duplicate lookup path that must still read
        // commands accepted under older, larger limits.
        let readLimit = max(SyncStore.maximumReadBytes, configuration.maxPayloadBytes)
        guard command.payload.canonicalByteCount(upTo: readLimit) <= readLimit else {
            throw SyncStoreError.payloadTooLarge(limit: readLimit)
        }
        let fingerprints = try command.fingerprints()
        let payloadBytes = command.payload.canonicalUTF8
        let now = nowMillis()

        return try writeTransaction { connection in
            // The duplicate lookup happens before current payload-policy and
            // size checks. A command accepted by an older build must still be
            // retrievable by its original identity after limits are tightened.
            if let existing = try SyncStore.loadStoredCommand(
                connection,
                id: command.commandID,
                maxPayloadBytes: SyncStore.maximumReadBytes
            ) {
                guard existing.commandDigest == fingerprints.intent else {
                    throw SyncStoreError.payloadConflict(command.commandID)
                }
                return CommandAcceptance(isDuplicate: true, receipt: existing.receipt)
            }

            try command.validateShape()
            guard payloadBytes.count <= configuration.maxPayloadBytes else {
                throw SyncStoreError.payloadTooLarge(limit: configuration.maxPayloadBytes)
            }
            try PortabilityPolicy.validate(command.payload)
            if command.kind == .workspaceCommitFile,
               let path = command.payload["path"]?.stringValue {
                try PortabilityPolicy.validatePortableRelativePath(path)
            }

            if command.runID != nil {
                try SyncStore.requireCurrentEpoch(connection, command: command)
            }

            let statement = try connection.prepare(
                """
                INSERT INTO commands (
                    command_id, protocol_major, protocol_minor, kind, task_id,
                    workspace_id, run_id, expected_revision, execution_epoch,
                    target_entity_kind, target_entity_id,
                    payload, payload_digest, command_digest, state, result,
                    accepted_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
                """
            )
            try statement.bind(1, command.commandID.canonical)
            try statement.bind(2, Int64(command.protocolVersion.major))
            try statement.bind(3, Int64(command.protocolVersion.minor))
            try statement.bind(4, command.kind.rawValue)
            try SyncStore.bindOptionalText(statement, 5, command.taskID?.canonical)
            try SyncStore.bindOptionalText(statement, 6, command.workspaceID?.canonical)
            try SyncStore.bindOptionalText(statement, 7, command.runID?.canonical)
            try SyncStore.bindOptionalInt64(statement, 8, command.expectedRevision?.rawValue)
            try SyncStore.bindOptionalInt64(statement, 9, command.executionEpoch?.rawValue)
            try SyncStore.bindOptionalText(statement, 10, command.targetKey?.kind.rawValue)
            try SyncStore.bindOptionalText(statement, 11, command.targetKey?.entityID.canonical)
            try statement.bind(12, payloadBytes)
            try statement.bind(13, fingerprints.payload.description)
            try statement.bind(14, fingerprints.intent.description)
            try statement.bind(15, CommandState.accepted.rawValue)
            try statement.bind(16, now)
            try statement.bind(17, now)
            _ = try statement.step()

            let receipt = CommandReceipt(
                commandID: command.commandID,
                state: .accepted,
                result: nil,
                acceptedAt: SyncStore.date(now),
                updatedAt: SyncStore.date(now),
                payloadDigest: fingerprints.payload
            )
            return CommandAcceptance(isDuplicate: false, receipt: receipt)
        }
    }

    public func storedCommand(for commandID: CommandID) throws -> StoredCommand? {
        let connection = try openConnection()
        return try SyncStore.loadStoredCommand(
            connection,
            id: commandID,
            maxPayloadBytes: SyncStore.maximumReadBytes
        )
    }

    public func receipt(for commandID: CommandID) throws -> CommandReceipt? {
        try storedCommand(for: commandID)?.receipt
    }

    /// Starts execution with an explicit authenticated principal. A command
    /// without a bound authentication identity is not startable.
    public func markStarted(
        _ commandID: CommandID,
        authenticatedDeviceID: DeviceID
    ) throws -> CommandReceipt {
        try transition(
            commandID,
            to: .started,
            result: nil,
            authenticatedDeviceID: authenticatedDeviceID
        )
    }

    public func complete(_ commandID: CommandID, result: JSONValue? = nil) throws -> CommandReceipt {
        try transition(commandID, to: .completed, result: result)
    }

    public func fail(_ commandID: CommandID, result: JSONValue? = nil) throws -> CommandReceipt {
        try transition(commandID, to: .failed, result: result)
    }

    public func cancel(_ commandID: CommandID, result: JSONValue? = nil) throws -> CommandReceipt {
        try transition(commandID, to: .cancelled, result: result)
    }

    /// Marks a started command as outcome-unknown without retrying it. This is
    /// also what `recoverInterruptedCommands` uses after a process restart.
    public func markOutcomeUnknown(_ commandID: CommandID) throws -> CommandReceipt {
        try transition(commandID, to: .outcomeUnknown, result: nil)
    }

    /// Commands that were durably marked `started` but never reached a result
    /// become `outcomeUnknown`. Accepted-but-not-started commands stay
    /// accepted; they did not begin an external side effect.
    @discardableResult
    public func recoverInterruptedCommands() throws -> [CommandID] {
        try writeTransaction { connection in
            let select = try connection.prepare(
                "SELECT command_id FROM commands WHERE state = ? ORDER BY command_id"
            )
            try select.bind(1, CommandState.started.rawValue)
            var identifiers: [CommandID] = []
            while try select.step() {
                guard let text = select.text(0) else {
                    throw SyncStoreError.schemaCorrupt("command row has no command_id")
                }
                identifiers.append(try CommandID(validating: text))
            }
            guard !identifiers.isEmpty else { return [] }

            let now = nowMillis()
            let update = try connection.prepare(
                "UPDATE commands SET state = ?, updated_at = ? WHERE command_id = ? AND state = ?"
            )
            for identifier in identifiers {
                update.reset()
                try update.bind(1, CommandState.outcomeUnknown.rawValue)
                try update.bind(2, now)
                try update.bind(3, identifier.canonical)
                try update.bind(4, CommandState.started.rawValue)
                _ = try update.step()
            }
            return identifiers
        }
    }

    private func transition(
        _ commandID: CommandID,
        to newState: CommandState,
        result: JSONValue?,
        authenticatedDeviceID: DeviceID? = nil
    ) throws -> CommandReceipt {
        try writeTransaction { connection in
            guard let stored = try SyncStore.loadStoredCommand(
                connection,
                id: commandID,
                maxPayloadBytes: SyncStore.maximumReadBytes
            ) else {
                throw SyncStoreError.commandNotFound(commandID)
            }
            let currentState = stored.receipt.state
            guard SyncStore.allowedTransitions[currentState]?.contains(newState) == true else {
                throw SyncStoreError.invalidTransition(
                    commandID,
                    from: currentState,
                    to: newState
                )
            }
            if newState == .started {
                guard result == nil else {
                    throw SyncStoreError.invalidCommand("a started receipt cannot carry a result")
                }
                guard let authenticatedDeviceID else {
                    throw SyncStoreError.invalidCommand(
                        "starting a command requires an authenticated device"
                    )
                }
                try SyncStore.requireExecutionStartBinding(
                    connection,
                    storeDeviceID: deviceID,
                    command: stored.command,
                    authenticatedDeviceID: authenticatedDeviceID
                )
            } else if newState.isTerminal, currentState == .accepted,
                      stored.command.kind.requiresExecutionEpoch {
                // An unstarted stale command must not be finalized as though
                // it belonged to the current execution generation.
                try SyncStore.requireCurrentEpoch(connection, command: stored.command)
            }

            var resultBytes: [UInt8]?
            if let result {
                try PortabilityPolicy.validate(result)
                resultBytes = try SyncStore.canonicalBytes(
                    result,
                    limit: configuration.maxPayloadBytes
                )
            }

            let now = nowMillis()
            let update = try connection.prepare(
                "UPDATE commands SET state = ?, result = ?, updated_at = ? WHERE command_id = ?"
            )
            try update.bind(1, newState.rawValue)
            if let resultBytes {
                try update.bind(2, resultBytes)
            } else {
                try update.bindNull(2)
            }
            try update.bind(3, now)
            try update.bind(4, commandID.canonical)
            _ = try update.step()

            return CommandReceipt(
                commandID: commandID,
                state: newState,
                result: result,
                acceptedAt: stored.receipt.acceptedAt,
                updatedAt: SyncStore.date(now),
                payloadDigest: stored.payloadDigest
            )
        }
    }

    // MARK: - Execution heads

    /// Installs the current writer generation for a run branch. Same epoch and
    /// same owner is idempotent; a lower epoch is stale; a higher epoch is the
    /// normal handoff advance.
    public func establishExecutionHead(
        runID: RunID,
        taskID: TaskID,
        epoch: ExecutionEpoch,
        ownerDeviceID: DeviceID
    ) throws -> ExecutionHead {
        try writeTransaction { connection in
            let now = nowMillis()
            if let existing = try SyncStore.loadExecutionHead(connection, runID: runID) {
                guard existing.taskID == taskID else {
                    throw SyncStoreError.invalidCommand(
                        "run \(runID) is already associated with task \(existing.taskID)"
                    )
                }
                if epoch == existing.epoch {
                    guard existing.ownerDeviceID == ownerDeviceID else {
                        throw SyncStoreError.executionEpochOwnerConflict(runID, epoch)
                    }
                    return existing
                }
                if epoch < existing.epoch {
                    throw SyncStoreError.staleExecutionEpoch(
                        runID,
                        epoch,
                        current: existing.epoch
                    )
                }
                let update = try connection.prepare(
                    "UPDATE execution_heads SET task_id = ?, epoch = ?, owner_device_id = ?, updated_at = ? WHERE run_id = ?"
                )
                try update.bind(1, taskID.canonical)
                try update.bind(2, epoch.rawValue)
                try update.bind(3, ownerDeviceID.canonical)
                try update.bind(4, now)
                try update.bind(5, runID.canonical)
                _ = try update.step()
            } else {
                let insert = try connection.prepare(
                    "INSERT INTO execution_heads (run_id, task_id, epoch, owner_device_id, updated_at) VALUES (?, ?, ?, ?, ?)"
                )
                try insert.bind(1, runID.canonical)
                try insert.bind(2, taskID.canonical)
                try insert.bind(3, epoch.rawValue)
                try insert.bind(4, ownerDeviceID.canonical)
                try insert.bind(5, now)
                _ = try insert.step()
            }
            return ExecutionHead(
                runID: runID,
                taskID: taskID,
                epoch: epoch,
                ownerDeviceID: ownerDeviceID,
                updatedAt: SyncStore.date(now)
            )
        }
    }

    public func executionHead(for runID: RunID) throws -> ExecutionHead? {
        let connection = try openConnection()
        return try SyncStore.loadExecutionHead(connection, runID: runID)
    }

    // MARK: - Records and local changes

    /// Applies a local writer's record. The record and its change-log entry
    /// are committed together, and the row is marked locally dirty until a peer
    /// acknowledgement or a converged remote revision clears it.
    public func commitLocalRecord(_ record: SyncRecord) throws -> RecordCommitOutcome {
        let prepared = try prepareLocalRecord(record)
        let now = nowMillis()
        return try writeTransaction { connection in
            try commitPreparedLocalRecord(prepared, connection: connection, atMillis: now)
        }
    }

    /// Commits related local task, run, message and other records as one unit.
    /// Every row and its change-log entry either commits or rolls back. This
    /// is a trusted local writer API, not a remote authentication boundary or
    /// proof that an upstream core cursor was committed with these records.
    /// Duplicate identities are rejected; callers must coalesce multiple
    /// revisions of the same record before constructing a batch.
    public func commitLocalRecords(_ records: [SyncRecord]) throws -> [RecordCommitOutcome] {
        let prepared = try prepareLocalRecords(records)
        let now = nowMillis()
        return try writeTransaction { connection in
            var outcomes: [RecordCommitOutcome] = []
            outcomes.reserveCapacity(prepared.count)
            for item in prepared {
                outcomes.append(try commitPreparedLocalRecord(item, connection: connection, atMillis: now))
            }
            try testHooks.afterLocalBatchRecordsApplied?()
            return outcomes
        }
    }

    private func prepareLocalRecords(_ records: [SyncRecord]) throws -> [PreparedLocalRecord] {
        guard records.count <= configuration.maxBatchRecords else {
            throw SyncStoreError.batchTooLarge(limit: configuration.maxBatchRecords)
        }
        var keys = Set<RecordKey>()
        var byteCount = 0
        var prepared: [PreparedLocalRecord] = []
        prepared.reserveCapacity(records.count)
        for record in records {
            let key = RecordKey(kind: record.kind, entityID: record.entityID)
            guard keys.insert(key).inserted else {
                throw SyncStoreError.invalidRecord("local batch repeats record \(key)")
            }
            let payloadSize = record.payload.canonicalByteCount(upTo: configuration.maxBatchBytes)
            guard payloadSize <= configuration.maxBatchBytes - byteCount else {
                throw SyncStoreError.batchBytesTooLarge(limit: configuration.maxBatchBytes)
            }
            byteCount += payloadSize
            prepared.append(try prepareLocalRecord(record))
        }
        return prepared
    }

    /// Commits normalized, already-durable Floe RunStore events and their
    /// source position together. Remote callers must use authenticated sync;
    /// this local ingestion method does not authorize execution.
    public func applyLocalRunProjection(_ batch: LocalRunProjectionBatch) throws -> RunProjectionCommit {
        let prepared = try prepareLocalRecords(batch.records)
        try batch.validate()
        let digest = batch.digest(ownerDeviceID: deviceID)
        let now = nowMillis()
        return try writeTransaction { connection in
            guard let head = try SyncStore.loadExecutionHead(connection, runID: batch.runID) else {
                throw SyncStoreError.executionHeadNotEstablished(batch.runID)
            }
            guard head.taskID == batch.taskID else {
                throw SyncStoreError.executionTaskMismatch(batch.runID, expected: head.taskID, received: batch.taskID)
            }
            guard head.epoch == batch.executionEpoch else {
                if batch.executionEpoch < head.epoch {
                    throw SyncStoreError.staleExecutionEpoch(batch.runID, batch.executionEpoch, current: head.epoch)
                }
                throw SyncStoreError.executionEpochNotEstablished(batch.runID, batch.executionEpoch)
            }
            guard head.ownerDeviceID == deviceID else {
                throw SyncStoreError.executionOwnerMismatch(batch.runID, owner: head.ownerDeviceID, authenticated: deviceID)
            }
            let previous = try SyncStore.loadRunProjectionCheckpoint(connection, runID: batch.runID)
            if let saved = previous?.checkpoint {
                guard saved.taskID == batch.taskID, saved.ownerDeviceID == deviceID,
                      saved.executionEpoch == batch.executionEpoch else {
                    throw SyncStoreError.runProjectionBindingMismatch(batch.runID)
                }
                if saved.afterSequence == batch.afterSequence, saved.sourceSequence == batch.throughSequence {
                    guard saved.batchDigest == digest else {
                        throw SyncStoreError.runProjectionReplayConflict(batch.runID)
                    }
                    return RunProjectionCommit(checkpoint: saved, isDuplicate: true)
                }
            }
            let expected = previous?.checkpoint.sourceSequence ?? 0
            guard batch.afterSequence == expected else {
                throw SyncStoreError.runProjectionCursorConflict(batch.runID, expected: expected, received: batch.afterSequence)
            }
            var appended = 0, unchanged = 0
            for item in prepared {
                switch try commitPreparedLocalRecord(item, connection: connection, atMillis: now) {
                case .appended: appended += 1
                case .unchanged: unchanged += 1
                }
            }
            try testHooks.beforeRunProjectionCheckpoint?()
            let checkpoint = RunProjectionCheckpoint(
                taskID: batch.taskID, runID: batch.runID, ownerDeviceID: deviceID,
                executionEpoch: batch.executionEpoch, afterSequence: batch.afterSequence,
                sourceSequence: batch.throughSequence, batchDigest: digest,
                appendedRecords: appended, unchangedRecords: unchanged,
                changeCursor: try SyncStore.latestCursor(connection))
            let key = SyncStore.runProjectionMetaKey(batch.runID)
            let encoded = checkpoint.wireValue.canonicalJSON()
            let statement: SQLiteStatement
            if let previous {
                statement = try connection.prepare("UPDATE meta SET value = ? WHERE key = ? AND value = ?")
                try statement.bind(1, encoded)
                try statement.bind(2, key)
                try statement.bind(3, previous.storedJSON)
            } else {
                statement = try connection.prepare("INSERT OR IGNORE INTO meta (value, key) VALUES (?, ?)")
                try statement.bind(1, encoded)
                try statement.bind(2, key)
            }
            _ = try statement.step()
            guard connection.changedRowCount == 1 else {
                throw SyncStoreError.runProjectionCursorConflict(batch.runID, expected: expected, received: batch.afterSequence)
            }
            return RunProjectionCommit(checkpoint: checkpoint, isDuplicate: false)
        }
    }

    public func runProjectionCheckpoint(for runID: RunID) throws -> RunProjectionCheckpoint? {
        try SyncStore.loadRunProjectionCheckpoint(openConnection(), runID: runID)?.checkpoint
    }

    private static func runProjectionMetaKey(_ runID: RunID) -> String {
        "local_run_projection.v1/" + runID.canonical
    }

    private static func loadRunProjectionCheckpoint(
        _ connection: SQLiteConnection, runID: RunID
    ) throws -> (storedJSON: String, checkpoint: RunProjectionCheckpoint)? {
        let statement = try connection.prepare("SELECT value, length(CAST(value AS BLOB)) FROM meta WHERE key = ?")
        try statement.bind(1, runProjectionMetaKey(runID))
        guard try statement.step() else { return nil }
        guard let bytes = statement.int64(1), bytes > 0, bytes <= 8_192,
              let value = statement.text(0) else {
            throw SyncStoreError.runProjectionCheckpointCorrupt(runID)
        }
        return (value, try RunProjectionCheckpoint(storedJSON: value, runID: runID))
    }

    private struct PreparedLocalRecord {
        let record: SyncRecord
        let digest: ContentDigest
    }

    private func prepareLocalRecord(_ record: SyncRecord) throws -> PreparedLocalRecord {
        try record.validateShape()
        guard record.originDeviceID == deviceID else {
            throw SyncStoreError.recordOriginMismatch(
                expected: deviceID,
                found: record.originDeviceID
            )
        }
        guard record.payload.canonicalByteCount(upTo: configuration.maxPayloadBytes)
            <= configuration.maxPayloadBytes else {
            throw SyncStoreError.payloadTooLarge(limit: configuration.maxPayloadBytes)
        }
        let payloadBytes = try SyncStore.canonicalBytes(
            record.payload,
            limit: configuration.maxPayloadBytes
        )
        return PreparedLocalRecord(record: record, digest: ContentDigest.compute(payloadBytes))
    }

    private func commitPreparedLocalRecord(
        _ prepared: PreparedLocalRecord,
        connection: SQLiteConnection,
        atMillis now: Int64
    ) throws -> RecordCommitOutcome {
        let record = prepared.record
        let digest = prepared.digest
        var effective = record
        if let existing = try SyncStore.loadRecordRow(
            connection,
            kind: record.kind,
            entityID: record.entityID,
            maxPayloadBytes: SyncStore.maximumReadBytes
        ) {
            if let base = record.baseRevision, base != existing.record.revision {
                throw SyncStoreError.localBaseMismatch(
                    record.kind,
                    record.entityID,
                    expected: base,
                    found: existing.record.revision
                )
            }
            if let baseDigest = record.baseDigest, baseDigest != existing.digest {
                throw SyncStoreError.localBaseDigestMismatch(
                    record.kind,
                    record.entityID
                )
            }
            if record.revision < existing.record.revision {
                throw SyncStoreError.staleLocalRevision(
                    record.kind,
                    record.entityID,
                    current: existing.record.revision,
                    received: record.revision
                )
            }
            if record.revision == existing.record.revision {
                guard SyncStore.sameContent(
                    existing,
                    record: record,
                    digest: digest
                ) else {
                    throw SyncStoreError.revisionPayloadMismatch(
                        record.kind,
                        record.entityID,
                        revision: record.revision
                    )
                }
                return .unchanged
            }
            // A local writer is serialized by this actor; recording the
            // actual current row as the baseline is therefore exact and
            // makes later remote fast-forwards verifiable by digest.
            effective = SyncStore.record(
                record,
                baseRevision: record.baseRevision ?? existing.record.revision,
                baseDigest: record.baseDigest ?? existing.digest
            )
        }

        try SyncStore.upsertRecord(
            connection,
            record: effective,
            digest: digest,
            localDirty: true,
            atMillis: now
        )
        let cursor = try SyncStore.appendChange(
            connection,
            record: effective,
            digest: digest,
            type: effective.deleted ? .delete : .upsert,
            atMillis: now
        )
        return .appended(cursor)
    }

    public func storedRecord(kind: SyncEntityKind, entityID: EntityID) throws -> StoredRecord? {
        let connection = try openConnection()
        guard let row = try SyncStore.loadRecordRow(
            connection,
            kind: kind,
            entityID: entityID,
            maxPayloadBytes: SyncStore.maximumReadBytes
        ) else {
            return nil
        }
        return StoredRecord(
            record: row.record,
            payloadDigest: row.digest,
            localDirty: row.localDirty,
            updatedAt: SyncStore.date(row.updatedAtMillis)
        )
    }

    public func recordCount(includingDeleted: Bool = false) throws -> Int {
        let connection = try openConnection()
        let sql = includingDeleted
            ? "SELECT COUNT(*) FROM records"
            : "SELECT COUNT(*) FROM records WHERE deleted = 0"
        return try SyncStore.scalarInt(connection, sql: sql)
    }

    /// Clears the local-dirty marker only when the acknowledged revision is
    /// still the stored one. A newer local edit stays dirty.
    public func acknowledgeLocalRecord(
        kind: SyncEntityKind,
        entityID: EntityID,
        revision: Revision
    ) throws -> Bool {
        try writeTransaction { connection in
            guard let existing = try SyncStore.loadRecordRow(
                connection,
                kind: kind,
                entityID: entityID,
                maxPayloadBytes: SyncStore.maximumReadBytes
            ), existing.record.revision == revision else {
                return false
            }
            guard existing.localDirty else { return true }
            let update = try connection.prepare(
                "UPDATE records SET local_dirty = 0 WHERE entity_kind = ? AND entity_id = ?"
            )
            try update.bind(1, kind.rawValue)
            try update.bind(2, entityID.canonical)
            _ = try update.step()
            return true
        }
    }

    // MARK: - Inbound batches and applied cursors

    /// Applies a peer's change batch and advances that peer's applied cursor in
    /// the same transaction. Throwing after some records were written (for
    /// example an invalid later record) rolls the whole batch back.
    public func applyRemoteBatch(_ batch: RemoteChangeBatch) throws -> RemoteApplyResult {
        // No authenticated source interval or expected starting cursor exists
        // in this legacy API. A later batch must not skip an earlier batch.
        _ = try openConnection()
        throw SyncStoreError.scopedIncrementalUnverified
    }

    /// Internal fixture for exercising transaction/conflict semantics. This is
    /// not a transport entry point and does not prove interval completeness.
    func applyUncheckedBatchForTesting(_ batch: RemoteChangeBatch) throws -> RemoteApplyResult {
        try validateBatch(batch.records)
        return try writeTransaction { connection in
            let current = try SyncStore.appliedCursor(connection, peer: batch.peerDeviceID)
            guard batch.through >= current else {
                throw SyncStoreError.cursorRegression(
                    batch.peerDeviceID,
                    current: current,
                    received: batch.through
                )
            }
            let now = nowMillis()
            let outcome = try SyncStore.applyRecords(
                connection,
                peerDeviceID: batch.peerDeviceID,
                records: batch.records,
                observedCursor: batch.through,
                maxWritePayloadBytes: configuration.maxPayloadBytes,
                atMillis: now
            )
            // Conflicts are persisted in this same transaction, including both
            // payloads. Advancing the cursor therefore cannot lose a refused
            // remote version across a crash; if the transaction fails, both
            // the records and the cursor roll back.
            try SyncStore.setAppliedCursor(
                connection,
                peer: batch.peerDeviceID,
                cursor: batch.through,
                atMillis: now
            )
            return RemoteApplyResult(
                applied: outcome.applied,
                conflicts: outcome.conflicts,
                cursor: batch.through
            )
        }
    }

    // MARK: - Snapshot export manifest

    /// Builds the complete deterministic page manifest for an already-open
    /// export snapshot. Page boundaries use the same record-count and payload
    /// byte rules as `snapshotPage`, so a transport can re-fetch exactly the
    /// declared pages without inventing a second version of the data.
    public func snapshotManifest(
        _ snapshotID: SnapshotID,
        pageSize: Int? = nil,
        subscriptionVersion: Int64 = 1
    ) throws -> SnapshotManifest {
        guard subscriptionVersion > 0 else { throw SyncStoreError.invalidSubscriptionVersion(subscriptionVersion) }
        let effectivePageSize = try validatedPageSize(pageSize)
        return try readTransaction { connection in
            guard let snapshot = try SyncStore.loadSnapshot(connection, id: snapshotID) else {
                throw SyncStoreError.snapshotNotFound(snapshotID)
            }
            guard snapshot.expiresAtMillis > nowMillis() else {
                throw SyncStoreError.snapshotExpired(snapshotID)
            }
            guard snapshot.manifestComplete else {
                throw SyncStoreError.snapshotManifestInvalid("legacy snapshot has no verified tombstone coverage")
            }
            let descriptor = snapshot.descriptor
            let totalEntries = descriptor.recordCount + descriptor.tombstoneCount
            var pages: [SnapshotPageManifest] = []
            var startPosition: Int64 = 0
            var entries = 0
            while true {
                let read = try SyncStore.readSnapshotPageRows(
                    connection,
                    snapshotID: snapshotID,
                    start: startPosition,
                    pageSize: effectivePageSize,
                    maxPageBytes: configuration.maxPageBytes
                )
                var records = read.records
                var positions = read.positions
                let exceededCount = records.count > effectivePageSize
                let hasMore = read.hasMore || exceededCount
                if exceededCount {
                    records.removeLast(records.count - effectivePageSize)
                    positions.removeLast(positions.count - effectivePageSize)
                }
                if records.isEmpty {
                    guard totalEntries == 0, pages.isEmpty else {
                        throw SyncStoreError.schemaCorrupt(
                            "snapshot declares entries but has no page rows"
                        )
                    }
                    break
                }
                guard positions.first == startPosition + 1,
                      positions.last == startPosition + Int64(records.count) else {
                    throw SyncStoreError.schemaCorrupt(
                        "snapshot page positions are not contiguous"
                    )
                }
                var bytes = 0
                for record in records {
                    let count = record.payload.canonicalByteCount(upTo: SyncStore.maximumReadBytes)
                    guard count <= SyncStore.maximumReadBytes else {
                        throw SyncStoreError.payloadTooLarge(limit: SyncStore.maximumReadBytes)
                    }
                    bytes += count
                }
                guard let firstPosition = positions.first,
                      let lastPosition = positions.last else {
                    throw SyncStoreError.schemaCorrupt("snapshot page has no positions")
                }
                pages.append(
                    SnapshotPageManifest(
                        pageIndex: pages.count,
                        firstPosition: firstPosition,
                        lastPosition: lastPosition,
                        entryCount: records.count,
                        byteCount: bytes,
                        digest: SnapshotDigest.pageDigest(records)
                    )
                )
                entries += records.count
                startPosition = lastPosition
                guard pages.count <= configuration.maxSnapshotPages,
                      entries <= configuration.maxSnapshotEntries else {
                    throw SyncStoreError.snapshotTooLarge(
                        "export snapshot exceeds configured manifest limits"
                    )
                }
                if !hasMore { break }
            }
            guard entries == totalEntries,
                  startPosition == Int64(totalEntries) else {
                throw SyncStoreError.schemaCorrupt(
                    "snapshot manifest does not cover the frozen entry set"
                )
            }
            let digest = SnapshotDigest.manifestDigest(
                protocolVersion: .v1,
                snapshotID: snapshotID,
                originDeviceID: deviceID,
                scope: descriptor.scope,
                baseCursor: descriptor.baseCursor,
                recordCount: descriptor.recordCount,
                tombstoneCount: descriptor.tombstoneCount,
                entryCount: totalEntries,
                pageSize: effectivePageSize,
                pages: pages,
                createdAt: descriptor.createdAt,
                expiresAt: descriptor.expiresAt,
                subscriptionVersion: subscriptionVersion
            )
            return SnapshotManifest(
                snapshotID: snapshotID,
                originDeviceID: deviceID,
                subscriptionVersion: subscriptionVersion,
                scope: descriptor.scope,
                baseCursor: descriptor.baseCursor,
                recordCount: descriptor.recordCount,
                tombstoneCount: descriptor.tombstoneCount,
                entryCount: totalEntries,
                pageSize: effectivePageSize,
                pages: pages,
                digest: digest,
                createdAt: descriptor.createdAt,
                expiresAt: descriptor.expiresAt
            )
        }
    }

    /// Fetches exactly one manifest page for transport. The frozen rows are
    /// re-hashed before being returned; a mismatch means the manifest no
    /// longer describes this snapshot and the page is refused.
    public func snapshotPageEnvelope(
        _ snapshotID: SnapshotID,
        manifest: SnapshotManifest,
        pageIndex: Int
    ) throws -> SnapshotPageEnvelope {
        guard manifest.originDeviceID == deviceID else {
            throw SyncStoreError.snapshotPeerMismatch(
                expected: deviceID,
                found: manifest.originDeviceID
            )
        }
        try manifest.validate()
        return try readTransaction { connection in
            guard let snapshot = try SyncStore.loadSnapshot(connection, id: snapshotID) else {
                throw SyncStoreError.snapshotNotFound(snapshotID)
            }
            guard snapshot.expiresAtMillis > nowMillis() else {
                throw SyncStoreError.snapshotExpired(snapshotID)
            }
            guard snapshot.manifestComplete else {
                throw SyncStoreError.snapshotManifestInvalid("legacy snapshot has no verified tombstone coverage")
            }
            let descriptor = snapshot.descriptor
            guard manifest.snapshotID == snapshotID,
                  manifest.scope == descriptor.scope,
                  manifest.baseCursor == descriptor.baseCursor,
                  manifest.recordCount == descriptor.recordCount,
                  manifest.tombstoneCount == descriptor.tombstoneCount else {
                throw SyncStoreError.snapshotManifestDigestMismatch
            }
            guard pageIndex >= 0, pageIndex < manifest.pages.count else {
                throw SyncStoreError.snapshotPageOutOfOrder(
                    expected: manifest.pages.count,
                    received: pageIndex
                )
            }
            let page = manifest.pages[pageIndex]
            let read = try SyncStore.readSnapshotRange(
                connection,
                snapshotID: snapshotID,
                firstPosition: page.firstPosition,
                lastPosition: page.lastPosition
            )
            guard read.records.count == page.entryCount,
                  read.positions.first == page.firstPosition,
                  read.positions.last == page.lastPosition else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(pageIndex) does not match the frozen snapshot range"
                )
            }
            var bytes = 0
            for record in read.records {
                bytes += record.payload.canonicalByteCount(upTo: SyncStore.maximumReadBytes)
            }
            guard bytes == page.byteCount else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(pageIndex) byte count does not match the manifest"
                )
            }
            let digest = SnapshotDigest.pageDigest(read.records)
            guard digest == page.digest else {
                throw SyncStoreError.snapshotManifestDigestMismatch
            }
            return SnapshotPageEnvelope(
                snapshotID: snapshotID,
                originDeviceID: deviceID,
                pageIndex: pageIndex,
                firstPosition: page.firstPosition,
                lastPosition: page.lastPosition,
                records: read.records,
                digest: digest,
                manifestDigest: manifest.digest
            )
        }
    }

    // MARK: - Inbound snapshot reception

    /// Legacy entry point lacks proof of peer identity and always fails closed.
    public func beginSnapshotImport(
        peerDeviceID: DeviceID,
        manifest: SnapshotManifest,
        subscriptionVersion: Int64
    ) throws -> SnapshotImportProgress {
        throw SyncStoreError.snapshotImportUnverified
    }

    public func beginAuthenticatedSnapshotImport(_ signed: AuthenticatedSnapshotManifest) throws -> SnapshotImportProgress {
        try verifySnapshotAuthentication(signed)
        return try beginSnapshotImportImpl(peerDeviceID: signed.manifest.originDeviceID, manifest: signed.manifest,
            subscriptionVersion: signed.manifest.subscriptionVersion, enforceAuthorization: true)
    }

    func beginSnapshotImportForTesting(peerDeviceID: DeviceID, manifest: SnapshotManifest,
                                       subscriptionVersion: Int64) throws -> SnapshotImportProgress {
        try beginSnapshotImportImpl(peerDeviceID: peerDeviceID, manifest: manifest,
                                    subscriptionVersion: subscriptionVersion, enforceAuthorization: false)
    }

    private func beginSnapshotImportImpl(peerDeviceID: DeviceID, manifest: SnapshotManifest,
        subscriptionVersion: Int64, enforceAuthorization: Bool) throws -> SnapshotImportProgress {
        guard subscriptionVersion > 0 else {
            throw SyncStoreError.invalidSubscriptionVersion(subscriptionVersion)
        }
        guard peerDeviceID != deviceID else {
            throw SyncStoreError.snapshotPeerMismatch(expected: deviceID, found: peerDeviceID)
        }
        guard manifest.originDeviceID == peerDeviceID else {
            throw SyncStoreError.snapshotPeerMismatch(
                expected: peerDeviceID,
                found: manifest.originDeviceID
            )
        }
        guard manifest.subscriptionVersion == subscriptionVersion else {
            throw SyncStoreError.subscriptionVersionMismatch(
                peerDeviceID, manifest.scope, expected: subscriptionVersion, found: manifest.subscriptionVersion
            )
        }
        try manifest.validate()
        guard manifest.pageSize <= configuration.maxPageSize else {
            throw SyncStoreError.snapshotTooLarge(
                "snapshot page size \(manifest.pageSize) exceeds \(configuration.maxPageSize)"
            )
        }
        guard manifest.pageCount <= configuration.maxSnapshotPages else {
            throw SyncStoreError.snapshotTooLarge(
                "snapshot has \(manifest.pageCount) pages, limit is \(configuration.maxSnapshotPages)"
            )
        }
        guard manifest.entryCount <= configuration.maxSnapshotEntries else {
            throw SyncStoreError.snapshotTooLarge(
                "snapshot has \(manifest.entryCount) entries, limit is \(configuration.maxSnapshotEntries)"
            )
        }
        for page in manifest.pages {
            guard page.entryCount <= configuration.maxPageSize else {
                throw SyncStoreError.snapshotTooLarge(
                    "snapshot page \(page.pageIndex) has \(page.entryCount) entries, limit is \(configuration.maxPageSize)"
                )
            }
        }
        var declaredBytes: Int64 = 0
        for page in manifest.pages {
            let addition = declaredBytes.addingReportingOverflow(Int64(page.byteCount))
            guard !addition.overflow else {
                throw SyncStoreError.snapshotTooLarge(
                    "declared snapshot bytes overflow the staging budget"
                )
            }
            declaredBytes = addition.partialValue
        }
        let overhead = Int64(manifest.entryCount).multipliedReportingOverflow(
            by: Int64(SyncStore.snapshotStagingEntryOverhead)
        )
        guard !overhead.overflow else {
            throw SyncStoreError.snapshotTooLarge(
                "declared snapshot overhead overflows the staging budget"
            )
        }
        let totalDeclared = declaredBytes.addingReportingOverflow(overhead.partialValue)
        guard !totalDeclared.overflow,
              totalDeclared.partialValue <= Int64(configuration.maxStagingBytes) else {
            throw SyncStoreError.snapshotTooLarge(
                "declared snapshot bytes exceed the global staging limit"
            )
        }

        let now = nowMillis()
        let manifestExpiry = SyncStore.millis(manifest.expiresAt)
        guard manifestExpiry > now else {
            throw SyncStoreError.snapshotImportExpired(peerDeviceID, manifest.snapshotID)
        }
        let localExpiry = now + Int64((configuration.snapshotLifetime * 1_000).rounded())
        let expiresAt = min(manifestExpiry, localExpiry)

        return try writeTransaction { connection in
            if enforceAuthorization,
               try SyncStore.loadScopeAuthorization(connection, peer: peerDeviceID, scope: manifest.scope) == nil {
                throw SyncStoreError.incrementalScopeUnauthorized(peerDeviceID, manifest.scope)
            }
            _ = try SyncStore.purgeExpiredStagingImports(connection, atMillis: now)

            var subscription = try SyncStore.loadSubscription(
                connection,
                peer: peerDeviceID,
                scope: manifest.scope
            )
            if let subscription {
                guard subscription.version == subscriptionVersion else {
                    throw SyncStoreError.subscriptionVersionMismatch(
                        peerDeviceID,
                        manifest.scope,
                        expected: subscriptionVersion,
                        found: subscription.version
                    )
                }
                if subscription.established, subscription.appliedCursor > manifest.baseCursor {
                    throw SyncStoreError.snapshotBaseStale(
                        peerDeviceID,
                        manifest.scope,
                        current: subscription.appliedCursor,
                        received: manifest.baseCursor
                    )
                }
            }

            if let existing = try SyncStore.loadSnapshotImport(
                connection,
                peer: peerDeviceID,
                snapshotID: manifest.snapshotID
            ) {
                if existing.subscriptionVersion == subscriptionVersion,
                   existing.manifest.digest == manifest.digest,
                   existing.manifest == manifest {
                    return SyncStore.progress(from: existing)
                }
                throw SyncStoreError.snapshotIdentityConflict(
                    peerDeviceID,
                    manifest.snapshotID
                )
            }

            if let active = try SyncStore.loadActiveSnapshotImport(
                connection,
                peer: peerDeviceID,
                scope: manifest.scope
            ), active.snapshotID != manifest.snapshotID {
                throw SyncStoreError.snapshotImportInProgress(
                    peerDeviceID,
                    manifest.scope
                )
            }

            let totals = try SyncStore.stagingTotals(connection)
            guard totals.imports < configuration.maxConcurrentSnapshotImports else {
                throw SyncStoreError.snapshotStagingLimitExceeded(
                    "at most \(configuration.maxConcurrentSnapshotImports) snapshots may stage at once"
                )
            }
            let maxTotalPages = Int64(configuration.maxSnapshotPages)
                * Int64(configuration.maxConcurrentSnapshotImports)
            guard Int64(totals.pages) < maxTotalPages else {
                throw SyncStoreError.snapshotStagingLimitExceeded(
                    "global staged page limit reached"
                )
            }
            let maxTotalEntries = Int64(configuration.maxSnapshotEntries)
                * Int64(configuration.maxConcurrentSnapshotImports)
            guard Int64(totals.entries) + Int64(manifest.entryCount) <= maxTotalEntries else {
                throw SyncStoreError.snapshotStagingLimitExceeded(
                    "global staged entry limit reached"
                )
            }

            if subscription == nil {
                try SyncStore.insertSubscription(
                    connection,
                    peer: peerDeviceID,
                    scope: manifest.scope,
                    version: subscriptionVersion,
                    atMillis: now
                )
                subscription = try SyncStore.loadSubscription(
                    connection,
                    peer: peerDeviceID,
                    scope: manifest.scope
                )
            }

            let insert = try connection.prepare(
                """
                INSERT INTO snapshot_imports (
                    peer_device_id, snapshot_id, scope_kind, scope_id,
                    subscription_version, base_cursor, manifest_digest,
                    manifest_blob, entry_count, record_count, tombstone_count,
                    page_count, next_page_index, received_page_count,
                    received_entry_count, staged_bytes, state, created_at,
                    expires_at, committed_at, receipt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, 'staging', ?, ?, NULL, NULL)
                """
            )
            try insert.bind(1, peerDeviceID.canonical)
            try insert.bind(2, manifest.snapshotID.canonical)
            try insert.bind(3, manifest.scope.kind)
            try insert.bind(4, manifest.scope.identifier ?? "")
            try insert.bind(5, subscriptionVersion)
            try insert.bind(6, manifest.baseCursor.rawValue)
            try insert.bind(7, manifest.digest.description)
            try insert.bind(8, manifest.wireJSONValue().canonicalUTF8)
            try insert.bind(9, Int64(manifest.entryCount))
            try insert.bind(10, Int64(manifest.recordCount))
            try insert.bind(11, Int64(manifest.tombstoneCount))
            try insert.bind(12, Int64(manifest.pageCount))
            try insert.bind(13, now)
            try insert.bind(14, expiresAt)
            _ = try insert.step()

            guard let created = try SyncStore.loadSnapshotImport(
                connection,
                peer: peerDeviceID,
                snapshotID: manifest.snapshotID
            ) else {
                throw SyncStoreError.schemaCorrupt("staged snapshot row disappeared")
            }
            return SyncStore.progress(from: created)
        }
    }

    /// Stages one page atomically. Pages must arrive in manifest order; a
    /// byte-identical retransmission is idempotent, while a different page at
    /// an already-received index is refused. Nothing in this method changes a
    /// visible record or a cursor.
    public func receiveSnapshotPage(
        peerDeviceID: DeviceID,
        envelope: SnapshotPageEnvelope
    ) throws -> SnapshotImportProgress {
        throw SyncStoreError.snapshotImportUnverified
    }

    public func receiveAuthenticatedSnapshotPage(_ signed: AuthenticatedSnapshotManifest,
                                                   envelope: SnapshotPageEnvelope) throws -> SnapshotImportProgress {
        try verifySnapshotAuthentication(signed)
        return try receiveSnapshotPageImpl(peerDeviceID: signed.manifest.originDeviceID,
                                           envelope: envelope, authenticatedManifest: signed.manifest)
    }

    func receiveSnapshotPageForTesting(peerDeviceID: DeviceID, envelope: SnapshotPageEnvelope) throws -> SnapshotImportProgress {
        try receiveSnapshotPageImpl(peerDeviceID: peerDeviceID, envelope: envelope, authenticatedManifest: nil)
    }

    private func receiveSnapshotPageImpl(peerDeviceID: DeviceID, envelope: SnapshotPageEnvelope,
                                         authenticatedManifest: SnapshotManifest?) throws -> SnapshotImportProgress {
        guard envelope.originDeviceID == peerDeviceID else {
            throw SyncStoreError.snapshotPeerMismatch(
                expected: peerDeviceID,
                found: envelope.originDeviceID
            )
        }
        return try writeTransaction { connection in
            let now = nowMillis()
            guard let staging = try SyncStore.loadSnapshotImport(
                connection,
                peer: peerDeviceID,
                snapshotID: envelope.snapshotID
            ) else {
                throw SyncStoreError.snapshotImportNotFound(
                    peerDeviceID,
                    envelope.snapshotID
                )
            }
            let manifest = staging.manifest
            if let authenticatedManifest {
                guard authenticatedManifest == manifest else { throw SyncStoreError.snapshotImportUnverified }
                guard try SyncStore.loadScopeAuthorization(connection, peer: peerDeviceID, scope: manifest.scope) != nil else {
                    throw SyncStoreError.incrementalScopeUnauthorized(peerDeviceID, manifest.scope)
                }
            }
            guard envelope.manifestDigest == manifest.digest else {
                throw SyncStoreError.snapshotManifestDigestMismatch
            }
            guard envelope.snapshotID == manifest.snapshotID else {
                throw SyncStoreError.snapshotIdentityConflict(
                    peerDeviceID,
                    envelope.snapshotID
                )
            }
            guard let subscription = try SyncStore.loadSubscription(
                connection,
                peer: peerDeviceID,
                scope: manifest.scope
            ) else {
                throw SyncStoreError.snapshotImportReceiptCorrupt
            }
            guard subscription.version == staging.subscriptionVersion else {
                throw SyncStoreError.subscriptionVersionMismatch(
                    peerDeviceID,
                    manifest.scope,
                    expected: staging.subscriptionVersion,
                    found: subscription.version
                )
            }
            if staging.expiresAtMillis <= now {
                throw SyncStoreError.snapshotImportExpired(
                    peerDeviceID,
                    envelope.snapshotID
                )
            }
            guard envelope.pageIndex >= 0, envelope.pageIndex < manifest.pageCount else {
                throw SyncStoreError.snapshotPageOutOfOrder(
                    expected: min(staging.nextPageIndex, manifest.pageCount),
                    received: envelope.pageIndex
                )
            }
            let expected = manifest.pages[envelope.pageIndex]
            guard envelope.firstPosition == expected.firstPosition,
                  envelope.lastPosition == expected.lastPosition,
                  envelope.records.count == expected.entryCount else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(envelope.pageIndex) does not match its manifest descriptor"
                )
            }

            if staging.state == .committed {
                guard envelope.digest == expected.digest,
                      envelope.computedDigest() == envelope.digest,
                      envelope.records.allSatisfy({ SyncStore.scopeContains($0, scope: manifest.scope) }) else {
                    throw SyncStoreError.snapshotPageConflict(
                        peerDeviceID,
                        envelope.snapshotID,
                        pageIndex: envelope.pageIndex
                    )
                }
                return SyncStore.progress(from: staging)
            }

            if let existing = try SyncStore.loadStagedPage(
                connection,
                peer: peerDeviceID,
                snapshotID: envelope.snapshotID,
                pageIndex: envelope.pageIndex
            ) {
                let stagedRecords = try SyncStore.loadStagedPageRecords(
                    connection,
                    peer: peerDeviceID,
                    snapshotID: envelope.snapshotID,
                    firstPosition: existing.firstPosition,
                    lastPosition: existing.lastPosition
                )
                guard stagedRecords.records.count == existing.entryCount,
                      SnapshotDigest.pageDigest(stagedRecords.records) == existing.digest,
                      existing.firstPosition == envelope.firstPosition,
                      existing.lastPosition == envelope.lastPosition,
                      existing.entryCount == envelope.records.count,
                      existing.byteCount == expected.byteCount,
                      existing.digest == envelope.digest,
                      envelope.computedDigest() == envelope.digest else {
                    throw SyncStoreError.snapshotPageConflict(
                        peerDeviceID,
                        envelope.snapshotID,
                        pageIndex: envelope.pageIndex
                    )
                }
                return SyncStore.progress(from: staging)
            }

            guard envelope.pageIndex == staging.nextPageIndex else {
                if envelope.pageIndex < staging.nextPageIndex {
                    throw SyncStoreError.snapshotPageConflict(
                        peerDeviceID,
                        envelope.snapshotID,
                        pageIndex: envelope.pageIndex
                    )
                }
                throw SyncStoreError.snapshotPageOutOfOrder(
                    expected: staging.nextPageIndex,
                    received: envelope.pageIndex
                )
            }

            let byteCap = expected.entryCount == 1
                ? configuration.maxPayloadBytes
                : configuration.maxPageBytes
            guard expected.byteCount <= byteCap else {
                throw SyncStoreError.snapshotTooLarge(
                    "page \(envelope.pageIndex) exceeds the page byte bound"
                )
            }

            var keys = Set<RecordKey>()
            var payloadBytes = 0
            for record in envelope.records {
                try record.validateShape()
                guard SyncStore.scopeContains(record, scope: manifest.scope) else {
                    throw SyncStoreError.snapshotScopeMismatch(
                        RecordKey(kind: record.kind, entityID: record.entityID),
                        manifest.scope
                    )
                }
                let key = RecordKey(kind: record.kind, entityID: record.entityID)
                guard keys.insert(key).inserted else {
                    throw SyncStoreError.snapshotDuplicateRecord(key)
                }
                if try SyncStore.stagedRecordExists(
                    connection,
                    peer: peerDeviceID,
                    snapshotID: envelope.snapshotID,
                    key: key
                ) {
                    throw SyncStoreError.snapshotDuplicateRecord(key)
                }
                let remaining = expected.byteCount - payloadBytes
                guard remaining >= 0 else {
                    throw SyncStoreError.snapshotManifestInvalid(
                        "page \(envelope.pageIndex) exceeds its declared bytes"
                    )
                }
                let count = record.payload.canonicalByteCount(
                    upTo: min(configuration.maxPayloadBytes, remaining)
                )
                guard count <= configuration.maxPayloadBytes, count <= remaining else {
                    throw SyncStoreError.snapshotManifestInvalid(
                        "page \(envelope.pageIndex) record exceeds the declared page bytes"
                    )
                }
                payloadBytes += count
            }
            let digest = SnapshotDigest.pageDigest(envelope.records)
            guard digest == envelope.digest,
                  envelope.digest == expected.digest else {
                throw SyncStoreError.snapshotPageDigestMismatch(
                    expected: expected.digest,
                    received: digest
                )
            }
            guard payloadBytes == expected.byteCount else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(envelope.pageIndex) payload bytes do not match the manifest"
                )
            }

            let cost = Int64(payloadBytes)
                + Int64(envelope.records.count) * Int64(SyncStore.snapshotStagingEntryOverhead)
            let totals = try SyncStore.stagingTotals(connection)
            let maxTotalPages = Int64(configuration.maxSnapshotPages)
                * Int64(configuration.maxConcurrentSnapshotImports)
            let maxTotalEntries = Int64(configuration.maxSnapshotEntries)
                * Int64(configuration.maxConcurrentSnapshotImports)
            guard Int64(totals.pages) + 1 <= maxTotalPages,
                  Int64(totals.entries) + Int64(envelope.records.count) <= maxTotalEntries else {
                throw SyncStoreError.snapshotStagingLimitExceeded(
                    "global staged page or entry limit reached"
                )
            }
            let effectiveBytes = Int64(totals.payloadBytes)
                + Int64(totals.entries) * Int64(SyncStore.snapshotStagingEntryOverhead)
            guard effectiveBytes + cost <= Int64(configuration.maxStagingBytes) else {
                throw SyncStoreError.snapshotStagingLimitExceeded(
                    "global staged byte limit reached"
                )
            }

            let pageInsert = try connection.prepare(
                """
                INSERT INTO snapshot_import_pages (
                    peer_device_id, snapshot_id, page_index, first_position,
                    last_position, entry_count, byte_count, page_digest, received_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            try pageInsert.bind(1, peerDeviceID.canonical)
            try pageInsert.bind(2, envelope.snapshotID.canonical)
            try pageInsert.bind(3, Int64(envelope.pageIndex))
            try pageInsert.bind(4, envelope.firstPosition)
            try pageInsert.bind(5, envelope.lastPosition)
            try pageInsert.bind(6, Int64(envelope.records.count))
            try pageInsert.bind(7, Int64(payloadBytes))
            try pageInsert.bind(8, digest.description)
            try pageInsert.bind(9, now)
            _ = try pageInsert.step()

            let recordInsert = try connection.prepare(
                """
                INSERT INTO snapshot_import_records (
                    peer_device_id, snapshot_id, position, entity_kind, entity_id,
                    task_id, workspace_id, revision, base_revision, base_digest,
                    origin_device_id, payload, payload_digest, deleted
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
            )
            for (offset, record) in envelope.records.enumerated() {
                recordInsert.reset()
                try recordInsert.bind(1, peerDeviceID.canonical)
                try recordInsert.bind(2, envelope.snapshotID.canonical)
                try recordInsert.bind(3, envelope.firstPosition + Int64(offset))
                try recordInsert.bind(4, record.kind.rawValue)
                try recordInsert.bind(5, record.entityID.canonical)
                try SyncStore.bindOptionalText(recordInsert, 6, record.taskID?.canonical)
                try SyncStore.bindOptionalText(recordInsert, 7, record.workspaceID?.canonical)
                try recordInsert.bind(8, record.revision.rawValue)
                try SyncStore.bindOptionalInt64(
                    recordInsert,
                    9,
                    record.baseRevision?.rawValue
                )
                try SyncStore.bindOptionalText(
                    recordInsert,
                    10,
                    record.baseDigest?.description
                )
                try recordInsert.bind(11, record.originDeviceID.canonical)
                try recordInsert.bind(12, record.payload.canonicalUTF8)
                try recordInsert.bind(
                    13,
                    ContentDigest.compute(record.payload.canonicalUTF8).description
                )
                try recordInsert.bind(14, record.deleted ? Int64(1) : Int64(0))
                _ = try recordInsert.step()
            }

            let update = try connection.prepare(
                """
                UPDATE snapshot_imports SET
                    next_page_index = ?,
                    received_page_count = received_page_count + 1,
                    received_entry_count = received_entry_count + ?,
                    staged_bytes = staged_bytes + ?
                WHERE peer_device_id = ? AND snapshot_id = ? AND state = 'staging'
                """
            )
            try update.bind(1, Int64(envelope.pageIndex + 1))
            try update.bind(2, Int64(envelope.records.count))
            try update.bind(3, Int64(payloadBytes))
            try update.bind(4, peerDeviceID.canonical)
            try update.bind(5, envelope.snapshotID.canonical)
            _ = try update.step()
            guard connection.changedRowCount == 1 else {
                throw SyncStoreError.schemaCorrupt("staged snapshot row disappeared")
            }

            try testHooks.afterSnapshotPageStaged?()

            guard let updated = try SyncStore.loadSnapshotImport(
                connection,
                peer: peerDeviceID,
                snapshotID: envelope.snapshotID
            ) else {
                throw SyncStoreError.schemaCorrupt("staged snapshot row disappeared")
            }
            return SyncStore.progress(from: updated)
        }
    }

    public func snapshotImportStatus(
        peerDeviceID: DeviceID,
        snapshotID: SnapshotID
    ) throws -> SnapshotImportProgress? {
        try readTransaction { connection in
            guard let staging = try SyncStore.loadSnapshotImport(
                connection,
                peer: peerDeviceID,
                snapshotID: snapshotID
            ) else {
                return nil
            }
            return SyncStore.progress(from: staging)
        }
    }

    /// Abandons a staging session without touching visible records or any
    /// cursor. Returns false when no staging session exists.
    @discardableResult
    public func abortSnapshotImport(
        peerDeviceID: DeviceID,
        snapshotID: SnapshotID
    ) throws -> Bool {
        try writeTransaction { connection in
            // Delete by durable key rather than decoding the manifest. Old
            // pre-version-bound staging remains preserved after migration and
            // fails closed, but an explicit abort must still be possible.
            let delete = try connection.prepare(
                "DELETE FROM snapshot_imports WHERE peer_device_id = ? AND snapshot_id = ? AND state = 'staging'"
            )
            try delete.bind(1, peerDeviceID.canonical)
            try delete.bind(2, snapshotID.canonical)
            _ = try delete.step()
            return connection.changedRowCount == 1
        }
    }

    @discardableResult
    public func pruneExpiredSnapshotImports() throws -> Int {
        try writeTransaction { connection in
            try SyncStore.purgeExpiredStagingImports(connection, atMillis: nowMillis())
        }
    }

    /// Commits a completely staged snapshot in one transaction. Every page is
    /// re-validated from persisted rows, not from a caller's completion claim.
    /// Visible records, tombstone updates, persisted conflicts, the durable
    /// unreconciled-local report and the scope cursor either all commit or all
    /// roll back. The legacy per-peer global cursor is never modified here.
    public func commitSnapshotImport(
        peerDeviceID: DeviceID,
        snapshotID: SnapshotID
    ) throws -> SnapshotImportResult {
        throw SyncStoreError.snapshotImportUnverified
    }

    public func commitAuthenticatedSnapshotImport(_ signed: AuthenticatedSnapshotManifest) throws -> SnapshotImportResult {
        try verifySnapshotAuthentication(signed)
        return try commitSnapshotImportImpl(peerDeviceID: signed.manifest.originDeviceID,
            snapshotID: signed.manifest.snapshotID, authenticatedManifest: signed.manifest)
    }

    func commitSnapshotImportForTesting(peerDeviceID: DeviceID, snapshotID: SnapshotID) throws -> SnapshotImportResult {
        try commitSnapshotImportImpl(peerDeviceID: peerDeviceID, snapshotID: snapshotID, authenticatedManifest: nil)
    }

    private func commitSnapshotImportImpl(peerDeviceID: DeviceID, snapshotID: SnapshotID,
                                         authenticatedManifest: SnapshotManifest?) throws -> SnapshotImportResult {
        try writeTransaction { connection in
            let now = nowMillis()
            guard let staging = try SyncStore.loadSnapshotImport(
                connection,
                peer: peerDeviceID,
                snapshotID: snapshotID
            ) else {
                throw SyncStoreError.snapshotImportNotFound(peerDeviceID, snapshotID)
            }
            let manifest = staging.manifest
            if let authenticatedManifest {
                guard authenticatedManifest == manifest else { throw SyncStoreError.snapshotImportUnverified }
                guard try SyncStore.loadScopeAuthorization(connection, peer: peerDeviceID, scope: manifest.scope) != nil else {
                    throw SyncStoreError.incrementalScopeUnauthorized(peerDeviceID, manifest.scope)
                }
            }
            guard let subscription = try SyncStore.loadSubscription(
                connection,
                peer: peerDeviceID,
                scope: manifest.scope
            ) else {
                throw SyncStoreError.snapshotImportReceiptCorrupt
            }
            guard subscription.version == staging.subscriptionVersion else {
                throw SyncStoreError.subscriptionVersionMismatch(
                    peerDeviceID,
                    manifest.scope,
                    expected: staging.subscriptionVersion,
                    found: subscription.version
                )
            }
            if staging.state == .committed, let receipt = staging.receipt {
                return receipt.withDuplicate(true)
            }
            if staging.expiresAtMillis <= now {
                throw SyncStoreError.snapshotImportExpired(peerDeviceID, snapshotID)
            }
            if subscription.established,
               subscription.lastSnapshotID == snapshotID,
               subscription.appliedCursor >= manifest.baseCursor {
                if let receipt = staging.receipt {
                    return receipt.withDuplicate(true)
                }
                return SnapshotImportResult(
                    snapshotID: snapshotID,
                    scope: manifest.scope,
                    subscriptionVersion: staging.subscriptionVersion,
                    baseCursor: manifest.baseCursor,
                    applied: [],
                    unchanged: [],
                    conflicts: [],
                    unreconciledLocalKeys: [],
                    isDuplicate: true
                )
            }
            guard subscription.appliedCursor <= manifest.baseCursor else {
                throw SyncStoreError.snapshotBaseStale(
                    peerDeviceID,
                    manifest.scope,
                    current: subscription.appliedCursor,
                    received: manifest.baseCursor
                )
            }
            guard staging.nextPageIndex == manifest.pageCount,
                  staging.receivedPageCount == manifest.pageCount,
                  staging.receivedEntryCount == manifest.entryCount else {
                throw SyncStoreError.snapshotPagesIncomplete(
                    received: staging.receivedPageCount,
                    expected: manifest.pageCount
                )
            }

            // First pass: verify every persisted page and record without
            // writing visible state. Only after the complete set is proven do
            // we apply anything, so a later corrupt page cannot publish an
            // earlier prefix even briefly inside the transaction.
            var verifiedEntries = 0
            var liveCount = 0
            var tombstoneCount = 0
            var snapshotKeys = Set<RecordKey>()
            for page in manifest.pages {
                let pageRead = try SyncStore.verifyStagedPage(
                    connection,
                    peer: peerDeviceID,
                    snapshotID: snapshotID,
                    page: page,
                    scope: manifest.scope,
                    maxPayloadBytes: configuration.maxPayloadBytes
                )
                for record in pageRead.records {
                    snapshotKeys.insert(
                        RecordKey(kind: record.kind, entityID: record.entityID)
                    )
                    liveCount += record.deleted ? 0 : 1
                    tombstoneCount += record.deleted ? 1 : 0
                }
                verifiedEntries += pageRead.records.count
            }
            guard verifiedEntries == manifest.entryCount,
                  liveCount == manifest.recordCount,
                  tombstoneCount == manifest.tombstoneCount else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "staged pages do not match the manifest counts"
                )
            }
            let totalRows = try SyncStore.stagedRecordCount(
                connection,
                peer: peerDeviceID,
                snapshotID: snapshotID
            )
            guard totalRows == manifest.entryCount else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "staged row count does not match the manifest entry count"
                )
            }

            // Second pass: apply one bounded page at a time. The whole
            // snapshot remains one SQLite transaction; a later failure rolls
            // back every record, conflict and cursor change.
            var applied: [RecordKey] = []
            var unchanged: [RecordKey] = []
            var conflicts: [RecordConflict] = []
            for page in manifest.pages {
                let pageRead = try SyncStore.loadStagedPageRecords(
                    connection,
                    peer: peerDeviceID,
                    snapshotID: snapshotID,
                    firstPosition: page.firstPosition,
                    lastPosition: page.lastPosition
                )
                let pageOutcome = try SyncStore.applySnapshotRecords(
                    connection,
                    peerDeviceID: peerDeviceID,
                    records: pageRead.records,
                    observedCursor: manifest.baseCursor,
                    maxWritePayloadBytes: configuration.maxPayloadBytes,
                    atMillis: now
                )
                applied.append(contentsOf: pageOutcome.applied)
                unchanged.append(contentsOf: pageOutcome.unchanged)
                conflicts.append(contentsOf: pageOutcome.conflicts)
            }
            let localKeys = try SyncStore.localRecordKeys(
                connection,
                scope: manifest.scope,
                limit: configuration.maxSnapshotEntries
            )
            let unreconciled = localKeys
                .filter { !snapshotKeys.contains($0) }
                .sorted { lhs, rhs in
                    if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
                    return lhs.entityID < rhs.entityID
                }

            try testHooks.beforeSnapshotCommitFinalize?()

            let result = SnapshotImportResult(
                snapshotID: snapshotID,
                scope: manifest.scope,
                subscriptionVersion: staging.subscriptionVersion,
                baseCursor: manifest.baseCursor,
                applied: applied,
                unchanged: unchanged,
                conflicts: conflicts,
                unreconciledLocalKeys: unreconciled,
                isDuplicate: false
            )
            try SyncStore.establishSubscriptionCursor(
                connection,
                peer: peerDeviceID,
                scope: manifest.scope,
                version: staging.subscriptionVersion,
                cursor: manifest.baseCursor,
                lastSnapshotID: snapshotID,
                atMillis: now
            )

            let receiptBytes = try SyncStore.canonicalBytes(
                result.wireJSONValue(),
                limit: SyncStore.maximumReadBytes
            )
            let clearStaged = try connection.prepare(
                "DELETE FROM snapshot_import_records WHERE peer_device_id = ? AND snapshot_id = ?"
            )
            try clearStaged.bind(1, peerDeviceID.canonical)
            try clearStaged.bind(2, snapshotID.canonical)
            _ = try clearStaged.step()
            let clearPages = try connection.prepare(
                "DELETE FROM snapshot_import_pages WHERE peer_device_id = ? AND snapshot_id = ?"
            )
            try clearPages.bind(1, peerDeviceID.canonical)
            try clearPages.bind(2, snapshotID.canonical)
            _ = try clearPages.step()

            let finalize = try connection.prepare(
                """
                UPDATE snapshot_imports SET
                    state = 'committed', next_page_index = ?,
                    received_page_count = ?, received_entry_count = ?,
                    staged_bytes = 0, committed_at = ?, receipt = ?
                WHERE peer_device_id = ? AND snapshot_id = ? AND state = 'staging'
                """
            )
            try finalize.bind(1, Int64(manifest.pageCount))
            try finalize.bind(2, Int64(manifest.pageCount))
            try finalize.bind(3, Int64(manifest.entryCount))
            try finalize.bind(4, now)
            try finalize.bind(5, receiptBytes)
            try finalize.bind(6, peerDeviceID.canonical)
            try finalize.bind(7, snapshotID.canonical)
            _ = try finalize.step()
            guard connection.changedRowCount == 1 else {
                throw SyncStoreError.schemaCorrupt("staged snapshot row disappeared")
            }

            // Keep one small committed receipt per subscription instead of an
            // unbounded history of old snapshot payloads.
            let pruneReceipts = try connection.prepare(
                """
                DELETE FROM snapshot_imports
                WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
                  AND state = 'committed' AND snapshot_id != ?
                """
            )
            try pruneReceipts.bind(1, peerDeviceID.canonical)
            try pruneReceipts.bind(2, manifest.scope.kind)
            try pruneReceipts.bind(3, manifest.scope.identifier ?? "")
            try pruneReceipts.bind(4, snapshotID.canonical)
            _ = try pruneReceipts.step()

            return result
        }
    }

    // MARK: - Scope subscriptions

    public func subscription(
        peerDeviceID: DeviceID,
        scope: SnapshotScope
    ) throws -> SyncSubscription? {
        try readTransaction { connection in
            try SyncStore.loadSubscription(connection, peer: peerDeviceID, scope: scope)
        }
    }

    public func subscriptions(peerDeviceID: DeviceID? = nil) throws -> [SyncSubscription] {
        try readTransaction { connection in
            let statement: SQLiteStatement
            if let peerDeviceID {
                statement = try connection.prepare(
                    """
                    SELECT peer_device_id, scope_kind, scope_id, subscription_version,
                           applied_cursor, established, last_snapshot_id, updated_at
                    FROM sync_subscriptions
                    WHERE peer_device_id = ?
                    ORDER BY scope_kind, scope_id
                    """
                )
                try statement.bind(1, peerDeviceID.canonical)
            } else {
                statement = try connection.prepare(
                    """
                    SELECT peer_device_id, scope_kind, scope_id, subscription_version,
                           applied_cursor, established, last_snapshot_id, updated_at
                    FROM sync_subscriptions
                    ORDER BY peer_device_id, scope_kind, scope_id
                    """
                )
            }
            var values: [SyncSubscription] = []
            while try statement.step() {
                values.append(try SyncStore.decodeSubscription(statement))
            }
            return values
        }
    }

    /// Starts a new subscription generation for one peer and scope. Only an
    /// explicit reset may invalidate an in-flight snapshot; a stale snapshot
    /// from the previous generation then fails its version check. The legacy
    /// global cursor is intentionally left out of this row.
    @discardableResult
    public func resetSubscription(
        peerDeviceID: DeviceID,
        scope: SnapshotScope,
        version: Int64
    ) throws -> SyncSubscription {
        guard version > 0 else {
            throw SyncStoreError.invalidSubscriptionVersion(version)
        }
        return try writeTransaction { connection in
            let now = nowMillis()
            if let existing = try SyncStore.loadSubscription(
                connection,
                peer: peerDeviceID,
                scope: scope
            ) {
                if version < existing.version {
                    throw SyncStoreError.subscriptionVersionMismatch(
                        peerDeviceID,
                        scope,
                        expected: version,
                        found: existing.version
                    )
                }
                if version == existing.version {
                    return existing
                }
            }
            let deleteImports = try connection.prepare(
                "DELETE FROM snapshot_imports WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?"
            )
            try deleteImports.bind(1, peerDeviceID.canonical)
            try deleteImports.bind(2, scope.kind)
            try deleteImports.bind(3, scope.identifier ?? "")
            _ = try deleteImports.step()

            // A receipt proves a batch for one generation. Keeping old
            // generations after an explicit reset would let stale replay
            // receipts accumulate and could mask a real gap if a version
            // number were ever reused. The visible cursor is already reset;
            // receipts are receipt-only state and are deleted with it.
            let deleteReceipts = try connection.prepare(
                "DELETE FROM incremental_receipts WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?"
            )
            try deleteReceipts.bind(1, peerDeviceID.canonical)
            try deleteReceipts.bind(2, scope.kind)
            try deleteReceipts.bind(3, scope.identifier ?? "")
            _ = try deleteReceipts.step()

            let statement = try connection.prepare(
                """
                INSERT INTO sync_subscriptions (
                    peer_device_id, scope_kind, scope_id, subscription_version,
                    applied_cursor, established, last_snapshot_id, updated_at
                ) VALUES (?, ?, ?, ?, 0, 0, NULL, ?)
                ON CONFLICT(peer_device_id, scope_kind, scope_id) DO UPDATE SET
                    subscription_version = excluded.subscription_version,
                    applied_cursor = 0,
                    established = 0,
                    last_snapshot_id = NULL,
                    updated_at = excluded.updated_at
                """
            )
            try statement.bind(1, peerDeviceID.canonical)
            try statement.bind(2, scope.kind)
            try statement.bind(3, scope.identifier ?? "")
            try statement.bind(4, version)
            try statement.bind(5, now)
            _ = try statement.step()
            guard let reset = try SyncStore.loadSubscription(
                connection,
                peer: peerDeviceID,
                scope: scope
            ) else {
                throw SyncStoreError.schemaCorrupt("subscription row disappeared")
            }
            return reset
        }
    }

    /// Applies changes only to an already established scope subscription. The
    /// caller must have received a complete verified snapshot first; this
    /// method cannot establish or repair completeness, and it never advances
    /// the legacy per-peer global cursor.
    public func applyScopedRemoteBatch(
        peerDeviceID: DeviceID,
        scope: SnapshotScope,
        through cursor: ChangeCursor,
        records: [SyncRecord]
    ) throws -> RemoteApplyResult {
        // The legacy shape cannot carry a subscription epoch, expected starting
        // cursor or authenticated proof of the scanned interval. Do not accept
        // a later page as evidence that all earlier changes were observed.
        _ = try openConnection()
        throw SyncStoreError.scopedIncrementalUnverified
    }

    // MARK: - Local scope authorization

    /// Records an explicit local user decision that `peerDeviceID` may
    /// synchronize `scope`. This is the only way a peer becomes authorized for
    /// incremental input; grants are never inferred from a snapshot, a batch,
    /// or another device's grant. Repeating the call is idempotent and keeps
    /// the original grant time.
    @discardableResult
    public func grantScopeAccess(
        peerDeviceID: DeviceID,
        scope: SnapshotScope
    ) throws -> ScopeAuthorization {
        guard peerDeviceID != deviceID else {
            throw SyncStoreError.invalidScopeGrant("a device cannot grant scope access to itself")
        }
        return try writeTransaction { connection in
            if let subscription = try SyncStore.loadSubscription(connection, peer: peerDeviceID, scope: scope),
               subscription.version == Int64.max, !subscription.established {
                throw SyncStoreError.invalidScopeGrant("subscription generation exhausted; a new paired identity is required")
            }
            let now = nowMillis()
            let statement = try connection.prepare(
                """
                INSERT INTO sync_scope_authorizations (
                    peer_device_id, scope_kind, scope_id, granted_at, updated_at
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(peer_device_id, scope_kind, scope_id) DO UPDATE SET
                    updated_at = excluded.updated_at
                """
            )
            try statement.bind(1, peerDeviceID.canonical)
            try statement.bind(2, scope.kind)
            try statement.bind(3, scope.identifier ?? "")
            try statement.bind(4, now)
            try statement.bind(5, now)
            _ = try statement.step()
            guard let authorization = try SyncStore.loadScopeAuthorization(
                connection,
                peer: peerDeviceID,
                scope: scope
            ) else {
                throw SyncStoreError.schemaCorrupt("scope authorization row disappeared")
            }
            return authorization
        }
    }

    /// Revocation fences the authorization generation atomically. Visible
    /// records remain, while staged imports, old receipts and the prior cursor
    /// cannot become valid again when this scope is later granted anew.
    @discardableResult
    public func revokeScopeAccess(
        peerDeviceID: DeviceID,
        scope: SnapshotScope
    ) throws -> Bool {
        try writeTransaction { connection in
            let statement = try connection.prepare(
                """
                DELETE FROM sync_scope_authorizations
                WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
                """
            )
            try statement.bind(1, peerDeviceID.canonical)
            try statement.bind(2, scope.kind)
            try statement.bind(3, scope.identifier ?? "")
            _ = try statement.step()
            guard connection.changedRowCount == 1 else { return false }
            let current = try SyncStore.loadSubscription(connection, peer: peerDeviceID, scope: scope)
            let oldVersion = current?.version ?? 1
            // A merely incremented generation can be pre-signed before
            // revocation. Pick a fresh OS-random, strictly newer version with
            // at least 56 bits of choice; reserve a terminal sentinel when the
            // remaining range is too small. Revocation itself must still work.
            let minimumChoices: Int64 = 1 << 56
            let available = Int64.max - oldVersion
            let next: Int64 = available >= minimumChoices
                ? Int64.random(in: (oldVersion + 1)...Int64.max)
                : Int64.max
            let clearImports = try connection.prepare(
                "DELETE FROM snapshot_imports WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?"
            )
            try clearImports.bind(1, peerDeviceID.canonical)
            try clearImports.bind(2, scope.kind)
            try clearImports.bind(3, scope.identifier ?? "")
            _ = try clearImports.step()
            let clearReceipts = try connection.prepare(
                "DELETE FROM incremental_receipts WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?"
            )
            try clearReceipts.bind(1, peerDeviceID.canonical)
            try clearReceipts.bind(2, scope.kind)
            try clearReceipts.bind(3, scope.identifier ?? "")
            _ = try clearReceipts.step()
            let update = try connection.prepare(
                """
                INSERT INTO sync_subscriptions (peer_device_id, scope_kind, scope_id, subscription_version,
                    applied_cursor, established, last_snapshot_id, updated_at)
                VALUES (?, ?, ?, ?, 0, 0, NULL, ?)
                ON CONFLICT(peer_device_id, scope_kind, scope_id) DO UPDATE SET
                    subscription_version = excluded.subscription_version, applied_cursor = 0,
                    established = 0, last_snapshot_id = NULL, updated_at = excluded.updated_at
                """
            )
            try update.bind(1, peerDeviceID.canonical)
            try update.bind(2, scope.kind)
            try update.bind(3, scope.identifier ?? "")
            try update.bind(4, next)
            try update.bind(5, nowMillis())
            _ = try update.step()
            return true
        }
    }

    public func scopeAuthorizations(
        peerDeviceID: DeviceID? = nil
    ) throws -> [ScopeAuthorization] {
        try readTransaction { connection in
            let statement: SQLiteStatement
            if let peerDeviceID {
                statement = try connection.prepare(
                    """
                    SELECT peer_device_id, scope_kind, scope_id, granted_at, updated_at
                    FROM sync_scope_authorizations
                    WHERE peer_device_id = ?
                    ORDER BY scope_kind, scope_id
                    """
                )
                try statement.bind(1, peerDeviceID.canonical)
            } else {
                statement = try connection.prepare(
                    """
                    SELECT peer_device_id, scope_kind, scope_id, granted_at, updated_at
                    FROM sync_scope_authorizations
                    ORDER BY peer_device_id, scope_kind, scope_id
                    """
                )
            }
            var values: [ScopeAuthorization] = []
            while try statement.step() {
                values.append(try SyncStore.decodeScopeAuthorization(statement))
            }
            return values
        }
    }

    public func isScopeAuthorized(
        peerDeviceID: DeviceID,
        scope: SnapshotScope
    ) throws -> Bool {
        try readTransaction { connection in
            try SyncStore.loadScopeAuthorization(
                connection,
                peer: peerDeviceID,
                scope: scope
            ) != nil
        }
    }

    // MARK: - Authenticated incremental sync

    /// Applies one authenticated, gap-free incremental scan interval.
    ///
    /// Requirements, all checked before or inside the single write
    /// transaction:
    /// - a trusted authenticator is attached and verifies this exact batch;
    /// - the authenticated peer matches both the batch claim and the local
    ///   scope grant for that peer;
    /// - the subscription exists, is established by a verified snapshot, and
    ///   is at the exact `subscriptionVersion`;
    /// - `fromCursor` equals the subscription's current applied cursor exactly;
    /// - every change cursor lies in `(fromCursor, throughCursor]`, is strictly
    ///   increasing, and every record belongs to the declared scope;
    /// - the atomic subscription-cursor CAS, applied records, persisted
    ///   conflicts and replay receipt commit in one `BEGIN IMMEDIATE`.
    ///
    /// An exact retry of already committed content returns the stored receipt
    /// with `isDuplicate = true`. The same interval with different content is
    /// refused. A batch with `throughCursor == fromCursor` and no changes is a
    /// verified no-op; a wider interval with no in-scope changes still advances
    /// the cursor because the sender proved it scanned that range.
    public func applyAuthenticatedIncrementalBatch(
        _ batch: IncrementalBatch
    ) throws -> IncrementalApplyResult {
        try batch.validateStructure()
        guard batch.receiverDeviceID == deviceID else {
            throw SyncStoreError.incrementalAuthenticationFailed(
                "batch is addressed to a different receiving device"
            )
        }
        guard batch.peerDeviceID != deviceID else {
            throw SyncStoreError.incrementalAuthenticationFailed(
                "a batch cannot claim the local device as its origin"
            )
        }
        try batch.validateLimits(
            maxRecords: configuration.maxBatchRecords,
            maxBytes: configuration.maxBatchBytes,
            maxPayloadBytes: configuration.maxPayloadBytes
        )
        let authenticationDigest = try batch.authenticationDigestThrowing()
        let contentDigest = batch.contentDigest()
        guard let authenticator = incrementalAuthenticator else {
            throw SyncStoreError.incrementalAuthenticationUnavailable
        }
        if let snapshotAuthenticator, let hmac = authenticator as? HMACIncrementalAuthenticator {
            try snapshotAuthenticator.validatePeerKeyIsolation(from: hmac)
        }
        let authentication = try authenticator.authenticate(
            IncrementalAuthenticationRequest(
                batch: batch,
                authenticationDigest: authenticationDigest
            )
        )
        guard authentication.authenticationDigest == authenticationDigest else {
            throw SyncStoreError.incrementalAuthenticationFailed(
                "authenticator verified a different batch digest"
            )
        }
        guard authentication.peerDeviceID == batch.peerDeviceID else {
            throw SyncStoreError.incrementalPeerMismatch(
                expected: authentication.peerDeviceID,
                found: batch.peerDeviceID
            )
        }

        return try writeTransaction { connection in
            guard try SyncStore.loadScopeAuthorization(
                connection,
                peer: batch.peerDeviceID,
                scope: batch.scope
            ) != nil else {
                throw SyncStoreError.incrementalScopeUnauthorized(
                    batch.peerDeviceID,
                    batch.scope
                )
            }
            guard let subscription = try SyncStore.loadSubscription(
                connection,
                peer: batch.peerDeviceID,
                scope: batch.scope
            ) else {
                throw SyncStoreError.subscriptionNotEstablished(
                    batch.peerDeviceID,
                    batch.scope
                )
            }
            guard subscription.version == batch.subscriptionVersion else {
                throw SyncStoreError.subscriptionVersionMismatch(
                    batch.peerDeviceID,
                    batch.scope,
                    expected: batch.subscriptionVersion,
                    found: subscription.version
                )
            }
            guard subscription.established else {
                throw SyncStoreError.subscriptionNotEstablished(
                    batch.peerDeviceID,
                    batch.scope
                )
            }

            if let receipt = try SyncStore.loadIncrementalReceipt(
                connection,
                peer: batch.peerDeviceID,
                scope: batch.scope,
                version: batch.subscriptionVersion,
                from: batch.fromCursor,
                through: batch.throughCursor,
                maxResultBytes: SyncStore.maximumReadBytes
            ) {
                guard receipt.contentDigest == contentDigest else {
                    throw SyncStoreError.incrementalReplayConflict(
                        batch.peerDeviceID,
                        batch.scope,
                        from: batch.fromCursor,
                        through: batch.throughCursor
                    )
                }
                return receipt.result.withDuplicate(true)
            }

            // Exact starting-cursor CAS. `fromCursor < applied` is an overlap
            // or stale replay without a retained receipt; `fromCursor >
            // applied` is a gap. Neither may advance the cursor.
            guard batch.fromCursor == subscription.appliedCursor else {
                throw SyncStoreError.incrementalRangeGap(
                    batch.peerDeviceID,
                    batch.scope,
                    expected: subscription.appliedCursor,
                    receivedFrom: batch.fromCursor
                )
            }

            if batch.changes.isEmpty, batch.throughCursor == batch.fromCursor {
                return IncrementalApplyResult(
                    peerDeviceID: batch.peerDeviceID,
                    scope: batch.scope,
                    subscriptionVersion: batch.subscriptionVersion,
                    fromCursor: batch.fromCursor,
                    throughCursor: batch.throughCursor,
                    applied: [],
                    unchanged: [],
                    conflicts: [],
                    isDuplicate: false
                )
            }

            let now = nowMillis()
            let outcome = try SyncStore.applyRecords(
                connection,
                peerDeviceID: batch.peerDeviceID,
                records: batch.changes.map(\.record),
                observedCursor: batch.throughCursor,
                maxWritePayloadBytes: configuration.maxPayloadBytes,
                atMillis: now
            )
            try testHooks.afterIncrementalRecordsApplied?()

            try SyncStore.advanceSubscriptionCursor(
                connection,
                peer: batch.peerDeviceID,
                scope: batch.scope,
                version: batch.subscriptionVersion,
                from: batch.fromCursor,
                through: batch.throughCursor,
                atMillis: now
            )

            let result = IncrementalApplyResult(
                peerDeviceID: batch.peerDeviceID,
                scope: batch.scope,
                subscriptionVersion: batch.subscriptionVersion,
                fromCursor: batch.fromCursor,
                throughCursor: batch.throughCursor,
                applied: outcome.applied,
                unchanged: outcome.unchanged,
                conflicts: outcome.conflicts,
                isDuplicate: false
            )
            let resultBytes = try SyncStore.canonicalBytes(
                result.wireJSONValue(),
                limit: SyncStore.maximumReadBytes
            )
            try SyncStore.insertIncrementalReceipt(
                connection,
                peer: batch.peerDeviceID,
                scope: batch.scope,
                version: batch.subscriptionVersion,
                from: batch.fromCursor,
                through: batch.throughCursor,
                contentDigest: contentDigest,
                result: resultBytes,
                atMillis: now
            )
            try SyncStore.pruneIncrementalReceipts(
                connection,
                peer: batch.peerDeviceID,
                scope: batch.scope,
                version: batch.subscriptionVersion,
                keep: configuration.maxIncrementalReceipts
            )
            return result
        }
    }

    /// Sender-side scan of the next contiguous local change range for one
    /// scope. It reads all retained changes in `(after, through]` in sequence
    /// order, keeps only records belonging to `scope`, and sets
    /// `throughCursor` to the end of the range actually inspected — never to
    /// the largest matched event. Changes for other scopes therefore create
    /// allowed gaps, and a range with no in-scope changes still produces a
    /// non-empty interval that the receiver can advance.
    ///
    /// The batch's `peerDeviceID` is this store's own identity. The destination
    /// must be supplied from the authenticated pairing/session, and is bound
    /// by the proof and checked against the receiving store's own identity.
    ///
    /// The returned batch has no proof; call `signed(keyID:key:)` with the
    /// pairing key before sending. The integration owns the handshake that
    /// supplies `subscriptionVersion` and the exact `after` cursor, and must
    /// retry the same signed batch rather than re-deriving a new one.
    public func nextIncrementalBatch(
        receiverDeviceID: DeviceID,
        scope: SnapshotScope,
        subscriptionVersion: Int64,
        after cursor: ChangeCursor,
        maxRecords: Int? = nil,
        maxBytes: Int? = nil
    ) throws -> IncrementalBatch {
        guard receiverDeviceID != deviceID else {
            throw SyncStoreError.incrementalBatchInvalid("receiver must differ from sender")
        }
        guard subscriptionVersion > 0 else {
            throw SyncStoreError.invalidSubscriptionVersion(subscriptionVersion)
        }
        let recordLimit = maxRecords ?? configuration.maxBatchRecords
        guard recordLimit >= 1, recordLimit <= configuration.maxBatchRecords else {
            throw SyncStoreError.invalidConfiguration(
                "incremental maxRecords must be within 1...\(configuration.maxBatchRecords)"
            )
        }
        let byteLimit = maxBytes ?? configuration.maxBatchBytes
        guard byteLimit >= 1, byteLimit <= configuration.maxBatchBytes else {
            throw SyncStoreError.invalidConfiguration(
                "incremental maxBytes must be within 1...\(configuration.maxBatchBytes)"
            )
        }

        return try readTransaction { connection in
            let latest = try SyncStore.latestCursor(connection)
            guard cursor <= latest else {
                throw SyncStoreError.cursorAhead(current: latest, received: cursor)
            }
            let prunedThrough = try SyncStore.prunedThrough(connection)
            guard cursor >= prunedThrough else {
                throw SyncStoreError.cursorExpired(cursor, retainedFrom: prunedThrough)
            }
            if cursor == latest {
                return try IncrementalBatch(
                    peerDeviceID: deviceID,
                    receiverDeviceID: receiverDeviceID,
                    scope: scope,
                    subscriptionVersion: subscriptionVersion,
                    fromCursor: cursor,
                    throughCursor: cursor,
                    changes: []
                )
            }

            // First establish a bounded, contiguous inspected boundary. Rows
            // outside the requested scope still advance this boundary, which
            // is what makes a filtered-empty interval meaningful.
            let window = try connection.prepare(
                """
                SELECT sequence FROM changes
                WHERE sequence > ? AND sequence <= ?
                ORDER BY sequence
                LIMIT ?
                """
            )
            try window.bind(1, cursor.rawValue)
            try window.bind(2, latest.rawValue)
            try window.bind(3, Int64(configuration.maxIncrementalScanRows + 1))
            var inspected = 0
            var scannedThrough = cursor
            while try window.step() {
                inspected += 1
                if inspected > configuration.maxIncrementalScanRows {
                    break
                }
                scannedThrough = ChangeCursor(unchecked: window.int64(0) ?? 0)
            }
            if inspected <= configuration.maxIncrementalScanRows {
                scannedThrough = latest
            }

            var filter = ""
            switch scope {
            case .all:
                break
            case .task:
                filter = " AND task_id = ?"
            case .workspace:
                filter = " AND workspace_id = ?"
            }
            let statement = try connection.prepare(
                """
                SELECT sequence, entity_kind, entity_id, task_id, workspace_id,
                       revision, base_revision, base_digest, change_type,
                       origin_device_id, payload, payload_digest, recorded_at,
                       length(payload)
                FROM changes
                WHERE sequence > ? AND sequence <= ?\(filter)
                ORDER BY sequence
                LIMIT ?
                """
            )
            try statement.bind(1, cursor.rawValue)
            try statement.bind(2, scannedThrough.rawValue)
            var bindIndex = 3
            if let identifier = scope.identifier {
                try statement.bind(bindIndex, identifier)
                bindIndex += 1
            }
            try statement.bind(bindIndex, Int64(recordLimit + 1))

            var changes: [IncrementalChange] = []
            var usedBytes = 0
            var truncated = false
            while try statement.step() {
                if changes.count >= recordLimit {
                    truncated = true
                    break
                }
                let payloadBytes = Int(statement.int64(13) ?? 0)
                if usedBytes + payloadBytes > byteLimit {
                    guard !changes.isEmpty else {
                        throw SyncStoreError.batchBytesTooLarge(limit: byteLimit)
                    }
                    truncated = true
                    break
                }
                let entry = try SyncStore.decodeChangeEntry(statement)
                guard let record = entry.makeRecord() else {
                    throw SyncStoreError.schemaCorrupt("change row has no payload")
                }
                guard record.payload.canonicalByteCount(upTo: configuration.maxPayloadBytes)
                    <= configuration.maxPayloadBytes else {
                    throw SyncStoreError.payloadTooLarge(
                        limit: configuration.maxPayloadBytes
                    )
                }
                changes.append(
                    IncrementalChange(sourceCursor: entry.cursor, record: record)
                )
                usedBytes += payloadBytes
            }
            let through = truncated
                ? (changes.last?.sourceCursor ?? cursor)
                : scannedThrough
            return try IncrementalBatch(
                peerDeviceID: deviceID,
                receiverDeviceID: receiverDeviceID,
                scope: scope,
                subscriptionVersion: subscriptionVersion,
                fromCursor: cursor,
                throughCursor: through,
                changes: changes
            )
        }
    }

    /// Snapshot import is unavailable until the receiver can verify every
    /// page, its identity and scope before committing a scope-bound cursor.
    public func applySnapshotPage(
        peerDeviceID: DeviceID,
        records: [SyncRecord]
    ) throws -> RemoteApplyResult {
        // This legacy API carries neither snapshot identity nor scope/page
        // continuity. Applying even one page would make a partial import look
        // like ordinary durable state; fail closed until that protocol exists.
        _ = try openConnection()
        throw SyncStoreError.snapshotImportUnverified
    }

    /// The legacy unscoped cursor commit cannot prove a complete snapshot.
    public func commitAppliedCursor(
        peerDeviceID: DeviceID,
        through cursor: ChangeCursor
    ) throws -> ChangeCursor {
        _ = try openConnection()
        throw SyncStoreError.snapshotImportUnverified
    }

    public func appliedCursor(for peerDeviceID: DeviceID) throws -> ChangeCursor {
        let connection = try openConnection()
        return try SyncStore.appliedCursor(connection, peer: peerDeviceID)
    }

    // MARK: - Durable conflicts

    /// Returns persisted conflicts. Both the local and incoming record are
    /// stored in the same transaction as the batch/cursor, so a crash after
    /// the remote cursor advanced cannot lose the refused version.
    public func conflicts(openOnly: Bool = true, limit: Int = 100) throws -> [StoredConflict] {
        guard (1...1_000).contains(limit) else {
            throw SyncStoreError.invalidPageSize(limit)
        }
        return try readTransaction { connection in
            let statement = try connection.prepare(
                """
                SELECT conflict_id, peer_device_id, reason, status, resolution,
                       observed_cursor, created_at, resolved_at,
                       entity_kind, entity_id, task_id, workspace_id, local_revision,
                       local_base_revision, local_base_digest,
                       local_origin_device_id, local_payload, local_payload_digest,
                       local_deleted, incoming_task_id, incoming_workspace_id,
                       incoming_revision, incoming_base_revision,
                       incoming_base_digest, incoming_origin_device_id,
                       incoming_payload, incoming_payload_digest, incoming_deleted
                FROM conflicts
                \(openOnly ? "WHERE status = 'open'" : "")
                ORDER BY created_at DESC, conflict_id
                LIMIT ?
                """
            )
            try statement.bind(1, Int64(limit))
            var result: [StoredConflict] = []
            while try statement.step() {
                result.append(try SyncStore.decodeConflict(statement))
            }
            return result
        }
    }

    public func storedConflict(for conflictID: ConflictID) throws -> StoredConflict? {
        try readTransaction { connection in
            try SyncStore.loadConflict(connection, id: conflictID)
        }
    }

    /// Resolves a persisted conflict explicitly. `acceptRemote` refuses when
    /// the local row changed since the conflict was recorded; it never
    /// silently overwrites a newer edit.
    @discardableResult
    public func resolveConflict(
        _ conflictID: ConflictID,
        resolution: ConflictResolution
    ) throws -> StoredConflict {
        try writeTransaction { connection in
            guard let conflict = try SyncStore.loadConflict(connection, id: conflictID) else {
                throw SyncStoreError.conflictNotFound(conflictID)
            }
            guard conflict.status == .open else {
                throw SyncStoreError.conflictAlreadyResolved(conflictID)
            }
            let now = nowMillis()
            switch resolution {
            case .keepLocal:
                break
            case .acceptRemote:
                let key = conflict.key
                guard let current = try SyncStore.loadRecordRow(
                    connection,
                    kind: key.kind,
                    entityID: key.entityID,
                    maxPayloadBytes: SyncStore.maximumReadBytes
                ), current.record == conflict.local,
                   current.digest == conflict.localDigest else {
                    throw SyncStoreError.conflictStale(conflictID)
                }
                try SyncStore.requireMatchingScope(existing: current.record, incoming: conflict.incoming)
                let incoming: SyncRecord
                let isRebased: Bool
                if conflict.incoming.revision <= current.record.revision {
                    guard current.record.revision.rawValue < Int64.max else {
                        throw SyncStoreError.invalidRecord("cannot advance maximum revision during conflict resolution")
                    }
                    let remote = conflict.incoming
                    incoming = SyncRecord(
                        kind: remote.kind, entityID: remote.entityID,
                        taskID: remote.taskID, workspaceID: remote.workspaceID,
                        revision: try Revision(current.record.revision.rawValue + 1),
                        baseRevision: current.record.revision, baseDigest: current.digest,
                        originDeviceID: deviceID, payload: remote.payload, deleted: remote.deleted
                    )
                    isRebased = true
                } else {
                    incoming = conflict.incoming
                    isRebased = false
                }
                try SyncStore.upsertRecord(
                    connection,
                    record: incoming,
                    digest: conflict.incomingDigest,
                    localDirty: isRebased,
                    atMillis: now
                )
                _ = try SyncStore.appendChange(
                    connection,
                    record: incoming,
                    digest: conflict.incomingDigest,
                    type: incoming.deleted ? .delete : .upsert,
                    atMillis: now
                )
            }
            let update = try connection.prepare(
                "UPDATE conflicts SET status = 'resolved', resolution = ?, resolved_at = ? WHERE conflict_id = ? AND status = 'open'"
            )
            try update.bind(1, resolution.rawValue)
            try update.bind(2, now)
            try update.bind(3, conflictID.canonical)
            _ = try update.step()
            guard connection.changedRowCount == 1 else {
                throw SyncStoreError.conflictAlreadyResolved(conflictID)
            }
            guard let resolved = try SyncStore.loadConflict(connection, id: conflictID) else {
                throw SyncStoreError.conflictNotFound(conflictID)
            }
            return resolved
        }
    }

    // MARK: - Change cursors

    public func latestChangeCursor() throws -> ChangeCursor {
        let connection = try openConnection()
        return try SyncStore.latestCursor(connection)
    }

    /// Reads retained changes strictly after `cursor`. An expired cursor is
    /// reported rather than silently returning a partial range.
    public func changes(after cursor: ChangeCursor, limit: Int? = nil) throws -> ChangePage {
        let pageSize = try validatedPageSize(limit)
        // The expiry check and the row read are one SQLite read transaction.
        // The first SELECT establishes its snapshot, so a concurrent prune on
        // another connection cannot delete rows between the check and the page
        // read and silently produce a short page.
        return try readTransaction { connection in
            let latest = try SyncStore.latestCursor(connection)
            guard cursor <= latest else {
                throw SyncStoreError.cursorAhead(current: latest, received: cursor)
            }
            let prunedThrough = try SyncStore.prunedThrough(connection)
            guard cursor >= prunedThrough else {
                throw SyncStoreError.cursorExpired(cursor, retainedFrom: prunedThrough)
            }
            try testHooks.afterChangesValidation?()

            let statement = try connection.prepare(
                """
                SELECT sequence, entity_kind, entity_id, task_id, workspace_id,
                       revision, base_revision, base_digest, change_type,
                       origin_device_id, payload, payload_digest, recorded_at,
                       length(payload)
                FROM changes
                WHERE sequence > ?
                ORDER BY sequence
                LIMIT ?
                """
            )
            try statement.bind(1, cursor.rawValue)
            try statement.bind(2, Int64(pageSize + 1))
            var entries: [ChangeEntry] = []
            var usedBytes = 0
            var stoppedByBudget = false
            while try statement.step() {
                let payloadBytes = Int(statement.int64(13) ?? 0)
                let remaining = configuration.maxPageBytes - usedBytes
                if !entries.isEmpty, payloadBytes > remaining {
                    stoppedByBudget = true
                    break
                }
                entries.append(try SyncStore.decodeChangeEntry(statement))
                usedBytes += payloadBytes
            }
            let exceededCount = entries.count > pageSize
            let hasMore = exceededCount || stoppedByBudget
            if exceededCount {
                entries.removeLast(entries.count - pageSize)
            }
            return ChangePage(
                entries: entries,
                nextCursor: entries.last?.cursor ?? cursor,
                hasMore: hasMore
            )
        }
    }

    /// Drops changes at or below `cursor` and records that position. Requests
    /// older than the pruned position are then refused as expired.
    ///
    /// Unexpired snapshots protect changes up to their `baseCursor`: a client
    /// that received a snapshot must still be able to read every change after
    /// that base. The returned `prunedThrough` is the position actually
    /// reached, which can be lower than the request while a snapshot lives.
    public func pruneChanges(through cursor: ChangeCursor) throws -> PruneResult {
        try writeTransaction { connection in
            let latest = try SyncStore.latestCursor(connection)
            guard cursor <= latest else {
                throw SyncStoreError.cursorAhead(current: latest, received: cursor)
            }
            let existing = try SyncStore.prunedThrough(connection)
            let protectedThrough = try SyncStore.minimumActiveSnapshotBaseCursor(
                connection,
                atMillis: nowMillis()
            )
            let effective = protectedThrough.map {
                ChangeCursor(unchecked: min(cursor.rawValue, $0.rawValue))
            } ?? cursor
            guard effective > existing else {
                return PruneResult(removed: 0, prunedThrough: existing)
            }
            let delete = try connection.prepare("DELETE FROM changes WHERE sequence <= ?")
            try delete.bind(1, effective.rawValue)
            _ = try delete.step()
            let removed = connection.changedRowCount
            try SyncStore.setMeta(
                connection,
                key: "changes_pruned_through",
                value: effective.decimalString
            )
            return PruneResult(removed: removed, prunedThrough: effective)
        }
    }

    // MARK: - Consistent snapshots

    /// Materializes a consistent snapshot in one transaction. Paging always
    /// reads the frozen `snapshot_entries` rows, so writes after `baseCursor`
    /// cannot make pages disagree with each other.
    public func openSnapshot(scope: SnapshotScope = .all) throws -> SnapshotDescriptor {
        let now = nowMillis()
        return try writeTransaction { connection in
            let deleteExpired = try connection.prepare(
                "DELETE FROM snapshots WHERE expires_at <= ?"
            )
            try deleteExpired.bind(1, now)
            _ = try deleteExpired.step()

            let snapshotID = SnapshotID()
            let baseCursor = try SyncStore.latestCursor(connection)
            let expiresAt = now + Int64((configuration.snapshotLifetime * 1_000).rounded())
            let insert = try connection.prepare(
                """
                INSERT INTO snapshots (
                    snapshot_id, base_cursor, record_count, tombstone_count,
                    scope_kind, scope_id, created_at, expires_at, manifest_complete
                ) VALUES (?, ?, 0, 0, ?, ?, ?, ?, 1)
                """
            )
            try insert.bind(1, snapshotID.canonical)
            try insert.bind(2, baseCursor.rawValue)
            try insert.bind(3, scope.kind)
            try SyncStore.bindOptionalText(insert, 4, scope.identifier)
            try insert.bind(5, now)
            try insert.bind(6, expiresAt)
            _ = try insert.step()

            var filter = ""
            switch scope {
            case .all:
                break
            case .task:
                filter = " AND task_id = ?"
            case .workspace:
                filter = " AND workspace_id = ?"
            }
            // Both live rows and tombstones are materialized. A receiver with
            // older state must see the delete explicitly; absence from a
            // scoped page is not a tombstone.
            let materialize = try connection.prepare(
                """
                INSERT INTO snapshot_entries (
                    snapshot_id, position, entity_kind, entity_id, task_id,
                    workspace_id, revision, base_revision, base_digest,
                    origin_device_id, payload, payload_digest, deleted, updated_at
                )
                SELECT ?, ROW_NUMBER() OVER (ORDER BY entity_kind, entity_id),
                       entity_kind, entity_id, task_id, workspace_id, revision,
                       base_revision, base_digest, origin_device_id, payload,
                       payload_digest, deleted, updated_at
                FROM records
                WHERE 1 = 1\(filter)
                ORDER BY entity_kind, entity_id
                """
            )
            try materialize.bind(1, snapshotID.canonical)
            if let identifier = scope.identifier {
                try materialize.bind(2, identifier)
            }
            _ = try materialize.step()
            let entryCount = connection.changedRowCount

            let count = try connection.prepare(
                """
                SELECT
                    COALESCE(SUM(CASE WHEN deleted = 0 THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN deleted != 0 THEN 1 ELSE 0 END), 0)
                FROM records
                WHERE 1 = 1\(filter)
                """
            )
            if let identifier = scope.identifier {
                try count.bind(1, identifier)
            }
            guard try count.step() else {
                throw SyncStoreError.schemaCorrupt("cannot count snapshot records")
            }
            let recordCount = Int(count.int64(0) ?? 0)
            let tombstoneCount = Int(count.int64(1) ?? 0)
            guard entryCount == recordCount + tombstoneCount else {
                throw SyncStoreError.schemaCorrupt("snapshot entry count does not match records")
            }

            let update = try connection.prepare(
                "UPDATE snapshots SET record_count = ?, tombstone_count = ? WHERE snapshot_id = ?"
            )
            try update.bind(1, Int64(recordCount))
            try update.bind(2, Int64(tombstoneCount))
            try update.bind(3, snapshotID.canonical)
            _ = try update.step()

            return SnapshotDescriptor(
                snapshotID: snapshotID,
                baseCursor: baseCursor,
                recordCount: recordCount,
                tombstoneCount: tombstoneCount,
                scope: scope,
                createdAt: SyncStore.date(now),
                expiresAt: SyncStore.date(expiresAt)
            )
        }
    }

    public func snapshotPage(
        _ snapshotID: SnapshotID,
        after token: SnapshotPageToken? = nil,
        limit: Int? = nil
    ) throws -> SnapshotPage {
        let pageSize = try validatedPageSize(limit)
        if let token, token.snapshotID != snapshotID {
            throw SyncStoreError.snapshotTokenMismatch(
                expected: snapshotID,
                received: token.snapshotID
            )
        }
        // Validity check, token validation and the page query share one read
        // transaction. A concurrent close/prune on another connection cannot
        // slip between the check and the SELECT and yield a silent empty page.
        return try readTransaction { connection in
            guard let snapshot = try SyncStore.loadSnapshot(connection, id: snapshotID) else {
                throw SyncStoreError.snapshotNotFound(snapshotID)
            }
            guard snapshot.expiresAtMillis > nowMillis() else {
                throw SyncStoreError.snapshotExpired(snapshotID)
            }
            let start = token?.position ?? 0
            let entryCount = snapshot.descriptor.recordCount + snapshot.descriptor.tombstoneCount
            guard start <= Int64(entryCount) else {
                throw SyncStoreError.snapshotPageTokenInvalid(
                    "position \(start) is past the snapshot entry count"
                )
            }
            try testHooks.afterSnapshotValidation?()

            let read = try SyncStore.readSnapshotPageRows(
                connection,
                snapshotID: snapshotID,
                start: start,
                pageSize: pageSize,
                maxPageBytes: configuration.maxPageBytes
            )
            var records = read.records
            var positions = read.positions
            let hasMore = read.hasMore || records.count > pageSize
            if records.count > pageSize {
                records.removeLast(records.count - pageSize)
                positions.removeLast(positions.count - pageSize)
            }
            let nextToken: SnapshotPageToken?
            if hasMore, let lastPosition = positions.last {
                nextToken = try SnapshotPageToken(snapshotID: snapshotID, position: lastPosition)
            } else {
                nextToken = nil
            }
            return SnapshotPage(
                records: records,
                nextToken: nextToken,
                baseCursor: snapshot.descriptor.baseCursor
            )
        }
    }

    public func closeSnapshot(_ snapshotID: SnapshotID) throws {
        let connection = try openConnection()
        let statement = try connection.prepare(
            "DELETE FROM snapshots WHERE snapshot_id = ?"
        )
        try statement.bind(1, snapshotID.canonical)
        _ = try statement.step()
    }

    @discardableResult
    public func pruneExpiredSnapshots() throws -> Int {
        let connection = try openConnection()
        let statement = try connection.prepare(
            "DELETE FROM snapshots WHERE expires_at <= ?"
        )
        try statement.bind(1, nowMillis())
        _ = try statement.step()
        return connection.changedRowCount
    }

    // MARK: - Device-local mappings

    /// Stores a root path and bookmark for this device only. These columns are
    /// never selected by snapshot or change queries.
    public func setLocalWorkspaceBinding(
        workspaceID: WorkspaceID,
        rootPath: String,
        bookmark: Data? = nil
    ) throws {
        guard !rootPath.isEmpty,
              rootPath.utf8.count <= 16_384,
              !rootPath.contains("\0") else {
            throw SyncStoreError.invalidLocalBinding("rootPath must be non-empty and at most 16 KiB")
        }
        let now = nowMillis()
        try writeTransaction { connection in
            let statement = try connection.prepare(
                """
                INSERT INTO local_workspace_bindings (workspace_id, device_id, root_path, bookmark, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(workspace_id, device_id) DO UPDATE SET
                    root_path = excluded.root_path,
                    bookmark = excluded.bookmark,
                    updated_at = excluded.updated_at
                """
            )
            try statement.bind(1, workspaceID.canonical)
            try statement.bind(2, deviceID.canonical)
            try statement.bind(3, rootPath)
            if let bookmark {
                try statement.bind(4, [UInt8](bookmark))
            } else {
                try statement.bindNull(4)
            }
            try statement.bind(5, now)
            _ = try statement.step()
        }
    }

    public func localWorkspaceBinding(
        workspaceID: WorkspaceID
    ) throws -> LocalWorkspaceBinding? {
        let connection = try openConnection()
        let statement = try connection.prepare(
            """
            SELECT workspace_id, device_id, root_path, bookmark, updated_at
            FROM local_workspace_bindings
            WHERE workspace_id = ? AND device_id = ?
            """
        )
        try statement.bind(1, workspaceID.canonical)
        try statement.bind(2, deviceID.canonical)
        guard try statement.step() else { return nil }
        guard let workspaceText = statement.text(0),
              let deviceText = statement.text(1),
              let rootPath = statement.text(2) else {
            throw SyncStoreError.schemaCorrupt("local binding row is incomplete")
        }
        let bookmark = statement.blob(3).map { Data($0) }
        return LocalWorkspaceBinding(
            workspaceID: try WorkspaceID(validating: workspaceText),
            deviceID: try DeviceID(validating: deviceText),
            rootPath: rootPath,
            bookmark: bookmark,
            updatedAt: SyncStore.date(statement.int64(4) ?? 0)
        )
    }

    public func removeLocalWorkspaceBinding(workspaceID: WorkspaceID) throws {
        let connection = try openConnection()
        let statement = try connection.prepare(
            "DELETE FROM local_workspace_bindings WHERE workspace_id = ? AND device_id = ?"
        )
        try statement.bind(1, workspaceID.canonical)
        try statement.bind(2, deviceID.canonical)
        _ = try statement.step()
    }

    /// Registers a same-machine Bridge path-derived identifier as a local
    /// alias. The alias is never written to `records` or `changes` and has no
    /// global uniqueness; another device may map the same path differently.
    @discardableResult
    public func registerLegacyBridgeIdentifier(
        _ legacy: LegacyBridgeIdentifier,
        kind: SyncEntityKind,
        stableID: EntityID
    ) throws -> LegacyBridgeMapping {
        try writeTransaction { connection in
            if let existing = try SyncStore.loadLegacyMapping(connection, legacy: legacy) {
                guard existing.kind == kind, existing.stableID == stableID else {
                    throw SyncStoreError.legacyMappingConflict(legacy.rawValue)
                }
                return existing
            }
            let insert = try connection.prepare(
                """
                INSERT INTO legacy_bridge_mappings (legacy_identifier, entity_kind, stable_entity_id, created_at)
                VALUES (?, ?, ?, ?)
                """
            )
            try insert.bind(1, legacy.rawValue)
            try insert.bind(2, kind.rawValue)
            try insert.bind(3, stableID.canonical)
            try insert.bind(4, nowMillis())
            _ = try insert.step()
            return LegacyBridgeMapping(legacy: legacy, kind: kind, stableID: stableID)
        }
    }

    public func legacyMapping(
        for legacy: LegacyBridgeIdentifier
    ) throws -> LegacyBridgeMapping? {
        let connection = try openConnection()
        return try SyncStore.loadLegacyMapping(connection, legacy: legacy)
    }

    public func legacyMappings(for stableID: EntityID) throws -> [LegacyBridgeMapping] {
        let connection = try openConnection()
        let statement = try connection.prepare(
            """
            SELECT legacy_identifier, entity_kind, stable_entity_id
            FROM legacy_bridge_mappings
            WHERE stable_entity_id = ?
            ORDER BY legacy_identifier
            """
        )
        try statement.bind(1, stableID.canonical)
        var mappings: [LegacyBridgeMapping] = []
        while try statement.step() {
            guard let legacyText = statement.text(0),
                  let kindText = statement.text(1),
                  let stableText = statement.text(2),
                  let kind = SyncEntityKind(rawValue: kindText) else {
                throw SyncStoreError.schemaCorrupt("legacy mapping row is incomplete")
            }
            mappings.append(
                LegacyBridgeMapping(
                    legacy: try LegacyBridgeIdentifier(validating: legacyText),
                    kind: kind,
                    stableID: try EntityID(validating: stableText)
                )
            )
        }
        return mappings
    }

    // MARK: - Metadata

    public func metadata() throws -> SyncStoreMetadata {
        let connection = try openConnection()
        let createdMillis = try SyncStore.metaInt64(connection, key: "created_at")
        return SyncStoreMetadata(
            deviceID: deviceID,
            schemaVersion: try connection.userVersionValue(),
            createdAt: SyncStore.date(createdMillis),
            prunedThrough: try SyncStore.prunedThrough(connection),
            recordCount: try SyncStore.scalarInt(
                connection,
                sql: "SELECT COUNT(*) FROM records WHERE deleted = 0"
            ),
            commandCount: try SyncStore.scalarInt(
                connection,
                sql: "SELECT COUNT(*) FROM commands"
            ),
            snapshotCount: try SyncStore.scalarInt(
                connection,
                sql: "SELECT COUNT(*) FROM snapshots"
            ),
            openConflictCount: try SyncStore.scalarInt(
                connection,
                sql: "SELECT COUNT(*) FROM conflicts WHERE status = 'open'"
            ),
            stagingSnapshotImportCount: try SyncStore.scalarInt(
                connection,
                sql: "SELECT COUNT(*) FROM snapshot_imports WHERE state = 'staging'"
            ),
            establishedSubscriptionCount: try SyncStore.scalarInt(
                connection,
                sql: "SELECT COUNT(*) FROM sync_subscriptions WHERE established = 1"
            ),
            authorizedScopeCount: try SyncStore.scalarInt(
                connection,
                sql: "SELECT COUNT(*) FROM sync_scope_authorizations"
            ),
            incrementalReceiptCount: try SyncStore.scalarInt(
                connection,
                sql: "SELECT COUNT(*) FROM incremental_receipts"
            ),
            journalMode: try SyncStore.scalarText(connection, sql: "PRAGMA journal_mode"),
            foreignKeysEnabled: try SyncStore.scalarInt(
                connection,
                sql: "PRAGMA foreign_keys"
            ) == 1
        )
    }

    // MARK: - Internal plumbing

    private func openConnection() throws -> SQLiteConnection {
        guard !connection.isClosed else { throw SyncStoreError.closed }
        if configuration.enforceSecurePermissions, !sidecarsSecured {
            try SyncStore.secureDatabaseFiles(path: connection.path)
            sidecarsSecured = true
        }
        return connection
    }

    private func writeTransaction<T>(
        _ body: (SQLiteConnection) throws -> T
    ) throws -> T {
        let connection = try openConnection()
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let value = try body(connection)
            try connection.execute("COMMIT")
            return value
        } catch {
            _ = try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func readTransaction<T>(
        _ body: (SQLiteConnection) throws -> T
    ) throws -> T {
        let connection = try openConnection()
        try connection.execute("BEGIN DEFERRED")
        do {
            let value = try body(connection)
            try connection.execute("COMMIT")
            return value
        } catch {
            _ = try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func nowMillis() -> Int64 {
        SyncStore.millis(clock())
    }

    private func validatedPageSize(_ requested: Int?) throws -> Int {
        let size = requested ?? configuration.maxPageSize
        guard size >= 1, size <= configuration.maxPageSize else {
            throw SyncStoreError.invalidPageSize(size)
        }
        return size
    }

    /// Bounds record count, structural complexity and canonical payload bytes
    /// before the transaction, serialization or hashing work begins. A page or
    /// batch that exceeds the configured envelope is refused as a whole.
    private func validateBatch(_ records: [SyncRecord]) throws {
        guard records.count <= configuration.maxBatchRecords else {
            throw SyncStoreError.batchTooLarge(limit: configuration.maxBatchRecords)
        }
        var totalBytes = 0
        for record in records {
            try record.validateShape()
            let remaining = configuration.maxBatchBytes - totalBytes
            guard remaining >= 1 else {
                throw SyncStoreError.batchBytesTooLarge(limit: configuration.maxBatchBytes)
            }
            let payloadBytes = record.payload.canonicalByteCount(upTo: remaining)
            guard payloadBytes <= remaining else {
                throw SyncStoreError.batchBytesTooLarge(limit: configuration.maxBatchBytes)
            }
            totalBytes += payloadBytes
        }
    }

    private static let allowedTransitions: [CommandState: Set<CommandState>] = [
        .accepted: [.started, .failed, .cancelled],
        .started: [.completed, .failed, .cancelled, .outcomeUnknown],
        .outcomeUnknown: [.completed, .failed, .cancelled]
    ]

    /// First-open identity is decided by one atomic INSERT OR IGNORE followed
    /// by a read in the same IMMEDIATE transaction. Two devices opening a new
    /// file therefore cannot both believe they own it: exactly one row wins and
    /// the loser sees the winner's identity and fails.
    static func ensureIdentity(
        _ connection: SQLiteConnection,
        deviceID: DeviceID,
        nowMillis: Int64
    ) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let insert = try connection.prepare(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('device_id', ?)"
            )
            try insert.bind(1, deviceID.canonical)
            _ = try insert.step()

            let select = try connection.prepare(
                "SELECT value FROM meta WHERE key = 'device_id'"
            )
            guard try select.step(), let existing = select.text(0), !existing.isEmpty else {
                throw SyncStoreError.schemaCorrupt("device identity row is missing")
            }
            guard existing == deviceID.canonical else {
                throw SyncStoreError.deviceIdentityMismatch(
                    expected: deviceID.canonical,
                    found: existing
                )
            }

            let created = try connection.prepare(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('created_at', ?)"
            )
            try created.bind(1, String(nowMillis))
            _ = try created.step()
            let pruned = try connection.prepare(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('changes_pruned_through', '0')"
            )
            _ = try pruned.step()
            try connection.execute("COMMIT")
        } catch {
            _ = try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private static func prepareSecureDirectory(forDatabasePath path: String) throws {
        guard !path.isEmpty, path != ":memory:" else {
            throw SyncStoreError.unsafeDatabasePath(path)
        }
        let fileManager = FileManager.default
        let databaseURL = URL(fileURLWithPath: path)
        let directoryURL = databaseURL.deletingLastPathComponent()
        let directory = directoryURL.path

        if fileManager.fileExists(atPath: path) {
            let values = try databaseURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values.isSymbolicLink == true || values.isRegularFile != true {
                throw SyncStoreError.unsafeDatabasePath(path)
            }
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw SyncStoreError.unsafeDatabasePath(directory)
            }
            let values = try directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw SyncStoreError.unsafeDatabasePath(directory)
            }
            let attributes = try fileManager.attributesOfItem(atPath: directory)
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            guard permissions & 0o077 == 0 else {
                throw SyncStoreError.insecureDatabaseDirectory(path: directory)
            }
        } else {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory
            )
        }
    }

    static func secureDatabaseFiles(path: String) throws {
        let fileManager = FileManager.default
        for candidate in [path, path + "-wal", path + "-shm"] {
            guard fileManager.fileExists(atPath: candidate) else { continue }
            let url = URL(fileURLWithPath: candidate)
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw SyncStoreError.unsafeDatabasePath(candidate)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: candidate
            )
        }
    }

    private static func requireCurrentEpoch(
        _ connection: SQLiteConnection,
        command: SyncCommand
    ) throws {
        guard let runID = command.runID else { return }
        let head = try loadExecutionHead(connection, runID: runID)
        if let head, let taskID = command.taskID, head.taskID != taskID {
            throw SyncStoreError.executionTaskMismatch(
                runID,
                expected: head.taskID,
                received: taskID
            )
        }
        guard let epoch = command.executionEpoch else {
            if command.kind.requiresExecutionEpoch, head == nil {
                throw SyncStoreError.executionHeadNotEstablished(runID)
            }
            return
        }
        guard let head else {
            throw SyncStoreError.executionEpochNotEstablished(runID, epoch)
        }
        guard head.epoch == epoch else {
            if epoch < head.epoch {
                throw SyncStoreError.staleExecutionEpoch(
                    runID,
                    epoch,
                    current: head.epoch
                )
            }
            throw SyncStoreError.executionEpochNotEstablished(runID, epoch)
        }
    }

    /// Execution entry binds the authenticated caller explicitly. Starting a
    /// command checks the head task/epoch, the current owner device, the
    /// expected record revision and the local store identity in the same write
    /// transaction that changes `accepted` to `started`.
    private static func requireExecutionStartBinding(
        _ connection: SQLiteConnection,
        storeDeviceID: DeviceID,
        command: SyncCommand,
        authenticatedDeviceID: DeviceID
    ) throws {
        guard authenticatedDeviceID == storeDeviceID else {
            throw SyncStoreError.executionPrincipalMismatch(
                expected: storeDeviceID,
                authenticated: authenticatedDeviceID
            )
        }
        if let runID = command.runID {
            guard let head = try loadExecutionHead(connection, runID: runID) else {
                throw SyncStoreError.executionHeadNotEstablished(runID)
            }
            if let taskID = command.taskID, head.taskID != taskID {
                throw SyncStoreError.executionTaskMismatch(
                    runID,
                    expected: head.taskID,
                    received: taskID
                )
            }
            guard let epoch = command.executionEpoch else {
                throw SyncStoreError.missingExecutionEpoch(command.kind)
            }
            guard head.epoch == epoch else {
                if epoch < head.epoch {
                    throw SyncStoreError.staleExecutionEpoch(
                        runID,
                        epoch,
                        current: head.epoch
                    )
                }
                throw SyncStoreError.executionEpochNotEstablished(runID, epoch)
            }
            guard head.ownerDeviceID == authenticatedDeviceID else {
                throw SyncStoreError.executionOwnerMismatch(
                    runID,
                    owner: head.ownerDeviceID,
                    authenticated: authenticatedDeviceID
                )
            }
        }
        if let expected = command.expectedRevision {
            guard let key = command.targetKey else {
                throw SyncStoreError.invalidCommand("expectedRevision requires a target record")
            }
            let row = try loadRecordRow(
                connection,
                kind: key.kind,
                entityID: key.entityID,
                maxPayloadBytes: maximumReadBytes
            )
            guard row?.record.revision == expected else {
                throw SyncStoreError.expectedRevisionMismatch(
                    key,
                    expected: expected,
                    current: row?.record.revision
                )
            }
            if let commandTask = command.taskID,
               row?.record.taskID != commandTask {
                throw SyncStoreError.targetTaskMismatch(
                    key,
                    expected: commandTask,
                    found: row?.record.taskID
                )
            }
            if let commandWorkspace = command.workspaceID,
               row?.record.workspaceID != commandWorkspace {
                throw SyncStoreError.targetWorkspaceMismatch(
                    key,
                    expected: commandWorkspace,
                    found: row?.record.workspaceID
                )
            }
        }
    }

    private static func canonicalBytes(_ payload: JSONValue, limit: Int) throws -> [UInt8] {
        let bytes = payload.canonicalUTF8
        guard bytes.count <= limit else {
            throw SyncStoreError.payloadTooLarge(limit: limit)
        }
        return bytes
    }

    private static func applyRecords(
        _ connection: SQLiteConnection,
        peerDeviceID: DeviceID,
        records: [SyncRecord],
        observedCursor: ChangeCursor,
        maxWritePayloadBytes: Int,
        atMillis now: Int64
    ) throws -> (applied: [RecordKey], unchanged: [RecordKey], conflicts: [RecordConflict]) {
        var applied: [RecordKey] = []
        var unchanged: [RecordKey] = []
        var conflicts: [RecordConflict] = []

        for record in records {
            try record.validateShape()
            guard record.payload.canonicalByteCount(upTo: maxWritePayloadBytes)
                <= maxWritePayloadBytes else {
                throw SyncStoreError.payloadTooLarge(limit: maxWritePayloadBytes)
            }
            let payloadBytes = try canonicalBytes(record.payload, limit: maxWritePayloadBytes)
            let digest = ContentDigest.compute(payloadBytes)
            let key = RecordKey(kind: record.kind, entityID: record.entityID)

            if let existing = try loadRecordRow(
                connection,
                kind: record.kind,
                entityID: record.entityID,
                maxPayloadBytes: maximumReadBytes
            ) {
                try requireMatchingScope(existing: existing.record, incoming: record)
                if existing.record.revision == record.revision {
                    if sameContent(existing, record: record, digest: digest) {
                        unchanged.append(key)
                        continue
                    }
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .revisionPayloadMismatch,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
                if existing.record.revision > record.revision {
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .staleRemoteRevision,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
                if existing.localDirty,
                   !sameContent(existing, record: record, digest: digest) {
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .localUnsyncedEdit,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
                // A higher revision is only a fast-forward when the writer
                // observed the exact row we currently hold. Comparing revision
                // numbers alone is not causal and loses other-device branches.
                guard let baseRevision = record.baseRevision,
                      let baseDigest = record.baseDigest else {
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .missingBaseRevision,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
                guard baseRevision == existing.record.revision,
                      baseDigest == existing.digest else {
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .concurrentDivergence,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
            }

            try upsertRecord(
                connection,
                record: record,
                digest: digest,
                localDirty: false,
                atMillis: now
            )
            _ = try appendChange(
                connection,
                record: record,
                digest: digest,
                type: record.deleted ? .delete : .upsert,
                atMillis: now
            )
            applied.append(key)
        }
        return (applied, unchanged, conflicts)
    }

    /// Persists both versions of a refused incoming record. Replaying the same
    /// batch reuses the open conflict instead of creating unbounded duplicates.
    private static func persistConflict(
        _ connection: SQLiteConnection,
        peerDeviceID: DeviceID,
        reason: ConflictReason,
        local: RecordRow,
        incoming: SyncRecord,
        incomingDigest: ContentDigest,
        observedCursor: ChangeCursor,
        atMillis now: Int64
    ) throws -> RecordConflict {
        let lookup = try connection.prepare(
            """
            SELECT conflict_id FROM conflicts
            WHERE peer_device_id = ? AND entity_kind = ? AND entity_id = ?
              AND status = 'open' AND reason = ?
              AND local_revision = ? AND incoming_revision = ?
              AND local_payload_digest = ? AND incoming_payload_digest = ?
            ORDER BY created_at DESC
            """
        )
        try lookup.bind(1, peerDeviceID.canonical)
        try lookup.bind(2, local.record.kind.rawValue)
        try lookup.bind(3, local.record.entityID.canonical)
        try lookup.bind(4, reason.rawValue)
        try lookup.bind(5, local.record.revision.rawValue)
        try lookup.bind(6, incoming.revision.rawValue)
        try lookup.bind(7, local.digest.description)
        try lookup.bind(8, incomingDigest.description)
        var existingID: ConflictID?
        while try lookup.step() {
            guard let text = lookup.text(0) else {
                throw SyncStoreError.schemaCorrupt("conflict row has no identity")
            }
            let candidateID = try ConflictID(validating: text)
            guard let candidate = try loadConflict(connection, id: candidateID) else {
                throw SyncStoreError.schemaCorrupt("conflict disappeared during transaction")
            }
            if candidate.local == local.record, candidate.incoming == incoming {
                existingID = candidateID
                break
            }
        }
        let conflictID = existingID ?? ConflictID()
        guard existingID == nil else {
            return RecordConflict(
                conflictID: conflictID,
                key: RecordKey(kind: local.record.kind, entityID: local.record.entityID),
                incomingRevision: incoming.revision,
                localRevision: local.record.revision,
                reason: reason
            )
        }

        let statement = try connection.prepare(
            """
            INSERT INTO conflicts (
                conflict_id, peer_device_id, entity_kind, entity_id, task_id,
                workspace_id, incoming_task_id, incoming_workspace_id, reason,
                local_revision, local_origin_device_id, local_base_revision,
                local_base_digest, local_payload_digest, local_payload,
                local_deleted, incoming_revision, incoming_origin_device_id,
                incoming_base_revision, incoming_base_digest,
                incoming_payload_digest, incoming_payload, incoming_deleted,
                observed_cursor, status, resolution, created_at, resolved_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'open', NULL, ?, NULL)
            """
        )
        try statement.bind(1, conflictID.canonical)
        try statement.bind(2, peerDeviceID.canonical)
        try statement.bind(3, local.record.kind.rawValue)
        try statement.bind(4, local.record.entityID.canonical)
        try bindOptionalText(statement, 5, local.record.taskID?.canonical)
        try bindOptionalText(statement, 6, local.record.workspaceID?.canonical)
        try bindOptionalText(statement, 7, incoming.taskID?.canonical)
        try bindOptionalText(statement, 8, incoming.workspaceID?.canonical)
        try statement.bind(9, reason.rawValue)
        try statement.bind(10, local.record.revision.rawValue)
        try statement.bind(11, local.record.originDeviceID.canonical)
        try bindOptionalInt64(statement, 12, local.record.baseRevision?.rawValue)
        try bindOptionalText(statement, 13, local.record.baseDigest?.description)
        try statement.bind(14, local.digest.description)
        try statement.bind(15, local.record.payload.canonicalUTF8)
        try statement.bind(16, local.record.deleted ? Int64(1) : Int64(0))
        try statement.bind(17, incoming.revision.rawValue)
        try statement.bind(18, incoming.originDeviceID.canonical)
        try bindOptionalInt64(statement, 19, incoming.baseRevision?.rawValue)
        try bindOptionalText(statement, 20, incoming.baseDigest?.description)
        try statement.bind(21, incomingDigest.description)
        try statement.bind(22, incoming.payload.canonicalUTF8)
        try statement.bind(23, incoming.deleted ? Int64(1) : Int64(0))
        try statement.bind(24, observedCursor.rawValue)
        try statement.bind(25, now)
        _ = try statement.step()
        return RecordConflict(
            conflictID: conflictID,
            key: RecordKey(kind: local.record.kind, entityID: local.record.entityID),
            incomingRevision: incoming.revision,
            localRevision: local.record.revision,
            reason: reason
        )
    }

    private static func record(
        _ record: SyncRecord,
        baseRevision: Revision?,
        baseDigest: ContentDigest?
    ) -> SyncRecord {
        SyncRecord(
            kind: record.kind,
            entityID: record.entityID,
            taskID: record.taskID,
            workspaceID: record.workspaceID,
            revision: record.revision,
            baseRevision: baseRevision,
            baseDigest: baseDigest,
            originDeviceID: record.originDeviceID,
            payload: record.payload,
            deleted: record.deleted
        )
    }

    private static func sameContent(
        _ existing: RecordRow,
        record: SyncRecord,
        digest: ContentDigest
    ) -> Bool {
        existing.digest == digest
            && existing.record.deleted == record.deleted
            && existing.record.taskID == record.taskID
            && existing.record.workspaceID == record.workspaceID
    }

    private static func upsertRecord(
        _ connection: SQLiteConnection,
        record: SyncRecord,
        digest: ContentDigest,
        localDirty: Bool,
        atMillis now: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO records (
                entity_kind, entity_id, task_id, workspace_id, revision,
                base_revision, base_digest, origin_device_id, payload,
                payload_digest, deleted, local_dirty, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(entity_kind, entity_id) DO UPDATE SET
                task_id = excluded.task_id,
                workspace_id = excluded.workspace_id,
                revision = excluded.revision,
                base_revision = excluded.base_revision,
                base_digest = excluded.base_digest,
                origin_device_id = excluded.origin_device_id,
                payload = excluded.payload,
                payload_digest = excluded.payload_digest,
                deleted = excluded.deleted,
                local_dirty = excluded.local_dirty,
                updated_at = excluded.updated_at
            """
        )
        try statement.bind(1, record.kind.rawValue)
        try statement.bind(2, record.entityID.canonical)
        try bindOptionalText(statement, 3, record.taskID?.canonical)
        try bindOptionalText(statement, 4, record.workspaceID?.canonical)
        try statement.bind(5, record.revision.rawValue)
        try bindOptionalInt64(statement, 6, record.baseRevision?.rawValue)
        try bindOptionalText(statement, 7, record.baseDigest?.description)
        try statement.bind(8, record.originDeviceID.canonical)
        try statement.bind(9, record.payload.canonicalUTF8)
        try statement.bind(10, digest.description)
        try statement.bind(11, record.deleted ? Int64(1) : Int64(0))
        try statement.bind(12, localDirty ? Int64(1) : Int64(0))
        try statement.bind(13, now)
        try statement.bind(14, now)
        _ = try statement.step()
    }

    private static func appendChange(
        _ connection: SQLiteConnection,
        record: SyncRecord,
        digest: ContentDigest,
        type: ChangeType,
        atMillis now: Int64
    ) throws -> ChangeCursor {
        let statement = try connection.prepare(
            """
            INSERT INTO changes (
                entity_kind, entity_id, task_id, workspace_id, revision,
                base_revision, base_digest, change_type, origin_device_id,
                payload, payload_digest, recorded_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(1, record.kind.rawValue)
        try statement.bind(2, record.entityID.canonical)
        try bindOptionalText(statement, 3, record.taskID?.canonical)
        try bindOptionalText(statement, 4, record.workspaceID?.canonical)
        try statement.bind(5, record.revision.rawValue)
        try bindOptionalInt64(statement, 6, record.baseRevision?.rawValue)
        try bindOptionalText(statement, 7, record.baseDigest?.description)
        try statement.bind(8, type.rawValue)
        try statement.bind(9, record.originDeviceID.canonical)
        try statement.bind(10, record.payload.canonicalUTF8)
        try statement.bind(11, digest.description)
        try statement.bind(12, now)
        _ = try statement.step()
        return ChangeCursor(unchecked: connection.lastInsertRowID)
    }

    private struct RecordRow {
        let record: SyncRecord
        let digest: ContentDigest
        let localDirty: Bool
        let updatedAtMillis: Int64
    }

    private static func loadRecordRow(
        _ connection: SQLiteConnection,
        kind: SyncEntityKind,
        entityID: EntityID,
        maxPayloadBytes: Int
    ) throws -> RecordRow? {
        let statement = try connection.prepare(
            """
            SELECT entity_kind, entity_id, task_id, workspace_id, revision,
                   base_revision, base_digest, origin_device_id, payload,
                   payload_digest, deleted, local_dirty, updated_at
            FROM records
            WHERE entity_kind = ? AND entity_id = ?
            """
        )
        try statement.bind(1, kind.rawValue)
        try statement.bind(2, entityID.canonical)
        guard try statement.step() else { return nil }
        return try decodeRecordRow(statement, maxPayloadBytes: maxPayloadBytes)
    }

    private static func decodeRecordRow(
        _ statement: SQLiteStatement,
        maxPayloadBytes: Int
    ) throws -> RecordRow {
        guard let kindText = statement.text(0),
              let kind = SyncEntityKind(rawValue: kindText),
              let entityText = statement.text(1),
              let revisionValue = statement.int64(4),
              let originText = statement.text(7),
              let payload = statement.blob(8),
              let digestText = statement.text(9) else {
            throw SyncStoreError.schemaCorrupt("record row is incomplete")
        }
        let taskID: TaskID? = try decodeOptionalID(statement.text(2))
        let workspaceID: WorkspaceID? = try decodeOptionalID(statement.text(3))
        let baseRevision = try statement.int64(5).map { try Revision($0) }
        let baseDigest = try statement.text(6).map { try ContentDigest(validating: $0) }
        let deleted = (statement.int64(10) ?? 0) != 0
        let localDirty = (statement.int64(11) ?? 0) != 0
        return RecordRow(
            record: SyncRecord(
                kind: kind,
                entityID: try EntityID(validating: entityText),
                taskID: taskID,
                workspaceID: workspaceID,
                revision: try Revision(revisionValue),
                baseRevision: baseRevision,
                baseDigest: baseDigest,
                originDeviceID: try DeviceID(validating: originText),
                payload: try JSONValue.parse(utf8: payload, maxBytes: maxPayloadBytes),
                deleted: deleted
            ),
            digest: try ContentDigest(validating: digestText),
            localDirty: localDirty,
            updatedAtMillis: statement.int64(12) ?? 0
        )
    }

    private static func readSnapshotPageRows(
        _ connection: SQLiteConnection,
        snapshotID: SnapshotID,
        start: Int64,
        pageSize: Int,
        maxPageBytes: Int
    ) throws -> (records: [SyncRecord], positions: [Int64], hasMore: Bool) {
        let statement = try connection.prepare(
            """
            SELECT position, entity_kind, entity_id, task_id, workspace_id,
                   revision, base_revision, base_digest, origin_device_id,
                   payload, payload_digest, deleted, length(payload)
            FROM snapshot_entries
            WHERE snapshot_id = ? AND position > ?
            ORDER BY position
            LIMIT ?
            """
        )
        try statement.bind(1, snapshotID.canonical)
        try statement.bind(2, start)
        try statement.bind(3, Int64(pageSize + 1))
        var records: [SyncRecord] = []
        var positions: [Int64] = []
        var usedBytes = 0
        var stoppedByBudget = false
        while try statement.step() {
            guard let position = statement.int64(0) else {
                throw SyncStoreError.schemaCorrupt("snapshot entry has no position")
            }
            let payloadBytes = Int(statement.int64(12) ?? 0)
            let remaining = maxPageBytes - usedBytes
            if !records.isEmpty, payloadBytes > remaining {
                stoppedByBudget = true
                break
            }
            records.append(
                try decodeSnapshotRecord(
                    statement,
                    maxPayloadBytes: maximumReadBytes
                )
            )
            positions.append(position)
            usedBytes += payloadBytes
        }
        return (records, positions, stoppedByBudget)
    }

    private static func readSnapshotRange(
        _ connection: SQLiteConnection,
        snapshotID: SnapshotID,
        firstPosition: Int64,
        lastPosition: Int64
    ) throws -> (records: [SyncRecord], positions: [Int64]) {
        let statement = try connection.prepare(
            """
            SELECT position, entity_kind, entity_id, task_id, workspace_id,
                   revision, base_revision, base_digest, origin_device_id,
                   payload, payload_digest, deleted, length(payload)
            FROM snapshot_entries
            WHERE snapshot_id = ? AND position >= ? AND position <= ?
            ORDER BY position
            LIMIT ?
            """
        )
        try statement.bind(1, snapshotID.canonical)
        try statement.bind(2, firstPosition)
        try statement.bind(3, lastPosition)
        try statement.bind(4, max(Int64(1), lastPosition - firstPosition + 2))
        var records: [SyncRecord] = []
        var positions: [Int64] = []
        while try statement.step() {
            guard let position = statement.int64(0) else {
                throw SyncStoreError.schemaCorrupt("snapshot entry has no position")
            }
            records.append(
                try decodeSnapshotRecord(statement, maxPayloadBytes: maximumReadBytes)
            )
            positions.append(position)
        }
        return (records, positions)
    }

    private struct SnapshotImportRow {
        let peerDeviceID: DeviceID
        let snapshotID: SnapshotID
        let manifest: SnapshotManifest
        let subscriptionVersion: Int64
        let state: SnapshotImportState
        let nextPageIndex: Int
        let receivedPageCount: Int
        let receivedEntryCount: Int
        let stagedBytes: Int
        let createdAtMillis: Int64
        let expiresAtMillis: Int64
        let committedAtMillis: Int64?
        let receipt: SnapshotImportResult?
    }

    private struct StagedPageRow {
        let pageIndex: Int
        let firstPosition: Int64
        let lastPosition: Int64
        let entryCount: Int
        let byteCount: Int
        let digest: ContentDigest
    }

    private static let snapshotImportSelectColumns = """
        peer_device_id, snapshot_id, scope_kind, scope_id, subscription_version,
        base_cursor, manifest_digest, manifest_blob, entry_count, record_count,
        tombstone_count, page_count, next_page_index, received_page_count,
        received_entry_count, staged_bytes, state, created_at, expires_at,
        committed_at, receipt
        """

    private static func loadSnapshotImport(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        snapshotID: SnapshotID
    ) throws -> SnapshotImportRow? {
        let statement = try connection.prepare(
            "SELECT \(snapshotImportSelectColumns) FROM snapshot_imports WHERE peer_device_id = ? AND snapshot_id = ?"
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, snapshotID.canonical)
        guard try statement.step() else { return nil }
        return try decodeSnapshotImport(statement, expectedPeer: peer, expectedSnapshot: snapshotID)
    }

    private static func loadActiveSnapshotImport(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope
    ) throws -> SnapshotImportRow? {
        let statement = try connection.prepare(
            """
            SELECT \(snapshotImportSelectColumns) FROM snapshot_imports
            WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
              AND state = 'staging'
            LIMIT 1
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, scope.kind)
        try statement.bind(3, scope.identifier ?? "")
        guard try statement.step() else { return nil }
        guard let snapshotText = statement.text(1) else {
            throw SyncStoreError.schemaCorrupt("staged snapshot has no identity")
        }
        return try decodeSnapshotImport(
            statement,
            expectedPeer: peer,
            expectedSnapshot: try SnapshotID(validating: snapshotText)
        )
    }

    private static func decodeSnapshotImport(
        _ statement: SQLiteStatement,
        expectedPeer: DeviceID,
        expectedSnapshot: SnapshotID
    ) throws -> SnapshotImportRow {
        guard let peerText = statement.text(0),
              let snapshotText = statement.text(1),
              let scopeKind = statement.text(2),
              let scopeID = statement.text(3),
              let version = statement.int64(4),
              let baseCursorValue = statement.int64(5),
              let manifestDigestText = statement.text(6),
              let manifestBlob = statement.blob(7),
              let entryCount = statement.int64(8),
              let recordCount = statement.int64(9),
              let tombstoneCount = statement.int64(10),
              let pageCount = statement.int64(11),
              let nextPageIndex = statement.int64(12),
              let receivedPageCount = statement.int64(13),
              let receivedEntryCount = statement.int64(14),
              let stagedBytes = statement.int64(15),
              let stateText = statement.text(16),
              let state = SnapshotImportState(rawValue: stateText),
              let createdAt = statement.int64(17),
              let expiresAt = statement.int64(18) else {
            throw SyncStoreError.schemaCorrupt("staged snapshot row is incomplete")
        }
        let peer = try DeviceID(validating: peerText)
        let snapshotID = try SnapshotID(validating: snapshotText)
        guard peer == expectedPeer, snapshotID == expectedSnapshot else {
            throw SyncStoreError.schemaCorrupt("staged snapshot identity does not match its key")
        }
        let manifestValue = try JSONValue.parse(
            utf8: manifestBlob,
            maxBytes: maximumManifestBytes
        )
        let manifest = try SnapshotManifest(wireValue: manifestValue)
        guard manifest.digest.description == manifestDigestText,
              manifest.subscriptionVersion == version,
              manifest.snapshotID == snapshotID,
              manifest.originDeviceID == peer,
              manifest.baseCursor.rawValue == baseCursorValue,
              manifest.scope.kind == scopeKind,
              (manifest.scope.identifier ?? "") == scopeID,
              manifest.entryCount == Int(entryCount),
              manifest.recordCount == Int(recordCount),
              manifest.tombstoneCount == Int(tombstoneCount),
              manifest.pageCount == Int(pageCount) else {
            throw SyncStoreError.snapshotImportReceiptCorrupt
        }
        var receipt: SnapshotImportResult?
        if let receiptBlob = statement.blob(20) {
            let value = try JSONValue.parse(utf8: receiptBlob, maxBytes: maximumReadBytes)
            receipt = try SnapshotImportResult.decode(wireValue: value, isDuplicate: false)
        }
        return SnapshotImportRow(
            peerDeviceID: peer,
            snapshotID: snapshotID,
            manifest: manifest,
            subscriptionVersion: version,
            state: state,
            nextPageIndex: Int(nextPageIndex),
            receivedPageCount: Int(receivedPageCount),
            receivedEntryCount: Int(receivedEntryCount),
            stagedBytes: Int(stagedBytes),
            createdAtMillis: createdAt,
            expiresAtMillis: expiresAt,
            committedAtMillis: statement.int64(19),
            receipt: receipt
        )
    }

    private static func progress(from row: SnapshotImportRow) -> SnapshotImportProgress {
        SnapshotImportProgress(
            peerDeviceID: row.peerDeviceID,
            snapshotID: row.snapshotID,
            scope: row.manifest.scope,
            subscriptionVersion: row.subscriptionVersion,
            baseCursor: row.manifest.baseCursor,
            pageCount: row.manifest.pageCount,
            receivedPageCount: row.receivedPageCount,
            receivedEntryCount: row.receivedEntryCount,
            stagedBytes: row.stagedBytes,
            state: row.state,
            expiresAt: date(row.expiresAtMillis),
            committedResult: row.receipt
        )
    }

    private static func loadSubscription(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope
    ) throws -> SyncSubscription? {
        let statement = try connection.prepare(
            """
            SELECT peer_device_id, scope_kind, scope_id, subscription_version,
                   applied_cursor, established, last_snapshot_id, updated_at
            FROM sync_subscriptions
            WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, scope.kind)
        try statement.bind(3, scope.identifier ?? "")
        guard try statement.step() else { return nil }
        return try decodeSubscription(statement)
    }

    private static func decodeSubscription(
        _ statement: SQLiteStatement
    ) throws -> SyncSubscription {
        guard let peerText = statement.text(0),
              let scopeKind = statement.text(1),
              let scopeID = statement.text(2),
              let version = statement.int64(3),
              let cursorValue = statement.int64(4),
              let established = statement.int64(5),
              let updatedAt = statement.int64(7) else {
            throw SyncStoreError.schemaCorrupt("subscription row is incomplete")
        }
        let lastSnapshotID: SnapshotID?
        if let text = statement.text(6) {
            lastSnapshotID = try SnapshotID(validating: text)
        } else {
            lastSnapshotID = nil
        }
        return SyncSubscription(
            peerDeviceID: try DeviceID(validating: peerText),
            scope: try SnapshotScope.decode(
                kind: scopeKind,
                identifier: scopeKind == "all" ? nil : scopeID
            ),
            version: version,
            appliedCursor: ChangeCursor(unchecked: max(0, cursorValue)),
            established: established == 1,
            lastSnapshotID: lastSnapshotID,
            updatedAt: date(updatedAt)
        )
    }

    private static func insertSubscription(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope,
        version: Int64,
        atMillis now: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO sync_subscriptions (
                peer_device_id, scope_kind, scope_id, subscription_version,
                applied_cursor, established, last_snapshot_id, updated_at
            ) VALUES (?, ?, ?, ?, 0, 0, NULL, ?)
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, scope.kind)
        try statement.bind(3, scope.identifier ?? "")
        try statement.bind(4, version)
        try statement.bind(5, now)
        _ = try statement.step()
    }

    private static func setSubscriptionCursor(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope,
        cursor: ChangeCursor,
        atMillis now: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE sync_subscriptions SET applied_cursor = ?, updated_at = ?
            WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
            """
        )
        try statement.bind(1, cursor.rawValue)
        try statement.bind(2, now)
        try statement.bind(3, peer.canonical)
        try statement.bind(4, scope.kind)
        try statement.bind(5, scope.identifier ?? "")
        _ = try statement.step()
        guard connection.changedRowCount == 1 else {
            throw SyncStoreError.subscriptionNotEstablished(peer, scope)
        }
    }

    private static func establishSubscriptionCursor(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope,
        version: Int64,
        cursor: ChangeCursor,
        lastSnapshotID: SnapshotID,
        atMillis now: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE sync_subscriptions SET
                applied_cursor = ?, established = 1, last_snapshot_id = ?,
                updated_at = ?
            WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
              AND subscription_version = ?
            """
        )
        try statement.bind(1, cursor.rawValue)
        try statement.bind(2, lastSnapshotID.canonical)
        try statement.bind(3, now)
        try statement.bind(4, peer.canonical)
        try statement.bind(5, scope.kind)
        try statement.bind(6, scope.identifier ?? "")
        try statement.bind(7, version)
        _ = try statement.step()
        guard connection.changedRowCount == 1 else {
            throw SyncStoreError.subscriptionVersionMismatch(
                peer,
                scope,
                expected: version,
                found: version
            )
        }
    }

    private static func loadScopeAuthorization(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope
    ) throws -> ScopeAuthorization? {
        let statement = try connection.prepare(
            """
            SELECT peer_device_id, scope_kind, scope_id, granted_at, updated_at
            FROM sync_scope_authorizations
            WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, scope.kind)
        try statement.bind(3, scope.identifier ?? "")
        guard try statement.step() else { return nil }
        return try decodeScopeAuthorization(statement)
    }

    private static func decodeScopeAuthorization(
        _ statement: SQLiteStatement
    ) throws -> ScopeAuthorization {
        guard let peerText = statement.text(0),
              let scopeKind = statement.text(1),
              let grantedAt = statement.int64(3),
              let updatedAt = statement.int64(4) else {
            throw SyncStoreError.schemaCorrupt("scope authorization row is incomplete")
        }
        let scope = try SnapshotScope.decode(
            kind: scopeKind,
            identifier: scopeKind == "all" ? nil : statement.text(2)
        )
        return ScopeAuthorization(
            peerDeviceID: try DeviceID(validating: peerText),
            scope: scope,
            grantedAt: date(grantedAt),
            updatedAt: date(updatedAt)
        )
    }

    private struct IncrementalReceiptRow {
        let contentDigest: ContentDigest
        let result: IncrementalApplyResult
    }

    private static func loadIncrementalReceipt(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope,
        version: Int64,
        from: ChangeCursor,
        through: ChangeCursor,
        maxResultBytes: Int
    ) throws -> IncrementalReceiptRow? {
        let statement = try connection.prepare(
            """
            SELECT content_digest, result FROM incremental_receipts
            WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
              AND subscription_version = ? AND from_cursor = ?
              AND through_cursor = ?
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, scope.kind)
        try statement.bind(3, scope.identifier ?? "")
        try statement.bind(4, version)
        try statement.bind(5, from.rawValue)
        try statement.bind(6, through.rawValue)
        guard try statement.step() else { return nil }
        guard let digestText = statement.text(0),
              let resultBytes = statement.blob(1) else {
            throw SyncStoreError.incrementalReceiptCorrupt
        }
        let value = try JSONValue.parse(utf8: resultBytes, maxBytes: maxResultBytes)
        return IncrementalReceiptRow(
            contentDigest: try ContentDigest(validating: digestText),
            result: try IncrementalApplyResult.decode(wireValue: value, isDuplicate: false)
        )
    }

    private static func insertIncrementalReceipt(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope,
        version: Int64,
        from: ChangeCursor,
        through: ChangeCursor,
        contentDigest: ContentDigest,
        result: [UInt8],
        atMillis now: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO incremental_receipts (
                peer_device_id, scope_kind, scope_id, subscription_version,
                from_cursor, through_cursor, content_digest, applied_at, result
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, scope.kind)
        try statement.bind(3, scope.identifier ?? "")
        try statement.bind(4, version)
        try statement.bind(5, from.rawValue)
        try statement.bind(6, through.rawValue)
        try statement.bind(7, contentDigest.description)
        try statement.bind(8, now)
        try statement.bind(9, result)
        _ = try statement.step()
    }

    private static func pruneIncrementalReceipts(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope,
        version: Int64,
        keep: Int
    ) throws {
        guard keep >= 1 else { return }
        let statement = try connection.prepare(
            """
            DELETE FROM incremental_receipts
            WHERE receipt_id IN (
                SELECT receipt_id FROM incremental_receipts
                WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
                  AND subscription_version = ?
                ORDER BY receipt_id DESC
                LIMIT -1 OFFSET ?
            )
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, scope.kind)
        try statement.bind(3, scope.identifier ?? "")
        try statement.bind(4, version)
        try statement.bind(5, Int64(keep))
        _ = try statement.step()
    }

    /// Compare-and-swap on the exact expected starting cursor. The caller is
    /// already inside the write transaction and loaded the same subscription,
    /// so a zero update means another writer changed it or the row vanished.
    private static func advanceSubscriptionCursor(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        scope: SnapshotScope,
        version: Int64,
        from: ChangeCursor,
        through: ChangeCursor,
        atMillis now: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            UPDATE sync_subscriptions SET applied_cursor = ?, updated_at = ?
            WHERE peer_device_id = ? AND scope_kind = ? AND scope_id = ?
              AND subscription_version = ? AND established = 1
              AND applied_cursor = ?
            """
        )
        try statement.bind(1, through.rawValue)
        try statement.bind(2, now)
        try statement.bind(3, peer.canonical)
        try statement.bind(4, scope.kind)
        try statement.bind(5, scope.identifier ?? "")
        try statement.bind(6, version)
        try statement.bind(7, from.rawValue)
        _ = try statement.step()
        guard connection.changedRowCount == 1 else {
            throw SyncStoreError.incrementalCursorConflict(peer, scope)
        }
    }

    private static func stagingTotals(
        _ connection: SQLiteConnection
    ) throws -> (imports: Int, pages: Int, entries: Int, payloadBytes: Int) {
        let statement = try connection.prepare(
            """
            SELECT COUNT(*), COALESCE(SUM(received_page_count), 0),
                   COALESCE(SUM(received_entry_count), 0),
                   COALESCE(SUM(staged_bytes), 0)
            FROM snapshot_imports WHERE state = 'staging'
            """
        )
        guard try statement.step() else {
            throw SyncStoreError.schemaCorrupt("cannot count staged snapshots")
        }
        return (
            imports: Int(statement.int64(0) ?? 0),
            pages: Int(statement.int64(1) ?? 0),
            entries: Int(statement.int64(2) ?? 0),
            payloadBytes: Int(statement.int64(3) ?? 0)
        )
    }

    private static func purgeExpiredStagingImports(
        _ connection: SQLiteConnection,
        atMillis now: Int64
    ) throws -> Int {
        let statement = try connection.prepare(
            "DELETE FROM snapshot_imports WHERE state = 'staging' AND expires_at <= ?"
        )
        try statement.bind(1, now)
        _ = try statement.step()
        return connection.changedRowCount
    }

    private static func loadStagedPage(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        snapshotID: SnapshotID,
        pageIndex: Int
    ) throws -> StagedPageRow? {
        let statement = try connection.prepare(
            """
            SELECT page_index, first_position, last_position, entry_count,
                   byte_count, page_digest
            FROM snapshot_import_pages
            WHERE peer_device_id = ? AND snapshot_id = ? AND page_index = ?
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, snapshotID.canonical)
        try statement.bind(3, Int64(pageIndex))
        guard try statement.step() else { return nil }
        guard let storedIndex = statement.int64(0),
              let first = statement.int64(1),
              let last = statement.int64(2),
              let count = statement.int64(3),
              let bytes = statement.int64(4),
              let digestText = statement.text(5) else {
            throw SyncStoreError.schemaCorrupt("staged page row is incomplete")
        }
        return StagedPageRow(
            pageIndex: Int(storedIndex),
            firstPosition: first,
            lastPosition: last,
            entryCount: Int(count),
            byteCount: Int(bytes),
            digest: try ContentDigest(validating: digestText)
        )
    }

    private static func loadStagedPageRecords(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        snapshotID: SnapshotID,
        firstPosition: Int64,
        lastPosition: Int64
    ) throws -> (records: [SyncRecord], positions: [Int64]) {
        let statement = try connection.prepare(
            """
            SELECT position, entity_kind, entity_id, task_id, workspace_id,
                   revision, base_revision, base_digest, origin_device_id,
                   payload, payload_digest, deleted
            FROM snapshot_import_records
            WHERE peer_device_id = ? AND snapshot_id = ?
              AND position >= ? AND position <= ?
            ORDER BY position
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, snapshotID.canonical)
        try statement.bind(3, firstPosition)
        try statement.bind(4, lastPosition)
        var records: [SyncRecord] = []
        var positions: [Int64] = []
        while try statement.step() {
            guard let position = statement.int64(0),
                  let kindText = statement.text(1),
                  let kind = SyncEntityKind(rawValue: kindText),
                  let entityText = statement.text(2),
                  let revision = statement.int64(5),
                  let originText = statement.text(8),
                  let payload = statement.blob(9),
                  let digestText = statement.text(10) else {
                throw SyncStoreError.schemaCorrupt("staged record row is incomplete")
            }
            guard ContentDigest.compute(payload).description
                == (try ContentDigest(validating: digestText)).description else {
                throw SyncStoreError.schemaCorrupt("staged record payload digest does not match")
            }
            records.append(
                SyncRecord(
                    kind: kind,
                    entityID: try EntityID(validating: entityText),
                    taskID: try decodeOptionalID(statement.text(3)),
                    workspaceID: try decodeOptionalID(statement.text(4)),
                    revision: try Revision(revision),
                    baseRevision: try statement.int64(6).map { try Revision($0) },
                    baseDigest: try statement.text(7).map {
                        try ContentDigest(validating: $0)
                    },
                    originDeviceID: try DeviceID(validating: originText),
                    payload: try JSONValue.parse(
                        utf8: payload,
                        maxBytes: maximumReadBytes
                    ),
                    deleted: (statement.int64(11) ?? 0) != 0
                )
            )
            positions.append(position)
        }
        return (records, positions)
    }

    private static func verifyStagedPage(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        snapshotID: SnapshotID,
        page: SnapshotPageManifest,
        scope: SnapshotScope,
        maxPayloadBytes: Int
    ) throws -> (records: [SyncRecord], positions: [Int64]) {
        guard let pageRow = try loadStagedPage(
            connection,
            peer: peer,
            snapshotID: snapshotID,
            pageIndex: page.pageIndex
        ) else {
            throw SyncStoreError.snapshotPageConflict(
                peer,
                snapshotID,
                pageIndex: page.pageIndex
            )
        }
        guard pageRow.firstPosition == page.firstPosition,
              pageRow.lastPosition == page.lastPosition,
              pageRow.entryCount == page.entryCount,
              pageRow.byteCount == page.byteCount,
              pageRow.digest == page.digest else {
            throw SyncStoreError.snapshotPageConflict(
                peer,
                snapshotID,
                pageIndex: page.pageIndex
            )
        }
        let pageRead = try loadStagedPageRecords(
            connection,
            peer: peer,
            snapshotID: snapshotID,
            firstPosition: page.firstPosition,
            lastPosition: page.lastPosition
        )
        guard pageRead.records.count == page.entryCount,
              pageRead.positions.first == page.firstPosition,
              pageRead.positions.last == page.lastPosition,
              SnapshotDigest.pageDigest(pageRead.records) == page.digest else {
            throw SyncStoreError.snapshotPageConflict(
                peer,
                snapshotID,
                pageIndex: page.pageIndex
            )
        }
        var payloadBytes = 0
        var keys = Set<RecordKey>()
        for record in pageRead.records {
            try record.validateShape()
            guard scopeContains(record, scope: scope) else {
                throw SyncStoreError.snapshotScopeMismatch(
                    RecordKey(kind: record.kind, entityID: record.entityID),
                    scope
                )
            }
            let key = RecordKey(kind: record.kind, entityID: record.entityID)
            guard keys.insert(key).inserted else {
                throw SyncStoreError.snapshotDuplicateRecord(key)
            }
            let remaining = page.byteCount - payloadBytes
            guard remaining >= 0 else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "persisted page \(page.pageIndex) exceeds its declared bytes"
                )
            }
            let count = record.payload.canonicalByteCount(
                upTo: min(maxPayloadBytes, remaining)
            )
            guard count <= maxPayloadBytes, count <= remaining else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "persisted page \(page.pageIndex) record exceeds its declared bytes"
                )
            }
            payloadBytes += count
        }
        guard payloadBytes == page.byteCount else {
            throw SyncStoreError.snapshotManifestInvalid(
                "persisted page \(page.pageIndex) does not match its declared bytes"
            )
        }
        return pageRead
    }

    private static func stagedRecordExists(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        snapshotID: SnapshotID,
        key: RecordKey
    ) throws -> Bool {
        let statement = try connection.prepare(
            """
            SELECT 1 FROM snapshot_import_records
            WHERE peer_device_id = ? AND snapshot_id = ?
              AND entity_kind = ? AND entity_id = ?
            LIMIT 1
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, snapshotID.canonical)
        try statement.bind(3, key.kind.rawValue)
        try statement.bind(4, key.entityID.canonical)
        return try statement.step()
    }

    private static func stagedRecordCount(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        snapshotID: SnapshotID
    ) throws -> Int {
        let statement = try connection.prepare(
            "SELECT COUNT(*) FROM snapshot_import_records WHERE peer_device_id = ? AND snapshot_id = ?"
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, snapshotID.canonical)
        guard try statement.step() else { return 0 }
        return Int(statement.int64(0) ?? 0)
    }

    private static func localRecordKeys(
        _ connection: SQLiteConnection,
        scope: SnapshotScope,
        limit: Int
    ) throws -> [RecordKey] {
        let filter: String
        switch scope {
        case .all:
            filter = ""
        case .task:
            filter = " WHERE task_id = ?"
        case .workspace:
            filter = " WHERE workspace_id = ?"
        }
        let statement = try connection.prepare(
            "SELECT entity_kind, entity_id FROM records\(filter) ORDER BY entity_kind, entity_id"
        )
        if let identifier = scope.identifier {
            try statement.bind(1, identifier)
        }
        var keys: [RecordKey] = []
        while try statement.step() {
            guard keys.count < limit else {
                throw SyncStoreError.snapshotTooLarge("local reconciliation exceeds \(limit) records")
            }
            guard let kindText = statement.text(0),
                  let kind = SyncEntityKind(rawValue: kindText),
                  let entityText = statement.text(1) else {
                throw SyncStoreError.schemaCorrupt("local record key is incomplete")
            }
            keys.append(
                RecordKey(
                    kind: kind,
                    entityID: try EntityID(validating: entityText)
                )
            )
        }
        return keys
    }

    private static func scopeContains(
        _ record: SyncRecord,
        scope: SnapshotScope
    ) -> Bool {
        switch scope {
        case .all:
            return true
        case .task(let taskID):
            return record.taskID == taskID
        case .workspace(let workspaceID):
            return record.workspaceID == workspaceID
        }
    }

    private static func requireMatchingScope(existing: SyncRecord, incoming: SyncRecord) throws {
        guard existing.taskID == incoming.taskID,
              existing.workspaceID == incoming.workspaceID else {
            throw SyncStoreError.invalidRecord("existing entity cannot change task or workspace through synchronization")
        }
    }

    private static func applySnapshotRecords(
        _ connection: SQLiteConnection,
        peerDeviceID: DeviceID,
        records: [SyncRecord],
        observedCursor: ChangeCursor,
        maxWritePayloadBytes: Int,
        atMillis now: Int64
    ) throws -> (
        applied: [RecordKey],
        unchanged: [RecordKey],
        conflicts: [RecordConflict]
    ) {
        var applied: [RecordKey] = []
        var unchanged: [RecordKey] = []
        var conflicts: [RecordConflict] = []
        for record in records {
            try record.validateShape()
            guard record.payload.canonicalByteCount(upTo: maxWritePayloadBytes)
                <= maxWritePayloadBytes else {
                throw SyncStoreError.payloadTooLarge(limit: maxWritePayloadBytes)
            }
            let payloadBytes = try canonicalBytes(record.payload, limit: maxWritePayloadBytes)
            let digest = ContentDigest.compute(payloadBytes)
            let key = RecordKey(kind: record.kind, entityID: record.entityID)

            if let existing = try loadRecordRow(
                connection,
                kind: record.kind,
                entityID: record.entityID,
                maxPayloadBytes: maximumReadBytes
            ) {
                try requireMatchingScope(existing: existing.record, incoming: record)
                if existing.record.revision == record.revision {
                    if sameContent(existing, record: record, digest: digest) {
                        if existing.localDirty {
                            try clearLocalDirty(
                                connection,
                                kind: record.kind,
                                entityID: record.entityID
                            )
                        }
                        unchanged.append(key)
                        continue
                    }
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .revisionPayloadMismatch,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
                if existing.record.revision > record.revision {
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .staleRemoteRevision,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
                if existing.localDirty,
                   !sameContent(existing, record: record, digest: digest) {
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .localUnsyncedEdit,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
                guard let baseRevision = record.baseRevision,
                      let baseDigest = record.baseDigest else {
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .missingBaseRevision,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
                guard baseRevision == existing.record.revision,
                      baseDigest == existing.digest else {
                    let conflict = try persistConflict(
                        connection,
                        peerDeviceID: peerDeviceID,
                        reason: .concurrentDivergence,
                        local: existing,
                        incoming: record,
                        incomingDigest: digest,
                        observedCursor: observedCursor,
                        atMillis: now
                    )
                    conflicts.append(conflict)
                    continue
                }
            }

            try upsertRecord(
                connection,
                record: record,
                digest: digest,
                localDirty: false,
                atMillis: now
            )
            _ = try appendChange(
                connection,
                record: record,
                digest: digest,
                type: record.deleted ? .delete : .upsert,
                atMillis: now
            )
            applied.append(key)
        }
        return (applied, unchanged, conflicts)
    }

    private static func clearLocalDirty(
        _ connection: SQLiteConnection,
        kind: SyncEntityKind,
        entityID: EntityID
    ) throws {
        let statement = try connection.prepare(
            "UPDATE records SET local_dirty = 0 WHERE entity_kind = ? AND entity_id = ?"
        )
        try statement.bind(1, kind.rawValue)
        try statement.bind(2, entityID.canonical)
        _ = try statement.step()
    }

    private static func decodeSnapshotRecord(
        _ statement: SQLiteStatement,
        maxPayloadBytes: Int
    ) throws -> SyncRecord {
        guard let kindText = statement.text(1),
              let kind = SyncEntityKind(rawValue: kindText),
              let entityText = statement.text(2),
              let revisionValue = statement.int64(5),
              let originText = statement.text(8),
              let payload = statement.blob(9) else {
            throw SyncStoreError.schemaCorrupt("snapshot entry is incomplete")
        }
        let taskID: TaskID? = try decodeOptionalID(statement.text(3))
        let workspaceID: WorkspaceID? = try decodeOptionalID(statement.text(4))
        let baseRevision = try statement.int64(6).map { try Revision($0) }
        let baseDigest = try statement.text(7).map { try ContentDigest(validating: $0) }
        return SyncRecord(
            kind: kind,
            entityID: try EntityID(validating: entityText),
            taskID: taskID,
            workspaceID: workspaceID,
            revision: try Revision(revisionValue),
            baseRevision: baseRevision,
            baseDigest: baseDigest,
            originDeviceID: try DeviceID(validating: originText),
            payload: try JSONValue.parse(utf8: payload, maxBytes: maxPayloadBytes),
            deleted: (statement.int64(11) ?? 0) != 0
        )
    }

    private static func decodeChangeEntry(_ statement: SQLiteStatement) throws -> ChangeEntry {
        guard let kindText = statement.text(1),
              let kind = SyncEntityKind(rawValue: kindText),
              let entityText = statement.text(2),
              let revisionValue = statement.int64(5),
              let changeText = statement.text(8),
              let changeType = ChangeType(rawValue: changeText),
              let originText = statement.text(9),
              let digestText = statement.text(11) else {
            throw SyncStoreError.schemaCorrupt("change row is incomplete")
        }
        let taskID: TaskID? = try decodeOptionalID(statement.text(3))
        let workspaceID: WorkspaceID? = try decodeOptionalID(statement.text(4))
        let baseRevision = try statement.int64(6).map { try Revision($0) }
        let baseDigest = try statement.text(7).map { try ContentDigest(validating: $0) }
        var payload: JSONValue?
        if let blob = statement.blob(10) {
            payload = try JSONValue.parse(utf8: blob, maxBytes: SyncStore.maximumReadBytes)
        }
        return ChangeEntry(
            cursor: ChangeCursor(unchecked: statement.int64(0) ?? 0),
            key: RecordKey(
                kind: kind,
                entityID: try EntityID(validating: entityText)
            ),
            taskID: taskID,
            workspaceID: workspaceID,
            revision: try Revision(revisionValue),
            baseRevision: baseRevision,
            baseDigest: baseDigest,
            changeType: changeType,
            originDeviceID: try DeviceID(validating: originText),
            payload: payload,
            payloadDigest: try ContentDigest(validating: digestText),
            recordedAt: date(statement.int64(12) ?? 0)
        )
    }

    private static let conflictSelectColumns = """
        conflict_id, peer_device_id, reason, status, resolution,
        observed_cursor, created_at, resolved_at,
        entity_kind, entity_id, task_id, workspace_id, local_revision,
        local_base_revision, local_base_digest, local_origin_device_id,
        local_payload, local_payload_digest, local_deleted,
        incoming_task_id, incoming_workspace_id, incoming_revision,
        incoming_base_revision, incoming_base_digest, incoming_origin_device_id,
        incoming_payload, incoming_payload_digest, incoming_deleted
        """

    private static func loadConflict(
        _ connection: SQLiteConnection,
        id: ConflictID
    ) throws -> StoredConflict? {
        let statement = try connection.prepare(
            "SELECT \(conflictSelectColumns) FROM conflicts WHERE conflict_id = ?"
        )
        try statement.bind(1, id.canonical)
        guard try statement.step() else { return nil }
        return try decodeConflict(statement)
    }

    private static func decodeConflict(_ statement: SQLiteStatement) throws -> StoredConflict {
        guard let conflictText = statement.text(0),
              let peerText = statement.text(1),
              let reasonText = statement.text(2),
              let reason = ConflictReason(rawValue: reasonText),
              let statusText = statement.text(3),
              let status = ConflictStatus(rawValue: statusText),
              let kindText = statement.text(8),
              let kind = SyncEntityKind(rawValue: kindText),
              let entityText = statement.text(9),
              let localRevisionValue = statement.int64(12),
              let localOriginText = statement.text(15),
              let localPayload = statement.blob(16),
              let localDigestText = statement.text(17),
              let incomingRevisionValue = statement.int64(21),
              let incomingOriginText = statement.text(24),
              let incomingPayload = statement.blob(25),
              let incomingDigestText = statement.text(26) else {
            throw SyncStoreError.schemaCorrupt("conflict row is incomplete")
        }
        let resolution: ConflictResolution?
        if let resolutionText = statement.text(4) {
            guard let value = ConflictResolution(rawValue: resolutionText) else {
                throw SyncStoreError.schemaCorrupt("conflict resolution is unknown")
            }
            resolution = value
        } else {
            resolution = nil
        }
        let taskID: TaskID? = try decodeOptionalID(statement.text(10))
        let workspaceID: WorkspaceID? = try decodeOptionalID(statement.text(11))
        let incomingTaskID: TaskID? = try decodeOptionalID(statement.text(19))
        let incomingWorkspaceID: WorkspaceID? = try decodeOptionalID(statement.text(20))
        let local = SyncRecord(
            kind: kind,
            entityID: try EntityID(validating: entityText),
            taskID: taskID,
            workspaceID: workspaceID,
            revision: try Revision(localRevisionValue),
            baseRevision: try statement.int64(13).map { try Revision($0) },
            baseDigest: try statement.text(14).map { try ContentDigest(validating: $0) },
            originDeviceID: try DeviceID(validating: localOriginText),
            payload: try JSONValue.parse(utf8: localPayload, maxBytes: maximumReadBytes),
            deleted: (statement.int64(18) ?? 0) != 0
        )
        let incoming = SyncRecord(
            kind: kind,
            entityID: try EntityID(validating: entityText),
            taskID: incomingTaskID,
            workspaceID: incomingWorkspaceID,
            revision: try Revision(incomingRevisionValue),
            baseRevision: try statement.int64(22).map { try Revision($0) },
            baseDigest: try statement.text(23).map { try ContentDigest(validating: $0) },
            originDeviceID: try DeviceID(validating: incomingOriginText),
            payload: try JSONValue.parse(utf8: incomingPayload, maxBytes: maximumReadBytes),
            deleted: (statement.int64(27) ?? 0) != 0
        )
        return StoredConflict(
            conflictID: try ConflictID(validating: conflictText),
            peerDeviceID: try DeviceID(validating: peerText),
            reason: reason,
            local: local,
            localDigest: try ContentDigest(validating: localDigestText),
            incoming: incoming,
            incomingDigest: try ContentDigest(validating: incomingDigestText),
            observedCursor: ChangeCursor(unchecked: max(0, statement.int64(5) ?? 0)),
            status: status,
            resolution: resolution,
            createdAt: date(statement.int64(6) ?? 0),
            resolvedAt: statement.int64(7).map { date($0) }
        )
    }

    private static func loadStoredCommand(
        _ connection: SQLiteConnection,
        id: CommandID,
        maxPayloadBytes: Int
    ) throws -> StoredCommand? {
        let statement = try connection.prepare(
            """
            SELECT command_id, protocol_major, protocol_minor, kind, task_id,
                   workspace_id, run_id, expected_revision, execution_epoch,
                   target_entity_kind, target_entity_id, payload, payload_digest,
                   command_digest, state, result, accepted_at, updated_at
            FROM commands
            WHERE command_id = ?
            """
        )
        try statement.bind(1, id.canonical)
        guard try statement.step() else { return nil }

        guard let commandText = statement.text(0),
              let kindText = statement.text(3),
              let kind = CommandKind(rawValue: kindText),
              let payloadBlob = statement.blob(11),
              let payloadDigestText = statement.text(12),
              let commandDigestText = statement.text(13),
              let stateText = statement.text(14),
              let state = CommandState(rawValue: stateText) else {
            throw SyncStoreError.schemaCorrupt("command row is incomplete")
        }
        let taskID: TaskID? = try decodeOptionalID(statement.text(4))
        let workspaceID: WorkspaceID? = try decodeOptionalID(statement.text(5))
        let runID: RunID? = try decodeOptionalID(statement.text(6))
        let expectedRevision = try statement.int64(7).map { try Revision($0) }
        let executionEpoch = try statement.int64(8).map { try ExecutionEpoch($0) }
        let targetKey: RecordKey?
        if let kindText = statement.text(9), let entityText = statement.text(10) {
            guard let targetKind = SyncEntityKind(rawValue: kindText) else {
                throw SyncStoreError.schemaCorrupt("command target kind is unknown")
            }
            targetKey = RecordKey(
                kind: targetKind,
                entityID: try EntityID(validating: entityText)
            )
        } else {
            targetKey = nil
        }
        var result: JSONValue?
        if let resultBlob = statement.blob(15) {
            result = try JSONValue.parse(utf8: resultBlob, maxBytes: maxPayloadBytes)
        }
        let acceptedAt = date(statement.int64(16) ?? 0)
        let updatedAt = date(statement.int64(17) ?? 0)
        let payloadDigest = try ContentDigest(validating: payloadDigestText)
        let command = SyncCommand(
            protocolVersion: ProtocolVersion(
                major: Int(statement.int64(1) ?? 1),
                minor: Int(statement.int64(2) ?? 0)
            ),
            commandID: try CommandID(validating: commandText),
            kind: kind,
            taskID: taskID,
            workspaceID: workspaceID,
            runID: runID,
            expectedRevision: expectedRevision,
            targetKey: targetKey,
            executionEpoch: executionEpoch,
            payload: try JSONValue.parse(utf8: payloadBlob, maxBytes: maxPayloadBytes)
        )
        return StoredCommand(
            command: command,
            payloadDigest: payloadDigest,
            commandDigest: try ContentDigest(validating: commandDigestText),
            receipt: CommandReceipt(
                commandID: command.commandID,
                state: state,
                result: result,
                acceptedAt: acceptedAt,
                updatedAt: updatedAt,
                payloadDigest: payloadDigest
            )
        )
    }

    private static func loadExecutionHead(
        _ connection: SQLiteConnection,
        runID: RunID
    ) throws -> ExecutionHead? {
        let statement = try connection.prepare(
            "SELECT run_id, task_id, epoch, owner_device_id, updated_at FROM execution_heads WHERE run_id = ?"
        )
        try statement.bind(1, runID.canonical)
        guard try statement.step() else { return nil }
        guard let runText = statement.text(0),
              let taskText = statement.text(1),
              let epochValue = statement.int64(2),
              let ownerText = statement.text(3) else {
            throw SyncStoreError.schemaCorrupt("execution head row is incomplete")
        }
        return ExecutionHead(
            runID: try RunID(validating: runText),
            taskID: try TaskID(validating: taskText),
            epoch: try ExecutionEpoch(epochValue),
            ownerDeviceID: try DeviceID(validating: ownerText),
            updatedAt: date(statement.int64(4) ?? 0)
        )
    }

    private struct SnapshotRow {
        let descriptor: SnapshotDescriptor
        let expiresAtMillis: Int64
        let manifestComplete: Bool
    }

    private static func loadSnapshot(
        _ connection: SQLiteConnection,
        id: SnapshotID
    ) throws -> SnapshotRow? {
        let statement = try connection.prepare(
            """
            SELECT snapshot_id, base_cursor, record_count, tombstone_count,
                   scope_kind, scope_id, created_at, expires_at, manifest_complete
            FROM snapshots WHERE snapshot_id = ?
            """
        )
        try statement.bind(1, id.canonical)
        guard try statement.step() else { return nil }
        guard let snapshotText = statement.text(0),
              let baseValue = statement.int64(1),
              let countValue = statement.int64(2),
              let tombstoneValue = statement.int64(3),
              let scopeKind = statement.text(4),
              let createdValue = statement.int64(6),
              let expiresValue = statement.int64(7) else {
            throw SyncStoreError.schemaCorrupt("snapshot row is incomplete")
        }
        return SnapshotRow(
            descriptor: SnapshotDescriptor(
                snapshotID: try SnapshotID(validating: snapshotText),
                baseCursor: ChangeCursor(unchecked: baseValue),
                recordCount: Int(countValue),
                tombstoneCount: Int(tombstoneValue),
                scope: try SnapshotScope.decode(
                    kind: scopeKind,
                    identifier: statement.text(5)
                ),
                createdAt: date(createdValue),
                expiresAt: date(expiresValue)
            ),
            expiresAtMillis: expiresValue,
            manifestComplete: statement.int64(8) == 1
        )
    }

    private static func loadLegacyMapping(
        _ connection: SQLiteConnection,
        legacy: LegacyBridgeIdentifier
    ) throws -> LegacyBridgeMapping? {
        let statement = try connection.prepare(
            "SELECT legacy_identifier, entity_kind, stable_entity_id FROM legacy_bridge_mappings WHERE legacy_identifier = ?"
        )
        try statement.bind(1, legacy.rawValue)
        guard try statement.step() else { return nil }
        guard let legacyText = statement.text(0),
              let kindText = statement.text(1),
              let stableText = statement.text(2),
              let kind = SyncEntityKind(rawValue: kindText) else {
            throw SyncStoreError.schemaCorrupt("legacy mapping row is incomplete")
        }
        return LegacyBridgeMapping(
            legacy: try LegacyBridgeIdentifier(validating: legacyText),
            kind: kind,
            stableID: try EntityID(validating: stableText)
        )
    }

    private static func minimumActiveSnapshotBaseCursor(
        _ connection: SQLiteConnection,
        atMillis now: Int64
    ) throws -> ChangeCursor? {
        let statement = try connection.prepare(
            "SELECT MIN(base_cursor) FROM snapshots WHERE expires_at > ?"
        )
        try statement.bind(1, now)
        guard try statement.step(), let value = statement.int64(0) else {
            return nil
        }
        return ChangeCursor(unchecked: max(0, value))
    }

    /// Uses SQLite's AUTOINCREMENT high-water mark rather than `MAX(sequence)`:
    /// pruning every visible change must not reset the cursor to zero.
    private static func latestCursor(_ connection: SQLiteConnection) throws -> ChangeCursor {
        let statement = try connection.prepare(
            "SELECT seq FROM sqlite_sequence WHERE name = 'changes'"
        )
        guard try statement.step(), let value = statement.int64(0) else {
            return .zero
        }
        return ChangeCursor(unchecked: max(0, value))
    }

    private static func prunedThrough(_ connection: SQLiteConnection) throws -> ChangeCursor {
        let value = try metaInt64(connection, key: "changes_pruned_through")
        return ChangeCursor(unchecked: max(0, value))
    }

    private static func appliedCursor(
        _ connection: SQLiteConnection,
        peer: DeviceID
    ) throws -> ChangeCursor {
        let statement = try connection.prepare(
            "SELECT cursor FROM applied_cursors WHERE peer_device_id = ?"
        )
        try statement.bind(1, peer.canonical)
        guard try statement.step() else { return .zero }
        return ChangeCursor(unchecked: max(0, statement.int64(0) ?? 0))
    }

    private static func setAppliedCursor(
        _ connection: SQLiteConnection,
        peer: DeviceID,
        cursor: ChangeCursor,
        atMillis now: Int64
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO applied_cursors (peer_device_id, cursor, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(peer_device_id) DO UPDATE SET
                cursor = excluded.cursor,
                updated_at = excluded.updated_at
            """
        )
        try statement.bind(1, peer.canonical)
        try statement.bind(2, cursor.rawValue)
        try statement.bind(3, now)
        _ = try statement.step()
    }

    private static func metaInt64(
        _ connection: SQLiteConnection,
        key: String
    ) throws -> Int64 {
        let statement = try connection.prepare(
            "SELECT value FROM meta WHERE key = ?"
        )
        try statement.bind(1, key)
        guard try statement.step(),
              let text = statement.text(0),
              let value = Int64(text) else {
            throw SyncStoreError.schemaCorrupt("meta key \(key) is missing or not an integer")
        }
        return value
    }

    private static func setMeta(
        _ connection: SQLiteConnection,
        key: String,
        value: String
    ) throws {
        let statement = try connection.prepare(
            """
            INSERT INTO meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        )
        try statement.bind(1, key)
        try statement.bind(2, value)
        _ = try statement.step()
    }

    private static func scalarText(
        _ connection: SQLiteConnection,
        sql: String
    ) throws -> String {
        let statement = try connection.prepare(sql)
        guard try statement.step(), let value = statement.text(0) else {
            return ""
        }
        return value
    }

    private static func scalarInt(
        _ connection: SQLiteConnection,
        sql: String
    ) throws -> Int {
        let statement = try connection.prepare(sql)
        guard try statement.step() else { return 0 }
        return Int(statement.int64(0) ?? 0)
    }

    private static func bindOptionalText(
        _ statement: SQLiteStatement,
        _ index: Int,
        _ value: String?
    ) throws {
        if let value {
            try statement.bind(index, value)
        } else {
            try statement.bindNull(index)
        }
    }

    private static func bindOptionalInt64(
        _ statement: SQLiteStatement,
        _ index: Int,
        _ value: Int64?
    ) throws {
        if let value {
            try statement.bind(index, value)
        } else {
            try statement.bindNull(index)
        }
    }

    private static func decodeOptionalID<Tag: SyncIDTag>(
        _ value: String?
    ) throws -> StableIdentifier<Tag>? {
        guard let value else { return nil }
        return try StableIdentifier<Tag>(validating: value)
    }

    private static func millis(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    private static func date(_ millis: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(millis) / 1_000)
    }
}
