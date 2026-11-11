// SPDX-License-Identifier: MPL-2.0
//
// JavaScriptCore host for the pinned, trusted ag-psd bundle. The codec script
// is shipped inside the package and is never model-authored. The adapter uses
// ag-psd's raw ImageData read path and imageData write path; its fake canvas
// factory throws if the codec ever asks for a DOM canvas.

import Foundation
import JavaScriptCore

public struct PSDReadLimits: Sendable {
    public var maxFileBytes: Int
    public var totalMemoryLimit: Int
    public var maxDimension: Int
    public var maxPixels: Int

    public init(
        maxFileBytes: Int = 512 * 1024 * 1024,
        totalMemoryLimit: Int = 256 * 1024 * 1024,
        maxDimension: Int = ImageLimits.maxDimension,
        maxPixels: Int = ImageLimits.maxPixels
    ) {
        self.maxFileBytes = maxFileBytes
        self.totalMemoryLimit = totalMemoryLimit
        self.maxDimension = maxDimension
        self.maxPixels = maxPixels
    }
}

public struct PSDMaskInfo: Sendable, Equatable {
    public let top: Int
    public let left: Int
    public let width: Int
    public let height: Int
    public let disabled: Bool
    public let imageData: RGBAImage?
    public var defaultColor: UInt8 = 0
}

/// Qualified single-style point text. Rich runs, warps and paragraph boxes
/// remain preserved-only until their native editing contracts are available.
public struct PSDText: Codable, Sendable, Equatable {
    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var colorHex: String
    public var alignment: String
    public init(text: String, fontName: String, fontSize: Double, colorHex: String, alignment: String = "left") {
        self.text = text; self.fontName = fontName; self.fontSize = fontSize
        self.colorHex = colorHex; self.alignment = alignment
    }
}

public struct PSDLayerInfo: Sendable, Equatable {
    public let name: String
    public let top: Int
    public let left: Int
    public let width: Int
    public let height: Int
    public let opacity: Int
    public let hidden: Bool
    public let clipping: Bool
    public let transparencyProtected: Bool
    public let blendMode: String
    public let group: Bool
    public let childCount: Int
    public let hasText: Bool
    public let hasPlacedLayer: Bool
    public let hasAdjustment: Bool
    public let hasEffects: Bool
    public let hasVectorMask: Bool
    public let depth: Int
    public let mask: PSDMaskInfo?
    public var text: PSDText? = nil
}

public struct PSDLayerPixels: Sendable {
    public let info: PSDLayerInfo
    public let imageData: RGBAImage?
    public let maskImageData: RGBAImage?
}

public struct PSDReadResult: Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public let bitsPerChannel: Int
    public let colorMode: Int
    public let layers: [PSDLayerPixels]
    public let composite: RGBAImage?
    public let warnings: [String]
    public let canvasFactoryCalls: Int
    public let imageDataFactoryCalls: Int
}

public enum PSDImportResult: Sendable {
    /// Supported 8-bit RGB PSD decoded into editable layers.
    case editable(PSDReadResult)
    /// Unsupported input. The exact original bytes are returned to the caller
    /// so they can be stored/downloaded unchanged; no flattening occurs.
    case preserved(original: Data, compatibility: PSDCompatibility)
}

public struct PSDWriteLayer: Sendable {
    public var name: String
    public var top: Int
    public var left: Int
    public var imageData: RGBAImage
    public var opacity: Int
    public var hidden: Bool
    public var clipping: Bool
    public var transparencyProtected: Bool
    public var blendMode: String
    public var mask: PSDMaskInfo?
    public var group: Bool
    public var depth: Int
    public var text: PSDText?

    public init(
        name: String,
        top: Int,
        left: Int,
        imageData: RGBAImage,
        opacity: Int = 255,
        hidden: Bool = false,
        clipping: Bool = false,
        transparencyProtected: Bool = false,
        blendMode: String = "normal",
        mask: PSDMaskInfo? = nil, group: Bool = false, depth: Int = 0, text: PSDText? = nil
    ) {
        self.name = name
        self.top = top
        self.left = left
        self.imageData = imageData
        self.opacity = opacity
        self.hidden = hidden
        self.clipping = clipping
        self.transparencyProtected = transparencyProtected
        self.blendMode = blendMode
        self.mask = mask; self.group = group; self.depth = depth; self.text = text
    }
}

