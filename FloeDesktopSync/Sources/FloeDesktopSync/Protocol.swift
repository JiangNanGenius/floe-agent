import Foundation

public struct ProtocolVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    public static let v1 = ProtocolVersion(major: 1, minor: 0)

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public var description: String { "\(major).\(minor)" }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

/// Object families from the v1 draft. A record identity is `(kind, entityID)`;
/// the same UUID used as a task ID and as a run ID is still two records.
public enum SyncEntityKind: String, Sendable, CaseIterable, Comparable {
    case task
    case run
    case childRun
    case message
    case checkpoint
    case schedule
    case scheduleOccurrence
    case workspaceFile
    case artifact

    public var requiresWorkspaceScope: Bool { self == .workspaceFile }
    public var requiresTaskScope: Bool { !requiresWorkspaceScope }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A snapshot states exactly which stored records it covers. Records outside
/// the scope are never implied absent by a page from this snapshot. Deleted
/// rows inside the scope are materialized as tombstones so a receiver with
/// older state can remove them without guessing from a missing page.
public enum SnapshotScope: Sendable, Equatable {
    case all
    case task(TaskID)
    case workspace(WorkspaceID)

    var kind: String {
        switch self {
        case .all: return "all"
        case .task: return "task"
        case .workspace: return "workspace"
        }
    }

    var identifier: String? {
        switch self {
        case .all: return nil
        case .task(let id): return id.canonical
        case .workspace(let id): return id.canonical
        }
    }

    static func decode(kind: String, identifier: String?) throws -> SnapshotScope {
        switch kind {
        case "all":
            return .all
        case "task":
            guard let identifier else {
                throw SyncStoreError.schemaCorrupt("snapshot task scope has no identifier")
            }
            return .task(try TaskID(validating: identifier))
        case "workspace":
            guard let identifier else {
                throw SyncStoreError.schemaCorrupt("snapshot workspace scope has no identifier")
            }
            return .workspace(try WorkspaceID(validating: identifier))
        default:
            throw SyncStoreError.schemaCorrupt("unknown snapshot scope \(kind)")
        }
    }

    var displayName: String {
        switch self {
        case .all:
            return "all"
        case .task(let id):
            return "task:\(id.canonical)"
        case .workspace(let id):
            return "workspace:\(id.canonical)"
        }
    }
}

public enum CommandScopeRequirement: Sendable {
    case task
    case workspace
    case none
}

/// Modifying command families. The raw values are wire values, not Swift API
/// names, so they remain stable if the enum is reorganized internally.
public enum CommandKind: String, Sendable, CaseIterable {
    case taskSubmit = "task.submit"
    case taskStop = "task.stop"
    case runStart = "run.start"
    case runStop = "run.stop"
    case childSend = "child.send"
    case childStop = "child.stop"
    case handoffPrepare = "handoff.prepare"
    case handoffCommit = "handoff.commit"
    case scheduleSave = "schedule.save"
    case scheduleRunNow = "schedule.runNow"
    case workspaceCommitFile = "workspace.commitFile"

    public var scopeRequirement: CommandScopeRequirement {
        switch self {
        case .workspaceCommitFile:
            return .workspace
        case .taskSubmit, .taskStop, .runStart, .runStop, .childSend, .childStop,
             .handoffPrepare, .handoffCommit, .scheduleSave, .scheduleRunNow:
            return .task
        }
    }

    /// Execution-mutating commands must name an installed execution head and
    /// its exact epoch. A missing head is never treated as epoch 1.
    public var requiresExecutionEpoch: Bool {
        switch self {
        case .runStart, .runStop, .childSend, .childStop, .handoffCommit:
            return true
        case .taskSubmit, .taskStop, .handoffPrepare, .scheduleSave,
             .scheduleRunNow, .workspaceCommitFile:
            return false
        }
    }
}

public enum CommandState: String, Sendable, CaseIterable {
    case accepted
    case started
    case completed
    case failed
    case cancelled
    case outcomeUnknown

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .accepted, .started, .outcomeUnknown:
            return false
        }
    }
}

