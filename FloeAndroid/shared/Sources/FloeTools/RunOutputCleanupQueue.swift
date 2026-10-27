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
//
// ANDROID MIRROR DELTA (FloeAndroid/shared, D04 producer batch,
// job-3135f83ef97c4a21): ported byte-for-byte from iOS main 8f185ac blob
// 881145e4546ad086a27eca783f7be9e32e3b3f6e except for three narrow,
// recorded adaptations:
//   1. Artifact-root resolution mirrors the store delta: Android has no
//      implicit Application Support authority and never falls back to
//      `$HOME` or a temporary directory; the trusted runtime composition
//      passes the owned persistent root explicitly and absent that binding
//      the queue fails closed.
//   2. `RunOutputLiveOwnership` + the `liveOwnership` hook on
//      `retryPersistedTombstones` and `RunOutputDeletionOrder.perform`:
//      on Android downloads, Office jobs and Linux-guest native jobs may
//      still own a run's outputs even after the conversation row is gone
//      (detached durable services outlive the DB cascade), so a proven-
//      absent conversation alone is not sufficient — every retained live
//      request keeps its tombstone and is retried on a later readiness
//      pass. The binding comes from the trusted runtime owner (a service
//      the composition injects), never from a model payload.
//      2026-10-27 lifetime review extended this into REAL exclusion: the
//      `RunOutputOperationGate` cleanup CLAIM (`beginCleanup/
//      endCleanup`, held across removal AND completion) refuses while any
//      publication lease is live and blocks new `beginPublication` for
//      the claimed runs, so a probe that said "safe" can never be raced
//      by a publication admitted in the probe→delete window. The gate's
//      publication ticket also CARRIES its captured artifact root so no
//      split root/lease capture can let one generation's bytes validate
//      under another.
//   3. `RunOutputDeletionOrder` carries the exact production ordering that
//      on iOS lives in the App-layer `ConversationCenter.
//      runOutputAwareDeletion`: on Android the trusted conversation-deletion
//      owner is the shared-core `FacadeConversationDomain`, so the ordering
//      helper belongs in the shared core next to the queue it drives.
//      Notes/Canvas files live in different namespaces entirely and are
//      outside every path this queue may delete.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
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
    /// ANDROID MIRROR DELTA (D04 producer batch): requests whose
    /// conversation is already gone but whose outputs are STILL owned by a
    /// live durable service (download, Office job, Linux-guest native job).
    /// The request and the snapshot trees are retained for a later pass;
    /// Apple-platform retries that pass no ownership probe leave this 0.
    public var retainedLiveOutputRequests: Int
    public var failedRequestCount: Int
    /// Path-free, bounded failure descriptions (storage/verification errors).
    public var failureDescriptions: [String]

    public init(
        completedRequests: Int = 0,
        retainedLiveConversationRequests: Int = 0,
        retainedLiveOutputRequests: Int = 0,
        failedRequestCount: Int = 0,
        failureDescriptions: [String] = []
    ) {
        self.completedRequests = completedRequests
        self.retainedLiveConversationRequests = retainedLiveConversationRequests
        self.retainedLiveOutputRequests = retainedLiveOutputRequests
        self.failedRequestCount = failedRequestCount
        self.failureDescriptions = failureDescriptions
    }
}

/// ANDROID MIRROR DELTA (D04 producer batch): the trusted live-ownership
/// hook. The composition injects a service-backed probe (job service,
/// download ledger, Office/native job registry); the queue never infers
/// liveness from paths, mtimes or model text. A run whose output is still
/// owned keeps its tombstone AND its snapshot trees until a later retry
/// sees the owner gone.
public protocol RunOutputLiveOwnership: Sendable {
    /// True when a live durable service still owns `runID`'s published
    /// outputs (open job, running download, attached native work).
    func ownsRunOutput(runID: UUID) async throws -> Bool
}

