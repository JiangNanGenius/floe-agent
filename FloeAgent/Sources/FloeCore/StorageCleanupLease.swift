import Foundation

// FloeCore — Live cleanup leases + owned scratch layout.
//
// `StorageCleanupLeaseCenter` is the lifecycle coordination point between
// components that own scratch on disk and the ownership-aware cleanup engine.
// Leases are keyed by the exact normalized scratch path (never by kind or
// name prefix), and deletion claims are coordinated *atomically* with lease
// acquisition inside the same actor — so a check-then-delete race (TOCTOU)
// cannot happen:
//
// - A component creates scratch through `makeLeasedScratch` (create + lease
//   is one actor-serialized step) and releases the lease when done.
// - Cleanup obtains an exclusive claim through `claimForDeletion`; the claim
//   is granted only while no lease is held, and both operations are serialized
//   by the actor. UUID-unique directory names make a collision between a
//   freshly leased directory and an in-deletion claim impossible.
//
// Leases are in-memory and die with the process; after a restart there are no
// stale leases, and the quiescence cutoff in the cleanup engine still guards
// files a crashed component left behind.
//
// `FloeScratch` is the single owned-scratch convention: every one-off
// component scratch directory is created under
// `tmp/FloeAgent/scratch/<purpose>-<uuid>` instead of directly under the
// shared tmp root. The cleanup plan registers exactly that dedicated
// directory — never the whole tmp root — as a deletable candidate.

/// An exclusive, revocable right to delete one exact path.
public struct StorageCleanupDeletionClaim: Sendable, Hashable {
    public let id: UUID
    /// Normalized absolute path this claim covers.
    public let path: String
}

