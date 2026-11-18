import Foundation

/// All expected failures are explicit values. Callers must not retry an
/// `outcomeUnknown` or a payload conflict as if it were a transient network
/// error.
public enum SyncStoreError: Error, Equatable, CustomStringConvertible {
    case closed
    case invalidConfiguration(String)
    case openFailed(path: String, message: String)
    case sqliteFailure(code: Int32, message: String)
    case unsafeDatabasePath(String)
    case insecureDatabaseDirectory(path: String)
    case unsupportedSchemaVersion(Int32)
    case schemaCorrupt(String)
    case deviceIdentityMismatch(expected: String, found: String)

    case invalidIdentifier(String)
    case invalidLegacyIdentifier(String)
    case invalidRevision(Int64)
    case invalidRevisionString(String)
    case invalidEpoch(Int64)
    case invalidEpochString(String)
    case invalidCursor(Int64)
    case invalidCursorString(String)
    case unsupportedProtocolVersion(major: Int, minor: Int)
    case invalidDigest(String)
    case invalidWireTime(String)

    case invalidCommand(String)
    case missingCommandScope(CommandKind)
    case missingExecutionEpoch(CommandKind)
    case executionEpochNotEstablished(RunID, ExecutionEpoch)
    case executionHeadNotEstablished(RunID)
    case staleExecutionEpoch(RunID, ExecutionEpoch, current: ExecutionEpoch)
    case executionEpochOwnerConflict(RunID, ExecutionEpoch)
    case executionTaskMismatch(RunID, expected: TaskID, received: TaskID)
    case executionOwnerMismatch(RunID, owner: DeviceID, authenticated: DeviceID)
    case executionPrincipalMismatch(expected: DeviceID, authenticated: DeviceID)
    case expectedRevisionMismatch(RecordKey, expected: Revision, current: Revision?)
    case targetTaskMismatch(RecordKey, expected: TaskID, found: TaskID?)
    case targetWorkspaceMismatch(RecordKey, expected: WorkspaceID, found: WorkspaceID?)
    case payloadConflict(CommandID)
    case commandNotFound(CommandID)
    case invalidTransition(CommandID, from: CommandState, to: CommandState)

    case invalidRecord(String)
    case invalidRunProjection(String)
    case runProjectionCursorConflict(RunID, expected: Int64, received: Int64)
    case runProjectionReplayConflict(RunID)
    case runProjectionBindingMismatch(RunID)
    case runProjectionCheckpointCorrupt(RunID)
    case recordOriginMismatch(expected: DeviceID, found: DeviceID)
    case staleLocalRevision(SyncEntityKind, EntityID, current: Revision, received: Revision)
    case localBaseMismatch(SyncEntityKind, EntityID, expected: Revision?, found: Revision)
    case localBaseDigestMismatch(SyncEntityKind, EntityID)
    case revisionPayloadMismatch(SyncEntityKind, EntityID, revision: Revision)
    case payloadTooLarge(limit: Int)
    case batchTooLarge(limit: Int)
    case batchBytesTooLarge(limit: Int)
    case nonPortableField(String)
    case invalidPortablePath(String)
    case invalidLocalBinding(String)

    case cursorExpired(ChangeCursor, retainedFrom: ChangeCursor)
    case cursorRegression(DeviceID, current: ChangeCursor, received: ChangeCursor)
    case cursorAhead(current: ChangeCursor, received: ChangeCursor)
    case invalidPageSize(Int)

    case snapshotNotFound(SnapshotID)
    case snapshotExpired(SnapshotID)
    case snapshotTokenMismatch(expected: SnapshotID, received: SnapshotID)
    case snapshotPageTokenInvalid(String)
    case snapshotImportUnverified
    case scopedIncrementalUnverified

    case invalidAuthenticationKey
    case invalidAuthenticationProof(String)
    case incrementalAuthenticationUnavailable
    case incrementalAuthenticationFailed(String)
    case incrementalPeerMismatch(expected: DeviceID, found: DeviceID)
    case incrementalBatchInvalid(String)
    case incrementalScopeUnauthorized(DeviceID, SnapshotScope)
    case incrementalRangeGap(
        DeviceID,
        SnapshotScope,
        expected: ChangeCursor,
        receivedFrom: ChangeCursor
    )
    case incrementalReplayConflict(
        DeviceID,
        SnapshotScope,
        from: ChangeCursor,
        through: ChangeCursor
    )
    case incrementalCursorConflict(DeviceID, SnapshotScope)
    case incrementalReceiptCorrupt
    case invalidScopeGrant(String)

