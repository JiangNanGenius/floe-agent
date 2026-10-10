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
public struct StorageSize: Sendable, Equatable {
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

/// Diagnostics collected during a scan. Paths, names and contents are never
/// retained; only category, count, size, timing and error counters, so this is
/// safe to log and export.
public struct StorageScanDiagnostics: Sendable, Equatable {
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
public struct StorageCensusRoot: Sendable {
    public enum Attribution: Sendable, Equatable {
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
public struct StorageCensusBucket: Sendable, Equatable, Identifiable {
    public let id: String
    public let attribution: StorageCensusRoot.Attribution
    public let exists: Bool
    public var size: StorageSize
    public var fileCount: Int
    /// Bytes in this root already claimed by another identity (hard link / root
    /// overlap). Not added to the total; reported for transparency.
    public var sharedSize: StorageSize

    public init(
        id: String,
        attribution: StorageCensusRoot.Attribution,
        exists: Bool,
        size: StorageSize = .zero,
        fileCount: Int = 0,
        sharedSize: StorageSize = .zero
    ) {
        self.id = id
        self.attribution = attribution
        self.exists = exists
        self.size = size
        self.fileCount = fileCount
        self.sharedSize = sharedSize
    }
}

/// Result of a single mutually-exclusive categorized snapshot.
public struct StorageCensusReport: Sendable, Equatable {
    public var buckets: [StorageCensusBucket]
    public var diagnostics: StorageScanDiagnostics
    /// Size of files inside `parentURL` but outside every supplied root.
    public var unattributedSize: StorageSize
    public var unattributedCount: Int
    /// True when clone-backed roots were walked; allocated bytes are an upper
    /// estimate rather than an exact figure.
    public var isSharedAllocationEstimate: Bool

    public var totalAllocatedBytes: Int64 {
        buckets.reduce(Int64(0)) { $0 + $1.size.allocatedBytes }
            + unattributedSize.allocatedBytes
    }

    public var totalLogicalBytes: Int64 {
        buckets.reduce(Int64(0)) { $0 + $1.size.logicalBytes }
            + unattributedSize.logicalBytes
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
        onProgress: (@Sendable (Int) -> Void)? = nil
    ) {
        self.roots = roots
        self.parentURL = parentURL?.standardizedFileURL.resolvingSymlinksInPath()
        self.metricLabel = metricLabel
        self.isCancelled = isCancelled
        self.onProgress = onProgress
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
            buckets.append(StorageCensusBucket(id: root.id, attribution: root.attribution, exists: exists))
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
                // remainder: claim before attributing.
                if let identity = Self.fileIdentity(at: itemURL) {
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

        diagnostics.duration = Date().timeIntervalSince(started)
        diagnostics.completedAt = Date()
        onProgress?(diagnostics.regularFileCount)
        return StorageCensusReport(
            buckets: buckets,
            diagnostics: diagnostics,
            unattributedSize: unattributed,
            unattributedCount: unattributedCount,
            isSharedAllocationEstimate: cloneLikeBucket
        )
    }
}
