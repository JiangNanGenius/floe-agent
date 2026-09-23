// FloeWorkspace — native compressed-stream codecs.
//
// The workspace archive tool used to route tar.gz/tar.bz2/tar.xz and single
// file gzip/bzip2/xz through the task environment's guest Python. That made a
// device-local operation depend on a Linux runtime (and on a pool slot).
// These codecs implement the same formats on the host:
//
//   * gzip  — gzip member framing around raw DEFLATE (system Compression
//             framework), CRC32/ISIZE verified on read.
//   * bzip2 — SWCompression (already a FloeWorkspace dependency). Its API is
//             one-shot; the engine bounds the buffered size and says so.
//   * xz    — the system Compression framework's LZMA codec emits/consumes a
//             complete `.xz` stream (liblzma-compatible), so tar.xz and .xz
//             stay native without a new dependency.
//
// Everything is pull/push streaming: callers feed input in bounded chunks and
// receive output chunks, so peak memory does not grow with file size. All
// codecs are synchronous; cancellation and progress live in the engine.

import Foundation
import Compression
import SWCompression
import FloeCore

/// Failures shared by the codecs. The engine maps these onto its public error
/// surface; they are never swallowed.
enum ArchiveCodecError: Error, Equatable {
    /// The platform codec could not be created for an algorithm we claim.
    case codecUnavailable(String)
    /// Compressed data is truncated, fails a checksum, or is not the format
    /// the extension claims.
    case corrupt(String)
    /// A bounded resource (bytes, entries, buffer) was exceeded.
    case limitExceeded(String)
    /// Format honestly not implemented on the host.
    case unsupported(String)
}

// MARK: - CRC32

/// Reflected CRC-32 (IEEE 802.3, polynomial 0xEDB88320), the checksum gzip
/// stores in its member trailer. Implemented here instead of reaching for a
/// dependency: the table is 1 KiB and the loop is trivially auditable.
enum ArchiveCRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data, seed: UInt32 = 0) -> UInt32 {
        var crc = ~seed
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return ~crc
    }
}

// MARK: - Streaming codec

/// A bounded, synchronous wrapper around `compression_stream`.
///
/// `process` may be called repeatedly with input chunks; output is delivered
/// to `sink` as it is produced. `pendingInputBytes` exposes how much of the
/// last fed chunk the codec did not consume, which is what lets the gzip
/// reader find the trailer that follows a DEFLATE stream.
final class CompressionStreamCodec {
    private var stream: compression_stream
    private let isEncoder: Bool
    private var outBuffer: [UInt8]
    private(set) var finished = false

    /// Bytes of the most recently fed chunk that the codec did not consume.
    private(set) var pendingInputBytes = 0

    init?(algorithm: compression_algorithm, operation: compression_stream_operation, bufferSize: Int = 64 * 1024) {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, operation, algorithm) == COMPRESSION_STATUS_OK else {
            return nil
        }
        self.stream = stream
        self.isEncoder = operation == COMPRESSION_STREAM_ENCODE
        self.outBuffer = [UInt8](repeating: 0, count: bufferSize)
    }

    deinit {
        compression_stream_destroy(&stream)
    }

    /// Feeds `input` (empty is allowed) and calls `sink` for every produced
    /// chunk. Pass `finalize: true` on the last call. Returns true when the
    /// stream reached its end marker.
    @discardableResult
    func process(_ input: Data, finalize: Bool, sink: (Data) throws -> Void) throws -> Bool {
        if finished {
            if !input.isEmpty {
                // Trailing bytes after a complete gzip/xz member: the caller
                // decides whether that is a second member or garbage.
                pendingInputBytes = input.count
            }
            return true
        }
        var reachedEnd = false
        try input.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            stream.src_ptr = base ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = input.count
            let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            while true {
                var status: compression_status = COMPRESSION_STATUS_OK
                let produced = outBuffer.withUnsafeMutableBufferPointer { buffer -> Int in
                    stream.dst_ptr = buffer.baseAddress!
                    stream.dst_size = buffer.count
                    status = compression_stream_process(&stream, flags)
                    return buffer.count - stream.dst_size
                }
                if status == COMPRESSION_STATUS_ERROR {
                    throw ArchiveCodecError.corrupt("compressed stream is invalid or truncated")
                }
                if produced > 0 {
                    try sink(Data(outBuffer[0..<produced]))
                }
                let pending = stream.src_size
                if status == COMPRESSION_STATUS_END {
                    reachedEnd = true
                    pendingInputBytes = pending
                    break
                }
                // Keep going while the codec consumed input or the output
                // buffer filled up; otherwise no progress is possible.
                if pending > 0 { continue }
                if produced == outBuffer.count { continue }
                break
            }
        }
        if reachedEnd { finished = true }
        return finished
    }
}

