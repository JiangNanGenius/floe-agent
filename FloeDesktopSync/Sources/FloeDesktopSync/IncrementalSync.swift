import Foundation

/// One ordered change in an authenticated incremental batch. `sourceCursor` is
/// the change sequence on the sending device, not a local cursor. It lets the
/// receiver prove that every delivered entry lies inside the declared
/// `(fromCursor, throughCursor]` scan interval and that entries are ordered.
public struct IncrementalChange: Sendable, Equatable {
    public let sourceCursor: ChangeCursor
    public let record: SyncRecord

    public init(sourceCursor: ChangeCursor, record: SyncRecord) {
        self.sourceCursor = sourceCursor
        self.record = record
    }
}

/// A complete, self-consistent incremental scan interval.
///
/// The sender scans *all* retained changes in `(fromCursor, throughCursor]` on
/// its own change log and includes exactly those relevant to `scope`, in
/// ascending source-cursor order. Changes for other scopes are filtered out,
/// so the delivered entry cursors may have gaps; an empty entry list with
/// `throughCursor > fromCursor` is a meaningful "scanned, nothing in scope"
/// result and must still advance the receiver's scope cursor.
///
/// `throughCursor` is the end of the contiguous source range that was actually
/// scanned, never merely the largest matched event. The receiver treats it as
/// the sender's authenticated completeness claim for that interval and checks
/// it against its own exact expected starting cursor.
public struct IncrementalBatch: Sendable, Equatable {
    /// Hard structural ceiling that applies before store configuration limits.
    /// A decoded frame can never allocate an unbounded change array.
    public static let maximumStructuralEntries = 100_000
    static let maximumWireBytes = 64 * 1_024 * 1_024
    static let maximumWireNodes = 2_000_000

    public let protocolVersion: ProtocolVersion
    /// The sender's claimed origin device identity. It is bound by the
    /// authentication proof and must equal the authenticated sender; it is
    /// never trusted alone.
    public let peerDeviceID: DeviceID
    /// The intended receiver, authenticated in the batch proof and compared
    /// against the receiving store's own durable device identity.
    public let receiverDeviceID: DeviceID
    public let scope: SnapshotScope
    public let subscriptionVersion: Int64
    public let fromCursor: ChangeCursor
    public let throughCursor: ChangeCursor
    public let changes: [IncrementalChange]
    /// `nil` means the batch arrived through a trusted transport adapter that
    /// supplied its own authentication result. A batch with no proof and no
    /// attached authenticator is always refused.
    public let proof: IncrementalBatchProof?

    public init(
        protocolVersion: ProtocolVersion = ProtocolVersion(major: 1, minor: 1),
        peerDeviceID: DeviceID,
        receiverDeviceID: DeviceID,
        scope: SnapshotScope,
        subscriptionVersion: Int64,
        fromCursor: ChangeCursor,
        throughCursor: ChangeCursor,
        changes: [IncrementalChange],
        proof: IncrementalBatchProof? = nil
    ) throws {
        try Self.validateStructure(
            protocolVersion: protocolVersion,
            subscriptionVersion: subscriptionVersion,
            fromCursor: fromCursor,
            throughCursor: throughCursor,
            changes: changes,
            scope: scope
        )
        self.protocolVersion = protocolVersion
        self.peerDeviceID = peerDeviceID
        self.receiverDeviceID = receiverDeviceID
        self.scope = scope
        self.subscriptionVersion = subscriptionVersion
        self.fromCursor = fromCursor
        self.throughCursor = throughCursor
        self.changes = changes
        self.proof = proof
    }

    private init(
        unchecked batch: IncrementalBatch,
        proof: IncrementalBatchProof
    ) {
        protocolVersion = batch.protocolVersion
        peerDeviceID = batch.peerDeviceID
        receiverDeviceID = batch.receiverDeviceID
        scope = batch.scope
        subscriptionVersion = batch.subscriptionVersion
        fromCursor = batch.fromCursor
        throughCursor = batch.throughCursor
        changes = batch.changes
        self.proof = proof
    }

    /// Returns a copy carrying an HMAC-SHA-256 proof. The proof covers every
    /// field of the batch (including the key identifier), not a bare content
    /// digest. The same batch content therefore produces the same proof and
    /// can be retried byte-for-byte after a lost acknowledgement.
    public func signed(keyID: String, key: SyncProofKey) throws -> IncrementalBatch {
        let proof = try IncrementalBatchProof.make(batch: self, keyID: keyID, key: key)
        return IncrementalBatch(unchecked: self, proof: proof)
    }

