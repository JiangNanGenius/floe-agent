//
//  CADGLBMaterialInteropTests.swift
//  FloeAppTests
//
//  Canonical material/GLB interoperability: the exported glTF factors and
//  packed image channels must mean the same thing as the engineering shader
//  and Present (factor × map, missing channel white, zero strength = no
//  emission), and the importer must recover the packed metallic-roughness
//  channels instead of treating the whole image as one scalar map.
//
//  These tests inspect the real GLB JSON and the embedded PNG pixels. They do
//  not compare lighting between renderers.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import simd

@testable import FloeCAD

final class CADGLBMaterialInteropTests: XCTestCase {

    // MARK: - Fixtures

    private func makeBody(material: BodyMaterialSpec?) -> Body {
        let positions = [SIMD3<Float>(0, 0, 0),
                         SIMD3<Float>(40, 0, 0),
                         SIMD3<Float>(0, 30, 0)]
        let normals = [SIMD3<Float>(0, 1, 0),
                       SIMD3<Float>(0, 1, 0),
                       SIMD3<Float>(0, 1, 0)]
        var body = Body(id: BodyID(), name: "Interop",
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: [0, 1, 2]),
                        revision: 1)
        body.material = material
        return body
    }

    /// Encode straight-alpha RGBA pixels as a PNG. CGImage bitmap data is
    /// premultiplied, so premultiply only for the provider; ImageIO writes a
    /// straight-alpha PNG, exactly like a normal image asset.
    private func png(width: Int, height: Int, straightRGBA: [UInt8]) -> Data {
        precondition(straightRGBA.count == width * height * 4)
        var premultiplied = straightRGBA
        var pixel = 0
        while pixel < premultiplied.count {
            let alpha = Int(premultiplied[pixel + 3])
            if alpha == 0 {
                premultiplied[pixel] = 0
                premultiplied[pixel + 1] = 0
                premultiplied[pixel + 2] = 0
            } else if alpha < 255 {
                for channel in 0..<3 {
                    let value = Int(premultiplied[pixel + channel]) * alpha
                    premultiplied[pixel + channel] = UInt8((value + 127) / 255)
                }
            }
            pixel += 4
        }
        let provider = CGDataProvider(data: Data(premultiplied) as CFData)!
        let image = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A 2×2 opaque grayscale map.
    private func grayPNG(_ value: UInt8) -> Data {
        var pixels = [UInt8]()
        for _ in 0..<4 {
            pixels += [value, value, value, 255]
        }
        return png(width: 2, height: 2, straightRGBA: pixels)
    }

    private func metadata(slot: MaterialTextureSlot, data: Data,
                          colorSpace: MaterialTextureColorSpace,
                          orientation: MaterialTextureOrientation = .topLeft)
        -> CADMaterialTextureMetadata {
        CADMaterialTextureMetadata(
            assetID: UUID(), slot: slot, mimeType: "image/png",
            colorSpace: colorSpace, orientation: orientation,
            sha256: CADMaterialTexture.digest(data), byteCount: data.count)
    }

    // MARK: - GLB inspection

    private func glbChunks(_ glb: Data) throws -> (json: [String: Any], bin: Data) {
        func u32(_ offset: Int) -> UInt32 {
            glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        XCTAssertEqual(u32(0), GLBExporter.magic)
        XCTAssertEqual(u32(4), GLBExporter.containerVersion)
        let jsonLength = Int(u32(12))
        XCTAssertGreaterThan(jsonLength, 0)
        let jsonStart = 20
        let jsonData = glb.subdata(in: jsonStart..<(jsonStart + jsonLength))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let binHeader = jsonStart + jsonLength
        let binLength = Int(u32(binHeader))
        let binStart = binHeader + 8
        let bin = glb.subdata(in: binStart..<(binStart + binLength))
        return (json, bin)
    }

    private func materials(_ json: [String: Any]) -> [[String: Any]] {
        (json["materials"] as? [[String: Any]]) ?? []
    }

    private func material(named name: String, in json: [String: Any]) throws
        -> [String: Any] {
        try XCTUnwrap(materials(json).first { ($0["name"] as? String) == name },
                      "missing glTF material \(name)")
    }

    private func imageData(json: [String: Any], bin: Data, textureIndex: Int) throws
        -> Data {
        let textures = try XCTUnwrap(json["textures"] as? [[String: Any]])
        let source = try XCTUnwrap(textures[textureIndex]["source"] as? Int)
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        let viewIndex = try XCTUnwrap(images[source]["bufferView"] as? Int)
        let views = try XCTUnwrap(json["bufferViews"] as? [[String: Any]])
        let offset = views[viewIndex]["byteOffset"] as? Int ?? 0
        let length = try XCTUnwrap(views[viewIndex]["byteLength"] as? Int)
        return bin.subdata(in: offset..<(offset + length))
    }

    private func textureIndex(_ material: [String: Any], key: String) throws -> Int {
        if key == "normalTexture" || key == "emissiveTexture" {
            let info = try XCTUnwrap(material[key] as? [String: Any])
            return try XCTUnwrap(info["index"] as? Int)
        }
        let pbr = try XCTUnwrap(material["pbrMetallicRoughness"] as? [String: Any])
        let info = try XCTUnwrap(pbr[key] as? [String: Any])
        return try XCTUnwrap(info["index"] as? Int)
    }

    /// Decode straight RGBA from an encoded PNG (ImageIO returns
    /// premultiplied bitmap bytes; un-premultiply for comparison).
    private func decodedRGBA(_ data: Data) throws
        -> (width: Int, height: Int, pixels: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var drew = false
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drew = true
        }
        XCTAssertTrue(drew)
        var pixel = 0
        while pixel < bytes.count {
            let alpha = Int(bytes[pixel + 3])
            if alpha == 0 {
                bytes[pixel] = 0
                bytes[pixel + 1] = 0
                bytes[pixel + 2] = 0
            } else if alpha < 255 {
                for channel in 0..<3 {
                    let value = Int(bytes[pixel + channel]) * 255
                    bytes[pixel + channel] = UInt8(min(255, (value + alpha / 2) / alpha))
                }
            }
            pixel += 4
        }
        return (width, height, bytes)
    }

    private func luminance(_ pixels: [UInt8], _ pixel: Int) -> UInt8 {
        let base = pixel * 4
        let value = (Int(pixels[base]) * 54 + Int(pixels[base + 1]) * 183
                     + Int(pixels[base + 2]) * 19) >> 8
        return UInt8(min(max(value, 0), 255))
    }

    private func assertClose(_ actual: [Double], _ expected: [Double],
                             accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertEqual(a, e, accuracy: accuracy, file: file, line: line)
        }
    }

    // MARK: - Metallic / roughness packing

    func testPackedMetallicRoughnessKeepsAuthoredFactors() throws {
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0.7, roughness: 0.2,
            materialName: "Factor Map",
            roughnessTexture: grayPNG(64),
            metallicTexture: grayPNG(128))
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let (json, bin) = try glbChunks(glb)
        let exported = try material(named: "Factor Map", in: json)
        let pbr = try XCTUnwrap(exported["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual(pbr["metallicFactor"] as? Double ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(pbr["roughnessFactor"] as? Double ?? -1, 0.2, accuracy: 1e-9)

        let index = try textureIndex(exported, key: "metallicRoughnessTexture")
        let decoded = try decodedRGBA(try imageData(json: json, bin: bin,
                                                    textureIndex: index))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)
        for pixel in 0..<4 {
            XCTAssertEqual(decoded.pixels[pixel * 4 + 1], 64,
                           "G must carry the roughness map, not a factor")
            XCTAssertEqual(decoded.pixels[pixel * 4 + 2], 128,
                           "B must carry the metallic map")
            XCTAssertEqual(decoded.pixels[pixel * 4 + 3], 255)
        }

        let nodes = try XCTUnwrap(json["nodes"] as? [[String: Any]])
        let rootScale = try XCTUnwrap(nodes.last?["scale"] as? [Double])
        XCTAssertEqual(rootScale, [0.001, 0.001, 0.001],
                       "mm -> m root transform must stay intact")
    }

    func testPackedMetallicRoughnessUsesWhiteForMissingChannel() throws {
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0.35, roughness: 0.8,
            materialName: "Missing Roughness",
            metallicTexture: grayPNG(200))
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let (json, bin) = try glbChunks(glb)
        let exported = try material(named: "Missing Roughness", in: json)
        let pbr = try XCTUnwrap(exported["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual(pbr["metallicFactor"] as? Double ?? -1, 0.35, accuracy: 1e-9)
        XCTAssertEqual(pbr["roughnessFactor"] as? Double ?? -1, 0.8, accuracy: 1e-9)

        let index = try textureIndex(exported, key: "metallicRoughnessTexture")
        let decoded = try decodedRGBA(try imageData(json: json, bin: bin,
                                                    textureIndex: index))
        for pixel in 0..<4 {
            XCTAssertEqual(decoded.pixels[pixel * 4 + 1], 255,
                           "a missing roughness map is white (factor identity)")
            XCTAssertEqual(decoded.pixels[pixel * 4 + 2], 200)
        }
    }

    // MARK: - Emissive

    func testZeroEmissiveStrengthIsOffEvenWithEmissiveRGBAndMap() throws {
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 0.5,
            materialName: "Dark Emitter",
            emissive: SIMD3(1, 0.5, 0.25), emissiveStrength: 0,
            emissiveTexture: grayPNG(200))
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let (json, _) = try glbChunks(glb)
        let exported = try material(named: "Dark Emitter", in: json)
        XCTAssertNil(exported["emissiveFactor"],
                     "strength 0 must not fall back to factorScale 1")
        XCTAssertNil(exported["emissiveTexture"],
                     "an off material must not export an emissive map")
        XCTAssertNil(exported["extensions"])
        let used = (json["extensionsUsed"] as? [String]) ?? []
        XCTAssertFalse(used.contains("KHR_materials_emissive_strength"))
    }

    func testEmissiveStrengthAtOrBelowOneScalesFactor() throws {
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 0.5,
            materialName: "Half Emitter",
            emissive: SIMD3(0.8, 0.4, 0.2), emissiveStrength: 0.5)
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let (json, _) = try glbChunks(glb)
        let exported = try material(named: "Half Emitter", in: json)
        let factor = try XCTUnwrap(exported["emissiveFactor"] as? [Double])
        assertClose(factor, [0.4, 0.2, 0.1])
        XCTAssertNil(exported["extensions"])
        let used = (json["extensionsUsed"] as? [String]) ?? []
        XCTAssertFalse(used.contains("KHR_materials_emissive_strength"))

        let parts = try GLTFImporter.parts(from: glb, isBinary: true,
                                           siblings: [:], unitScale: 1)
        let imported = try XCTUnwrap(parts.first?.material)
        XCTAssertEqual(imported.emissiveStrength ?? -1, 1.0, accuracy: 1e-9,
                       "glTF's implicit strength is 1, not 0")
        let importedRGB = try XCTUnwrap(imported.emissive)
        assertClose([importedRGB.x, importedRGB.y, importedRGB.z],
                    [0.4, 0.2, 0.1], accuracy: 1e-9)
    }

    func testEmissiveStrengthAboveOneUsesKHRMultiplier() throws {
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 0.5,
            materialName: "Bright Emitter",
            emissive: SIMD3(0.8, 0.4, 0.2), emissiveStrength: 2.5)
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let (json, _) = try glbChunks(glb)
        let exported = try material(named: "Bright Emitter", in: json)
        let factor = try XCTUnwrap(exported["emissiveFactor"] as? [Double])
        assertClose(factor, [0.8, 0.4, 0.2])
        let extensions = try XCTUnwrap(exported["extensions"] as? [String: Any])
        let strengthBody = try XCTUnwrap(
            extensions["KHR_materials_emissive_strength"] as? [String: Any])
        let strength = try XCTUnwrap(strengthBody["emissiveStrength"] as? Double)
        XCTAssertEqual(strength, 2.5, accuracy: 1e-9)
        let used = (json["extensionsUsed"] as? [String]) ?? []
        XCTAssertTrue(used.contains("KHR_materials_emissive_strength"))

        let parts = try GLTFImporter.parts(from: glb, isBinary: true,
                                           siblings: [:], unitScale: 1)
        let imported = try XCTUnwrap(parts.first?.material)
        XCTAssertEqual(imported.emissiveStrength ?? -1, 2.5, accuracy: 1e-9)
    }

    // MARK: - Opacity packing

    func testOpacityPackingKeepsBaseRGBWhileCombiningAlpha() throws {
        // 2×2 RGBA with transparency: alpha 255, 128, 64, 192.
        let basePixels: [UInt8] = [
            200, 100, 50, 255,
            10, 20, 30, 128,
            255, 0, 128, 64,
            40, 80, 120, 192,
        ]
        let basePNG = png(width: 2, height: 2, straightRGBA: basePixels)
        let opacityValues: [UInt8] = [255, 128, 64, 32]
        var opacityPixels = [UInt8]()
        for value in opacityValues {
            opacityPixels += [value, value, value, 255]
        }
        let opacityPNG = png(width: 2, height: 2, straightRGBA: opacityPixels)
        let factor: Double = 0.5
        let factorByte = Int((factor * 255).rounded())

        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 0.5,
            baseColorTexture: basePNG, materialName: "Packed Opacity",
            opacity: factor, opacityTexture: opacityPNG)
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let (json, bin) = try glbChunks(glb)
        let exported = try material(named: "Packed Opacity", in: json)
        let pbr = try XCTUnwrap(exported["pbrMetallicRoughness"] as? [String: Any])
        let factorArray = try XCTUnwrap(pbr["baseColorFactor"] as? [Double])
        XCTAssertEqual(factorArray.count, 4)
        XCTAssertEqual(factorArray[3], 1.0, accuracy: 1e-9,
                       "the packed alpha owns the opacity; alphaMode supplies the scalar")
        XCTAssertEqual(exported["alphaMode"] as? String, "BLEND")

        let index = try textureIndex(exported, key: "baseColorTexture")
        let packed = try decodedRGBA(try imageData(json: json, bin: bin,
                                                   textureIndex: index))
        let source = try decodedRGBA(basePNG)
        let opacity = try decodedRGBA(opacityPNG)
        XCTAssertEqual(packed.width, 2)
        XCTAssertEqual(packed.height, 2)
        for pixel in 0..<4 {
            let base = pixel * 4
            // RGB must stay the base colour even though alpha changes.
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(
                    abs(Int(packed.pixels[base + channel])
                        - Int(source.pixels[base + channel])), 4,
                    "8-bit premultiplication must not shift the base RGB")
            }
            let expectedAlpha = Int((Double(source.pixels[base + 3])
                                     * Double(luminance(opacity.pixels, pixel))
                                     * Double(factorByte) / (255.0 * 255.0)).rounded())
            XCTAssertLessThanOrEqual(
                abs(Int(packed.pixels[base + 3]) - expectedAlpha), 1,
                "alpha = albedo alpha × opacity map × factor")
        }
    }

    func testDeclaredColorSpacesAreConvertedToGLTFTargetSpaces() throws {
        // A scalar map declared sRGB is linearised before packing (glTF MR is
        // linear), and a colour map declared linear is sRGB-encoded (glTF
        // baseColor is sRGB). Metadata itself has no glTF field; the exported
        // code values are what preserve the material's meaning.
        let scalar = grayPNG(128)
        let linearBase = png(width: 2, height: 2, straightRGBA: [
            128, 128, 128, 255, 128, 128, 128, 255,
            128, 128, 128, 255, 128, 128, 128, 255,
        ])
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 1,
            baseColorTexture: linearBase, materialName: "Color Spaces",
            roughnessTexture: scalar,
            textureMetadata: [
                metadata(slot: .baseColor, data: linearBase,
                         colorSpace: .linear),
                metadata(slot: .roughness, data: scalar,
                         colorSpace: .srgb),
            ])
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let (json, bin) = try glbChunks(glb)
        let exported = try material(named: "Color Spaces", in: json)
        let pbr = try XCTUnwrap(exported["pbrMetallicRoughness"] as? [String: Any])

        let baseIndex = try textureIndex(exported, key: "baseColorTexture")
        let base = try decodedRGBA(try imageData(json: json, bin: bin,
                                                 textureIndex: baseIndex))
        // linearToSRGB(128/255) ≈ 0.7355 → 188.
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(base.pixels[channel]) - 188), 2)
        }
        XCTAssertEqual(base.pixels[3], 255)

        let mrIndex = try textureIndex(exported, key: "metallicRoughnessTexture")
        let packed = try decodedRGBA(try imageData(json: json, bin: bin,
                                                   textureIndex: mrIndex))
        // srgbToLinear(128/255) ≈ 0.2159 → 55.
        XCTAssertLessThanOrEqual(abs(Int(packed.pixels[1]) - 55), 2)
        XCTAssertEqual(packed.pixels[2], 255, "missing metallic channel is white")

        let parts = try GLTFImporter.parts(from: glb, isBinary: true,
                                           siblings: [:], unitScale: 1)
        let imported = try XCTUnwrap(parts.first?.material)
        let importedBase = try XCTUnwrap(
            imported.textureMetadata?.first { $0.slot == .baseColor })
        let importedRoughness = try XCTUnwrap(
            imported.textureMetadata?.first { $0.slot == .roughness })
        XCTAssertEqual(importedBase.colorSpace, MaterialTextureColorSpace.srgb)
        XCTAssertEqual(importedRoughness.colorSpace, MaterialTextureColorSpace.linear)
    }

    // MARK: - Import round-trip

    func testPackedMetallicRoughnessReimportsIntoCanonicalSlots() throws {
        let rough = grayPNG(64)
        let metal = grayPNG(128)
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0.7, roughness: 0.2,
            materialName: "Round Trip",
            roughnessTexture: rough, metallicTexture: metal,
            textureMetadata: [
                metadata(slot: .roughness, data: rough, colorSpace: .linear),
                metadata(slot: .metallic, data: metal, colorSpace: .linear),
            ])
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let parts = try GLTFImporter.parts(from: glb, isBinary: true,
                                           siblings: [:], unitScale: 1)
        let imported = try XCTUnwrap(parts.first)
        let spec = try XCTUnwrap(imported.material)
        XCTAssertEqual(spec.metallic, 0.7, accuracy: 1e-9)
        XCTAssertEqual(spec.roughness, 0.2, accuracy: 1e-9)
        let roughnessData = try XCTUnwrap(spec.roughnessTexture,
                                          "packed G must become roughnessTexture")
        let metallicData = try XCTUnwrap(spec.metallicTexture,
                                         "packed B must become metallicTexture")
        let roughness = try decodedRGBA(roughnessData)
        let metallic = try decodedRGBA(metallicData)
        for pixel in 0..<4 {
            XCTAssertEqual(roughness.pixels[pixel * 4], 64)
            XCTAssertEqual(roughness.pixels[pixel * 4 + 1], 64)
            XCTAssertEqual(roughness.pixels[pixel * 4 + 2], 64)
            XCTAssertEqual(roughness.pixels[pixel * 4 + 3], 255)
            XCTAssertEqual(metallic.pixels[pixel * 4], 128)
            XCTAssertEqual(metallic.pixels[pixel * 4 + 1], 128)
            XCTAssertEqual(metallic.pixels[pixel * 4 + 2], 128)
            XCTAssertEqual(metallic.pixels[pixel * 4 + 3], 255)
        }
        let metadata = spec.textureMetadata ?? []
        let roughnessMetadata = try XCTUnwrap(metadata.first { $0.slot == .roughness })
        let metallicMetadata = try XCTUnwrap(metadata.first { $0.slot == .metallic })
        XCTAssertEqual(roughnessMetadata.colorSpace, MaterialTextureColorSpace.linear)
        XCTAssertEqual(metallicMetadata.colorSpace, MaterialTextureColorSpace.linear)

        // Re-exporting the imported material must preserve factor × map.
        var reimportedBody = makeBody(material: spec)
        reimportedBody.render = imported.mesh
        let second = GLBExporter.glb(bodies: [reimportedBody])
        let (json, bin) = try glbChunks(second)
        let exported = try material(named: "Round Trip", in: json)
        let pbr = try XCTUnwrap(exported["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual(pbr["metallicFactor"] as? Double ?? -1, 0.7, accuracy: 1e-9)
        XCTAssertEqual(pbr["roughnessFactor"] as? Double ?? -1, 0.2, accuracy: 1e-9)
        let index = try textureIndex(exported, key: "metallicRoughnessTexture")
        let packed = try decodedRGBA(try imageData(json: json, bin: bin,
                                                   textureIndex: index))
        for pixel in 0..<4 {
            XCTAssertEqual(packed.pixels[pixel * 4 + 1], 64)
            XCTAssertEqual(packed.pixels[pixel * 4 + 2], 128)
        }
    }

    func testBottomUpOrientationUsesTextureTransformAndReimports() throws {
        let basePNG = png(width: 2, height: 2, straightRGBA: [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255,
        ])
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 0.5,
            baseColorTexture: basePNG, materialName: "Bottom Up",
            textureMetadata: [
                metadata(slot: .baseColor, data: basePNG,
                         colorSpace: .srgb, orientation: .bottomLeft),
            ])
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        let (json, _) = try glbChunks(glb)
        let exported = try material(named: "Bottom Up", in: json)
        let pbr = try XCTUnwrap(exported["pbrMetallicRoughness"] as? [String: Any])
        let info = try XCTUnwrap(pbr["baseColorTexture"] as? [String: Any])
        let extensions = try XCTUnwrap(info["extensions"] as? [String: Any])
        let transform = try XCTUnwrap(
            extensions["KHR_texture_transform"] as? [String: Any])
        assertClose(try XCTUnwrap(transform["scale"] as? [Double]), [1, -1])
        assertClose(try XCTUnwrap(transform["offset"] as? [Double]), [0, 1])
        let used = (json["extensionsUsed"] as? [String]) ?? []
        XCTAssertTrue(used.contains("KHR_texture_transform"))

        let parts = try GLTFImporter.parts(from: glb, isBinary: true,
                                           siblings: [:], unitScale: 1)
        let imported = try XCTUnwrap(parts.first?.material)
        let base = try XCTUnwrap(
            imported.textureMetadata?.first { $0.slot == .baseColor })
        XCTAssertEqual(base.orientation, MaterialTextureOrientation.bottomLeft)
        XCTAssertEqual(base.colorSpace, MaterialTextureColorSpace.srgb)
    }

    // MARK: - Bounded decode

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// A normal small PNG with a deliberately oversized (but CRC-valid) IHDR:
    /// ImageIO can report 100000×100000 from the header, so the exporter must
    /// reject it from metadata before creating a CGImage.
    private func oversizedHeaderPNG() -> Data {
        var bytes = [UInt8](grayPNG(128))
        XCTAssertEqual(Array(bytes[12..<16]), Array("IHDR".utf8))
        let width = [UInt8](bigEndian(100_000))
        let height = [UInt8](bigEndian(100_000))
        bytes.replaceSubrange(16..<20, with: width)
        bytes.replaceSubrange(20..<24, with: height)
        let crc = crc32(Array(bytes[12..<29]))
        bytes.replaceSubrange(29..<33, with: bigEndian(crc))
        // The fixture itself is an oversized header, independent of ImageIO.
        XCTAssertEqual(Array(bytes[16..<20]), width)
        XCTAssertEqual(Array(bytes[20..<24]), height)
        return Data(bytes)
    }

    func testOversizedImageHeaderIsRejectedWithoutFailingExport() throws {
        let huge = oversizedHeaderPNG()
        let appearance = BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0.5, roughness: 0.4,
            materialName: "Bounded Decode",
            emissive: SIMD3(0.2, 0.3, 0.4), emissiveStrength: 1,
            roughnessTexture: grayPNG(64),
            metallicTexture: huge,
            normalTexture: huge,
            emissiveTexture: Data([0x89, 0x50, 0x4E, 0x47]))
        let glb = GLBExporter.glb(bodies: [makeBody(material: appearance)])
        XCTAssertLessThan(glb.count, 2 * 1024 * 1024,
                          "a compressed oversized header must not become a huge GLB")
        let (json, bin) = try glbChunks(glb)
        let exported = try material(named: "Bounded Decode", in: json)
        let pbr = try XCTUnwrap(exported["pbrMetallicRoughness"] as? [String: Any])
        XCTAssertEqual(pbr["metallicFactor"] as? Double ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(pbr["roughnessFactor"] as? Double ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertNil(exported["normalTexture"],
                     "a direct map with an oversized header is omitted, not embedded")
        XCTAssertNotNil(exported["emissiveFactor"],
                        "emission factor survives a malformed emissive map")
        XCTAssertNil(exported["emissiveTexture"],
                     "a malformed emissive map is omitted, not embedded")

        // The valid roughness channel still exports; the rejected metallic
        // map becomes the missing-channel white identity, not an allocation.
        let index = try textureIndex(exported, key: "metallicRoughnessTexture")
        let decoded = try decodedRGBA(try imageData(json: json, bin: bin,
                                                    textureIndex: index))
        for pixel in 0..<4 {
            XCTAssertEqual(decoded.pixels[pixel * 4 + 1], 64)
            XCTAssertEqual(decoded.pixels[pixel * 4 + 2], 255)
        }
    }
}
