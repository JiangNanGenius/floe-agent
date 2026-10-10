import Foundation
import FloeCore

// FloeTools — Design revision payloads on the existing artifact authority.
//
// A `DesignRevision` records the content hash of exactly the bytes an editor
// produced. This store persists those bytes through the shared
// `FloeArtifactStore` (namespace `DesignRevisions`) so candidates, adoptions
// and exports can be re-verified against real data later. There is no
// parallel design material library:
//
// `<FloeAgent>/DesignRevisions/<canvasID>/<nodeID>/<artifactID>/<revisionID>.payload`
//
// Guarantees:
// - Every entry point validates all four identity components; canvas and node
//   are typed UUIDs, artifact/revision ids must match a strict allowlist.
// - Writes are staged and hash-verified, then committed with one atomic
//   rename. A revision is immutable: storing the same id with identical bytes
//   is a replay no-op; different bytes are a conflict, never an overwrite.
// - Reads go through `FloeArtifactStore.resolve` (containment, symlink
//   resolution, size preflight, streaming digest) plus a bounded read.

public enum DesignRevisionPayloadStoreError: Error, Equatable {
    case invalidIdentity(String)
    case payloadTooLarge(Int64)
    case conflict(String)
}

public struct DesignRevisionPayloadStore: Sendable {
    public static let namespace = ArtifactNamespace.designRevisions
    /// Maximum accepted payload size (default 256 MiB), enforced before any
    /// file is read into memory.
    public let maxPayloadBytes: Int64

    public init(maxPayloadBytes: Int64 = 256 * 1_024 * 1_024) {
        self.maxPayloadBytes = maxPayloadBytes
    }

    // MARK: - Identity validation

    static func validate(_ value: String, field: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !value.isEmpty,
              value.count <= 64,
              value.unicodeScalars.allSatisfy(allowed.contains),
              value != ".", value != ".." else {
            throw DesignRevisionPayloadStoreError.invalidIdentity(field)
        }
        return value
    }

    static func relativePath(canvasID: UUID, nodeID: UUID, artifactID: String, revisionID: String) throws -> String {
        let artifact = try validate(artifactID, field: "artifactID")
        let revision = try validate(revisionID, field: "revisionID")
        return "\(Self.namespace.rawValue)/\(canvasID.uuidString.lowercased())/\(nodeID.uuidString.lowercased())/\(artifact)/\(revision).payload"
    }

    // MARK: - Write (atomic, immutable)

    /// An immutable payload staged beside its final path. The bytes are
    /// hash-verified at stage time; `commit` publishes with one atomic rename
    /// (never overwriting an existing revision payload), and `abandon` removes
    /// only the staging file — a published payload shared by reference is
    /// never touched by cleanup.
    public struct StagedPayload: Sendable {
        /// App-storage relative path the committed payload will occupy (this
        /// is the pointer recorded in the Canvas CAS commit).
        public let relativePath: String
        /// Revision identity this payload belongs to.
        public let revisionID: String
        public let contentSHA256: String
        fileprivate let stagingURL: URL
        fileprivate let targetURL: URL
        fileprivate let digest: String
    }