/// One modification request. `commandID` is the idempotency key; retries reuse
/// the same identity and payload instead of creating a second execution.
public struct SyncCommand: Sendable, Equatable {
    public let protocolVersion: ProtocolVersion
    public let commandID: CommandID
    public let kind: CommandKind
    public let taskID: TaskID?
    public let workspaceID: WorkspaceID?
    public let runID: RunID?
    public let expectedRevision: Revision?
    /// The concrete record whose revision is checked when execution starts.
    /// `expectedRevision` without a target is rejected: a revision number
    /// cannot identify the object it was meant to protect.
    public let targetKey: RecordKey?
    public let executionEpoch: ExecutionEpoch?
    public let payload: JSONValue

    public init(
        protocolVersion: ProtocolVersion = .v1,
        commandID: CommandID,
        kind: CommandKind,
        taskID: TaskID? = nil,
        workspaceID: WorkspaceID? = nil,
        runID: RunID? = nil,
        expectedRevision: Revision? = nil,
        targetKey: RecordKey? = nil,
        executionEpoch: ExecutionEpoch? = nil,
        payload: JSONValue
    ) {
        self.protocolVersion = protocolVersion
        self.commandID = commandID
        self.kind = kind
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.runID = runID
        self.expectedRevision = expectedRevision
        self.targetKey = targetKey
        self.executionEpoch = executionEpoch
        self.payload = payload
    }

    public init(wireJSON: String) throws {
        guard wireJSON.utf8.count <= SyncStore.maximumWireBytes else {
            throw SyncStoreError.payloadTooLarge(limit: SyncStore.maximumWireBytes)
        }
        let value = try JSONValue.parse(
            wireJSON,
            maxBytes: SyncStore.maximumWireBytes,
            maxNodes: SyncStore.maximumWireNodes
        )
        try self.init(wireValue: value)
    }

    public init(wireValue: JSONValue) throws {
        guard case .object(let object) = wireValue else {
            throw SyncStoreError.invalidCommand("wire command must be a JSON object")
        }
        guard let majorValue = object["protocolMajor"]?.integerValue, majorValue >= 1,
              let minorValue = object["protocolMinor"]?.integerValue, minorValue >= 0 else {
            throw SyncStoreError.invalidCommand("protocolMajor/protocolMinor must be non-negative integers")
        }
        let version = ProtocolVersion(major: Int(majorValue), minor: Int(minorValue))
        guard version.major == 1 else {
            throw SyncStoreError.unsupportedProtocolVersion(major: version.major, minor: version.minor)
        }
        guard let commandIDText = object["commandID"]?.stringValue else {
            throw SyncStoreError.invalidCommand("commandID is required")
        }
        let commandID = try CommandID(validating: commandIDText)
        guard let kindText = object["kind"]?.stringValue,
              let kind = CommandKind(rawValue: kindText) else {
            throw SyncStoreError.invalidCommand("kind is missing or unknown")
        }
        guard let payload = object["payload"] else {
            throw SyncStoreError.invalidCommand("payload is required")
        }
        let taskID: TaskID? = try SyncCommand.decodeOptionalIdentifier(object["taskID"])
        let workspaceID: WorkspaceID? = try SyncCommand.decodeOptionalIdentifier(object["workspaceID"])
        let runID: RunID? = try SyncCommand.decodeOptionalIdentifier(object["runID"])
        let expectedRevision = try SyncCommand.decodeOptionalRevision(object["expectedRevision"])
        let targetKey = try SyncCommand.decodeOptionalTarget(object)
        let executionEpoch = try SyncCommand.decodeOptionalEpoch(object["executionEpoch"])
        self.init(
            protocolVersion: version,
            commandID: commandID,
            kind: kind,
            taskID: taskID,
            workspaceID: workspaceID,
            runID: runID,
            expectedRevision: expectedRevision,
            targetKey: targetKey,
            executionEpoch: executionEpoch,
            payload: payload
        )
    }

