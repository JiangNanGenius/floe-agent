// SPDX-License-Identifier: MPL-2.0
//
// OpenRaster 0.0.3 baseline model. Layers are stored bottom-to-top (the same
// direction as PSD/ag-psd); the ORA stack.xml writer reverses them because the
// OpenRaster stack's first element is the uppermost layer.

import Foundation

public struct ORALayer: Sendable, Equatable {
    public var name: String
    /// Original PNG bytes, preserved verbatim through read/write.
    public var pngData: Data
    /// Signed offset in document pixels. Out-of-canvas content is allowed.
    public var x: Int
    public var y: Int
    /// 0...1
    public var opacity: Double
    public var visible: Bool
    /// SVG composite operation, default svg:src-over.
    public var compositeOp: String
    /// Non-standard extension from the 2023 alpha-preserve proposal. Parsed
    /// and preserved, but the qualification compositor rejects it.
    public var alphaPreserve: Bool

    public init(
        name: String,
        pngData: Data,
        x: Int = 0,
        y: Int = 0,
        opacity: Double = 1,
        visible: Bool = true,
        compositeOp: String = "svg:src-over",
        alphaPreserve: Bool = false
    ) {
        self.name = name
        self.pngData = pngData
        self.x = x
        self.y = y
        self.opacity = opacity
        self.visible = visible
        self.compositeOp = compositeOp
        self.alphaPreserve = alphaPreserve
    }

    public var pngWidth: Int { (try? PNGHeader.parse(pngData))?.width ?? 0 }
    public var pngHeight: Int { (try? PNGHeader.parse(pngData))?.height ?? 0 }
}

public struct ORADocument: Sendable {
    public var width: Int
    public var height: Int
    public var rootName: String?
    public var xres: Int?
    public var yres: Int?
    /// Bottom-to-top.
    public var layers: [ORALayer]
    /// Mandatory baseline viewing image. Read from/written to mergedimage.png.
    public var mergedPNG: Data?
    /// Mandatory baseline thumbnail. Read from/written to Thumbnails/thumbnail.png.
    public var thumbnailPNG: Data?
    /// Non-fatal reader observations (for example unreferenced entries).
    public var warnings: [String]

    public init(
        width: Int,
        height: Int,
        rootName: String? = nil,
        xres: Int? = nil,
        yres: Int? = nil,
        layers: [ORALayer],
        mergedPNG: Data? = nil,
        thumbnailPNG: Data? = nil,
        warnings: [String] = []
    ) {
        self.width = width
        self.height = height
        self.rootName = rootName
        self.xres = xres
        self.yres = yres
        self.layers = layers
        self.mergedPNG = mergedPNG
        self.thumbnailPNG = thumbnailPNG
        self.warnings = warnings
    }
}

public struct ORALimits: Sendable {
    public var maxArchiveBytes: Int
    public var maxEntries: Int
    public var maxTotalUncompressedBytes: Int
    public var maxStackXMLBytes: Int
    public var maxLayerBytes: Int
    public var maxDimension: Int
    public var maxLayers: Int
    public var maxThumbnailDimension: Int

    public init(
        maxArchiveBytes: Int = 512 * 1024 * 1024,
        maxEntries: Int = 512,
        maxTotalUncompressedBytes: Int = 512 * 1024 * 1024,
        maxStackXMLBytes: Int = 4 * 1024 * 1024,
        maxLayerBytes: Int = 128 * 1024 * 1024,
        maxDimension: Int = ImageLimits.maxDimension,
        maxLayers: Int = 256,
        maxThumbnailDimension: Int = 256
    ) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxEntries = maxEntries
        self.maxTotalUncompressedBytes = maxTotalUncompressedBytes
        self.maxStackXMLBytes = maxStackXMLBytes
        self.maxLayerBytes = maxLayerBytes
        self.maxDimension = maxDimension
        self.maxLayers = maxLayers
        self.maxThumbnailDimension = maxThumbnailDimension
    }

    public static let `default` = ORALimits()
}

public enum ORAError: Error, Equatable, CustomStringConvertible {
    case archiveTooLarge(actual: Int, limit: Int)
    case tooManyEntries(actual: Int, limit: Int)
    case invalidArchive(String)
    case missingEntry(String)
    case duplicateEntry(String)
    case unsafePath(String)
    case entryTooLarge(path: String, actual: UInt64, limit: Int)
    case totalTooLarge(actual: UInt64, limit: Int)
    case invalidXML(String)
    case unsupportedFeature(String)
    case invalidAttribute(element: String, name: String, value: String)
    case missingAttribute(element: String, name: String)
    case invalidLayerCount(Int)
    case invalidDimensions(width: Int, height: Int)
    case invalidPNG(path: String, reason: String)
    case destinationExists(URL)
    case writeFailed(String)
    case unsupportedComposite(op: String)
    case unsupportedAlphaPreserve(layer: String)
    case mergedImageMismatch(expected: String, actual: String)
    case thumbnailTooLarge(width: Int, height: Int, limit: Int)

