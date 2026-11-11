// SPDX-License-Identifier: MPL-2.0
//
// Common in-memory layer model and explicit PSD <-> ORA adapters. This is the
// qualification adapter, not the final production exchange layer: it supports
// the 8-bit RGB raster baseline and rejects masks/clipping for ORA instead of
// silently flattening or dropping them.

import Foundation

public struct PortableMask: Sendable, Equatable {
    public var image: RGBAImage
    /// Mask position relative to the owning layer's top-left.
    public var left: Int
    public var top: Int
    public var isEnabled: Bool
    public var defaultColor: UInt8

    public init(image: RGBAImage, left: Int, top: Int, isEnabled: Bool = true, defaultColor: UInt8 = 0) {
        self.image = image
        self.left = left
        self.top = top; self.isEnabled = isEnabled; self.defaultColor = defaultColor
    }
}

public struct PortableLayer: Sendable, Equatable {
    public var name: String
    public var image: RGBAImage
    public var left: Int
    public var top: Int
    /// 0...1
    public var opacity: Double
    public var visible: Bool
    /// ag-psd/PSD canonical blend name (normal, screen, multiply, ...).
    public var blendMode: String
    public var clipping: Bool
    public var transparencyProtected: Bool
    public var mask: PortableMask?
    public var group: Bool
    public var depth: Int
    public var text: PSDText?

    public init(
        name: String,
        image: RGBAImage,
        left: Int = 0,
        top: Int = 0,
        opacity: Double = 1,
        visible: Bool = true,
        blendMode: String = "normal",
        clipping: Bool = false,
        transparencyProtected: Bool = false,
        mask: PortableMask? = nil, group: Bool = false, depth: Int = 0, text: PSDText? = nil
    ) {
        self.name = name
        self.image = image
        self.left = left
        self.top = top
        self.opacity = opacity
        self.visible = visible
        self.blendMode = blendMode
        self.clipping = clipping
        self.transparencyProtected = transparencyProtected
        self.mask = mask; self.group = group; self.depth = depth; self.text = text
    }
}

public struct PortableDocument: Sendable, Equatable {
    public var width: Int
    public var height: Int
    /// Bottom-to-top.
    public var layers: [PortableLayer]

    public init(width: Int, height: Int, layers: [PortableLayer]) {
        self.width = width
        self.height = height
        self.layers = layers
    }
}

public enum ExchangeError: Error, Equatable, CustomStringConvertible {
    case invalidDimensions(Int, Int)
    case missingLayerPixels(String)
    case unsupportedLayerFeature(layer: String, feature: String)
    case unsupportedBlendMode(String)
    case unsupportedCompositeOperation(String)
    case missingMaskPixels(String)
    case layerCount(Int)
    case emptyDocument

    public var description: String {
        switch self {
        case let .invalidDimensions(width, height): return "invalid document dimensions \(width)x\(height)"
        case let .missingLayerPixels(layer): return "layer \(layer) has no raster pixels"
        case let .unsupportedLayerFeature(layer, feature): return "layer \(layer) uses unsupported \(feature)"
        case let .unsupportedBlendMode(mode): return "unsupported blend mode \(mode)"
        case let .unsupportedCompositeOperation(op): return "unsupported ORA composite-op \(op)"
        case let .missingMaskPixels(layer): return "layer \(layer) has a mask without pixels"
        case let .layerCount(count): return "invalid layer count \(count)"
        case .emptyDocument: return "document has no layers"
        }
    }
}

public enum LayeredExchange {
    public static let oraCompositeOps: [String: String] = [
        "normal": "svg:src-over",
        "screen": "svg:screen",
        "multiply": "svg:multiply",
        "overlay": "svg:overlay",
        "darken": "svg:darken",
        "lighten": "svg:lighten",
        "color burn": "svg:color-burn",
        "color dodge": "svg:color-dodge",
        "hard light": "svg:hard-light",
        "soft light": "svg:soft-light",
        "difference": "svg:difference",
        "hue": "svg:hue",
        "saturation": "svg:saturation",
        "color": "svg:color",
        "luminosity": "svg:luminosity"
    ]

