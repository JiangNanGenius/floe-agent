// SPDX-License-Identifier: MPL-2.0
//
// Header-only PSD/PSB inspection. This runs before any JavaScriptCore decode
// so unsupported color modes, depths, PSB files and oversized documents are
// rejected explicitly and the original bytes can be retained by the caller.

import Foundation

public struct PSDHeader: Equatable, Sendable {
    public enum Version: UInt16, Sendable {
        case psd = 1
        case psb = 2
    }

    public let version: Version
    public let channels: Int
    public let height: Int
    public let width: Int
    public let bitsPerChannel: Int
    public let colorMode: Int

    public static let fileSignature: [UInt8] = Array("8BPS".utf8)

    public static func parse(_ data: Data) throws -> PSDHeader {
        guard data.count >= 26 else {
            throw PSDHeaderError.truncatedHeader(bytes: data.count)
        }
        let bytes = [UInt8](data.prefix(26))
        guard Array(bytes[0..<4]) == fileSignature else {
            throw PSDHeaderError.badSignature
        }
        let versionValue = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        guard let version = Version(rawValue: versionValue) else {
            throw PSDHeaderError.unsupportedVersion(versionValue)
        }
        guard bytes[6..<12].allSatisfy({ $0 == 0 }) else {
            throw PSDHeaderError.nonZeroReservedBytes
        }
        let channels = Int(UInt16(bytes[12]) << 8 | UInt16(bytes[13]))
        let height = Int(UInt32(bytes[14]) << 24 | UInt32(bytes[15]) << 16 | UInt32(bytes[16]) << 8 | UInt32(bytes[17]))
        let width = Int(UInt32(bytes[18]) << 24 | UInt32(bytes[19]) << 16 | UInt32(bytes[20]) << 8 | UInt32(bytes[21]))
        let bits = Int(UInt16(bytes[22]) << 8 | UInt16(bytes[23]))
        let colorMode = Int(UInt16(bytes[24]) << 8 | UInt16(bytes[25]))
        guard channels >= 1, channels <= 56 else {
            throw PSDHeaderError.invalidChannelCount(channels)
        }
        guard width > 0, height > 0 else {
            throw PSDHeaderError.invalidDimensions(width: width, height: height)
        }
        return PSDHeader(
            version: version,
            channels: channels,
            height: height,
            width: width,
            bitsPerChannel: bits,
            colorMode: colorMode
        )
    }

    public var colorModeName: String {
        switch colorMode {
        case 0: return "bitmap"
        case 1: return "grayscale"
        case 2: return "indexed"
        case 3: return "RGB"
        case 4: return "CMYK"
        case 7: return "multichannel"
        case 8: return "duotone"
        case 9: return "Lab"
        default: return "unknown(\(colorMode))"
        }
    }
}

public enum PSDHeaderError: Error, Equatable, CustomStringConvertible {
    case truncatedHeader(bytes: Int)
    case badSignature
    case unsupportedVersion(UInt16)
    case nonZeroReservedBytes
    case invalidChannelCount(Int)
    case invalidDimensions(width: Int, height: Int)
    case unsupportedColorMode(Int)
    case unsupportedBitDepth(Int)
    case unsupportedPSB
    case dimensionsExceedLimit(width: Int, height: Int, limit: Int)
    case pixelCountExceedLimit(width: Int, height: Int, limit: Int)

    public var description: String {
        switch self {
        case let .truncatedHeader(bytes): return "PSD header is truncated (\(bytes) bytes)"
        case .badSignature: return "PSD signature is not 8BPS"
        case let .unsupportedVersion(version): return "unsupported PSD version \(version)"
        case .nonZeroReservedBytes: return "PSD reserved header bytes are not zero"
        case let .invalidChannelCount(count): return "invalid PSD channel count \(count)"
        case let .invalidDimensions(width, height): return "invalid PSD dimensions \(width)x\(height)"
        case let .unsupportedColorMode(mode): return "unsupported PSD color mode \(mode)"
        case let .unsupportedBitDepth(depth): return "unsupported PSD bit depth \(depth)"
        case .unsupportedPSB: return "PSB large-document files are not supported by this baseline"
        case let .dimensionsExceedLimit(width, height, limit):
            return "PSD dimensions \(width)x\(height) exceed limit \(limit)"
        case let .pixelCountExceedLimit(width, height, limit):
            return "PSD pixel count \(width)x\(height) exceeds limit \(limit)"
        }
    }
}

public struct PSDCompatibility: Equatable, Sendable {
    public enum Status: String, Sendable {
        /// 8-bit RGB PSD that the qualification codec can read and write.
        case supported
        /// Original bytes must be preserved; no layer round-trip is claimed.
        case preservedOnly
    }

    public let status: Status
    public let reasons: [String]
    public let header: PSDHeader

    public var isLayerEditable: Bool { status == .supported }
}

public enum PSDCompatibilityEvaluator {
    /// Baseline: single 8-bit RGB PSD. PSB, CMYK, grayscale, indexed,
    /// 16/32-bit and oversized documents are preserved-only.
    public static func evaluate(
        _ header: PSDHeader,
        maxDimension: Int = ImageLimits.maxDimension,
        maxPixels: Int = ImageLimits.maxPixels
    ) -> PSDCompatibility {
        var reasons: [String] = []
        if header.version == .psb {
            reasons.append("PSB large-document format is not supported")
        }
        if header.colorMode != 3 {
            reasons.append("color mode \(header.colorModeName) is not supported (RGB only)")
        }
        if header.bitsPerChannel != 8 {
            reasons.append("bit depth \(header.bitsPerChannel) is not supported (8-bit only)")
        }
        if header.width > maxDimension || header.height > maxDimension {
            reasons.append("dimensions \(header.width)x\(header.height) exceed \(maxDimension)")
        }
        let (pixels, overflow) = header.width.multipliedReportingOverflow(by: header.height)
        if overflow || pixels > maxPixels {
            reasons.append("pixel count \(overflow ? "overflow" : String(pixels)) exceeds \(maxPixels)")
        }
        return PSDCompatibility(
            status: reasons.isEmpty ? .supported : .preservedOnly,
            reasons: reasons,
            header: header
        )
    }
}
