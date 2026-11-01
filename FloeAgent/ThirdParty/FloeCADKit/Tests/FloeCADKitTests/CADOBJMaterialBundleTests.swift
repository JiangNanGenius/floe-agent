//
//  CADOBJMaterialBundleTests.swift
//  FloeCADKitTests
//
//  Independent readers for the native OBJ-with-materials bundle:
//    * a stored-ZIP reader that verifies every local header, CRC32, size,
//      central-directory binding and safe relative entry name;
//    * a small Wavefront OBJ reader that resolves v/vt/vn indices;
//    * a small MTL reader that reads newmtl blocks and their values;
//    * ImageIO pixel reads for the actual exported texture bytes.
//
//  No test calls OBJExporter/OBJBundleExporter to validate its own output.
//  Every ZIP/OBJ/MTL expectation below is derived independently from the
//  fixture geometry/material values. Real archives are attached to the test
//  result for later independent viewer/Blender/ModelIO inspection.
//

import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import FloeCAD

// MARK: - Fixtures and independent readers

private enum OBJFixture {
    static func png(_ bytes: [UInt8], width: Int = 1, height: Int = 1) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    static func metadata(slot: MaterialTextureSlot, data: Data,
                         colorSpace: MaterialTextureColorSpace = .srgb,
                         orientation: MaterialTextureOrientation = .topLeft)
        -> CADMaterialTextureMetadata {
        CADMaterialTextureMetadata(
            assetID: UUID(), slot: slot, mimeType: "image/png",
            colorSpace: colorSpace, orientation: orientation,
            sha256: CADMaterialTexture.digest(data), byteCount: data.count)
    }

    static func triangle(uv: Bool = false,
                         material: BodyMaterialSpec? = nil) -> Body {
        let mesh = RenderMesh(
            positions: [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 20, 0)],
            normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: 3),
            indices: [0, 1, 2],
            texcoords: uv
                ? [SIMD2<Float>(0.1, 0.2), SIMD2<Float>(0.9, 0.2), SIMD2<Float>(0.1, 0.8)]
                : nil)
        var body = Body(id: BodyID(), name: "Triangle", transform: .identity,
                        primitive: nil, render: mesh, revision: 1)
        body.material = material
        return body
    }
}

private struct ZipEntry {
    var path: String
    var data: Data
    var crc: UInt32
    var localOffset: Int
}

/// Independent STORED-ZIP reader. It asserts the actual CRC and the central
/// directory binding; it is not the production `MinimalZipWriter` validating
/// itself.
private func readStoredZip(_ archive: Data,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> [String: ZipEntry] {
    let bytes = [UInt8](archive)
    func u16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else {
            throw NSError(domain: "TruncatedZIP", code: 1)
        }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
    }
    func u32(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else {
            throw NSError(domain: "TruncatedZIP", code: 2)
        }
        return Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            | (Int(bytes[offset + 2]) << 16) | (Int(bytes[offset + 3]) << 24)
    }
    var cursor = 0
    var entries: [String: ZipEntry] = [:]
    var localOrder: [String] = []
    while cursor + 4 <= bytes.count, try u32(cursor) == 0x0403_4B50 {
        let localStart = cursor
        XCTAssertEqual(try u16(cursor + 6) & 8, 0, "entry flags must declare sizes", file: file, line: line)
        XCTAssertEqual(try u16(cursor + 8), 0, "entries must be STORED", file: file, line: line)
        let crc = UInt32(try u32(cursor + 14))
        let size = try u32(cursor + 18)
        XCTAssertEqual(try u32(cursor + 22), size, "compressed size must equal size for STORED", file: file, line: line)
        let nameLength = try u16(cursor + 26)
        let extraLength = try u16(cursor + 28)
        let nameStart = cursor + 30
        let payloadStart = nameStart + nameLength + extraLength
        guard payloadStart + size <= bytes.count else {
            throw NSError(domain: "TruncatedZIP", code: 3)
        }
        let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
        XCTAssertFalse(name.hasPrefix("/"), file: file, line: line)
        XCTAssertFalse(name.contains("\\"), file: file, line: line)
        XCTAssertFalse(name.contains(".."), file: file, line: line)
        XCTAssertTrue(name.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value < 127 },
                      "resource names must be ASCII", file: file, line: line)
        let payload = Data(bytes[payloadStart..<(payloadStart + size)])
        XCTAssertEqual(MinimalZipWriter.crc32(payload), crc,
                       "CRC mismatch for \(name)", file: file, line: line)
        entries[name] = ZipEntry(path: name, data: payload, crc: crc,
                                 localOffset: localStart)
        localOrder.append(name)
        cursor = payloadStart + size
    }
    XCTAssertEqual(try u32(cursor), 0x0201_4B50,
                   "local entries must end at the central directory", file: file, line: line)
    var centralNames: [String] = []
    while cursor + 4 <= bytes.count, try u32(cursor) == 0x0201_4B50 {
        let crc = UInt32(try u32(cursor + 16))
        let size = try u32(cursor + 20)
        let nameLength = try u16(cursor + 28)
        let extraLength = try u16(cursor + 30)
        let commentLength = try u16(cursor + 32)
        let offset = try u32(cursor + 42)
        let nameStart = cursor + 46
        let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
        guard let local = entries[name] else {
            XCTFail("central directory names an unread entry \(name)", file: file, line: line)
            break
        }
        XCTAssertEqual(local.localOffset, offset, file: file, line: line)
        XCTAssertEqual(local.crc, crc, file: file, line: line)
        XCTAssertEqual(local.data.count, size, file: file, line: line)
        centralNames.append(name)
        cursor = nameStart + nameLength + extraLength + commentLength
    }
    XCTAssertEqual(centralNames, localOrder, "central directory order/names", file: file, line: line)
    XCTAssertEqual(try u32(cursor), 0x0605_4B50, "end of central directory", file: file, line: line)
    XCTAssertEqual(try u16(cursor + 10), localOrder.count, file: file, line: line)
    return entries
}

private struct ParsedFace {
    var material: String?
    var vertices: [Int]      // 1-based
    var uvs: [Int]           // 1-based, empty when absent
    var normals: [Int]       // 1-based
}

private struct ParsedOBJ {
    var positions: [SIMD3<Double>] = []
    var normals: [SIMD3<Double>] = []
    var uvs: [SIMD2<Double>] = []
    var faces: [ParsedFace] = []
    var objects: [String] = []
    var hasMTLLib = false
}