public enum PSDCodecError: Error, CustomStringConvertible {
    case resourceMissing(String)
    case javascript(String)
    case invalidResponse(String)
    case unsupported([String])
    case fileTooLarge(actual: Int, limit: Int)
    case layerCountExceeded(actual: Int, limit: Int)
    case invalidLayerDimensions(layer: String, width: Int, height: Int)
    case invalidCompositeDimensions(expected: String, actual: String)
    case base64DecodeFailed

    public var description: String {
        switch self {
        case let .resourceMissing(name): return "missing codec resource \(name)"
        case let .javascript(message): return "JavaScriptCore codec error: \(message)"
        case let .invalidResponse(message): return "invalid codec response: \(message)"
        case let .unsupported(reasons): return "unsupported PSD: \(reasons.joined(separator: "; "))"
        case let .fileTooLarge(actual, limit): return "PSD file is \(actual) bytes, limit is \(limit)"
        case let .layerCountExceeded(actual, limit): return "PSD layer count \(actual) exceeds limit \(limit)"
        case let .invalidLayerDimensions(layer, width, height):
            return "layer \(layer) has invalid dimensions \(width)x\(height)"
        case let .invalidCompositeDimensions(expected, actual):
            return "composite dimensions \(actual) do not match \(expected)"
        case .base64DecodeFailed: return "codec returned invalid base64"
        }
    }
}

public final class PSDCodec {
    private let context: JSContext

    public init(bundleScript: String, adapterScript: String) throws {
        guard let context = JSContext() else {
            throw PSDCodecError.javascript("could not create JSContext")
        }
        self.context = context
        context.exceptionHandler = { _, exception in
            // The adapter catches its own errors; this is a last-resort signal.
            _ = exception
        }
        evaluate(bundleScript, name: "ag-psd bundle")
        evaluate(adapterScript, name: "fixed adapter")
        guard !context.objectForKeyedSubscript("__floeReadPSD").isUndefined else {
            throw PSDCodecError.invalidResponse("__floeReadPSD is not defined")
        }
    }

    public static func bundled() throws -> PSDCodec {
        guard let bundleURL = Bundle.module.url(forResource: "ag-psd-bundle", withExtension: "js") else {
            throw PSDCodecError.resourceMissing("ag-psd-bundle.js")
        }
        guard let adapterURL = Bundle.module.url(forResource: "adapter", withExtension: "js") else {
            throw PSDCodecError.resourceMissing("adapter.js")
        }
        let bundleScript = try String(contentsOf: bundleURL, encoding: .utf8)
        let adapterScript = try String(contentsOf: adapterURL, encoding: .utf8)
        return try PSDCodec(bundleScript: bundleScript, adapterScript: adapterScript)
    }

    public func codecInfo() throws -> String {
        guard let function = context.objectForKeyedSubscript("__floeCodecInfo"),
              !function.isUndefined,
              let value = function.call(withArguments: []),
              let string = value.toString() else {
            throw PSDCodecError.invalidResponse("__floeCodecInfo failed")
        }
        return string
    }

    /// Imports a PSD or preserves the exact original bytes when the document
    /// is outside the qualified 8-bit RGB editable baseline.
    public func importDocument(
        _ data: Data,
        limits: PSDReadLimits = PSDReadLimits()
    ) throws -> PSDImportResult {
        let compatibility = try evaluateCompatibility(data, limits: limits)
        guard compatibility.status == .supported else {
            return .preserved(original: data, compatibility: compatibility)
        }
        return .editable(try read(data, includePixels: true, includeComposite: true, limits: limits))
    }

    public func evaluateCompatibility(
        _ data: Data,
        limits: PSDReadLimits = PSDReadLimits()
    ) throws -> PSDCompatibility {
        guard data.count <= limits.maxFileBytes else {
            throw PSDCodecError.fileTooLarge(actual: data.count, limit: limits.maxFileBytes)
        }
        let header = try PSDHeader.parse(data)
        var compatibility = PSDCompatibilityEvaluator.evaluate(
            header,
            maxDimension: limits.maxDimension,
            maxPixels: limits.maxPixels
        )
        guard compatibility.status == .supported else { return compatibility }
        let metadata = try read(data, includePixels: false, includeComposite: false, limits: limits)
        var reasons = compatibility.reasons
        if metadata.layers.contains(where: { $0.info.depth > 16 }) {
            reasons.append("layer nesting exceeds 16 levels")
        }
        if metadata.layers.contains(where: { $0.info.hasText && ($0.info.text == nil || $0.info.width == 0 || $0.info.height == 0) }) {
            reasons.append("complex editable text is preserved without conversion")
        }
        if metadata.layers.contains(where: { $0.info.hasPlacedLayer }) {
            reasons.append("smart objects are not supported by the editable baseline")
        }
        if metadata.layers.contains(where: { $0.info.hasAdjustment }) {
            reasons.append("adjustment layers are not supported by the editable baseline")
        }
        if metadata.layers.contains(where: { $0.info.hasEffects }) {
            reasons.append("layer effects are not supported by the editable baseline")
        }
        if metadata.layers.contains(where: { $0.info.hasVectorMask }) {
            reasons.append("vector masks are not supported by the editable baseline")
        }
        if !reasons.isEmpty {
            compatibility = PSDCompatibility(status: .preservedOnly, reasons: reasons, header: header)
        }
        return compatibility
    }