    /// Stages the payload for one revision without publishing it. The digest
    /// is computed from the actual bytes; a caller-supplied hash is
    /// cross-checked.
    public func stage(
        canvasID: UUID,
        nodeID: UUID,
        artifactID: String,
        revisionID: String,
        bytes: Data,
        expectedContentSHA256: String? = nil
    ) throws -> StagedPayload {
        let relative = try Self.relativePath(canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID)
        let size = Int64(bytes.count)
        guard size <= maxPayloadBytes else { throw DesignRevisionPayloadStoreError.payloadTooLarge(size) }
        let digest = FloeDigest.sha256Hex(bytes)
        if let expectedContentSHA256, expectedContentSHA256.lowercased() != digest {
            throw FloeError.validationFailed("Payload bytes do not match the recorded revision hash")
        }
        let root = try FloeArtifactStore.root()
        let target = try Self.containedURL(root: root, relativePath: relative)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString.lowercased()).staging")
        try bytes.write(to: staging, options: .atomic)
        do {
            let stagedDigest = try FloeDigest.sha256Hex(ofFileAt: staging)
            guard stagedDigest == digest else {
                throw FloeError.storageCorrupted("Staged payload digest mismatch")
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return StagedPayload(relativePath: relative, revisionID: revisionID, contentSHA256: digest, stagingURL: staging, targetURL: target, digest: digest)
    }

    /// Publishes a staged payload with one atomic rename. Identical bytes on
    /// an existing payload are a replay no-op; different bytes are a conflict.
    public func commit(_ staged: StagedPayload) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: staged.targetURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            let existingDigest = try FloeDigest.sha256Hex(ofFileAt: staged.targetURL)
            if existingDigest == staged.digest {
                try? FileManager.default.removeItem(at: staged.stagingURL)
                return
            }
            throw DesignRevisionPayloadStoreError.conflict(staged.revisionID)
        }
        try FileManager.default.moveItem(at: staged.stagingURL, to: staged.targetURL)
    }

    /// Abandons a staged payload after a failed upstream commit. Removes only
    /// the staging file, never a published payload.
    public func abandon(_ staged: StagedPayload) {
        try? FileManager.default.removeItem(at: staged.stagingURL)
    }

    /// Stages, verifies and commits the payload for one revision, returning
    /// the app-storage relative path to record on the revision.
    @discardableResult
    public func store(
        canvasID: UUID,
        nodeID: UUID,
        artifactID: String,
        revisionID: String,
        bytes: Data,
        expectedContentSHA256: String? = nil
    ) throws -> String {
        let staged = try stage(
            canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID,
            bytes: bytes, expectedContentSHA256: expectedContentSHA256
        )
        do {
            try commit(staged)
        } catch {
            abandon(staged)
            throw error
        }
        return staged.relativePath
    }

    // MARK: - Read (bounded, verified)

    /// Loads and verifies one revision payload. Fails closed when the bytes
    /// are missing, exceed the cap, or do not match the recorded hash.
    public func verifiedBytes(
        canvasID: UUID,
        nodeID: UUID,
        artifactID: String,
        revisionID: String,
        expectedContentSHA256: String
    ) throws -> Data {
        let relative = try Self.relativePath(canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID)
        return try FloeArtifactStore.verifiedData(
            relative,
            allowed: [Self.namespace],
            maxBytes: Int(maxPayloadBytes),
            expectedSHA256: expectedContentSHA256.lowercased()
        )
    }

    /// Resolves one revision payload to a verified on-disk URL for streaming
    /// consumers (video/archives). The digest is verified before the URL is
    /// handed out.
    public func verifiedFile(
        canvasID: UUID,
        nodeID: UUID,
        artifactID: String,
        revisionID: String,
        expectedContentSHA256: String
    ) throws -> URL {
        let relative = try Self.relativePath(canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID)
        return try FloeArtifactStore.resolve(
            relative,
            allowed: [Self.namespace],
            maxBytes: Int(maxPayloadBytes),
            expectedSHA256: expectedContentSHA256.lowercased()
        )
    }

    /// Removes one revision-bound payload by exact identity. Only ever called
    /// for revisions the owning workflow discarded; cleanup never touches the
    /// artifact store.
    public func remove(canvasID: UUID, nodeID: UUID, artifactID: String, revisionID: String) throws {
        let relative = try Self.relativePath(canvasID: canvasID, nodeID: nodeID, artifactID: artifactID, revisionID: revisionID)
        let url = try Self.containedURL(root: FloeArtifactStore.root(), relativePath: relative)
        try FileManager.default.removeItem(at: url)
    }

    // MARK: - Containment

    /// Builds a URL inside the artifact root, rejecting anything that escapes
    /// it after symlink resolution (mirrors `FloeArtifactStore.resolve`).
    static func containedURL(root: URL, relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count >= 2, components.allSatisfy({ $0 != ".." && $0 != "." }) else {
            throw FloeError.validationFailed("Payload path is outside the artifact store")
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = components.reduce(base) { partial, component in
            partial.appendingPathComponent(component)
        }.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path + "/") else {
            throw FloeError.validationFailed("Payload path escapes the artifact store")
        }
        return resolved
    }
}
