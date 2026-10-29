// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes cloud OCR — bounded image validation.
//
// The native side accepts exactly one complete PNG per stage. It verifies the
// declared byte count, SHA-256, PNG signature and IHDR dimensions BEFORE any
// provider request. No caller-provided path, media type or operation is
// trusted.
import Foundation
import Crypto

enum NotesOCRImage {
    struct Dimensions: Sendable, Equatable {
        let width: Int
        let height: Int
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isHexDigest(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
                || (byte >= 65 && byte <= 70)
        }
    }

    /// Strict canonical base64 (no whitespace or ignored characters).
    static func decodeBase64(_ value: String) -> Data? {
        guard !value.isEmpty, value.utf8.count <= 88_000,
              let data = Data(base64Encoded: value),
              data.base64EncodedString() == value else { return nil }
        return data
    }

    /// PNG signature + IHDR. The provider still decodes the image; this check
    /// only proves the declared format/dimensions are truthful enough to send.
    static func pngDimensions(_ data: Data) -> Dimensions? {
        guard data.count >= 33 else { return nil }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard Array(data.prefix(8)) == signature else { return nil }
        guard bigEndian32(data, at: 8) == 13 else { return nil }
        guard Array(data[12..<16]) == Array("IHDR".utf8) else { return nil }
        let width = bigEndian32(data, at: 16)
        let height = bigEndian32(data, at: 20)
        guard width > 0, height > 0,
              width <= UInt32(NotesOCRPolicy.maximumDimension),
              height <= UInt32(NotesOCRPolicy.maximumDimension),
              Int(width) * Int(height) <= NotesOCRPolicy.maximumPixelCount else {
            return nil
        }
        let bitDepth = data[24]
        let colorType = data[25]
        let compression = data[26]
        let filter = data[27]
        let interlace = data[28]
        guard [1, 2, 4, 8, 16].contains(bitDepth),
              [0, 2, 3, 4, 6].contains(colorType),
              compression == 0, filter == 0, interlace <= 1 else { return nil }
        return Dimensions(width: Int(width), height: Int(height))
    }

    private static func bigEndian32(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }
}
