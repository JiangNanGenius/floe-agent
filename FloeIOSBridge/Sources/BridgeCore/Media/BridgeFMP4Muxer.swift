import Foundation

/// Fragmented MP4 (ISO/IEC 14496-12) muxer for a single live H.264 video track.
///
/// This is a Swift 6 adaptation of `iCTRLUITests/FMP4Muxer.swift` from
/// OpenMinis/iCTRL at commit `c1e4268859ba858d1579f7b846a56cb40641b7f6`
/// (Apache-2.0). The upstream algorithm is retained: one `moof` + `mdat` per
/// encoded access unit, a 90 kHz timescale, `avcC` built from the encoder's
/// actual SPS/PPS, and an SPS VUI rewrite that declares zero frame reordering.
/// Local changes are limited to:
///
/// * Swift 6 / Foundation-only compilation (no UIKit, XCTest, CoreMedia or
///   AVFoundation types cross this module boundary);
/// * an explicit throwing API with bounded sample validation;
/// * a bounded, checked `trun.data_offset` patch instead of a fixed offset;
/// * cached init segment and read-only sequence/decode-time diagnostics.
///
/// What a browser's MediaSource needs is preserved: `ftyp` + `moov` (with
/// `avc1`/`avcC`) followed by monotonic `moof`/`mdat` fragments. Rotation or
/// resolution changes are **not** represented by this muxer; the caller must
/// close consumers and require a fresh init segment.
///
/// Thread ownership: instances are mutable and not thread-safe. The host
/// creates and advances one on a single serial media queue.
public final class BridgeFMP4Muxer {
    public enum MuxerError: Error, Equatable {
        case invalidDimensions
        case invalidParameterSets
        case emptySample
        case sampleTooLarge
        case malformedFragmentLayout
    }

    /// The pinned upstream uses 90 kHz, matching the H.264/TS convention and
    /// keeping decode/presentation deltas exact for integer milliseconds.
    public static let timescale: UInt32 = 90_000

    private let trackID: UInt32 = 1
    private let sps: Data
    private let pps: Data
    private let cachedInitSegment: Data
    private var sequenceNumber: UInt32 = 1
    private var nextBaseDecodeTime: UInt64 = 0

    public let width: Int
    public let height: Int
    public let codecString: String

    /// `sps`/`pps` are the raw NAL units captured from the encoder format
    /// description (without start codes). Dimensions must be positive and fit
    /// the 16-bit visual sample entry fields.
    public init?(width: Int, height: Int, sps: Data, pps: Data) {
        guard width > 0, height > 0, width <= Int(UInt16.max), height <= Int(UInt16.max) else {
            return nil
        }
        guard sps.count >= 4, !pps.isEmpty, sps.count <= Int(UInt16.max), pps.count <= Int(UInt16.max) else {
            return nil
        }
        let rewrittenSPS = BridgeH264LowDelaySPS.rewrite(sps) ?? sps
        guard rewrittenSPS.count >= 4 else { return nil }
        self.width = width
        self.height = height
        self.sps = rewrittenSPS
        self.pps = pps
        self.codecString = String(format: "avc1.%02X%02X%02X",
                                  rewrittenSPS[1], rewrittenSPS[2], rewrittenSPS[3])
        self.cachedInitSegment = Self.makeInitSegment(width: width,
                                                      height: height,
                                                      sps: rewrittenSPS,
                                                      pps: pps)
    }

    /// `ftyp` + `moov`; send once to every subscriber before any fragment.
    public func initSegment() -> Data {
        cachedInitSegment
    }

    /// Decode time that the next fragment will carry, in the 90 kHz timescale.
    public var nextDecodeTimeTicks: UInt64 {
        nextBaseDecodeTime
    }

    /// Monotonic fragment sequence number for diagnostics.
    public var currentSequenceNumber: UInt32 {
        sequenceNumber
    }

