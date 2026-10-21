// FloeTools — Durable exact run-output cleanup tied to conversation deletion (S3-D).
//
// `RunOutputs/<runUUID>/` trees are user deliverables retained with their
// durable run. Conversation deletion owns their removal ordering: a small,
// exact, task-owned request record (conversationID + the durable run IDs that
// were captured BEFORE the DB cascade) is persisted first; only after the
// conversation's DB records are confirmed gone does the owner remove exactly
// those canonical snapshot trees and complete the request. On any failure the
// request survives and the next `AppEnvironment.performBootstrap` readiness
// pass retries only these proven tombstones — after verifying the original
// conversation truly no longer exists, so a pre-DB-failure tombstone can
// never delete a live run's output. There is deliberately NO global
// missing-run scan, no age GC and no directory-orphan guessing.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FloeCore
import FloeModels

/// One durable cleanup request: the conversation being deleted and the exact
/// durable run IDs whose `RunOutputs/<runUUID>` trees it owns. Bounded
/// metadata only — never prompts, secrets or free-form text.
public struct RunOutputCleanupRequest: Sendable, Codable, Hashable {
    public var conversationID: UUID
    /// Exact durable run IDs captured before the DB cascade (sorted and
    /// de-duplicated so equal deletions compare equal).
    public var runIDs: [UUID]

    /// Bound on a single request's run list (bounded metadata; a task with
    /// more durable runs than this is refused rather than silently truncated).
    public static let maximumRunIDsPerRequest = 100_000

    public init(conversationID: UUID, runIDs: [UUID]) {
        self.conversationID = conversationID
        self.runIDs = Array(Set(runIDs)).sorted { $0.uuidString < $1.uuidString }
    }
}

/// Summary of one bootstrap tombstone retry pass. Failures are described
/// path-free; every failed or live-conversation request is retained on disk.
public struct RunOutputCleanupRetryOutcome: Sendable, Equatable {
    public var completedRequests: Int
    public var retainedLiveConversationRequests: Int
    public var failedRequestCount: Int
    /// Path-free, bounded failure descriptions (storage/verification errors).
    public var failureDescriptions: [String]

    public init(
        completedRequests: Int = 0,
        retainedLiveConversationRequests: Int = 0,
        failedRequestCount: Int = 0,
        failureDescriptions: [String] = []
    ) {
        self.completedRequests = completedRequests
        self.retainedLiveConversationRequests = retainedLiveConversationRequests
        self.failedRequestCount = failedRequestCount
        self.failureDescriptions = failureDescriptions
    }
}

/// Exact, owned, idempotent cleanup queue for run-output snapshots.
public enum RunOutputCleanupQueue {
    /// Directory (inside the Floe artifact store root) that owns the pending
    /// request records. Distinct from the `RunOutputs` namespace itself so a
    /// request never interferes with snapshot caps or readers.
    static let requestDirectoryName = "RunOutputCleanupRequests"
    static let requestFileExtension = "json"
    /// Individual request records are tiny (bounded UUID lists); refuse
    /// anything larger so a corrupt/garbage file can never be "parsed".
    static let maximumRequestFileBytes = 1024 * 1024

    // MARK: - Persistence

    /// Root directory holding pending request records.
    public static func requestRoot(storeRoot: URL? = nil) throws -> URL {
        try (storeRoot ?? FloeArtifactStore.root())
            .appendingPathComponent(requestDirectoryName, isDirectory: true)
    }

    /// Persists `request` atomically BEFORE the caller's DB cascade. Throws
    /// on invalid/oversized input or an I/O failure; the caller must then NOT
    /// proceed with the DB deletion (no tombstone-less orphaning).
    public static func enqueue(
        _ request: RunOutputCleanupRequest,
        storeRoot: URL? = nil
    ) throws {
        guard !request.runIDs.isEmpty else {
            throw FloeError.validationFailed(
                "run-output cleanup request requires at least one durable run id")
        }
        guard request.runIDs.count <= RunOutputCleanupRequest.maximumRunIDsPerRequest else {
            throw FloeError.validationFailed(
                "run-output cleanup request exceeds the bounded run list")
        }
        let root = try requestRoot(storeRoot: storeRoot)
        let fileURL = root
            .appendingPathComponent(request.conversationID.uuidString, isDirectory: false)
            .appendingPathExtension(requestFileExtension)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(request)
        _ = try AtomicFileCommitter.commit(
            data,
            to: fileURL,
            policy: FileCommitPolicy(
                conflict: .replaceAtomically(consent: true),
                maxBytes: maximumRequestFileBytes
            )
        )
    }