    public func wireJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "protocolMajor": .integer(Int64(protocolVersion.major)),
            "protocolMinor": .integer(Int64(protocolVersion.minor)),
            "commandID": .string(commandID.canonical),
            "kind": .string(kind.rawValue),
            "payload": payload
        ]
        if let taskID { object["taskID"] = .string(taskID.canonical) }
        if let workspaceID { object["workspaceID"] = .string(workspaceID.canonical) }
        if let runID { object["runID"] = .string(runID.canonical) }
        if let expectedRevision { object["expectedRevision"] = .string(expectedRevision.decimalString) }
        if let targetKey {
            object["targetEntityKind"] = .string(targetKey.kind.rawValue)
            object["targetEntityID"] = .string(targetKey.entityID.canonical)
        }
        if let executionEpoch { object["executionEpoch"] = .string(executionEpoch.decimalString) }
        return .object(object)
    }

    public func wireJSON() -> String {
        wireJSONValue().canonicalJSON()
    }

    /// Structural validation shared by acceptance and receipt storage. It does
    /// not consult the execution head; that check happens inside the same
    /// transaction as the durable command insert.
    public func validateShape(allowingLegacyTarget: Bool = false) throws {
        guard protocolVersion.major == 1, protocolVersion.minor >= 0 else {
            throw SyncStoreError.unsupportedProtocolVersion(
                major: protocolVersion.major,
                minor: protocolVersion.minor
            )
        }
        switch kind.scopeRequirement {
        case .task:
            guard taskID != nil else { throw SyncStoreError.missingCommandScope(kind) }
        case .workspace:
            guard workspaceID != nil else { throw SyncStoreError.missingCommandScope(kind) }
        case .none:
            break
        }
        if kind.requiresExecutionEpoch {
            guard executionEpoch != nil else { throw SyncStoreError.missingExecutionEpoch(kind) }
            guard runID != nil else {
                throw SyncStoreError.invalidCommand("\(kind.rawValue) requires runID")
            }
        } else if executionEpoch != nil, runID == nil {
            throw SyncStoreError.invalidCommand("an execution epoch requires runID")
        }
        if !allowingLegacyTarget {
            switch (expectedRevision, targetKey) {
            case (nil, nil):
                break
            case (.some, .some):
                break
            case (.some, nil):
                throw SyncStoreError.invalidCommand("expectedRevision requires a target record")
            case (nil, .some):
                throw SyncStoreError.invalidCommand("a target record requires expectedRevision")
            }
        }
    }

    func fingerprints() throws -> (payload: ContentDigest, intent: ContentDigest) {
        let payloadDigest = ContentDigest.compute(payload.canonicalUTF8)
        var intentObject: [String: JSONValue] = [
            "kind": .string(kind.rawValue),
            "taskID": taskID.map { .string($0.canonical) } ?? .null,
            "workspaceID": workspaceID.map { .string($0.canonical) } ?? .null,
            "runID": runID.map { .string($0.canonical) } ?? .null,
            "expectedRevision": expectedRevision.map { .string($0.decimalString) } ?? .null,
            "executionEpoch": executionEpoch.map { .string($0.decimalString) } ?? .null,
            "payload": payload
        ]
        // Commands accepted before v2 had no target. Omitting the two keys for
        // a nil target preserves their original intent digest so a retry by
        // the original commandID still returns the stored receipt.
        if let targetKey {
            intentObject["targetEntityKind"] = .string(targetKey.kind.rawValue)
            intentObject["targetEntityID"] = .string(targetKey.entityID.canonical)
        }
        let intent = JSONValue.object(intentObject)
        return (payloadDigest, ContentDigest.compute(intent.canonicalUTF8))
    }

    private static func decodeOptionalIdentifier<Tag: SyncIDTag>(
        _ value: JSONValue?
    ) throws -> StableIdentifier<Tag>? {
        guard let value else { return nil }
        guard let text = value.stringValue else {
            throw SyncStoreError.invalidCommand("identifier fields must be strings")
        }
        return try StableIdentifier<Tag>(validating: text)
    }

    private static func decodeOptionalTarget(
        _ object: [String: JSONValue]
    ) throws -> RecordKey? {
        guard let kindValue = object["targetEntityKind"],
              let entityValue = object["targetEntityID"] else {
            if object["targetEntityKind"] != nil || object["targetEntityID"] != nil {
                throw SyncStoreError.invalidCommand(
                    "targetEntityKind and targetEntityID must be provided together"
                )
            }
            return nil
        }
        guard let kindText = kindValue.stringValue,
              let kind = SyncEntityKind(rawValue: kindText),
              let entityText = entityValue.stringValue else {
            throw SyncStoreError.invalidCommand("target record fields are not valid strings")
        }
        return RecordKey(kind: kind, entityID: try EntityID(validating: entityText))
    }

    private static func decodeOptionalRevision(_ value: JSONValue?) throws -> Revision? {
        guard let value else { return nil }
        guard let text = value.stringValue else {
            throw SyncStoreError.invalidCommand("expectedRevision must be a decimal string")
        }
        return try Revision(decimalString: text)
    }

    private static func decodeOptionalEpoch(_ value: JSONValue?) throws -> ExecutionEpoch? {
        guard let value else { return nil }
        guard let text = value.stringValue else {
            throw SyncStoreError.invalidCommand("executionEpoch must be a decimal string")
        }
        return try ExecutionEpoch(decimalString: text)
    }
}

