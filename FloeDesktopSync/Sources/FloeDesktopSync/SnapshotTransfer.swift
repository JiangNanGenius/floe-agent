import Foundation

/// One deterministic page in a sender's snapshot manifest.
///
/// The page index is zero-based and pages are contiguous. `firstPosition` and
/// `lastPosition` refer to the frozen `snapshot_entries.position` sequence, so
/// a receiver can reject a missing, duplicated or reordered page without
/// trusting the transport to report what it delivered.
public struct SnapshotPageManifest: Sendable, Equatable {
    public let pageIndex: Int
    public let firstPosition: Int64
    public let lastPosition: Int64
    public let entryCount: Int
    public let byteCount: Int
    public let digest: ContentDigest

    public init(
        pageIndex: Int,
        firstPosition: Int64,
        lastPosition: Int64,
        entryCount: Int,
        byteCount: Int,
        digest: ContentDigest
    ) {
        self.pageIndex = pageIndex
        self.firstPosition = firstPosition
        self.lastPosition = lastPosition
        self.entryCount = entryCount
        self.byteCount = byteCount
        self.digest = digest
    }
}

/// Complete description of one scoped snapshot. A receiver persists this
/// manifest before accepting any page. `digest` covers the snapshot identity,
/// scope, base cursor, counts and every page descriptor; it is an integrity
/// check, not a signature. Transport authentication must bind the peer
/// identity and protect the manifest in transit.
public struct SnapshotManifest: Sendable, Equatable {
    public let protocolVersion: ProtocolVersion
    public let snapshotID: SnapshotID
    public let originDeviceID: DeviceID
    public let subscriptionVersion: Int64
    public let scope: SnapshotScope
    public let baseCursor: ChangeCursor
    public let recordCount: Int
    public let tombstoneCount: Int
    public let entryCount: Int
    public let pageSize: Int
    public let pages: [SnapshotPageManifest]
    public let digest: ContentDigest
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        protocolVersion: ProtocolVersion = .v1,
        snapshotID: SnapshotID,
        originDeviceID: DeviceID,
        subscriptionVersion: Int64 = 1,
        scope: SnapshotScope,
        baseCursor: ChangeCursor,
        recordCount: Int,
        tombstoneCount: Int,
        entryCount: Int,
        pageSize: Int,
        pages: [SnapshotPageManifest],
        digest: ContentDigest,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.protocolVersion = protocolVersion
        self.snapshotID = snapshotID
        self.originDeviceID = originDeviceID
        self.subscriptionVersion = subscriptionVersion
        self.scope = scope
        self.baseCursor = baseCursor
        self.recordCount = recordCount
        self.tombstoneCount = tombstoneCount
        self.entryCount = entryCount
        self.pageSize = pageSize
        self.pages = pages
        self.digest = digest
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }

    public var pageCount: Int { pages.count }

    /// Structural checks plus a full digest recomputation. Unknown optional
    /// wire fields are ignored for minor-version compatibility, but every
    /// field that changes the covered set must be internally consistent.
    public func validate() throws {
        guard subscriptionVersion > 0 else {
            throw SyncStoreError.invalidSubscriptionVersion(subscriptionVersion)
        }
        guard protocolVersion.major == 1, protocolVersion.minor >= 0 else {
            throw SyncStoreError.unsupportedProtocolVersion(
                major: protocolVersion.major,
                minor: protocolVersion.minor
            )
        }
        guard recordCount >= 0, tombstoneCount >= 0, entryCount >= 0,
              tombstoneCount <= Int.max - recordCount else {
            throw SyncStoreError.snapshotManifestInvalid("counts must not be negative or overflow")
        }
        guard entryCount == recordCount + tombstoneCount else {
            throw SyncStoreError.snapshotManifestInvalid(
                "entry count does not equal live plus tombstone counts"
            )
        }
        guard pageSize >= 1 else {
            throw SyncStoreError.snapshotManifestInvalid("pageSize must be positive")
        }
        guard createdAt <= expiresAt else {
            throw SyncStoreError.snapshotManifestInvalid("snapshot expiry precedes its creation")
        }
        if entryCount == 0 {
            guard pages.isEmpty else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "an empty snapshot cannot declare pages"
                )
            }
        } else {
            guard !pages.isEmpty else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "a non-empty snapshot must declare at least one page"
                )
            }
        }
        var expectedPosition: Int64 = 1
        var entries = 0
        for (index, page) in pages.enumerated() {
            guard page.pageIndex == index else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(index) is out of order or duplicated"
                )
            }
            guard page.entryCount >= 1, page.byteCount >= 0,
                  page.entryCount <= pageSize,
                  entries <= Int.max - page.entryCount else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(index) has an invalid entry or byte count"
                )
            }
            guard page.firstPosition == expectedPosition else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(index) does not start at the next frozen position"
                )
            }
            let count = Int64(page.entryCount)
            guard page.firstPosition <= Int64.max - count,
                  page.firstPosition + count < Int64.max else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(index) position range overflows"
                )
            }
            let last = page.firstPosition + count - 1
            guard last == page.lastPosition else {
                throw SyncStoreError.snapshotManifestInvalid(
                    "page \(index) position range does not match its entry count"
                )
            }
            entries += page.entryCount
            expectedPosition = last + 1
        }
        guard entries == entryCount,
              entryCount == 0 || pages.last?.lastPosition == Int64(entryCount) else {
            throw SyncStoreError.snapshotManifestInvalid(
                "pages do not cover the complete snapshot entry set"
            )
        }
        let computed = SnapshotDigest.manifestDigest(
            protocolVersion: protocolVersion,
            snapshotID: snapshotID,
            originDeviceID: originDeviceID,
            scope: scope,
            baseCursor: baseCursor,
            recordCount: recordCount,
            tombstoneCount: tombstoneCount,
            entryCount: entryCount,
            pageSize: pageSize,
            pages: pages,
            createdAt: createdAt,
            expiresAt: expiresAt,
            subscriptionVersion: subscriptionVersion
        )
        guard computed == digest else {
            throw SyncStoreError.snapshotManifestDigestMismatch
        }
    }

    public func wireJSONValue() -> JSONValue {
        var object: [String: JSONValue] = [
            "protocolMajor": .integer(Int64(protocolVersion.major)),
            "protocolMinor": .integer(Int64(protocolVersion.minor)),
            "snapshotID": .string(snapshotID.canonical),
            "originDeviceID": .string(originDeviceID.canonical),
            "subscriptionVersion": .string(String(subscriptionVersion)),
            "scopeKind": .string(scope.kind),
            "baseCursor": .string(baseCursor.decimalString),
            "recordCount": .string(String(recordCount)),
            "tombstoneCount": .string(String(tombstoneCount)),
            "entryCount": .string(String(entryCount)),
            "pageSize": .string(String(pageSize)),
            "digest": .string(digest.description),
            "createdAt": .string(SyncWireTime.rfc3339(createdAt)),
            "expiresAt": .string(SyncWireTime.rfc3339(expiresAt)),
            "pages": .array(pages.map { page in
                .object([
                    "pageIndex": .string(String(page.pageIndex)),
                    "firstPosition": .string(String(page.firstPosition)),
                    "lastPosition": .string(String(page.lastPosition)),
                    "entryCount": .string(String(page.entryCount)),
                    "byteCount": .string(String(page.byteCount)),
                    "digest": .string(page.digest.description)
                ])
            })
        ]
        if let identifier = scope.identifier {
            object["scopeID"] = .string(identifier)
        }
        return .object(object)
    }

    public func wireJSON() -> String {
        wireJSONValue().canonicalJSON()
    }

    public init(wireJSON: String) throws {
        guard wireJSON.utf8.count <= SyncStore.maximumManifestBytes else {
            throw SyncStoreError.payloadTooLarge(limit: SyncStore.maximumManifestBytes)
        }
        let value = try JSONValue.parse(
            wireJSON,
            maxBytes: SyncStore.maximumManifestBytes,
            maxNodes: SyncStore.maximumManifestNodes
        )
        try self.init(wireValue: value)
    }

    public init(wireValue: JSONValue) throws {
        guard case .object(let object) = wireValue else {
            throw SyncStoreError.snapshotManifestInvalid("manifest must be a JSON object")
        }
        guard let major = object["protocolMajor"]?.integerValue, major >= 1,
              let minor = object["protocolMinor"]?.integerValue, minor >= 0,
              let snapshotID = object["snapshotID"]?.stringValue,
              let originDeviceID = object["originDeviceID"]?.stringValue,
              let subscriptionVersionText = object["subscriptionVersion"]?.stringValue,
              let subscriptionVersion = Int64(subscriptionVersionText), subscriptionVersion > 0,
              let scopeKind = object["scopeKind"]?.stringValue,
              let baseCursor = object["baseCursor"]?.stringValue,
              let recordCount = object["recordCount"]?.stringValue,
              let tombstoneCount = object["tombstoneCount"]?.stringValue,
              let entryCount = object["entryCount"]?.stringValue,
              let pageSize = object["pageSize"]?.stringValue,
              let digestText = object["digest"]?.stringValue,
              let createdAt = object["createdAt"]?.stringValue,
              let expiresAt = object["expiresAt"]?.stringValue,
              let pagesValue = object["pages"]?.arrayValue else {
            throw SyncStoreError.snapshotManifestInvalid("manifest fields are missing or mistyped")
        }
        guard let recordCountValue = Int(recordCount), recordCountValue >= 0,
              let tombstoneValue = Int(tombstoneCount), tombstoneValue >= 0,
              let entryCountValue = Int(entryCount), entryCountValue >= 0,
              let pageSizeValue = Int(pageSize), pageSizeValue >= 1 else {
            throw SyncStoreError.snapshotManifestInvalid("manifest counts are not decimal integers")
        }
        let scope = try SnapshotScope.decode(
            kind: scopeKind,
            identifier: scopeKind == "all" ? nil : object["scopeID"]?.stringValue
        )
        var pages: [SnapshotPageManifest] = []
        pages.reserveCapacity(pagesValue.count)
        for pageValue in pagesValue {
            guard case .object(let pageObject) = pageValue,
                  let indexText = pageObject["pageIndex"]?.stringValue,
                  let firstText = pageObject["firstPosition"]?.stringValue,
                  let lastText = pageObject["lastPosition"]?.stringValue,
                  let countText = pageObject["entryCount"]?.stringValue,
                  let bytesText = pageObject["byteCount"]?.stringValue,
                  let pageDigestText = pageObject["digest"]?.stringValue,
                  let index = Int(indexText), index >= 0,
                  let first = Int64(firstText), first >= 1,
                  let last = Int64(lastText), last >= first,
                  let count = Int(countText), count >= 1,
                  let bytes = Int(bytesText), bytes >= 0 else {
                throw SyncStoreError.snapshotManifestInvalid("page descriptor is malformed")
            }
            pages.append(
                SnapshotPageManifest(
                    pageIndex: index,
                    firstPosition: first,
                    lastPosition: last,
                    entryCount: count,
                    byteCount: bytes,
                    digest: try ContentDigest(validating: pageDigestText)
                )
            )
        }
        self.init(
            protocolVersion: ProtocolVersion(major: Int(major), minor: Int(minor)),
            snapshotID: try SnapshotID(validating: snapshotID),
            originDeviceID: try DeviceID(validating: originDeviceID),
            subscriptionVersion: subscriptionVersion,
            scope: scope,
            baseCursor: try ChangeCursor(decimalString: baseCursor),
            recordCount: recordCountValue,
            tombstoneCount: tombstoneValue,
            entryCount: entryCountValue,
            pageSize: pageSizeValue,
            pages: pages,
            digest: try ContentDigest(validating: digestText),
            createdAt: try SyncWireTime.parseRFC3339(createdAt),
            expiresAt: try SyncWireTime.parseRFC3339(expiresAt)
        )
        try validate()
    }
}