    /// All pending requests. A malformed or foreign record is a visible
    /// storage error (never silently dropped): the caller keeps every request
    /// recoverable and reports the failure.
    public static func pending(storeRoot: URL? = nil) throws -> [RunOutputCleanupRequest] {
        let root = try requestRoot(storeRoot: storeRoot)
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return []
        }
        var requests: [RunOutputCleanupRequest] = []
        let decoder = JSONDecoder()
        for name in names.sorted() where name.hasSuffix("." + requestFileExtension) {
            let fileURL = root.appendingPathComponent(name, isDirectory: false)
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maximumRequestFileBytes else {
                throw FloeError.storageCorrupted(
                    "run-output cleanup request exceeds the bounded size")
            }
            guard let request = try? decoder.decode(
                RunOutputCleanupRequest.self, from: Data(contentsOf: fileURL)
            ) else {
                throw FloeError.storageCorrupted(
                    "run-output cleanup request is malformed")
            }
            requests.append(request)
        }
        return requests
    }

    /// Completes a request by removing its record. Already-absent is a
    /// successful no-op (idempotent reattempt).
    public static func complete(
        conversationID: UUID,
        storeRoot: URL? = nil
    ) throws {
        let root = try requestRoot(storeRoot: storeRoot)
        let fileURL = root
            .appendingPathComponent(conversationID.uuidString, isDirectory: false)
            .appendingPathExtension(requestFileExtension)
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // Already completed: idempotent success.
        }
    }

    // MARK: - Snapshot removal

    enum ComponentKind: Equatable {
        case absent
        case realDirectory
        case symlink
        case other
    }

    /// lstat-based classification: symlinks are NEVER followed (a symlinked
    /// tree is refused, not deleted), and anything that is not a real
    /// directory is foreign to the snapshot namespace.
    static func componentKind(_ url: URL) throws -> ComponentKind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return .absent }
            throw FloeError.storageCorrupted("run-output cleanup could not inspect a path component")
        }
        let type = info.st_mode & mode_t(S_IFMT)
        if type == mode_t(S_IFLNK) { return .symlink }
        if type == mode_t(S_IFDIR) { return .realDirectory }
        return .other
    }

    /// Verifies every existing path component from `base` down to `target`
    /// is a real, unaliased directory. A symlink anywhere in the chain, or a
    /// non-directory component, is refused (the tree is foreign and is never
    /// followed or deleted). An entirely absent chain means there is nothing
    /// to clean.
    static func assertOwnedChain(base: URL, target: URL) throws -> Bool {
        let basePath = base.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath == basePath || targetPath.hasPrefix(basePath + "/") else {
            throw FloeError.validationFailed(
                "run-output cleanup target is outside the artifact root")
        }
        var current = base.standardizedFileURL
        // A missing artifact root means every owned tree below it is already
        // absent: an idempotent no-op, exactly like a missing namespace. A
        // present-but-aliased or non-directory root is foreign and refused.
        switch try componentKind(current) {
        case .absent:
            return false
        case .realDirectory:
            break
        case .symlink:
            throw FloeError.storageCorrupted(
                "run-output cleanup refuses a symlinked artifact root")
        case .other:
            throw FloeError.storageCorrupted(
                "run-output cleanup refuses a foreign artifact root")
        }
        let relative = targetPath.dropFirst(basePath.count)
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            current = current.appendingPathComponent(String(component))
            switch try componentKind(current) {
            case .absent:
                return false // Nothing exists below this point.
            case .realDirectory:
                continue
            case .symlink:
                throw FloeError.storageCorrupted(
                    "run-output cleanup refuses a symlinked path component")
            case .other:
                throw FloeError.storageCorrupted(
                    "run-output cleanup refuses a foreign path component")
            }
        }
        return true
    }

    /// Removes ONLY the canonical `RunOutputs/<runUUID>` trees named by the
    /// request. Other runs, the request record itself, workspace originals
    /// and unrelated user files are never touched. An already-absent tree is
    /// a successful no-op. Refuses (without deleting anything) on a
    /// symlinked/foreign namespace chain or an unexpected component.
    public static func removeOwnedSnapshots(
        for request: RunOutputCleanupRequest,
        artifactRoot: URL? = nil
    ) throws {
        guard !request.runIDs.isEmpty else {
            throw FloeError.validationFailed(
                "run-output cleanup request requires at least one durable run id")
        }
        let base = try artifactRoot ?? FloeArtifactStore.root()
        let namespace = base
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
        guard try assertOwnedChain(base: base.standardizedFileURL, target: namespace) else {
            return // Namespace absent: every owned tree is already absent.
        }
        for runID in request.runIDs {
            let target = namespace.appendingPathComponent(runID.uuidString, isDirectory: true)
            guard try assertOwnedChain(base: namespace, target: target) else {
                continue // Idempotent: this run's tree is already absent.
            }
            // The chain check proved the target is a real directory.
            do {
                try FileManager.default.removeItem(at: target)
            } catch {
                throw FloeError.storageCorrupted(
                    "run-output cleanup failed to remove an owned snapshot tree")
            }
        }
    }

    // MARK: - Bootstrap retry

    /// Retries exactly the persisted tombstones, nothing else. For each
    /// pending request the original conversation is re-verified absent
    /// THROUGH THE CALLER (live conversations — e.g. a pre-DB-failure
    /// tombstone — keep their outputs and their request). Deletion failures
    /// keep the request on disk and are reported path-free.
    public static func retryPersistedTombstones(
        storeRoot: URL? = nil,
        artifactRoot: URL? = nil,
        conversationExists: (UUID) async throws -> Bool
    ) async -> RunOutputCleanupRetryOutcome {
        var outcome = RunOutputCleanupRetryOutcome()
        let requests: [RunOutputCleanupRequest]
        do {
            requests = try pending(storeRoot: storeRoot)
        } catch {
            outcome.failedRequestCount = 1
            outcome.failureDescriptions = [
                "run-output cleanup could not read the pending request list"
            ]
            return outcome
        }
        for request in requests {
            do {
                if try await conversationExists(request.conversationID) {
                    // The conversation is still live: never delete its runs'
                    // outputs; keep the tombstone for a later pass.
                    outcome.retainedLiveConversationRequests += 1
                    continue
                }
                try removeOwnedSnapshots(for: request, artifactRoot: artifactRoot)
                try complete(conversationID: request.conversationID, storeRoot: storeRoot)
                outcome.completedRequests += 1
            } catch {
                outcome.failedRequestCount += 1
                let description = (error as NSError).localizedDescription
                outcome.failureDescriptions.append(
                    String(description.prefix(256)))
            }
        }
        return outcome
    }
}
