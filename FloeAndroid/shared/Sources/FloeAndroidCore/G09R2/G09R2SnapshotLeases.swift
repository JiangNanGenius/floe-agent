// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — bounded, native-issued render snapshot leases (job-b72b2978320e484e).
//
// A lease names ONE immutable project snapshot file written by the native side
// under the SAME trusted media root that owns the project. The platform host
// may read `mediaRootPath + "/" + relativePath`; it can never construct a lease
// by value, reopen a mutable "latest" project or derive a root from recorded
// project JSON. The registry below is the native authority:
//
//  * every field presented back by a caller is compared with the stored record;
//  * a lease is fence-bound to the accepted root epoch and expires;
//  * release removes ONLY the snapshot file this lease created (after digest
//    re-verification) and never touches original project assets;
//  * an exact-epoch root stop retires that epoch's leases and owned snapshots.
//
// The registry is a small NSLock-guarded table (the reviewed Office mailbox
// discipline), NOT a project/task store and NOT a second database.
import Foundation
import FloeCore

public struct G09R2SnapshotLeaseRecord: Sendable, Equatable {
    public let leaseID: String
    public let epoch: UInt64
    public let projectID: UUID
    public let revision: Int64
    public let timelineDigest: String
    public let mediaRootPath: String
    public let relativePath: String
    public let sha256: String
    public let byteCount: Int64
    public let storage: G09StorageLayerDTO
    public let origin: G09CreativeOriginDTO?
    public let ownerReference: String
    public let createdAt: Date
    public let expiresAt: Date
    /// Absolute asset files whose existence was verified at acquisition. The
    /// lease pins them: release never deletes an original project asset.
    public let pinnedAssets: [String]
}

public final class G09R2SnapshotLeases: @unchecked Sendable {
    public static let shared = G09R2SnapshotLeases()

    /// Bounded lease lifetime; a ticket may not outlive it.
    public static let lifetimeSeconds: TimeInterval = 15 * 60
    public static let maximumLeases = 16

    private struct Entry {
        var record: G09R2SnapshotLeaseRecord
        let snapshotURL: URL
        let snapshotSHA256: String
        let snapshotBytes: Int64
        /// Bounded internal pin set (owner = ticket/export identity). A live
        /// claimed render ticket keeps the exact snapshot/record alive even
        /// when its lease expires or the caller asks to release it.
        var pins: Set<String> = []
        /// A caller release arrived while pinned: honour it exactly once the
        /// last pin settles, never under active work.
        var deferredRelease = false
        /// Root retirement was requested while pinned: keep the owned file
        /// until the last pin settles.
        var retireRequested = false
    }

    /// Hard bound on pin owners per lease. One lease normally serves at most
    /// the two live render tickets; the small extra headroom is bounded.
    public static let maximumPinsPerLease = 8

    private let condition = NSLock()
    private var leases: [String: Entry] = [:]
    private var order: [String] = []

    public init() {}

    public var count: Int {
        condition.lock(); defer { condition.unlock() }
        return leases.count
    }