private func parseOBJ(_ text: String,
                      file: StaticString = #filePath,
                      line: UInt = #line) throws -> ParsedOBJ {
    var result = ParsedOBJ()
    var currentMaterial: String?
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let lineText = rawLine.trimmingCharacters(in: .whitespaces)
        guard !lineText.isEmpty, !lineText.hasPrefix("#") else { continue }
        let parts = lineText.split(separator: " ", omittingEmptySubsequences: true)
        guard let keyword = parts.first else { continue }
        switch keyword {
        case "v":
            XCTAssertEqual(parts.count, 4, file: file, line: line)
            result.positions.append(SIMD3(Double(String(parts[1])) ?? .nan,
                                          Double(String(parts[2])) ?? .nan,
                                          Double(String(parts[3])) ?? .nan))
        case "vn":
            XCTAssertEqual(parts.count, 4, file: file, line: line)
            result.normals.append(SIMD3(Double(String(parts[1])) ?? .nan,
                                        Double(String(parts[2])) ?? .nan,
                                        Double(String(parts[3])) ?? .nan))
        case "vt":
            XCTAssertEqual(parts.count, 3, file: file, line: line)
            result.uvs.append(SIMD2(Double(String(parts[1])) ?? .nan,
                                    Double(String(parts[2])) ?? .nan))
        case "f":
            var vertices: [Int] = []
            var uvs: [Int] = []
            var normals: [Int] = []
            for token in parts.dropFirst() {
                let fields = token.split(separator: "/", omittingEmptySubsequences: false)
                XCTAssertEqual(fields.count, 3, file: file, line: line)
                let v = try XCTUnwrap(Int(String(fields[0])), file: file, line: line)
                XCTAssertGreaterThan(v, 0, file: file, line: line)
                XCTAssertLessThanOrEqual(v, result.positions.count, file: file, line: line)
                vertices.append(v)
                if fields.count > 1, !fields[1].isEmpty {
                    let t = try XCTUnwrap(Int(String(fields[1])), file: file, line: line)
                    XCTAssertGreaterThan(t, 0, file: file, line: line)
                    XCTAssertLessThanOrEqual(t, result.uvs.count, file: file, line: line)
                    uvs.append(t)
                }
                if fields.count > 2, !fields[2].isEmpty {
                    let n = try XCTUnwrap(Int(String(fields[2])), file: file, line: line)
                    XCTAssertGreaterThan(n, 0, file: file, line: line)
                    XCTAssertLessThanOrEqual(n, result.normals.count, file: file, line: line)
                    normals.append(n)
                }
            }
            XCTAssertEqual(vertices.count, 3, file: file, line: line)
            result.faces.append(ParsedFace(material: currentMaterial,
                                           vertices: vertices,
                                           uvs: uvs,
                                           normals: normals))
        case "usemtl":
            XCTAssertEqual(parts.count, 2, file: file, line: line)
            currentMaterial = String(parts[1])
        case "o":
            result.objects.append(parts.dropFirst().joined(separator: " "))
        case "mtllib":
            result.hasMTLLib = true
        default:
            break
        }
    }
    return result
}

private struct ParsedMTLMaterial {
    var name: String
    var values: [String: [String]] = [:]
}

private func parseMTL(_ text: String) -> [ParsedMTLMaterial] {
    var result: [ParsedMTLMaterial] = []
    var current: ParsedMTLMaterial?
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let lineText = rawLine.trimmingCharacters(in: .whitespaces)
        guard !lineText.isEmpty, !lineText.hasPrefix("#") else { continue }
        let parts = lineText.split(separator: " ", maxSplits: 1,
                                   omittingEmptySubsequences: true).map(String.init)
        guard let key = parts.first else { continue }
        let value = parts.count > 1 ? parts[1] : ""
        if key == "newmtl" {
            if let current { result.append(current) }
            current = ParsedMTLMaterial(name: value)
        } else if current != nil {
            current!.values[key, default: []].append(value)
        }
    }
    if let current { result.append(current) }
    return result
}

private func decodePNG(_ data: Data,
                       file: StaticString = #filePath,
                       line: UInt = #line) throws -> (width: Int, height: Int, pixels: [UInt8]) {
    let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil), file: file, line: line)
    let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    XCTAssertTrue(drew, file: file, line: line)
    // Recover straight RGBA for exact comparisons.
    var offset = 0
    while offset < pixels.count {
        let alpha = Int(pixels[offset + 3])
        if alpha == 0 {
            pixels[offset] = 0
            pixels[offset + 1] = 0
            pixels[offset + 2] = 0
        } else if alpha < 255 {
            for channel in 0..<3 {
                let value = Int(pixels[offset + channel]) * 255
                pixels[offset + channel] = UInt8(min(255, (value + alpha / 2) / alpha))
            }
        }
        offset += 4
    }
    return (image.width, image.height, pixels)
}

private func mapPath(_ material: ParsedMTLMaterial, _ key: String) -> String? {
    material.values[key]?.first
}

private func faceIndicesByMaterial(_ obj: ParsedOBJ, _ material: String) -> [[Int]] {
    obj.faces.filter { $0.material == material }.map(\.vertices)
}

private func attachment(_ data: Data, name: String) -> XCTAttachment {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.zip-archive")
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
}

private func textAttachment(_ text: String, name: String) -> XCTAttachment {
    let attachment = XCTAttachment(string: text)
    attachment.name = name
    attachment.lifetime = .keepAlways
    return attachment
}

// MARK: - Six-map bundle