/// One transport page. Its content digest must equal both the envelope digest
/// and the matching page digest from the manifest; positions are checked
/// against the manifest before any row is staged.
public struct SnapshotPageEnvelope: Sendable, Equatable {
    public let snapshotID: SnapshotID
    public let originDeviceID: DeviceID
    public let pageIndex: Int
    public let firstPosition: Int64
    public let lastPosition: Int64
    public let records: [SyncRecord]
    public let digest: ContentDigest
    public let manifestDigest: ContentDigest?

    public init(
        snapshotID: SnapshotID,
        originDeviceID: DeviceID,
        pageIndex: Int,
        firstPosition: Int64,
        lastPosition: Int64,
        records: [SyncRecord],
        digest: ContentDigest,
        manifestDigest: ContentDigest? = nil
    ) {
        self.snapshotID = snapshotID
        self.originDeviceID = originDeviceID
        self.pageIndex = pageIndex
        self.firstPosition = firstPosition
        self.lastPosition = lastPosition
        self.records = records
        self.digest = digest
        self.manifestDigest = manifestDigest
    }

    public func computedDigest() -> ContentDigest {
        SnapshotDigest.pageDigest(records)
    }
}

public enum SnapshotImportState: String, Sendable, Equatable {
    case staging
    case committed
}