    public static func fromPSD(_ result: PSDReadResult) throws -> PortableDocument {
        guard result.width > 0, result.height > 0 else {
            throw ExchangeError.invalidDimensions(result.width, result.height)
        }
        guard !result.layers.isEmpty else { throw ExchangeError.emptyDocument }
        var layers: [PortableLayer] = []
        // ag-psd and psd_sdk both return layer records bottom-to-top.
        for layer in result.layers {
            let info = layer.info
            if info.hasText && info.text == nil { throw ExchangeError.unsupportedLayerFeature(layer: info.name, feature: "complex editable text") }
            if info.hasPlacedLayer { throw ExchangeError.unsupportedLayerFeature(layer: info.name, feature: "smart object") }
            if info.hasAdjustment { throw ExchangeError.unsupportedLayerFeature(layer: info.name, feature: "adjustment layer") }
            if info.hasEffects { throw ExchangeError.unsupportedLayerFeature(layer: info.name, feature: "layer effects") }
            if info.hasVectorMask { throw ExchangeError.unsupportedLayerFeature(layer: info.name, feature: "vector mask") }
            guard info.depth <= 16 else { throw ExchangeError.unsupportedLayerFeature(layer: info.name, feature: "nesting depth") }
            let image: RGBAImage
            if info.group { image = try RGBAImage(width: 1, height: 1, pixels: [0, 0, 0, 0]) }
            else if let pixels = layer.imageData { image = pixels }
            else { throw ExchangeError.missingLayerPixels(info.name) }
            var portableMask: PortableMask?
            if let maskInfo = info.mask {
                guard let maskImage = layer.maskImageData else {
                    throw ExchangeError.missingMaskPixels(info.name)
                }
                portableMask = PortableMask(
                    image: maskImage,
                    left: maskInfo.left - info.left,
                    top: maskInfo.top - info.top, isEnabled: !maskInfo.disabled, defaultColor: maskInfo.defaultColor
                )
            }
            layers.append(PortableLayer(
                name: info.name,
                image: image,
                left: info.left,
                top: info.top,
                opacity: Double(info.opacity) / 255,
                visible: !info.hidden,
                blendMode: info.blendMode,
                clipping: info.clipping,
                transparencyProtected: info.transparencyProtected,
                mask: portableMask, group: info.group, depth: info.depth, text: info.text
            ))
        }
        return PortableDocument(width: result.width, height: result.height, layers: layers)
    }