    case snapshotManifestInvalid(String)
    case snapshotManifestDigestMismatch
    case snapshotPeerMismatch(expected: DeviceID, found: DeviceID)
    case snapshotScopeMismatch(RecordKey, SnapshotScope)
    case snapshotImportNotFound(DeviceID, SnapshotID)
    case snapshotImportExpired(DeviceID, SnapshotID)
    case snapshotImportInProgress(DeviceID, SnapshotScope)
    case snapshotIdentityConflict(DeviceID, SnapshotID)
    case snapshotPageOutOfOrder(expected: Int, received: Int)
    case snapshotPageConflict(DeviceID, SnapshotID, pageIndex: Int)
    case snapshotPageDigestMismatch(expected: ContentDigest, received: ContentDigest)
    case snapshotPagesIncomplete(received: Int, expected: Int)
    case snapshotDuplicateRecord(RecordKey)
    case snapshotStagingLimitExceeded(String)
    case snapshotTooLarge(String)
    case snapshotBaseStale(DeviceID, SnapshotScope, current: ChangeCursor, received: ChangeCursor)
    case subscriptionNotEstablished(DeviceID, SnapshotScope)
    case subscriptionVersionMismatch(
        DeviceID,
        SnapshotScope,
        expected: Int64,
        found: Int64
    )
    case invalidSubscriptionVersion(Int64)
    case snapshotImportReceiptCorrupt

    case conflictNotFound(ConflictID)
    case conflictAlreadyResolved(ConflictID)
    case conflictStale(ConflictID)

    case legacyMappingConflict(String)