/// ANDROID delta (D04 lifetime fix, coordinator review 2026-10-27): a
/// narrow generation-bound operation ticket for one in-flight publication
/// (or, later, a verified read). The ticket is minted by the trusted
/// runtime gate ATOMICALLY from the gate's current binding — the captured
/// artifact root travels INSIDE the ticket, so no retire/rebind between an
/// earlier root capture and lease acquisition can ever let bytes
/// published to one generation validate under another. The completion
/// boundary MUST re-validate it before any receipt is advertised. It
/// grants nothing by itself: it is opaque bookkeeping the configured
/// `RuntimeFacadeRunOutput` (or a focused test gate) resolves, never a
/// model-supplied value and never a path/permission system.
public struct RunOutputPublicationTicket: Sendable, Hashable {
    public let leaseID: UInt64
    public let epoch: UInt64
    public let runID: UUID
    /// The artifact-store root captured WITH this generation atomically at
    /// mint time. Gates that bind a root (the runtime facade) set it and
    /// the publication path must use THIS root, never a separately
    /// re-read one. `nil` means "no gate-managed root" — the caller falls
    /// back to its injected provider/default (host fixtures).
    public let artifactRoot: URL?

    public init(
        leaseID: UInt64,
        epoch: UInt64,
        runID: UUID,
        artifactRoot: URL? = nil
    ) {
        self.leaseID = leaseID
        self.epoch = epoch
        self.runID = runID
        self.artifactRoot = artifactRoot
    }
}

/// The trusted operation gate the configured publication path must consult:
/// `beginPublication` fails closed (nil) when no current generation binds
/// the store OR a cleanup claim covers the run, `endPublication` releases
/// exactly one ticket, and `isPublicationCurrent` is false once the
/// ticket's generation was retired or rebound — a publisher whose bytes
/// committed under a retired generation must NOT advertise the receipt,
/// while the committed bytes themselves are preserved (never rolled back
/// here).
///
/// 2026-10-27 lifetime review (REQUIRED exclusion): `beginCleanup/
/// endCleanup` are the narrow CLEANUP CLAIM/admission fence over the SAME
/// run ownership. A boolean probe-then-delete check is not atomic: a
/// publication starting after the probe returns false would race the
/// removal. The claim fails closed while any unreleased lease names one of
/// the runs AND blocks every subsequent `beginPublication` for those
/// runIDs until released, so the removal runs under real exclusion. Gates
/// without claim support (focused fixtures) get the default no-op;
/// production always wires the real claim.
public protocol RunOutputOperationGate: Sendable {
    func beginPublication(runID: UUID) -> RunOutputPublicationTicket?
    func endPublication(_ ticket: RunOutputPublicationTicket)
    func isPublicationCurrent(_ ticket: RunOutputPublicationTicket) -> Bool
    func beginCleanup(runIDs: [UUID]) -> Bool
    func endCleanup(runIDs: [UUID])
}

public extension RunOutputOperationGate {
    func beginCleanup(runIDs: [UUID]) -> Bool { true }
    func endCleanup(runIDs: [UUID]) {}
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
        try resolveStoreRoot(storeRoot)
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
    /// With an `operationGate`, the removal runs inside the narrow cleanup
    /// claim (2026-10-27 lifetime review): refused while any live
    /// publication lease names one of the runs, and blocking new
    /// publications for those runs for the duration.
    public static func removeOwnedSnapshots(
        for request: RunOutputCleanupRequest,
        artifactRoot: URL? = nil,
        operationGate: (any RunOutputOperationGate)? = nil
    ) throws {
        guard !request.runIDs.isEmpty else {
            throw FloeError.validationFailed(
                "run-output cleanup request requires at least one durable run id")
        }
        if let operationGate {
            guard operationGate.beginCleanup(runIDs: request.runIDs) else {
                throw FloeError.validationFailed(
                    "run-output cleanup claim refused (a live operation owns one of the runs)")
            }
            defer { operationGate.endCleanup(runIDs: request.runIDs) }
            try removeOwnedSnapshotsUnclaimed(for: request, base: try resolveStoreRoot(artifactRoot))
        } else {
            try removeOwnedSnapshotsUnclaimed(
                for: request, base: try resolveStoreRoot(artifactRoot))
        }
    }