    public func read(
        _ data: Data,
        includePixels: Bool = true,
        includeComposite: Bool = true,
        limits: PSDReadLimits = PSDReadLimits()
    ) throws -> PSDReadResult {
        guard data.count <= limits.maxFileBytes else {
            throw PSDCodecError.fileTooLarge(actual: data.count, limit: limits.maxFileBytes)
        }
        let header = try PSDHeader.parse(data)
        let compatibility = PSDCompatibilityEvaluator.evaluate(
            header,
            maxDimension: limits.maxDimension,
            maxPixels: limits.maxPixels
        )
        guard compatibility.status == .supported else {
            throw PSDCodecError.unsupported(compatibility.reasons)
        }
        let options = ReadRequestOptions(
            includePixels: includePixels,
            includeComposite: includeComposite,
            totalMemoryLimit: limits.totalMemoryLimit
        )
        let optionsJSON = try encodeJSON(options)
        let responseJSON = try call(
            "__floeReadPSD",
            arguments: [data.base64EncodedString(), optionsJSON]
        )
        let response: ReadResponseDTO
        do {
            response = try JSONDecoder().decode(ReadResponseDTO.self, from: Data(responseJSON.utf8))
        } catch {
            throw PSDCodecError.invalidResponse("could not decode read response: \(error)")
        }
        guard response.ok else {
            throw PSDCodecError.javascript(response.error ?? "unknown read error")
        }
        guard let width = response.width, let height = response.height,
              let layers = response.layers else {
            throw PSDCodecError.invalidResponse("read response is missing width/height/layers")
        }
        var layerPixels: [PSDLayerPixels] = []
        layerPixels.reserveCapacity(layers.count)
        for dto in layers {
            let image = try dto.imageData.map { try $0.image(width: dto.width, height: dto.height, name: dto.name) }
            let maskImage = try dto.mask?.imageData.map {
                try $0.image(
                    width: dto.mask?.width ?? $0.width,
                    height: dto.mask?.height ?? $0.height,
                    name: "\(dto.name) mask"
                )
            }
            let mask = dto.mask.map {
                PSDMaskInfo(
                    top: $0.top,
                    left: $0.left,
                    width: $0.width,
                    height: $0.height,
                    disabled: $0.disabled,
                    imageData: maskImage, defaultColor: UInt8(clamping: $0.defaultColor ?? 0)
                )
            }
            layerPixels.append(PSDLayerPixels(
                info: PSDLayerInfo(
                    name: dto.name,
                    top: dto.top,
                    left: dto.left,
                    width: dto.width,
                    height: dto.height,
                    opacity: dto.opacity,
                    hidden: dto.hidden,
                    clipping: dto.clipping,
                    transparencyProtected: dto.transparencyProtected,
                    blendMode: dto.blendMode,
                    group: dto.group,
                    childCount: dto.childCount,
                    hasText: dto.hasText,
                    hasPlacedLayer: dto.hasPlacedLayer,
                    hasAdjustment: dto.hasAdjustment,
                    hasEffects: dto.hasEffects,
                    hasVectorMask: dto.hasVectorMask,
                    depth: dto.depth,
                    mask: mask, text: dto.text
                ),
                imageData: image,
                maskImageData: maskImage
            ))
        }
        let composite = try response.composite.map {
            try $0.image(width: width, height: height, name: "composite")
        }
        return PSDReadResult(
            width: width,
            height: height,
            channels: response.channels ?? 0,
            bitsPerChannel: response.bitsPerChannel ?? 8,
            colorMode: response.colorMode ?? 3,
            layers: layerPixels,
            composite: composite,
            warnings: response.warnings ?? [],
            canvasFactoryCalls: response.factoryCalls?.canvas ?? 0,
            imageDataFactoryCalls: response.factoryCalls?.imageData ?? 0
        )
    }

