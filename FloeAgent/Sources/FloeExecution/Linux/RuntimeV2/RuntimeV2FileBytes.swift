// FloeExecution — Runtime v2 measured byte accounting.
//
// Template and environment reuse decisions are only honest when the numbers
// are real. Three distinct measures are reported and never conflated:
//
//   logicalBytes    the file's byte size (what the guest sees)
//   allocatedBytes  physical blocks the filesystem reports (st_blocks × 512),
//                   nil when the filesystem cannot report them
//   measuredSavingsBytes  logical − allocated, and ONLY when allocated is
//                   known and strictly lower (a genuinely sparse file).
//                   A clone that still owns its full extent reports nil, not
//                   an invented "saving".
//
// Download bytes are never measured here: they come from the installer that
// actually performed the downloads.

import Foundation

public struct RuntimeV2FileBytes: Sendable, Equatable {
    public var logicalBytes: Int64
    public var allocatedBytes: Int64?
    public var measuredSavingsBytes: Int64?

    public init(logicalBytes: Int64, allocatedBytes: Int64?, measuredSavingsBytes: Int64?) {
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.measuredSavingsBytes = measuredSavingsBytes
    }

    /// Measures one regular file. Missing files measure as all-zero rather
    /// than throwing: callers decide whether absence is an error.
    public static func measure(fileAt url: URL, fileManager: FileManager = .default) -> RuntimeV2FileBytes {
        let logical = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)
            .flatMap { $0?.int64Value } ?? 0
        var info = stat()
        var allocated: Int64?
        if lstat(url.path, &info) == 0 {
            let blocks = Int64(info.st_blocks)
            if blocks > 0 {
                allocated = blocks * 512
            } else if logical == 0 {
                allocated = 0
            }
            // st_blocks == 0 with a non-empty logical size means the volume
            // does not report allocation (or the file is wholly sparse):
            // allocated stays nil so no saving is ever guessed.
        }
        let savings: Int64? = {
            guard let allocated, allocated >= 0, allocated < logical else { return nil }
            return logical - allocated
        }()
        return RuntimeV2FileBytes(
            logicalBytes: logical,
            allocatedBytes: allocated,
            measuredSavingsBytes: savings
        )
    }

    /// Sum for a set of files (e.g. a template's data directory).
    public static func sum(_ values: [RuntimeV2FileBytes]) -> RuntimeV2FileBytes {
        let logical = values.reduce(Int64(0)) { $0 + $1.logicalBytes }
        let allocatedValues = values.map(\.allocatedBytes)
        let allocated = allocatedValues.allSatisfy { $0 != nil }
            ? allocatedValues.compactMap { $0 }.reduce(Int64(0), +)
            : nil
        let savings: Int64? = {
            guard let allocated, allocated < logical else { return nil }
            return logical - allocated
        }()
        return RuntimeV2FileBytes(logicalBytes: logical, allocatedBytes: allocated, measuredSavingsBytes: savings)
    }
}
