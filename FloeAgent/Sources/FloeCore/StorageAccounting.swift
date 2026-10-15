import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Storage accounting primitives shared by Settings → Data Management, the
/// Linux/environment managers, the local-model catalog and the asset stores.
///
/// A single file carries two distinct byte measurements and callers must keep
/// them separate:
///
/// - ``StorageSize/logicalBytes`` is the file's apparent length. A 16 GiB
///   *sparse* VM disk that has only written a fraction of that still reports the
///   full capacity here, so this is the configured/guest capacity, not host use.
/// - ``StorageSize/allocatedBytes`` is the host-allocated size
///   (`totalFileAllocatedSize`/`fileAllocatedSize`, sparse-aware, with a verified
///   `stat` `st_blocks` fallback). If neither is available the file's allocated
///   size is reported as *unmeasured* — logical size is never substituted.
///
/// Sharing handling:
///
/// - **Hard links and nested/overlapping scan roots** are the same on-disk bytes
///   and are deduplicated *exactly* by file identity (device + inode) across
///   every bucket, including the unattributed remainder. Walk trees are
///   normalized so contained roots are not traversed twice.
/// - **APFS copy-on-write clones** may share blocks across distinct inodes and
///   cannot be measured from `stat`; clone-backed roots are counted in full and
///   the report is flagged as an upper estimate. Nothing is subtracted for
///   sharing that cannot be measured.
public struct StorageSize: Sendable, Equatable, Codable {
    /// Apparent file length in bytes (sparse disks report their full capacity).
    public var logicalBytes: Int64
    /// Host-allocated bytes; 0 when the allocated measurement was unavailable.
    public var allocatedBytes: Int64

    public init(logicalBytes: Int64, allocatedBytes: Int64) {
        self.logicalBytes = max(0, logicalBytes)
        self.allocatedBytes = max(0, allocatedBytes)
    }

    public static let zero = StorageSize(logicalBytes: 0, allocatedBytes: 0)

    static func + (lhs: StorageSize, rhs: StorageSize) -> StorageSize {
        StorageSize(
            logicalBytes: lhs.logicalBytes + rhs.logicalBytes,
            allocatedBytes: lhs.allocatedBytes + rhs.allocatedBytes
        )
    }
}

/// Stable on-disk identity used to deduplicate hard links and overlapping roots
/// exactly (device + inode). APFS CoW *clones* have distinct inodes and are not
/// collapsed here.
public struct StorageFileIdentity: Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

/// APFS clone streams are scoped to a volume: the same clone-id on two devices
/// is NOT the same data stream. Grouping therefore always carries the volume
/// identity next to the clone-id (the same device the inode dedup uses).
struct CloneStreamKey: Hashable, Sendable {
    let device: UInt64
    let cloneID: UInt64
}

/// Diagnostics collected during a scan. Paths, names and contents are never
/// retained; only category, count, size, timing and error counters, so this is
/// safe to log and export.
public struct StorageScanDiagnostics: Sendable, Equatable, Codable {
    public var regularFileCount: Int
    public var directoryCount: Int
    public var symbolicLinkCount: Int
    /// Files skipped because they were already counted via another bucket or a
    /// hard link (exact, identity-based dedup).
    public var dedupedFileCount: Int
    /// Files that vanished or changed while being enumerated (benign race).
    public var changedOrVanishedCount: Int
    /// Entries or subtrees that could not be read (permission, I/O).
    public var errorCount: Int
    /// Files whose identity could not be read; they cannot participate in dedup
    /// and are counted with an uncertainty flag.
    public var identityUnavailableCount: Int
    /// Files whose allocated size could not be measured; logical size is never
    /// substituted for allocated.
    public var allocatedUnavailableCount: Int
    /// Distinct files whose ALLOCATED BYTES were removed from the totals
    /// because they are pure APFS clones of a stream already counted on the
    /// same volume (same device + clone-id, SHARES_ALL_BLOCKS). The files
    /// themselves are still counted in their category's file count; only the
    /// physically shared bytes are deduplicated. This is an exact, measured
    /// dedup — not an estimate.
    public var dedupedCloneFileCount: Int
    /// Allocated bytes removed by the full-clone-stream dedup above.
    public var dedupedCloneBytes: Int64
    /// Files for which measured clone attributes were collected.
    public var cloneAttributeFileCount: Int
    /// Per-file clone-attribute queries that failed transiently; when > 0 the
    /// aggregate exclusive lower bound is withheld (it would be incomplete).
    public var cloneAttributeFailureCount: Int
    /// Whether measured clone attributes were collected at all.
    public var cloneAttributeSupport: StorageCloneAttributeSupport
    /// Sum of measured private bytes (bytes not trapped in a clone/snapshot
    /// and freed immediately on delete). A measured lower bound; never
    /// presented as a total.
    public var measuredPrivateBytes: Int64
    /// Whether the measured physical-extent basis was collected in this scan.
    public var extentBasis: StorageExtentBasisState
    /// First failure that withheld the extent basis. Aggregate token only —
    /// never a path, offset or file name.
    public var extentUnavailableReason: StorageExtentProbeFailure?
    /// Wall-clock duration of the scan.
    public var duration: TimeInterval
    /// Stable label identifying which census produced these metrics.
    public var metricLabel: String
    /// When the scan finished.
    public var completedAt: Date