/// Receiver-side view of one subscription scope. `appliedCursor` is in the
/// peer's change sequence for this exact scope; the legacy per-peer global
/// cursor is kept separate and is never used to claim complete scope sync.
public struct SyncSubscription: Sendable, Equatable {
    public let peerDeviceID: DeviceID
    public let scope: SnapshotScope
    public let version: Int64
    public let appliedCursor: ChangeCursor
    public let established: Bool
    public let lastSnapshotID: SnapshotID?
    public let updatedAt: Date

    public init(
        peerDeviceID: DeviceID,
        scope: SnapshotScope,
        version: Int64,
        appliedCursor: ChangeCursor,
        established: Bool,
        lastSnapshotID: SnapshotID?,
        updatedAt: Date
    ) {
        self.peerDeviceID = peerDeviceID
        self.scope = scope
        self.version = version
        self.appliedCursor = appliedCursor
        self.established = established
        self.lastSnapshotID = lastSnapshotID
        self.updatedAt = updatedAt
    }
}

/// Durable progress for an inbound snapshot. A staging row is advanced page by
/// page in its own transaction; a process restart resumes from this record
/// rather than from a caller's assertion.
public struct SnapshotImportProgress: Sendable, Equatable {
    public let peerDeviceID: DeviceID
    public let snapshotID: SnapshotID
    public let scope: SnapshotScope
    public let subscriptionVersion: Int64
    public let baseCursor: ChangeCursor
    public let pageCount: Int
    public let receivedPageCount: Int
    public let receivedEntryCount: Int
    public let stagedBytes: Int
    public let state: SnapshotImportState
    public let expiresAt: Date
    public let committedResult: SnapshotImportResult?

