// SPDX-License-Identifier: MPL-2.0
import Foundation
import Compression

/// One embedded plate G-code stream inside a sliced 3MF container.
public struct PrintThreeMFPlate: Sendable, Identifiable {
    /// 1-based plate number taken from the entry name (`plate_<n>.gcode`).
    public let id: Int
    /// Exact archive entry name, preserved for provenance and diagnostics.
    public let name: String
    /// Raw G-code bytes of this plate.
    public let data: Data
}

/// Read-only access to the plate G-code streams a slicer embedded in a 3MF
/// ZIP container (Bambu Studio / PrusaSlicer convention
/// `Metadata/plate_<n>.gcode`). This is a preview reader, not a general ZIP
/// extractor: entry names are validated before any byte is touched, only
/// matched plate entries are inflated, every length comes from the central
/// directory with full bounds checks, decompressed bytes are CRC32-verified,
/// duplicate plate IDs are rejected, and listing/inflation poll
/// cancellation. The FloeWorkspace archive codecs stay stream-oriented for
/// gzip/bzip2/xz/tar; a 3MF needs container indexing, so this reader keeps
/// FloePrintCore dependency-free.
public enum PrintThreeMF {
    public static let maximumArchiveBytes = 64 * 1024 * 1024
    public static let maximumPlateBytes = 48 * 1024 * 1024
    public static let maximumEntries = 4_096
    /// A whole-archive `plates(in:)` call stays bounded for large user files.
    public static let maximumPlates = 64
    public static let maximumTotalPlateBytes = 96 * 1024 * 1024

    private static let entryPrefix = "metadata/"
    private static let plateStem = "plate_"
    private static let entrySuffix = ".gcode"

    public struct PlateEntry: Sendable, Equatable {
        public let plateID: Int
        public let name: String
    }

    /// Lists embedded plate entries without inflating them (the central
    /// directory is a few kilobytes even for large archives). Returns an
    /// empty array for a ZIP that contains no plate G-code (a model-only 3MF
    /// is not an error; callers keep the geometry viewer route). Duplicate
    /// plate IDs are rejected: silently dropping one would print the wrong
    /// plate.
    public static func plateEntries(in archive: Data,
                                    maximumBytes: Int = maximumArchiveBytes) throws -> [PlateEntry] {
        guard archive.count >= 22, archive.count <= maximumBytes else { throw PrintError.sizeLimit }
        let directory = try centralDirectory(in: archive)
        var seen = Set<Int>()
        var entries: [PlateEntry] = []
        entries.reserveCapacity(min(directory.records.count, 64))
        for record in directory.records {
            try Task.checkCancellation()
            guard let plateID = plateNumber(record.name) else { continue }
            guard seen.insert(plateID).inserted else { throw PrintError.invalidArtifact }
            entries.append(PlateEntry(plateID: plateID, name: record.name))
        }
        return entries.sorted { $0.plateID < $1.plateID }
    }

    /// Inflates exactly one plate, selected by ID. This is the route the UI
    /// uses so opening a sliced 3MF never materializes plates the user did
    /// not ask for.
    public static func plate(_ id: Int, in archive: Data,
                             maximumBytes: Int = maximumArchiveBytes) throws -> PrintThreeMFPlate {
        guard id > 0 else { throw PrintError.unsupportedFormat }
        let entries = try plateEntries(in: archive, maximumBytes: maximumBytes)
        guard let entry = entries.first(where: { $0.plateID == id }) else { throw PrintError.unsupportedFormat }
        let directory = try centralDirectory(in: archive)
        guard let record = directory.records.first(where: { $0.name == entry.name }) else {
            throw PrintError.invalidArtifact
        }
        return PrintThreeMFPlate(id: entry.plateID, name: entry.name,
                                 data: try extract(record, from: archive))
    }