    public init(
        regularFileCount: Int = 0,
        directoryCount: Int = 0,
        symbolicLinkCount: Int = 0,
        dedupedFileCount: Int = 0,
        changedOrVanishedCount: Int = 0,
        errorCount: Int = 0,
        identityUnavailableCount: Int = 0,
        allocatedUnavailableCount: Int = 0,
        dedupedCloneFileCount: Int = 0,
        dedupedCloneBytes: Int64 = 0,
        cloneAttributeFileCount: Int = 0,
        cloneAttributeFailureCount: Int = 0,
        cloneAttributeSupport: StorageCloneAttributeSupport = .notRequested,
        measuredPrivateBytes: Int64 = 0,
        extentBasis: StorageExtentBasisState = .notRequested,
        extentUnavailableReason: StorageExtentProbeFailure? = nil,
        duration: TimeInterval = 0,
        metricLabel: String = "",
        completedAt: Date = Date()
    ) {
        self.regularFileCount = regularFileCount
        self.directoryCount = directoryCount
        self.symbolicLinkCount = symbolicLinkCount
        self.dedupedFileCount = dedupedFileCount
        self.changedOrVanishedCount = changedOrVanishedCount
        self.errorCount = errorCount
        self.identityUnavailableCount = identityUnavailableCount
        self.allocatedUnavailableCount = allocatedUnavailableCount
        self.dedupedCloneFileCount = dedupedCloneFileCount
        self.dedupedCloneBytes = dedupedCloneBytes
        self.cloneAttributeFileCount = cloneAttributeFileCount
        self.cloneAttributeFailureCount = cloneAttributeFailureCount
        self.cloneAttributeSupport = cloneAttributeSupport
        self.measuredPrivateBytes = measuredPrivateBytes
        self.extentBasis = extentBasis
        self.extentUnavailableReason = extentUnavailableReason
        self.duration = duration
        self.metricLabel = metricLabel
        self.completedAt = completedAt
    }

    /// True when some measurement was unavailable and totals are therefore a
    /// lower/uncertain bound rather than an exact figure.
    public var hasMeasurementGaps: Bool {
        errorCount > 0 || identityUnavailableCount > 0 || allocatedUnavailableCount > 0
    }
}

/// A root to include in a mutually-exclusive census. Nested/overlapping roots
/// are resolved to the most specific (deepest) match.
public struct StorageCensusRoot: Sendable, Equatable {
    public enum Attribution: Sendable, Equatable, Codable {
        /// Counted and reported as its own category.
        case category
        /// Counted in full and reported separately, but flagged as *potentially
        /// sharing* APFS clone blocks. The bytes are still included in the total.
        case shared
    }

    /// Roots that are known to produce/hold APFS CoW clones; walking them makes
    /// the resulting allocated total an upper estimate.
    public let potentiallyCloned: Bool

    public let id: String
    public let url: URL
    public let attribution: Attribution
    public let includeHiddenFiles: Bool

    public init(
        id: String,
        url: URL,
        attribution: Attribution = .category,
        includeHiddenFiles: Bool = true,
        potentiallyCloned: Bool = false
    ) {
        self.id = id
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.attribution = attribution
        self.includeHiddenFiles = includeHiddenFiles
        self.potentiallyCloned = potentiallyCloned
    }
}

