// Typed CAD/drawing revision history kept on the canvas node.
//
// Every DWG/DXF version the node adopts is recorded here as an immutable
// reference (asset id + content hash + stored path), including the original
// document. The list itself lives inside `CanvasNode.metadata`, so it
// survives app restarts and canvas sync; the bytes it points at are ordinary
// creative assets that the backup package carries explicitly.
//
// Reverting to an older version never overwrites history: it adopts those
// bytes as a NEW revision (kind `.restore`) pointing back at the source
// revision. Old nodes that pre-date this contract get their original seeded
// lazily on the next adopt, while the live node still carries those bytes.

import Foundation

/// One adopted CAD revision for a drawing node.
public struct CanvasDrawingRevision: Codable, Sendable, Identifiable, Hashable {
    public static let currentSchemaVersion = 1

    /// How the revision entered the node's history.
    public enum Kind: String, Codable, Sendable {
        /// The immutable original document the node first carried.
        case original
        /// User edits applied through the CAD editor ("Finish").
        case adopt
        /// A restore of an older revision, adopted as a new current version.
        case restore
        /// A separately created variant node's starting document.
        case variant
    }

    public var schemaVersion: Int
    public var id: UUID
    public var assetID: UUID
    public var contentHash: String
    /// Stored path of the immutable revision bytes
    /// (Materials/<name> or WorkbenchRoot/...).
    public var relativePath: String
    public var byteCount: Int64
    public var createdAt: Date
    public var kind: Kind
    /// Optional user-facing label.
    public var label: String?
    /// For `.restore`: the revision these bytes were taken from.
    public var sourceRevisionID: UUID?

    public init(schemaVersion: Int = CanvasDrawingRevision.currentSchemaVersion,
                id: UUID = UUID(), assetID: UUID, contentHash: String,
                relativePath: String, byteCount: Int64, createdAt: Date = Date(),
                kind: Kind, label: String? = nil, sourceRevisionID: UUID? = nil) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.assetID = assetID
        self.contentHash = contentHash
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.kind = kind
        self.label = label
        self.sourceRevisionID = sourceRevisionID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, assetID, contentHash, relativePath, byteCount
        case createdAt, kind, label, sourceRevisionID
    }

    // Revision lists written before a field existed decode with defaults.
    // An UNKNOWN kind is a decoding failure (never silently mapped to
    // `.adopt`): the raw metadata is then preserved read-only.
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try values.decode(UUID.self, forKey: .id)
        assetID = try values.decode(UUID.self, forKey: .assetID)
        contentHash = try values.decode(String.self, forKey: .contentHash)
        relativePath = try values.decode(String.self, forKey: .relativePath)
        byteCount = try values.decodeIfPresent(Int64.self, forKey: .byteCount) ?? 0
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        let rawKind = try values.decode(String.self, forKey: .kind)
        guard let decodedKind = Kind(rawValue: rawKind) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: values,
                debugDescription: "Unknown CAD revision kind \(rawKind)")
        }
        kind = decodedKind
        label = try values.decodeIfPresent(String.self, forKey: .label)
        sourceRevisionID = try values.decodeIfPresent(UUID.self, forKey: .sourceRevisionID)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(id, forKey: .id)
        try values.encode(assetID, forKey: .assetID)
        try values.encode(contentHash, forKey: .contentHash)
        try values.encode(relativePath, forKey: .relativePath)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(kind, forKey: .kind)
        try values.encodeIfPresent(label, forKey: .label)
        try values.encodeIfPresent(sourceRevisionID, forKey: .sourceRevisionID)
    }
}

/// Read outcome: distinguishes "no history yet" from usable history and
/// raw metadata this build cannot safely interpret (malformed, unknown
/// kind, higher schema). Callers that append/mutate history MUST use this
/// and refuse mutation instead of overwriting raw metadata after an empty
/// filtered read.
public enum CanvasDrawingHistoryRead: Equatable {
    /// No history entry exists; a fresh list may be created.
    case absent
    /// A readable, fully version-compatible, validated list.
    case usable([CanvasDrawingRevision])
    /// Raw metadata preserved read-only (never overwrite).
    case unsupported(raw: String, reason: String)
}

/// Pure history policy: read, seed and append typed CAD revisions.
public enum CanvasDrawingRevisionHistory {
    public static let metadataKey = "canvas.cad.revisions"

    public static let maximumRevisionsPerNode = 200
    public static let maximumLabelCharacters = 200
    public static let hashCharacterCount = 64

