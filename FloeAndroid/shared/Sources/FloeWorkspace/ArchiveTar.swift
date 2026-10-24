// FloeWorkspace — streaming tar container reader/writer.
//
// The archive engine writes tar bytes incrementally (so tar.gz/tar.xz stream
// with bounded memory) and reads them incrementally (so extraction never
// materializes the whole archive). Only regular files, directories, symlinks
// and hard links are represented; every other entry type is surfaced to the
// caller as `.unknown` so it can be reported instead of silently dropped.

import Foundation
import FloeCore

enum TarStreamError: Error, Equatable {
    case malformed(String)
    case nameTooLong(String)
    case truncated(String)
    case checksumMismatch
}

// MARK: - Writer

/// Writes POSIX ustar blocks, falling back to GNU long-name/long-link
/// records (`L`/`K`) when a name cannot be split into the 100+155 fields.
/// Linux GNU tar, bsdtar and Python's tarfile all read this.
struct TarStreamWriter {
    let sink: ArchiveByteSink
    private var wroteEnd = false

    init(sink: ArchiveByteSink) {
        self.sink = sink
    }

    mutating func addDirectory(name: String, mode: Int, mtime: Date) throws {
        try sink.write(try header(name: name.hasSuffix("/") ? name : name + "/", mode: mode, size: 0, mtime: mtime, typeflag: "5", linkName: nil))
    }

    mutating func addSymlink(name: String, target: String, mode: Int, mtime: Date) throws {
        try writeLongNameIfNeeded(name: name)
        try sink.write(try header(name: name, mode: mode, size: 0, mtime: mtime, typeflag: "2", linkName: target))
    }

    mutating func addHardlink(name: String, target: String, mode: Int, mtime: Date) throws {
        try writeLongNameIfNeeded(name: name)
        try sink.write(try header(name: name, mode: mode, size: 0, mtime: mtime, typeflag: "1", linkName: target))
    }

    /// Streams a file body: `onChunk` is called for every written chunk so the
    /// caller can report progress and poll cancellation.
    mutating func addFile(
        name: String,
        size: Int64,
        mode: Int,
        mtime: Date,
        onChunk: (Data) throws -> Void,
        from makeSource: () throws -> ArchiveByteSource
    ) throws {
        try writeLongNameIfNeeded(name: name)
        try sink.write(try header(name: name, mode: mode, size: size, mtime: mtime, typeflag: "0", linkName: nil))
        let source = try makeSource()
        var remaining = size
        while remaining > 0 {
            let want = Int(min(remaining, 256 * 1_024))
            guard let chunk = try source.read(max: want), !chunk.isEmpty else {
                throw TarStreamError.truncated("input shrank while archiving: \(name)")
            }
            try sink.write(chunk)
            try onChunk(chunk)
            remaining -= Int64(chunk.count)
        }
        let padding = (512 - Int(size % 512)) % 512
        if padding > 0 {
            try sink.write(Data(count: padding))
        }
    }

    mutating func finish() throws {
        guard !wroteEnd else { return }
        try sink.write(Data(count: 1_024))
        wroteEnd = true
    }

    private func writeLongNameIfNeeded(name: String) throws {
        guard Self.split(name: name) == nil else { return }
        guard name.utf8.count <= 4_096 else {
            throw TarStreamError.nameTooLong(name)
        }
        var payload = Data(name.utf8)
        payload.append(0)
        try sink.write(try header(name: "././@LongLink", mode: 0o644, size: Int64(payload.count), mtime: Date(), typeflag: "L", linkName: nil))
        try sink.write(payload)
        let padding = (512 - payload.count % 512) % 512
        if padding > 0 { try sink.write(Data(count: padding)) }
    }

    /// ustar allows a 100-byte name plus a 155-byte prefix. Returns the split
    /// when the name fits; nil means a GNU long-name record is required.
    static func split(name: String) -> (name: String, prefix: String)? {
        if name.utf8.count <= 100 { return (name, "") }
        var best: (name: String, prefix: String)?
        var cursor = name.startIndex
        while let slash = name[cursor...].firstIndex(of: "/") {
            let prefix = String(name[..<slash])
            let rest = String(name[name.index(after: slash)...])
            if prefix.utf8.count <= 155 && rest.utf8.count <= 100 && !rest.isEmpty {
                best = (rest, prefix)
            }
            cursor = name.index(after: slash)
        }
        return best
    }