final class CADOBJMaterialBundleTests: XCTestCase {
    func testSixMapBundleIsSelfContainedWithRealOBJMTLUVsAndTextureBytes() throws {
        let baseBytes = try OBJFixture.png(
            [255, 0, 0, 255, 0, 0, 255, 255], width: 1, height: 2)
        let metallicBytes = try OBJFixture.png([64, 64, 64, 255])
        let roughnessBytes = try OBJFixture.png([192, 192, 192, 255])
        let normalBytes = try OBJFixture.png([128, 128, 255, 255])
        let emissiveBytes = try OBJFixture.png([0, 255, 0, 255])
        let opacityBytes = try OBJFixture.png([128, 128, 128, 255])

        let spec = BodyMaterialSpec(
            baseColor: SIMD4(0.2, 0.4, 0.6, 1),
            metallic: 0.75,
            roughness: 0.25,
            baseColorTexture: baseBytes,
            materialName: "Six Maps",
            opacity: 0.5,
            emissive: SIMD3(0.5, 0.25, 0.125),
            emissiveStrength: 0.5,
            roughnessTexture: roughnessBytes,
            metallicTexture: metallicBytes,
            normalTexture: normalBytes,
            emissiveTexture: emissiveBytes,
            opacityTexture: opacityBytes,
            textureMetadata: [
                OBJFixture.metadata(slot: .baseColor, data: baseBytes,
                                    colorSpace: .srgb, orientation: .bottomLeft),
                OBJFixture.metadata(slot: .metallic, data: metallicBytes,
                                    colorSpace: .linear),
                OBJFixture.metadata(slot: .roughness, data: roughnessBytes,
                                    colorSpace: .linear),
                OBJFixture.metadata(slot: .normal, data: normalBytes,
                                    colorSpace: .linear),
                OBJFixture.metadata(slot: .emissive, data: emissiveBytes,
                                    colorSpace: .srgb),
                OBJFixture.metadata(slot: .opacity, data: opacityBytes,
                                    colorSpace: .linear),
            ])
        var body = OBJFixture.triangle(uv: true, material: spec)
        body.transform.translation = SIMD3(1, 2, 3)
        body.transform.scale = 2
        body.transform.rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let sourceUVs = body.render.texcoords
        let sourceMaterial = body.material

        let result = OBJBundleExporter.export(bodies: [body])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let archive = try XCTUnwrap(result.data)
        let receipt = try XCTUnwrap(result.receipt)
        let entries = try readStoredZip(archive)
        XCTAssertEqual(Set(entries.keys),
                       Set(["model.obj", "model.mtl"] + receipt.textures.map(\.path)))
        XCTAssertEqual(receipt.entries.count, 8)
        XCTAssertEqual(receipt.textures.count, 6)
        XCTAssertEqual(receipt.materials.count, 1)
        XCTAssertEqual(receipt.bodies.count, 1)
        XCTAssertEqual(receipt.triangleCount, 1)
        XCTAssertEqual(receipt.vertexCount, 3)
        XCTAssertEqual(receipt.bundleSHA256, CADMaterialTexture.digest(archive))
        XCTAssertEqual(receipt.totalBytes,
                       receipt.entries.reduce(0) { $0 + $1.byteCount })

        let objData = try XCTUnwrap(entries["model.obj"]).data
        let mtlData = try XCTUnwrap(entries["model.mtl"]).data
        let objText = String(decoding: objData, as: UTF8.self)
        let mtlText = String(decoding: mtlData, as: UTF8.self)
        add(textAttachment(objText, name: "OBJBundle-six-maps.obj"))
        add(textAttachment(mtlText, name: "OBJBundle-six-maps.mtl"))
        add(attachment(archive, name: "OBJBundle-six-maps.zip"))

        let obj = try parseOBJ(objText)
        XCTAssertTrue(obj.hasMTLLib)
        XCTAssertEqual(obj.objects, ["Triangle"])
        XCTAssertEqual(obj.positions.count, 3)
        XCTAssertEqual(obj.normals.count, 3)
        XCTAssertEqual(obj.uvs.count, 3)
        // Independent world-space arithmetic for the placed triangle.
        let expectedPositions: [SIMD3<Double>] = [
            SIMD3(1, 2, 3), SIMD3(1, 22, 3), SIMD3(-39, 2, 3),
        ]
        for expected in expectedPositions {
            XCTAssertTrue(obj.positions.contains {
                simd_distance($0, expected) < 1e-5
            }, "missing world-space vertex \(expected), got \(obj.positions)")
        }
        for normal in obj.normals {
            XCTAssertEqual(normal.z, 1, accuracy: 1e-6)
            XCTAssertEqual(normal.x, 0, accuracy: 1e-6)
            XCTAssertEqual(normal.y, 0, accuracy: 1e-6)
        }
        let expectedUVs: [SIMD2<Double>] = [
            SIMD2(0.1, 0.8), SIMD2(0.9, 0.8), SIMD2(0.1, 0.2),
        ]
        for expected in expectedUVs {
            XCTAssertTrue(obj.uvs.contains {
                abs($0.x - expected.x) < 1e-6 && abs($0.y - expected.y) < 1e-6
            }, "missing bottom-left vt \(expected), got \(obj.uvs)")
        }
        XCTAssertEqual(obj.faces.count, 1)
        XCTAssertEqual(obj.faces[0].vertices.count, 3)
        XCTAssertEqual(obj.faces[0].uvs.count, 3)
        XCTAssertEqual(obj.faces[0].normals.count, 3)

        let materials = parseMTL(mtlText)
        XCTAssertEqual(materials.count, 1)
        let material = materials[0]
        XCTAssertEqual(material.values["Kd"]?.first ?? "", "0.200000 0.400000 0.600000")
        XCTAssertEqual(material.values["Pr"]?.first ?? "", "0.250000")
        XCTAssertEqual(material.values["Pm"]?.first ?? "", "0.750000")
        XCTAssertEqual(material.values["d"]?.first ?? "", "1.000000",
                       "a mapped opacity mask bakes the authored d scalar")
        XCTAssertEqual(material.values["Ke"]?.first ?? "", "0.250000 0.125000 0.062500")
        XCTAssertEqual(material.values["illum"]?.first ?? "", "2")
        XCTAssertEqual(obj.faces[0].material, material.name)

        let mapKeys = ["map_Kd", "map_Pr", "map_Pm", "map_Ke", "norm", "map_d"]
        for key in mapKeys {
            let path = try XCTUnwrap(mapPath(material, key), "missing \(key)")
            XCTAssertTrue(path.hasPrefix("textures/"), "relative texture path")
            XCTAssertTrue(entries[path] != nil, "MTL references a missing ZIP entry \(path)")
        }
        XCTAssertEqual(Set(receipt.textures.map(\.path)),
                       Set(mapKeys.compactMap { mapPath(material, $0) }))
        for texture in receipt.textures {
            let entry = try XCTUnwrap(entries[texture.path])
            XCTAssertEqual(texture.sha256, CADMaterialTexture.digest(entry.data))
            XCTAssertEqual(texture.byteCount, entry.data.count)
        }

        // The base map is bottom-left authored: exported rows are flipped.
        let basePath = try XCTUnwrap(mapPath(material, "map_Kd"))
        let basePixels = try decodePNG(try XCTUnwrap(entries[basePath]).data)
        XCTAssertEqual(basePixels.width, 1)
        XCTAssertEqual(basePixels.height, 2)
        XCTAssertEqual(Array(basePixels.pixels.prefix(4)), [0, 0, 255, 255])
        XCTAssertEqual(Array(basePixels.pixels[4..<8]), [255, 0, 0, 255])

        // Top-left grayscale/linear scalars and the normal/emissive maps keep
        // their authored bytes exactly.
        for (key, original) in [("map_Pr", roughnessBytes),
                                ("map_Pm", metallicBytes),
                                ("norm", normalBytes),
                                ("map_Ke", emissiveBytes)] {
            let path = try XCTUnwrap(mapPath(material, key))
            XCTAssertEqual(try XCTUnwrap(entries[path]).data, original,
                           "\(key) must preserve the authored bytes")
        }

        let opacityPath = try XCTUnwrap(mapPath(material, "map_d"))
        let opacityPixels = try decodePNG(try XCTUnwrap(entries[opacityPath]).data)
        XCTAssertEqual(opacityPixels.width, 1)
        XCTAssertEqual(opacityPixels.height, 1)
        // 128/255 opacity luminance × authored d 0.5, in both RGB and alpha.
        XCTAssertEqual(Array(opacityPixels.pixels.prefix(4)), [64, 64, 64, 64])
        XCTAssertEqual(receipt.materials.first?.opacity ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(receipt.materials.first?.opacityMaskBaked, true)
        XCTAssertEqual(receipt.materials.first?.bakedOpacity ?? 0, 0.5, accuracy: 1e-9)
        let materialJSON = try XCTUnwrap(
            (receipt.jsonObject["materials"] as? [[String: Any]])?.first)
        XCTAssertEqual(materialJSON["opacity_mask_baked"] as? Bool, true)
        XCTAssertEqual(materialJSON["baked_opacity"] as? Double ?? 0, 0.5, accuracy: 1e-9)

        // Source data is never mutated by an export.
        XCTAssertEqual(body.render.texcoords, sourceUVs)
        XCTAssertEqual(body.material, sourceMaterial)

        XCTAssertTrue(receipt.warnings.contains("mtl_pbr_extension"))
        XCTAssertTrue(receipt.warnings.contains("obj_uv_bottom_left"))
        XCTAssertTrue(receipt.warnings.contains("texture_rows_or_color_normalized"))
        XCTAssertTrue(receipt.warnings.contains("opacity_map_semantics"))
        XCTAssertFalse(receipt.warnings.contains("base_alpha_baked_to_map_d"))
    }

    func testRepeatedExportIsByteStable() throws {
        let base = try OBJFixture.png([255, 0, 0, 255])
        var spec = BodyMaterialSpec(baseColor: SIMD4(repeating: 1),
                                    baseColorTexture: base,
                                    materialName: "Stable")
        spec.textureMetadata = [OBJFixture.metadata(slot: .baseColor, data: base)]
        let body = OBJFixture.triangle(uv: true, material: spec)
        let first = OBJBundleExporter.export(bodies: [body])
        let second = OBJBundleExporter.export(bodies: [body])
        XCTAssertTrue(first.succeeded, "\(first.diagnostics)")
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.receipt, second.receipt)
    }

