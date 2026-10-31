//
//  CADMaterialRenderWitnessTests.swift
//  FloeCADKitTests
//
//  X13 REAL renderer witness — engineering Metal viewport.
//
//  The source-level interop tests simulate the KHR sampling and the explicit
//  TANGENT basis in Swift; this witness renders the same physics through the
//  ACTUAL Metal shader (Shaders.metal `fragment_litTextured` + the shared-UV
//  derivative TBN) via the real document capture entry point
//  `FloeCADDocument.captureViewportPNG` (offscreen `Renderer` over the live
//  scene; no drawing-page renderer, no fabricated image, no fallback).
//
//  Fixture oracle (A/B/C):
//    * One closed 100x100x12 mm slab, identical authored mesh UVs, one
//      2x2 tangent-space normal map with an asymmetric green channel
//      (memory top row green 204 => +0.60 Y, bottom row green 51 => -0.60 Y)
//      and per-column red variation (96/160).
//    * A = the authored bytes, declared `topLeft`.
//    * B = the EXACT lossless row inversion of A's bytes, declared
//      `bottomLeft`. A and B describe the SAME physical normals; with the
//      fixed per-map-origin sampling (flip only the sampled coordinate,
//      derive the TBN from the shared mesh UV) the two renders must match
//      to GPU-numerical tolerance. `checks/metal_lighting_oracle.py`
//      evaluates the identical shader math in exact arithmetic: A/B are
//      identical (delta 0.0).
//    * C = the SAME bytes as B but declared `topLeft`, i.e. the green
//      channel is deliberately reversed relative to A at every memory
//      position. C is the negative control: its lighting MUST differ
//      clearly (oracle: max channel delta 81 code values). Because B and C
//      are byte-identical and differ only in the declared origin, a stale
//      or cached texture cannot fake B==A while C!=A.
//
//  Every attachment binds the rendered pixels to the source document
//  (revision, change count, content SHA-256) and to the normal-map bytes
//  (SHA-256, declared orientation) that produced them.
//
//  Run: App-hosted FloeAppTests bundle on the pinned iPad Simulator
//  (`--ui-testing` NOT required; Metal must be available — a missing Metal
//  device fails, it never skips, because the witness is meaningless without
//  the real GPU path).
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import simd

#if canImport(MetalKit)
import MetalKit
#endif

@testable import FloeCAD

// MARK: - Shared witness fixture (duplicated per witness file on purpose:
// each witness must stay independently readable; the constants are pinned
// here and by checks/witness_fixture_check.py).

private enum MaterialRenderWitnessFixture {
    /// 2x2 RGBA rows, memory top -> bottom. Green is asymmetric between
    /// rows (+0.60 / -0.60); red varies per column (96 / 160).
    static let rowTop: [[UInt8]] = [[96, 204, 255, 255], [160, 204, 255, 255]]
    static let rowBottom: [[UInt8]] = [[96, 51, 255, 255], [160, 51, 255, 255]]

    enum Variant {
        case a, b, c

        /// Memory rows top -> bottom. B and C share identical bytes; only
        /// the declared origin differs, which is the discriminant.
        var rows: [[UInt8]] {
            switch self {
            case .a: return MaterialRenderWitnessFixture.rowTop + MaterialRenderWitnessFixture.rowBottom
            case .b, .c: return MaterialRenderWitnessFixture.rowBottom + MaterialRenderWitnessFixture.rowTop
            }
        }

        var orientation: MaterialTextureOrientation {
            switch self {
            case .a, .c: return .topLeft
            case .b: return .bottomLeft
            }
        }

        var displayName: String {
            switch self {
            case .a: return "A-topLeft"
            case .b: return "B-bottomLeft"
            case .c: return "C-topLeft-greenReversed"
            }
        }
    }