    private func header(
        name: String,
        mode: Int,
        size: Int64,
        mtime: Date,
        typeflag: Character,
        linkName: String?
    ) throws -> Data {
        var block = [UInt8](repeating: 0, count: 512)
        func writeString(_ value: String, at offset: Int, maxLength: Int) {
            let bytes = Array(value.utf8.prefix(maxLength))
            if !bytes.isEmpty {
                block.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
            }
        }
        func writeOctal(_ value: Int64, at offset: Int, length: Int) {
            let text = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(0, length - 1 - text.count)) + text
            writeString(padded, at: offset, maxLength: length - 1)
            block[offset + length - 1] = 0
        }

        let parts = Self.split(name: name) ?? (name, "")
        guard parts.name.utf8.count <= 100 else { throw TarStreamError.nameTooLong(name) }
        writeString(parts.name, at: 0, maxLength: 100)
        writeOctal(Int64(mode & 0o7777), at: 100, length: 8)
        writeOctal(0, at: 108, length: 8) // uid: iOS has no meaningful Linux uid
        writeOctal(0, at: 116, length: 8) // gid
        writeOctal(size, at: 124, length: 12)
        writeOctal(Int64(mtime.timeIntervalSince1970), at: 136, length: 12)
        block[156] = typeflag.asciiValue ?? 0x30
        if let linkName {
            let target = linkName.utf8.count <= 100 ? linkName : String(linkName.prefix(100))
            writeString(target, at: 157, maxLength: 100)
        }
        writeString("ustar", at: 257, maxLength: 6)
        writeString("00", at: 263, maxLength: 2)
        writeString("floe", at: 265, maxLength: 32)
        writeString("floe", at: 297, maxLength: 32)
        writeString(parts.prefix, at: 345, maxLength: 155)
        // Checksum: field treated as eight spaces while summing.
        for index in 148..<156 { block[index] = 0x20 }
        let checksum = block.reduce(0) { $0 + Int($1) }
        let checksumText = String(checksum, radix: 8)
        let padded = String(repeating: "0", count: max(0, 6 - checksumText.count)) + checksumText
        writeString(padded, at: 148, maxLength: 6)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }
}

// MARK: - Reader

/// Incremental tar parser. `next()` positions the reader at an entry's
/// payload; callers then stream it with `readPayload`/`skipPayload` and must
/// terminate each entry with `finishPayload`.
///
/// The reader is deliberately strict: a header block that is not exactly 512
/// bytes, a missing end-of-archive marker, a malformed/overflowing numeric
/// field or a truncated payload is an error, never a silently successful
/// (partial) extraction. Zero padding after the end-of-archive marker stays
/// compatible; non-zero trailing bytes are refused.
final class TarStreamReader {
    enum Kind {
        case file
        case directory
        case symlink
        case hardlink
        /// Extended headers folded into the following entry.
        case paxHeader
        case gnuLongName
        case gnuLongLink
        /// Any other typeflag (devices, fifos, sparse maps, …).
        case unknown
    }

    struct Header {
        var name: String
        var kind: Kind
        var mode: Int
        var size: Int64
        var mtime: Int
        var linkTarget: String?
        var rawTypeflag: UInt8
    }

    private let source: ArchiveByteSource
    private let checkCancellation: (() throws -> Void)?
    private var remainingPayload: Int64 = 0
    private var payloadPadding = 0
    private var payloadActive = false
    private var pendingName: String?
    private var pendingLink: String?
    private var pendingSize: Int64?
    private var pendingMtime: Int?
    /// True when a global pax header was present; the engine reports that its
    /// record set could not be applied (never a silent drop).
    private(set) var sawGlobalPaxHeader = false
    private var finished = false

    init(source: ArchiveByteSource, checkCancellation: (() throws -> Void)? = nil) throws {
        self.source = source
        self.checkCancellation = checkCancellation
    }