    func testBaseAlphaAndOpacityMapBecomeOneMapD() throws {
        let base = try OBJFixture.png(
            [255, 0, 0, 128, 0, 255, 0, 255], width: 2, height: 1)
        let opacity = try OBJFixture.png([128, 128, 128, 255])
        var spec = BodyMaterialSpec(
            baseColor: SIMD4(repeating: 1),
            baseColorTexture: base,
            materialName: "Alpha",
            opacity: 0.5,
            opacityTexture: opacity)
        spec.textureMetadata = [
            OBJFixture.metadata(slot: .baseColor, data: base),
            OBJFixture.metadata(slot: .opacity, data: opacity, colorSpace: .linear),
        ]
        let body = OBJFixture.triangle(uv: true, material: spec)
        let result = OBJBundleExporter.export(bodies: [body])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let archive = try XCTUnwrap(result.data)
        let receipt = try XCTUnwrap(result.receipt)
        let entries = try readStoredZip(archive)
        let mtl = parseMTL(String(decoding: try XCTUnwrap(entries["model.mtl"]).data,
                                  as: UTF8.self))
        XCTAssertEqual(mtl.count, 1)
        XCTAssertEqual(mtl[0].values["d"]?.first ?? "", "1.000000",
                       "the authored d scalar is baked into map_d")
        XCTAssertTrue(receipt.warnings.contains("base_alpha_baked_to_map_d"))

        let basePath = try XCTUnwrap(mapPath(mtl[0], "map_Kd"))
        let basePixels = try decodePNG(try XCTUnwrap(entries[basePath]).data)
        XCTAssertEqual(basePixels.width, 2)
        XCTAssertEqual(basePixels.height, 1)
        XCTAssertEqual(Array(basePixels.pixels[0..<8]),
                       [255, 0, 0, 255, 0, 255, 0, 255],
                       "map_Kd must be flattened after alpha is baked into map_d")

        let opacityPath = try XCTUnwrap(mapPath(mtl[0], "map_d"))
        let opacityPixels = try decodePNG(try XCTUnwrap(entries[opacityPath]).data)
        XCTAssertEqual(opacityPixels.width, 2)
        XCTAssertEqual(opacityPixels.height, 1)
        // base alpha [128, 255] × opacity luminance 128 / 255 × authored d 0.5.
        // RGB and alpha must carry the same final mask value.
        XCTAssertEqual(Array(opacityPixels.pixels[0..<4]), [32, 32, 32, 32])
        XCTAssertEqual(Array(opacityPixels.pixels[4..<8]), [64, 64, 64, 64])
        XCTAssertEqual(receipt.materials.first?.opacityMaskBaked, true)
        XCTAssertEqual(receipt.materials.first?.bakedOpacity ?? 0, 0.5, accuracy: 1e-9)
    }

    func testScalarOpacityWithoutMaskKeepsDAndReportsNotBaked() throws {
        let base = try OBJFixture.png([255, 0, 0, 255])
        var spec = BodyMaterialSpec(
            baseColor: SIMD4(repeating: 1),
            baseColorTexture: base,
            materialName: "Scalar Opacity",
            opacity: 0.5)
        spec.textureMetadata = [OBJFixture.metadata(slot: .baseColor, data: base)]
        let body = OBJFixture.triangle(uv: true, material: spec)
        let result = OBJBundleExporter.export(bodies: [body])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let receipt = try XCTUnwrap(result.receipt)
        let entries = try readStoredZip(try XCTUnwrap(result.data))
        let mtl = parseMTL(String(decoding: try XCTUnwrap(entries["model.mtl"]).data,
                                  as: UTF8.self))
        XCTAssertEqual(mtl.count, 1)
        XCTAssertEqual(mtl[0].values["d"]?.first ?? "", "0.500000")
        XCTAssertNil(mapPath(mtl[0], "map_d"))
        XCTAssertEqual(receipt.materials.first?.opacity ?? 0, 0.5, accuracy: 1e-9)
        XCTAssertEqual(receipt.materials.first?.opacityMaskBaked, false)
        XCTAssertNil(receipt.materials.first?.bakedOpacity)
    }