    public func validateStructure() throws {
        try Self.validateStructure(
            protocolVersion: protocolVersion,
            subscriptionVersion: subscriptionVersion,
            fromCursor: fromCursor,
            throughCursor: throughCursor,
            changes: changes,
            scope: scope
        )
    }

    /// Store-specific bounds: record count, aggregate payload bytes and each
    /// record's payload limit. Called before authentication hashing so an
    /// oversized frame is refused before expensive work.
    public func validateLimits(
        maxRecords: Int,
        maxBytes: Int,
        maxPayloadBytes: Int
    ) throws {
        guard maxRecords >= 1, maxBytes >= 1, maxPayloadBytes >= 1 else {
            throw SyncStoreError.invalidConfiguration("incremental limits must be positive")
        }
        guard changes.count <= maxRecords else {
            throw SyncStoreError.batchTooLarge(limit: maxRecords)
        }
        var totalBytes = 0
        for change in changes {
            let remaining = maxBytes - totalBytes
            guard remaining >= 1 else {
                throw SyncStoreError.batchBytesTooLarge(limit: maxBytes)
            }
            let payloadBytes = change.record.payload.canonicalByteCount(upTo: remaining)
            guard payloadBytes <= remaining else {
                throw SyncStoreError.batchBytesTooLarge(limit: maxBytes)
            }
            guard change.record.payload.canonicalByteCount(upTo: maxPayloadBytes)
                <= maxPayloadBytes else {
                throw SyncStoreError.payloadTooLarge(limit: maxPayloadBytes)
            }
            totalBytes += payloadBytes
        }
    }

    /// Digest of the batch content without the proof key identifier. It is an
    /// integrity value used for replay identity, never a sender proof.
    public func contentDigest() -> ContentDigest {
        IncrementalBatchDigest.digest(of: self, keyID: nil)
    }

    /// Digest that the HMAC proof covers. Includes the proof key identifier so
    /// a valid tag cannot be relabeled under a different key identity.
    public func authenticationDigest() -> ContentDigest {
        IncrementalBatchDigest.digest(of: self, keyID: proof?.keyID)
    }

    internal func contentDigestThrowing() throws -> ContentDigest {
        try validateStructure()
        return contentDigest()
    }

    internal func authenticationDigest(usingKeyID keyID: String) throws -> ContentDigest {
        try validateStructure()
        return IncrementalBatchDigest.digest(of: self, keyID: keyID)
    }

    internal func authenticationDigestThrowing() throws -> ContentDigest {
        try validateStructure()
        return authenticationDigest()
    }

    private static func validateStructure(
        protocolVersion: ProtocolVersion,
        subscriptionVersion: Int64,
        fromCursor: ChangeCursor,
        throughCursor: ChangeCursor,
        changes: [IncrementalChange],
        scope: SnapshotScope
    ) throws {
        guard protocolVersion.major == 1, protocolVersion.minor >= 1 else {
            throw SyncStoreError.unsupportedProtocolVersion(
                major: protocolVersion.major,
                minor: protocolVersion.minor
            )
        }
        guard subscriptionVersion > 0 else {
            throw SyncStoreError.invalidSubscriptionVersion(subscriptionVersion)
        }
        guard throughCursor >= fromCursor else {
            throw SyncStoreError.incrementalBatchInvalid(
                "throughCursor \(throughCursor) precedes fromCursor \(fromCursor)"
            )
        }
        guard changes.count <= maximumStructuralEntries else {
            throw SyncStoreError.batchTooLarge(limit: maximumStructuralEntries)
        }
        if fromCursor == throughCursor, !changes.isEmpty {
            throw SyncStoreError.incrementalBatchInvalid(
                "an empty scan interval cannot carry changes"
            )
        }
        var previousCursor: ChangeCursor?
        for change in changes {
            guard change.sourceCursor > fromCursor,
                  change.sourceCursor <= throughCursor else {
                throw SyncStoreError.incrementalBatchInvalid(
                    "change cursor \(change.sourceCursor) is outside the declared interval"
                )
            }
            if let previousCursor {
                guard change.sourceCursor > previousCursor else {
                    throw SyncStoreError.incrementalBatchInvalid(
                        "change cursors must be strictly increasing"
                    )
                }
            }
            previousCursor = change.sourceCursor
            try change.record.validateShape()
            try validateScope(change.record, scope: scope)
        }
    }