    func next() throws -> Header? {
        if finished { return nil }
        while true {
            try finishPayload()
            guard let block = try readBlock() else {
                // End of input where the end-of-archive marker should be: a
                // truncated archive must not be reported as a clean end.
                throw TarStreamError.truncated("tar end-of-archive marker is missing")
            }
            if block.allSatisfy({ $0 == 0 }) {
                // One or more zero blocks terminate the archive (the canonical
                // form is two). The remainder must be zero padding; any other
                // trailing data is refused instead of being ignored.
                finished = true
                try drainTrailingPadding()
                return nil
            }
            var header = try parse(block: block)

            switch header.kind {
            case .paxHeader:
                startPayload(size: header.size)
                let payload = try readPayloadData()
                try finishPayload()
                let records = try Self.parsePax(payload)
                if header.rawTypeflag == UInt8(ascii: "g") {
                    sawGlobalPaxHeader = true
                } else {
                    if let path = records["path"] {
                        guard path.utf8.count <= 4_096 else {
                            throw TarStreamError.nameTooLong("pax path over 4096 bytes")
                        }
                        pendingName = path
                    }
                    if let linkpath = records["linkpath"] {
                        guard linkpath.utf8.count <= 4_096 else {
                            throw TarStreamError.nameTooLong("pax linkpath over 4096 bytes")
                        }
                        pendingLink = linkpath
                    }
                    if let rawSize = records["size"] {
                        guard let value = Int64(rawSize), value >= 0 else {
                            throw TarStreamError.malformed("pax size record is not a valid non-negative number")
                        }
                        pendingSize = value
                    }
                    if let rawMtime = records["mtime"] {
                        guard let seconds = Double(rawMtime), seconds.isFinite,
                              seconds >= -62_135_596_800, seconds <= 253_402_300_799 else {
                            throw TarStreamError.malformed("pax mtime record is not a valid timestamp")
                        }
                        pendingMtime = Int(seconds.rounded())
                    }
                }
                continue
            case .gnuLongName, .gnuLongLink:
                startPayload(size: header.size)
                let payload = try readPayloadData()
                try finishPayload()
                let value = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
                guard value.utf8.count <= 4_096 else {
                    throw TarStreamError.nameTooLong("GNU long name over 4096 bytes")
                }
                if header.kind == .gnuLongName { pendingName = value } else { pendingLink = value }
                continue
            default:
                if let name = pendingName { header.name = name }
                if let link = pendingLink { header.linkTarget = link }
                if let size = pendingSize, header.kind == .file { header.size = size }
                if let mtime = pendingMtime { header.mtime = mtime }
                pendingName = nil
                pendingLink = nil
                pendingSize = nil
                pendingMtime = nil
                startPayload(size: header.size)
                return header
            }
        }
    }

    func readPayload(max: Int) throws -> Data {
        guard payloadActive, remainingPayload > 0 else { return Data() }
        try checkCancellation?()
        let want = Int(min(remainingPayload, Int64(max)))
        guard let chunk = try source.read(max: want), !chunk.isEmpty else {
            throw TarStreamError.truncated("tar entry payload is truncated")
        }
        remainingPayload -= Int64(chunk.count)
        return chunk
    }

    /// Drains any unread payload plus its 512-byte padding.
    func skipPayload() throws {
        try finishPayload()
    }

    func finishPayload() throws {
        guard payloadActive else { return }
        while remainingPayload > 0 {
            try checkCancellation?()
            let chunk = try readPayload(max: 256 * 1_024)
            if chunk.isEmpty { throw TarStreamError.truncated("tar entry payload is truncated") }
        }
        var remainingPadding = payloadPadding
        while remainingPadding > 0 {
            try checkCancellation?()
            guard let skipped = try source.read(max: remainingPadding), !skipped.isEmpty else {
                throw TarStreamError.truncated("tar padding is truncated")
            }
            remainingPadding -= skipped.count
        }
        payloadActive = false
        payloadPadding = 0
    }

    // MARK: - internals

    private func startPayload(size: Int64) {
        remainingPayload = max(0, size)
        payloadPadding = Int((512 - (size % 512)) % 512)
        payloadActive = true
    }

    private func readPayloadData() throws -> Data {
        guard remainingPayload <= 16 * 1_024 * 1_024 else {
            throw TarStreamError.malformed("extended tar header is too large")
        }
        var data = Data()
        while remainingPayload > 0 {
            try checkCancellation?()
            let chunk = try readPayload(max: 256 * 1_024)
            if chunk.isEmpty { throw TarStreamError.truncated("extended tar header is truncated") }
            data.append(chunk)
        }
        return data
    }

    /// Reads whatever follows the end-of-archive marker and requires it to be
    /// zero padding (blocking-factor padding written by `tar`). Non-zero bytes
    /// — including a partial header — are trailing garbage: the archive is
    /// refused rather than reported as a partial extraction.
    private func drainTrailingPadding() throws {
        while true {
            try checkCancellation?()
            guard let chunk = try source.read(max: 64 * 1024), !chunk.isEmpty else { return }
            guard chunk.allSatisfy({ $0 == 0 }) else {
                throw TarStreamError.malformed("tar has trailing garbage after its end-of-archive marker")
            }
        }
    }

    /// Reads exactly one 512-byte header block. `nil` means the source ended
    /// at a block boundary (the caller treats that as a missing end marker);
    /// a short block is corruption.
    private func readBlock() throws -> Data? {
        guard var block = try source.read(max: 512) else { return nil }
        while block.count < 512 {
            guard let next = try source.read(max: 512 - block.count), !next.isEmpty else {
                throw TarStreamError.truncated("tar header is truncated")
            }
            block.append(next)
        }
        return block
    }