    public func write(
        width: Int,
        height: Int,
        layers: [PSDWriteLayer],
        composite: RGBAImage,
        limits: PSDReadLimits = PSDReadLimits()
    ) throws -> Data {
        guard layers.count <= 256 else {
            throw PSDCodecError.layerCountExceeded(actual: layers.count, limit: 256)
        }
        guard width > 0, height > 0, width <= limits.maxDimension, height <= limits.maxDimension else {
            throw PSDCodecError.invalidCompositeDimensions(
                expected: "positive <=\(limits.maxDimension)",
                actual: "\(width)x\(height)"
            )
        }
        guard composite.width == width, composite.height == height else {
            throw PSDCodecError.invalidCompositeDimensions(
                expected: "\(width)x\(height)",
                actual: "\(composite.width)x\(composite.height)"
            )
        }
        let request = WriteRequestDTO(
            width: width,
            height: height,
            layers: try layers.map { layer in
                guard layer.imageData.width > 0, layer.imageData.height > 0 else {
                    throw PSDCodecError.invalidLayerDimensions(
                        layer: layer.name,
                        width: layer.imageData.width,
                        height: layer.imageData.height
                    )
                }
                return WriteLayerDTO(
                    group: layer.group, depth: layer.depth, text: layer.text,
                    name: layer.name,
                    top: layer.top,
                    left: layer.left,
                    opacity: max(0, min(255, layer.opacity)),
                    hidden: layer.hidden,
                    clipping: layer.clipping,
                    transparencyProtected: layer.transparencyProtected,
                    blendMode: layer.blendMode,
                    imageData: PixelDataDTO(
                        width: layer.imageData.width,
                        height: layer.imageData.height,
                        data: Data(layer.imageData.pixels).base64EncodedString()
                    ),
                    mask: layer.mask.map { mask in
                        WriteMaskDTO(
                            top: mask.top,
                            left: mask.left,
                            disabled: mask.disabled, defaultColor: mask.defaultColor,
                            imageData: mask.imageData.map {
                                PixelDataDTO(
                                    width: $0.width,
                                    height: $0.height,
                                    data: Data($0.pixels).base64EncodedString()
                                )
                            }
                        )
                    }
                )
            },
            composite: PixelDataDTO(
                width: composite.width,
                height: composite.height,
                data: Data(composite.pixels).base64EncodedString()
            )
        )
        let requestJSON = try encodeJSON(request)
        let responseJSON = try call("__floeWritePSD", arguments: [requestJSON])
        let response: WriteResponseDTO
        do {
            response = try JSONDecoder().decode(WriteResponseDTO.self, from: Data(responseJSON.utf8))
        } catch {
            throw PSDCodecError.invalidResponse("could not decode write response: \(error)")
        }
        guard response.ok else {
            throw PSDCodecError.javascript(response.error ?? "unknown write error")
        }
        guard let base64 = response.base64, let data = Data(base64Encoded: base64) else {
            throw PSDCodecError.base64DecodeFailed
        }
        return data
    }

    public func roundTrip(_ data: Data, limits: PSDReadLimits = PSDReadLimits()) throws -> Data {
        guard data.count <= limits.maxFileBytes else {
            throw PSDCodecError.fileTooLarge(actual: data.count, limit: limits.maxFileBytes)
        }
        let header = try PSDHeader.parse(data)
        let compatibility = PSDCompatibilityEvaluator.evaluate(
            header,
            maxDimension: limits.maxDimension,
            maxPixels: limits.maxPixels
        )
        guard compatibility.status == .supported else {
            throw PSDCodecError.unsupported(compatibility.reasons)
        }
        let optionsJSON = try encodeJSON(ReadRequestOptions(
            includePixels: true,
            includeComposite: true,
            totalMemoryLimit: limits.totalMemoryLimit
        ))
        let responseJSON = try call(
            "__floeRoundTrip",
            arguments: [data.base64EncodedString(), optionsJSON]
        )
        let response: RoundTripResponseDTO
        do {
            response = try JSONDecoder().decode(RoundTripResponseDTO.self, from: Data(responseJSON.utf8))
        } catch {
            throw PSDCodecError.invalidResponse("could not decode round-trip response: \(error)")
        }
        guard response.ok else {
            throw PSDCodecError.javascript(response.error ?? "unknown round-trip error")
        }
        guard let base64 = response.base64, let out = Data(base64Encoded: base64) else {
            throw PSDCodecError.base64DecodeFailed
        }
        return out
    }