    public static func toORA(_ document: PortableDocument) throws -> ORADocument {
        guard document.width > 0, document.height > 0 else {
            throw ExchangeError.invalidDimensions(document.width, document.height)
        }
        guard !document.layers.isEmpty else { throw ExchangeError.emptyDocument }
        var layers: [ORALayer] = []
        for layer in document.layers {
            if layer.group || layer.depth != 0 || layer.text != nil {
                throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "editable group or text in OpenRaster")
            }
            if layer.clipping {
                throw ExchangeError.unsupportedLayerFeature(
                    layer: layer.name,
                    feature: "clipping layer (OpenRaster 0.0.3 has no baseline clipping flag; svg:src-atop is only an approximation)"
                )
            }
            if layer.mask != nil {
                throw ExchangeError.unsupportedLayerFeature(
                    layer: layer.name,
                    feature: "layer mask (OpenRaster baseline has no per-layer mask; bake it into alpha only with explicit opt-in)"
                )
            }
            guard let compositeOp = oraCompositeOps[layer.blendMode] else {
                throw ExchangeError.unsupportedBlendMode(layer.blendMode)
            }
            let png = try PNGCodec.encode(layer.image)
            layers.append(ORALayer(
                name: layer.name,
                pngData: png,
                x: layer.left,
                y: layer.top,
                opacity: layer.opacity,
                visible: layer.visible,
                compositeOp: compositeOp
            ))
        }
        return ORADocument(width: document.width, height: document.height, layers: layers)
    }

    public static func fromORA(_ document: ORADocument) throws -> PortableDocument {
        guard document.width > 0, document.height > 0 else {
            throw ExchangeError.invalidDimensions(document.width, document.height)
        }
        guard !document.layers.isEmpty else { throw ExchangeError.emptyDocument }
        let reverseOps = Dictionary(uniqueKeysWithValues: oraCompositeOps.map { ($0.value, $0.key) })
        var layers: [PortableLayer] = []
        for layer in document.layers {
            if layer.alphaPreserve {
                throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "alpha-preserve extension")
            }
            guard let blendMode = reverseOps[layer.compositeOp] else {
                throw ExchangeError.unsupportedCompositeOperation(layer.compositeOp)
            }
            let image = try PNGCodec.decode(layer.pngData)
            layers.append(PortableLayer(
                name: layer.name,
                image: image,
                left: layer.x,
                top: layer.y,
                opacity: layer.opacity,
                visible: layer.visible,
                blendMode: blendMode
            ))
        }
        return PortableDocument(width: document.width, height: document.height, layers: layers)
    }

    public static func toPSD(
        _ document: PortableDocument,
        codec: PSDCodec
    ) throws -> Data {
        guard document.width > 0, document.height > 0 else {
            throw ExchangeError.invalidDimensions(document.width, document.height)
        }
        guard !document.layers.isEmpty else { throw ExchangeError.emptyDocument }
        let composite = try PortableCompositor.flatten(document)
        let layers = document.layers.map { layer -> PSDWriteLayer in
            let mask = layer.mask.map { mask in
                PSDMaskInfo(
                    top: layer.top + mask.top,
                    left: layer.left + mask.left,
                    width: mask.image.width,
                    height: mask.image.height,
                    disabled: !mask.isEnabled,
                    imageData: mask.image, defaultColor: mask.defaultColor
                )
            }
            return PSDWriteLayer(
                name: layer.name,
                top: layer.top,
                left: layer.left,
                imageData: layer.image,
                opacity: Int((layer.opacity * 255).rounded()),
                hidden: !layer.visible,
                clipping: layer.clipping,
                transparencyProtected: layer.transparencyProtected,
                blendMode: layer.blendMode,
                mask: mask, group: layer.group, depth: layer.depth, text: layer.text
            )
        }
        return try codec.write(width: document.width, height: document.height, layers: layers, composite: composite)
    }
}

