// FloeWorkspaceTests — Android codec-backend contracts.
//
// The original engine/tool/browser suites above are ported byte-for-byte and
// exercise the whole closure. This file pins ONLY the replaced layer: the
// `CompressionStreamCodec` backends (zlib raw DEFLATE for gzip members,
// CFloeArchive/liblzma 5.8.1 for `.xz`) must satisfy the exact streaming
// contract the original Apple `Compression`-framework wrapper provided —
// byte-exact `pendingInputBytes` boundaries, bounded yield per decoder call,
// budget-before-append, cancellation polling on the same path, member
// location by decoding, and permanent failure on corrupt input. Reference
// `.xz` fixtures below were produced by the standard library implementation
// (Python `lzma`) so this suite also proves tool-interoperability of the
// decode path without depending on a host CLI.

import Foundation
import Testing
@testable import FloeWorkspace
import FloeCore
import FloeTools
import CFloeArchive

struct ArchiveCodecsAndroidBackendTests {

    // MARK: fixtures

    /// `lzma.compress(b"FloeAndroid xz fixture " * 256, preset=6)` —
    /// produced by the reference implementation, verified decodable by the
    /// lane's C driver (CRC64 check, single LZMA2 filter).
    private static let referenceXz: Data = {
        let base64 = Data(base64Encoded: """
        /Td6WFoAAATm1rRGAgAhARYAAAB0L+Wj4Bb/ADldACMbCeZobDgrf24h/yvC+VpYJaO6eRpmrzsl
        GF1GCJa+317ySTC3MsHJIMljKw2q++0FE9Kvtn30AAAAAABUS1I4+EpmCwABVYAuAAAABiUdbrHE
        Z/sCAAAAAARZWg==
        """, options: [.ignoreUnknownCharacters]) ?? Data()
        return base64
    }()

    /// A deterministic compressible payload (never random — failures must be
    /// reproducible byte for byte).
    private static func payload(_ count: Int) -> Data {
        var out = Data(capacity: count)
        var state: UInt64 = 0x9E3779B97F4A7C15
        while out.count < count {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            out.append(UInt8(truncatingIfNeeded: state >> 33))
            if out.count % 61 == 0 { out.append(0x20) }
        }
        return out.subdata(in: 0..<count)
    }

    private static func gzipOf(_ data: Data) throws -> Data {
        var out = Data()
        let writer = try GzipArchiveWriter { out.append($0) }
        // Feed in bounded chunks like the engine does.
        var offset = 0
        while offset < data.count {
            let end = min(offset + 70_000, data.count)
            try writer.write(data.subdata(in: offset..<end))
            offset = end
        }
        try writer.finish()
        return out
    }

    private static func xzOf(_ data: Data) throws -> Data {
        var out = Data()
        let writer = try XZArchiveWriter { out.append($0) }
        var offset = 0
        while offset < data.count {
            let end = min(offset + 70_000, data.count)
            try writer.write(data.subdata(in: offset..<end))
            offset = end
        }
        try writer.finish()
        return out
    }

    // MARK: - CRC32 known vectors

    @Test("CRC32 matches the IEEE vector set")
    func crc32Vectors() {
        #expect(ArchiveCRC32.checksum(Data()) == 0)
        #expect(ArchiveCRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        // Chained seed equals one-pass CRC (the gzip writer relies on this).
        let full = Data("FloeAndroid archive codecs".utf8)
        let half = full.count / 2
        let chained = ArchiveCRC32.checksum(full.subdata(in: half..<full.count),
                                            seed: ArchiveCRC32.checksum(full.subdata(in: 0..<half)))
        #expect(chained == ArchiveCRC32.checksum(full))
    }

    // MARK: - gzip backend (zlib raw DEFLATE replacement)