    private func evaluate(_ script: String, name: String) {
        context.exception = nil
        _ = context.evaluateScript(script, withSourceURL: URL(string: "floe-\(name).js"))
        if let exception = context.exception {
            context.exception = nil
            // Initialization failures are surfaced by the missing global check;
            // keep the message available through the thrown error path.
            lastInitializationError = exception.toString()
        }
    }

    private var lastInitializationError: String?

    private func call(_ functionName: String, arguments: [String]) throws -> String {
        context.exception = nil
        guard let function = context.objectForKeyedSubscript(functionName), !function.isUndefined else {
            let suffix = lastInitializationError.map { " (\($0))" } ?? ""
            throw PSDCodecError.invalidResponse("\(functionName) is not defined\(suffix)")
        }
        guard let result = function.call(withArguments: arguments) else {
            if let exception = context.exception {
                context.exception = nil
                throw PSDCodecError.javascript(exception.toString())
            }
            throw PSDCodecError.invalidResponse("\(functionName) returned nil")
        }
        if let exception = context.exception {
            context.exception = nil
            throw PSDCodecError.javascript(exception.toString())
        }
        guard let string = result.toString() else {
            throw PSDCodecError.invalidResponse("\(functionName) did not return a string")
        }
        return string
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw PSDCodecError.invalidResponse("could not encode request as UTF-8")
        }
        return string
    }
}

// MARK: - Wire DTOs

private struct ReadRequestOptions: Encodable {
    let includePixels: Bool
    let includeComposite: Bool
    let totalMemoryLimit: Int
}

private struct PixelDataDTO: Codable {
    let width: Int
    let height: Int
    let data: String

    func image(width: Int, height: Int, name: String) throws -> RGBAImage {
        guard self.width == width, self.height == height else {
            throw PSDCodecError.invalidResponse(
                "\(name) imageData is \(self.width)x\(self.height), expected \(width)x\(height)"
            )
        }
        guard let bytes = Data(base64Encoded: data) else {
            throw PSDCodecError.base64DecodeFailed
        }
        return try RGBAImage(width: width, height: height, pixels: [UInt8](bytes))
    }
}

private struct MaskDTO: Decodable {
    let defaultColor: Int?
    let top: Int
    let left: Int
    let width: Int
    let height: Int
    let disabled: Bool
    let imageData: PixelDataDTO?
}

private struct LayerDTO: Decodable {
    let text: PSDText?
    let name: String
    let top: Int
    let left: Int
    let width: Int
    let height: Int
    let opacity: Int
    let hidden: Bool
    let clipping: Bool
    let transparencyProtected: Bool
    let blendMode: String
    let group: Bool
    let childCount: Int
    let hasText: Bool
    let hasPlacedLayer: Bool
    let hasAdjustment: Bool
    let hasEffects: Bool
    let hasVectorMask: Bool
    let depth: Int
    let mask: MaskDTO?
    let imageData: PixelDataDTO?
}

private struct FactoryCallsDTO: Decodable {
    let canvas: Int
    let imageData: Int
}

private struct ReadResponseDTO: Decodable {
    let ok: Bool
    let error: String?
    let width: Int?
    let height: Int?
    let channels: Int?
    let bitsPerChannel: Int?
    let colorMode: Int?
    let layers: [LayerDTO]?
    let composite: PixelDataDTO?
    let warnings: [String]?
    let factoryCalls: FactoryCallsDTO?
}

private struct WriteLayerDTO: Encodable {
    let group: Bool
    let depth: Int
    let text: PSDText?
    let name: String
    let top: Int
    let left: Int
    let opacity: Int
    let hidden: Bool
    let clipping: Bool
    let transparencyProtected: Bool
    let blendMode: String
    let imageData: PixelDataDTO
    let mask: WriteMaskDTO?
}

private struct WriteMaskDTO: Encodable {
    let top: Int
    let left: Int
    let disabled: Bool
    let defaultColor: UInt8
    let imageData: PixelDataDTO?
}

private struct WriteRequestDTO: Encodable {
    let width: Int
    let height: Int
    let layers: [WriteLayerDTO]
    let composite: PixelDataDTO
}

private struct WriteResponseDTO: Decodable {
    let ok: Bool
    let error: String?
    let base64: String?
    let byteLength: Int?
    let factoryCalls: FactoryCallsDTO?
}

private struct RoundTripResponseDTO: Decodable {
    let ok: Bool
    let error: String?
    let base64: String?
    let byteLength: Int?
    let layers: Int?
    let factoryCalls: FactoryCallsDTO?
}
