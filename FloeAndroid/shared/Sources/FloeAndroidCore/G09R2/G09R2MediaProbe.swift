// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — bounded media probing for generated/candidate bytes.
//
// The workbench must not trust a provider-declared MIME type, a file
// extension or a caller-supplied size. This file sniffs actual image
// signatures (PNG/JPEG) and reads ISO-BMFF (MP4/MOV) container metadata with
// bounded seeks/reads. It performs no network, starts no task and never
// decodes media with a platform codec.
import Foundation
import FloeCore
import FloeAndroidWorkbench

public enum G09R2MediaProbe {
    /// Generated image policy cap (per image). The 12 MiB source/edit cap is a
    /// different policy; provider outputs are bounded here so a hostile or
    /// broken response can never materialise an unbounded file.
    public static let maximumGeneratedImageBytes: Int64 = 32 * 1024 * 1024
    /// Total generated image batch cap (max 4 outputs).
    public static let maximumGeneratedImageBatchBytes: Int64 = 96 * 1024 * 1024
    /// Generated video policy cap; the same 8 GiB large-import policy ceiling.
    public static let maximumGeneratedVideoBytes: Int64 =
        G09R2CreativeLimits.importVideoBytes
    /// Maximum bytes of a `moov` box inspected for duration/dimension.
    public static let maximumMovieHeaderBytes: Int64 = 32 * 1024 * 1024
    /// Bounded top-level box walk; a malformed file cannot pin the reader.
    public static let maximumTopLevelBoxes = 256
    public static let maximumSuberBoxes = 64