    private static func validateScope(_ record: SyncRecord, scope: SnapshotScope) throws {
        switch scope {
        case .all:
            return
        case .task(let taskID):
            guard record.taskID == taskID else {
                throw SyncStoreError.snapshotScopeMismatch(
                    RecordKey(kind: record.kind, entityID: record.entityID),
                    scope
                )
            }
        case .workspace(let workspaceID):
            guard record.workspaceID == workspaceID else {
                throw SyncStoreError.snapshotScopeMismatch(
                    RecordKey(kind: record.kind, entityID: record.entityID),
                    scope
                )
            }
        }
    }
}

/// A key-identified HMAC-SHA-256 tag over `IncrementalBatch.authenticationDigest()`.
public struct IncrementalBatchProof: Sendable, Equatable {
    public let keyID: String
    public let tag: IncrementalAuthenticationTag

    public init(keyID: String, tag: IncrementalAuthenticationTag) throws {
        try IncrementalProofKeyIdentifier.validate(keyID)
        self.keyID = keyID
        self.tag = tag
    }

    static func make(
        batch: IncrementalBatch,
        keyID: String,
        key: SyncProofKey
    ) throws -> IncrementalBatchProof {
        try IncrementalProofKeyIdentifier.validate(keyID)
        let digest = try batch.authenticationDigest(usingKeyID: keyID)
        let message = IncrementalBatchDigest.proofMessage(digest)
        return try IncrementalBatchProof(
            keyID: keyID,
            tag: IncrementalAuthenticationTag.compute(key: key, message: message)
        )
    }
}

/// Non-secret key identifier used in proofs and diagnostics. Keeping it
/// printable and bounded avoids ambiguous log/DB values; the key bytes never
/// appear here.
enum IncrementalProofKeyIdentifier {
    static func validate(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128 else {
            throw SyncStoreError.invalidAuthenticationProof(
                "proof key ID must contain 1...128 bytes"
            )
        }
        for scalar in value.unicodeScalars {
            let isAllowed = (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || scalar.value == 0x2E   // .
                || scalar.value == 0x5F   // _
                || scalar.value == 0x3A   // :
                || scalar.value == 0x2D   // -
            guard isAllowed else {
                throw SyncStoreError.invalidAuthenticationProof(
                    "proof key ID contains a disallowed character"
                )
            }
        }
    }
}

/// Canonical descriptor shared by sender and receiver. Only identities,
/// revisions, causal baselines and payload digests are covered; the trailing
/// key identifier distinguishes the content digest from the authenticated
/// digest.
enum IncrementalBatchDigest {
    static let domain = "floe.incremental.batch.receiver.v2"

    static func digest(of batch: IncrementalBatch, keyID: String?) -> ContentDigest {
        ContentDigest.compute(descriptor(batch, keyID: keyID).canonicalUTF8)
    }

    static func proofMessage(_ digest: ContentDigest) -> [UInt8] {
        Array("\(domain)\n\(digest.description)".utf8)
    }