    /// One access unit (one frame) as a `moof` + `mdat` pair.
    ///
    /// `nalus` are length-prefixed AVCC payload NAL units (no start codes).
    /// SPS/PPS/AUD must already be excluded; they live in the init segment.
    /// `presentationTicks` optionally pins this fragment's `tfdt` to the
    /// encoder presentation time. The value is raised to the previous decode
    /// time if necessary, so the emitted timeline is always monotonic even if
    /// capture time is irregular. Passing nil keeps the upstream behaviour of
    /// advancing by `durationTicks` alone.
    @discardableResult
    public func fragment(nalus: [Data],
                         durationTicks: UInt32,
                         keyframe: Bool,
                         presentationTicks: UInt64? = nil) throws -> Data {
        guard !nalus.isEmpty else { throw MuxerError.emptySample }
        guard durationTicks > 0 else { throw MuxerError.emptySample }

        var mdatPayload = Data()
        for nal in nalus {
            guard !nal.isEmpty else { throw MuxerError.emptySample }
            guard nal.count <= Int(UInt32.max) else { throw MuxerError.sampleTooLarge }
            guard mdatPayload.count <= Self.maximumSampleBytes - nal.count - 4 else {
                throw MuxerError.sampleTooLarge
            }
            mdatPayload.append(Self.u32be(UInt32(nal.count)))
            mdatPayload.append(nal)
        }

        let sampleSize = UInt32(mdatPayload.count)
        let baseDecodeTime = max(nextBaseDecodeTime, presentationTicks ?? nextBaseDecodeTime)
        nextBaseDecodeTime = baseDecodeTime &+ UInt64(durationTicks)

        let moofData = moof(sequenceNumber: sequenceNumber,
                            baseDecodeTime: baseDecodeTime,
                            sampleSize: sampleSize,
                            sampleDuration: durationTicks,
                            keyframe: keyframe)
        sequenceNumber &+= 1

        let patched = try patchTrunDataOffset(moof: moofData,
                                              dataOffset: Int32(moofData.count + 8))
        var out = Data()
        out.reserveCapacity(patched.count + 8 + mdatPayload.count)
        out.append(patched)
        out.append(Self.box("mdat", body: mdatPayload))
        return out
    }

    // MARK: - Box builders (ISO/IEC 14496-12 + 14496-15)

    private static let maximumSampleBytes = 8 * 1_024 * 1_024

    private static func box(_ type: String, body: Data) -> Data {
        var out = Data()
        out.reserveCapacity(8 + body.count)
        out.append(u32be(UInt32(8 + body.count)))
        out.append(type.data(using: .ascii)!)
        out.append(body)
        return out
    }

    private static func fullBox(_ type: String,
                                version: UInt8 = 0,
                                flags: UInt32 = 0,
                                body: Data) -> Data {
        var inner = Data()
        inner.append(version)
        inner.append(u24be(flags))
        inner.append(body)
        return box(type, body: inner)
    }

    private static func makeInitSegment(width: Int, height: Int,
                                        sps: Data, pps: Data) -> Data {
        var moovBody = Data()
        moovBody.append(mvhd())
        moovBody.append(trak(width: width, height: height, sps: sps, pps: pps))
        moovBody.append(mvex())
        var out = Data()
        out.append(ftyp())
        out.append(box("moov", body: moovBody))
        return out
    }

    private static func ftyp() -> Data {
        var body = Data()
        body.append("iso5".data(using: .ascii)!)     // major brand
        body.append(u32be(512))                      // minor version
        for brand in ["iso5", "iso6", "avc1", "mp41"] {
            body.append(brand.data(using: .ascii)!)  // compatible brands
        }
        return box("ftyp", body: body)
    }

