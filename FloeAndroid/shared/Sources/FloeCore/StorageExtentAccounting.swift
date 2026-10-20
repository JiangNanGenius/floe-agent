// FloeCore — Measured physical extents through the public fcntl
// `F_LOG2PHYS_EXT` primitive, and the exact block union of a measured file
// set.
//
// Why this exists (Build 273 feedback: Settings → Data Management showed
// >100 GB on an upgraded iPad while iOS Storage showed about 20 GB):
//
//   * An APFS CoW clone or hard link reports its FULL allocated size through
//     `stat`/`getattrlist`, and partially-CoW-split families cannot be
//     deduplicated from clone-ids alone. Summing allocated sizes therefore
//     over-counts every shared block that is not part of a pure full clone.
//   * `fcntl(fd, F_LOG2PHYS_EXT, &log2phys)` (public SDK: macOS, iPhoneOS and
//     iPhoneSimulator `sys/fcntl.h`) maps a file offset to the backing device
//     offset and the length of the physically contiguous run. Shared extents
//     of clones and hard links return identical device offsets; CoW-rewritten
//     extents return different offsets exactly over the rewritten range;
//     genuinely unallocated holes return `devoffset == -1`. The sorted union
//     of these runs is the measured physical block footprint of the set.
//
// Accounting semantics — read carefully:
//
//   * The union counts DATA BLOCKS referenced by the measured file set,
//     deduplicated within the set at snapshot time. It excludes filesystem
//     metadata/checksums, blocks retained only by APFS snapshots, and extra
//     forks (a resource-fork-only file cannot be mapped here); it still
//     includes blocks that are also shared with files outside the set. It is
//     NOT the app size iOS Storage accounts for, NOT device usage and NOT a
//     reclaimable number.
//   * Raw device offsets are opaque comparison keys: never persisted, logged,
//     shown, or exported. Only aggregated bytes leave this file.
//   * Any per-file failure, unsupported filesystem, anomalous mapping or
//     budget overflow withholds the WHOLE union for the snapshot
//     (``StorageExtentProbeResult``); callers keep the accepted allocated
//     basis and never subtract a partial union.
//
// `st_blocks` cross-check (measured on APFS): a coherent data-fork walk
// returns exactly `st_blocks * 512` bytes for regular files of every size,
// including files whose logical size is not block-aligned (the kernel returns
// the block-rounded tail when `want` is not clipped to the remaining logical
// bytes). Any mismatch means an unmappable class (compressed mapping, extra
// fork, unexpected semantics) and fails closed instead of guessing a round
// unit or counting a small file as 0 / as its logical length.

import Foundation
#if canImport(Android)
import Android
#endif
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CFloeExtentShim)
import CFloeExtentShim
#endif

/// One physically contiguous run of device bytes backing part of a file.
/// `deviceOffset` is a raw volume byte offset and must remain opaque.
public struct StoragePhysicalRun: Sendable, Equatable {
    /// `st_dev` of the file's volume (runs are only comparable within it).
    public let device: UInt64
    /// Device byte offset of the run start (>= 0; `-1` holes are never a run).
    public let deviceOffset: Int64
    /// Length of the physically contiguous run in bytes.
    public let length: Int64

    public init(device: UInt64, deviceOffset: Int64, length: Int64) {
        self.device = device
        self.deviceOffset = deviceOffset
        self.length = max(0, length)
    }
}