    static func descriptor(_ batch: IncrementalBatch, keyID: String?) -> JSONValue {
        var object: [String: JSONValue] = [
            "domain": .string(domain),
            "protocolMajor": .integer(Int64(batch.protocolVersion.major)),
            "protocolMinor": .integer(Int64(batch.protocolVersion.minor)),
            "peerDeviceID": .string(batch.peerDeviceID.canonical),
            "receiverDeviceID": .string(batch.receiverDeviceID.canonical),
            "scopeKind": .string(batch.scope.kind),
            "scopeID": batch.scope.identifier.map { .string($0) } ?? .null,
            "subscriptionVersion": .string(String(batch.subscriptionVersion)),
            "fromCursor": .string(batch.fromCursor.decimalString),
            "throughCursor": .string(batch.throughCursor.decimalString),
            "changes": .array(batch.changes.map { change in
                .object([
                    "cursor": .string(change.sourceCursor.decimalString),
                    "record": SnapshotDigest.recordDescriptor(change.record)
                ])
            })
        ]
        object["keyID"] = keyID.map { .string($0) } ?? .null
        return .object(object)
    }
}

// MARK: - Wire encoding

public extension IncrementalBatch {
    /// Canonical transport frame. The HMAC covers the canonical descriptor,
    /// not these bytes, so an integration may wrap the frame in its own
    /// transport envelope; it must still deliver the exact batch value that
    /// was authenticated.
    func wireJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "protocolMajor": .integer(Int64(protocolVersion.major)),
            "protocolMinor": .integer(Int64(protocolVersion.minor)),
            "peerDeviceID": .string(peerDeviceID.canonical),
            "receiverDeviceID": .string(receiverDeviceID.canonical),
            "scopeKind": .string(scope.kind),
            "subscriptionVersion": .string(String(subscriptionVersion)),
            "fromCursor": .string(fromCursor.decimalString),
            "throughCursor": .string(throughCursor.decimalString),
            "changes": .array(changes.map { change in
                .object([
                    "cursor": .string(change.sourceCursor.decimalString),
                    "record": IncrementalWire.recordValue(change.record)
                ])
            })
        ]
        if let identifier = scope.identifier {
            object["scopeID"] = .string(identifier)
        }
        if let proof {
            object["proof"] = .object([
                "keyID": .string(proof.keyID),
                "tag": .string(proof.tag.description)
            ])
        } else {
            object["proof"] = .null
        }
        return .object(object)
    }

    func wireJSON() -> String {
        wireJSONValue().canonicalJSON()
    }

    init(wireJSON: String) throws {
        guard wireJSON.utf8.count <= Self.maximumWireBytes else {
            throw SyncStoreError.payloadTooLarge(limit: Self.maximumWireBytes)
        }
        let value = try JSONValue.parse(
            wireJSON,
            maxBytes: Self.maximumWireBytes,
            maxNodes: Self.maximumWireNodes
        )
        try self.init(wireValue: value)
    }

    init(wireValue: JSONValue) throws {
        guard case .object(let object) = wireValue else {
            throw SyncStoreError.incrementalBatchInvalid("batch must be a JSON object")
        }
        guard let major = object["protocolMajor"]?.integerValue, major >= 1,
              let minor = object["protocolMinor"]?.integerValue, minor >= 0,
              let peerText = object["peerDeviceID"]?.stringValue,
              let receiverText = object["receiverDeviceID"]?.stringValue,
              let scopeKind = object["scopeKind"]?.stringValue,
              let versionText = object["subscriptionVersion"]?.stringValue,
              let version = Int64(versionText), version > 0,
              let fromText = object["fromCursor"]?.stringValue,
              let throughText = object["throughCursor"]?.stringValue,
              let changeValues = object["changes"]?.arrayValue else {
            throw SyncStoreError.incrementalBatchInvalid("batch fields are missing or mistyped")
        }
        let scope = try SnapshotScope.decode(
            kind: scopeKind,
            identifier: scopeKind == "all" ? nil : object["scopeID"]?.stringValue
        )
        var proof: IncrementalBatchProof?
        if let proofValue = object["proof"], proofValue != .null {
            guard case .object(let proofObject) = proofValue,
                  let keyID = proofObject["keyID"]?.stringValue,
                  let tagText = proofObject["tag"]?.stringValue else {
                throw SyncStoreError.incrementalBatchInvalid("proof is malformed")
            }
            proof = try IncrementalBatchProof(
                keyID: keyID,
                tag: IncrementalAuthenticationTag(validating: tagText)
            )
        }
        guard changeValues.count <= IncrementalBatch.maximumStructuralEntries else {
            throw SyncStoreError.batchTooLarge(
                limit: IncrementalBatch.maximumStructuralEntries
            )
        }
        var changes: [IncrementalChange] = []
        changes.reserveCapacity(changeValues.count)
        for changeValue in changeValues {
            guard case .object(let changeObject) = changeValue,
                  let cursorText = changeObject["cursor"]?.stringValue,
                  let recordValue = changeObject["record"] else {
                throw SyncStoreError.incrementalBatchInvalid("change entry is malformed")
            }
            changes.append(
                IncrementalChange(
                    sourceCursor: try ChangeCursor(decimalString: cursorText),
                    record: try IncrementalWire.decodeRecord(recordValue)
                )
            )
        }
        try self.init(
            protocolVersion: ProtocolVersion(major: Int(major), minor: Int(minor)),
            peerDeviceID: try DeviceID(validating: peerText),
            receiverDeviceID: try DeviceID(validating: receiverText),
            scope: scope,
            subscriptionVersion: version,
            fromCursor: try ChangeCursor(decimalString: fromText),
            throughCursor: try ChangeCursor(decimalString: throughText),
            changes: changes,
            proof: proof
        )
    }
}