public struct CommandReceipt: Sendable, Equatable {
    public let commandID: CommandID
    public let state: CommandState
    public let result: JSONValue?
    public let acceptedAt: Date
    public let updatedAt: Date
    public let payloadDigest: ContentDigest

    public init(
        commandID: CommandID,
        state: CommandState,
        result: JSONValue?,
        acceptedAt: Date,
        updatedAt: Date,
        payloadDigest: ContentDigest
    ) {
        self.commandID = commandID
        self.state = state
        self.result = result
        self.acceptedAt = acceptedAt
        self.updatedAt = updatedAt
        self.payloadDigest = payloadDigest
    }

    public var isTerminal: Bool { state.isTerminal }

    public func wireJSON() -> String {
        wireJSONValue().canonicalJSON()
    }

    public func wireJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "commandID": .string(commandID.canonical),
            "state": .string(state.rawValue),
            "acceptedAt": .string(SyncWireTime.rfc3339(acceptedAt)),
            "updatedAt": .string(SyncWireTime.rfc3339(updatedAt)),
            "payloadDigest": .string(payloadDigest.description)
        ]
        if let result { object["result"] = result }
        return .object(object)
    }
}

public struct CommandAcceptance: Sendable, Equatable {
    /// True when the durable ledger already held this exact command intent.
    public let isDuplicate: Bool
    public let receipt: CommandReceipt

    public init(isDuplicate: Bool, receipt: CommandReceipt) {
        self.isDuplicate = isDuplicate
        self.receipt = receipt
    }
}

public struct StoredCommand: Sendable, Equatable {
    public let command: SyncCommand
    public let payloadDigest: ContentDigest
    public let commandDigest: ContentDigest
    public let receipt: CommandReceipt
}

public struct SyncRecord: Sendable, Equatable {
    public let kind: SyncEntityKind
    public let entityID: EntityID
    public let taskID: TaskID?
    public let workspaceID: WorkspaceID?
    public let revision: Revision
    /// The revision the writer observed before producing this one. This is
    /// the common-baseline check that catches concurrent edits from devices
    /// whose local counters happen to be higher. It is optional only for
    /// legacy/database-internal rows; remote updates to an existing record
    /// require it (see `applyRecords`).
    public let baseRevision: Revision?
    public let baseDigest: ContentDigest?
    public let originDeviceID: DeviceID
    public let payload: JSONValue
    public let deleted: Bool

    public init(
        kind: SyncEntityKind,
        entityID: EntityID,
        taskID: TaskID? = nil,
        workspaceID: WorkspaceID? = nil,
        revision: Revision,
        baseRevision: Revision? = nil,
        baseDigest: ContentDigest? = nil,
        originDeviceID: DeviceID,
        payload: JSONValue,
        deleted: Bool = false
    ) {
        self.kind = kind
        self.entityID = entityID
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.revision = revision
        self.baseRevision = baseRevision
        self.baseDigest = baseDigest
        self.originDeviceID = originDeviceID
        self.payload = payload
        self.deleted = deleted
    }

    public func validateShape() throws {
        if let baseRevision, baseRevision >= revision {
            throw SyncStoreError.invalidRecord(
                "baseRevision \(baseRevision) must be older than revision \(revision)"
            )
        }
        if baseDigest != nil, baseRevision == nil {
            throw SyncStoreError.invalidRecord("baseDigest requires baseRevision")
        }
        if kind.requiresWorkspaceScope {
            guard workspaceID != nil else {
                throw SyncStoreError.invalidRecord("\(kind.rawValue) requires workspaceID")
            }
        }
        if kind.requiresTaskScope {
            guard taskID != nil else {
                throw SyncStoreError.invalidRecord("\(kind.rawValue) requires taskID")
            }
        }
        try PortabilityPolicy.validate(payload)
        if kind == .workspaceFile, let path = payload["path"]?.stringValue {
            try PortabilityPolicy.validatePortableRelativePath(path)
        }
    }
}

