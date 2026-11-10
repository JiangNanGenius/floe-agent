// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import FloeCore
import FloeProviders

/// Optional per-route request preparation. Ordinary image tools pass nil.
/// Ownership, paid-route fallback and per-HTTP authorization stay in the caller.
struct AgentImageRequestTransform: Sendable {
    let acceptsRoute: @MainActor @Sendable (ProviderProfile, ModelProfile) -> Bool
    let prepare: @MainActor @Sendable (ProviderProfile, ModelProfile) async throws -> AgentPreparedImageRequest
}

struct AgentPreparedImageRequest: Sendable {
    let selection: ImageGenerationSelection
    let sourceImages: [Data]
    let mask: Data?
    let metadata: [String: String]
    let restoreImages: @Sendable ([Data]) async throws -> [Data]
}

/// Bounded pixels and reviewed wire sizing, without credentials, persistence or
/// route mutation. A provider's listing/account availability is never a gate.
nonisolated enum MediaProviderImageGeometry {
    struct Input: Sendable {
        let sourcePNG: Data
        let maskPNG: Data
        /// The real document canvas, not the rounded/downsampled reference.
        let width: Int
        let height: Int
    }
    struct Size: Sendable, Equatable {
        let width: Int
        let height: Int
        var wire: String { "\(width)x\(height)" }
    }
    struct Plan: Sendable {
        let target: Size
        let canvas: Size
        let selection: ImageGenerationSelection
        var scale: Double { min(Double(canvas.width) / Double(target.width), Double(canvas.height) / Double(target.height)) }
        var content: CGRect {
            let w = Double(target.width) * scale, h = Double(target.height) * scale
            return CGRect(x: (Double(canvas.width) - w) / 2, y: (Double(canvas.height) - h) / 2, width: w, height: h)
        }
        var metadata: [String: String] {
            ["editGeometry.target": target.wire, "editGeometry.request": canvas.wire,
             "editGeometry.mapping": "uniform-contain-pad-and-crop",
             "editGeometry.content": "\(content.minX),\(content.minY),\(content.width),\(content.height)",
             "editGeometry.mask": "alpha-zero-editable;alpha255-protected;soft-coverage-composited-locally"]
        }
    }
    struct Prepared: Sendable {
        let plan: Plan
        let sourcePNG: Data
        let maskPNG: Data
    }

    /// Mask support is proven by the actual multipart encoder, not .inpaint
    /// alone: Ark currently advertises that operation but omits request.mask.
    static func accepts(provider: ProviderProfile, model: ModelProfile) -> Bool {
        guard model.providerID == provider.id,
              ImageProviderAdapterFactory().adapter(for: provider) is OpenAIImageAdapter else { return false }
        return sizing(model.remoteModelID) != nil
    }

    enum Sizing: Sendable { case flexible, fixed }
    private static func sizing(_ id: String) -> Sizing? {
        // Explicit API contracts, including their documented snapshots. Unknown
        // user IDs retain ordinary generate/edit; this masked canvas operation
        // cannot promise their size or alpha behavior.
        switch id {
        case "gpt-image-2", "gpt-image-2-2026-04-21",
             "gpt-image-2.5-sunburst", "gpt-image-2.5-sunburst-2026-09-08",
             "gpt-image-2.5-flare", "gpt-image-2.5-flare-2026-09-08": .flexible
        case "gpt-image-1.5", "gpt-image-1-mini", "chatgpt-image-latest": .fixed
        default: nil
        }
    }

    static func plan(width: Int, height: Int, provider: ProviderProfile, model: ModelProfile) throws -> Plan {
        try Task.checkCancellation()
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              Int64(width) * Int64(height) <= 8_388_608 else { throw failure(.target) }
        guard accepts(provider: provider, model: model), let mode = sizing(model.remoteModelID) else { throw failure(.route) }
        let contract = ImageGenerationPresetResolver.parameterContract(provider: provider, model: model, operation: .inpaint)
        let target = Size(width: width, height: height)
        let canvas: Size
        if mode == .flexible, let exact = exactSize(target) { canvas = exact }
        else {
            var offers = [Size(width: 1024, height: 1024), Size(width: 1536, height: 1024), Size(width: 1024, height: 1536)]
            // Only documented catalog ratios translated by the real resolver
            // may supplement the universal fixed GPT Image sizes.
            if mode == .flexible {
                for ratio in contract.aspectRatio {
                    let selection = ImageGenerationSelection(aspectRatio: ratio, resolution: contract.defaultResolution)
                    if let wire = try ImageGenerationPresetResolver.nativeSize(provider: .openAI, modelRemoteID: model.remoteModelID, operation: .inpaint, selection: selection),
                       let size = parseSize(wire), size.width <= 1536, size.height <= 1536,
                       size.width * size.height >= 655_360 { offers.append(size) }
                }
            }
            // Minimal padding; deterministic tie-break minimizes request area.
            canvas = offers.min { lhs, rhs in
                let l = padding(target: target, canvas: lhs), r = padding(target: target, canvas: rhs)
                return abs(l - r) > 1e-12 ? l < r : lhs.width * lhs.height < rhs.width * rhs.height
            }!
        }
        // A native size is authoritative: do not inject a contradictory 1:1
        // default aspect alongside an exact 2:1/other WIDTHxHEIGHT request.
        let selection = ImageGenerationSelection(quality: contract.defaultQuality, nativeSizeOverride: canvas.wire)
        try ImageGenerationPresetResolver.validateSelection(selection, provider: provider, model: model,
            operation: .inpaint, count: 1, referenceCount: 1)
        guard try ImageGenerationPresetResolver.nativeSize(provider: .openAI, modelRemoteID: model.remoteModelID,
            operation: .inpaint, selection: selection) == canvas.wire else { throw failure(.route) }
        let result = Plan(target: target, canvas: canvas, selection: selection)
        guard result.content.width >= 1, result.content.height >= 1 else { throw failure(.target) }
        return result
    }

    /// Stay within the normal <=1536-edge request budget. The exact reduced
    /// ratio must be representable with 16-divisible dimensions; otherwise a
    /// documented fixed frame is padded, never a distorted approximate ratio.
    private static func exactSize(_ target: Size) -> Size? {
        guard max(target.width, target.height) <= 3 * min(target.width, target.height) else { return nil }
        let divisor = gcd(target.width, target.height), w = target.width / divisor, h = target.height / divisor
        var best: Size?, bestDistance = Double.infinity
        for multiplier in stride(from: 16, through: 1536 / max(w, h), by: 16) {
            let size = Size(width: w * multiplier, height: h * multiplier), area = size.width * size.height
            guard area >= 655_360, area <= 8_294_400 else { continue }
            let distance = abs(log(Double(area) / 1_048_576))
            if distance < bestDistance { best = size; bestDistance = distance }
        }
        return best
    }
    private static func gcd(_ a: Int, _ b: Int) -> Int { var a = a, b = b; while b != 0 { (a, b) = (b, a % b) }; return a }
    private static func padding(target: Size, canvas: Size) -> Double {
        let scale = min(Double(canvas.width) / Double(target.width), Double(canvas.height) / Double(target.height))
        return 1 - Double(target.width * target.height) * scale * scale / Double(canvas.width * canvas.height)
    }
    private static func parseSize(_ text: String) -> Size? {
        let parts = text.split(separator: "x"); guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]), w > 0, h > 0 else { return nil }
        return Size(width: w, height: h)
    }

    static func prepare(_ input: Input, plan: Plan) throws -> Prepared {
        try Task.checkCancellation()
        guard input.width == plan.target.width, input.height == plan.target.height else { throw failure(.target) }
        let source = try decode(input.sourcePNG, pngOnly: true, reference: true)
        let originalMask = try decode(input.maskPNG, pngOnly: true, reference: true)
        guard source.width == originalMask.width, source.height == originalMask.height,
              abs(Int64(source.width) * Int64(input.height) - Int64(source.height) * Int64(input.width)) <= Int64(max(input.width, input.height)) else { throw failure(.reference) }
        let mask = try binaryWireMask(originalMask)
        let content = plan.content
        let scale = min(content.width / Double(source.width), content.height / Double(source.height))
        let rect = CGRect(x: content.midX - Double(source.width) * scale / 2,
                          y: content.midY - Double(source.height) * scale / 2,
                          width: Double(source.width) * scale, height: Double(source.height) * scale)
        let paddedSource = try render(width: plan.canvas.width, height: plan.canvas.height, opaque: false) { context in
            context.interpolationQuality = .high; context.setBlendMode(.copy); context.draw(source, in: rect)
        }
        let paddedMask = try render(width: plan.canvas.width, height: plan.canvas.height, opaque: true) { context in
            context.interpolationQuality = .none; context.setShouldAntialias(false)
            context.setAllowsAntialiasing(false); context.setBlendMode(.copy); context.draw(mask, in: rect)
        }
        let sourcePNG = try encode(paddedSource), maskPNG = try encode(paddedMask)
        guard maskPNG.count < 4 * 1_024 * 1_024, sourcePNG.count <= 32 * 1_024 * 1_024 else { throw failure(.bytes) }
        try Task.checkCancellation()
        return Prepared(plan: plan, sourcePNG: sourcePNG, maskPNG: maskPNG)
    }

    static func restore(_ data: Data, plan: Plan) throws -> Data {
        try Task.checkCancellation()
        let image = try decode(data, pngOnly: false, reference: false)
        guard abs(Int64(image.width) * Int64(plan.canvas.height) - Int64(image.height) * Int64(plan.canvas.width)) <= Int64(max(plan.canvas.width, plan.canvas.height)) else { throw failure(.response) }
        let outputScale = min(Double(image.width) / Double(plan.canvas.width), Double(image.height) / Double(plan.canvas.height))
        let offsetX = (Double(image.width) - Double(plan.canvas.width) * outputScale) / 2
        let offsetY = (Double(image.height) - Double(plan.canvas.height) * outputScale) / 2
        let scale = 1 / (plan.scale * outputScale)
        let rect = CGRect(x: -(offsetX + plan.content.minX * outputScale) * scale,
                          y: -(offsetY + plan.content.minY * outputScale) * scale,
                          width: Double(image.width) * scale, height: Double(image.height) * scale)
        // One uniform draw clips only the recorded artificial margins. Avoid
        // rounding a crop then stretching its slightly different aspect.
        let restored = try render(width: plan.target.width, height: plan.target.height, opaque: false) { context in
            context.interpolationQuality = .high; context.setBlendMode(.copy); context.draw(image, in: rect)
        }
        let png = try encode(restored)
        guard png.count <= 32 * 1_024 * 1_024 else { throw failure(.bytes) }
        try Task.checkCancellation(); return png
    }

    private static func binaryWireMask(_ image: CGImage) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none; context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard ok else { throw failure(.reference) }
        var editable = false
        for pixel in 0..<(image.width * image.height) {
            if pixel % 4096 == 0 { try Task.checkCancellation() }
            let value: UInt8 = bytes[pixel * 4 + 3] == 255 ? 255 : 0
            if value == 0 { editable = true }
            for channel in 0..<4 { bytes[pixel * 4 + channel] = value }
        }
        guard editable, let provider = CGDataProvider(data: Data(bytes) as CFData),
              let result = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw failure(.mask) }
        return result
    }

    static func decode(_ data: Data, pngOnly: Bool = false, reference: Bool = false) throws -> CGImage {
        guard !data.isEmpty, data.count <= 32 * 1_024 * 1_024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              !pngOnly || (CGImageSourceGetType(source) as String?) == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= (reference ? 2048 : 8192), height <= (reference ? 2048 : 8192),
              Int64(width) * Int64(height) <= (reference ? 4_194_304 : 16_777_216),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw failure(.reference) }
        try Task.checkCancellation()
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(orientation), !reference || orientation == 1 else { throw failure(.reference) }
        if orientation == 1 { return image }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let normalized = context.createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw failure(.response) }
        return normalized
    }
    private static func render(width: Int, height: Int, opaque: Bool, draw: (CGContext) -> Void) throws -> CGImage {
        try Task.checkCancellation()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw failure(.bytes) }
        if opaque { context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)) }
        draw(context); try Task.checkCancellation()
        guard let image = context.makeImage() else { throw failure(.bytes) }; return image
    }
    static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw failure(.bytes) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw failure(.bytes) }; return data as Data
    }

    enum Failure { case target, route, reference, mask, response, bytes }
    private static func failure(_ reason: Failure) -> RemoteImageError {
        let messages: (String, String) = switch reason {
        case .target: ("请选择不超过 8 百万像素的画布。", "Choose a canvas of up to 8 megapixels.")
        case .route: ("所选图像服务不能保留选区和画布形状，请选择兼容的编辑模型。", "Choose an image-editing model that preserves the selection and canvas shape.")
        case .reference: ("图像与选区不匹配，请重新选择后重试。", "The image and selection do not match. Select the area again and retry.")
        case .mask: ("请先选择需要编辑的区域。", "Select an area to edit first.")
        case .response: ("图像服务返回了不同的画幅，未保存此结果。", "The image service returned a different shape. The result was not saved.")
        case .bytes: ("图像超出处理范围，请选择更小的区域后重试。", "This image is too large to process. Select a smaller area and retry.")
        }
        return .requestFailed(FloeL10n.isChinese ? messages.0 : messages.1)
    }

    @MainActor static func transform(_ input: Input) -> AgentImageRequestTransform {
        AgentImageRequestTransform(acceptsRoute: { provider, model in
            (try? plan(width: input.width, height: input.height, provider: provider, model: model)) != nil
        }, prepare: { provider, model in
            let plan = try plan(width: input.width, height: input.height, provider: provider, model: model)
            let prepared = try await ownedWorker { try prepare(input, plan: plan) }
            return AgentPreparedImageRequest(selection: plan.selection, sourceImages: [prepared.sourcePNG], mask: prepared.maskPNG, metadata: plan.metadata,
                restoreImages: { images in
                    try await ownedWorker { try images.map { try restore($0, plan: plan) } }
                })
        })
    }
    /// Cancellation reaches only this bounded pixel worker, never its caller's
    /// siblings or another provider operation. No unstructured retained job.
    private static func ownedWorker<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler(operation: {
            let value = try await worker.value; try Task.checkCancellation(); return value
        }, onCancel: { worker.cancel() })
    }
}