    func testLinearBottomLeftColorIsFlippedAndEncodedToSRGB() throws {
        let base = try OBJFixture.png(
            [128, 128, 128, 255, 255, 255, 255, 255], width: 1, height: 2)
        var spec = BodyMaterialSpec(baseColor: SIMD4(repeating: 1),
                                    baseColorTexture: base,
                                    materialName: "Linear")
        spec.textureMetadata = [OBJFixture.metadata(
            slot: .baseColor, data: base,
            colorSpace: .linear, orientation: .bottomLeft)]
        let body = OBJFixture.triangle(uv: true, material: spec)
        let result = OBJBundleExporter.export(bodies: [body])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let entries = try readStoredZip(try XCTUnwrap(result.data))
        let mtl = parseMTL(String(decoding: try XCTUnwrap(entries["model.mtl"]).data,
                                  as: UTF8.self))
        let path = try XCTUnwrap(mapPath(mtl[0], "map_Kd"))
        let pixels = try decodePNG(try XCTUnwrap(entries[path]).data)
        XCTAssertEqual(pixels.width, 1)
        XCTAssertEqual(pixels.height, 2)
        XCTAssertEqual(Array(pixels.pixels[0..<4]), [255, 255, 255, 255])
        XCTAssertEqual(Double(pixels.pixels[4]), 188, accuracy: 1)
        XCTAssertEqual(Double(pixels.pixels[5]), 188, accuracy: 1)
        XCTAssertEqual(Double(pixels.pixels[6]), 188, accuracy: 1)
    }
}

// MARK: - Geometry-only OBJ

final class CADOBJGeometryOnlyTests: XCTestCase {
    func testPlainOBJHasUVsButNeverMaterials() throws {
        let texture = try OBJFixture.png([255, 0, 0, 255])
        var spec = BodyMaterialSpec(baseColor: SIMD4(repeating: 1),
                                    baseColorTexture: texture,
                                    materialName: "Painted")
        spec.textureMetadata = [OBJFixture.metadata(slot: .baseColor, data: texture)]
        let body = OBJFixture.triangle(uv: true, material: spec)
        let text = OBJExporter.obj(bodies: [body])
        XCTAssertTrue(text.contains("Geometry and UVs only"))
        XCTAssertFalse(text.contains("mtllib"))
        XCTAssertFalse(text.contains("usemtl"))
        let parsed = try parseOBJ(text)
        XCTAssertEqual(parsed.positions.count, 3)
        XCTAssertEqual(parsed.uvs.count, 3)
        XCTAssertEqual(parsed.faces.count, 1)
        XCTAssertEqual(parsed.faces[0].uvs, [1, 2, 3])
        XCTAssertEqual(parsed.faces[0].normals, [1, 2, 3])
        XCTAssertTrue(text.contains("f 1/1/1 2/2/2 3/3/3"))
        XCTAssertTrue(OBJExporter.materialLimitationNote.contains("no MTL"))
    }

    func testPlainOBJWithoutUVsUsesVSlashSlashVN() throws {
        let body = OBJFixture.triangle()
        let text = OBJExporter.obj(bodies: [body])
        let parsed = try parseOBJ(text)
        XCTAssertEqual(parsed.uvs.count, 0)
        XCTAssertEqual(parsed.faces.count, 1)
        XCTAssertEqual(parsed.faces[0].uvs.count, 0)
        XCTAssertTrue(text.contains("f 1//1 2//2 3//3"))
    }
}

// MARK: - Per-face material authority