    /// Inserts a freshly written snapshot. Caller generated the identity and
    /// must already have verified the file's digest/size/path containment.
    public func insert(_ record: G09R2SnapshotLeaseRecord,
                       snapshotURL: URL) throws {
        condition.lock()
        defer { condition.unlock() }
        guard leases[record.leaseID] == nil else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseIdentityCollision")
        }
        guard leases.count < Self.maximumLeases else {
            throw G09R2Error(.renderTicketExpired, detail: "leaseTableFull")
        }
        leases[record.leaseID] = Entry(
            record: record, snapshotURL: snapshotURL,
            snapshotSHA256: record.sha256, snapshotBytes: record.byteCount)
        order.append(record.leaseID)
    }

    public func record(for leaseID: String) -> G09R2SnapshotLeaseRecord? {
        condition.lock(); defer { condition.unlock() }
        return leases[leaseID]?.record
    }

    /// Adds ONE bounded internal pin. The caller is the native ticket producer
    /// (owner = native ticketID), not the platform. Unknown/expired records
    /// and a full pin set are refused.
    @discardableResult
    public func pin(leaseID: String, owner: String, now: Date = Date()) -> Bool {
        guard !owner.isEmpty, owner.utf8.count <= 128 else { return false }
        condition.lock(); defer { condition.unlock() }
        guard var entry = leases[leaseID], entry.record.expiresAt > now else {
            return false
        }
        guard entry.pins.count < Self.maximumPinsPerLease else { return false }
        entry.pins.insert(owner)
        leases[leaseID] = entry
        return true
    }

    /// Removes ONE pin. When the last pin settles an earlier release or root
    /// retirement is honoured: only this lease's verified snapshot bytes are
    /// deleted, never an original project/asset file.
    public func unpin(leaseID: String, owner: String) {
        condition.lock()
        guard var entry = leases[leaseID] else { condition.unlock(); return }
        entry.pins.remove(owner)
        guard entry.pins.isEmpty,
              entry.deferredRelease || entry.retireRequested else {
            leases[leaseID] = entry
            condition.unlock()
            return
        }
        leases.removeValue(forKey: leaseID)
        order.removeAll { $0 == leaseID }
        condition.unlock()
        Self.removeIfOwned(url: entry.snapshotURL,
                           expectedSHA: entry.snapshotSHA256,
                           expectedBytes: entry.snapshotBytes)
    }

    public func pinnedCount(epoch: UInt64) -> Int {
        condition.lock(); defer { condition.unlock() }
        return leases.values.reduce(0) { count, entry in
            entry.record.epoch == epoch ? count + entry.pins.count : count
        }
    }

    public func hasPins(epoch: UInt64) -> Bool {
        pinnedCount(epoch: epoch) > 0
    }

    /// Verifies a lease exactly as a ticket producer would. Every presented
    /// field must match the native record; the epoch, project, revision,
    /// timeline digest, storage layer and owner token digest are all fenced.
    public func verify(
        _ lease: G09R2RenderSnapshotLeaseDTO,
        epoch: UInt64,
        projectID: UUID,
        revision: Int64,
        timelineDigest: String,
        storage: G09StorageLayerDTO,
        sessionToken: String,
        now: Date = Date()
    ) throws -> G09R2SnapshotLeaseRecord {
        condition.lock(); defer { condition.unlock() }
        guard let entry = leases[lease.leaseID] else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseUnknown")
        }
        let record = entry.record
        guard record.epoch == epoch else {
            throw G09R2Error(.renderTicketExpired, detail: "leaseOldEpoch")
        }
        guard record.expiresAt > now, lease.expiresAt == record.expiresAt,
              lease.expiresAt > now else {
            throw G09R2Error(.renderTicketExpired, detail: "leaseExpired")
        }
        guard record.projectID == projectID else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseCrossProject")
        }
        guard record.revision == revision,
              lease.mediaRootPath == record.mediaRootPath,
              lease.relativePath == record.relativePath,
              lease.sha256 == record.sha256,
              lease.byteCount == record.byteCount else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseMismatch")
        }
        guard record.timelineDigest == timelineDigest else {
            throw G09R2Error(.renderTicketExpired, detail: "leaseStaleTimeline")
        }
        guard record.storage == storage else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseCrossStorage")
        }
        guard record.ownerReference == G09CreativeAssetHost.sessionDigest(sessionToken) else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseCrossOwner")
        }
        return record
    }

    /// Re-verifies the exact snapshot bytes on disk (ticket creation boundary).
    public func verifyFile(leaseID: String) throws -> G09R2SnapshotLeaseRecord {
        condition.lock()
        guard let entry = leases[leaseID] else {
            condition.unlock()
            throw G09R2Error(.renderTicketNotFound, detail: "leaseUnknown")
        }
        let url = entry.snapshotURL
        let record = entry.record
        condition.unlock()
        return try Self.checkFile(url: url, expectedSHA: record.sha256,
                                  expectedBytes: record.byteCount,
                                  rootPath: record.mediaRootPath, record: record)
    }

    /// Idempotent release. The caller-supplied lease must match the record;
    /// only the owned snapshot file is removed, and only when it is still the
    /// exact bytes this lease wrote (a replacement is never deleted).
    ///
    /// While a native ticket/export pin is live this refuses (FALSE) and
    /// remembers the request; the last unpin performs the removal. A caller
    /// can therefore never delete the file under active work, and a repeated
    /// release after settlement is an idempotent TRUE.
    @discardableResult
    public func release(_ lease: G09R2RenderSnapshotLeaseDTO,
                        epoch: UInt64) -> Bool {
        condition.lock()
        guard var entry = leases[lease.leaseID] else {
            condition.unlock()
            return true // idempotent: already released/expired
        }
        guard entry.record.epoch == epoch else {
            condition.unlock()
            return false
        }
        guard entry.record.mediaRootPath == lease.mediaRootPath,
              entry.record.relativePath == lease.relativePath,
              entry.record.sha256 == lease.sha256,
              entry.record.byteCount == lease.byteCount else {
            condition.unlock()
            return false
        }
        guard entry.pins.isEmpty else {
            entry.deferredRelease = true
            leases[lease.leaseID] = entry
            condition.unlock()
            return false
        }
        leases.removeValue(forKey: lease.leaseID)
        order.removeAll { $0 == lease.leaseID }
        condition.unlock()
        Self.removeIfOwned(url: entry.snapshotURL,
                           expectedSHA: entry.snapshotSHA256,
                           expectedBytes: entry.snapshotBytes)
        return true
    }

    /// Exact-epoch root retirement. Deletes only snapshots this epoch owned
    /// after digest verification; never deletes project/asset files. A pinned
    /// entry stays (with its file) until the last pin settles.
    public func retire(epoch: UInt64) {
        condition.lock()
        var retiring: [Entry] = []
        for (id, entry) in leases where entry.record.epoch == epoch {
            if entry.pins.isEmpty {
                retiring.append(entry)
                leases.removeValue(forKey: id)
                order.removeAll { $0 == id }
            } else if var current = leases[id] {
                current.retireRequested = true
                leases[id] = current
            }
        }
        condition.unlock()
        for entry in retiring {
            Self.removeIfOwned(url: entry.snapshotURL,
                               expectedSHA: entry.snapshotSHA256,
                               expectedBytes: entry.snapshotBytes)
        }
    }

    /// Drops already-expired records and their owned files. Bounded; called on
    /// acquisition/bind boundaries so the table cannot grow without limit.
    public func purgeExpired(now: Date = Date()) {
        condition.lock()
        // An expired record pinned by a live claimed ticket is retained (the
        // file may already be open); the pin settlement performs the removal.
        let expired = leases.values.filter { entry in
            entry.record.expiresAt <= now && entry.pins.isEmpty
        }
        for entry in expired {
            leases.removeValue(forKey: entry.record.leaseID)
            order.removeAll { $0 == entry.record.leaseID }
        }
        condition.unlock()
        for entry in expired {
            Self.removeIfOwned(url: entry.snapshotURL,
                               expectedSHA: entry.snapshotSHA256,
                               expectedBytes: entry.snapshotBytes)
        }
    }

    // MARK: - File helpers

    private static func checkFile(url: URL, expectedSHA: String,
                                  expectedBytes: Int64, rootPath: String,
                                  record: G09R2SnapshotLeaseRecord)
        throws -> G09R2SnapshotLeaseRecord {
        let root = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let target = url.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else {
            throw G09R2Error(.renderTicketNotFound, detail: "leasePathEscape")
        }
        let values = try? target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              let size = values?.fileSize, Int64(size) == expectedBytes else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseFileMissing")
        }
        guard let digest = try? FloeDigest.sha256Hex(ofFileAt: target),
              digest.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
            throw G09R2Error(.renderTicketNotFound, detail: "leaseDigestMismatch")
        }
        return record
    }

    private static func removeIfOwned(url: URL, expectedSHA: String,
                                      expectedBytes: Int64) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, Int64(size) == expectedBytes else { return }
        guard let digest = try? FloeDigest.sha256Hex(ofFileAt: url),
              digest.caseInsensitiveCompare(expectedSHA) == .orderedSame else {
            return
        }
        try? FileManager.default.removeItem(at: url)
    }
}