    /// Extracts and returns every embedded plate G-code, sorted by plate
    /// number, bounded by `maximumPlates` and `maximumTotalPlateBytes`.
    /// Throws `PrintError.unsupportedFormat` when the container holds no
    /// plate G-code so callers fail closed instead of showing an empty
    /// toolpath surface for an unsliced model.
    public static func plates(in archive: Data,
                              maximumBytes: Int = maximumArchiveBytes) throws -> [PrintThreeMFPlate] {
        let entries = try plateEntries(in: archive, maximumBytes: maximumBytes)
        guard !entries.isEmpty else { throw PrintError.unsupportedFormat }
        guard entries.count <= maximumPlates else { throw PrintError.sizeLimit }
        let directory = try centralDirectory(in: archive)
        var plates: [PrintThreeMFPlate] = []
        plates.reserveCapacity(entries.count)
        var totalBytes = 0
        for entry in entries {
            try Task.checkCancellation()
            guard let record = directory.records.first(where: { $0.name == entry.name }) else {
                throw PrintError.invalidArtifact
            }
            let data = try extract(record, from: archive)
            totalBytes += data.count
            guard totalBytes <= maximumTotalPlateBytes else { throw PrintError.sizeLimit }
            plates.append(PrintThreeMFPlate(id: entry.plateID, name: entry.name, data: data))
        }
        return plates
    }

    // MARK: - ZIP central directory

    private struct CentralRecord {
        let name: String
        let compression: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    private struct CentralDirectory {
        let records: [CentralRecord]
    }

    private static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    private static func centralDirectory(in archive: Data) throws -> CentralDirectory {
        let bytes = [UInt8](archive)
        // EOCD (22 bytes + up to 64 KiB comment) is at the tail of the file.
        let eocdSize = 22
        let scanWindow = min(bytes.count, eocdSize + 65_536)
        guard scanWindow >= eocdSize else { throw PrintError.invalidArtifact }
        var eocd = bytes.count - scanWindow
        let limit = bytes.count - eocdSize
        while true {
            guard eocd <= limit else { throw PrintError.invalidArtifact }
            if bytes[eocd] == 0x50, bytes[eocd + 1] == 0x4b, bytes[eocd + 2] == 0x05, bytes[eocd + 3] == 0x06 { break }
            eocd += 1
        }
        guard u16(bytes, eocd + 4) == 0, u16(bytes, eocd + 6) == 0 else { throw PrintError.unsupportedFormat }
        let totalEntries = Int(u16(bytes, eocd + 10))
        let directorySize = Int(u32(bytes, eocd + 12))
        let directoryOffset = Int(u32(bytes, eocd + 16))
        guard totalEntries > 0, totalEntries <= maximumEntries,
              directorySize > 0, directoryOffset >= 0,
              directoryOffset <= bytes.count - directorySize else { throw PrintError.invalidArtifact }
        var records: [CentralRecord] = []
        records.reserveCapacity(totalEntries)
        var cursor = directoryOffset
        let end = directoryOffset + directorySize
        for _ in 0..<totalEntries {
            try Task.checkCancellation()
            guard cursor + 46 <= end,
                  bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4b,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else { throw PrintError.invalidArtifact }
            let flags = u16(bytes, cursor + 8)
            let compression = u16(bytes, cursor + 10)
            let crc32 = u32(bytes, cursor + 16)
            let compressedSize = Int(u32(bytes, cursor + 20))
            let uncompressedSize = Int(u32(bytes, cursor + 24))
            let nameLength = Int(u16(bytes, cursor + 28))
            let extraLength = Int(u16(bytes, cursor + 30))
            let commentLength = Int(u16(bytes, cursor + 32))
            let localHeaderOffset = Int(u32(bytes, cursor + 42))
            guard nameLength > 0, cursor + 46 + nameLength <= end else { throw PrintError.invalidArtifact }
            let name = String(decoding: Data(bytes[(cursor + 46)..<(cursor + 46 + nameLength)]), as: UTF8.self)
            guard safeEntryName(name) else { throw PrintError.invalidArtifact }
            // Multi-volume and encrypted entries are not a preview input;
            // 0xFFFFFFFF sizes mean ZIP64, which the bounded reader refuses.
            guard flags & 0x01 == 0, compression == 0 || compression == 8,
                  compressedSize >= 0, uncompressedSize >= 0,
                  compressedSize <= bytes.count, uncompressedSize <= maximumPlateBytes else { throw PrintError.invalidArtifact }
            records.append(CentralRecord(name: name, compression: compression, crc32: crc32,
                compressedSize: compressedSize, uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset))
            cursor += 46 + nameLength + extraLength + commentLength
        }
        guard cursor == end else { throw PrintError.invalidArtifact }
        return CentralDirectory(records: records)
    }