/// Why a file's extents could not be mapped coherently. A single failure
/// withholds the whole union for the snapshot.
public enum StorageExtentProbeFailure: String, Sendable, Equatable, Codable, Error {
    /// `open` failed for a reason other than a raced replacement.
    case openFailed
    /// The descriptor is not a regular file.
    case notRegularFile
    /// The file was replaced/removed/changed between enumeration, open and
    /// the post-walk `fstat` (or `O_NOFOLLOW` caught a symlink swap).
    case changedWhileWalking
    /// The volume/kernel does not implement the extent primitive.
    case unsupportedFilesystem
    /// A compressed (decmpfs) mapping: its blocks cannot be enumerated here.
    case compressedMapping
    /// The primitive failed for one offset.
    case callFailed
    /// `lseek(SEEK_DATA/SEEK_HOLE)` failed or reported an inconsistent region.
    case seekFailed
    /// A call returned no progress (`contigbytes <= 0`).
    case zeroProgress
    /// A device/file offset would overflow.
    case offsetOverflow
    /// The measured runs do not reconcile with `st_blocks` (extra fork,
    /// compressed mapping or unexpected allocation semantics).
    case allocationMismatch
    /// The per-file or per-snapshot budget was exhausted.
    case budgetExceeded
    /// The scan was cancelled; the snapshot keeps its previous value.
    case cancelled
    /// The optional bundle root could not be enumerated, so the cross-root
    /// union cannot be claimed as complete.
    case bundleUnreadable
}

/// One file's measured data-fork runs.
public struct StorageExtentMeasurement: Sendable, Equatable {
    public let runs: [StoragePhysicalRun]
    /// Number of `fcntl` calls used (bounded; drives the snapshot budget).
    public let callCount: Int

    public init(runs: [StoragePhysicalRun], callCount: Int) {
        self.runs = runs
        self.callCount = max(0, callCount)
    }
}

public enum StorageExtentProbeResult: Sendable, Equatable {
    case measured(StorageExtentMeasurement)
    /// The volume cannot answer the primitive; the snapshot must keep the
    /// allocated basis.
    case unsupported
    case failed(StorageExtentProbeFailure)
}

/// Bounds for one file's extent walk.
public struct StorageExtentProbeConfiguration: Sendable, Equatable {
    /// Requested length per `fcntl` call. Bounded but deliberately large so a
    /// 100 GB sparse VM disk never loops block by block; the kernel always
    /// returns at most the file's own contiguous run, and the block-rounded
    /// tail is included because the request is never clipped to the remaining
    /// logical bytes.
    public var chunkBytes: Int64
    /// Hard per-file call cap; exceeding it fails closed.
    public var maxCallsPerFile: Int

    public static let `default` = StorageExtentProbeConfiguration(
        chunkBytes: 16 * 1024 * 1024,
        maxCallsPerFile: 1_000_000
    )

    public init(chunkBytes: Int64, maxCallsPerFile: Int) {
        self.chunkBytes = max(1, chunkBytes)
        self.maxCallsPerFile = max(1, maxCallsPerFile)
    }
}

/// Bounds for the extent pass of one snapshot. All three are enforced
/// cooperatively (cancellation and checks between calls); hitting any of them
/// withholds the union instead of scanning unbounded.
public struct StorageExtentBudget: Sendable, Equatable {
    /// Total `fcntl` calls across every measured file.
    public var maxTotalCalls: Int
    /// Total collected physical intervals before the union sweep.
    public var maxIntervals: Int
    /// Wall clock for the whole extent pass.
    public var maxDuration: TimeInterval

    public static let `default` = StorageExtentBudget(
        maxTotalCalls: 4_000_000,
        maxIntervals: 1_000_000,
        maxDuration: 180
    )

    public init(maxTotalCalls: Int, maxIntervals: Int, maxDuration: TimeInterval) {
        self.maxTotalCalls = max(1, maxTotalCalls)
        self.maxIntervals = max(1, maxIntervals)
        self.maxDuration = max(1, maxDuration)
    }
}

/// Remaining snapshot-level bounds handed into ONE file's walk. The global
/// call budget and wall-clock deadline are enforced inside the per-offset
/// loop, so a single huge/fragmented file cannot exceed them before the
/// per-file cap; cancellation and budget stay distinct (`.cancelled` cancels
/// the scan, `.budgetExceeded` only withholds the union).
public struct StorageExtentRemainingBudget: Sendable, Equatable {
    /// Remaining total `fcntl` calls for this snapshot.
    public var maxCalls: Int
    /// Absolute wall-clock deadline of the snapshot's extent pass.
    public var deadline: Date