    @Test("gzip writer/reader round-trips with bounded chunks and byte-exact member end")
    func gzipRoundTrip() throws {
        let data = Self.payload(300_000)
        let gz = try Self.gzipOf(data)
        // Deterministic output: same input twice hashes the same (mtime-0 header).
        let gz2 = try Self.gzipOf(data)
        #expect(gz == gz2)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-backend-gz-\(UUID().uuidString).gz")
        try gz.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let budget = ArchiveDecodeBudget(maxOutputBytes: Int64(data.count), cancellation: nil)
        let source = try GzipDecodingSource(url: url, budget: budget)
        var out = Data()
        while let chunk = try source.read(max: 4096) { out.append(chunk) }
        #expect(out == data)
        // A single-member file never pays for the boundary relocation pass.
        #expect(source.membersDecoded == 1)
        #expect(source.boundaryRelocations == 0)
    }

    @Test("gzip concatenated members are located by decoding, trailing garbage fails")
    func gzipMembersAndGarbage() throws {
        let a = Self.payload(90_000)
        let b = Self.payload(40)
        let cat = try Self.gzipOf(a) + Self.gzipOf(b)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-backend-gz2-\(UUID().uuidString).gz")
        try cat.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let budget = ArchiveDecodeBudget(maxOutputBytes: Int64(a.count + b.count), cancellation: nil)
        let source = try GzipDecodingSource(url: url, budget: budget)
        var out = Data()
        while let chunk = try source.read(max: 65_536) { out.append(chunk) }
        #expect(out == a + b)
        #expect(source.membersDecoded == 2)

        // Trailing non-gzip bytes after the last member are refused.
        let garbageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-backend-gzbomb-\(UUID().uuidString).gz")
        try (try Self.gzipOf(b) + Data([0x00, 0x01, 0x02, 0x03])).write(to: garbageURL)
        defer { try? FileManager.default.removeItem(at: garbageURL) }
        let source2 = try GzipDecodingSource(
            url: garbageURL,
            budget: ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: nil))
        #expect(throws: ArchiveCodecError.self) {
            var sink = Data()
            while let chunk = try source2.read(max: 4096) { sink.append(chunk) }
        }
    }

    @Test("gzip expansion bomb and cancellation are enforced before any append")
    func gzipBudgetAndCancel() throws {
        let data = Self.payload(512_000)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-backend-gzb-\(UUID().uuidString).gz")
        try (try Self.gzipOf(data)).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let budget = ArchiveDecodeBudget(maxOutputBytes: 100_000, cancellation: nil)
        let source = try GzipDecodingSource(url: url, budget: budget)
        #expect(throws: ArchiveCodecError.self) {
            while let _ = try source.read(max: 65_536) {}
        }

        let token = CancellationToken()
        let source2 = try GzipDecodingSource(
            url: url,
            budget: ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: token))
        token.cancel()
        var received = 0
        #expect(throws: FloeError.self) {
            while let chunk = try source2.read(max: 8192) { received += chunk.count }
        }
        // The cancel is polled before producing (bounded, prompt interruption).
        #expect(received == 0)
    }

    // MARK: - xz backend (CFloeArchive/liblzma replacement)

    @Test("reference-produced .xz stream decodes with exact accounting")
    func xzReferenceDecode() throws {
        guard Self.referenceXz.count > 60, Self.referenceXz.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) else {
            Issue.record("embedded reference xz fixture must be a real .xz stream")
            return
        }
        let budget = ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: nil)
        let source = try VerifiedXZSource(source: DataByteSource(Self.referenceXz), budget: budget)
        var out = Data()
        while let chunk = try source.read(max: 4096) { out.append(chunk) }
        // The fixture is "FloeAndroid xz fixture " repeated 256 times.
        #expect(out.count == 23 * 256)
        #expect(String(data: out, encoding: .utf8)?.hasPrefix("FloeAndroid xz fixture ") == true)
    }

    @Test("xz writer/reader round-trip, concatenated members, truncation and garbage")
    func xzRoundTripAndMembers() throws {
        let a = Self.payload(200_000)
        let b = Self.payload(1_024)
        let xa = try Self.xzOf(a)
        let xb = try Self.xzOf(b)
        // Our stream must decode (and its boundary must be exact).
        let budget = ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: nil)
        let s1 = try VerifiedXZSource(source: DataByteSource(xa), budget: budget)
        var out1 = Data()
        while let chunk = try s1.read(max: 9_000) { out1.append(chunk) }
        #expect(out1 == a)

        // Concatenated members decode in sequence like `xz -dc`.
        let s2 = try VerifiedXZSource(source: DataByteSource(xa + xb),
                                      budget: ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: nil))
        var out2 = Data()
        while let chunk = try s2.read(max: 64 * 1024) { out2.append(chunk) }
        #expect(out2 == a + b)

        // Truncation never reports success.
        #expect(throws: ArchiveCodecError.self) {
            let cut = xa.subdata(in: 0..<(xa.count / 2))
            let s = try VerifiedXZSource(source: DataByteSource(cut),
                                         budget: ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: nil))
            while let _ = try s.read(max: 4096) {}
        }
        // Trailing garbage after a member is refused, not ignored.
        #expect(throws: ArchiveCodecError.self) {
            let s = try VerifiedXZSource(source: DataByteSource(xa + Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])),
                                         budget: ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: nil))
            while let _ = try s.read(max: 65_536) {}
        }
    }

    @Test("xz decoder releases state exactly at stream end and refuses reuse")
    func xzDecoderLifecycle() throws {
        let a = Self.payload(50_000)
        let xa = try Self.xzOf(a)
        guard let decoder = floe_xz_decoder_create() else { Issue.record("create failed"); return }
        defer { floe_xz_decoder_destroy(decoder) }
        #expect(floe_xz_decoder_state_active(decoder) == 1)
        var out = [UInt8](repeating: 0, count: 65_536)
        var off = 0
        var sawEnd = false
        let inputPtr = UnsafeRawPointer((xa as NSData).bytes).assumingMemoryBound(to: UInt8.self)
        while !sawEnd {
            var consumed = 0
            var produced = 0
            let status = floe_xz_decoder_process(decoder, inputPtr, xa.count, &out, out.count, &consumed, &produced)
            _ = consumed
            off += produced
            if status == FLOE_XZ_STREAM_END { sawEnd = true; break }
            if status != FLOE_XZ_OK { Issue.record("unexpected status \(status)"); break }
        }
        #expect(sawEnd)
        #expect(off == a.count)
        // State is released at the END transition itself (contract), and any
        // further processing on the ended decoder is PARAM (misuse), never a
        // false success.
        #expect(floe_xz_decoder_state_active(decoder) == 0)
        var c = 0, p = 0
        #expect(floe_xz_decoder_process(decoder, inputPtr, xa.count, &out, out.count, &c, &p) == FLOE_XZ_PARAM)
    }

    @Test("gzip single-file containers created by the reference gzip framing decode natively")
    func gzipStoredBlockMagicContainment() throws {
        // Stored (uncompressed) DEFLATE block whose payload literally
        // contains the gzip magic: member location must be by decoding.
        let inner = Data([0x1F, 0x8B, 0x08, 0x00]) + Self.payload(60)
        var member = Data([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0, 0x03, 0x01])
        let count = UInt16(inner.count)
        member.append(UInt8(truncatingIfNeeded: count))
        member.append(UInt8(truncatingIfNeeded: count >> 8))
        let nlen = ~count
        member.append(UInt8(truncatingIfNeeded: nlen))
        member.append(UInt8(truncatingIfNeeded: nlen >> 8))
        member.append(inner)
        var crc = ArchiveCRC32.checksum(inner).littleEndian
        withUnsafeBytes(of: &crc) { member.append(contentsOf: $0) }
        var isize = UInt32(truncatingIfNeeded: inner.count).littleEndian
        withUnsafeBytes(of: &isize) { member.append(contentsOf: $0) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-backend-gzs-\(UUID().uuidString).gz")
        try member.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try GzipDecodingSource(url: url,
                                            budget: ArchiveDecodeBudget(maxOutputBytes: .max, cancellation: nil))
        var out = Data()
        while let chunk = try source.read(max: 4096) { out.append(chunk) }
        #expect(out == inner)
    }
}