// MARK: - Byte sources and sinks

/// Sequential reader the tar/codec layers consume. Implementations are
/// bounded and never read more than requested.
protocol ArchiveByteSource: AnyObject {
    /// Next `max` bytes, or nil at end of input.
    func read(max: Int) throws -> Data?
    var position: Int64 { get }
    /// Total length when the source knows it up front (files and buffers).
    var totalSize: Int64? { get }
}

/// Push sink for produced bytes (a staged file, or an in-memory buffer for
/// the bounded bzip2 path).
protocol ArchiveByteSink: AnyObject {
    func write(_ data: Data) throws
}

final class FileByteSource: ArchiveByteSource {
    private let handle: FileHandle
    private(set) var position: Int64 = 0
    let totalSize: Int64?

    init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        self.totalSize = (attributes?[.size] as? NSNumber)?.int64Value
    }

    deinit {
        try? handle.close()
    }

    func read(max: Int) throws -> Data? {
        let data = try handle.read(upToCount: max) ?? Data()
        if data.isEmpty { return nil }
        position += Int64(data.count)
        return data
    }

    /// Positional read that does not disturb the sequential cursor. Returns a
    /// short read at end of file so callers can bound their own loops.
    func readAt(offset: Int64, count: Int) throws -> Data {
        let end = try handle.seekToEnd()
        guard offset < end, offset >= 0 else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: min(count, Int(end) - Int(offset))) ?? Data()
        // Restore the sequential cursor.
        try handle.seek(toOffset: UInt64(position))
        return data
    }
}

final class DataByteSource: ArchiveByteSource {
    private let data: Data
    private var offset = 0
    private(set) var position: Int64 = 0
    var totalSize: Int64? { Int64(data.count) }

    init(_ data: Data) {
        self.data = data
    }

    func read(max: Int) throws -> Data? {
        guard offset < data.count else { return nil }
        let end = min(offset + max, data.count)
        let slice = data.subdata(in: offset..<end)
        offset = end
        position += Int64(slice.count)
        return slice
    }
}

/// Caps a source at `limit` total bytes. Used to stop a codec exactly at a
/// gzip member's payload boundary so the trailer stays readable.
final class LimitedByteSource: ArchiveByteSource {
    private let inner: ArchiveByteSource
    private let limit: Int64
    private var consumed: Int64 = 0
    private(set) var position: Int64 = 0

    init(source: ArchiveByteSource, limit: Int64) {
        self.inner = source
        self.limit = max(0, limit)
    }

    var totalSize: Int64? { limit }

    func read(max: Int) throws -> Data? {
        let remaining = limit - consumed
        guard remaining > 0 else { return nil }
        let want = Int(min(Int64(max), remaining))
        guard let chunk = try inner.read(max: want), !chunk.isEmpty else { return nil }
        consumed += Int64(chunk.count)
        position += Int64(chunk.count)
        return chunk
    }
}

final class FileByteSink: ArchiveByteSink {
    private let handle: FileHandle

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func close() throws {
        try handle.close()
    }
}