    public init(
        peerDeviceID: DeviceID,
        snapshotID: SnapshotID,
        scope: SnapshotScope,
        subscriptionVersion: Int64,
        baseCursor: ChangeCursor,
        pageCount: Int,
        receivedPageCount: Int,
        receivedEntryCount: Int,
        stagedBytes: Int,
        state: SnapshotImportState,
        expiresAt: Date,
        committedResult: SnapshotImportResult?
    ) {
        self.peerDeviceID = peerDeviceID
        self.snapshotID = snapshotID
        self.scope = scope
        self.subscriptionVersion = subscriptionVersion
        self.baseCursor = baseCursor
        self.pageCount = pageCount
        self.receivedPageCount = receivedPageCount
        self.receivedEntryCount = receivedEntryCount
        self.stagedBytes = stagedBytes
        self.state = state
        self.expiresAt = expiresAt
        self.committedResult = committedResult
    }

    public var isComplete: Bool {
        state == .committed || (pageCount > 0 && receivedPageCount == pageCount)
            || (pageCount == 0 && receivedPageCount == 0)
    }
}

public struct SnapshotImportResult: Sendable, Equatable {
    public let snapshotID: SnapshotID
    public let scope: SnapshotScope
    public let subscriptionVersion: Int64
    public let baseCursor: ChangeCursor
    public let applied: [RecordKey]
    public let unchanged: [RecordKey]
    public let conflicts: [RecordConflict]
    /// Local rows inside the scope that were absent from the complete snapshot
    /// set. They are preserved and reported; absence is not treated as a
    /// tombstone because the source never proved it saw them.
    public let unreconciledLocalKeys: [RecordKey]
    /// True when the caller retried a commit that had already succeeded.
    public let isDuplicate: Bool