enum IncrementalWire {
    static func recordValue(_ record: SyncRecord) -> JSONValue {
        .object([
            "kind": .string(record.kind.rawValue),
            "entityID": .string(record.entityID.canonical),
            "taskID": record.taskID.map { .string($0.canonical) } ?? .null,
            "workspaceID": record.workspaceID.map { .string($0.canonical) } ?? .null,
            "revision": .string(record.revision.decimalString),
            "baseRevision": record.baseRevision.map { .string($0.decimalString) } ?? .null,
            "baseDigest": record.baseDigest.map { .string($0.description) } ?? .null,
            "originDeviceID": .string(record.originDeviceID.canonical),
            "deleted": .bool(record.deleted),
            "payload": record.payload
        ])
    }

    static func decodeRecord(_ value: JSONValue) throws -> SyncRecord {
        guard case .object(let object) = value,
              let kindText = object["kind"]?.stringValue,
              let kind = SyncEntityKind(rawValue: kindText),
              let entityText = object["entityID"]?.stringValue,
              let revisionText = object["revision"]?.stringValue,
              let originText = object["originDeviceID"]?.stringValue,
              let deleted = object["deleted"]?.boolValue,
              let payload = object["payload"] else {
            throw SyncStoreError.incrementalBatchInvalid("record fields are missing or mistyped")
        }
        let taskID: TaskID?
        if let taskText = object["taskID"]?.stringValue {
            taskID = try TaskID(validating: taskText)
        } else {
            taskID = nil
        }
        let workspaceID: WorkspaceID?
        if let workspaceText = object["workspaceID"]?.stringValue {
            workspaceID = try WorkspaceID(validating: workspaceText)
        } else {
            workspaceID = nil
        }
        let baseRevision: Revision?
        if let baseText = object["baseRevision"]?.stringValue {
            baseRevision = try Revision(decimalString: baseText)
        } else {
            baseRevision = nil
        }
        let baseDigest: ContentDigest?
        if let digestText = object["baseDigest"]?.stringValue {
            baseDigest = try ContentDigest(validating: digestText)
        } else {
            baseDigest = nil
        }
        return SyncRecord(
            kind: kind,
            entityID: try EntityID(validating: entityText),
            taskID: taskID,
            workspaceID: workspaceID,
            revision: try Revision(decimalString: revisionText),
            baseRevision: baseRevision,
            baseDigest: baseDigest,
            originDeviceID: try DeviceID(validating: originText),
            payload: payload,
            deleted: deleted
        )
    }
}

// MARK: - Authentication boundary

/// Everything the trusted authenticator may inspect. The batch is untrusted
/// input; `authenticationDigest` is recomputed by the store from that exact
/// batch before the authenticator is asked to verify it.
public struct IncrementalAuthenticationRequest: Sendable {
    public let batch: IncrementalBatch
    public let authenticationDigest: ContentDigest

    public init(batch: IncrementalBatch, authenticationDigest: ContentDigest) {
        self.batch = batch
        self.authenticationDigest = authenticationDigest
    }
}

/// The authenticator's only output: which peer it authenticated and which
/// exact batch digest it verified. The store rejects any mismatch with the
/// batch value it will apply. `evidence` is a short non-secret diagnostic
/// label such as `hmac-sha256:pairing-key-2`.
public struct IncrementalAuthenticationResult: Sendable, Equatable {
    public let peerDeviceID: DeviceID
    public let authenticationDigest: ContentDigest
    public let evidence: String

    public init(
        peerDeviceID: DeviceID,
        authenticationDigest: ContentDigest,
        evidence: String
    ) throws {
        guard !evidence.isEmpty, evidence.utf8.count <= 128,
              !evidence.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw SyncStoreError.invalidAuthenticationProof(
                "authentication evidence must be a short printable label"
            )
        }
        self.peerDeviceID = peerDeviceID
        self.authenticationDigest = authenticationDigest
        self.evidence = evidence
    }
}