    public init(maxCalls: Int, deadline: Date) {
        self.maxCalls = max(0, maxCalls)
        self.deadline = deadline
    }

    /// Unbounded (direct reader callers/tests).
    public static let unbounded = StorageExtentRemainingBudget(
        maxCalls: Int.max, deadline: .distantFuture
    )
}

/// Injectable extent probe seam. Production uses ``system``; tests inject
/// deterministic run sets (or failures) without touching a real filesystem.
public struct StorageExtentProbe: Sendable {
    public typealias Reader = @Sendable (
        _ path: String,
        _ expectedDevice: UInt64?,
        _ expectedInode: UInt64?,
        _ remaining: StorageExtentRemainingBudget,
        _ isCancelled: @Sendable () -> Bool
    ) -> StorageExtentProbeResult

    public let read: Reader

    public init(read: @escaping Reader) {
        self.read = read
    }

    /// The real public-SDK reader (`fcntl F_LOG2PHYS_EXT`).
    public static let system = StorageExtentProbe(configuration: .default)

    public init(configuration: StorageExtentProbeConfiguration) {
        self.read = { path, expectedDevice, expectedInode, remaining, isCancelled in
            StorageExtentProbeReader.read(
                path: path,
                expectedDevice: expectedDevice,
                expectedInode: expectedInode,
                configuration: configuration,
                remaining: remaining,
                isCancelled: isCancelled
            )
        }
    }
}

/// Owner keys used by the union builder. Bucket owners are the bucket's index
/// in the census root list; the two negative keys are reserved.
enum StorageExtentOwner {
    /// Files inside the parent walk but outside every root.
    static let unattributed: Int32 = -1
    /// Files of the optional app-bundle measurement root.
    static let bundle: Int32 = -2
}

/// Per-snapshot union result: bytes by owner plus aggregate counts. Only
/// aggregates are produced — no offsets, paths or names.
struct StorageExtentUnionResult: Equatable {
    var totalBytes: Int64
    var bytesByOwner: [Int32: Int64]
    var intervalCount: Int
}

/// Incremental, bounded union of measured runs grouped by volume. Runs are
/// merged per file while collected, then sorted by `(device, start, end,
/// owner)` and swept so every device byte is claimed exactly once by a
/// deterministic owner (lowest sort key wins an overlap). Owner sums
/// therefore always reconcile with the single global total.
struct StorageExtentUnionBuilder {
    private var intervals: [StoragePhysicalInterval]
    private let maxIntervals: Int

    private struct StoragePhysicalInterval {
        var device: UInt64
        var start: Int64
        var end: Int64
        var owner: Int32
    }

    init(maxIntervals: Int) {
        self.intervals = []
        self.maxIntervals = max(1, maxIntervals)
    }

    /// Adds one file's runs under `owner`. Returns false without changing the
    /// collected set when the interval budget would be exceeded (the caller
    /// treats it as a withheld union).
    mutating func add(runs: [StoragePhysicalRun], owner: Int32) -> Bool {
        guard !runs.isEmpty else { return true }
        if intervals.count + runs.count > maxIntervals { return false }
        for run in runs where run.length > 0 {
            let end = run.deviceOffset + run.length
            if let last = intervals.last, last.owner == owner, last.device == run.device,
               last.end == run.deviceOffset {
                intervals[intervals.count - 1].end = end
            } else {
                intervals.append(StoragePhysicalInterval(
                    device: run.device, start: run.deviceOffset, end: end, owner: owner
                ))
            }
        }
        return true
    }