@MainActor
final class CADOBJFaceMaterialTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADOBJFace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func run(_ document: FloeCADDocument, _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(json)")
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func makeBox(_ document: FloeCADDocument) throws -> Body {
        let sketch = try run(document, #"{"op":"sketch.create","args":{"name":"Box"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try run(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[40,20]}]}}
        """)
        _ = try run(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)","seedPoint":[20,10],
         "distance":10}}
        """)
        return try XCTUnwrap(document.session.document.bodies.first)
    }

    private func makeFaceMaterial(name: String,
                                  color: SIMD4<Double>,
                                  mapping: CADMaterialUVMapping) throws -> BodyMaterialSpec {
        let bytes = try OBJFixture.png([
            UInt8(color.x * 255), UInt8(color.y * 255), UInt8(color.z * 255), 255,
        ])
        return BodyMaterialSpec(
            baseColor: color,
            metallic: 0.25,
            roughness: 0.75,
            baseColorTexture: bytes,
            materialName: name,
            uvMapping: mapping,
            textureMetadata: [OBJFixture.metadata(slot: .baseColor, data: bytes)])
    }

    func testFreshTableUsesSignatureNotCapturedIndexAndPerFaceProjections() async throws {
        let url = workDir.appendingPathComponent("faces.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Faces")
        defer { document.close() }
        let source = try makeBox(document)
        let table = try XCTUnwrap(document.session.lastFaceTables[source.id])
        let entries = table.entries.filter { !$0.triangles.isEmpty }
        XCTAssertGreaterThanOrEqual(entries.count, 3)
        let entryA = entries[0]
        let entryB = entries[1]

        let materialA = try makeFaceMaterial(
            name: "Face A", color: SIMD4(0.9, 0.2, 0.1, 1),
            mapping: CADMaterialUVMapping(source: .planarProjection, axis: .z,
                                          scaleMM: SIMD2(20, 40),
                                          offset: SIMD2(0.1, 0.2)))
        let materialB = try makeFaceMaterial(
            name: "Face B", color: SIMD4(0.1, 0.2, 0.9, 1),
            mapping: CADMaterialUVMapping(source: .planarProjection, axis: .y,
                                          scaleMM: SIMD2(5, 5),
                                          offset: SIMD2(0.5, 0.5)))
        // capturedIndex is provenance only: deliberately wrong here.
        let bindingA = CADFaceMaterialBinding(
            key: CADFaceKey(signature: entryA.signature, capturedIndex: 999),
            material: materialA)
        let bindingB = CADFaceMaterialBinding(
            key: CADFaceKey(signature: entryB.signature, capturedIndex: 1),
            material: materialB)

        var candidate = source
        candidate.material = nil
        candidate.materialFaceBindings = [bindingA, bindingB]
        candidate.render.texcoords = nil

        let result = OBJBundleExporter.export(
            bodies: [candidate],
            faceTables: [candidate.id: table],
            faceTableRevisions: [candidate.id: candidate.meshRevision])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let entriesByPath = try readStoredZip(try XCTUnwrap(result.data))
        let obj = try parseOBJ(String(decoding: try XCTUnwrap(entriesByPath["model.obj"]).data,
                                      as: UTF8.self))
        let mtl = parseMTL(String(decoding: try XCTUnwrap(entriesByPath["model.mtl"]).data,
                                  as: UTF8.self))
        let nameA = try XCTUnwrap(mtl.first { $0.name.hasPrefix("Face_A_") }?.name)
        let nameB = try XCTUnwrap(mtl.first { $0.name.hasPrefix("Face_B_") }?.name)
        XCTAssertNotEqual(nameA, nameB)

        let facesA = obj.faces.filter { $0.material == nameA }
        let facesB = obj.faces.filter { $0.material == nameB }
        XCTAssertEqual(facesA.count, entryA.triangles.count)
        XCTAssertEqual(facesB.count, entryB.triangles.count)

        // The group's vertex set must be exactly the table entry's triangles,
        // not the face whose index the stale capture happened to name.
        func vertexSet(_ triangles: [Int]) -> Set<Int> {
            Set(triangles.flatMap { triangle in
                (0..<3).map { Int(candidate.render.indices[triangle * 3 + $0]) + 1 }
            })
        }
        XCTAssertEqual(Set(facesA.flatMap(\.vertices)), vertexSet(entryA.triangles))
        XCTAssertEqual(Set(facesB.flatMap(\.vertices)), vertexSet(entryB.triangles))
        XCTAssertNotEqual(vertexSet(entryA.triangles), vertexSet(entryB.triangles))

        // The OBJ has no authored mesh UVs here; each face group's vt values
        // must be the material's own projection. The identity body transform
        // makes the exported v row the body-local position.
        for face in facesA {
            for (corner, vertexIndex) in face.vertices.enumerated() {
                let p = obj.positions[vertexIndex - 1]
                let expectedU = p.x / 20.0 + 0.1
                let expectedV = p.y / 40.0 + 0.2
                let uv = obj.uvs[face.uvs[corner] - 1]
                XCTAssertEqual(uv.x, expectedU, accuracy: 1e-5)
                XCTAssertEqual(uv.y, 1.0 - expectedV, accuracy: 1e-5)
            }
        }
        for face in facesB {
            for (corner, vertexIndex) in face.vertices.enumerated() {
                let p = obj.positions[vertexIndex - 1]
                let expectedU = p.x / 5.0 + 0.5
                let expectedV = p.z / 5.0 + 0.5
                let uv = obj.uvs[face.uvs[corner] - 1]
                XCTAssertEqual(uv.x, expectedU, accuracy: 1e-5)
                XCTAssertEqual(uv.y, 1.0 - expectedV, accuracy: 1e-5)
            }
        }

        let report = try XCTUnwrap(result.receipt?.bodies.first)
        XCTAssertEqual(report.groups.filter { $0.faceIndex != nil }.count, 2)
        XCTAssertEqual(report.unresolvedFaceBindings.count, 0)
        XCTAssertTrue(report.groups.allSatisfy { $0.uvSource == "planarProjection" || $0.faceIndex == nil })
        XCTAssertFalse(result.receipt?.warnings.contains("face_material_fallback") == true)
    }

    func testStaleTableNeverPaintsAGuessedFaceRange() async throws {
        let url = workDir.appendingPathComponent("stale.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Stale")
        defer { document.close() }
        let source = try makeBox(document)
        let table = try XCTUnwrap(document.session.lastFaceTables[source.id])
        let entry = try XCTUnwrap(table.entries.first { !$0.triangles.isEmpty })
        let material = try makeFaceMaterial(
            name: "Face A", color: SIMD4(0.9, 0.2, 0.1, 1),
            mapping: CADMaterialUVMapping(source: .planarProjection, axis: .z,
                                          scaleMM: SIMD2(20, 40)))
        var candidate = source
        candidate.material = nil
        candidate.materialFaceBindings = [
            CADFaceMaterialBinding(key: CADFaceKey(signature: entry.signature),
                                   material: material)
        ]
        let result = OBJBundleExporter.export(
            bodies: [candidate],
            faceTables: [candidate.id: table],
            faceTableRevisions: [candidate.id: candidate.meshRevision &+ 1])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let entries = try readStoredZip(try XCTUnwrap(result.data))
        let mtl = parseMTL(String(decoding: try XCTUnwrap(entries["model.mtl"]).data,
                                  as: UTF8.self))
        XCTAssertFalse(mtl.contains { $0.name.hasPrefix("Face_A_") },
                       "a stale face range must fall back to the body material")
        let report = try XCTUnwrap(result.receipt?.bodies.first)
        XCTAssertEqual(report.unresolvedFaceBindings.count, 1)
        XCTAssertTrue(report.unresolvedFaceBindings[0].contains("face_triangle_table_unavailable"))
        XCTAssertTrue(result.receipt?.warnings.contains("face_material_fallback") == true)
    }

    func testOverlappingBindingsCannotClaimOneFaceTwice() async throws {
        let url = workDir.appendingPathComponent("overlap.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Overlap")
        defer { document.close() }
        let source = try makeBox(document)
        let table = try XCTUnwrap(document.session.lastFaceTables[source.id])
        let entry = try XCTUnwrap(table.entries.first { !$0.triangles.isEmpty })
        let material = try makeFaceMaterial(
            name: "Face A", color: SIMD4(0.9, 0.2, 0.1, 1),
            mapping: CADMaterialUVMapping(source: .planarProjection, axis: .z,
                                          scaleMM: SIMD2(20, 40)))
        let binding = CADFaceMaterialBinding(
            key: CADFaceKey(signature: entry.signature), material: material)
        var candidate = source
        candidate.material = nil
        candidate.materialFaceBindings = [binding, binding]
        let result = OBJBundleExporter.export(
            bodies: [candidate],
            faceTables: [candidate.id: table],
            faceTableRevisions: [candidate.id: candidate.meshRevision])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let entries = try readStoredZip(try XCTUnwrap(result.data))
        let obj = try parseOBJ(String(decoding: try XCTUnwrap(entries["model.obj"]).data,
                                      as: UTF8.self))
        let mtl = parseMTL(String(decoding: try XCTUnwrap(entries["model.mtl"]).data,
                                  as: UTF8.self))
        let name = try XCTUnwrap(mtl.first { $0.name.hasPrefix("Face_A_") }?.name)
        XCTAssertEqual(obj.faces.filter { $0.material == name }.count,
                       entry.triangles.count)
        let report = try XCTUnwrap(result.receipt?.bodies.first)
        XCTAssertEqual(report.unresolvedFaceBindings.count, 1)
        XCTAssertTrue(report.unresolvedFaceBindings[0]
            .contains("face_triangle_map_overlap_or_invalid"))
    }

    func testFreshTableMissingEntryIsASharedLossAndFallsBack() async throws {
        let url = workDir.appendingPathComponent("missing.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Missing")
        defer { document.close() }
        let source = try makeBox(document)
        let table = try XCTUnwrap(document.session.lastFaceTables[source.id])
        let entry = try XCTUnwrap(table.entries.first { !$0.triangles.isEmpty })
        let material = try makeFaceMaterial(
            name: "Face A", color: SIMD4(0.9, 0.2, 0.1, 1),
            mapping: CADMaterialUVMapping(source: .planarProjection, axis: .z,
                                          scaleMM: SIMD2(20, 40)))
        var candidate = source
        candidate.material = nil
        candidate.materialFaceBindings = [CADFaceMaterialBinding(
            key: CADFaceKey(signature: entry.signature), material: material)]
        // Fresh revision, but the exact face row is absent. This is the real
        // hole the old coverage missed: signature matching resolves, the table
        // does not.
        let missingTable = FaceTable(entries: table.entries.filter {
            $0.triangles != entry.triangles
        })
        let assessment = CADFaceMaterialResolver.assessGroups(
            in: candidate, table: missingTable,
            tableRevision: candidate.meshRevision)
        XCTAssertFalse(assessment.isLossless)
        XCTAssertEqual(assessment.issues.map(\.kind), [.missing])
        XCTAssertTrue(assessment.groups.isEmpty)

        let result = OBJBundleExporter.export(
            bodies: [candidate],
            faceTables: [candidate.id: missingTable],
            faceTableRevisions: [candidate.id: candidate.meshRevision])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        XCTAssertTrue(result.receipt?.warnings.contains("face_material_fallback") == true)
        let report = try XCTUnwrap(result.receipt?.bodies.first)
        XCTAssertEqual(report.unresolvedFaceBindings.count, 1)
        XCTAssertTrue(report.unresolvedFaceBindings[0]
            .contains("face_triangle_map_missing"))
    }

    func testSharedAssessmentReportsOverlapThatCoverageMustNotCallComplete() async throws {
        let url = workDir.appendingPathComponent("overlap-assess.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Overlap Assess")
        defer { document.close() }
        let source = try makeBox(document)
        let table = try XCTUnwrap(document.session.lastFaceTables[source.id])
        let entry = try XCTUnwrap(table.entries.first { !$0.triangles.isEmpty })
        let material = try makeFaceMaterial(
            name: "Face A", color: SIMD4(0.9, 0.2, 0.1, 1),
            mapping: CADMaterialUVMapping(source: .planarProjection, axis: .z,
                                          scaleMM: SIMD2(20, 40)))
        let binding = CADFaceMaterialBinding(
            key: CADFaceKey(signature: entry.signature), material: material)
        var candidate = source
        candidate.material = nil
        candidate.materialFaceBindings = [binding, binding]
        let assessment = CADFaceMaterialResolver.assessGroups(
            in: candidate, table: table,
            tableRevision: candidate.meshRevision)
        XCTAssertFalse(assessment.isLossless)
        XCTAssertEqual(assessment.issues.map(\.kind), [.overlapOrInvalid])
        XCTAssertEqual(assessment.groups.count, 1)
    }
}

