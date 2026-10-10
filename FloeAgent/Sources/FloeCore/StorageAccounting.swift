import Foundation

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
///   (`totalFileAllocatedSize`, including extents/cluster overhead; sparse-aware).
///
/// Both are recorded; neither is asserted to be the same figure iOS shows in
/// Settings → General → iPad|iPhone Storage, whose methodology is not published
/// and may count app data, caches and purgeable space differently.
///
/// Two sharing effects matter and are handled differently:
///
/// - **Hard links and nested/overlapping scan roots** are the same on-disk bytes
///   and are deduplicated *exactly* by file identity (device + inode), so they
///   are never counted twice.
/// - **APFS copy-on-write clones** (used for VM images/base slices) may share
///   physical blocks across files with *distinct* inodes, and after divergence a
///   clone may hold unique blocks. That sharing cannot be measured from `stat`,
///   so such roots are still counted in full (no silent undercount) and the
///   report is explicitly flagged as an upper estimate via
///   ``StorageCensusReport/isSharedAllocationEstimate``. We never subtract on the
///   basis of *potential* sharing.
public struct StorageSize: Sendable, Equatable {
    /// Apparent file length in bytes (sparse disks report their full capacity).
    public var logicalBytes: Int64
    /// Host-allocated bytes including extents/cluster overhead (sparse-aware).
    public var allocatedBytes: Int64

    public init(logicalBytes: Int64, allocatedBytes: Int64) {
        self.logicalBytes = max(0, logicalBytes)
        self.allocatedBytes = max(0, allocatedBytes)
    }

    public static let zero = StorageSize(logicalBytes: 0, allocatedBytes: 0)
}

/// Stable on-disk identity used to deduplicate hard links and overlapping roots
/// exactly (device + inode). APFS CoW *clones* have distinct inodes and are not
/// collapsed here; see the file-level note about shared-allocation estimates.
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
    /// Files skipped because they were already counted via another root or a
    /// hard link (exact, identity-based dedup).
    public var dedupedFileCount: Int
    /// Files that vanished or changed while being enumerated (benign race).
    public var changedOrVanishedCount: Int
    /// Entries that could not be read (permission, I/O, corrupt resource value).
    public var errorCount: Int
    /// Wall-clock duration of the scan.
    public var duration: TimeInterval
    /// Stable label identifying which census produced these metrics.
    public var metricLabel: String

    public init(
        regularFileCount: Int = 0,
        directoryCount: Int = 0,
        symbolicLinkCount: Int = 0,
        dedupedFileCount: Int = 0,
        changedOrVanishedCount: Int = 0,
        errorCount: Int = 0,
        duration: TimeInterval = 0,
        metricLabel: String = ""
    ) {
        self.regularFileCount = regularFileCount
        self.directoryCount = directoryCount
        self.symbolicLinkCount = symbolicLinkCount
        self.dedupedFileCount = dedupedFileCount
        self.changedOrVanishedCount = changedOrVanishedCount
        self.errorCount = errorCount
        self.duration = duration
        self.metricLabel = metricLabel
    }
}

/// A root to include in a mutually-exclusive census. Nested/overlapping roots
/// are resolved to the most specific (deepest) match.
public struct StorageCensusRoot: Sendable {
    public enum Attribution: Sendable, Equatable {
        /// Counted and reported as its own category.
        case category
        /// Counted in full and reported separately, but flagged as *potentially
        /// sharing* APFS clone blocks (e.g. a content-addressed image store).
        /// The bytes are still included in the total — clones can hold unique
        /// blocks, so we never subtract for sharing we cannot measure.
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

/// Per-root result. Byte values are unique to this bucket after identity dedup;
/// files already claimed by an earlier/deeper root are not re-added.
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
    /// True when the scan walked roots that commonly hold APFS CoW clones. In
    /// that case allocated bytes are an upper estimate because clones share
    /// blocks across distinct inodes and cannot be split honestly from `stat`.
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
/// cause double counting.
public struct StorageCensus: Sendable {
    public let roots: [StorageCensusRoot]
    /// Optional parent directory; files inside it but outside all roots are
    /// tallied as unattributed/other. Typically the app data container.
    public let parentURL: URL?
    public let metricLabel: String
    /// Polled cooperatively for cancellation.
    public let isCancelled: @Sendable () -> Bool

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .fileAllocatedSizeKey,
        .totalFileAllocatedSizeKey
    ]