    public init(
        snapshotID: SnapshotID,
        scope: SnapshotScope,
        subscriptionVersion: Int64,
        baseCursor: ChangeCursor,
        applied: [RecordKey],
        unchanged: [RecordKey],
        conflicts: [RecordConflict],
        unreconciledLocalKeys: [RecordKey],
        isDuplicate: Bool
    ) {
        self.snapshotID = snapshotID
        self.scope = scope
        self.subscriptionVersion = subscriptionVersion
        self.baseCursor = baseCursor
        self.applied = applied
        self.unchanged = unchanged
        self.conflicts = conflicts
        self.unreconciledLocalKeys = unreconciledLocalKeys
        self.isDuplicate = isDuplicate
    }

    func wireJSONValue() -> JSONValue {
        .object([
            "snapshotID": .string(snapshotID.canonical),
            "scopeKind": .string(scope.kind),
            "scopeID": scope.identifier.map { .string($0) } ?? .null,
            "subscriptionVersion": .string(String(subscriptionVersion)),
            "baseCursor": .string(baseCursor.decimalString),
            "applied": .array(applied.map(SnapshotDigest.recordKeyValue)),
            "unchanged": .array(unchanged.map(SnapshotDigest.recordKeyValue)),
            "conflicts": .array(conflicts.map(SnapshotDigest.conflictValue)),
            "unreconciledLocalKeys": .array(
                unreconciledLocalKeys.map(SnapshotDigest.recordKeyValue)
            )
        ])
    }

    static func decode(wireValue: JSONValue, isDuplicate: Bool) throws -> SnapshotImportResult {
        guard case .object(let object) = wireValue,
              let snapshotText = object["snapshotID"]?.stringValue,
              let scopeKind = object["scopeKind"]?.stringValue,
              let versionText = object["subscriptionVersion"]?.stringValue,
              let version = Int64(versionText),
              let baseText = object["baseCursor"]?.stringValue,
              let appliedValues = object["applied"]?.arrayValue,
              let unchangedValues = object["unchanged"]?.arrayValue,
              let conflictValues = object["conflicts"]?.arrayValue,
              let unreconciledValues = object["unreconciledLocalKeys"]?.arrayValue else {
            throw SyncStoreError.snapshotImportReceiptCorrupt
        }
        let scope = try SnapshotScope.decode(
            kind: scopeKind,
            identifier: object["scopeID"]?.stringValue
        )
        return SnapshotImportResult(
            snapshotID: try SnapshotID(validating: snapshotText),
            scope: scope,
            subscriptionVersion: version,
            baseCursor: try ChangeCursor(decimalString: baseText),
            applied: try appliedValues.map(SnapshotDigest.decodeRecordKey),
            unchanged: try unchangedValues.map(SnapshotDigest.decodeRecordKey),
            conflicts: try conflictValues.map(SnapshotDigest.decodeConflict),
            unreconciledLocalKeys: try unreconciledValues.map(SnapshotDigest.decodeRecordKey),
            isDuplicate: isDuplicate
        )
    }

    func withDuplicate(_ duplicate: Bool) -> SnapshotImportResult {
        SnapshotImportResult(
            snapshotID: snapshotID,
            scope: scope,
            subscriptionVersion: subscriptionVersion,
            baseCursor: baseCursor,
            applied: applied,
            unchanged: unchanged,
            conflicts: conflicts,
            unreconciledLocalKeys: unreconciledLocalKeys,
            isDuplicate: duplicate
        )
    }
}