    /// Entry names must stay relative, single-purpose paths. Anything with
    /// traversal, absolute roots, Windows separators, NULs or drive letters is
    /// a hostile archive, not a sliced plate container.
    static func safeEntryName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count < 1024, !name.hasPrefix("/"), !name.hasPrefix("~"),
              !name.contains("\\"), !name.contains(":"), !name.contains("\0"),
              !name.split(separator: "/").contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return true
    }

    static func plateNumber(_ name: String) -> Int? {
        let lowered = name.lowercased()
        guard lowered.hasPrefix(entryPrefix), lowered.hasSuffix(entrySuffix) else { return nil }
        let stem = lowered.dropFirst(entryPrefix.count).dropLast(entrySuffix.count)
        guard stem.hasPrefix(plateStem) else { return nil }
        let digits = stem.dropFirst(plateStem.count)
        guard !digits.isEmpty, digits.count <= 6, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(digits), value > 0 else { return nil }
        return value
    }

    // MARK: - Entry inflation

    private static func extract(_ record: CentralRecord, from archive: Data) throws -> Data {
        let bytes = [UInt8](archive)
        let at = record.localHeaderOffset
        guard at + 30 <= bytes.count,
              bytes[at] == 0x50, bytes[at + 1] == 0x4b, bytes[at + 2] == 0x03, bytes[at + 3] == 0x04 else {
            throw PrintError.invalidArtifact
        }
        let nameLength = Int(u16(bytes, at + 26))
        let extraLength = Int(u16(bytes, at + 28))
        let dataStart = at + 30 + nameLength + extraLength
        guard dataStart <= bytes.count, record.compressedSize <= bytes.count - dataStart else {
            throw PrintError.invalidArtifact
        }
        try Task.checkCancellation()
        let compressed = Data(bytes[dataStart..<(dataStart + record.compressedSize)])
        let output: Data
        switch record.compression {
        case 0:
            guard record.compressedSize == record.uncompressedSize else { throw PrintError.invalidArtifact }
            output = compressed
        case 8:
            guard record.uncompressedSize > 0 else { throw PrintError.invalidArtifact }
            var inflated = Data(count: record.uncompressedSize)
            let written: Int = inflated.withUnsafeMutableBytes { dst in
                compressed.withUnsafeBytes { src in
                    guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return 0 }
                    return compression_decode_buffer(
                        dstBase.assumingMemoryBound(to: UInt8.self), record.uncompressedSize,
                        srcBase.assumingMemoryBound(to: UInt8.self), compressed.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            guard written == record.uncompressedSize else { throw PrintError.invalidArtifact }
            output = inflated
        default:
            throw PrintError.unsupportedFormat
        }
        // The slicer wrote the CRC; a mismatch means corrupt bytes, never a
        // preview of the wrong toolpath.
        guard crc32(output) == record.crc32 else { throw PrintError.invalidArtifact }
        return output
    }

    // MARK: - CRC32 (ISO 3309, polynomial 0xEDB88320)

    static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = Array(repeating: 0, count: 256)
        for value in UInt32(0)..<256 {
            var remainder = value
            for _ in 0..<8 { remainder = remainder & 1 == 1 ? remainder >> 1 ^ 0xEDB88320 : remainder >> 1 }
            table[Int(value)] = remainder
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
