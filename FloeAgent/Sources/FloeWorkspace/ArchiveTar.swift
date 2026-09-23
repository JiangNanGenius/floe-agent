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
    /// True when the archive ended with the canonical two zero blocks.
    private(set) var sawEndMarker = false

    init(source: ArchiveByteSource) throws {
        self.source = source
    }

    func next() throws -> Header? {
        if finished { return nil }
        while true {
            try finishPayload()
            let block = try readBlock(lenient: true)
            guard let block else {
                // End of input without the zero-block marker.
                finished = true
                return nil
            }
            if block.allSatisfy({ $0 == 0 }) {
                // The canonical end is two zero blocks; one is enough to stop.
                finished = true
                sawEndMarker = true
                return nil
            }
            var header = try parse(block: block)

            switch header.kind {
            case .paxHeader:
                startPayload(size: header.size)
                let payload = try readPayloadData()
                try finishPayload()
                let records = Self.parsePax(payload)
                if header.rawTypeflag == UInt8(ascii: "g") {
                    sawGlobalPaxHeader = true
                } else {
                    pendingName = records["path"]
                    pendingLink = records["linkpath"]
                    if let size = records["size"] { pendingSize = Int64(size) }
                    if let mtime = records["mtime"], let seconds = Double(mtime) { pendingMtime = Int(seconds) }
                }
                continue
            case .gnuLongName, .gnuLongLink:
                startPayload(size: header.size)
                let payload = try readPayloadData()
                try finishPayload()
                let value = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
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
            let chunk = try readPayload(max: 256 * 1_024)
            if chunk.isEmpty { throw TarStreamError.truncated("tar entry payload is truncated") }
        }
        if payloadPadding > 0 {
            guard let skipped = try source.read(max: payloadPadding), skipped.count == payloadPadding else {
                throw TarStreamError.truncated("tar padding is truncated")
            }
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
            let chunk = try readPayload(max: 256 * 1_024)
            if chunk.isEmpty { throw TarStreamError.truncated("extended tar header is truncated") }
            data.append(chunk)
        }
        return data
    }

    private func readBlock(lenient: Bool) throws -> Data? {
        guard let block = try source.read(max: 512) else { return nil }
        if block.count < 512 {
            if lenient { return nil }
            throw TarStreamError.truncated("tar header is truncated")
        }
        return block
    }

    private func parse(block: Data) throws -> Header {
        func field(_ offset: Int, _ length: Int) -> String {
            let start = block.startIndex + offset
            let slice = block[start..<(start + length)]
            let trimmed = slice.prefix { $0 != 0 }
            return String(decoding: trimmed, as: UTF8.self)
        }
        func octal(_ offset: Int, _ length: Int) -> Int64? {
            let text = field(offset, length).trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
            if text.isEmpty { return 0 }
            return Int64(text, radix: 8)
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
        let size = octal(124, 12) ?? 0
        let mode = Int(octal(100, 8) ?? 0o644)
        let mtime = Int(octal(136, 12) ?? 0)
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
            mode: mode,
            size: max(0, size),
            mtime: mtime,
            linkTarget: link.isEmpty ? nil : link,
            rawTypeflag: typeflag
        )
    }

    static func parsePax(_ payload: Data) -> [String: String] {
        var result: [String: String] = [:]
        var cursor = payload.startIndex
        while cursor < payload.endIndex {
            guard let space = payload[cursor...].firstIndex(of: 0x20),
                  let length = Int(String(decoding: payload[cursor..<space], as: UTF8.self)),
                  length > 0,
                  cursor + length <= payload.endIndex else { break }
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