    private func parse(block: Data) throws -> Header {
        func bytes(_ offset: Int, _ length: Int) -> [UInt8] {
            let start = block.startIndex + offset
            return Array(block[start..<(start + length)])
        }
        func field(_ offset: Int, _ length: Int) -> String {
            let slice = bytes(offset, length)
            let trimmed = slice.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        }
        /// Strict numeric field: POSIX octal or GNU base-256. A present but
        /// invalid / overflowing / negative value is corruption. `fallback`
        /// applies only to an empty field (nil = the field is required).
        /// Base-256 is accepted only in its canonical positive form (`0x80`
        /// prefix); unknown prefixes (e.g. negative two's complement) are
        /// rejected rather than misread.
        func numeric(_ offset: Int, _ length: Int, _ name: String, fallback: Int64?) throws -> Int64 {
            let raw = bytes(offset, length)
            if let first = raw.first, first & 0x80 != 0 {
                guard first == 0x80 else {
                    throw TarStreamError.malformed("tar \(name) field uses an unsupported base-256 encoding")
                }
                var value: Int64 = 0
                for byte in raw.dropFirst() {
                    guard value <= (Int64.max >> 8) else {
                        throw TarStreamError.malformed("tar \(name) field overflows")
                    }
                    value = (value << 8) | Int64(byte)
                }
                return value
            }
            var digits: [UInt8] = []
            for byte in raw {
                if byte == 0 || byte == 0x20 {
                    if digits.isEmpty { continue }
                    break
                }
                guard byte >= 0x30, byte <= 0x37 else {
                    throw TarStreamError.malformed("tar \(name) field is not a valid octal number")
                }
                digits.append(byte)
            }
            if digits.isEmpty {
                guard let fallback else {
                    throw TarStreamError.malformed("tar \(name) field is empty")
                }
                return fallback
            }
            guard let value = Int64(String(decoding: digits, as: UTF8.self), radix: 8) else {
                throw TarStreamError.malformed("tar \(name) field overflows")
            }
            return value
        }
        // Checksum first: a mismatch means we are not looking at a tar header
        // (or the archive is damaged).
        var checksumBlock = [UInt8](block)
        for index in 148..<156 { checksumBlock[index] = 0x20 }
        let expected = checksumBlock.reduce(0) { $0 + Int($1) }
        let recordedText = field(148, 8).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard let recorded = Int(recordedText, radix: 8), recorded == expected else {
            throw TarStreamError.checksumMismatch
        }
        let name = field(0, 100)
        let prefix = field(345, 155)
        let fullName = prefix.isEmpty ? name : prefix + "/" + name
        let typeflag = block[block.startIndex + 156]
        let size = try numeric(124, 12, "size", fallback: nil)
        let mode = try numeric(100, 8, "mode", fallback: 0o644)
        let mtime = try numeric(136, 12, "mtime", fallback: 0)
        let link = field(157, 100)
        let kind: Kind
        switch typeflag {
        case UInt8(ascii: "0"), 0:
            kind = .file
        case UInt8(ascii: "5"):
            kind = .directory
        case UInt8(ascii: "2"):
            kind = .symlink
        case UInt8(ascii: "1"):
            kind = .hardlink
        case UInt8(ascii: "x"), UInt8(ascii: "g"):
            kind = .paxHeader
        case UInt8(ascii: "L"):
            kind = .gnuLongName
        case UInt8(ascii: "K"):
            kind = .gnuLongLink
        default:
            kind = .unknown
        }
        return Header(
            name: fullName,
            kind: kind,
            mode: Int(truncatingIfNeeded: mode),
            size: size,
            mtime: Int(truncatingIfNeeded: mtime),
            linkTarget: link.isEmpty ? nil : link,
            rawTypeflag: typeflag
        )
    }

    /// Parses pax records. A record that does not parse is corruption: the
    /// caller must not silently fall back to the ustar name/size.
    static func parsePax(_ payload: Data) throws -> [String: String] {
        var result: [String: String] = [:]
        var cursor = payload.startIndex
        while cursor < payload.endIndex {
            guard let space = payload[cursor...].firstIndex(of: 0x20),
                  let length = Int(String(decoding: payload[cursor..<space], as: UTF8.self)),
                  length > 0,
                  cursor + length <= payload.endIndex,
                  length > payload.distance(from: cursor, to: space) + 1 else {
                throw TarStreamError.malformed("pax record is malformed")
            }
            let record = payload[(space + 1)..<(cursor + length - 1)]
            if let equals = record.firstIndex(of: 0x3D) {
                let key = String(decoding: record[..<equals], as: UTF8.self)
                let value = String(decoding: record[(equals + 1)...], as: UTF8.self)
                result[key] = value
            }
            cursor += length
        }
        return result
    }
}