    static func normalPNG(_ variant: Variant) throws -> Data {
        var bytes: [UInt8] = []
        for row in variant.rows { bytes.append(contentsOf: row) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 2 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
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

    /// Closed 100x100x12 mm slab, 24 vertices, per-face UVs spanning 0...1,
    /// outward normals, counter-clockwise front faces (same convention as the
    /// interop tests' quad).
    static func slabBody(normalPNG png: Data,
                         orientation: MaterialTextureOrientation) -> Body {
        let h: Float = 50
        let z0: Float = 0, z1: Float = 12
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var texcoords: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        let faceUVs = [SIMD2<Float>(0, 0), SIMD2<Float>(1, 0),
                       SIMD2<Float>(1, 1), SIMD2<Float>(0, 1)]
        func addFace(_ corners: [SIMD3<Float>], _ normal: SIMD3<Float>) {
            let base = UInt32(positions.count)
            for index in 0..<4 {
                positions.append(corners[index])
                normals.append(normal)
                texcoords.append(faceUVs[index])
            }
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }
        addFace([SIMD3(-h, -h, z1), SIMD3(h, -h, z1),
                 SIMD3(h, h, z1), SIMD3(-h, h, z1)], SIMD3(0, 0, 1))
        addFace([SIMD3(h, -h, z0), SIMD3(-h, -h, z0),
                 SIMD3(-h, h, z0), SIMD3(h, h, z0)], SIMD3(0, 0, -1))
        addFace([SIMD3(h, -h, z1), SIMD3(h, -h, z0),
                 SIMD3(h, h, z0), SIMD3(h, h, z1)], SIMD3(1, 0, 0))
        addFace([SIMD3(-h, -h, z0), SIMD3(-h, -h, z1),
                 SIMD3(-h, h, z1), SIMD3(-h, h, z0)], SIMD3(-1, 0, 0))
        addFace([SIMD3(-h, h, z1), SIMD3(h, h, z1),
                 SIMD3(h, h, z0), SIMD3(-h, h, z0)], SIMD3(0, 1, 0))
        addFace([SIMD3(-h, -h, z0), SIMD3(h, -h, z0),
                 SIMD3(h, -h, z1), SIMD3(-h, -h, z1)], SIMD3(0, -1, 0))

        var body = Body(id: BodyID(), name: "X13 witness slab",
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: indices, texcoords: texcoords),
                        revision: 1)
        let metadata = CADMaterialTextureMetadata(
            assetID: UUID(), slot: .normal, mimeType: "image/png",
            colorSpace: .linear, orientation: orientation,
            sha256: CADMaterialTexture.digest(png), byteCount: png.count)
        body.material = BodyMaterialSpec(
            baseColor: SIMD4(0.80, 0.80, 0.85, 1), metallic: 0, roughness: 0.5,
            normalTexture: png, uvMapping: .mesh,
            textureMetadata: [metadata])
        return body
    }
}

// MARK: - Pixel decode / diff (self-contained; no production helper reused)

private struct WitnessPixels {
    var width: Int
    var height: Int
    var rgba: [UInt8]

    static func decode(_ png: Data, file: StaticString = #filePath,
                       line: UInt = #line) throws -> WitnessPixels {
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(png as CFData, nil),
            "attachment must be a decodable PNG", file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil),
                                  file: file, line: line)
        let width = image.width, height = image.height
        XCTAssertGreaterThan(width, 0, file: file, line: line)
        XCTAssertGreaterThan(height, 0, file: file, line: line)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        try rgba.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(
                data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                file: file, line: line)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return WitnessPixels(width: width, height: height, rgba: rgba)
    }

    /// Whole-frame absolute channel difference statistics.
    struct DiffStats {
        var mean: Double
        var max: Int
        var exactFraction: Double
        var p95: Int
        var distinctA: Int
        var distinctB: Int
    }

    static func diff(_ lhs: WitnessPixels, _ rhs: WitnessPixels,
                     file: StaticString = #filePath,
                     line: UInt = #line) throws -> DiffStats {
        XCTAssertEqual(lhs.width, rhs.width, file: file, line: line)
        XCTAssertEqual(lhs.height, rhs.height, file: file, line: line)
        _ = try XCTUnwrap(lhs.width == rhs.width && lhs.height == rhs.height ? true : nil,
                         "Renderer variants must have identical dimensions")
        let count = lhs.width * lhs.height
        var total = 0
        var maximum = 0
        var exact = 0
        var samples: [Int] = []
        samples.reserveCapacity(count * 3)
        var colorsA = Set<UInt32>()
        var colorsB = Set<UInt32>()
        for pixel in 0..<count {
            let base = pixel * 4
            var packedA: UInt32 = 0
            var packedB: UInt32 = 0
            for channel in 0..<3 {
                let a = Int(lhs.rgba[base + channel])
                let b = Int(rhs.rgba[base + channel])
                let d = abs(a - b)
                total += d
                maximum = max(maximum, d)
                if d == 0 { exact += 1 } else { samples.append(d) }
                packedA = (packedA << 8) | UInt32(a)
                packedB = (packedB << 8) | UInt32(b)
            }
            colorsA.insert(packedA)
            colorsB.insert(packedB)
        }
        samples.sort()
        let p95 = samples.isEmpty ? 0 : samples[(samples.count - 1) * 95 / 100]
        return DiffStats(
            mean: Double(total) / Double(count * 3),
            max: maximum,
            exactFraction: Double(exact) / Double(count * 3),
            p95: p95,
            distinctA: colorsA.count,
            distinctB: colorsB.count)
    }
}