/// Per-root result. Byte values are unique to this bucket after identity dedup.
public struct StorageCensusBucket: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let attribution: StorageCensusRoot.Attribution
    public let exists: Bool
    public var size: StorageSize
    public var fileCount: Int
    /// Bytes in this root already claimed by another identity (hard link / root
    /// overlap). Not added to the total; reported for transparency.
    public var sharedSize: StorageSize
    /// Bytes dropped from `size` because they are pure APFS clones of a stream
    /// already counted (exact measured dedup of full-clone families).
    public var dedupedCloneSize: StorageSize
    /// True when this root is known to hold APFS CoW clones (root flag) or the
    /// per-file extended flags report actual block sharing. Its allocated bytes
    /// may share physical blocks and are an upper estimate (counted in full,
    /// never silently subtracted).
    public var isCloneCapable: Bool
    /// Sum of measured private bytes for files in this bucket (exclusive,
    /// snapshot-aware). Only meaningful when the scan's clone attribute
    /// support is `.supported`.
    public var measuredPrivateBytes: Int64

    public init(
        id: String,
        attribution: StorageCensusRoot.Attribution,
        exists: Bool,
        size: StorageSize = .zero,
        fileCount: Int = 0,
        sharedSize: StorageSize = .zero,
        dedupedCloneSize: StorageSize = .zero,
        isCloneCapable: Bool = false,
        measuredPrivateBytes: Int64 = 0
    ) {
        self.id = id
        self.attribution = attribution
        self.exists = exists
        self.size = size
        self.fileCount = fileCount
        self.sharedSize = sharedSize
        self.dedupedCloneSize = dedupedCloneSize
        self.isCloneCapable = isCloneCapable
        self.measuredPrivateBytes = measuredPrivateBytes
    }
}

/// Result of a single mutually-exclusive categorized snapshot.
public struct StorageCensusReport: Sendable, Equatable, Codable {
    public var buckets: [StorageCensusBucket]
    public var diagnostics: StorageScanDiagnostics
    /// Size of files inside `parentURL` but outside every supplied root.
    public var unattributedSize: StorageSize
    public var unattributedCount: Int
    /// True when clone-backed roots were walked; allocated bytes are an upper
    /// estimate rather than an exact figure.
    public var isSharedAllocationEstimate: Bool
    /// Measured union of the physical blocks referenced by the counted files
    /// (public `fcntl(F_LOG2PHYS_EXT)` extents), present only when every
    /// measured file — including the optional bundle root — answered
    /// coherently. Nil keeps the accepted allocated basis; a partial union is
    /// never published or subtracted.
    public var extentUnion: StorageExtentUnionSummary? = nil

    /// True when the report's numeric totals may switch to the measured
    /// extent basis.
    public var hasMeasuredExtentBasis: Bool { extentUnion != nil }

    public var totalAllocatedBytes: Int64 {
        buckets.reduce(Int64(0)) { $0 + $1.size.allocatedBytes }
            + unattributedSize.allocatedBytes
    }

    public var totalLogicalBytes: Int64 {
        buckets.reduce(Int64(0)) { $0 + $1.size.logicalBytes }
            + unattributedSize.logicalBytes
    }

    /// Allocated bytes in buckets that are clone-capable (declared root or
    /// actual per-file sharing flags). Counted in full in the totals; may share
    /// APFS clone blocks, so they are an explicit non-additive figure — never
    /// subtracted, never relabelled as exclusive.
    public var cloneCapableAllocatedBytes: Int64 {
        buckets.reduce(Int64(0)) { $0 + ($1.isCloneCapable ? $1.size.allocatedBytes : 0) }
    }

    /// Allocated bytes removed by the exact full-clone-stream dedup (same
    /// clone-id with SHARES_ALL_BLOCKS). Measured, not an estimate.
    public var dedupedCloneBytes: Int64 { diagnostics.dedupedCloneBytes }

    /// Measured lower bound of the physical footprint of the counted files:
    /// the sum of private bytes (blocks not trapped in a clone or snapshot,
    /// freed immediately on delete). Nil when the extended query was not
    /// available for the whole scan or any per-file query failed — a partial
    /// sum must never be shown as a bound.
    public var measuredExclusiveLowerBoundBytes: Int64? {
        guard diagnostics.cloneAttributeSupport == .supported,
              diagnostics.cloneAttributeFailureCount == 0 else { return nil }
        return diagnostics.measuredPrivateBytes
    }

    /// True when any actual clone/block-sharing was measured or declared.
    public var hasCloneSharing: Bool {
        isSharedAllocationEstimate || dedupedCloneBytes > 0
            || buckets.contains { $0.isCloneCapable }
    }