    private static func mvhd() -> Data {
        var body = Data()
        body.append(u32be(0))                        // creation_time
        body.append(u32be(0))                        // modification_time
        body.append(u32be(timescale))                // timescale
        body.append(u32be(0))                        // duration (fragmented)
        body.append(u32be(0x0001_0000))              // rate 1.0
        body.append(u16be(0x0100))                   // volume 1.0
        body.append(u16be(0))                        // reserved
        body.append(Data(repeating: 0, count: 8))    // reserved[2]
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] {
            body.append(u32be(value))
        }
        body.append(Data(repeating: 0, count: 24))   // pre_defined[6]
        body.append(u32be(0xFFFF_FFFF))              // next_track_ID
        return fullBox("mvhd", body: body)
    }

    private static func trak(width: Int, height: Int, sps: Data, pps: Data) -> Data {
        var body = Data()
        body.append(tkhd(width: width, height: height))
        body.append(mdia(width: width, height: height, sps: sps, pps: pps))
        return box("trak", body: body)
    }

    private static func tkhd(width: Int, height: Int) -> Data {
        var body = Data()
        body.append(u32be(0))                        // creation_time
        body.append(u32be(0))                        // modification_time
        body.append(u32be(1))                        // track_ID
        body.append(u32be(0))                        // reserved
        body.append(u32be(0))                        // duration
        body.append(Data(repeating: 0, count: 8))    // reserved[2]
        body.append(u16be(0))                        // layer
        body.append(u16be(0))                        // alternate_group
        body.append(u16be(0))                        // volume
        body.append(u16be(0))                        // reserved
        for value: UInt32 in [0x0001_0000, 0, 0, 0, 0x0001_0000, 0, 0, 0, 0x4000_0000] {
            body.append(u32be(value))
        }
        body.append(u32be(UInt32(width) << 16))      // width 16.16
        body.append(u32be(UInt32(height) << 16))     // height 16.16
        return fullBox("tkhd", flags: 0x000007, body: body)
    }

    private static func mdia(width: Int, height: Int, sps: Data, pps: Data) -> Data {
        var body = Data()
        body.append(mdhd())
        body.append(hdlr())
        body.append(minf(width: width, height: height, sps: sps, pps: pps))
        return box("mdia", body: body)
    }

    private static func mdhd() -> Data {
        var body = Data()
        body.append(u32be(0))                        // creation_time
        body.append(u32be(0))                        // modification_time
        body.append(u32be(timescale))                // timescale
        body.append(u32be(0))                        // duration
        let und: UInt16 = ((UInt16(0x15) & 0x1F) << 10)
            | ((UInt16(0x0E) & 0x1F) << 5)
            | (UInt16(0x04) & 0x1F)
        body.append(u16be(und))                      // language
        body.append(u16be(0))                        // pre_defined
        return fullBox("mdhd", body: body)
    }

    private static func hdlr() -> Data {
        var body = Data()
        body.append(u32be(0))                        // pre_defined
        body.append("vide".data(using: .ascii)!)     // handler_type
        body.append(Data(repeating: 0, count: 12))   // reserved[3]
        body.append(Data("Floe Bridge Video\0".utf8)) // name
        return fullBox("hdlr", body: body)
    }

    private static func minf(width: Int, height: Int, sps: Data, pps: Data) -> Data {
        var body = Data()
        body.append(vmhd())
        body.append(dinf())
        body.append(stbl(width: width, height: height, sps: sps, pps: pps))
        return box("minf", body: body)
    }

    private static func vmhd() -> Data {
        var body = Data()
        body.append(u16be(0))                        // graphicsmode
        body.append(Data(repeating: 0, count: 6))    // opcolor[3]
        return fullBox("vmhd", flags: 1, body: body)
    }

    private static func dinf() -> Data {
        var drefBody = Data()
        drefBody.append(u32be(1))                    // entry_count
        drefBody.append(fullBox("url ", flags: 1, body: Data()))
        return box("dinf", body: fullBox("dref", body: drefBody))
    }

    private static func stbl(width: Int, height: Int, sps: Data, pps: Data) -> Data {
        var body = Data()
        body.append(stsd(width: width, height: height, sps: sps, pps: pps))
        body.append(fullBox("stts", body: u32be(0)))
        body.append(fullBox("stsc", body: u32be(0)))
        body.append(fullBox("stsz", body: Data([0, 0, 0, 0]) + u32be(0) + u32be(0)))
        body.append(fullBox("stco", body: u32be(0)))
        return box("stbl", body: body)
    }

    private static func stsd(width: Int, height: Int, sps: Data, pps: Data) -> Data {
        var body = Data()
        body.append(u32be(1))                        // entry_count
        body.append(avc1(width: width, height: height, sps: sps, pps: pps))
        return fullBox("stsd", body: body)
    }

    private static func avc1(width: Int, height: Int, sps: Data, pps: Data) -> Data {
        var body = Data()
        body.append(Data(repeating: 0, count: 6))    // reserved[6]
        body.append(u16be(1))                        // data_reference_index
        body.append(u16be(0))                        // pre_defined
        body.append(u16be(0))                        // reserved
        body.append(Data(repeating: 0, count: 12))   // pre_defined[3]
        body.append(u16be(UInt16(width)))
        body.append(u16be(UInt16(height)))
        body.append(u32be(0x0048_0000))              // horizresolution 72 dpi
        body.append(u32be(0x0048_0000))              // vertresolution 72 dpi
        body.append(u32be(0))                        // reserved
        body.append(u16be(1))                        // frame_count
        body.append(Data(repeating: 0, count: 32))   // compressorname
        body.append(u16be(0x0018))                   // depth
        body.append(i16be(-1))                       // pre_defined
        body.append(avcC(sps: sps, pps: pps))
        return box("avc1", body: body)
    }

    private static func avcC(sps: Data, pps: Data) -> Data {
        var body = Data()
        body.append(UInt8(1))                        // configurationVersion
        body.append(sps[1])                          // AVCProfileIndication
        body.append(sps[2])                          // profile_compatibility
        body.append(sps[3])                          // AVCLevelIndication
        body.append(UInt8(0xFF))                     // lengthSizeMinusOne = 3
        body.append(UInt8(0xE1))                     // numOfSPS = 1
        body.append(u16be(UInt16(sps.count)))
        body.append(sps)
        body.append(UInt8(1))                        // numOfPPS
        body.append(u16be(UInt16(pps.count)))
        body.append(pps)
        return box("avcC", body: body)
    }

    private static func mvex() -> Data {
        var body = Data()
        body.append(trex())
        return box("mvex", body: body)
    }

    private static func trex() -> Data {
        var body = Data()
        body.append(u32be(1))                        // track_ID
        body.append(u32be(1))                        // default_sample_description_index
        body.append(u32be(0))                        // default_sample_duration
        body.append(u32be(0))                        // default_sample_size
        body.append(u32be(0))                        // default_sample_flags
        return fullBox("trex", body: body)
    }

    // MARK: - Fragment (moof) — one sample per fragment

    private func moof(sequenceNumber: UInt32,
                      baseDecodeTime: UInt64,
                      sampleSize: UInt32,
                      sampleDuration: UInt32,
                      keyframe: Bool) -> Data {
        var body = Data()
        body.append(Self.fullBox("mfhd", body: Self.u32be(sequenceNumber)))
        var trafBody = Data()
        trafBody.append(Self.fullBox("tfhd", flags: 0x020000, body: Self.u32be(trackID)))
        trafBody.append(Self.fullBox("tfdt", version: 1, body: Self.u64be(baseDecodeTime)))
        trafBody.append(trun(sampleSize: sampleSize,
                             sampleDuration: sampleDuration,
                             keyframe: keyframe))
        body.append(Self.box("traf", body: trafBody))
        return Self.box("moof", body: body)
    }

    private func trun(sampleSize: UInt32,
                      sampleDuration: UInt32,
                      keyframe: Bool) -> Data {
        let flags: UInt32 = 0x000001 | 0x000004 | 0x000100 | 0x000200
        var body = Data()
        body.append(Self.u32be(1))                   // sample_count
        body.append(Self.u32be(0))                   // data_offset (patched)
        let dependsOn: UInt32 = keyframe ? 2 : 1
        let nonSync: UInt32 = keyframe ? 0 : 1
        let firstFlags: UInt32 = (dependsOn << 24) | (nonSync << 16)
        body.append(Self.u32be(firstFlags))
        body.append(Self.u32be(sampleDuration))
        body.append(Self.u32be(sampleSize))
        return Self.fullBox("trun", flags: flags, body: body)
    }

    /// Locate the single `trun` box and rewrite its `data_offset`.
    ///
    /// The box scanner is bounded and checked rather than relying on the
    /// pinned upstream's fixed byte 84, so a future box change fails instead
    /// of silently corrupting the sample pointer.
    private func patchTrunDataOffset(moof: Data, dataOffset: Int32) throws -> Data {
        let bytes = [UInt8](moof)
        guard let boxStart = Self.findBox(type: "trun", in: bytes) else {
            throw MuxerError.malformedFragmentLayout
        }
        let field = boxStart + 16                     // header 8 + fullbox 4 + sample_count 4
        guard field + 4 <= bytes.count else {
            throw MuxerError.malformedFragmentLayout
        }
        guard dataOffset > 0 else { throw MuxerError.malformedFragmentLayout }
        var out = moof
        let bigEndian = UInt32(bitPattern: dataOffset).bigEndian
        withUnsafeBytes(of: bigEndian) { raw in
            out.replaceSubrange(field..<field + 4, with: raw)
        }
        return out
    }

    private static func findBox(type: String, in bytes: [UInt8]) -> Int? {
        let tag = Array(type.utf8)
        guard tag.count == 4, bytes.count >= 8 else { return nil }
        var index = 4
        while index + 4 <= bytes.count {
            if bytes[index] == tag[0], bytes[index + 1] == tag[1],
               bytes[index + 2] == tag[2], bytes[index + 3] == tag[3] {
                let start = index - 4
                let size = Int(readU32be(bytes, at: start) ?? 0)
                if size >= 16, start + size <= bytes.count {
                    return start
                }
            }
            index += 1
        }
        return nil
    }

    private static func readU32be(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    // MARK: - Big-endian helpers

    private static func u16be(_ value: UInt16) -> Data {
        var value = value.bigEndian
        return Data(bytes: &value, count: 2)
    }

    private static func u24be(_ value: UInt32) -> Data {
        Data([UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF),
              UInt8(value & 0xFF)])
    }

    private static func u32be(_ value: UInt32) -> Data {
        var value = value.bigEndian
        return Data(bytes: &value, count: 4)
    }

    private static func u64be(_ value: UInt64) -> Data {
        var value = value.bigEndian
        return Data(bytes: &value, count: 8)
    }

    private static func i16be(_ value: Int16) -> Data {
        var value = value.bigEndian
        return Data(bytes: &value, count: 2)
    }
}

