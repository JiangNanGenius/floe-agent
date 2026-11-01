// USDZ export through Apple's SceneKit writer using ModelIO assets. Baked body
// positions retain millimetres; an ordinary parent converts them to the USD
// writer's metre stage. One material per body; face bindings require a verified
// face table supplied separately.

import Foundation
import ModelIO
import SceneKit
import SceneKit.ModelIO
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd
import os

nonisolated enum USDZExporter {
    struct Diagnostic: Sendable, Equatable {
        var code: String
        var bodyID: UUID?
        var textureSlot: MaterialTextureSlot?
        var message: String
    }

    struct ExportResult: Sendable {
        var data: Data?
        var diagnostics: [Diagnostic]
        var succeeded: Bool { data != nil && diagnostics.isEmpty }
    }

    // SceneKit has its own USDZ writer; ModelIO's canExportFileExtension is
    // false on platforms where SceneKit actually writes USDZ successfully.
    // Probe under one lock: concurrent callers share its result, and no native
    // scene object escapes this boundary. Success lasts for the process; an
    // I/O failure only suppresses probes briefly so disk recovery can recover
    // export without restarting the app.
    private static let nativeWriterCache = OSAllocatedUnfairLock(initialState: WriterCapabilityCache())

    struct WriterCapabilityCache: Sendable {
        private var succeeded = false
        private var retryAfter: TimeInterval?
        private static let failureRetryInterval: TimeInterval = 2

        mutating func check(clock: () -> TimeInterval, probe: () -> Bool) -> Bool {
            if succeeded { return true }
            if let retryAfter, clock() < retryAfter { return false }
            if probe() {
                succeeded = true
                retryAfter = nil
                return true
            }
            // Measure from completion, not start: a slow failed probe must
            // still coalesce callers that were waiting for the same lock.
            retryAfter = clock() + Self.failureRetryInterval
            return false
        }
    }

    /// The first synchronous read runs one fixed three-vertex write/read
    /// probe in an owned temporary directory; success reads perform no I/O.
    /// Failure uses a two-second monotonic cooldown before a later read retries.
    static var isSupported: Bool {
        nativeWriterCache.withLock { state in
            state.check(clock: { ProcessInfo.processInfo.systemUptime }) {
                // The probe never calls isSupported, awaits, or hops actors;
                // holding this lock across it cannot re-enter this cache.
                probeNativeWriter(temporaryDirectory: FileManager.default.temporaryDirectory)
            }
        }
    }

    /// Compatibility entry point. Call `export` to present actionable failures.
    static func usdz(bodies: [Body]) -> Data? { export(bodies: bodies).data }

    /// No external URLs are accepted: applied materials own their image bytes.
    /// Private staging and every texture live until ModelIO finishes packaging,
    /// and are removed on success and failure. No shared resource is removed.
    static func export(bodies: [Body],
                       temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> ExportResult {
        guard isSupported else {
            return failure("unsupportedPlatform", "The native USDZ writer is unavailable on this platform.")
        }
        let directory = temporaryDirectory.appendingPathComponent("floe-usdz-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let asset = MDLAsset()
            var diagnostics: [Diagnostic] = []
            for body in bodies {
                do {
                    try validate(body)
                    let spec = body.material ?? .default
                    let uvs = try textureCoordinates(body, material: spec)
                    let material = try mdlMaterial(spec, body: body, directory: directory)
                    asset.add(mdlMesh(for: body, uvs: uvs, material: material))
                } catch let issue as ExportIssue {
                    diagnostics.append(Diagnostic(code: issue.code, bodyID: body.id.raw,
                                                  textureSlot: issue.slot, message: issue.message))
                }
            }
            // Never return a partial model after losing a body, face override,
            // declared resource or material channel. The old wrapper also fails.
            guard diagnostics.isEmpty else { return ExportResult(data: nil, diagnostics: diagnostics) }
            guard asset.count > 0 else { return failure("emptyModel", "There are no meshes to export.") }
            let output = directory.appendingPathComponent("model.usdz")
            asset.loadTextures()
            try writeNativeAsset(asset, to: output)
            return ExportResult(data: try Data(contentsOf: output), diagnostics: [])
        } catch let issue as ExportIssue {
            return ExportResult(data: nil, diagnostics: [Diagnostic(code: issue.code, textureSlot: issue.slot,
                                                                  message: issue.message)])
        } catch {
            return failure("exportFailed", error.localizedDescription)
        }
    }

    /// Internal seam for lifecycle tests. Does not modify the cached result.
    /// The geometry, factors and buffers are constant and bounded; it neither
    /// opens user documents nor uses shared file names. No task/actor hop or
    /// semaphore wait is hidden inside the synchronous capability query.
    static func probeNativeWriter(temporaryDirectory: URL) -> Bool {
        let directory = temporaryDirectory.appendingPathComponent("floe-usdz-capability-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        var createdDirectory = false
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            createdDirectory = true
            let supported = try autoreleasepool {
                let render = RenderMesh(positions: [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 20, 0)],
                                        normals: Array(repeating: SIMD3(0, 0, 1), count: 3), indices: [0, 1, 2],
                                        texcoords: [SIMD2(0.1, 0.2), SIMD2(0.9, 0.2), SIMD2(0.1, 0.8)])
                var body = Body(id: BodyID(), name: "USDZCapability", transform: .identity, render: render,
                                edges: FeatureEdgeSet(segments: []), revision: 1)
                let spec = BodyMaterialSpec(baseColor: SIMD4(0.2, 0.4, 0.8, 1), metallic: 0.75, roughness: 0.35)
                body.material = spec
                let material = try mdlMaterial(spec, body: body, directory: directory)
                let uvs = try textureCoordinates(body, material: spec)
                let asset = MDLAsset()
                asset.add(mdlMesh(for: body, uvs: uvs, material: material))
                let output = directory.appendingPathComponent("probe.usdz")
                try writeNativeAsset(asset, to: output)
                let bytes = try Data(contentsOf: output)
                guard Array(bytes.prefix(4)) == [80, 75, 3, 4] else { return false }
                let imported = MDLAsset(url: output)
                let meshes = imported.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
                guard meshes.count == 1, let mesh = meshes.first, mesh.vertexCount == 3,
                      let uv = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeTextureCoordinate, as: .float2),
                      let positions = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3),
                      let submesh = mesh.submeshes?.firstObject as? MDLSubmesh,
                      let metallic = submesh.material?.property(with: .metallic), metallic.type == .float,
                      let roughness = submesh.material?.property(with: .roughness), roughness.type == .float,
                      abs(metallic.floatValue - 0.75) < 0.003, abs(roughness.floatValue - 0.35) < 0.003 else { return false }
                let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
                let expectedMetres: [SIMD3<Float>] = [.zero, SIMD3(0.01, 0, 0), SIMD3(0, 0.02, 0)]
                guard expectedMetres.allSatisfy({ expected in
                    (0..<mesh.vertexCount).contains { index in
                        let start = positions.dataStart.advanced(by: index * positions.stride)
                        let p = SIMD4(start.loadUnaligned(as: Float.self),
                                      start.advanced(by: 4).loadUnaligned(as: Float.self),
                                      start.advanced(by: 8).loadUnaligned(as: Float.self), 1)
                        let composed = world * p
                        return simd_distance(SIMD3(composed.x, composed.y, composed.z), expected) < 1e-7
                    }
                }) else { return false }
                // Check UV values, not merely the existence of an attribute.
                return (uvs ?? []).allSatisfy { expected in
                    (0..<mesh.vertexCount).contains { index in
                        let start = uv.dataStart.advanced(by: index * uv.stride)
                        let u = start.loadUnaligned(as: Float.self)
                        let v = start.advanced(by: 4).loadUnaligned(as: Float.self)
                        return abs(u - expected.x) < 0.0001 && abs(v - expected.y) < 0.0001
                    }
                }
            }
            try fm.removeItem(at: directory)
            return supported
        } catch {
            // This path is task-owned scratch, never a user resource. A
            // failed write/read or failed cleanup must not advertise support.
            if createdDirectory { try? fm.removeItem(at: directory) }
            return false
        }
    }

    private static func writeNativeAsset(_ asset: MDLAsset, to url: URL) throws {
        let scene = SCNScene(mdlAsset: asset)
        // SceneKit authors metersPerUnit=1. Its special root's transform and
        // unit-metadata write options are ignored by the USDZ writer. Preserve
        // the body's raw millimetre buffers using a NORMAL exported parent.
        let millimetres = SCNNode()
        millimetres.name = "FloeMillimeters"
        millimetres.simdScale = SIMD3<Float>(repeating: 0.001)
        for child in scene.rootNode.childNodes {
            child.removeFromParentNode()
            millimetres.addChildNode(child)
        }
        scene.rootNode.addChildNode(millimetres)
        guard scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) else {
            throw ExportIssue(code: "nativeWriterFailed", message: "The native writer could not create the USDZ archive.")
        }
    }

    private struct ExportIssue: Error {
        var code: String
        var slot: MaterialTextureSlot? = nil
        var message: String
    }

    private static func failure(_ code: String, _ message: String) -> ExportResult {
        ExportResult(data: nil, diagnostics: [Diagnostic(code: code, message: message)])
    }

    private static func validate(_ body: Body) throws {
        let mesh = body.render
        guard !mesh.positions.isEmpty, !mesh.indices.isEmpty,
              mesh.positions.count == mesh.normals.count, mesh.indices.count % 3 == 0,
              mesh.indices.allSatisfy({ Int($0) < mesh.positions.count }),
              mesh.positions.allSatisfy({ finite($0) }),
              mesh.normals.allSatisfy({ finite($0) && simd_length_squared($0) > 0 }),
              body.transform.scale.isFinite, body.transform.scale > 0,
              finite(SIMD3<Float>(body.transform.translation)),
              body.transform.rotation.vector.x.isFinite, body.transform.rotation.vector.y.isFinite,
              body.transform.rotation.vector.z.isFinite, body.transform.rotation.vector.w.isFinite else {
            throw ExportIssue(code: "invalidMesh", message: "Mesh buffers or transform are invalid.")
        }
        guard simd_length_squared(body.transform.rotation.vector) > 0,
              mesh.positions.allSatisfy({ finite(SIMD3<Float>(body.transform.applying(to: SIMD3<Double>($0)))) }) else {
            throw ExportIssue(code: "invalidMesh", message: "World-space mesh coordinates exceed the export range.")
        }
        guard body.materialFaceBindings.isEmpty else {
            throw ExportIssue(code: "unsupportedFaceMaterials",
                              message: "Per-face materials require verified face-to-triangle ranges; this export supports body materials.")
        }
        let m = body.material ?? .default
        let values = [m.baseColor.x, m.baseColor.y, m.baseColor.z, m.baseColor.w,
                      m.metallic, m.roughness, m.opacity ?? m.baseColor.w,
                      m.emissive?.x ?? 0, m.emissive?.y ?? 0, m.emissive?.z ?? 0]
        guard values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              (m.emissiveStrength ?? 1).isFinite, (m.emissiveStrength ?? 1) >= 0 else {
            throw ExportIssue(code: "invalidMaterial", message: "Material factors must be finite and within their supported range.")
        }
        // The native bridge clamps colour components above one, even for
        // scalar emission in an extended colour space. Do not claim HDR
        // fidelity after writing a clipped emissive factor.
        let emission = (m.emissive ?? SIMD3(repeating: m.emissiveTexture == nil ? 0 : 1)) * (m.emissiveStrength ?? 1)
        if simd_reduce_max(emission) > 1 {
            throw ExportIssue(code: "unsupportedHDREmission", slot: .emissive,
                              message: "The native USDZ writer cannot preserve emission factors above one.")
        }
        let declaredSlots = (m.textureMetadata ?? []).map { $0.slot.rawValue }
        guard Set(declaredSlots).count == declaredSlots.count else {
            throw ExportIssue(code: "ambiguousTextureMetadata", message: "A texture slot has conflicting resource descriptions.")
        }
        for item in m.textureMetadata ?? [] {
            guard let bytes = m.textureData(for: item.slot) else {
                throw ExportIssue(code: "missingTexture", slot: item.slot,
                                  message: "The material declares a texture whose image bytes are missing.")
            }
            guard item.verifiedDigest(for: bytes) != nil else {
                throw ExportIssue(code: "textureIdentityMismatch", slot: item.slot,
                                  message: "Texture bytes do not match their persisted identity.")
            }
        }
        if metadata(.normal, in: m)?.colorSpace == .srgb, m.normalTexture != nil {
            throw ExportIssue(code: "unsupportedNormalColorSpace", slot: .normal,
                              message: "Tangent-space normal maps must use linear channel values.")
        }
    }

    private static func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }

    private static func textureCoordinates(_ body: Body, material: BodyMaterialSpec) throws -> [SIMD2<Float>]? {
        if let map = material.uvMapping, map.source == .mesh,
           map.rotationDegrees != 0 || map.offset != .zero || map.flipU || map.flipV {
            throw ExportIssue(code: "unsupportedMeshUVTransform",
                              message: "Mesh UV transforms need an explicit material mapping adapter.")
        }
        let uvs = MaterialUVProjector.effectiveUVs(
            meshTexcoords: body.render.texcoords,
            positions: body.render.positions,
            normals: body.render.normals,
            indices: body.render.indices,
            mapping: material.uvMapping)
        if let uvs {
            guard uvs.count == body.render.positions.count,
                  uvs.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw ExportIssue(code: "invalidUVs", message: "Texture coordinates must match the vertex buffer.")
            }
        } else if material.hasAnyTexture {
            throw ExportIssue(code: "missingUVs", message: "Textured materials need mesh UVs or an explicit projection.")
        }
        // Floe's mesh UV origin is top-left; USD's st origin is bottom-left.
        return uvs?.map { SIMD2($0.x, 1 - $0.y) }
    }

    private static func metadata(_ slot: MaterialTextureSlot, in spec: BodyMaterialSpec) -> CADMaterialTextureMetadata? {
        spec.textureMetadata?.first { $0.slot == slot }
    }

    private static func mdlMaterial(_ spec: BodyMaterialSpec, body: Body, directory: URL) throws -> MDLMaterial {
        let material = MDLMaterial(name: spec.materialName ?? "\(body.name) Material",
                                   scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        // One value per semantic: bake map multipliers into image pixels.
        // Duplicate factor/map properties have writer-dependent precedence.
        material.removeAllProperties()
        let emission = (spec.emissive ?? SIMD3(repeating: spec.emissiveTexture == nil ? 0 : 1)) * (spec.emissiveStrength ?? 1)
        let colors: [(MaterialTextureSlot, MDLMaterialSemantic, SIMD3<Double>)] = [
            (.baseColor, .baseColor, SIMD3(spec.baseColor.x, spec.baseColor.y, spec.baseColor.z)),
            (.emissive, .emission, emission)
        ]
        for (slot, semantic, factor) in colors {
            if let bytes = spec.textureData(for: slot) {
                var image = try pixels(bytes, slot: slot, metadata: metadata(slot, in: spec))
                let isSRGB = metadata(slot, in: spec)?.colorSpace != .linear
                for offset in stride(from: 0, to: image.bytes.count, by: 4) {
                    for channel in 0..<3 {
                        let value = Double(image.bytes[offset + channel]) / 255
                        let linear = isSRGB ? srgbToLinear(value) : value
                        image.bytes[offset + channel] = byte(linearToSRGB(linear * factor[channel]))
                    }
                    image.bytes[offset + 3] = 255 // opacity is a separate semantic
                }
                try setTexture(image, slot: slot, semantic: semantic, material: material,
                               prefix: body.id.raw.uuidString, directory: directory)
            } else {
                // BodyMaterialSpec's current viewport factors are authored in
                // display-encoded sRGB; GLB also retains their numeric values.
                // An untagged MDL float3 takes a device-RGB conversion through
                // SceneKit and changes them. Declare the canonical space
                // explicitly, rather than compensating values empirically.
                guard let space = CGColorSpace(name: CGColorSpace.extendedSRGB),
                      let color = CGColor(colorSpace: space,
                                          components: [CGFloat(factor.x), CGFloat(factor.y), CGFloat(factor.z), 1]) else {
                    throw ExportIssue(code: "unsupportedColorSpace", slot: slot,
                                      message: "Cannot represent the material's canonical sRGB factor.")
                }
                material.setProperty(MDLMaterialProperty(name: slot.rawValue, semantic: semantic,
                                                         color: color))
            }
        }
        for (slot, semantic, factor) in [(MaterialTextureSlot.metallic, MDLMaterialSemantic.metallic, spec.metallic),
                                         (.roughness, .roughness, spec.roughness)] {
            if let bytes = spec.textureData(for: slot) {
                var image = try pixels(bytes, slot: slot, metadata: metadata(slot, in: spec))
                let isSRGB = metadata(slot, in: spec)?.colorSpace == .srgb
                for offset in stride(from: 0, to: image.bytes.count, by: 4) {
                    let value = byte(luminance(image.bytes, offset: offset, srgb: isSRGB) * factor)
                    image.bytes.replaceSubrange(offset..<(offset + 4), with: [value, value, value, 255])
                }
                try setTexture(image, slot: slot, semantic: semantic, material: material,
                               prefix: body.id.raw.uuidString, directory: directory)
            } else {
                material.setProperty(MDLMaterialProperty(name: slot.rawValue, semantic: semantic, float: Float(factor)))
            }
        }
        if let bytes = spec.normalTexture {
            let image = try pixels(bytes, slot: .normal, metadata: metadata(.normal, in: spec))
            try setTexture(image, slot: .normal, semantic: .tangentSpaceNormal, material: material,
                           prefix: body.id.raw.uuidString, directory: directory)
        }
        // Preserve albedo alpha, the separate opacity factor and opacity map.
        let base = try spec.baseColorTexture.map { try pixels($0, slot: .baseColor, metadata: metadata(.baseColor, in: spec)) }
        let opacity = try spec.opacityTexture.map { try pixels($0, slot: .opacity, metadata: metadata(.opacity, in: spec)) }
        if let dimensions = base ?? opacity {
            guard base == nil || opacity == nil || (base!.width == opacity!.width && base!.height == opacity!.height) else {
                throw ExportIssue(code: "unsupportedOpacityDimensions", slot: .opacity,
                                  message: "Albedo and opacity maps need matching dimensions to preserve texels exactly.")
            }
            var combined = Pixels(width: dimensions.width, height: dimensions.height,
                                  bytes: [UInt8](repeating: 255, count: dimensions.bytes.count))
            for offset in stride(from: 0, to: combined.bytes.count, by: 4) {
                let alpha = base.map { Double($0.bytes[offset + 3]) / 255 } ?? 1
                let opacityValue = opacity.map {
                    luminance($0.bytes, offset: offset, srgb: metadata(.opacity, in: spec)?.colorSpace == .srgb)
                } ?? 1
                let value = byte(alpha * opacityValue * spec.effectiveOpacity)
                // Native USD conversion and external PreviewSurface readers
                // may sample either luminance or alpha for an opacity map.
                // Store the complete authored product in both, once. An
                // opaque alpha channel otherwise discards the entire mask.
                combined.bytes.replaceSubrange(offset..<(offset + 4), with: [value, value, value, value])
            }
            try setTexture(combined, slot: .opacity, semantic: .opacity, material: material,
                           prefix: body.id.raw.uuidString, directory: directory)
        } else {
            material.setProperty(MDLMaterialProperty(name: "opacity", semantic: .opacity, float: Float(spec.effectiveOpacity)))
        }
        return material
    }

    private struct Pixels { var width: Int; var height: Int; var bytes: [UInt8] }

    /// Bound ImageIO allocations from header dimensions before decoding.
    private static func pixels(_ bytes: Data, slot: MaterialTextureSlot, metadata: CADMaterialTextureMetadata?) throws -> Pixels {
        guard bytes.count <= CADMaterialLimits.maximumTextureBytes,
              MaterialImageSniffer.mimeType(of: bytes) != nil,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (info[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (info[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= CADImagePackingLimits.maximumDimension,
              height <= CADImagePackingLimits.maximumDimension,
              width * height <= CADImagePackingLimits.maximumPixelCount,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ExportIssue(code: "invalidTexture", slot: slot, message: "Texture is invalid or exceeds image limits.")
        }
        if let orientation = (info[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation != 1 {
            throw ExportIssue(code: "unsupportedImageOrientation", slot: slot,
                              message: "EXIF-oriented images must be normalized before export.")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw ExportIssue(code: "textureDecodeFailed", slot: slot, message: "Cannot decode texture pixels.") }
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            if alpha > 0 && alpha < 255 {
                for channel in 0..<3 {
                    pixels[offset + channel] = UInt8(min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        if metadata?.orientation == .bottomLeft {
            let original = pixels
            let rowStride = width * 4
            for row in 0..<height {
                pixels.replaceSubrange((row * rowStride)..<((row + 1) * rowStride),
                                       with: original[((height - row - 1) * rowStride)..<((height - row) * rowStride)])
            }
        }
        return Pixels(width: width, height: height, bytes: pixels)
    }

    private static func setTexture(_ pixels: Pixels, slot: MaterialTextureSlot, semantic: MDLMaterialSemantic,
                                   material: MDLMaterial, prefix: String, directory: URL) throws {
        guard let provider = CGDataProvider(data: Data(pixels.bytes) as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixels.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw ExportIssue(code: "textureEncodeFailed", slot: slot, message: "Cannot prepare texture image.")
        }
        let url = directory.appendingPathComponent("\(prefix)-\(slot.rawValue).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportIssue(code: "textureEncodeFailed", slot: slot, message: "Cannot create texture resource.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportIssue(code: "textureEncodeFailed", slot: slot, message: "Cannot encode texture resource.")
        }
        material.setProperty(MDLMaterialProperty(name: slot.rawValue, semantic: semantic, url: url))
    }

    private static func byte(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
    private static func srgbToLinear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func linearToSRGB(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }
    private static func luminance(_ bytes: [UInt8], offset: Int, srgb: Bool) -> Double {
        let c = (0..<3).map { Double(bytes[offset + $0]) / 255 }
        return srgb ? (srgbToLinear(c[0]) * 0.2126 + srgbToLinear(c[1]) * 0.7152 + srgbToLinear(c[2]) * 0.0722)
            : (c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722)
    }

    private static func mdlMesh(for body: Body, uvs: [SIMD2<Float>]?, material: MDLMaterial) -> MDLMesh {
        let transform = body.transform
        let stride = uvs == nil ? 24 : 32
        var vertexData = Data(capacity: body.render.positions.count * stride)
        for index in body.render.positions.indices {
            let worldP = SIMD3<Float>(transform.applying(to: SIMD3<Double>(body.render.positions[index])))
            let worldN = SIMD3<Float>(simd_normalize(transform.rotation.act(SIMD3<Double>(body.render.normals[index]))))
            var components = [worldP.x, worldP.y, worldP.z, worldN.x, worldN.y, worldN.z]
            if let uv = uvs?[index] { components += [uv.x, uv.y] }
            for component in components { withUnsafeBytes(of: component) { vertexData.append(contentsOf: $0) } }
        }
        var indexData = Data(capacity: body.render.indices.count * 4)
        for index in body.render.indices { withUnsafeBytes(of: index.littleEndian) { indexData.append(contentsOf: $0) } }
        let allocator = MDLMeshBufferDataAllocator()
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        if uvs != nil {
            descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        }
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: stride)
        let submesh = MDLSubmesh(indexBuffer: allocator.newBuffer(with: indexData, type: .index),
                                indexCount: body.render.indices.count, indexType: .uInt32, geometryType: .triangles, material: material)
        let mesh = MDLMesh(vertexBuffer: allocator.newBuffer(with: vertexData, type: .vertex),
                           vertexCount: body.render.positions.count, descriptor: descriptor, submeshes: [submesh])
        mesh.name = body.name
        if body.material?.normalTexture != nil {
            mesh.addTangentBasis(forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                                 normalAttributeNamed: MDLVertexAttributeNormal, tangentAttributeNamed: MDLVertexAttributeTangent)
        }
        return mesh
    }
}