public struct RecordKey: Hashable, Sendable, CustomStringConvertible {
    public let kind: SyncEntityKind
    public let entityID: EntityID

    public init(kind: SyncEntityKind, entityID: EntityID) {
        self.kind = kind
        self.entityID = entityID
    }

    public var description: String { "\(kind.rawValue)/\(entityID.canonical)" }
}

public struct StoredRecord: Sendable, Equatable {
    public let record: SyncRecord
    public let payloadDigest: ContentDigest
    public let localDirty: Bool
    public let updatedAt: Date
}

public enum RecordCommitOutcome: Sendable, Equatable {
    case appended(ChangeCursor)
    case unchanged
}

public enum ChangeType: String, Sendable {
    case upsert
    case delete
}

public struct ChangeEntry: Sendable, Equatable {
    public let cursor: ChangeCursor
    public let key: RecordKey
    public let taskID: TaskID?
    public let workspaceID: WorkspaceID?
    public let revision: Revision
    public let baseRevision: Revision?
    public let baseDigest: ContentDigest?
    public let changeType: ChangeType
    public let originDeviceID: DeviceID
    public let payload: JSONValue?
    public let payloadDigest: ContentDigest
    public let recordedAt: Date
}

public extension ChangeEntry {
    /// Reconstructs the portable record represented by this change. Returns
    /// nil only for a malformed entry with no payload, which the store never
    /// writes for a real record.
    func makeRecord() -> SyncRecord? {
        guard let payload else { return nil }
        return SyncRecord(
            kind: key.kind,
            entityID: key.entityID,
            taskID: taskID,
            workspaceID: workspaceID,
            revision: revision,
            baseRevision: baseRevision,
            baseDigest: baseDigest,
            originDeviceID: originDeviceID,
            payload: payload,
            deleted: changeType == .delete
        )
    }
}

public struct ChangePage: Sendable, Equatable {
    public let entries: [ChangeEntry]
    public let nextCursor: ChangeCursor
    public let hasMore: Bool

    public init(entries: [ChangeEntry], nextCursor: ChangeCursor, hasMore: Bool) {
        self.entries = entries
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}

public struct PruneResult: Sendable, Equatable {
    public let removed: Int
    public let prunedThrough: ChangeCursor

    public init(removed: Int, prunedThrough: ChangeCursor) {
        self.removed = removed
        self.prunedThrough = prunedThrough
    }
}

public struct SnapshotDescriptor: Sendable, Equatable {
    public let snapshotID: SnapshotID
    public let baseCursor: ChangeCursor
    /// Live records in the explicit scope. Tombstones are counted separately.
    public let recordCount: Int
    public let tombstoneCount: Int
    public let scope: SnapshotScope
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        snapshotID: SnapshotID,
        baseCursor: ChangeCursor,
        recordCount: Int,
        tombstoneCount: Int,
        scope: SnapshotScope,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.snapshotID = snapshotID
        self.baseCursor = baseCursor
        self.recordCount = recordCount
        self.tombstoneCount = tombstoneCount
        self.scope = scope
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct SnapshotPageToken: Sendable, Equatable {
    public let snapshotID: SnapshotID
    public let position: Int64

    public init(snapshotID: SnapshotID, position: Int64) throws {
        guard position >= 0 else {
            throw SyncStoreError.snapshotPageTokenInvalid("position must not be negative")
        }
        self.snapshotID = snapshotID
        self.position = position
    }
}

public struct SnapshotPage: Sendable, Equatable {
    public let records: [SyncRecord]
    public let nextToken: SnapshotPageToken?
    public let baseCursor: ChangeCursor
}

public struct RemoteChangeBatch: Sendable, Equatable {
    public let peerDeviceID: DeviceID
    public let through: ChangeCursor
    public let records: [SyncRecord]

    public init(peerDeviceID: DeviceID, through: ChangeCursor, records: [SyncRecord]) {
        self.peerDeviceID = peerDeviceID
        self.through = through
        self.records = records
    }
}

public enum ConflictReason: String, Sendable {
    /// The peer sent an older revision than the one already stored locally.
    case staleRemoteRevision
    /// The local record has unsent edits; the remote revision did not replace it.
    case localUnsyncedEdit
    /// The same revision carries different content on the two sides.
    case revisionPayloadMismatch
    /// The incoming higher revision was based on an older common baseline, so
    /// it is a concurrent branch rather than a fast-forward.
    case concurrentDivergence
    /// A remote update to an existing record carried no baseline; causality
    /// cannot be proven, so it is refused instead of overwriting.
    case missingBaseRevision
}

public struct RecordConflict: Sendable, Equatable {
    public let conflictID: ConflictID?
    public let key: RecordKey
    public let incomingRevision: Revision
    public let localRevision: Revision
    public let reason: ConflictReason