public actor StorageCleanupLeaseCenter {
    public static let shared = StorageCleanupLeaseCenter()

    /// Live component leases keyed by normalized path, reference counted so
    /// two owners of the same path never unprotect each other.
    private var leaseCounts: [String: Int] = [:]
    /// Active deletion claims keyed by claim id.
    private var claims: [UUID: String] = [:]

    /// Isolated instances for tests; production uses `shared`.
    init() {}

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True when `held` and `queried` are the same path or one contains the
    /// other (directory deletion must respect descendant AND ancestor leases).
    static func pathsOverlap(_ held: String, _ queried: String) -> Bool {
        held == queried
            || held.hasPrefix(queried + "/")
            || queried.hasPrefix(held + "/")
    }

    // MARK: - Components (lease holders)

    /// Atomically creates and leases a unique scratch directory owned by
    /// `purpose`. Fresh UUID names can never collide with an in-flight
    /// deletion claim, so create+lease is unconditional. The lease is held
    /// until `release(path:)`; the caller must balance it (defer-release even
    /// on error) and remove the directory when done — forgotten quiescent
    /// directories are what cleanup reclaims.
    public func makeLeasedScratch(
        purpose: String,
        temporary: URL = FileManager.default.temporaryDirectory
    ) throws -> (url: URL, lease: ScratchLeaseToken) {
        let directory = try FloeScratch.makeDirectory(purpose: purpose, temporary: temporary)
        let normalized = Self.normalize(directory.path)
        // Defensive: refuse to hand out a live directory under a path with an
        // in-flight deletion claim (fresh UUID names make this unreachable in
        // practice, but the guard must not depend on that).
        guard !claims.values.contains(where: { Self.pathsOverlap($0, normalized) }) else {
            try? FileManager.default.removeItem(at: directory)
            throw FloeError.cancelled
        }
        leaseCounts[normalized, default: 0] += 1
        return (directory, ScratchLeaseToken(path: normalized, center: self))
    }

    /// Reserves a unique scratch path and holds its lease WITHOUT creating
    /// the directory, for callees that contractually require a fresh
    /// non-existent target (archive extractors, `copyItem`). The parent
    /// scratch root is created. The caller must balance with
    /// `release(path:)`; the reserved path is protected from cleanup for the
    /// lease's whole lifetime.
    public func reserveLeasedScratchPath(
        purpose: String,
        temporary: URL = FileManager.default.temporaryDirectory
    ) throws -> (url: URL, lease: ScratchLeaseToken) {
        try FileManager.default.createDirectory(
            at: FloeScratch.scratchRoot(temporary: temporary),
            withIntermediateDirectories: true
        )
        let directory = FloeScratch.scratchRoot(temporary: temporary)
            .appendingPathComponent(
                "\(FloeScratch.sanitizedPurpose(purpose))-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        let normalized = Self.normalize(directory.path)
        guard !claims.values.contains(where: { Self.pathsOverlap($0, normalized) }) else {
            throw FloeError.cancelled
        }
        leaseCounts[normalized, default: 0] += 1
        return (directory, ScratchLeaseToken(path: normalized, center: self))
    }

    /// Acquires a lease on an exact normalized path the caller owns. Fails
    /// while a deletion claim overlaps the path (cleanup is about to remove
    /// it); the caller must not write there and should use a fresh scratch
    /// directory instead.
    @discardableResult
    public func acquire(path: String) -> Bool {
        let normalized = Self.normalize(path)
        // Reject while any active claim overlaps: acquiring must never let a
        // writer race an in-flight deletion of the same (or a parent/child)
        // path.
        guard !claims.values.contains(where: { Self.pathsOverlap($0, normalized) }) else { return false }
        leaseCounts[normalized, default: 0] += 1
        return true
    }

    /// Shared guard: true while any deletion claim overlaps `normalized`.
    private func hasClaimOverlap(_ normalized: String) -> Bool {
        claims.values.contains { Self.pathsOverlap($0, normalized) }
    }

    /// Acquires a lease and returns a releasable token, or nil while a
    /// deletion claim overlaps the path (the same guard `acquire` uses — a
    /// token must never bypass in-flight deletion protection). The lease is
    /// held until `token.release()`; process death releases implicitly, after
    /// which the quiescence cutoff protects the bytes.
    public func acquireToken(path: String) -> ScratchLeaseToken? {
        let normalized = Self.normalize(path)
        guard !claims.values.contains(where: { Self.pathsOverlap($0, normalized) }) else { return nil }
        leaseCounts[normalized, default: 0] += 1
        return ScratchLeaseToken(path: normalized, center: self)
    }

    /// Balances one lease acquisition. Releasing an unleased path is a no-op.
    public func release(path: String) {
        let normalized = Self.normalize(path)
        guard let count = leaseCounts[normalized] else { return }
        if count <= 1 { leaseCounts.removeValue(forKey: normalized) } else { leaseCounts[normalized] = count - 1 }
    }

    /// True while any holder keeps the exact path alive.
    public func isLeased(path: String) -> Bool {
        (leaseCounts[Self.normalize(path)] ?? 0) > 0
    }

    /// True while any lease whose path lies inside `root` is held.
    public func isLeasedUnder(root: URL) -> Bool {
        let prefix = Self.normalize(root.path) + "/"
        return leaseCounts.keys.contains { $0.hasPrefix(prefix) && (leaseCounts[$0] ?? 0) > 0 }
    }

    /// Diagnostic snapshot of currently leased paths.
    public func leasedPaths() -> Set<String> {
        Set(leaseCounts.filter { $0.value > 0 }.map(\.key))
    }

    // MARK: - Cleanup (exclusive claims)

    /// Grants an exclusive deletion claim for an exact path, or nil while any
    /// lease OR any other active claim overlaps it (same path, descendant or
    /// ancestor). The claim is held until `releaseClaim` and covers the path
    /// against both new leases and overlapping claims for its whole lifetime.
    public func claimForDeletion(path: String) -> StorageCleanupDeletionClaim? {
        let normalized = Self.normalize(path)
        let leaseConflict = leaseCounts.contains { held, count in
            count > 0 && Self.pathsOverlap(held, normalized)
        }
        guard !leaseConflict else { return nil }
        let claimConflict = claims.values.contains { Self.pathsOverlap($0, normalized) }
        guard !claimConflict else { return nil }
        let claim = StorageCleanupDeletionClaim(id: UUID(), path: normalized)
        claims[claim.id] = normalized
        return claim
    }

    /// Releases a deletion claim after the item was removed or kept.
    public func releaseClaim(_ claimID: UUID) {
        claims.removeValue(forKey: claimID)
    }
}

/// A releasable scratch lease held by a consumer that took ownership of a
/// scratch artifact (share sheet, preview). Releasing is idempotent; the lease
/// also dies with the process, after which the cleanup quiescence cutoff
/// protects the bytes.
public final class ScratchLeaseToken: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    /// Normalized absolute path this token protects.
    public let path: String
    /// The center this token belongs to; releasing always balances the
    /// originating center (isolated test instances included).
    private let center: StorageCleanupLeaseCenter

    fileprivate init(path: String, center: StorageCleanupLeaseCenter) {
        self.path = path
        self.center = center
    }

    public func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        lock.unlock()
        let path = path
        let center = center
        Task { await center.release(path: path) }
    }

    deinit { release() }
}

/// Owned scratch layout shared by every component that creates one-off
/// temporary working directories.
public enum FloeScratch {
    /// Environment fallback root lives directly at `tmp/FloeAgent`; scratch is
    /// a dedicated subdirectory so the two never mix.
    public static func root(temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appendingPathComponent("FloeAgent", isDirectory: true)
    }

    /// The single registered, deletable scratch root. Only directories created
    /// through `makeDirectory` live here; nothing else is ever placed inside.
    public static func scratchRoot(temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        root(temporary: temporary).appendingPathComponent("scratch", isDirectory: true)
    }

    static func sanitizedPurpose(_ purpose: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let cleaned = purpose.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let name = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return name.isEmpty ? "misc" : name
    }

    /// Creates a unique scratch directory owned by `purpose`, e.g.
    /// `tmp/FloeAgent/scratch/notes-a1b2c3…`. The caller owns the result and
    /// must remove it when done; the cleanup engine may reclaim forgotten,
    /// quiescent ones. For directories that may exist across awaited work,
    /// use `StorageCleanupLeaseCenter.makeLeasedScratch` so cleanup can never
    /// reclaim a live directory.
    public static func makeDirectory(
        purpose: String,
        temporary: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let directory = scratchRoot(temporary: temporary)
            .appendingPathComponent("\(sanitizedPurpose(purpose))-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