    /// Sorts and sweeps the collected intervals. Deterministic and exact:
    /// overlapping/adjacent runs (full clones, partial clones, hard links)
    /// never double count, and independent copies at different device offsets
    /// always count separately.
    mutating func finalize() -> StorageExtentUnionResult {
        intervals.sort { lhs, rhs in
            if lhs.device != rhs.device { return lhs.device < rhs.device }
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.owner < rhs.owner
        }
        var cursorByDevice: [UInt64: Int64] = [:]
        var bytesByOwner: [Int32: Int64] = [:]
        var total: Int64 = 0
        for interval in intervals {
            let cursor = cursorByDevice[interval.device] ?? Int64.min
            let from = interval.start > cursor ? interval.start : cursor
            if interval.end > from {
                let bytes = interval.end - from
                bytesByOwner[interval.owner, default: 0] += bytes
                total += bytes
                cursorByDevice[interval.device] = interval.end
            }
        }
        return StorageExtentUnionResult(
            totalBytes: total,
            bytesByOwner: bytesByOwner,
            intervalCount: intervals.count
        )
    }
}

/// Persisted aggregate of one snapshot's measured extent union. `nil` union on
/// the report means the basis is not available; a present union with a `nil`
/// `bundleBytes` means the bundle was not part of the measured set.
public struct StorageExtentUnionSummary: Codable, Equatable, Sendable {
    /// Global union bytes of every measured set (data roots, unattributed
    /// remainder and, when requested, the app bundle).
    public var totalBytes: Int64
    /// Bundle-owned share of the union; `nil` when the bundle was not
    /// measured in this snapshot.
    public var bundleBytes: Int64?
    /// Unattributed-remainder share of the union.
    public var unattributedBytes: Int64
    /// Bucket-id → owned share. Only buckets with owned bytes appear.
    public var categoryBytes: [String: Int64]
    /// Regular files measured into the union.
    public var measuredFileCount: Int
    /// `fcntl` calls used (bounded).
    public var callCount: Int
    /// Collected physical intervals before the sweep.
    public var intervalCount: Int

    public init(
        totalBytes: Int64,
        bundleBytes: Int64?,
        unattributedBytes: Int64,
        categoryBytes: [String: Int64],
        measuredFileCount: Int,
        callCount: Int,
        intervalCount: Int
    ) {
        self.totalBytes = totalBytes
        self.bundleBytes = bundleBytes
        self.unattributedBytes = unattributedBytes
        self.categoryBytes = categoryBytes
        self.measuredFileCount = measuredFileCount
        self.callCount = callCount
        self.intervalCount = intervalCount
    }
}

/// Whether the measured extent basis could be collected in a scan.
public enum StorageExtentBasisState: String, Sendable, Codable, Equatable {
    /// The caller did not request the extent probe (legacy callers/tests).
    case notRequested
    /// Every measured file answered coherently; the union is published.
    case available
    /// At least one file/volume failed or a budget was hit; the accepted
    /// allocated basis is retained and no union is published.
    case unavailable
}