// MARK: - Names, deduplication and per-body self-containment

final class CADOBJResourceTests: XCTestCase {
    func testDuplicateMaterialNamesStayDistinctAndCannotInjectMTL() throws {
        let red = try OBJFixture.png([255, 0, 0, 255])
        let blue = try OBJFixture.png([0, 0, 255, 255])
        var first = OBJFixture.triangle(uv: true, material: BodyMaterialSpec(
            baseColor: SIMD4(1, 0, 0, 1),
            baseColorTexture: red,
            materialName: "Steel\nnewmtl hacked"))
        first.material?.textureMetadata = [OBJFixture.metadata(slot: .baseColor, data: red)]
        first.name = "Bad\nObject"
        var second = OBJFixture.triangle(uv: true, material: BodyMaterialSpec(
            baseColor: SIMD4(0, 0, 1, 1),
            baseColorTexture: blue,
            materialName: "Steel\nnewmtl hacked"))
        second.material?.textureMetadata = [OBJFixture.metadata(slot: .baseColor, data: blue)]
        second.name = "Other"
        let result = OBJBundleExporter.export(bodies: [first, second])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let entries = try readStoredZip(try XCTUnwrap(result.data))
        let obj = try parseOBJ(String(decoding: try XCTUnwrap(entries["model.obj"]).data,
                                      as: UTF8.self))
        let mtl = parseMTL(String(decoding: try XCTUnwrap(entries["model.mtl"]).data,
                                  as: UTF8.self))
        XCTAssertEqual(mtl.count, 2)
        XCTAssertEqual(Set(mtl.map(\.name)).count, 2)
        for material in mtl {
            XCTAssertTrue(material.name.hasPrefix("Steel_newmtl_hacked_"))
            XCTAssertTrue(material.name.unicodeScalars.allSatisfy {
                ($0.value >= 48 && $0.value <= 57)
                    || ($0.value >= 65 && $0.value <= 90)
                    || ($0.value >= 97 && $0.value <= 122)
                    || $0.value == 95 || $0.value == 45 || $0.value == 46
            })
        }
        XCTAssertFalse(mtl.contains { $0.name == "hacked" })
        XCTAssertEqual(Set(obj.objects), Set(["Bad_Object", "Other"]))
        XCTAssertFalse(obj.objects.contains("Bad"))
    }