    public init(
        conflictID: ConflictID? = nil,
        key: RecordKey,
        incomingRevision: Revision,
        localRevision: Revision,
        reason: ConflictReason
    ) {
        self.conflictID = conflictID
        self.key = key
        self.incomingRevision = incomingRevision
        self.localRevision = localRevision
        self.reason = reason
    }
}

public enum ConflictStatus: String, Sendable {
    case open
    case resolved
}

public enum ConflictResolution: String, Sendable {
    case keepLocal
    case acceptRemote
}

public struct StoredConflict: Sendable, Equatable {
    public let conflictID: ConflictID
    public let peerDeviceID: DeviceID
    public let reason: ConflictReason
    public let local: SyncRecord
    public let localDigest: ContentDigest
    public let incoming: SyncRecord
    public let incomingDigest: ContentDigest
    public let observedCursor: ChangeCursor
    public let status: ConflictStatus
    public let resolution: ConflictResolution?
    public let createdAt: Date
    public let resolvedAt: Date?

    public init(
        conflictID: ConflictID,
        peerDeviceID: DeviceID,
        reason: ConflictReason,
        local: SyncRecord,
        localDigest: ContentDigest,
        incoming: SyncRecord,
        incomingDigest: ContentDigest,
        observedCursor: ChangeCursor,
        status: ConflictStatus,
        resolution: ConflictResolution?,
        createdAt: Date,
        resolvedAt: Date?
    ) {
        self.conflictID = conflictID
        self.peerDeviceID = peerDeviceID
        self.reason = reason
        self.local = local
        self.localDigest = localDigest
        self.incoming = incoming
        self.incomingDigest = incomingDigest
        self.observedCursor = observedCursor
        self.status = status
        self.resolution = resolution
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }

    public var key: RecordKey { RecordKey(kind: local.kind, entityID: local.entityID) }
}

public struct RemoteApplyResult: Sendable, Equatable {
    public let applied: [RecordKey]
    public let conflicts: [RecordConflict]
    public let cursor: ChangeCursor

    public init(applied: [RecordKey], conflicts: [RecordConflict], cursor: ChangeCursor) {
        self.applied = applied
        self.conflicts = conflicts
        self.cursor = cursor
    }
}

public struct ExecutionHead: Sendable, Equatable {
    public let runID: RunID
    public let taskID: TaskID
    public let epoch: ExecutionEpoch
    public let ownerDeviceID: DeviceID
    public let updatedAt: Date

    public init(
        runID: RunID,
        taskID: TaskID,
        epoch: ExecutionEpoch,
        ownerDeviceID: DeviceID,
        updatedAt: Date
    ) {
        self.runID = runID
        self.taskID = taskID
        self.epoch = epoch
        self.ownerDeviceID = ownerDeviceID
        self.updatedAt = updatedAt
    }
}

public struct LegacyBridgeMapping: Sendable, Equatable {
    public let legacy: LegacyBridgeIdentifier
    public let kind: SyncEntityKind
    public let stableID: EntityID

    public init(legacy: LegacyBridgeIdentifier, kind: SyncEntityKind, stableID: EntityID) {
        self.legacy = legacy
        self.kind = kind
        self.stableID = stableID
    }
}

public struct LocalWorkspaceBinding: Sendable, Equatable {
    public let workspaceID: WorkspaceID
    public let deviceID: DeviceID
    public let rootPath: String
    public let bookmark: Data?
    public let updatedAt: Date