final class DataByteSink: ArchiveByteSink {
    private(set) var data = Data()

    func write(_ data: Data) throws {
        self.data.append(data)
    }
}

// MARK: - GZip

/// Writes a gzip member: fixed 10-byte header, raw DEFLATE payload, CRC32 and
/// ISIZE trailer. Output is deterministic (mtime 0) so repeated runs hash the
/// same, and Linux `gzip`/`gunzip`/`tar -xz` read it unchanged.
final class GzipArchiveWriter {
    private let codec: CompressionStreamCodec
    private let sink: (Data) throws -> Void
    private var crc: UInt32 = 0
    private var size: UInt32 = 0
    private var wroteHeader = false

    init(sink: @escaping (Data) throws -> Void) throws {
        guard let codec = CompressionStreamCodec(algorithm: COMPRESSION_ZLIB, operation: COMPRESSION_STREAM_ENCODE) else {
            throw ArchiveCodecError.codecUnavailable("gzip (DEFLATE)")
        }
        self.codec = codec
        self.sink = sink
    }

    func write(_ data: Data) throws {
        if !wroteHeader {
            try sink(Self.header)
            wroteHeader = true
        }
        guard !data.isEmpty else { return }
        crc = ArchiveCRC32.checksum(data, seed: crc)
        size = size &+ UInt32(truncatingIfNeeded: data.count)
        try codec.process(data, finalize: false, sink: sink)
    }

    func finish() throws {
        if !wroteHeader {
            try sink(Self.header)
            wroteHeader = true
        }
        try codec.process(Data(), finalize: true, sink: sink)
        var trailer = Data()
        withUnsafeBytes(of: crc.littleEndian) { trailer.append(contentsOf: $0) }
        withUnsafeBytes(of: size.littleEndian) { trailer.append(contentsOf: $0) }
        try sink(trailer)
    }

    private static let header = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
}

// MARK: - XZ

/// Writes a complete `.xz` stream through the system LZMA codec. The output
/// is verified against `xz`/liblzma and Python's lzma module in the tests.
final class XZArchiveWriter {
    private let codec: CompressionStreamCodec
    private let sink: (Data) throws -> Void

    init(sink: @escaping (Data) throws -> Void) throws {
        guard let codec = CompressionStreamCodec(algorithm: COMPRESSION_LZMA, operation: COMPRESSION_STREAM_ENCODE) else {
            throw ArchiveCodecError.codecUnavailable("xz (LZMA)")
        }
        self.codec = codec
        self.sink = sink
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try codec.process(data, finalize: false, sink: sink)
    }

    func finish() throws {
        try codec.process(Data(), finalize: true, sink: sink)
    }
}

// MARK: - BZip2

/// bzip2 is the one format the system codecs do not cover. SWCompression's
/// implementation is one-shot, so the engine buffers the payload and enforces
/// an explicit in-memory bound (reported in the operation summary). Both
/// directions interoperate with `bzip2`/`bunzip2`/`tar -xj`.
enum Bzip2Codec {
    static func compress(_ data: Data, limit: Int) throws -> Data {
        guard data.count <= limit else {
            throw ArchiveCodecError.limitExceeded("bzip2 buffers the whole payload (\(data.count) bytes > \(limit))")
        }
        return BZip2.compress(data: data)
    }

    static func decompress(_ data: Data, limit: Int) throws -> Data {
        guard data.count <= limit else {
            throw ArchiveCodecError.limitExceeded("bzip2 buffers the whole payload (\(data.count) bytes > \(limit))")
        }
        do {
            return try BZip2.decompress(data: data)
        } catch {
            throw ArchiveCodecError.corrupt("bzip2 data is invalid or truncated")
        }
    }
}

// MARK: - Verified decoding sources