public enum StorageExtentProbeReader {
    /// Walks one regular file's data-fork extents with the public
    /// `fcntl(F_LOG2PHYS_EXT)` primitive.
    ///
    /// Strategy: `lseek(SEEK_DATA/SEEK_HOLE)` (public POSIX) skips long
    /// unallocated ranges in constant time, and within each data region the
    /// extent primitive maps physically contiguous runs. If the volume does
    /// not answer `SEEK_DATA/SEEK_HOLE`, the walk degrades to a bounded
    /// sequential walk (`want = chunkBytes`) of the whole logical range. Both
    /// paths are reconciled against `st_blocks` before the result is used.
    public static func read(
        path: String,
        expectedDevice: UInt64?,
        expectedInode: UInt64?,
        configuration: StorageExtentProbeConfiguration = .default,
        remaining: StorageExtentRemainingBudget = .unbounded,
        isCancelled: @Sendable () -> Bool
    ) -> StorageExtentProbeResult {
        #if canImport(Darwin) && canImport(CFloeExtentShim)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            switch errno {
            case ELOOP, ENOENT, ESTALE:
                // Swapped to a symlink or raced away between enumeration and
                // open; the enumerated identity no longer exists.
                return .failed(.changedWhileWalking)
            default:
                return .failed(.openFailed)
            }
        }
        defer { close(fd) }

        var pre = stat()
        guard fstat(fd, &pre) == 0 else { return .failed(.openFailed) }
        guard (pre.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .failed(.notRegularFile)
        }
        if let expectedDevice, UInt64(pre.st_dev) != expectedDevice {
            return .failed(.changedWhileWalking)
        }
        if let expectedInode, UInt64(pre.st_ino) != expectedInode {
            return .failed(.changedWhileWalking)
        }

        // APFS only (measured, K2/K3): the extent identities are comparable
        // per volume and the block accounting has been reconciled there.
        //
        // The file-system check uses public `URLResourceValues` instead of
        // `fstatfs`/`statfs` (required-reason DiskSpace APIs this path derives
        // no capacity value from). A volume must report the full measured
        // capability set — file cloning (the APFS CoW feature this walk
        // deduplicates), sparse files and zero runs — to run the walk. On the
        // measured systems only APFS reports all three: HFS+ reports sparse
        // false, exFAT reports all false (and F_LOG2PHYS_EXT fails with
        // ENOTSUP), network volumes report cloning false. A volume that does
        // not answer any capability (nil) is unsupported rather than assumed,
        // and a future filesystem with a different capability set must be
        // re-measured before this gate accepts it.
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &pathBuffer) != -1 else {
            return .failed(.callFailed)
        }
        let resolvedPath = String(decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                  as: UTF8.self)
        guard let volume = try? URL(fileURLWithPath: resolvedPath)
            .resourceValues(forKeys: [.volumeSupportsFileCloningKey,
                                      .volumeSupportsSparseFilesKey,
                                      .volumeSupportsZeroRunsKey]),
            volume.volumeSupportsFileCloning == true,
            volume.volumeSupportsSparseFiles == true,
            volume.volumeSupportsZeroRuns == true else {
            return .unsupported
        }

        // Compressed (decmpfs) mappings cannot be enumerated here; measured
        // ENOTSUP/flag paths would otherwise silently under-count.
        if pre.st_flags & UInt32(UF_COMPRESSED) != 0 {
            return .failed(.compressedMapping)
        }

        let size = Int64(pre.st_size)
        // Zero-length files have no data-fork extents to map. If the inode
        // still holds allocated blocks (for example a resource-fork-only
        // file), those blocks exist but cannot be enumerated here: fail closed
        // instead of publishing a wrong 0.
        guard size > 0 else {
            guard pre.st_blocks == 0 else { return .failed(.allocationMismatch) }
            return .measured(StorageExtentMeasurement(runs: [], callCount: 0))
        }

        let device = UInt64(pre.st_dev)
        var runs: [StoragePhysicalRun] = []
        var calls = 0
        var off: Int64 = 0
        var useSeek = true

        while off < size {
            if isCancelled() { return .failed(.cancelled) }

            var regionStart = off
            if useSeek {
                errno = 0
                let data = lseek(fd, off_t(off), SEEK_DATA)
                if data < 0 {
                    if errno == ENXIO {
                        // No data at or after `off`: the remaining range is
                        // unallocated (holes contribute no blocks).
                        break
                    } else if errno == EINVAL || errno == ENOTSUP {
                        useSeek = false
                    } else {
                        return .failed(.seekFailed)
                    }
                } else if data > off {
                    regionStart = Int64(data)
                    off = regionStart
                }
            }

            var regionEnd = size
            if useSeek {
                errno = 0
                let hole = lseek(fd, off_t(regionStart), SEEK_HOLE)
                if hole < 0 {
                    if errno == EINVAL || errno == ENOTSUP {
                        useSeek = false
                    } else {
                        return .failed(.seekFailed)
                    }
                } else if Int64(hole) < regionStart {
                    // Inconsistent region report: fail closed instead of
                    // risking a missed or double-counted range.
                    return .failed(.seekFailed)
                } else {
                    regionEnd = min(Int64(hole), size)
                }
            }

            if useSeek, regionEnd <= regionStart {
                // A reported data region with no bytes cannot make progress.
                return .failed(.zeroProgress)
            }

            while off < regionEnd {
                if isCancelled() { return .failed(.cancelled) }
                // Global bounds are enforced per call, not only between files:
                // a single huge or fragmented file cannot outrun the snapshot
                // budget before the per-file cap, and cancellation stays
                // distinct from a budget overflow.
                if calls >= configuration.maxCallsPerFile { return .failed(.budgetExceeded) }
                if calls >= remaining.maxCalls { return .failed(.budgetExceeded) }
                if Date() > remaining.deadline { return .failed(.budgetExceeded) }
                // The request is NOT clipped to the logical remainder: the
                // kernel returns the block-rounded tail, which is what makes
                // unaligned file sizes reconcile with st_blocks.
                let want = configuration.chunkBytes
                var deviceOffset: Int64 = 0
                var contig: Int64 = 0
                let status = floe_log2phys_ext(fd, off, want, &deviceOffset, &contig)
                calls += 1
                guard status == 0 else {
                    switch errno {
                    case ENOTSUP, EINVAL, ENOSYS:
                        return .unsupported
                    default:
                        return .failed(.callFailed)
                    }
                }
                guard contig > 0 else { return .failed(.zeroProgress) }
                guard off <= Int64.max - contig else { return .failed(.offsetOverflow) }
                let end = off + contig
                if deviceOffset != -1 {
                    // Only -1 denotes an unbacked range; a negative offset is
                    // not a valid device offset.
                    guard deviceOffset >= 0 else { return .failed(.callFailed) }
                    guard deviceOffset <= Int64.max - contig else {
                        return .failed(.offsetOverflow)
                    }
                    if let last = runs.last, last.device == device,
                       last.deviceOffset <= Int64.max - last.length,
                       last.deviceOffset + last.length == deviceOffset {
                        runs[runs.count - 1] = StoragePhysicalRun(
                            device: device,
                            deviceOffset: last.deviceOffset,
                            length: last.length + contig
                        )
                    } else {
                        runs.append(StoragePhysicalRun(
                            device: device, deviceOffset: deviceOffset, length: contig
                        ))
                    }
                }
                off = end
            }

            if useSeek, off <= regionStart {
                // Defensive: the region walk must advance.
                return .failed(.zeroProgress)
            }
        }

        var post = stat()
        guard fstat(fd, &post) == 0 else { return .failed(.openFailed) }
        guard pre.st_size == post.st_size,
              pre.st_blocks == post.st_blocks,
              pre.st_ino == post.st_ino,
              pre.st_dev == post.st_dev,
              pre.st_flags == post.st_flags,
              pre.st_mtimespec.tv_sec == post.st_mtimespec.tv_sec,
              pre.st_mtimespec.tv_nsec == post.st_mtimespec.tv_nsec else {
            return .failed(.changedWhileWalking)
        }

        // Independent reconciliation: the data-fork runs must equal the
        // file's allocated block bytes. This catches compressed mappings,
        // extra forks, unaligned-tail truncation and any unexpected
        // filesystem semantics instead of returning a plausible wrong number.
        let measuredBytes = runs.reduce(Int64(0)) { $0 + $1.length }
        let allocatedBytes = Int64(pre.st_blocks) * 512
        guard measuredBytes == allocatedBytes else {
            return .failed(.allocationMismatch)
        }

        return .measured(StorageExtentMeasurement(runs: runs, callCount: calls))
        #else
        _ = (path, expectedDevice, expectedInode, configuration, isCancelled)
        return .unsupported
        #endif
    }
}