    private static func removeOwnedSnapshotsUnclaimed(
        for request: RunOutputCleanupRequest,
        base: URL
    ) throws {
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
    ///
    /// ANDROID MIRROR DELTA (D04 producer batch): `liveOwnership` is the
    /// trusted service-lifecycle hook. When present, a request whose
    /// conversation is gone is STILL retained (counted in
    /// `retainedLiveOutputRequests`) while any of its runs has a live
    /// owner, so a download/Office/native job that outlived the DB cascade
    /// never loses its outputs under this pass. Callers that pass nil keep
    /// the original conversation-absence semantics.
    public static func retryPersistedTombstones(
        storeRoot: URL? = nil,
        artifactRoot: URL? = nil,
        liveOwnership: (any RunOutputLiveOwnership)? = nil,
        operationGate: (any RunOutputOperationGate)? = nil,
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
            var claimed = false
            do {
                if try await conversationExists(request.conversationID) {
                    // The conversation is still live: never delete its runs'
                    // outputs; keep the tombstone for a later pass.
                    outcome.retainedLiveConversationRequests += 1
                    continue
                }
                if let liveOwnership {
                    var hasLiveOwner = false
                    for runID in request.runIDs {
                        if try await liveOwnership.ownsRunOutput(runID: runID) {
                            hasLiveOwner = true
                            break
                        }
                    }
                    if hasLiveOwner {
                        // A durable service still owns the outputs: retain
                        // BOTH the trees and the request for a later pass.
                        outcome.retainedLiveOutputRequests += 1
                        continue
                    }
                }
                // Atomic exclusion (2026-10-27 lifetime review): take the
                // narrow cleanup claim over exactly these runs BEFORE
                // touching bytes. The claim refuses while any lease is
                // active AND blocks new `beginPublication` for these runs,
                // so a publisher starting between the probe above and the
                // removal can never race the delete. Held across removal
                // AND completion so no window reopens mid-record; every
                // path that reaches the claim falls through to the
                // release below (the retain paths `continue` BEFORE it).
                if let operationGate {
                    guard operationGate.beginCleanup(runIDs: request.runIDs) else {
                        outcome.retainedLiveOutputRequests += 1
                        continue
                    }
                    claimed = true
                }
                try removeOwnedSnapshotsUnclaimed(
                    for: request, base: try resolveStoreRoot(artifactRoot))
                try complete(conversationID: request.conversationID, storeRoot: storeRoot)
                outcome.completedRequests += 1
            } catch {
                outcome.failedRequestCount += 1
                let description = (error as NSError).localizedDescription
                outcome.failureDescriptions.append(
                    String(description.prefix(256)))
            }
            if claimed { operationGate?.endCleanup(runIDs: request.runIDs) }
        }
        return outcome
    }

    // MARK: - Artifact root resolution (ANDROID MIRROR DELTA)

    /// ANDROID MIRROR DELTA (D04 producer batch): same fail-closed default
    /// as the snapshot store — an explicit trusted root always wins; the
    /// Apple default is unchanged; on Android the implicit Foundation root
    /// can resolve below `$HOME`, so without the runtime-provided owned
    /// persistent root the queue refuses instead of inventing storage.
    static func resolveStoreRoot(_ explicit: URL?) throws -> URL {
        if let explicit { return explicit }
        #if os(Android)
        throw FloeError.validationFailed(
            "run-output cleanup requires the trusted runtime artifact-root binding")
        #else
        return try FloeArtifactStore.root()
        #endif
    }
}

// MARK: - Trusted deletion ordering (ANDROID MIRROR DELTA)

