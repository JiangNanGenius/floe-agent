// FloeWorkspace — native compressed-stream codecs.
//
// The workspace archive tool used to route tar.gz/tar.bz2/tar.xz and single
// file gzip/bzip2/xz through the task environment's guest Python. That made a
// device-local operation depend on a Linux runtime (and on a pool slot).
// These codecs implement the same formats on the host:
//
//   * gzip  — gzip member framing around raw DEFLATE (system Compression
//             framework), CRC32/ISIZE verified on read. Members are located
//             by decoding, never by scanning compressed bytes for a magic.
//   * bzip2 — the SDK's own libbz2 streaming API through the `CFloeArchive`
//             C shim (`ArchiveBzip2.swift`): bounded decode with
//             concatenated members located by decoding, and bounded stream
//             encode. No one-shot buffer exists in either direction.
//   * xz    — the system Compression framework's LZMA codec emits/consumes a
//             complete `.xz` stream (liblzma-compatible), so tar.xz and .xz
//             stay native without a new dependency.
//
// Everything is pull/push streaming: callers feed input in bounded chunks and
// receive output chunks, so peak memory does not grow with file size. Decoders
// enforce an `ArchiveDecodeBudget` *before* appending a produced chunk, and
// poll cancellation on the same path, so an expansion bomb fails while memory
// is still bounded by the codec's fixed buffers. All codecs are synchronous.

import Foundation
import Compression
import FloeCore
import FloeTools

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

// MARK: - Decode budget

/// Decode-side resource guard shared by every decompression path.
///
/// A budget is consulted *before* a produced chunk is handed to a sink, so an
/// expansion bomb is refused while memory is still bounded by the codec's
/// fixed buffers — it is never detected "after the fact" by inspecting a
/// materialized `Data`. Cancellation is polled on the same path at chunk (and,
/// for gzip boundary location, byte) granularity, which makes a long decode
/// promptly interruptible.
final class ArchiveDecodeBudget {
    let maxOutputBytes: Int64
    let cancellation: CancellationToken?
    private(set) var producedBytes: Int64 = 0

    init(maxOutputBytes: Int64, cancellation: CancellationToken?) {
        self.maxOutputBytes = maxOutputBytes
        self.cancellation = cancellation
    }

    /// Throws `FloeError.cancelled` when cancellation was requested.
    func poll() throws {
        try cancellation?.throwIfCancelled()
    }

    /// Throws before the caller can append `count` bytes of decoded output.
    func reserve(_ count: Int) throws {
        try poll()
        guard Int64(count) <= maxOutputBytes - producedBytes else {
            throw ArchiveCodecError.limitExceeded("decompressed output exceeds the \(maxOutputBytes)-byte budget")
        }
    }

    func didProduce(_ count: Int) {
        producedBytes += Int64(count)
    }
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
/// last fed chunk the codec did not consume, which is what lets a reader find
/// the trailer/member that follows a DEFLATE or LZMA stream.
///
/// Decoders set `maxOutputPerCall` so one `process` call yields back to its
/// caller after a bounded amount of output: no caller can grow a buffer past
/// its own working set plus one fixed chunk. When a budget is supplied it is
/// checked before every sink call, so the append itself is bounded.
final class CompressionStreamCodec {
    /// One decoder `process` call returns after producing at most this much,
    /// leaving the rest of the input as `pendingInputBytes` for the next call.
    static let decoderCallOutputLimit = 256 * 1024

    private var stream: compression_stream
    private let isEncoder: Bool
    private var outBuffer: [UInt8]
    private let maxOutputPerCall: Int?
    private(set) var finished = false
    /// True when the last `process` call returned early only because it hit
    /// `maxOutputPerCall` (i.e. progress was made and the caller must feed the
    /// unconsumed tail or call again to drain).
    private(set) var yieldedForOutputLimit = false

    /// Bytes of the most recently fed chunk that the codec did not consume.
    private(set) var pendingInputBytes = 0

    init?(
        algorithm: compression_algorithm,
        operation: compression_stream_operation,
        bufferSize: Int = 64 * 1024,
        maxOutputPerCall: Int? = nil
    ) {
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
        self.maxOutputPerCall = maxOutputPerCall
    }