    /// Reads and validates the history entry on a node without mutating.
    public static func read(from node: CanvasNode) -> CanvasDrawingHistoryRead {
        guard let raw = node.metadata[metadataKey] else { return .absent }
        guard let data = raw.data(using: .utf8) else {
            return .unsupported(raw: raw, reason: "malformed")
        }
        guard let list = try? JSONDecoder().decode([CanvasDrawingRevision].self, from: data) else {
            return .unsupported(raw: raw, reason: "malformed")
        }
        // A single higher-schema entry makes closure unknowable: the whole
        // list is preserved read-only, never filtered silently.
        for revision in list where revision.schemaVersion > CanvasDrawingRevision.currentSchemaVersion {
            return .unsupported(raw: raw, reason: "unsupportedSchema")
        }
        do {
            try validate(list)
        } catch let error as FloeError {
            return .unsupported(raw: raw, reason: error.reason)
        } catch {
            return .unsupported(raw: raw, reason: "invalid")
        }
        return .usable(list)
    }

    /// Structural validation: bounded counts, unique ids, hex hashes, safe
    /// contained paths, consistent restore references and size limits.
    public static func validate(_ revisions: [CanvasDrawingRevision]) throws {
        guard revisions.count <= maximumRevisionsPerNode else {
            throw FloeError.invalidConfiguration("tooManyRevisions")
        }
        var seenIDs = Set<UUID>()
        for revision in revisions {
            guard revision.schemaVersion >= 1,
                  seenIDs.insert(revision.id).inserted else {
                throw FloeError.invalidConfiguration("duplicateOrInvalidRevisionID")
            }
            guard revision.contentHash.count == hashCharacterCount,
                  revision.contentHash.allSatisfy({ $0.isHexDigit }),
                  revision.byteCount >= 0 else {
                throw FloeError.invalidConfiguration("invalidRevisionHashOrSize")
            }
            guard isValidStoredPath(revision.relativePath) else {
                throw FloeError.invalidConfiguration("invalidRevisionPath")
            }
            if let label = revision.label {
                guard label.count <= maximumLabelCharacters else {
                    throw FloeError.invalidConfiguration("revisionLabelTooLong")
                }
            }
            if revision.kind == .restore {
                guard let sourceID = revision.sourceRevisionID,
                      sourceID != revision.id,
                      contains(sourceID, in: revisions) else {
                    throw FloeError.invalidConfiguration("invalidRestoreReference")
                }
            }
        }
    }

    private static func contains(_ id: UUID, in revisions: [CanvasDrawingRevision]) -> Bool {
        revisions.contains { $0.id == id }
    }