/// The exact S3-D per-conversation deletion order — on iOS this lives in
/// the App layer as `ConversationCenter.runOutputAwareDeletion`; on Android
/// the trusted conversation-deletion owner is the shared-core
/// `FacadeConversationDomain`, so the ordering helper lives beside the
/// queue it drives. Ported behavior, unchanged guarantees:
///
/// 1. The task-owned cleanup request (conversationID + the durable run IDs
///    captured BEFORE the cascade) is persisted atomically first. An
///    enqueue failure THROWS and the DB deletion never runs: outputs can
///    never be orphaned without a recovery tombstone.
/// 2. The caller's DB cascade runs. Its failure propagates with the
///    tombstone still persisted and the snapshots untouched.
/// 3. Only after the DB deletion is confirmed are exactly the canonical
///    `RunOutputs/<runUUID>` trees for those runs removed (skipped while a
///    live service still owns them) and the request completed. A cleanup
///    failure keeps the request (the readiness retry reattempts it) and is
///    reported to the caller through the typed outcome.
///
/// Must be called only after every writer for these runs has been
/// cancelled and joined. Notes/Canvas persistence lives in different
/// stores and namespaces: this order can never remove a Notes file.
public enum RunOutputDeletionOrder {
    public enum Outcome: Sendable, Equatable {
        /// The conversation owned no durable run outputs: plain deletion.
        case noOutputs
        /// Tombstone persisted, conversation deleted, exactly the owned
        /// snapshot trees removed and the request completed.
        case removed
        /// ANDROID delta: the conversation is deleted, but a live durable
        /// service still owns one of the runs' outputs. The tombstone and
        /// the trees are retained for the readiness retry pass.
        case deferredLiveOwnership
        /// Conversation deleted and trees removed, but completing or
        /// removing failed: the request SURVIVES on disk and the next
        /// readiness retry finishes the job idempotently.
        case cleanupDeferred(reason: String)
    }

    public static func perform(
        conversationID: UUID,
        durableRunIDs: [UUID],
        storeRoot: URL? = nil,
        artifactRoot: URL? = nil,
        liveOwnership: (any RunOutputLiveOwnership)? = nil,
        operationGate: (any RunOutputOperationGate)? = nil,
        deleteConversation: () async throws -> Void
    ) async throws -> Outcome {
        guard !durableRunIDs.isEmpty else {
            try await deleteConversation()
            return .noOutputs
        }
        let request = RunOutputCleanupRequest(
            conversationID: conversationID, runIDs: durableRunIDs)
        // 1. Persist the tombstone BEFORE the cascade. Failure here throws;
        // the conversation is not deleted.
        try RunOutputCleanupQueue.enqueue(request, storeRoot: storeRoot)
        // 2. The caller's DB cascade. Failure propagates; the tombstone
        // stays and the snapshots are untouched.
        try await deleteConversation()
        // 3. Confirmed gone: check the trusted owners, take the atomic
        // cleanup claim (refusing while any lease is active and blocking
        // new publications for these runs until released), then remove
        // exactly the owned trees and complete. NOTHING here may throw —
        // the DB deletion already committed; every post-cascade problem
        // becomes a typed deferral that keeps the tombstone for the
        // readiness retry. The claim is released on EVERY path that took
        // it (value-return shape; no `return` escapes it).
        var claimed = false
        var outcome: Outcome
        do {
            var live = false
            if let liveOwnership {
                for runID in request.runIDs {
                    if try await liveOwnership.ownsRunOutput(runID: runID) {
                        live = true
                        break
                    }
                }
            }
            if live {
                outcome = .deferredLiveOwnership
            } else if let operationGate, !operationGate.beginCleanup(runIDs: request.runIDs) {
                // A publication leased between the probe and here: real
                // exclusion decided the race, not a stale boolean probe.
                outcome = .deferredLiveOwnership
            } else {
                claimed = operationGate != nil
                try RunOutputCleanupQueue.removeOwnedSnapshots(
                    for: request, artifactRoot: artifactRoot, operationGate: nil)
                try RunOutputCleanupQueue.complete(
                    conversationID: conversationID, storeRoot: storeRoot)
                outcome = .removed
            }
        } catch {
            let description = (error as NSError).localizedDescription
            outcome = .cleanupDeferred(reason: String(description.prefix(256)))
        }
        if claimed { operationGate?.endCleanup(runIDs: request.runIDs) }
        return outcome
    }
}