public enum PortableCompositor {
    public static func flatten(_ document: PortableDocument) throws -> RGBAImage {
        guard document.width > 0, document.height > 0,
              document.width <= ImageLimits.maxDimension,
              document.height <= ImageLimits.maxDimension else {
            throw ExchangeError.invalidDimensions(document.width, document.height)
        }
        guard !document.layers.isEmpty else { throw ExchangeError.emptyDocument }
        if document.layers.contains(where: { $0.group || $0.depth != 0 }) {
            var index = 0
            func collect(_ depth: Int) throws -> [PortableLayer] {
                guard depth <= 16 else { throw ExchangeError.layerCount(depth) }
                var output: [PortableLayer] = []
                while index < document.layers.count, document.layers[index].depth >= depth {
                    var layer = document.layers[index]
                    guard layer.depth == depth else { throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "invalid hierarchy") }
                    index += 1
                    if layer.group {
                        let children = try collect(depth + 1)
                        if layer.blendMode == "pass through" {
                            guard layer.opacity == 1, layer.mask == nil, children.allSatisfy({ $0.blendMode == "normal" && !$0.clipping }) else {
                                throw ExchangeError.unsupportedLayerFeature(layer: layer.name, feature: "pass-through group compositing")
                            }
                            layer.blendMode = "normal"
                        }
                        layer.image = children.isEmpty ? try RGBAImage(width: 1, height: 1, pixels: [0, 0, 0, 0]) :
                            try flatten(.init(width: document.width, height: document.height, layers: children))
                        if var mask = layer.mask { mask.left += layer.left; mask.top += layer.top; layer.mask = mask }
                        layer.left = 0; layer.top = 0; layer.group = false
                    }
                    layer.depth = 0; output.append(layer)
                }
                return output
            }
            let flat = try collect(0)
            guard index == document.layers.count else { throw ExchangeError.layerCount(document.layers.count) }
            return try flatten(.init(width: document.width, height: document.height, layers: flat))
        }
        let count = try ImageLimits.byteCount(width: document.width, height: document.height)
        var out = [Double](repeating: 0, count: count) // r,g,b,a
        var previousAlpha = [Double](repeating: 0, count: document.width * document.height)
        for layer in document.layers {
            guard layer.visible else {
                if !layer.clipping { previousAlpha = [Double](repeating: 0, count: document.width * document.height) }
                continue
            }
            guard layer.image.width > 0, layer.image.height > 0 else {
                throw ExchangeError.missingLayerPixels(layer.name)
            }
            let x0 = max(0, layer.left)
            let y0 = max(0, layer.top)
            let x1 = min(document.width, layer.left + layer.image.width)
            let y1 = min(document.height, layer.top + layer.image.height)
            if x1 > x0, y1 > y0 {
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let sx = x - layer.left
                        let sy = y - layer.top
                        let si = layer.image.offset(x: sx, y: sy)
                        var sa = Double(layer.image.pixels[si + 3]) / 255 * layer.opacity
                        if let mask = layer.mask, mask.isEnabled {
                            let mx = sx - mask.left
                            let my = sy - mask.top
                            if mx >= 0, my >= 0, mx < mask.image.width, my < mask.image.height {
                                sa *= Double(mask.image.pixels[mask.image.offset(x: mx, y: my)]) / 255
                            } else {
                                sa *= Double(mask.defaultColor) / 255
                            }
                        }
                        if layer.clipping {
                            sa *= previousAlpha[y * document.width + x]
                        }
                        guard sa > 0 else { continue }
                        let di = (y * document.width + x) * 4
                        let da = out[di + 3] / 255
                        let oa = sa + da * (1 - sa)
                        guard oa > 0 else { continue }
                        for c in 0..<3 {
                            let src = Double(layer.image.pixels[si + c])
                            let dst = out[di + c]
                            let blended = try blend(mode: layer.blendMode, backdrop: dst, source: src)
                            let mixed = (1 - da) * src + da * blended
                            out[di + c] = (sa * mixed + (1 - sa) * da * dst) / oa
                        }
                        out[di + 3] = oa * 255
                    }
                }
            }
            if !layer.clipping { previousAlpha = alphaMask(layer: layer, width: document.width, height: document.height) }
        }
        var pixels = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            pixels[i] = UInt8(clamping: Int(out[i].rounded()))
        }
        return try RGBAImage(width: document.width, height: document.height, pixels: pixels)
    }

    private static func alphaMask(layer: PortableLayer, width: Int, height: Int) -> [Double] {
        var alpha = [Double](repeating: 0, count: width * height)
        let x0 = max(0, layer.left)
        let y0 = max(0, layer.top)
        let x1 = min(width, layer.left + layer.image.width)
        let y1 = min(height, layer.top + layer.image.height)
        guard x1 > x0, y1 > y0 else { return alpha }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let sx = x - layer.left
                let sy = y - layer.top
                var coverage = Double(layer.image.pixels[layer.image.offset(x: sx, y: sy) + 3]) / 255 * layer.opacity
                if let mask = layer.mask, mask.isEnabled {
                    let mx = sx - mask.left, my = sy - mask.top
                    let value = mx >= 0 && my >= 0 && mx < mask.image.width && my < mask.image.height ? mask.image.pixels[mask.image.offset(x: mx, y: my)] : mask.defaultColor
                    coverage *= Double(value) / 255
                }
                alpha[y * width + x] = coverage
            }
        }
        return alpha
    }

    private static func blend(mode: String, backdrop: Double, source: Double) throws -> Double {
        let b = backdrop
        let s = source
        switch mode {
        case "normal": return s
        case "multiply": return b * s / 255
        case "screen": return 255 - (255 - b) * (255 - s) / 255
        case "overlay": return b < 128 ? 2 * b * s / 255 : 255 - 2 * (255 - b) * (255 - s) / 255
        case "darken": return min(b, s)
        case "lighten": return max(b, s)
        case "difference": return abs(b - s)
        case "exclusion": return b + s - 2 * b * s / 255
        default: throw ExchangeError.unsupportedBlendMode(mode)
        }
    }
}