// MARK: - Engineering Metal render witness

@MainActor
final class CADMaterialRenderWitnessTests: XCTestCase {
    private var directories: [URL] = []
    private var documents: [FloeCADDocument] = []

    override func tearDown() async throws {
        for document in documents { document.close() }
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        documents = []
        directories = []
    }

    private struct Captured {
        var variant: MaterialRenderWitnessFixture.Variant
        var png: Data
        var pixels: WitnessPixels
        var sourceSHA256: String
        var orientation: MaterialTextureOrientation
        var revision: Int
        var changeCount: Int
        var contentSHA256: String
        var imageSHA256: String
        var renderer: String
    }

    private func capture(_ variant: MaterialRenderWitnessFixture.Variant)
        async throws -> Captured {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("X13MetalWitness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let png = try MaterialRenderWitnessFixture.normalPNG(variant)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("witness-\(variant.displayName).floecad"),
            name: "X13 \(variant.displayName)")
        documents.append(document)
        let body = MaterialRenderWitnessFixture.slabBody(
            normalPNG: png, orientation: variant.orientation)
        document.session.perform(AddBodyCommand(body: body,
                                                title: "Add witness slab"))
        // The actual engineering capture: offscreen Metal renderer over the
        // live scene; throws (never fabricates) when the GPU path is missing.
        let result = try document.captureViewportPNG(width: 1024, height: 768)
        XCTAssertEqual(result.renderer, "engineering",
                       "the capture must name the actual renderer")
        XCTAssertFalse(result.pngData.isEmpty)
        XCTAssertEqual(result.pngData.prefix(2), Data([0x89, 0x50]),
                       "capture must be a real PNG")
        let pixels = try WitnessPixels.decode(result.pngData)
        // Nonblank: a real shaded render has many distinct colors and real
        // variance; a flat frame cannot count as evidence.
        XCTAssertGreaterThanOrEqual(pixels.rgba.count, 1024 * 768 * 4)
        var distinct = Set<UInt32>()
        var luminanceSum = 0
        var luminanceSq = 0
        let count = pixels.width * pixels.height
        for pixel in 0..<count {
            let base = pixel * 4
            let r = Int(pixels.rgba[base])
            let g = Int(pixels.rgba[base + 1])
            let b = Int(pixels.rgba[base + 2])
            distinct.insert((UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b))
            let lum = r * 54 + g * 183 + b * 19
            luminanceSum += lum
            luminanceSq += lum * lum
        }
        XCTAssertGreaterThanOrEqual(distinct.count, 64,
                                    "a lit textured slab must produce many colors")
        let mean = Double(luminanceSum) / Double(count)
        let variance = Double(luminanceSq) / Double(count) - mean * mean
        XCTAssertGreaterThan(variance, 16,
                             "a flat/blank frame cannot witness real shading")

        return Captured(
            variant: variant, png: result.pngData, pixels: pixels,
            sourceSHA256: CADMaterialTexture.digest(png),
            orientation: variant.orientation,
            revision: result.revision, changeCount: result.changeCount,
            contentSHA256: result.contentSHA256, imageSHA256: result.sha256,
            renderer: result.renderer)
    }