    /// True for a Materials/ filename-only or WorkbenchRoot/ relative path
    /// with no escapes.
    public static func isValidStoredPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("..") else { return false }
        if path.hasPrefix("Materials/") {
            let fileName = String(path.dropFirst("Materials/".count))
            return !fileName.isEmpty && !fileName.contains("/")
        }
        if path.hasPrefix("WorkbenchRoot/") {
            let suffix = String(path.dropFirst("WorkbenchRoot/".count))
            return !suffix.isEmpty && !suffix.hasSuffix("/")
        }
        return false
    }

    /// Convenience: usable revisions, or an empty list. NEVER use this to
    /// decide whether a mutation is safe — check `read(from:)` for that.
    public static func revisions(from node: CanvasNode) -> [CanvasDrawingRevision] {
        guard case .usable(let list) = read(from: node) else { return [] }
        return list
    }

    /// True only when the node carries a readable validated list.
    public static func hasUsableHistory(on node: CanvasNode) -> Bool {
        if case .usable = read(from: node) { return true }
        return false
    }

    /// Appends a revision; a duplicate id replaces that entry instead of
    /// duplicating. Order is chronological.
    public static func appending(
        _ revision: CanvasDrawingRevision,
        to revisions: [CanvasDrawingRevision]
    ) throws -> [CanvasDrawingRevision] {
        var updated = revisions
        if let index = updated.firstIndex(where: { $0.id == revision.id }) {
            updated[index] = revision
        } else {
            updated.append(revision)
        }
        try validate(updated)
        return updated
    }

    /// The immutable original revision for a node that has no history yet,
    /// built from the bytes the node currently carries. Returns nil when the
    /// node lacks a bounded drawing asset.
    public static func seedOriginal(for node: CanvasNode) -> CanvasDrawingRevision? {
        guard CanvasDrawingNodePlanner.isDrawingNode(node)
                || CADCanvasNodePlanner.isNativeCADAsset(node.asset),
              let asset = node.asset,
              let hash = asset.contentHash, !hash.isEmpty,
              let path = asset.localRelativePath,
              isValidStoredPath(path) else { return nil }
        return CanvasDrawingRevision(
            assetID: asset.id,
            contentHash: hash,
            relativePath: path,
            byteCount: asset.byteCount ?? 0,
            kind: .original,
            label: nil)
    }

    /// Encodes the history list into a node metadata entry.
    public static func metadata(_ revisions: [CanvasDrawingRevision]) throws -> [String: String] {
        try validate(revisions)
        let data = try JSONEncoder().encode(revisions)
        guard let raw = String(data: data, encoding: .utf8) else {
            throw FloeError.internalError("Could not encode CAD revision history")
        }
        return [metadataKey: raw]
    }

    /// Refuses when any drawing node in the project carries history this
    /// build cannot close (malformed/unsupported raw metadata). Export and
    /// mutation callers run this so history bytes are never silently omitted
    /// from a successful backup.
    public static func requireClosableHistory(in project: CanvasProject) throws {
        for document in project.documents {
            for node in document.nodes where carriesCADHistory(node) {
                if case .unsupported = read(from: node) {
                    throw FloeError.invalidConfiguration("unsupportedCADHistory")
                }
            }
        }
    }

    /// Distinct stored revision paths carried by every drawing node in the
    /// project, in deterministic order. Callers must first run
    /// `requireClosableHistory(in:)` so this set is provably complete.
    public static func revisionRelativePaths(in project: CanvasProject) -> [String] {
        var paths = Set<String>()
        for document in project.documents {
            for node in document.nodes where carriesCADHistory(node) {
                for revision in revisions(from: node) {
                    guard isValidStoredPath(revision.relativePath) else { continue }
                    paths.insert(revision.relativePath)
                }
            }
        }
        return Array(paths).sorted()
    }

    /// Rewrites stored revision paths (e.g. after backup restore remaps a
    /// collision) inside the given list.
    public static func remapping(
        _ revisions: [CanvasDrawingRevision],
        pathRemap: [String: String]
    ) throws -> [CanvasDrawingRevision] {
        let updated = revisions.map { revision -> CanvasDrawingRevision in
            guard let mapped = pathRemap[revision.relativePath],
                  mapped != revision.relativePath else { return revision }
            var changed = revision
            changed.relativePath = mapped
            return changed
        }
        try validate(updated)
        return updated
    }

    /// True for any node that may carry typed CAD history: a DWG/DXF drawing
    /// node or a native `.floecad` node (whose live asset becomes the PNG
    /// render while its history keeps the package revisions).
    static func carriesCADHistory(_ node: CanvasNode) -> Bool {
        CanvasDrawingNodePlanner.isDrawingNode(node)
            || CADCanvasNodePlanner.isNativeCADNode(node)
    }

    /// Every asset reference reachable in the project as a multiset:
    /// each node's current asset PLUS each typed CAD revision reference.
    /// An asset carried both as current and as a historical revision is
    /// counted twice (two independent owners). Used to reconcile creative
    /// asset reference counts so zero-count pruning can never remove bytes
    /// that revision history still reaches.
    public static func reachableAssetReferences(in project: CanvasProject) -> [UUID] {
        var result: [UUID] = []
        for document in project.documents {
            for node in document.nodes {
                if let currentID = node.asset?.id {
                    result.append(currentID)
                }
                if carriesCADHistory(node),
                   case .usable(let revisions) = read(from: node) {
                    result.append(contentsOf: revisions.map(\.assetID))
                }
            }
        }
        return result
    }

    /// Per-asset change in reachable references between two project states.
    /// Positive values require an increment, negative a decrement. Callers
    /// apply this through the creative asset store in the same unit of work.
    public static func reachableDeltas(
        from before: CanvasProject, to after: CanvasProject
    ) -> [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for id in reachableAssetReferences(in: before) {
            counts[id, default: 0] -= 1
        }
        for id in reachableAssetReferences(in: after) {
            counts[id, default: 0] += 1
        }
        return counts.filter { $0.value != 0 }
    }
}