/// Trusted boundary between the package and the pairing/transport layer.
///
/// Implementations must derive `peerDeviceID` from state they own (a verified
/// TLS session, a pinned pairing identity, or a verified HMAC key registered
/// for that peer) and must verify the exact `authenticationDigest`. They must
/// never trust `batch.peerDeviceID` or a caller-supplied Boolean. A store with
/// no attached authenticator refuses every incremental batch.
public protocol IncrementalAuthenticator: Sendable {
    func authenticate(
        _ request: IncrementalAuthenticationRequest
    ) throws -> IncrementalAuthenticationResult
}

/// Production-usable proof verifier. Keys are supplied by the integration from
/// authenticated pairing state; they are not stored in the sync database and
/// are never part of a batch. Multiple key IDs per peer support rotation.
public struct HMACIncrementalAuthenticator: IncrementalAuthenticator {
    public struct PeerKey: Sendable {
        public let peerDeviceID: DeviceID
        public let keyID: String
        public let key: SyncProofKey

        public init(peerDeviceID: DeviceID, keyID: String, key: SyncProofKey) throws {
            try IncrementalProofKeyIdentifier.validate(keyID)
            self.peerDeviceID = peerDeviceID
            self.keyID = keyID
            self.key = key
        }
    }

    private struct Entry: Sendable {
        let peerDeviceID: DeviceID
        let key: SyncProofKey
    }

    private let entries: [String: Entry]

    /// Used only to detect cross-protocol key reuse between different peers.
    var effectivePeerKeys: [(DeviceID, [UInt8])] {
        entries.values.map { ($0.peerDeviceID, HMACSHA256.normalizeKey($0.key.bytes)) }
    }

    public init(peerKeys: [PeerKey]) throws {
        var entries: [String: Entry] = [:]
        var effectiveKeyOwners: [[UInt8]: DeviceID] = [:]
        for peerKey in peerKeys {
            guard entries[peerKey.keyID] == nil else {
                throw SyncStoreError.invalidAuthenticationProof(
                    "duplicate proof key ID \(peerKey.keyID)"
                )
            }
            // HMAC binds the claimed peer only when each effective key belongs
            // to one peer. A different key ID or zero padding does not make a
            // shared HMAC key cryptographically distinct.
            let effectiveKey = HMACSHA256.normalizeKey(peerKey.key.bytes)
            if let owner = effectiveKeyOwners[effectiveKey], owner != peerKey.peerDeviceID {
                throw SyncStoreError.invalidAuthenticationProof(
                    "an equivalent proof key is registered for more than one peer"
                )
            }
            effectiveKeyOwners[effectiveKey] = peerKey.peerDeviceID
            entries[peerKey.keyID] = Entry(
                peerDeviceID: peerKey.peerDeviceID,
                key: peerKey.key
            )
        }
        guard !entries.isEmpty else {
            throw SyncStoreError.invalidAuthenticationProof(
                "at least one trusted peer key is required"
            )
        }
        self.entries = entries
    }

    public func authenticate(
        _ request: IncrementalAuthenticationRequest
    ) throws -> IncrementalAuthenticationResult {
        guard let proof = request.batch.proof else {
            throw SyncStoreError.incrementalAuthenticationFailed("batch carries no proof")
        }
        guard let entry = entries[proof.keyID] else {
            throw SyncStoreError.incrementalAuthenticationFailed(
                "proof key \(proof.keyID) is not registered"
            )
        }
        guard entry.peerDeviceID == request.batch.peerDeviceID else {
            throw SyncStoreError.incrementalAuthenticationFailed(
                "proof key is not registered for the claimed peer"
            )
        }
        let recomputed = request.batch.authenticationDigest()
        guard recomputed == request.authenticationDigest else {
            throw SyncStoreError.incrementalAuthenticationFailed(
                "batch digest does not match the authenticated request"
            )
        }
        let message = IncrementalBatchDigest.proofMessage(recomputed)
        guard proof.tag.verify(key: entry.key, message: message) else {
            throw SyncStoreError.incrementalAuthenticationFailed("proof tag does not verify")
        }
        return try IncrementalAuthenticationResult(
            peerDeviceID: entry.peerDeviceID,
            authenticationDigest: recomputed,
            evidence: "hmac-sha256:\(proof.keyID)"
        )
    }
}

// MARK: - Receiver results and local authorization