    func testIdenticalTextureBytesAreDeduplicatedAcrossSlots() throws {
        let gray = try OBJFixture.png([77, 77, 77, 255])
        var spec = BodyMaterialSpec(baseColor: SIMD4(repeating: 1),
                                    baseColorTexture: gray,
                                    materialName: "Shared",
                                    metallicTexture: gray)
        spec.textureMetadata = [
            OBJFixture.metadata(slot: .baseColor, data: gray),
            OBJFixture.metadata(slot: .metallic, data: gray, colorSpace: .linear),
        ]
        let body = OBJFixture.triangle(uv: true, material: spec)
        let result = OBJBundleExporter.export(bodies: [body])
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        let receipt = try XCTUnwrap(result.receipt)
        XCTAssertEqual(receipt.textures.count, 1)
        XCTAssertEqual(receipt.textures[0].slots, ["baseColor", "metallic"])
        XCTAssertEqual(receipt.entries.count, 3)
        let entries = try readStoredZip(try XCTUnwrap(result.data))
        let mtl = parseMTL(String(decoding: try XCTUnwrap(entries["model.mtl"]).data,
                                  as: UTF8.self))
        XCTAssertEqual(mapPath(mtl[0], "map_Kd"), mapPath(mtl[0], "map_Pm"))
    }

    func testPerBodyBundlesAreCompleteAndSelfContained() throws {
        let red = try OBJFixture.png([255, 0, 0, 255])
        let blue = try OBJFixture.png([0, 0, 255, 255])
        var first = OBJFixture.triangle(uv: true, material: BodyMaterialSpec(
            baseColor: SIMD4(repeating: 1), baseColorTexture: red,
            materialName: "Red"))
        first.material?.textureMetadata = [OBJFixture.metadata(slot: .baseColor, data: red)]
        var second = OBJFixture.triangle(uv: true, material: BodyMaterialSpec(
            baseColor: SIMD4(repeating: 1), baseColorTexture: blue,
            materialName: "Blue"))
        second.material?.textureMetadata = [OBJFixture.metadata(slot: .baseColor, data: blue)]

        for body in [first, second] {
            let result = OBJBundleExporter.export(bodies: [body])
            XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
            let entries = try readStoredZip(try XCTUnwrap(result.data))
            let mtl = parseMTL(String(decoding: try XCTUnwrap(entries["model.mtl"]).data,
                                      as: UTF8.self))
            let referenced = Set(["model.obj", "model.mtl"]
                + mtl.flatMap { material in
                    ["map_Kd", "map_Pr", "map_Pm", "map_Ke", "norm", "map_d"]
                        .compactMap { mapPath(material, $0) }
                })
            XCTAssertEqual(Set(entries.keys), referenced,
                           "a per-body bundle must not contain orphan resources")
            XCTAssertTrue(Set(entries.keys).allSatisfy { $0 == "model.obj" || $0 == "model.mtl"
                || $0.hasPrefix("textures/") })
        }
    }
}

// MARK: - Refusals

final class CADOBJRefusalTests: XCTestCase {
    private func assertFailure(_ result: OBJBundleExportResult,
                               _ code: String,
                               slot: MaterialTextureSlot? = nil,
                               file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertNil(result.data, file: file, line: line)
        XCTAssertNil(result.receipt, file: file, line: line)
        XCTAssertEqual(result.diagnostics.first?.code, code, file: file, line: line)
        if let slot {
            XCTAssertEqual(result.diagnostics.first?.textureSlot, slot,
                           file: file, line: line)
        }
    }

    func testMissingDeclaredTextureRefusesTheWholeBundle() throws {
        let bytes = try OBJFixture.png([255, 255, 255, 255])
        var spec = BodyMaterialSpec()
        spec.textureMetadata = [OBJFixture.metadata(slot: .normal, data: bytes,
                                                    colorSpace: .linear)]
        let body = OBJFixture.triangle(uv: true, material: spec)
        assertFailure(OBJBundleExporter.export(bodies: [body]),
                      "obj_bundle_missing_texture", slot: .normal)
    }

    func testStaleTextureIdentityRefusesInsteadOfRelabellingBytes() throws {
        let bytes = try OBJFixture.png([255, 255, 255, 255])
        var spec = BodyMaterialSpec(normalTexture: bytes)
        spec.textureMetadata = [CADMaterialTextureMetadata(
            assetID: UUID(), slot: .normal, mimeType: "image/png",
            colorSpace: .linear, orientation: .topLeft,
            sha256: String(repeating: "0", count: 64), byteCount: bytes.count)]
        let body = OBJFixture.triangle(uv: true, material: spec)
        assertFailure(OBJBundleExporter.export(bodies: [body]),
                      "obj_bundle_texture_identity_mismatch", slot: .normal)
    }

    func testInvalidImageAndHDRAndNormalColorSpaceRefuse() throws {
        var invalid = BodyMaterialSpec()
        invalid.baseColorTexture = Data("not an image".utf8)
        assertFailure(OBJBundleExporter.export(bodies: [
            OBJFixture.triangle(uv: true, material: invalid)
        ]), "obj_bundle_invalid_texture", slot: .baseColor)

        var hdr = BodyMaterialSpec()
        hdr.emissive = SIMD3(repeating: 1)
        hdr.emissiveStrength = 2
        assertFailure(OBJBundleExporter.export(bodies: [
            OBJFixture.triangle(uv: true, material: hdr)
        ]), "obj_bundle_unsupported_emissive_strength", slot: .emissive)

        let normal = try OBJFixture.png([128, 128, 255, 255])
        var normalSpec = BodyMaterialSpec(normalTexture: normal)
        normalSpec.textureMetadata = [OBJFixture.metadata(
            slot: .normal, data: normal, colorSpace: .srgb)]
        assertFailure(OBJBundleExporter.export(bodies: [
            OBJFixture.triangle(uv: true, material: normalSpec)
        ]), "obj_bundle_unsupported_normal_color_space", slot: .normal)
    }

    func testMeshUVTransformAndInvalidMeshAndEmptyModelRefuse() throws {
        let red = try OBJFixture.png([255, 0, 0, 255])
        var transformed = BodyMaterialSpec(
            baseColor: SIMD4(repeating: 1),
            baseColorTexture: red,
            materialName: "Mesh transform",
            uvMapping: CADMaterialUVMapping(source: .mesh, rotationDegrees: 45))
        transformed.textureMetadata = [OBJFixture.metadata(slot: .baseColor, data: red)]
        assertFailure(OBJBundleExporter.export(bodies: [
            OBJFixture.triangle(uv: true, material: transformed)
        ]), "obj_bundle_unsupported_mesh_uv_transform")

        var broken = OBJFixture.triangle()
        broken.render.indices = [0, 1, 9]
        assertFailure(OBJBundleExporter.export(bodies: [broken]),
                      "obj_bundle_invalid_mesh")

        assertFailure(OBJBundleExporter.export(bodies: []),
                      "obj_bundle_empty_model")
    }
}