    public init(
        workspaceID: WorkspaceID,
        deviceID: DeviceID,
        rootPath: String,
        bookmark: Data?,
        updatedAt: Date
    ) {
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.rootPath = rootPath
        self.bookmark = bookmark
        self.updatedAt = updatedAt
    }
}

public struct SyncStoreMetadata: Sendable, Equatable {
    public let deviceID: DeviceID
    public let schemaVersion: Int32
    public let createdAt: Date
    public let prunedThrough: ChangeCursor
    public let recordCount: Int
    public let commandCount: Int
    public let snapshotCount: Int
    public let openConflictCount: Int
    /// Inbound snapshots that are still staging pages. They are not visible
    /// records and hold no cursor until a verified commit.
    public let stagingSnapshotImportCount: Int
    public let establishedSubscriptionCount: Int
    /// Local peer/scope grants. Incremental input is refused without one.
    public let authorizedScopeCount: Int
    /// Bounded replay receipts for authenticated incremental batches.
    public let incrementalReceiptCount: Int
    /// Diagnostic proof that the file is using the expected SQLite setup.
    public let journalMode: String
    public let foreignKeysEnabled: Bool
}

public struct SyncStoreConfiguration: Sendable, Equatable {
    public var snapshotLifetime: TimeInterval
    public var maxPageSize: Int
    public var maxPageBytes: Int
    public var maxPayloadBytes: Int
    public var maxBatchRecords: Int
    public var maxBatchBytes: Int
    /// Maximum number of inbound snapshots that may be staging at the same
    /// time across all peers and scopes. Completed receipts are not counted.
    public var maxConcurrentSnapshotImports: Int
    /// Maximum declared entries and pages in one inbound snapshot manifest.
    public var maxSnapshotEntries: Int
    public var maxSnapshotPages: Int
    /// Maximum canonical payload bytes held by all staging snapshots together.
    public var maxStagingBytes: Int
    /// Number of recent incremental replay receipts retained per
    /// `(peer, scope, subscription version)`. A replay older than this window
    /// fails closed as a cursor gap instead of being reported as a duplicate.
    public var maxIncrementalReceipts: Int
    /// Maximum retained change rows inspected by one sender scan call. This
    /// bounds time spent crossing a large range that contains no in-scope
    /// changes; the scan still advances `throughCursor` to the inspected end.
    public var maxIncrementalScanRows: Int
    /// Refuses a database directory that is not owner-only and sets the
    /// database and its WAL/SHM sidecars to owner read/write. Disable only for
    /// a platform whose file system cannot express POSIX permissions.
    public var enforceSecurePermissions: Bool

    public init(
        snapshotLifetime: TimeInterval = 3_600,
        maxPageSize: Int = 200,
        maxPageBytes: Int = 8 * 1_024 * 1_024,
        maxPayloadBytes: Int = 1_048_576,
        maxBatchRecords: Int = 4_096,
        maxBatchBytes: Int = 32 * 1_024 * 1_024,
        maxConcurrentSnapshotImports: Int = 2,
        maxSnapshotEntries: Int = 100_000,
        maxSnapshotPages: Int = 10_000,
        maxStagingBytes: Int = 64 * 1_024 * 1_024,
        maxIncrementalReceipts: Int = 64,
        maxIncrementalScanRows: Int = 200_000,
        enforceSecurePermissions: Bool = true
    ) {
        self.snapshotLifetime = snapshotLifetime
        self.maxPageSize = maxPageSize
        self.maxPageBytes = maxPageBytes
        self.maxPayloadBytes = maxPayloadBytes
        self.maxBatchRecords = maxBatchRecords
        self.maxBatchBytes = maxBatchBytes
        self.maxConcurrentSnapshotImports = maxConcurrentSnapshotImports
        self.maxSnapshotEntries = maxSnapshotEntries
        self.maxSnapshotPages = maxSnapshotPages
        self.maxStagingBytes = maxStagingBytes
        self.maxIncrementalReceipts = maxIncrementalReceipts
        self.maxIncrementalScanRows = maxIncrementalScanRows
        self.enforceSecurePermissions = enforceSecurePermissions
    }