/// A local user decision that one peer may synchronize one scope. Grants are
/// keyed by `(peerDeviceID, scope)` and never inferred from a batch, a
/// snapshot, or another device's grant. Revocation removes the row; the next
/// incremental batch fails closed while already-visible records are preserved.
public struct ScopeAuthorization: Sendable, Equatable {
    public let peerDeviceID: DeviceID
    public let scope: SnapshotScope
    public let grantedAt: Date
    public let updatedAt: Date

    public init(
        peerDeviceID: DeviceID,
        scope: SnapshotScope,
        grantedAt: Date,
        updatedAt: Date
    ) {
        self.peerDeviceID = peerDeviceID
        self.scope = scope
        self.grantedAt = grantedAt
        self.updatedAt = updatedAt
    }
}

public struct IncrementalApplyResult: Sendable, Equatable {
    public let peerDeviceID: DeviceID
    public let scope: SnapshotScope
    public let subscriptionVersion: Int64
    public let fromCursor: ChangeCursor
    public let throughCursor: ChangeCursor
    public let applied: [RecordKey]
    public let unchanged: [RecordKey]
    public let conflicts: [RecordConflict]
    /// True when the exact same batch content had already been committed.
    /// Receipts are bounded per subscription; an older replay outside the
    /// retained window is refused as a gap rather than reported as a duplicate.
    public let isDuplicate: Bool

    public init(
        peerDeviceID: DeviceID,
        scope: SnapshotScope,
        subscriptionVersion: Int64,
        fromCursor: ChangeCursor,
        throughCursor: ChangeCursor,
        applied: [RecordKey],
        unchanged: [RecordKey],
        conflicts: [RecordConflict],
        isDuplicate: Bool
    ) {
        self.peerDeviceID = peerDeviceID
        self.scope = scope
        self.subscriptionVersion = subscriptionVersion
        self.fromCursor = fromCursor
        self.throughCursor = throughCursor
        self.applied = applied
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.isDuplicate = isDuplicate
    }

    func wireJSONValue() -> JSONValue {
        .object([
            "peerDeviceID": .string(peerDeviceID.canonical),
            "scopeKind": .string(scope.kind),
            "scopeID": scope.identifier.map { .string($0) } ?? .null,
            "subscriptionVersion": .string(String(subscriptionVersion)),
            "fromCursor": .string(fromCursor.decimalString),
            "throughCursor": .string(throughCursor.decimalString),
            "applied": .array(applied.map(SnapshotDigest.recordKeyValue)),
            "unchanged": .array(unchanged.map(SnapshotDigest.recordKeyValue)),
            "conflicts": .array(conflicts.map(SnapshotDigest.conflictValue))
        ])
    }

    static func decode(wireValue: JSONValue, isDuplicate: Bool) throws -> IncrementalApplyResult {
        guard case .object(let object) = wireValue,
              let peerText = object["peerDeviceID"]?.stringValue,
              let scopeKind = object["scopeKind"]?.stringValue,
              let versionText = object["subscriptionVersion"]?.stringValue,
              let version = Int64(versionText),
              let fromText = object["fromCursor"]?.stringValue,
              let throughText = object["throughCursor"]?.stringValue,
              let appliedValues = object["applied"]?.arrayValue,
              let unchangedValues = object["unchanged"]?.arrayValue,
              let conflictValues = object["conflicts"]?.arrayValue else {
            throw SyncStoreError.incrementalReceiptCorrupt
        }
        return IncrementalApplyResult(
            peerDeviceID: try DeviceID(validating: peerText),
            scope: try SnapshotScope.decode(
                kind: scopeKind,
                identifier: object["scopeID"]?.stringValue
            ),
            subscriptionVersion: version,
            fromCursor: try ChangeCursor(decimalString: fromText),
            throughCursor: try ChangeCursor(decimalString: throughText),
            applied: try appliedValues.map(SnapshotDigest.decodeRecordKey),
            unchanged: try unchangedValues.map(SnapshotDigest.decodeRecordKey),
            conflicts: try conflictValues.map(SnapshotDigest.decodeConflict),
            isDuplicate: isDuplicate
        )
    }

    func withDuplicate(_ duplicate: Bool) -> IncrementalApplyResult {
        IncrementalApplyResult(
            peerDeviceID: peerDeviceID,
            scope: scope,
            subscriptionVersion: subscriptionVersion,
            fromCursor: fromCursor,
            throughCursor: throughCursor,
            applied: applied,
            unchanged: unchanged,
            conflicts: conflicts,
            isDuplicate: duplicate
        )
    }
}