/// Framing facts about a gzip file: where the (single) member's DEFLATE
/// payload ends and what trailer values are expected. Multi-member files
/// return nil and are handled by the bounded one-shot path, because the raw
/// DEFLATE decoder cannot report where one member ends.
struct GzipFraming {
    var payloadStart: Int64
    var payloadEnd: Int64
    var expectedCRC: UInt32
    var expectedISize: UInt32
    var totalSize: Int64

    enum Inspection {
        case single(GzipFraming)
        case multiMember
    }

    /// Inspects `source` (sequential, restored afterwards).
    static func inspect(_ source: FileByteSource) throws -> Inspection {
        guard let total = source.totalSize, total >= 18 else {
            throw ArchiveCodecError.corrupt("gzip input is truncated")
        }
        let header = try source.readAt(offset: 0, count: 10)
        guard header[header.startIndex] == 0x1F, header[header.startIndex + 1] == 0x8B,
              header[header.startIndex + 2] == 8 else {
            throw ArchiveCodecError.corrupt("not a gzip stream (bad magic)")
        }
        let flags = header[header.startIndex + 3]
        var cursor: Int64 = 10
        if flags & 0x04 != 0 {
            let lengthBytes = try source.readAt(offset: cursor, count: 2)
            let length = Int64(Int(lengthBytes[lengthBytes.startIndex]) | (Int(lengthBytes[lengthBytes.startIndex + 1]) << 8))
            cursor += 2 + length
        }
        if flags & 0x08 != 0 { cursor = try skipZeroTerminated(source, from: cursor) }
        if flags & 0x10 != 0 { cursor = try skipZeroTerminated(source, from: cursor) }
        if flags & 0x02 != 0 { cursor += 2 }
        guard cursor <= total - 8 else { throw ArchiveCodecError.corrupt("gzip header is truncated") }

        let trailer = try source.readAt(offset: total - 8, count: 8)
        let start = trailer.startIndex
        let expectedCRC = UInt32(trailer[start])
            | (UInt32(trailer[start + 1]) << 8)
            | (UInt32(trailer[start + 2]) << 16)
            | (UInt32(trailer[start + 3]) << 24)
        let expectedISize = UInt32(trailer[start + 4])
            | (UInt32(trailer[start + 5]) << 8)
            | (UInt32(trailer[start + 6]) << 16)
            | (UInt32(trailer[start + 7]) << 24)

        // A second member would start with the gzip magic inside the input.
        // The scan only reads; a false positive merely selects the buffered
        // one-shot path, which stays correct.
        if try hasSecondMember(source, payloadStart: cursor, payloadEnd: total - 8) {
            return .multiMember
        }
        return .single(GzipFraming(
            payloadStart: cursor,
            payloadEnd: total - 8,
            expectedCRC: expectedCRC,
            expectedISize: expectedISize,
            totalSize: total
        ))
    }

    private static func skipZeroTerminated(_ source: FileByteSource, from offset: Int64) throws -> Int64 {
        var cursor = offset
        var scratch = Data()
        while true {
            let chunk = try source.readAt(offset: cursor, count: 512)
            guard !chunk.isEmpty else {
                throw ArchiveCodecError.corrupt("gzip header is truncated")
            }
            for byte in chunk {
                if byte == 0 { return cursor + Int64(scratch.count) + 1 }
                scratch.append(byte)
                if scratch.count > 4096 {
                    throw ArchiveCodecError.corrupt("gzip header field is not terminated")
                }
            }
            cursor += Int64(chunk.count)
        }
    }

    private static func hasSecondMember(_ source: FileByteSource, payloadStart: Int64, payloadEnd: Int64) throws -> Bool {
        var cursor = payloadStart
        var previous: UInt8?
        var previous2: UInt8?
        while cursor < payloadEnd {
            let count = Int(min(64 * 1024, payloadEnd - cursor))
            let chunk = try source.readAt(offset: cursor, count: count)
            for byte in chunk {
                if previous2 == 0x1F, previous == 0x8B, byte == 0x08 {
                    return true
                }
                previous2 = previous
                previous = byte
            }
            cursor += Int64(chunk.count)
        }
        return false
    }
}