    func validate() throws {
        guard snapshotLifetime.isFinite,
              snapshotLifetime > 0,
              snapshotLifetime <= 31_536_000 else {
            throw SyncStoreError.invalidConfiguration("snapshotLifetime must be finite and within one year")
        }
        guard (1...1_000).contains(maxPageSize) else {
            throw SyncStoreError.invalidConfiguration("maxPageSize must be within 1...1000")
        }
        guard (1...(64 * 1_024 * 1_024)).contains(maxPageBytes) else {
            throw SyncStoreError.invalidConfiguration("maxPageBytes must be within 1...67108864")
        }
        guard (1...(16 * 1_024 * 1_024)).contains(maxPayloadBytes) else {
            throw SyncStoreError.invalidConfiguration("maxPayloadBytes must be within 1...16777216")
        }
        guard (1...100_000).contains(maxBatchRecords) else {
            throw SyncStoreError.invalidConfiguration("maxBatchRecords must be within 1...100000")
        }
        guard (1...(256 * 1_024 * 1_024)).contains(maxBatchBytes) else {
            throw SyncStoreError.invalidConfiguration("maxBatchBytes must be within 1...268435456")
        }
        guard (1...8).contains(maxConcurrentSnapshotImports) else {
            throw SyncStoreError.invalidConfiguration(
                "maxConcurrentSnapshotImports must be within 1...8"
            )
        }
        guard (1...1_000_000).contains(maxSnapshotEntries) else {
            throw SyncStoreError.invalidConfiguration(
                "maxSnapshotEntries must be within 1...1000000"
            )
        }
        guard (1...100_000).contains(maxSnapshotPages) else {
            throw SyncStoreError.invalidConfiguration(
                "maxSnapshotPages must be within 1...100000"
            )
        }
        guard maxSnapshotPages <= maxSnapshotEntries else {
            throw SyncStoreError.invalidConfiguration(
                "maxSnapshotPages must not exceed maxSnapshotEntries"
            )
        }
        guard (1...(1_024 * 1_024 * 1_024)).contains(maxStagingBytes) else {
            throw SyncStoreError.invalidConfiguration(
                "maxStagingBytes must be within 1...1073741824"
            )
        }
        guard (1...1_024).contains(maxIncrementalReceipts) else {
            throw SyncStoreError.invalidConfiguration(
                "maxIncrementalReceipts must be within 1...1024"
            )
        }
        guard (1...1_000_000).contains(maxIncrementalScanRows) else {
            throw SyncStoreError.invalidConfiguration(
                "maxIncrementalScanRows must be within 1...1000000"
            )
        }
    }
}

/// Fields that belong to a device and must not cross the sync boundary.
/// This is a structural denylist for protocol payloads, not a content
/// classifier: callers must still never put local authorization data in a
/// payload under a different name.
public enum PortabilityPolicy {
    public static let forbiddenFields: Set<String> = [
        "rootpath", "rootbookmark", "bookmark", "bookmarkdata", "filebookmark",
        "absolutepath", "absolutepaths", "localpath", "sourcepath", "hostpath",
        "keychain", "keychainitem", "keychainitems",
        "credential", "credentials", "secret", "secrets",
        "accesstoken", "refreshtoken", "password", "passwords", "apikey", "apikeys",
        "devicepermission", "devicepermissions",
        "systempermission", "systempermissions",
        "authorizationheader", "authorizationheaders"
    ]

    public static func validate(_ payload: JSONValue) throws {
        switch payload {
        case .object(let object):
            for (key, value) in object {
                if forbiddenFields.contains(canonicalFieldName(key)) {
                    throw SyncStoreError.nonPortableField(key)
                }
                try validate(value)
            }
        case .array(let values):
            for value in values {
                try validate(value)
            }
        case .null, .bool, .integer, .string:
            break
        }
    }

    /// Workspace records carry logical relative paths. Absolute paths, home
    /// relative paths, drive letters, backslashes and `..` traversal are
    /// rejected rather than normalized into a different name.
    public static func validatePortableRelativePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 4_096, !path.contains("\0") else {
            throw SyncStoreError.invalidPortablePath(path)
        }
        guard !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.hasPrefix("~"),
              !path.hasPrefix("file://") else {
            throw SyncStoreError.invalidPortablePath(path)
        }
        let scalars = path.unicodeScalars
        if let first = scalars.first, first.isASCII,
           (first.value >= 0x41 && first.value <= 0x5A) || (first.value >= 0x61 && first.value <= 0x7A),
           scalars.dropFirst().first?.value == 0x3A {
            throw SyncStoreError.invalidPortablePath(path)
        }
        guard !path.contains("\\") else {
            throw SyncStoreError.invalidPortablePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw SyncStoreError.invalidPortablePath(path)
            }
            guard !component.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
                throw SyncStoreError.invalidPortablePath(path)
            }
        }
    }

    static func canonicalFieldName(_ key: String) -> String {
        String(key.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

enum SyncWireTime {
    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func parseRFC3339(_ text: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = plain.date(from: text) else {
            throw SyncStoreError.invalidWireTime(text)
        }
        return date
    }
}