    /// Exact on-disk identity (device + inode) via Foundation attributes. Used
    /// for hard-link/root-overlap dedup. Returns nil if attributes are
    /// unreadable, in which case the file is counted without dedup metadata.
    static func fileIdentity(at url: URL) -> StorageFileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        guard let device, let inode else { return nil }
        return StorageFileIdentity(device: device, inode: inode)
    }

    public init(
        roots: [StorageCensusRoot],
        parentURL: URL? = nil,
        metricLabel: String = "storage.census",
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.roots = roots
        self.parentURL = parentURL?.standardizedFileURL.resolvingSymlinksInPath()
        self.metricLabel = metricLabel
        self.isCancelled = isCancelled
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

        // Walk each physical tree once. A parent walk covers every root it
        // contains; roots outside the parent (Caches/, tmp/) walk separately.
        struct WalkTree { let url: URL; let includeHidden: Bool }
        var trees: [WalkTree] = []
        if let parentURL {
            trees.append(WalkTree(url: parentURL, includeHidden: true))
            for root in roots where !root.url.path.hasPrefix(prefix(parentURL)) && root.url.path != parentPath {
                trees.append(WalkTree(url: root.url, includeHidden: root.includeHiddenFiles))
            }
        } else {
            for root in roots { trees.append(WalkTree(url: root.url, includeHidden: root.includeHiddenFiles)) }
        }

        var unattributed = StorageSize.zero
        var unattributedCount = 0
        var cloneLikeBucket = roots.contains { $0.potentiallyCloned }

        // File identity -> root index that first claimed it. Makes hard links
        // and nested/overlapping roots mutually exclusive exactly.
        var claimedIdentity: [StorageFileIdentity: Int] = [:]

        for tree in trees {
            if isCancelled() { throw StorageCensusError.cancelled }
            guard manager.fileExists(atPath: tree.url.path) else { continue }

            var options: FileManager.DirectoryEnumerationOptions = []
            if !tree.includeHidden { options.insert(.skipsHiddenFiles) }

            guard let enumerator = manager.enumerator(
                at: tree.url,
                includingPropertiesForKeys: Array(Self.resourceKeys),
                options: options
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

                let identity = Self.fileIdentity(at: itemURL)
                let logical = Int64(values.fileSize ?? 0)
                let allocated = Int64(values.totalFileAllocatedSize
                                      ?? values.fileAllocatedSize
                                      ?? values.fileSize ?? 0)
                let size = StorageSize(logicalBytes: logical, allocatedBytes: allocated)
                diagnostics.regularFileCount += 1

                let path = itemURL.standardizedFileURL.path
                guard let idx = rootIndex(for: path) else {
                    if parentPath != nil {
                        unattributed = StorageSize(
                            logicalBytes: unattributed.logicalBytes + size.logicalBytes,
                            allocatedBytes: unattributed.allocatedBytes + size.allocatedBytes
                        )
                        unattributedCount += 1
                    }
                    continue
                }

                if let identity {
                    if let firstIndex = claimedIdentity[identity] {
                        diagnostics.dedupedFileCount += 1
                        if firstIndex != idx {
                            buckets[idx].sharedSize = StorageSize(
                                logicalBytes: buckets[idx].sharedSize.logicalBytes + size.logicalBytes,
                                allocatedBytes: buckets[idx].sharedSize.allocatedBytes + size.allocatedBytes
                            )
                        }
                        continue
                    }
                    claimedIdentity[identity] = idx
                }
                buckets[idx].size = StorageSize(
                    logicalBytes: buckets[idx].size.logicalBytes + size.logicalBytes,
                    allocatedBytes: buckets[idx].size.allocatedBytes + size.allocatedBytes
                )
                buckets[idx].fileCount += 1
            }
        }

        diagnostics.duration = Date().timeIntervalSince(started)
        return StorageCensusReport(
            buckets: buckets,
            diagnostics: diagnostics,
            unattributedSize: unattributed,
            unattributedCount: unattributedCount,
            isSharedAllocationEstimate: cloneLikeBucket
        )
    }
}