/// Streams the decompressed bytes of a single-member gzip file, verifying the
/// trailer's CRC32 and ISIZE before the caller trusts the output. The payload
/// is fed to the DEFLATE decoder exactly up to `payloadEnd`, so the trailer is
/// never mistaken for payload even though the system decoder does not report
/// the end of a raw DEFLATE stream.
final class GzipDecodingSource: ArchiveByteSource {
    private let buffered: BufferedSource
    private let trailer: (crc: UInt32, isize: UInt32)
    private var codec: CompressionStreamCodec
    private var out = Data()
    private var outOffset = 0
    private var crc: UInt32 = 0
    private var isize: UInt32 = 0
    private var verified = false
    private var finished = false
    private(set) var position: Int64 = 0
    var totalSize: Int64? { nil }

    init(url: URL, framing: GzipFraming) throws {
        let file = try FileByteSource(url: url)
        _ = try file.read(max: Int(framing.payloadStart))
        let limited = LimitedByteSource(source: file, limit: framing.payloadEnd - framing.payloadStart)
        self.buffered = try BufferedSource(source: limited)
        self.trailer = (framing.expectedCRC, framing.expectedISize)
        guard let codec = CompressionStreamCodec(algorithm: COMPRESSION_ZLIB, operation: COMPRESSION_STREAM_DECODE) else {
            throw ArchiveCodecError.codecUnavailable("gzip (DEFLATE)")
        }
        self.codec = codec
    }

    func read(max: Int) throws -> Data? {
        while out.count - outOffset < max && !finished {
            if let chunk = try buffered.nextInputChunk(limit: 64 * 1024) {
                _ = try codec.process(chunk, finalize: false) { try absorb($0) }
                buffered.rewind(codec.pendingInputBytes)
            } else {
                _ = try codec.process(Data(), finalize: true) { try absorb($0) }
                try verify()
                finished = true
            }
        }
        guard outOffset < out.count else {
            out.removeAll(keepingCapacity: true)
            outOffset = 0
            return nil
        }
        let end = min(outOffset + max, out.count)
        let slice = out.subdata(in: outOffset..<end)
        outOffset = end
        position += Int64(slice.count)
        if outOffset == out.count {
            out.removeAll(keepingCapacity: true)
            outOffset = 0
        }
        return slice
    }

    private func absorb(_ data: Data) throws {
        crc = ArchiveCRC32.checksum(data, seed: crc)
        isize = isize &+ UInt32(truncatingIfNeeded: data.count)
        out.append(data)
    }

    private func verify() throws {
        guard !verified else { return }
        verified = true
        guard crc == trailer.crc else { throw ArchiveCodecError.corrupt("gzip CRC32 mismatch") }
        guard isize == trailer.isize else { throw ArchiveCodecError.corrupt("gzip size mismatch") }
    }
}

/// Presents the decompressed bytes of a `.xz` stream. The system decoder
/// validates the stream's own integrity check; concatenated streams are
/// decoded in sequence like `xz -dc`.
final class VerifiedXZSource: ArchiveByteSource {
    private let buffered: BufferedSource
    private var codec: CompressionStreamCodec
    private var out = Data()
    private var outOffset = 0
    private var memberOpen = true
    private var finished = false
    private(set) var position: Int64 = 0
    var totalSize: Int64? { nil }

    init(source: ArchiveByteSource) throws {
        self.buffered = try BufferedSource(source: source)
        guard let codec = CompressionStreamCodec(algorithm: COMPRESSION_LZMA, operation: COMPRESSION_STREAM_DECODE) else {
            throw ArchiveCodecError.codecUnavailable("xz (LZMA)")
        }
        self.codec = codec
    }

