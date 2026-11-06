import Foundation
import CryptoKit

/// Lifecycle fence for a single pending document write. This is not a tool
/// permission: the host repository must check it at its atomic commit point.
/// No async work or realtime audio runs while this short lock is held.
public final class MusicCommitFence: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let projectID: MusicProjectID
    private let revision: Int64
    private let sessionID: MusicSessionID

    public init(document: MusicDocument, sessionID: MusicSessionID) {
        projectID = document.id; revision = document.revision; self.sessionID = sessionID
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }

    public func withValidCommit<T>(document: MusicDocument, _ commit: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        guard active, document.id == projectID, document.revision == revision else {
            throw MusicError.staleOwner(session: sessionID.rawValue)
        }
        return try commit()
    }
}

/// Payload bytes for a staged asset. `bytes` are the immutable blob the
/// `MusicAsset.contentHash` was computed over.
public struct MusicAssetPayload: Sendable, Hashable {
    public var asset: MusicAsset
    public var bytes: Data
    public init(asset: MusicAsset, bytes: Data) {
        self.asset = asset
        self.bytes = bytes
    }
}

/// Token returned by a persisted save; binds the committed revision to the
/// exact bytes the repository stored for that revision.
public struct MusicRevisionToken: Sendable, Codable, Hashable {
    public var revision: Int64
    public var contentHash: String
    public init(revision: Int64, contentHash: String) {
        self.revision = revision
        self.contentHash = contentHash
    }
}

/// Persistence seam. The core never touches a filesystem or database; the
/// host adapter (mapping onto the existing MediaProjectStore / PreparedCore
/// transaction ownership at mainline integration) implements this protocol.
///
/// Host adapter obligations (see CORE_CONTRACT.md):
/// 1. `stageAsset` verifies `SHA-256(bytes) == asset.contentHash`, stores the
///    blob content-addressed and immutable, and never silently replaces an
///    existing asset ID with different content/source revision.
/// 2. `save` is a compare-and-swap: `expectedRevision == nil` means
///    create-only (fail if a document with this ID already exists); otherwise
///    the stored document's revision must equal `expectedRevision` and the new
///    document's revision must be exactly `expectedRevision + 1`. Stale or
///    non-advancing saves are rejected so separate stores can never overwrite
///    newer documents.
/// 3. `save` persists the validated document and all referenced asset blobs
///    in ONE atomic transaction: a crash mid-save must yield either the old
///    or the new state, never a mixed one, and must be reopenable. The token
///    binds the exact stored bytes.
/// 4. `load` returns the last atomically saved document; decoding runs the
///    same validation as the constructors.
/// 5. Unreferenced blobs may be garbage-collected only when no document
///    revision references them (kept for undo/reopen).
public protocol MusicRepository: Sendable {
    /// Verify hash and stage an immutable asset blob.
    func stageAsset(_ payload: MusicAssetPayload) async throws
    /// Compare-and-swap save of the document plus all staged asset blobs.
    func save(document: MusicDocument, expectedRevision: Int64?, fence: MusicCommitFence?) async throws -> MusicRevisionToken
    /// Load the last atomically saved document for `projectID`.
    func load(projectID: MusicProjectID) async throws -> MusicDocument
    /// Fetch a staged blob by asset ID (nil when unknown).
    func assetPayload(assetID: MusicAssetID) async throws -> MusicAssetPayload?
}

public extension MusicRepository {
    /// Direct create/CAS operations without a pending editor session.
    func save(document: MusicDocument, expectedRevision: Int64?) async throws -> MusicRevisionToken {
        try await save(document: document, expectedRevision: expectedRevision, fence: nil)
    }
}

/// Standalone in-memory adapter: enough for package verification, tests and
/// the DJ asset-reference checks. Not a production store.
public actor InMemoryMusicRepository: MusicRepository {
    public struct NotStagedError: Error, Hashable, Sendable {
        public let assetID: MusicAssetID
    }

    private var staged: [MusicAssetID: MusicAssetPayload] = [:]
    private var documents: [MusicProjectID: MusicDocument] = [:]
    private var storedBytes: [MusicProjectID: Data] = [:]

    public init() {}

    public func stageAsset(_ payload: MusicAssetPayload) async throws {
        let digest = SHA256.hash(data: payload.bytes)
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        guard hash == payload.asset.contentHash else {
            throw MusicError.invalidAsset(
                reason: "payload hash \(hash) does not match asset contentHash \(payload.asset.contentHash)")
        }
        if let existing = staged[payload.asset.id] {
            // Never silently replace an existing asset identity.
            guard existing.asset.contentHash == payload.asset.contentHash,
                  existing.asset.sourceRevision == payload.asset.sourceRevision,
                  existing.bytes == payload.bytes else {
                throw MusicError.invalidAsset(
                    reason: "asset \(payload.asset.id) already staged with different content or source revision")
            }
            return
        }
        staged[payload.asset.id] = payload
    }

    public func save(document: MusicDocument, expectedRevision: Int64?, fence: MusicCommitFence?) async throws -> MusicRevisionToken {
        // Every throwing check completes before any state is mutated.
        try document.validate()
        for asset in document.assets {
            guard let payload = staged[asset.id], payload.asset.contentHash == asset.contentHash,
                  payload.asset.sourceRevision == asset.sourceRevision else {
                throw NotStagedError(assetID: asset.id)
            }
        }
        // Encode and hash the exact bytes that will be stored, before mutation.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes: Data
        do {
            bytes = try encoder.encode(document)
        } catch {
            throw MusicError.encodingFailed(reason: String(describing: error))
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        if let expected = expectedRevision {
            guard let stored = documents[document.id] else {
                throw MusicError.staleRevision(expected: expected, actual: -1)
            }
            guard stored.revision == expected else {
                throw MusicError.staleRevision(expected: expected, actual: stored.revision)
            }
            let (next, overflow) = expected.addingReportingOverflow(1)
            guard !overflow, document.revision == next else {
                throw MusicError.invalidBatch(
                    reason: "document revision must be expectedRevision + 1, got \(document.revision) for expected \(expected)")
            }
        } else {
            guard documents[document.id] == nil else {
                throw MusicError.invalidBatch(
                    reason: "create-only save conflicts with existing document \(document.id)")
            }
        }
        if let fence {
            try fence.withValidCommit(document: document) {
                documents[document.id] = document
                storedBytes[document.id] = bytes
            }
        } else {
            try Task.checkCancellation()
            documents[document.id] = document
            storedBytes[document.id] = bytes
        }
        return MusicRevisionToken(revision: document.revision, contentHash: digest)
    }

    public func load(projectID: MusicProjectID) async throws -> MusicDocument {
        guard let document = documents[projectID] else {
            throw MusicError.invalidAsset(reason: "no document for project \(projectID)")
        }
        return document
    }

    public func assetPayload(assetID: MusicAssetID) async throws -> MusicAssetPayload? {
        staged[assetID]
    }

    /// Exact stored bytes for `projectID` (verification support).
    public func storedBytes(projectID: MusicProjectID) -> Data? {
        storedBytes[projectID]
    }
}