/// Declares "no frame reordering" in an H.264 SPS that does not say so.
///
/// VideoToolbox commonly emits a Baseline SPS without VUI. Without
/// `bitstream_restriction`, a decoder is allowed to assume frames may be
/// reordered across the DPB and holds several before showing the first. This
/// stream has no B-frames and the encoder sets
/// `kVTCompressionPropertyKey_AllowFrameReordering = false`, so appending a VUI
/// with `max_num_reorder_frames = 0` is true and removes that startup latency.
///
/// Returns nil (keep the original SPS) for anything not understood: an SPS
/// that already carries VUI, scaling matrices, or malformed RBSP.
enum BridgeH264LowDelaySPS {
    static func rewrite(_ nal: Data) -> Data? {
        let bytes = [UInt8](nal)
        guard bytes.count > 4, bytes[0] & 0x1F == 7 else { return nil }
        var reader = BitReader(rbsp: unescape(Array(bytes[1...])))
        guard let profile = reader.u(8),
              reader.u(8) != nil,
              reader.u(8) != nil,
              reader.ue() != nil else { return nil }
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
            .contains(profile) {
            guard let chroma = reader.ue() else { return nil }
            if chroma == 3 {
                guard reader.u(1) != nil else { return nil }
            }
            guard reader.ue() != nil,
                  reader.ue() != nil,
                  reader.u(1) != nil,
                  let scaling = reader.u(1),
                  scaling == 0 else { return nil }
        }
        guard reader.ue() != nil, let pocType = reader.ue() else { return nil }
        if pocType == 0 {
            guard reader.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard reader.u(1) != nil,
                  reader.se() != nil,
                  reader.se() != nil,
                  let count = reader.ue() else { return nil }
            for _ in 0..<count {
                guard reader.se() != nil else { return nil }
            }
        }
        guard let maxReferenceFrames = reader.ue(),
              reader.u(1) != nil,
              reader.ue() != nil,
              reader.ue() != nil,
              let frameMbsOnly = reader.u(1) else { return nil }
        if frameMbsOnly == 0 {
            guard reader.u(1) != nil else { return nil }
        }
        guard reader.u(1) != nil, let crop = reader.u(1) else { return nil }
        if crop == 1 {
            for _ in 0..<4 {
                guard reader.ue() != nil else { return nil }
            }
        }
        let vuiFlagPosition = reader.pos
        guard let vui = reader.u(1), vui == 0 else { return nil }

        var writer = BitWriter()
        var copy = BitReader(rbsp: reader.data)
        for _ in 0..<vuiFlagPosition {
            writer.put(copy.u(1)!, 1)
        }
        writer.put(1, 1)                             // vui_parameters_present_flag
        for _ in 0..<5 { writer.put(0, 1) }          // aspect/overscan/video/chroma/timing
        for _ in 0..<3 { writer.put(0, 1) }          // nal_hrd/vcl_hrd/pic_struct
        writer.put(1, 1)                             // bitstream_restriction_flag
        writer.put(1, 1)                             // motion_vectors_over_pic_boundaries_flag
        writer.ue(2)                                 // max_bytes_per_pic_denom
        writer.ue(1)                                 // max_bits_per_mb_denom
        writer.ue(15)                                // log2_max_mv_length_horizontal
        writer.ue(15)                                // log2_max_mv_length_vertical
        writer.ue(0)                                 // max_num_reorder_frames
        writer.ue(max(1, maxReferenceFrames))        // max_dec_frame_buffering
        writer.put(1, 1)                             // rbsp_stop_one_bit
        writer.align()
        return Data([bytes[0]] + escape(writer.bytes))
    }