    private func attach(_ captured: Captured) {
        let attachment = XCTAttachment(data: captured.png, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "x13-metal-\(captured.variant.displayName)-rev\(captured.revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let manifest: [String: Any] = [
            "witness": "X13 normal-map origins — engineering Metal viewport",
            "variant": captured.variant.displayName,
            "renderer": captured.renderer,
            "documentRevision": captured.revision,
            "documentChangeCount": captured.changeCount,
            "documentContentSHA256": captured.contentSHA256,
            "renderedImageSHA256": captured.imageSHA256,
            "normalMapBytesSHA256": captured.sourceSHA256,
            "normalMapOrientation": "\(captured.orientation)",
            "captureEntryPoint": "FloeCADDocument.captureViewportPNG",
            "shader": "Shaders.metal fragment_litTextured (shared-UV derivative TBN)",
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-metal-\(captured.variant.displayName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    func testOppositeNormalOriginsRenderIdenticallyAndReversedGreenDoesNot()
        async throws {
        #if canImport(MetalKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            XCTFail("Metal is unavailable: the engineering witness requires "
                    + "the real GPU renderer; it must not be skipped or faked.")
            return
        }
        #else
        XCTFail("MetalKit is unavailable in this build; the engineering "
                + "witness cannot run and must not be faked.")
        return
        #endif

        let a = try await capture(.a)
        let b = try await capture(.b)
        let c = try await capture(.c)
        attach(a); attach(b); attach(c)

        // Byte-level negative-control proof: B and C are the SAME bytes with
        // opposite declared origins, so a renderer that ignored the origin
        // (or served a cached texture) would render B == C and could not
        // satisfy both requirements below.
        let pngA = try MaterialRenderWitnessFixture.normalPNG(.a)
        let pngB = try MaterialRenderWitnessFixture.normalPNG(.b)
        let pngC = try MaterialRenderWitnessFixture.normalPNG(.c)
        XCTAssertEqual(pngB, pngC,
                       "B and C must share identical bytes; only the declared "
                       + "origin differs")
        XCTAssertNotEqual(pngA, pngB)
        XCTAssertEqual(a.sourceSHA256, CADMaterialTexture.digest(pngA))
        XCTAssertEqual(b.sourceSHA256, CADMaterialTexture.digest(pngB))
        XCTAssertEqual(c.sourceSHA256, CADMaterialTexture.digest(pngC))

        let ab = try WitnessPixels.diff(a.pixels, b.pixels)
        let ac = try WitnessPixels.diff(a.pixels, c.pixels)

        // A and B describe identical physical normals. The lighting oracle
        // (checks/metal_lighting_oracle.py) evaluates this shader's math in
        // exact arithmetic and gets delta 0.0; the small slack here covers
        // GPU sampler rounding only.
        XCTAssertLessThanOrEqual(ab.mean, 1.0,
                                 "A/B mean channel delta \(ab.mean) exceeds the "
                                 + "GPU-numerical tolerance")
        XCTAssertGreaterThanOrEqual(ab.exactFraction, 0.97,
                                    "A/B must be pixel-identical except for "
                                    + "sampler rounding (exact \(ab.exactFraction))")
        XCTAssertLessThanOrEqual(ab.max, 12, "A/B max delta \(ab.max)")

        // Negative control: C reverses the green channel, so its lighting
        // must differ clearly. Oracle: 81 code values per band.
        XCTAssertGreaterThanOrEqual(ac.mean, 8.0,
                                    "A/C mean delta \(ac.mean): the reversed "
                                    + "green must change the lighting visibly")
        XCTAssertGreaterThanOrEqual(ac.p95, 48,
                                    "A/C p95 delta \(ac.p95)")
        XCTAssertGreaterThanOrEqual(ac.max, 64, "A/C max delta \(ac.max)")
        XCTAssertGreaterThanOrEqual(ac.mean, 6 * max(ab.mean, 0.25),
                                    "the negative control must dominate any "
                                    + "numerical noise")
    }
}