    public func bucket(_ id: String) -> StorageCensusBucket? {
        buckets.first { $0.id == id }
    }
}

public enum StorageCensusError: Error, Equatable {
    case cancelled
}

/// One-shot, single-threaded census. Run it on a background task. It performs a
/// single mutually-exclusive pass; hard links, nested roots and symlinks never
/// cause double counting, and contained walk trees are not traversed twice.
public struct StorageCensus: Sendable {
    public let roots: [StorageCensusRoot]
    /// Optional parent directory; files inside it but outside all roots are
    /// tallied as unattributed/other. Typically the app data container.
    public let parentURL: URL?
    public let metricLabel: String
    /// Polled cooperatively for cancellation.
    public let isCancelled: @Sendable () -> Bool
    /// Called periodically with the number of regular files scanned so the UI
    /// can show measured progress instead of a synthetic animation.
    public let onProgress: (@Sendable (Int) -> Void)?
    /// Measured APFS clone/private attributes via public-SDK getattrlist.
    /// `nil` disables the measurement (legacy callers/tests); when it returns
    /// `.unsupported` the scan falls back to declared root clone flags.
    public let cloneAttributeProvider: (@Sendable (String) -> StorageCloneAttributeResult)?
    /// Volume identity used to group clone streams (device id). Production
    /// reads it from the same `StorageFileIdentity` used for inode dedup; the
    /// seam lets focused tests model two volumes that reuse a clone-id.
    public let cloneStreamVolumeProvider: (@Sendable (String) -> UInt64?)?
    /// Optional measured physical-extent probe (public `fcntl F_LOG2PHYS_EXT`).
    /// `nil` disables the extent basis and keeps the allocated basis exactly
    /// as before (legacy callers/tests).
    public let extentProbe: StorageExtentProbe?
    /// Optional read-only app-bundle root measured into the SAME union as the
    /// data roots, so a clone between the app bundle and the data container is
    /// counted once instead of as raw bundle bytes plus union data. It is not
    /// a census bucket and never changes the allocated totals.
    public let bundleMeasurementURL: URL?
    /// Bounds for the extent pass (calls, intervals, wall clock).
    public let extentBudget: StorageExtentBudget

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey
    ]

    public init(
        roots: [StorageCensusRoot],
        parentURL: URL? = nil,
        metricLabel: String = "storage.census",
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: (@Sendable (Int) -> Void)? = nil,
        cloneAttributeProvider: (@Sendable (String) -> StorageCloneAttributeResult)? = StorageCloneAttributesReader.read,
        cloneStreamVolumeProvider: (@Sendable (String) -> UInt64?)? = nil,
        extentProbe: StorageExtentProbe? = nil,
        bundleMeasurementURL: URL? = nil,
        extentBudget: StorageExtentBudget = .default
    ) {
        self.roots = roots
        self.parentURL = parentURL?.standardizedFileURL.resolvingSymlinksInPath()
        self.metricLabel = metricLabel
        self.isCancelled = isCancelled
        self.onProgress = onProgress
        self.cloneAttributeProvider = cloneAttributeProvider
        self.cloneStreamVolumeProvider = cloneStreamVolumeProvider
        self.extentProbe = extentProbe
        self.bundleMeasurementURL = bundleMeasurementURL?.standardizedFileURL
        self.extentBudget = extentBudget
    }

    /// Exact on-disk identity (device + inode) via Foundation attributes.
    static func fileIdentity(at url: URL) -> StorageFileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let device, let inode else { return nil }
        return StorageFileIdentity(device: device, inode: inode)
    }

    /// Host-allocated bytes with a verified `stat` fallback. Returns
    /// `measured == false` when no reliable figure exists; the caller must never
    /// substitute logical size.
    static func allocatedMeasurement(at url: URL, values: URLResourceValues?) -> (bytes: Int64, measured: Bool) {
        if let total = values?.totalFileAllocatedSize { return (Int64(total), true) }
        if let allocated = values?.fileAllocatedSize { return (Int64(allocated), true) }
        #if canImport(Darwin) || canImport(Glibc)
        var info = stat()
        if lstat(url.path, &info) == 0 {
            return (Int64(info.st_blocks) * 512, true)
        }
        #endif
        return (0, false)
    }

    private final class ErrorCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    struct WalkTree { let url: URL; let includeHidden: Bool }

    /// Normalize walk trees so a root contained in another tree is not traversed
    /// twice; attribution still uses the full root list (deepest match wins).
    static func normalizedWalkTrees(
        roots: [StorageCensusRoot],
        parentURL: URL?
    ) -> [WalkTree] {
        var candidates: [WalkTree] = []
        if let parentURL {
            candidates.append(WalkTree(url: parentURL, includeHidden: true))
            for root in roots where !Self.contains(parentURL, root.url) && root.url.path != parentURL.path {
                candidates.append(WalkTree(url: root.url, includeHidden: root.includeHiddenFiles))
            }
        } else {
            for root in roots {
                candidates.append(WalkTree(url: root.url, includeHidden: root.includeHiddenFiles))
            }
        }
        // Drop any tree contained in another candidate (compare standardized paths).
        let paths = candidates.map { $0.url.standardizedFileURL.path }
        var keep: [WalkTree] = []
        for (index, tree) in candidates.enumerated() {
            let path = paths[index]
            let containedByOther = paths.enumerated().contains { otherIndex, otherPath in
                otherIndex != index
                    && otherPath != path
                    && (path == otherPath || path.hasPrefix(otherPath + "/"))
            }
            if !containedByOther { keep.append(tree) }
        }
        return keep
    }

    private static func contains(_ parent: URL, _ child: URL) -> Bool {
        let parentPath = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return childPath.hasPrefix(parentPath + "/")
    }

    public func run() throws -> StorageCensusReport {
        let started = Date()
        var diagnostics = StorageScanDiagnostics(metricLabel: metricLabel)
        let manager = FileManager.default

        var buckets: [StorageCensusBucket] = []
        for root in roots {
            let exists = manager.fileExists(atPath: root.url.path)
            buckets.append(StorageCensusBucket(
                id: root.id,
                attribution: root.attribution,
                exists: exists,
                isCloneCapable: root.potentiallyCloned
            ))
        }

        func prefix(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasSuffix("/") ? path : path + "/"
        }

        let rootPrefixes = roots.enumerated().map { (index: $0.offset, prefix: prefix($0.element.url)) }
        let parentPath = parentURL?.standardizedFileURL.path

        func rootIndex(for path: String) -> Int? {
            var best: (index: Int, length: Int)?
            for entry in rootPrefixes where path.hasPrefix(entry.prefix) {
                if best == nil || entry.prefix.count > best!.length {
                    best = (entry.index, entry.prefix.count)
                }
            }
            return best?.index
        }

        let trees = Self.normalizedWalkTrees(roots: roots, parentURL: parentURL)
        var unattributed = StorageSize.zero
        var unattributedCount = 0
        let cloneLikeBucket = roots.contains { $0.potentiallyCloned }

        // File identity -> claiming attribution (-1 = unattributed remainder).
        // Claiming happens for *every* counted file, so a hard link cannot be
        // counted once as a category and again in the parent remainder.
        var claimedIdentity: [StorageFileIdentity: Int] = [:]

        // Measured APFS clone/private accounting (public-SDK getattrlist).
        // `cloneMeasurementActive` flips off permanently when the volume
        // rejects the query, so an unsupported filesystem costs one syscall.
        var cloneMeasurementActive = cloneAttributeProvider != nil
        var cloneSharingDetected = false
        // Clone streams are grouped by (volume identity, clone-id), never by
        // clone-id alone: clone ids are scoped to the volume, so the same id on
        // two different devices is NOT the same data stream and must not be
        // deduplicated. The device comes from the file identity already
        // computed for inode dedup; when it is unavailable the stream cannot be
        // claimed across files, so no exact dedup happens for that file.
        var claimedCloneStreams: Set<CloneStreamKey> = []
        var measuredPrivateBytes: Int64 = 0
        var cloneAttributeFileCount = 0
        var cloneAttributeFailureCount = 0
        var dedupedCloneBytes: Int64 = 0
        var dedupedCloneFileCount = 0

        // Measured physical-extent union (public fcntl F_LOG2PHYS_EXT). The
        // union is all-or-nothing: any per-file failure, unsupported volume,
        // anomalous mapping or budget overflow withholds it for the WHOLE
        // snapshot, so the accepted allocated basis is kept unchanged and no
        // partial union is ever subtracted.
        var extentUnionBuilder = StorageExtentUnionBuilder(maxIntervals: extentBudget.maxIntervals)
        var extentFailure: StorageExtentProbeFailure?
        var extentMeasuredFileCount = 0
        var extentTotalCalls = 0
        var extentBundleRequested = false
        let extentPassStart = Date()

        func degradeExtentBasis(_ failure: StorageExtentProbeFailure) {
            if extentFailure == nil { extentFailure = failure }
        }

        /// Snapshot-level bounds for the NEXT file's walk. The reader enforces
        /// them inside its per-offset loop, so one large fragmented file can
        /// never exceed the global call/time budget before the per-file cap.
        func extentRemainingBudget() -> StorageExtentRemainingBudget {
            StorageExtentRemainingBudget(
                maxCalls: max(0, extentBudget.maxTotalCalls - extentTotalCalls),
                deadline: extentPassStart.addingTimeInterval(extentBudget.maxDuration)
            )
        }

        func extentBudgetAllowsAnotherCall() -> Bool {
            if Date().timeIntervalSince(extentPassStart) > extentBudget.maxDuration {
                degradeExtentBasis(.budgetExceeded)
                return false
            }
            if extentTotalCalls >= extentBudget.maxTotalCalls {
                degradeExtentBasis(.budgetExceeded)
                return false
            }
            return true
        }

        for tree in trees {
            if isCancelled() { throw StorageCensusError.cancelled }
            guard manager.fileExists(atPath: tree.url.path) else { continue }

            var options: FileManager.DirectoryEnumerationOptions = []
            if !tree.includeHidden { options.insert(.skipsHiddenFiles) }
            let errorCounter = ErrorCounter()

            guard let enumerator = manager.enumerator(
                at: tree.url,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: options,
                errorHandler: { _, _ in
                    errorCounter.increment()
                    return true
                }
            ) else {
                diagnostics.errorCount += 1
                continue
            }

            for case let itemURL as URL in enumerator {
                if isCancelled() { throw StorageCensusError.cancelled }

                let values: URLResourceValues
                do {
                    values = try itemURL.resourceValues(forKeys: Self.resourceKeys)
                } catch {
                    let code = (error as NSError).code
                    if code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError {
                        diagnostics.changedOrVanishedCount += 1
                    } else {
                        diagnostics.errorCount += 1
                    }
                    continue
                }

                if values.isSymbolicLink == true {
                    diagnostics.symbolicLinkCount += 1
                    continue
                }
                if values.isDirectory == true {
                    diagnostics.directoryCount += 1
                    continue
                }
                guard values.isRegularFile == true else { continue }

                let logical = Int64(values.fileSize ?? 0)
                let allocated = Self.allocatedMeasurement(at: itemURL, values: values)
                if !allocated.measured { diagnostics.allocatedUnavailableCount += 1 }
                let size = StorageSize(logicalBytes: logical, allocatedBytes: allocated.bytes)
                diagnostics.regularFileCount += 1
                if let onProgress, diagnostics.regularFileCount % 256 == 0 {
                    onProgress(diagnostics.regularFileCount)
                }

                let path = itemURL.standardizedFileURL.path
                let idx = rootIndex(for: path)
                let attributionIndex: Int? = idx
                    ?? (parentPath != nil ? -1 : nil)
                guard let attributionIndex else { continue }

                // Identity dedup across every bucket *and* the unattributed
                // remainder: claim before attributing. The same identity also
                // carries the volume the clone-stream key is grouped by.
                let identity = Self.fileIdentity(at: itemURL)
                if let identity {
                    if let firstIndex = claimedIdentity[identity] {
                        diagnostics.dedupedFileCount += 1
                        if let idx {
                            if firstIndex == -1 {
                                // The duplicate was first seen in the parent
                                // remainder; move it to the category that owns
                                // it so enumeration order cannot change totals.
                                unattributed = StorageSize(
                                    logicalBytes: max(0, unattributed.logicalBytes - size.logicalBytes),
                                    allocatedBytes: max(0, unattributed.allocatedBytes - size.allocatedBytes)
                                )
                                unattributedCount = max(0, unattributedCount - 1)
                                buckets[idx].size = buckets[idx].size + size
                                buckets[idx].fileCount += 1
                                claimedIdentity[identity] = idx
                            } else if firstIndex != idx {
                                buckets[idx].sharedSize = buckets[idx].sharedSize + size
                            }
                        }
                        continue
                    }
                    claimedIdentity[identity] = attributionIndex
                } else {
                    diagnostics.identityUnavailableCount += 1
                }

                // Measured clone/private attributes. Zero-length files cannot
                // share blocks, so skip the syscall for them.
                var dedupedCloneStream = false
                if cloneMeasurementActive, logical > 0, let cloneAttributeProvider {
                    switch cloneAttributeProvider(path) {
                    case .attributes(let attributes):
                        cloneAttributeFileCount += 1
                        measuredPrivateBytes += attributes.privateBytes
                        if attributionIndex >= 0 {
                            buckets[attributionIndex].measuredPrivateBytes += attributes.privateBytes
                        }
                        if attributes.mayShareBlocks {
                            cloneSharingDetected = true
                            if attributionIndex >= 0 {
                                buckets[attributionIndex].isCloneCapable = true
                            }
                        }
                        if attributes.sharesAllBlocks, attributes.cloneID != 0,
                           let volumeIdentity = cloneStreamVolumeProvider?(path) ?? identity?.device {
                            let streamKey = CloneStreamKey(
                                device: volumeIdentity, cloneID: attributes.cloneID
                            )
                            if claimedCloneStreams.contains(streamKey) {
                                // Exact dedup of a pure clone family on ONE
                                // volume: the stream was already counted once.
                                dedupedCloneStream = true
                                dedupedCloneFileCount += 1
                                dedupedCloneBytes += size.allocatedBytes
                                if attributionIndex >= 0 {
                                    buckets[attributionIndex].dedupedCloneSize =
                                        buckets[attributionIndex].dedupedCloneSize + size
                                }
                                cloneSharingDetected = true
                            } else {
                                claimedCloneStreams.insert(streamKey)
                            }
                        }
                    case .unsupported:
                        cloneMeasurementActive = false
                    case .unavailable:
                        cloneAttributeFailureCount += 1
                    }
                }

                // Measured physical extents for every counted regular file,
                // including zero-length ones: a zero-length inode that still
                // holds allocated blocks (resource fork) must fail the basis
                // instead of being silently omitted from the union. Pure
                // full-clone duplicates are skipped because their runs are
                // identical to the stream already claimed, so the union is
                // unchanged. Hard links never reach this point twice (identity
                // dedup above), and even if identity were unavailable the
                // union would still deduplicate their identical runs by
                // physical overlap — the allocated basis and the extent basis
                // each count every block once and neither subtracts the other.
                if let extentProbe, !dedupedCloneStream, extentFailure == nil,
                   extentBudgetAllowsAnotherCall() {
                    switch extentProbe.read(
                        path, identity?.device, identity?.inode,
                        extentRemainingBudget(), isCancelled
                    ) {
                    case .measured(let measurement):
                        extentMeasuredFileCount += 1
                        extentTotalCalls += measurement.callCount
                        if !extentUnionBuilder.add(
                            runs: measurement.runs, owner: Int32(attributionIndex)
                        ) {
                            degradeExtentBasis(.budgetExceeded)
                        }
                    case .unsupported:
                        degradeExtentBasis(.unsupportedFilesystem)
                    case .failed(.cancelled):
                        throw StorageCensusError.cancelled
                    case .failed(let failure):
                        degradeExtentBasis(failure)
                    }
                }
                if dedupedCloneStream {
                    // The BYTES are physically shared with an already counted
                    // stream and are not added again. The FILE is a distinct
                    // identity (different inode) and still counts as a scanned
                    // file in its category; the UI labels this column "files".
                    if attributionIndex >= 0 {
                        buckets[attributionIndex].fileCount += 1
                    } else {
                        unattributedCount += 1
                    }
                    continue
                }

                if attributionIndex >= 0 {
                    buckets[attributionIndex].size = buckets[attributionIndex].size + size
                    buckets[attributionIndex].fileCount += 1
                } else {
                    unattributed = unattributed + size
                    unattributedCount += 1
                }
            }
            diagnostics.errorCount += errorCounter.value
        }

        // Optional app-bundle measurement into the SAME union. The bundle
        // lives outside every data root, so a resource cloned from the bundle
        // into Documents would otherwise be counted twice once the installer
        // figure is added to a data-only union. Only runs while the basis is
        // still coherent; any unreadable bundle entry withholds the union
        // instead of publishing a known-double-counted total.
        if let extentProbe, extentFailure == nil, let bundleMeasurementURL {
            extentBundleRequested = true
            if isCancelled() { throw StorageCensusError.cancelled }
            if !manager.fileExists(atPath: bundleMeasurementURL.path) {
                degradeExtentBasis(.bundleUnreadable)
            } else {
                let bundleErrorCounter = ErrorCounter()
                if let bundleEnumerator = manager.enumerator(
                    at: bundleMeasurementURL,
                    includingPropertiesForKeys: Array(Self.resourceKeys),
                    options: [],
                    errorHandler: { _, _ in
                        bundleErrorCounter.increment()
                        return true
                    }
                ) {
                    for case let itemURL as URL in bundleEnumerator {
                        if isCancelled() { throw StorageCensusError.cancelled }
                        guard extentFailure == nil else { break }
                        guard let values = try? itemURL.resourceValues(forKeys: Self.resourceKeys) else {
                            degradeExtentBasis(.bundleUnreadable)
                            break
                        }
                        if values.isSymbolicLink == true || values.isDirectory == true { continue }
                        guard values.isRegularFile == true else { continue }
                        // Zero-length entries are probed too: an inode that
                        // still holds allocated blocks must fail the basis
                        // rather than be silently omitted.
                        guard extentBudgetAllowsAnotherCall() else { break }
                        switch extentProbe.read(
                            itemURL.standardizedFileURL.path, nil, nil,
                            extentRemainingBudget(), isCancelled
                        ) {
                        case .measured(let measurement):
                            extentMeasuredFileCount += 1
                            extentTotalCalls += measurement.callCount
                            if !extentUnionBuilder.add(
                                runs: measurement.runs, owner: StorageExtentOwner.bundle
                            ) {
                                degradeExtentBasis(.budgetExceeded)
                            }
                        case .unsupported:
                            degradeExtentBasis(.unsupportedFilesystem)
                        case .failed(.cancelled):
                            throw StorageCensusError.cancelled
                        case .failed(let failure):
                            degradeExtentBasis(failure)
                        }
                    }
                    if bundleErrorCounter.value > 0 {
                        degradeExtentBasis(.bundleUnreadable)
                    }
                } else {
                    degradeExtentBasis(.bundleUnreadable)
                }
            }
        }

        // Publish the union only when every measured file answered
        // coherently; otherwise the accepted allocated basis is retained and
        // the reason is kept as an internal aggregate flag.
        var extentSummary: StorageExtentUnionSummary?
        if extentProbe == nil {
            diagnostics.extentBasis = .notRequested
        } else if let extentFailure {
            diagnostics.extentBasis = .unavailable
            diagnostics.extentUnavailableReason = extentFailure
        } else {
            let union = extentUnionBuilder.finalize()
            var categoryBytes: [String: Int64] = [:]
            var unattributedExtentBytes: Int64 = 0
            var bundleExtentBytes: Int64? = extentBundleRequested ? 0 : nil
            for (owner, bytes) in union.bytesByOwner where bytes > 0 {
                if owner >= 0, Int(owner) < buckets.count {
                    categoryBytes[buckets[Int(owner)].id] = bytes
                } else if owner == StorageExtentOwner.unattributed {
                    unattributedExtentBytes += bytes
                } else if owner == StorageExtentOwner.bundle {
                    bundleExtentBytes = (bundleExtentBytes ?? 0) + bytes
                }
            }
            diagnostics.extentBasis = .available
            extentSummary = StorageExtentUnionSummary(
                totalBytes: union.totalBytes,
                bundleBytes: bundleExtentBytes,
                unattributedBytes: unattributedExtentBytes,
                categoryBytes: categoryBytes,
                measuredFileCount: extentMeasuredFileCount,
                callCount: extentTotalCalls,
                intervalCount: union.intervalCount
            )
        }

        diagnostics.dedupedCloneFileCount = dedupedCloneFileCount
        diagnostics.dedupedCloneBytes = dedupedCloneBytes
        diagnostics.cloneAttributeFileCount = cloneAttributeFileCount
        diagnostics.cloneAttributeFailureCount = cloneAttributeFailureCount
        diagnostics.cloneAttributeSupport = cloneAttributeProvider == nil
            ? .notRequested
            : (cloneMeasurementActive ? .supported : .unavailable)
        diagnostics.measuredPrivateBytes = measuredPrivateBytes
        diagnostics.duration = Date().timeIntervalSince(started)
        diagnostics.completedAt = Date()
        onProgress?(diagnostics.regularFileCount)
        return StorageCensusReport(
            buckets: buckets,
            diagnostics: diagnostics,
            unattributedSize: unattributed,
            unattributedCount: unattributedCount,
            isSharedAllocationEstimate: cloneLikeBucket
                || cloneSharingDetected
                || dedupedCloneBytes > 0,
            extentUnion: extentSummary
        )
    }
}