/// Canonical record/page/manifest digests shared by sender and receiver. The
/// digest descriptor deliberately covers identity, scope, revision, causal
/// baseline, deletion and payload bytes; two records with the same payload but
/// different identity cannot collide in a page digest.
enum SnapshotDigest {
    static func recordDescriptor(_ record: SyncRecord) -> JSONValue {
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
            "payloadDigest": .string(
                ContentDigest.compute(record.payload.canonicalUTF8).description
            )
        ])
    }

    static func pageDigest(_ records: [SyncRecord]) -> ContentDigest {
        ContentDigest.compute(
            JSONValue.array(records.map(recordDescriptor)).canonicalUTF8
        )
    }

    static func manifestDigest(
        protocolVersion: ProtocolVersion,
        snapshotID: SnapshotID,
        originDeviceID: DeviceID,
        scope: SnapshotScope,
        baseCursor: ChangeCursor,
        recordCount: Int,
        tombstoneCount: Int,
        entryCount: Int,
        pageSize: Int,
        pages: [SnapshotPageManifest],
        createdAt: Date,
        expiresAt: Date,
        subscriptionVersion: Int64 = 1
    ) -> ContentDigest {
        let header: [String: JSONValue] = [
            "protocolMajor": .integer(Int64(protocolVersion.major)),
            "protocolMinor": .integer(Int64(protocolVersion.minor)),
            "snapshotID": .string(snapshotID.canonical),
            "originDeviceID": .string(originDeviceID.canonical),
            "subscriptionVersion": .string(String(subscriptionVersion)),
            "scopeKind": .string(scope.kind),
            "scopeID": scope.identifier.map { .string($0) } ?? .null,
            "baseCursor": .string(baseCursor.decimalString),
            "recordCount": .string(String(recordCount)),
            "tombstoneCount": .string(String(tombstoneCount)),
            "entryCount": .string(String(entryCount)),
            "pageSize": .string(String(pageSize)),
            "createdAt": .string(SyncWireTime.rfc3339(createdAt)),
            "expiresAt": .string(SyncWireTime.rfc3339(expiresAt)),
            "pages": .array(pages.map { page in
                .object([
                    "pageIndex": .string(String(page.pageIndex)),
                    "firstPosition": .string(String(page.firstPosition)),
                    "lastPosition": .string(String(page.lastPosition)),
                    "entryCount": .string(String(page.entryCount)),
                    "byteCount": .string(String(page.byteCount)),
                    "digest": .string(page.digest.description)
                ])
            })
        ]
        return ContentDigest.compute(JSONValue.object(header).canonicalUTF8)
    }

    static func recordKeyValue(_ key: RecordKey) -> JSONValue {
        .object([
            "kind": .string(key.kind.rawValue),
            "entityID": .string(key.entityID.canonical)
        ])
    }

    static func decodeRecordKey(_ value: JSONValue) throws -> RecordKey {
        guard let kindText = value["kind"]?.stringValue,
              let kind = SyncEntityKind(rawValue: kindText),
              let entityText = value["entityID"]?.stringValue else {
            throw SyncStoreError.snapshotImportReceiptCorrupt
        }
        return RecordKey(kind: kind, entityID: try EntityID(validating: entityText))
    }

    static func conflictValue(_ conflict: RecordConflict) -> JSONValue {
        .object([
            "conflictID": conflict.conflictID.map { .string($0.canonical) } ?? .null,
            "kind": .string(conflict.key.kind.rawValue),
            "entityID": .string(conflict.key.entityID.canonical),
            "incomingRevision": .string(conflict.incomingRevision.decimalString),
            "localRevision": .string(conflict.localRevision.decimalString),
            "reason": .string(conflict.reason.rawValue)
        ])
    }

    static func decodeConflict(_ value: JSONValue) throws -> RecordConflict {
        guard let kindText = value["kind"]?.stringValue,
              let kind = SyncEntityKind(rawValue: kindText),
              let entityText = value["entityID"]?.stringValue,
              let incomingText = value["incomingRevision"]?.stringValue,
              let localText = value["localRevision"]?.stringValue,
              let reasonText = value["reason"]?.stringValue,
              let reason = ConflictReason(rawValue: reasonText) else {
            throw SyncStoreError.snapshotImportReceiptCorrupt
        }
        let conflictID: ConflictID?
        if let text = value["conflictID"]?.stringValue {
            conflictID = try ConflictID(validating: text)
        } else {
            conflictID = nil
        }
        return RecordConflict(
            conflictID: conflictID,
            key: RecordKey(kind: kind, entityID: try EntityID(validating: entityText)),
            incomingRevision: try Revision(decimalString: incomingText),
            localRevision: try Revision(decimalString: localText),
            reason: reason
        )
    }
}