    deinit {
        compression_stream_destroy(&stream)
    }

    /// Feeds `input` (empty is allowed) and calls `sink` for every produced
    /// chunk. Pass `finalize: true` on the last call. Returns true when the
    /// stream reached its end marker.
    ///
    /// With `maxOutputPerCall` set, a false return does not mean the stream is
    /// incomplete: the unconsumed tail of `input` is reported through
    /// `pendingInputBytes` and must be fed again.
    @discardableResult
    func process(
        _ input: Data,
        finalize: Bool,
        budget: ArchiveDecodeBudget? = nil,
        sink: (Data) throws -> Void
    ) throws -> Bool {
        if finished {
            if !input.isEmpty {
                // Trailing bytes after a complete gzip/xz member: the caller
                // decides whether that is a second member or garbage.
                pendingInputBytes = input.count
            }
            yieldedForOutputLimit = false
            return true
        }
        yieldedForOutputLimit = false
        var reachedEnd = false
        try input.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            stream.src_ptr = base ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = input.count
            let flags = finalize ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            var producedThisCall = 0
            while true {
                try budget?.poll()
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
                    // The budget check happens before the append: an
                    // expansion bomb never reaches the caller's buffer.
                    try budget?.reserve(produced)
                    try sink(Data(outBuffer[0..<produced]))
                    budget?.didProduce(produced)
                    producedThisCall += produced
                }
                let pending = stream.src_size
                if status == COMPRESSION_STATUS_END {
                    reachedEnd = true
                    pendingInputBytes = pending
                    break
                }
                if let limit = maxOutputPerCall, producedThisCall >= limit {
                    // Yield to the caller; it re-feeds the unconsumed tail.
                    pendingInputBytes = pending
                    yieldedForOutputLimit = true
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

// MARK: - Verified decoding sources

/// Facts about one gzip member header.
///
/// Only the fixed header and its bounded optional fields are read here: member
/// boundaries are found by decoding the DEFLATE payload, never by scanning
/// compressed bytes for the gzip magic (a payload may contain `1f 8b 08`).
struct GzipMemberHeader {
    var payloadStart: Int64

    /// Parses the member header at `offset`. `end` is the file size; the
    /// trailer of the last member still has to fit after the payload.
    static func parse(file: FileByteSource, offset: Int64, end: Int64) throws -> GzipMemberHeader {
        let header = try file.readAt(offset: offset, count: 10)
        let start = header.startIndex
        guard header.count == 10,
              header[start] == 0x1F,
              header[start + 1] == 0x8B,
              header[start + 2] == 8 else {
            throw ArchiveCodecError.corrupt("not a gzip stream (bad magic or method)")
        }
        let flags = header[start + 3]
        guard flags & 0xE0 == 0 else {
            throw ArchiveCodecError.corrupt("gzip header uses reserved flag bits")
        }
        var cursor = offset + 10
        if flags & 0x04 != 0 { // FEXTRA
            let lengthBytes = try file.readAt(offset: cursor, count: 2)
            guard lengthBytes.count == 2 else {
                throw ArchiveCodecError.corrupt("gzip header is truncated")
            }
            let extraStart = lengthBytes.startIndex
            let length = Int(lengthBytes[extraStart]) | (Int(lengthBytes[extraStart + 1]) << 8)
            cursor += 2 + Int64(length)
        }
        if flags & 0x08 != 0 { // FNAME
            cursor = try skipZeroTerminated(file: file, from: cursor, end: end, field: "name")
        }
        if flags & 0x10 != 0 { // FCOMMENT
            cursor = try skipZeroTerminated(file: file, from: cursor, end: end, field: "comment")
        }
        if flags & 0x02 != 0 { cursor += 2 } // FHCRC (not verified)
        guard cursor + 8 <= end else {
            throw ArchiveCodecError.corrupt("gzip header is truncated")
        }
        return GzipMemberHeader(payloadStart: cursor)
    }

    private static func skipZeroTerminated(
        file: FileByteSource,
        from offset: Int64,
        end: Int64,
        field: String
    ) throws -> Int64 {
        var cursor = offset
        var scanned = 0
        while cursor < end {
            let chunk = try file.readAt(offset: cursor, count: 512)
            guard !chunk.isEmpty else { break }
            for (index, byte) in chunk.enumerated() {
                scanned += 1
                if byte == 0 { return cursor + Int64(index) + 1 }
                if scanned > 4_096 {
                    throw ArchiveCodecError.corrupt("gzip header \(field) field is not terminated")
                }
            }
            cursor += Int64(chunk.count)
        }
        throw ArchiveCodecError.corrupt("gzip header \(field) field is truncated")
    }
}

/// Streams the decompressed bytes of a gzip file — one member or many
/// concatenated members.
///
/// The system raw-DEFLATE decoder reports the end marker but swallows any
/// trailing bytes of the buffer it was given, so it cannot say where the
/// deflate stream ended. This reader therefore feeds the payload in bounded
/// chunks and, when the end marker arrives, pins the exact boundary by
/// re-decoding at most one `chunkSize` window (output discarded); the 8-byte
/// trailer is then read from its real position and CRC32/ISIZE are verified.
/// The last `byteWiseTail` bytes before the final trailer are fed one byte at
/// a time, so an ordinary single-member file never pays for the second pass.
///
/// Memory stays bounded (fixed codec buffers plus one bounded window) and the
/// decode budget is consulted before any produced chunk is appended, so an
/// expansion bomb fails while memory is still small.
final class GzipDecodingSource: ArchiveByteSource {
    /// Input chunk size; a boundary window is never larger than this.
    static let chunkSize = 16 * 1024
    /// The tail of the file is fed byte by byte so single-member files resolve
    /// their boundary in one pass.
    static let byteWiseTail = 16 * 1024

    private let file: FileByteSource
    private let fileSize: Int64
    private let lastTrailerStart: Int64
    private let budget: ArchiveDecodeBudget

    private var out = Data()
    private var outOffset = 0
    private(set) var position: Int64 = 0
    private(set) var finished = false
    /// Diagnostics: verified members and boundary re-decode passes (the latter
    /// is 0 for an ordinary single-member file).
    private(set) var membersDecoded = 0
    private(set) var boundaryRelocations = 0
    /// Offset of the next member header.
    private var cursor: Int64 = 0
    private var codec: CompressionStreamCodec?
    private var payloadStart: Int64 = 0
    private var feedOffset: Int64 = 0
    private var crc: UInt32 = 0
    private var isize: UInt32 = 0
    /// Window of the last fed chunk in which the DEFLATE end marker arrived.
    private var boundaryWindow: (start: Int64, length: Int)?

    init(url: URL, budget: ArchiveDecodeBudget) throws {
        self.file = try FileByteSource(url: url)
        guard let total = file.totalSize, total >= 18 else {
            throw ArchiveCodecError.corrupt("gzip input is truncated")
        }
        self.fileSize = total
        self.lastTrailerStart = total - 8
        self.budget = budget
    }

    var totalSize: Int64? { nil }

    func read(max: Int) throws -> Data? {
        while out.count - outOffset < max && !finished {
            try pump()
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

    private func pump() throws {
        try budget.poll()
        if codec == nil && !finished {
            try startMember()
        }
        guard let codec, !finished else { return }
        if let window = boundaryWindow {
            boundaryRelocations += 1
            let deflateEnd = try locateDeflateEnd(windowStart: window.start, windowLength: window.length)
            try finishMember(deflateEnd: deflateEnd)
            return
        }
        let remaining = lastTrailerStart - feedOffset
        guard remaining > 0 else {
            throw ArchiveCodecError.corrupt("gzip member does not end before its trailer area")
        }
        if remaining <= Int64(Self.byteWiseTail) {
            // Terminal zone: one byte per call pins the deflate boundary exactly.
            let byte = try file.readAt(offset: feedOffset, count: 1)
            guard byte.count == 1 else {
                throw ArchiveCodecError.corrupt("gzip member payload is truncated")
            }
            let ended = try codec.process(byte, finalize: false, budget: budget) { try absorb($0) }
            // A not-fully-consumed byte stays in place and is re-fed, so no
            // input can be lost when a yielded call returns early.
            feedOffset += Int64(byte.count - codec.pendingInputBytes)
            if ended { try finishMember(deflateEnd: feedOffset) }
        } else {
            let want = Int(min(Int64(Self.chunkSize), remaining - Int64(Self.byteWiseTail)))
            let chunk = try file.readAt(offset: feedOffset, count: want)
            guard !chunk.isEmpty else {
                throw ArchiveCodecError.corrupt("gzip member payload is truncated")
            }
            let chunkStart = feedOffset
            let ended = try codec.process(chunk, finalize: false, budget: budget) { try absorb($0) }
            feedOffset += Int64(chunk.count - codec.pendingInputBytes)
            if ended {
                boundaryWindow = (chunkStart, chunk.count)
            }
        }
    }

    private func startMember() throws {
        let header = try GzipMemberHeader.parse(file: file, offset: cursor, end: fileSize)
        payloadStart = header.payloadStart
        feedOffset = header.payloadStart
        crc = 0
        isize = 0
        boundaryWindow = nil
        guard header.payloadStart < lastTrailerStart else {
            throw ArchiveCodecError.corrupt("gzip member has no deflate payload")
        }
        guard let codec = CompressionStreamCodec(
            algorithm: COMPRESSION_ZLIB,
            operation: COMPRESSION_STREAM_DECODE,
            maxOutputPerCall: CompressionStreamCodec.decoderCallOutputLimit
        ) else {
            throw ArchiveCodecError.codecUnavailable("gzip (DEFLATE)")
        }
        self.codec = codec
    }

    /// Re-decodes `[payloadStart, windowStart)` (output discarded) and then
    /// feeds the window byte by byte until the codec reports the end marker,
    /// which pins the exclusive end of the DEFLATE stream. Bounded by one
    /// chunk window plus one extra pass over the member; cancellation is
    /// polled per chunk and per byte.
    private func locateDeflateEnd(windowStart: Int64, windowLength: Int) throws -> Int64 {
        guard let probe = CompressionStreamCodec(
            algorithm: COMPRESSION_ZLIB,
            operation: COMPRESSION_STREAM_DECODE,
            maxOutputPerCall: CompressionStreamCodec.decoderCallOutputLimit
        ) else {
            throw ArchiveCodecError.codecUnavailable("gzip (DEFLATE)")
        }
        // The probe must not consume the caller's output budget: its output is
        // discarded. It still polls cancellation and yields per chunk.
        let probeBudget = ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: budget.cancellation)
        var offset = payloadStart
        while offset < windowStart {
            try budget.poll()
            let want = Int(min(Int64(Self.chunkSize), windowStart - offset))
            let chunk = try file.readAt(offset: offset, count: want)
            guard !chunk.isEmpty else {
                throw ArchiveCodecError.corrupt("gzip member payload is truncated")
            }
            let ended = try probe.process(chunk, finalize: false, budget: probeBudget) { _ in }
            offset += Int64(chunk.count - probe.pendingInputBytes)
            if ended {
                // The stream ended exactly on a chunk boundary: the first pass
                // must have seen the end marker on that same chunk.
                guard offset == windowStart else {
                    throw ArchiveCodecError.corrupt("gzip member boundary is inconsistent")
                }
                return offset
            }
        }
        var cursor = windowStart
        let windowEnd = windowStart + Int64(windowLength)
        while cursor < windowEnd {
            try budget.poll()
            let byte = try file.readAt(offset: cursor, count: 1)
            guard byte.count == 1 else {
                throw ArchiveCodecError.corrupt("gzip member payload is truncated")
            }
            let ended = try probe.process(byte, finalize: false, budget: probeBudget) { _ in }
            if ended { return cursor + 1 }
            // Advance only by what the probe consumed; an early-yielded byte is
            // re-fed rather than skipped.
            cursor += Int64(byte.count - probe.pendingInputBytes)
        }
        throw ArchiveCodecError.corrupt("gzip member deflate stream has no end marker")
    }

    private func finishMember(deflateEnd: Int64) throws {
        guard deflateEnd >= payloadStart, deflateEnd + 8 <= fileSize else {
            throw ArchiveCodecError.corrupt("gzip trailer is truncated")
        }
        let trailer = try file.readAt(offset: deflateEnd, count: 8)
        guard trailer.count == 8 else {
            throw ArchiveCodecError.corrupt("gzip trailer is truncated")
        }
        let start = trailer.startIndex
        let expectedCRC = UInt32(trailer[start])
            | (UInt32(trailer[start + 1]) << 8)
            | (UInt32(trailer[start + 2]) << 16)
            | (UInt32(trailer[start + 3]) << 24)
        let expectedISize = UInt32(trailer[start + 4])
            | (UInt32(trailer[start + 5]) << 8)
            | (UInt32(trailer[start + 6]) << 16)
            | (UInt32(trailer[start + 7]) << 24)
        guard crc == expectedCRC else { throw ArchiveCodecError.corrupt("gzip CRC32 mismatch") }
        guard isize == expectedISize else { throw ArchiveCodecError.corrupt("gzip size mismatch") }

        membersDecoded += 1
        cursor = deflateEnd + 8
        codec = nil
        boundaryWindow = nil
        if cursor == fileSize {
            finished = true
            return
        }
        // Concatenated members are supported; anything else is a hard error
        // instead of silently ignoring trailing bytes.
        let magic = try file.readAt(offset: cursor, count: 2)
        guard magic.count == 2,
              magic[magic.startIndex] == 0x1F,
              magic[magic.startIndex + 1] == 0x8B else {
            throw ArchiveCodecError.corrupt("gzip file has trailing data after its last member")
        }
    }

    private func absorb(_ data: Data) throws {
        crc = ArchiveCRC32.checksum(data, seed: crc)
        isize = isize &+ UInt32(truncatingIfNeeded: data.count)
        out.append(data)
    }
}

/// Presents the decompressed bytes of a `.xz` stream. The system decoder
/// validates the stream's own integrity check; concatenated streams are
/// decoded in sequence like `xz -dc`. Every produced chunk passes the
/// `ArchiveDecodeBudget` before it is appended, and each decoder yields after
/// a bounded amount of output.
final class VerifiedXZSource: ArchiveByteSource {
    private let buffered: BufferedSource
    private var codec: CompressionStreamCodec
    private let budget: ArchiveDecodeBudget
    private var out = Data()
    private var outOffset = 0
    private var memberOpen = true
    private var finished = false
    private(set) var position: Int64 = 0
    var totalSize: Int64? { nil }

    init(source: ArchiveByteSource, budget: ArchiveDecodeBudget) throws {
        self.buffered = try BufferedSource(source: source)
        self.budget = budget
        guard let codec = Self.makeCodec() else {
            throw ArchiveCodecError.codecUnavailable("xz (LZMA)")
        }
        self.codec = codec
    }

    private static func makeCodec() -> CompressionStreamCodec? {
        CompressionStreamCodec(
            algorithm: COMPRESSION_LZMA,
            operation: COMPRESSION_STREAM_DECODE,
            maxOutputPerCall: CompressionStreamCodec.decoderCallOutputLimit
        )
    }

    func read(max: Int) throws -> Data? {
        while out.count - outOffset < max && !finished {
            try budget.poll()
            if memberOpen {
                if let chunk = try buffered.nextInputChunk(limit: 64 * 1024) {
                    let ended = try codec.process(chunk, finalize: false, budget: budget) { out.append($0) }
                    buffered.rewind(codec.pendingInputBytes)
                    if ended { memberOpen = false }
                } else {
                    let ended = try codec.process(Data(), finalize: true, budget: budget) { out.append($0) }
                    if ended {
                        memberOpen = false
                    } else if !codec.yieldedForOutputLimit {
                        // No end marker and no further output: the stream is
                        // truncated (not merely yielding for the caller).
                        throw ArchiveCodecError.corrupt("xz stream is truncated")
                    }
                }
            } else if let peek = try buffered.peek(1), !peek.isEmpty {
                guard let next = Self.makeCodec() else {
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