    func read(max: Int) throws -> Data? {
        while out.count - outOffset < max && !finished {
            if memberOpen {
                if let chunk = try buffered.nextInputChunk(limit: 64 * 1024) {
                    let ended = try codec.process(chunk, finalize: false) { out.append($0) }
                    buffered.rewind(codec.pendingInputBytes)
                    if ended { memberOpen = false }
                } else {
                    let ended = try codec.process(Data(), finalize: true) { out.append($0) }
                    guard ended else { throw ArchiveCodecError.corrupt("xz stream is truncated") }
                    memberOpen = false
                }
            } else if let peek = try buffered.peek(1), !peek.isEmpty {
                guard let next = CompressionStreamCodec(algorithm: COMPRESSION_LZMA, operation: COMPRESSION_STREAM_DECODE) else {
                    throw ArchiveCodecError.codecUnavailable("xz (LZMA)")
                }
                codec = next
                memberOpen = true
            } else {
                finished = true
            }
        }
        guard outOffset < out.count else {
            out.removeAll(keepingCapacity: true)
            outOffset = 0
            return nil
        }
        let end = min(outOffset + max, out.count)
        let slice = out.subdata(in: outOffset..<end)
        outOffset = end
        position += Int64(slice.count)
        if outOffset == out.count {
            out.removeAll(keepingCapacity: true)
            outOffset = 0
        }
        return slice
    }
}

// MARK: - Buffered source

/// Adds bounded lookahead to a source. The gzip/xz readers need to know
/// exactly how many bytes a decoder consumed inside a fed chunk so that the
/// following trailer/member can be located; `rewind` returns the unused tail.
final class BufferedSource {
    private let source: ArchiveByteSource
    private var buffer = Data()
    private var offset = 0

    init(source: ArchiveByteSource) throws {
        self.source = source
    }

    /// Next input chunk for the codec, or nil at end of input.
    func nextInputChunk(limit: Int) throws -> Data? {
        if offset < buffer.count {
            let chunk = buffer.subdata(in: offset..<buffer.count)
            offset = buffer.count
            return chunk
        }
        guard let next = try source.read(max: limit), !next.isEmpty else { return nil }
        buffer = next
        offset = buffer.count
        return next
    }

    /// Pushes `count` unused bytes from the last supplied chunk back.
    func rewind(_ count: Int) {
        guard count > 0 else { return }
        offset = max(0, offset - count)
    }

    /// Peeks `count` bytes without consuming them.
    func peek(_ count: Int) throws -> Data? {
        try fill(count)
        guard offset < buffer.count else { return nil }
        let end = min(offset + count, buffer.count)
        return buffer.subdata(in: offset..<end)
    }

    /// Consumes exactly `count` bytes; throws when the source ends early.
    func consume(exactly count: Int) throws -> Data {
        try fill(count)
        guard buffer.count - offset >= count else {
            throw ArchiveCodecError.corrupt("compressed input is truncated")
        }
        let result = buffer.subdata(in: offset..<(offset + count))
        offset += count
        compact()
        return result
    }

    func consumeZeroTerminatedString() throws -> String {
        var result = Data()
        while true {
            let byte = try consume(exactly: 1)
            if byte[byte.startIndex] == 0 { break }
            result.append(byte)
            if result.count > 4096 {
                throw ArchiveCodecError.corrupt("gzip header field is not terminated")
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// Ensures `count` bytes are buffered ahead of the cursor.
    private func fill(_ count: Int) throws {
        while buffer.count - offset < count {
            guard let next = try source.read(max: max(64 * 1024, count)), !next.isEmpty else {
                compact()
                return
            }
            if offset > 0 {
                buffer.removeSubrange(0..<offset)
                offset = 0
            }
            buffer.append(next)
        }
    }

    private func compact() {
        if offset > 0, offset == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 64 * 1024 {
            buffer.removeSubrange(0..<offset)
            offset = 0
        }
    }
}