    private static let pngSignature: [UInt8] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ]

    // MARK: - Images

    public struct ImageFacts: Sendable, Equatable {
        public var mimeType: String
        public var width: Int
        public var height: Int
        public var hasAlpha: Bool?

        public init(mimeType: String, width: Int, height: Int, hasAlpha: Bool?) {
            self.mimeType = mimeType
            self.width = width
            self.height = height
            self.hasAlpha = hasAlpha
        }
    }

    /// Actual signature/dimension facts. Returns nil for any format the
    /// workbench cannot verify (HEIC/SVG/WebP are not silently relabelled).
    public static func imageFacts(_ data: Data) -> ImageFacts? {
        let bytes = [UInt8](data.prefix(1_048_576))
        if bytes.count >= 26, Array(bytes.prefix(8)) == pngSignature {
            let width = bigEndianInt(bytes, at: 16)
            let height = bigEndianInt(bytes, at: 20)
            guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
                return nil
            }
            let colorType = bytes[25]
            return ImageFacts(
                mimeType: "image/png", width: width, height: height,
                hasAlpha: colorType == 4 || colorType == 6)
        }
        if bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 {
            return jpegFacts(bytes)
        }
        return nil
    }

    private static func jpegFacts(_ bytes: [UInt8]) -> ImageFacts? {
        var index = 2
        let limit = min(bytes.count, 1_048_576)
        while index + 3 < limit {
            guard bytes[index] == 0xFF else { return nil }
            var marker = bytes[index + 1]
            while marker == 0xFF, index + 2 < limit {
                index += 1
                marker = bytes[index + 1]
            }
            index += 2
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                continue
            }
            guard index + 1 < limit else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard length >= 2, index + length <= limit else { return nil }
            if (0xC0...0xCF).contains(marker),
               marker != 0xC4, marker != 0xC8, marker != 0xCC {
                guard length >= 7 else { return nil }
                let height = Int(bytes[index + 3]) << 8 | Int(bytes[index + 4])
                let width = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                guard width > 0, height > 0, width <= 16_384, height <= 16_384 else {
                    return nil
                }
                return ImageFacts(
                    mimeType: "image/jpeg", width: width, height: height,
                    hasAlpha: false)
            }
            index += length
        }
        return nil
    }

    // MARK: - Video

    public struct VideoFacts: Sendable, Equatable {
        public var mimeType: String
        public var durationSeconds: Double
        public var width: Int?
        public var height: Int?
        public var rotationDegrees: Double?

        public init(mimeType: String, durationSeconds: Double, width: Int?,
                    height: Int?, rotationDegrees: Double?) {
            self.mimeType = mimeType
            self.durationSeconds = durationSeconds
            self.width = width
            self.height = height
            self.rotationDegrees = rotationDegrees
        }

        public var metadata: MediaAssetMetadata {
            MediaAssetMetadata(
                width: width, height: height,
                durationSeconds: durationSeconds,
                rotationDegrees: rotationDegrees)
        }
    }

    /// Sniffs the container family from the first bytes. Only the formats the
    /// native accept path can actually describe are accepted.
    public static func videoMIMEType(prefix: Data) -> String? {
        let bytes = [UInt8](prefix.prefix(64))
        guard bytes.count >= 12 else { return nil }
        if bytes.count >= 12,
           Array(bytes[4...7]) == Array("ftyp".utf8) {
            let brand = String(bytes: bytes[8...11], encoding: .ascii) ?? ""
            if brand == "qt  " { return "video/quicktime" }
            return "video/mp4"
        }
        if Array(bytes[0...3]) == [0x1A, 0x45, 0xDF, 0xA3] {
            return "video/webm"
        }
        return nil
    }

    /// Reads bounded ISO-BMFF metadata. WebM is recognized but has no
    /// in-package duration parser; accept then refuses truthfully instead of
    /// inventing a trim end.
    public static func videoFacts(fileURL: URL) -> VideoFacts? {
        guard let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, Int64(size) <= maximumGeneratedVideoBytes else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 64), !prefix.isEmpty,
              let mime = videoMIMEType(prefix: prefix) else { return nil }
        guard mime == "video/mp4" || mime == "video/quicktime" else { return nil }
        var found = FoundMovie()
        do {
            try walkTopLevel(handle: handle, fileSize: Int64(size), found: &found)
        } catch {
            return nil
        }
        guard let duration = found.durationSeconds,
              duration.isFinite, duration > 0, duration <= 86_400 else {
            return nil
        }
        return VideoFacts(
            mimeType: mime, durationSeconds: duration,
            width: found.width, height: found.height,
            rotationDegrees: found.rotation)
    }

    private struct FoundMovie {
        var durationSeconds: Double?
        var width: Int?
        var height: Int?
        var rotation: Double?
    }

    private struct BoxHeader {
        var type: String
        var payloadOffset: Int64
        var payloadLength: Int64
        var totalLength: Int64
    }

    private static func readHeader(
        handle: FileHandle, at offset: Int64, fileSize: Int64
    ) throws -> BoxHeader? {
        guard offset >= 0, offset + 8 <= fileSize else { return nil }
        try handle.seek(toOffset: UInt64(offset))
        guard let head = try handle.read(upToCount: 8), head.count == 8 else {
            return nil
        }
        let bytes = [UInt8](head)
        var size = Int64(bigEndianUInt32(bytes, at: 0))
        let type = String(bytes: bytes[4...7], encoding: .ascii) ?? ""
        var headerSize: Int64 = 8
        if size == 1 {
            guard let extra = try handle.read(upToCount: 8), extra.count == 8 else {
                return nil
            }
            size = Int64(bitPattern: bigEndianUInt64([UInt8](extra), at: 0))
            headerSize = 16
        } else if size == 0 {
            size = fileSize - offset
        }
        guard size >= headerSize, offset + size <= fileSize else { return nil }
        return BoxHeader(
            type: type, payloadOffset: offset + headerSize,
            payloadLength: size - headerSize, totalLength: size)
    }

    private static func walkTopLevel(
        handle: FileHandle, fileSize: Int64, found: inout FoundMovie
    ) throws {
        var offset: Int64 = 0
        var boxes = 0
        while offset + 8 <= fileSize, boxes < maximumTopLevelBoxes {
            boxes += 1
            guard let header = try readHeader(
                handle: handle, at: offset, fileSize: fileSize) else {
                return
            }
            if header.type == "moov" {
                let length = min(header.payloadLength, maximumMovieHeaderBytes)
                guard length >= 8, let data = try read(
                    handle: handle, at: header.payloadOffset, count: length) else {
                    return
                }
                parseMovie(data, found: &found)
                if found.durationSeconds != nil, found.width != nil {
                    return
                }
            }
            offset += header.totalLength
        }
    }

    private static func parseMovie(_ data: Data, found: inout FoundMovie) {
        let bytes = [UInt8](data)
        var offset = 0
        var boxes = 0
        while offset + 8 <= bytes.count, boxes < maximumSuberBoxes {
            boxes += 1
            guard let size = boxSize(bytes, at: offset, limit: bytes.count) else {
                return
            }
            let type = String(
                bytes: bytes[(offset + 4)...(offset + 7)], encoding: .ascii) ?? ""
            let payload = offset + 8
            let payloadEnd = offset + size
            switch type {
            case "mvhd":
                if let duration = parseMovieHeader(
                    bytes, start: payload, end: payloadEnd) {
                    found.durationSeconds = duration
                }
            case "trak", "mdia":
                // Both containers may hold the track header at a different
                // nesting depth; scan their children.
                parseMovie(Data(bytes[payload..<payloadEnd]), found: &found)
            case "tkhd":
                parseTrackHeader(bytes, start: payload, end: payloadEnd, found: &found)
            default:
                break
            }
            offset += size
        }
    }

    private static func parseMovieHeader(
        _ bytes: [UInt8], start: Int, end: Int
    ) -> Double? {
        guard start + 4 <= end else { return nil }
        let version = bytes[start]
        var timescale: UInt32
        var duration: UInt64
        if version == 1 {
            guard start + 32 <= end else { return nil }
            timescale = bigEndianUInt32(bytes, at: start + 20)
            duration = bigEndianUInt64(bytes, at: start + 24)
        } else {
            guard start + 20 <= end else { return nil }
            timescale = bigEndianUInt32(bytes, at: start + 12)
            duration = UInt64(bigEndianUInt32(bytes, at: start + 16))
        }
        guard timescale > 0, duration > 0 else { return nil }
        return Double(duration) / Double(timescale)
    }

    private static func parseTrackHeader(
        _ bytes: [UInt8], start: Int, end: Int, found: inout FoundMovie
    ) {
        guard end - start >= 52 else { return }
        let width = bigEndianUInt32(bytes, at: end - 8)
        let height = bigEndianUInt32(bytes, at: end - 4)
        let pixelWidth = Int(Double(width) / 65_536.0)
        let pixelHeight = Int(Double(height) / 65_536.0)
        if pixelWidth > 0, pixelHeight > 0 {
            if found.width == nil { found.width = pixelWidth }
            if found.height == nil { found.height = pixelHeight }
        }
        // The transformation matrix is the 36 bytes immediately before the
        // 16.16 width/height pair. Derive only exact quarter turns.
        if end - start >= 44 {
            let matrix = end - 44
            let a = Double(Int32(bitPattern: bigEndianUInt32(bytes, at: matrix)))
            let b = Double(Int32(bitPattern: bigEndianUInt32(bytes, at: matrix + 4)))
            if a != 0 || b != 0 {
                let radians = atan2(b, a)
                let degrees = radians * 180.0 / Double.pi
                let normalized = (degrees.truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                let allowed: [Double] = [0, 90, 180, 270]
                if let nearest = allowed.min(by: {
                    abs($0 - normalized) < abs($1 - normalized)
                }), abs(nearest - normalized) < 1 {
                    found.rotation = nearest
                }
            }
        }
    }

    private static func boxSize(_ bytes: [UInt8], at offset: Int, limit: Int) -> Int? {
        guard offset + 8 <= limit else { return nil }
        var size = Int(bigEndianUInt32(bytes, at: offset))
        if size == 1 {
            guard offset + 16 <= limit else { return nil }
            let large = bigEndianUInt64(bytes, at: offset + 8)
            guard large > 0, large <= UInt64(Int.max) else { return nil }
            size = Int(large)
        } else if size == 0 {
            size = limit - offset
        }
        guard size >= 8, offset + size <= limit else { return nil }
        return size
    }

    private static func read(
        handle: FileHandle, at offset: Int64, count: Int64
    ) throws -> Data? {
        guard count > 0, count <= Int.max else { return nil }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: Int(count)),
              Int64(data.count) == count else { return nil }
        return data
    }

    // MARK: - Byte helpers

    private static func bigEndianInt(_ bytes: [UInt8], at offset: Int) -> Int {
        guard offset + 4 <= bytes.count else { return 0 }
        return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private static func bigEndianUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func bigEndianUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value = value << 8 | UInt64(bytes[offset + index])
        }
        return value
    }

    /// Extension/mime for a verified image. Used for display names only; the
    /// actual bytes were already verified.
    public static func imageExtension(mimeType: String) -> String {
        mimeType == "image/png" ? "png" : "jpg"
    }

    public static func videoExtension(mimeType: String) -> String {
        switch mimeType {
        case "video/quicktime": "mov"
        case "video/webm": "webm"
        default: "mp4"
        }
    }
}