/// Bounded, crash-resumable application of reachable-reference deltas.
///
/// Each scheduled delta becomes an op with a STABLE id. Consumers persist
/// the pending ops durably beside the authoritative project file and apply
/// them through `CreativeAssetStore.applyReferenceOp`, which records the op
/// receipt and the `reference_count` update in the SAME SQLite transaction:
/// a crash either applies both or neither, and a replayed op id is a no-op
/// instead of double-applying its delta. The on-disk op journal is only a
/// progress hint — the receipts are the source of truth — so a lost or
/// stale journal can never under-count by replaying.
///
/// One pass applies increments before decrements; when ANY increment fails,
/// every decrement op is retained unapplied, so an asset can never be
/// decremented into a pruning state while a prerequisite increment is still
/// owed. A failed pass returns `completed == false` and retains its ops for
/// the next pass — a persistent store failure can never spin a retry loop.
public struct CanvasAssetReconciliation: Sendable, Equatable {
    /// One idempotent reference-count delta.
    public struct Op: Sendable, Equatable, Codable {
        public var id: String
        public var assetID: UUID
        public var delta: Int

        public init(id: String, assetID: UUID, delta: Int) {
            self.id = id; self.assetID = assetID; self.delta = delta
        }
    }

    public private(set) var pending: [Op]

    public init(pending: [Op] = []) {
        self.pending = pending
    }

    public var isEmpty: Bool { pending.isEmpty }

    /// Coalesces new deltas into pending ops. `idFactory` supplies stable
    /// unique op ids (injectable for tests).
    public mutating func schedule(
        _ deltas: [UUID: Int],
        idFactory: () -> String = { UUID().uuidString }
    ) {
        for (assetID, delta) in deltas where delta != 0 {
            pending.append(Op(id: idFactory(), assetID: assetID, delta: delta))
        }
    }

    /// ONE bounded pass over the current pending ops. Positive deltas
    /// (increments) run first, in stable id order; when any increment fails,
    /// every decrement op is retained unapplied. `apply` performs one op and
    /// throws to retain it. Ops scheduled mid-pass append to `pending` and
    /// survive this pass's accounting (removal is by op id).
    @discardableResult
    public mutating func runPass(
        apply: (Op) async throws -> Void
    ) async -> (applied: [String], completed: Bool) {
        let snapshot = pending
        guard !snapshot.isEmpty else { return ([], true) }
        var failed: Set<String> = []
        var applied: [String] = []
        let increments = snapshot.filter { $0.delta > 0 }
            .sorted { $0.id < $1.id }
        var incrementsComplete = true
        for op in increments {
            do {
                try await apply(op)
                applied.append(op.id)
            } catch {
                failed.insert(op.id)
                incrementsComplete = false
            }
        }
        if incrementsComplete {
            let decrements = snapshot.filter { $0.delta < 0 }
                .sorted { $0.id < $1.id }
            for op in decrements {
                do {
                    try await apply(op)
                    applied.append(op.id)
                } catch {
                    failed.insert(op.id)
                }
            }
        } else {
            // Prerequisite increments did not all land: retain EVERY
            // decrement op so no reachable asset is decremented this pass.
            for op in snapshot where op.delta < 0 {
                failed.insert(op.id)
            }
        }
        if !applied.isEmpty {
            let done = Set(applied)
            pending.removeAll { done.contains($0.id) }
        }
        return (applied, failed.isEmpty)
    }

    /// Removes exactly the ops one pass applied (by op id). Ops scheduled
    /// after that pass's snapshot survive.
    public mutating func markApplied(_ opIDs: Set<String>) {
        guard !opIDs.isEmpty else { return }
        pending.removeAll { opIDs.contains($0.id) }
    }

/// Durable, codable form of the pending op set. Persisted BEFORE any
    /// pass runs (precommit intent) and after each pass (checkpoint); the
    /// journal is advisory — receipts in the database decide idempotency.
    public struct Record: Codable, Equatable, Sendable {
        public var ops: [Op]
        public init(ops: [Op]) { self.ops = ops }
    }

    public var record: Record { Record(ops: pending) }

    public init(record: Record) {
        self.init(pending: record.ops)
    }
}

/// Authoritative reachability decision for creative-asset prune protection.
/// `unknown` FAILS CLOSED: enumeration or decode failures (including a
/// newer-schema project this build cannot read) must retain the bytes and
/// surface a recoverable maintenance warning, because destructive pruning
/// can never be allowed to proceed on incomplete knowledge.
public enum CanvasAssetReachability: Sendable, Equatable {
    /// A persisted canvas project references the asset (live node or CAD
    /// revision history).
    case reachable
    /// Authoritatively unreferenced by every readable canvas project.
    case notReachable
    /// The reachability scan could not prove the asset unreferenced
    /// (enumeration failure, unreadable/corrupt/newer-schema project, or
    /// in-flight reconciliation bookkeeping). Treat as reachable.
    case unknown
}