    /// Drop emulation-prevention bytes (00 00 03 -> 00 00).
    private static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var zeros = 0
        for value in bytes {
            if zeros >= 2 && value == 3 {
                zeros = 0
                continue
            }
            out.append(value)
            zeros = value == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Insert emulation-prevention bytes before 00 00 0x (x <= 3).
    private static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        var zeros = 0
        for value in bytes {
            if zeros >= 2 && value <= 3 {
                out.append(3)
                zeros = 0
            }
            out.append(value)
            zeros = value == 0 ? zeros + 1 : 0
        }
        return out
    }

    private struct BitReader {
        let data: [UInt8]
        var pos = 0

        init(rbsp: [UInt8]) {
            data = rbsp
        }

        mutating func u(_ count: Int) -> Int? {
            guard count >= 0, pos + count <= data.count * 8 else { return nil }
            var value = 0
            for _ in 0..<count {
                value = value << 1 | Int(data[pos >> 3] >> (7 - UInt8(pos & 7)) & 1)
                pos += 1
            }
            return value
        }

        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let bit = u(1) else { return nil }
                if bit == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = zeros > 0 ? u(zeros) : 0 else { return nil }
            return (1 << zeros) - 1 + rest
        }

        mutating func se() -> Int? {
            guard let value = ue() else { return nil }
            return value & 1 == 1 ? (value + 1) / 2 : -(value / 2)
        }
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var bit = 0

        mutating func put(_ value: Int, _ count: Int) {
            for index in stride(from: count - 1, through: 0, by: -1) {
                if bit == 0 { bytes.append(0) }
                if (value >> index) & 1 == 1 {
                    bytes[bytes.count - 1] |= UInt8(0x80 >> bit)
                }
                bit = (bit + 1) & 7
            }
        }

        mutating func ue(_ value: Int) {
            let code = value + 1
            let length = Int.bitWidth - code.leadingZeroBitCount
            put(0, length - 1)
            put(code, length)
        }

        mutating func align() {
            while bit != 0 { put(0, 1) }
        }
    }
}