    public var description: String {
        switch self {
        case .closed:
            return "sync store is closed"
        case .invalidConfiguration(let detail):
            return "invalid sync store configuration: \(detail)"
        case .openFailed(let path, let message):
            return "cannot open sync database at \(path): \(message)"
        case .sqliteFailure(let code, let message):
            return "SQLite failure \(code): \(message)"
        case .unsafeDatabasePath(let path):
            return "database path \(path) is a symlink or otherwise unsafe"
        case .insecureDatabaseDirectory(let path):
            return "database directory \(path) must be owner-only (0700)"
        case .unsupportedSchemaVersion(let version):
            return "database schema version \(version) is newer than this package supports"
        case .schemaCorrupt(let detail):
            return "sync database schema is not usable: \(detail)"
        case .deviceIdentityMismatch(let expected, let found):
            return "database belongs to device \(found), not \(expected)"
        case .invalidIdentifier(let value):
            return "\(value) is not a canonical UUID identity"
        case .invalidLegacyIdentifier(let value):
            return "\(value) is not a usable legacy Bridge identifier"
        case .invalidRevision(let value):
            return "revision \(value) must be positive"
        case .invalidRevisionString(let value):
            return "\(value) is not a positive decimal revision"
        case .invalidEpoch(let value):
            return "execution epoch \(value) must be positive"
        case .invalidEpochString(let value):
            return "\(value) is not a positive decimal execution epoch"
        case .invalidCursor(let value):
            return "change cursor \(value) must not be negative"
        case .invalidCursorString(let value):
            return "\(value) is not a non-negative decimal change cursor"
        case .unsupportedProtocolVersion(let major, let minor):
            return "protocol version \(major).\(minor) is not supported"
        case .invalidDigest(let value):
            return "\(value) is not a sha256:<64 hex> content digest"
        case .invalidWireTime(let value):
            return "\(value) is not an RFC 3339 UTC timestamp"
        case .invalidCommand(let detail):
            return "invalid command: \(detail)"
        case .missingCommandScope(let kind):
            return "command \(kind.rawValue) is missing its required task/workspace scope"
        case .missingExecutionEpoch(let kind):
            return "command \(kind.rawValue) requires an execution epoch"
        case .executionEpochNotEstablished(let runID, let epoch):
            return "run \(runID) has no installed execution head for epoch \(epoch)"
        case .executionHeadNotEstablished(let runID):
            return "run \(runID) has no installed execution head"
        case .staleExecutionEpoch(let runID, let epoch, let current):
            return "run \(runID) epoch \(epoch) is older than current epoch \(current)"
        case .executionEpochOwnerConflict(let runID, let epoch):
            return "run \(runID) epoch \(epoch) already belongs to another owner"
        case .executionTaskMismatch(let runID, let expected, let received):
            return "run \(runID) belongs to task \(expected), not \(received)"
        case .executionOwnerMismatch(let runID, let owner, let authenticated):
            return "run \(runID) is owned by \(owner), not authenticated device \(authenticated)"
        case .executionPrincipalMismatch(let expected, let authenticated):
            return "execution is bound to this store's device \(expected), not \(authenticated)"
        case .expectedRevisionMismatch(let key, let expected, let current):
            if let current {
                return "\(key) is at revision \(current), expected \(expected)"
            }
            return "\(key) does not exist, expected revision \(expected)"
        case .targetTaskMismatch(let key, let expected, let found):
            return "\(key) belongs to task \(found?.canonical ?? "nil"), not command task \(expected)"
        case .targetWorkspaceMismatch(let key, let expected, let found):
            return "\(key) belongs to workspace \(found?.canonical ?? "nil"), not command workspace \(expected)"
        case .payloadConflict(let commandID):
            return "command \(commandID) was already accepted with a different intent"
        case .commandNotFound(let commandID):
            return "command \(commandID) is unknown"
        case .invalidTransition(let commandID, let from, let to):
            return "command \(commandID) cannot move from \(from.rawValue) to \(to.rawValue)"
        case .invalidRecord(let detail):
            return "invalid sync record: \(detail)"
        case .invalidRunProjection(let detail):
            return "invalid local run projection: \(detail)"
        case .runProjectionCursorConflict(let runID, let expected, let received):
            return "run projection \(runID) expected source sequence \(expected), received \(received)"
        case .runProjectionReplayConflict(let runID):
            return "run projection \(runID) replay has different content"
        case .runProjectionBindingMismatch(let runID):
            return "run projection \(runID) has a different task, owner or execution epoch"
        case .runProjectionCheckpointCorrupt(let runID):
            return "run projection \(runID) checkpoint is corrupt"
        case .recordOriginMismatch(let expected, let found):
            return "local record origin \(found) does not match this device \(expected)"
        case .staleLocalRevision(let kind, let entityID, let current, let received):
            return "\(kind.rawValue) \(entityID) local revision \(received) is older than \(current)"
        case .localBaseMismatch(let kind, let entityID, let expected, let found):
            return "\(kind.rawValue) \(entityID) local edit is based on revision \(expected.map(String.init) ?? "nil"), current is \(found)"
        case .localBaseDigestMismatch(let kind, let entityID):
            return "\(kind.rawValue) \(entityID) local edit baseline content does not match the stored row"
        case .revisionPayloadMismatch(let kind, let entityID, let revision):
            return "\(kind.rawValue) \(entityID) already has different content at revision \(revision)"
        case .payloadTooLarge(let limit):
            return "canonical payload exceeds the \(limit)-byte limit"
        case .batchTooLarge(let limit):
            return "batch has more than \(limit) records"
        case .batchBytesTooLarge(let limit):
            return "batch payloads exceed the \(limit)-byte limit"
        case .nonPortableField(let key):
            return "payload field \(key) is device-local and must not be synchronized"
        case .invalidPortablePath(let path):
            return "\(path) is not a portable workspace-relative path"
        case .invalidLocalBinding(let detail):
            return "local workspace binding is invalid: \(detail)"
        case .cursorExpired(let cursor, let retainedFrom):
            return "change cursor \(cursor) expired; retained changes start after \(retainedFrom)"
        case .cursorRegression(let peer, let current, let received):
            return "inbound cursor for \(peer) regressed from \(current) to \(received)"
        case .cursorAhead(let current, let received):
            return "change cursor \(received) is ahead of local latest \(current)"
        case .invalidPageSize(let size):
            return "page size \(size) is outside the accepted bounds"
        case .snapshotNotFound(let id):
            return "snapshot \(id) does not exist"
        case .snapshotImportUnverified:
            return "snapshot import requires verified complete pages and a scope-specific cursor"
        case .scopedIncrementalUnverified:
            return "incremental sync requires an authenticated subscription version and verified scan interval"
        case .invalidAuthenticationKey:
            return "authentication key must contain between 32 and 1024 bytes"
        case .invalidAuthenticationProof(let detail):
            return "authentication proof is invalid: \(detail)"
        case .incrementalAuthenticationUnavailable:
            return "no trusted incremental authenticator is attached; refusing unauthenticated changes"
        case .incrementalAuthenticationFailed(let detail):
            return "incremental batch authentication failed: \(detail)"
        case .incrementalPeerMismatch(let expected, let found):
            return "incremental batch claims peer \(found), authenticated peer is \(expected)"
        case .incrementalBatchInvalid(let detail):
            return "incremental batch is invalid: \(detail)"
        case .incrementalScopeUnauthorized(let peer, let scope):
            return "peer \(peer) is not authorized to synchronize \(scope.displayName)"
        case .incrementalRangeGap(let peer, let scope, let expected, let received):
            return "incremental batch for \(scope.displayName) from \(peer) starts at \(received), expected exactly \(expected)"
        case .incrementalReplayConflict(let peer, let scope, let from, let through):
            return "batch \(from)...\(through) for \(scope.displayName) from \(peer) was already applied with different content"
        case .incrementalCursorConflict(let peer, let scope):
            return "subscription cursor for \(scope.displayName) from \(peer) changed concurrently"
        case .incrementalReceiptCorrupt:
            return "stored incremental receipt is not readable"
        case .invalidScopeGrant(let detail):
            return "scope authorization is invalid: \(detail)"
        case .snapshotManifestInvalid(let detail):
            return "snapshot manifest is invalid: \(detail)"
        case .snapshotManifestDigestMismatch:
            return "snapshot manifest digest does not match its declared identity and pages"
        case .snapshotPeerMismatch(let expected, let found):
            return "snapshot belongs to peer \(found), not authenticated peer \(expected)"
        case .snapshotScopeMismatch(let key, let scope):
            return "\(key) is outside snapshot scope \(scope.displayName)"
        case .snapshotImportNotFound(let peer, let snapshotID):
            return "no snapshot import \(snapshotID) is staged for peer \(peer)"
        case .snapshotImportExpired(let peer, let snapshotID):
            return "snapshot import \(snapshotID) for peer \(peer) has expired"
        case .snapshotImportInProgress(let peer, let scope):
            return "peer \(peer) already has a different snapshot in progress for \(scope.displayName)"
        case .snapshotIdentityConflict(let peer, let snapshotID):
            return "peer \(peer) already used snapshot identity \(snapshotID) with different content"
        case .snapshotPageOutOfOrder(let expected, let received):
            return "snapshot page \(received) arrived out of order; expected page \(expected)"
        case .snapshotPageConflict(let peer, let snapshotID, let pageIndex):
            return "snapshot \(snapshotID) page \(pageIndex) from peer \(peer) was already staged with different content"
        case .snapshotPageDigestMismatch(let expected, let received):
            return "snapshot page digest \(received) does not match the manifest digest \(expected)"
        case .snapshotPagesIncomplete(let received, let expected):
            return "snapshot import has \(received) of \(expected) pages"
        case .snapshotDuplicateRecord(let key):
            return "snapshot stages \(key) more than once"
        case .snapshotStagingLimitExceeded(let detail):
            return "snapshot staging limit exceeded: \(detail)"
        case .snapshotTooLarge(let detail):
            return "snapshot exceeds configured limits: \(detail)"
        case .snapshotBaseStale(let peer, let scope, let current, let received):
            return "snapshot for \(scope.displayName) from \(peer) has base cursor \(received), behind applied \(current)"
        case .subscriptionNotEstablished(let peer, let scope):
            return "peer \(peer) has no complete snapshot subscription for \(scope.displayName)"
        case .subscriptionVersionMismatch(let peer, let scope, let expected, let found):
            return "peer \(peer) subscription \(scope.displayName) is at version \(found), not \(expected)"
        case .invalidSubscriptionVersion(let value):
            return "subscription version \(value) must be positive"
        case .snapshotImportReceiptCorrupt:
            return "stored snapshot import receipt is not readable"
        case .snapshotExpired(let id):
            return "snapshot \(id) has expired"
        case .snapshotTokenMismatch(let expected, let received):
            return "page token belongs to snapshot \(received), not \(expected)"
        case .snapshotPageTokenInvalid(let detail):
            return "snapshot page token is invalid: \(detail)"
        case .conflictNotFound(let id):
            return "conflict \(id) does not exist"
        case .conflictAlreadyResolved(let id):
            return "conflict \(id) is already resolved"
        case .conflictStale(let id):
            return "conflict \(id) no longer matches the current local record"
        case .legacyMappingConflict(let legacy):
            return "legacy Bridge identifier \(legacy) is already mapped to a different stable identity"
        }
    }
}