    public var description: String {
        switch self {
        case let .archiveTooLarge(actual, limit): return "ORA archive is \(actual) bytes, limit is \(limit)"
        case let .tooManyEntries(actual, limit): return "ORA archive has \(actual) entries, limit is \(limit)"
        case let .invalidArchive(reason): return "invalid ORA archive: \(reason)"
        case let .missingEntry(path): return "ORA archive is missing \(path)"
        case let .duplicateEntry(path): return "ORA archive contains duplicate path \(path)"
        case let .unsafePath(path): return "unsafe ORA path \(path)"
        case let .entryTooLarge(path, actual, limit): return "ORA entry \(path) is \(actual) bytes, limit is \(limit)"
        case let .totalTooLarge(actual, limit): return "ORA uncompressed total \(actual) exceeds \(limit)"
        case let .invalidXML(reason): return "invalid ORA stack.xml: \(reason)"
        case let .unsupportedFeature(reason): return "unsupported ORA feature: \(reason)"
        case let .invalidAttribute(element, name, value): return "invalid \(element).\(name) value \(value)"
        case let .missingAttribute(element, name): return "missing \(element).\(name)"
        case let .invalidLayerCount(count): return "invalid ORA layer count \(count)"
        case let .invalidDimensions(width, height): return "invalid ORA dimensions \(width)x\(height)"
        case let .invalidPNG(path, reason): return "invalid PNG \(path): \(reason)"
        case let .destinationExists(url): return "destination already exists: \(url.path)"
        case let .writeFailed(reason): return "could not write ORA file: \(reason)"
        case let .unsupportedComposite(op): return "unsupported ORA composite-op \(op)"
        case let .unsupportedAlphaPreserve(layer): return "alpha-preserve is not supported for \(layer)"
        case let .mergedImageMismatch(expected, actual):
            return "mergedimage.png is \(actual), expected \(expected)"
        case let .thumbnailTooLarge(width, height, limit):
            return "thumbnail is \(width)x\(height), limit is \(limit)"
        }
    }
}

public enum ORACompositor {
    /// Flattens the supported baseline subset: visible svg:src-over layers,
    /// no alpha-preserve, no masks. Other composites are rejected rather than
    /// silently approximated.
    public static func flatten(_ document: ORADocument, limits: ORALimits = .default) throws -> RGBAImage {
        guard document.width > 0, document.height > 0,
              document.width <= limits.maxDimension, document.height <= limits.maxDimension else {
            throw ORAError.invalidDimensions(width: document.width, height: document.height)
        }
        var result = try RGBAImage(width: document.width, height: document.height, fill: 0)
        for layer in document.layers {
            guard layer.visible else { continue }
            guard !layer.alphaPreserve else {
                throw ORAError.unsupportedAlphaPreserve(layer: layer.name)
            }
            guard layer.compositeOp == "svg:src-over" else {
                throw ORAError.unsupportedComposite(op: layer.compositeOp)
            }
            let source = try PNGCodec.decode(layer.pngData)
            guard result.width == document.width, result.height == document.height else {
                throw ORAError.invalidDimensions(width: result.width, height: result.height)
            }
            blendSourceOver(
                into: &result,
                source: source,
                offsetX: layer.x,
                offsetY: layer.y,
                opacity: layer.opacity
            )
        }
        return result
    }

    public static func blendSourceOver(
        into destination: inout RGBAImage,
        source: RGBAImage,
        offsetX: Int,
        offsetY: Int,
        opacity: Double
    ) {
        let clampedOpacity = max(0, min(1, opacity))
        guard clampedOpacity > 0 else { return }
        let x0 = max(0, offsetX)
        let y0 = max(0, offsetY)
        let x1 = min(destination.width, offsetX + source.width)
        let y1 = min(destination.height, offsetY + source.height)
        guard x1 > x0, y1 > y0 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let sx = x - offsetX
                let sy = y - offsetY
                let si = source.offset(x: sx, y: sy)
                let di = destination.offset(x: x, y: y)
                let sa = Double(source.pixels[si + 3]) / 255 * clampedOpacity
                guard sa > 0 else { continue }
                let da = Double(destination.pixels[di + 3]) / 255
                let oa = sa + da * (1 - sa)
                if oa <= 0 { continue }
                destination.pixels[di] = UInt8(clamping: Int(((Double(source.pixels[si]) * sa + Double(destination.pixels[di]) * da * (1 - sa)) / oa).rounded()))
                destination.pixels[di + 1] = UInt8(clamping: Int(((Double(source.pixels[si + 1]) * sa + Double(destination.pixels[di + 1]) * da * (1 - sa)) / oa).rounded()))
                destination.pixels[di + 2] = UInt8(clamping: Int(((Double(source.pixels[si + 2]) * sa + Double(destination.pixels[di + 2]) * da * (1 - sa)) / oa).rounded()))
                destination.pixels[di + 3] = UInt8(clamping: Int((oa * 255).rounded()))
            }
        }
    }
}

enum ORAXML {
    static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
