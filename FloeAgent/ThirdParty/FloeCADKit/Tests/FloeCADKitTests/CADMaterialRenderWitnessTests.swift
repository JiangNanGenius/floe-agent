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
//  Fixture A/B/C — one closed 100x100x12 mm slab with authored mesh UVs:
//    * NORMAL half: one 2x2 tangent-space normal map whose green channel is
//      255 (tangent +Y, memory top row) and 0 (tangent -Y, memory bottom
//      row), with per-column red variation (96/160). Bilinear interpolation
//      still crosses zero at the midpoint; the brighter albedo, roughness
//      and framing provide the broad visible response.
//    * COLOR half: one 64x64 sRGB base-colour map with four solid authored
//      quadrants (red/green/blue/yellow) and the same A/B/C origin rules.
//      The absolute landmarks below project each authored quadrant centre
//      from the known world point through the actual capture camera, so a
//      renderer that consistently samples the wrong place cannot pass.
//    * A = the authored bytes, declared `topLeft`.
//    * B = the EXACT lossless row inversion of A's bytes, declared
//      `bottomLeft`. A and B describe the SAME physical samples; with the
//      fixed per-map-origin sampling the two renders must match to
//      GPU-numerical tolerance.
//    * C = the SAME bytes as B but declared `topLeft`, i.e. the map is
//      deliberately reversed relative to A. Because B and C are
//      byte-identical and differ only in the declared origin, a stale or
//      cached texture cannot fake B==A while C!=A.
//    * Negative-control gate: per the root's explicit fixed-footprint
//      decision, the original whole-frame mean floor is enforced as the same
//      >=8 response over the deterministic projected front-face interior;
//      the whole-frame dominance, p95, max, changed-region and border
//      gates are preserved.
//
//  Every attachment binds the rendered pixels to the source document
//  (revision, change count, content SHA-256) and to the authored image bytes
//  (SHA-256, declared orientation) that produced them. It always names the
//  rendered PNG and the authored texture separately.
//
//  MIXED-MATERIAL witness (the original X13 criterion):
//  `testMixedColorAndNormalOriginsRenderOneMaterialAtOnePlace` puts the 64x64
//  colour map and the 2x2 normal map into ONE BodyMaterialSpec with separate
//  typed metadata, then compares four variants through the same actual capture:
//    A = colour topLeft + normal topLeft;
//    B = the SAME colour topLeft + row-inverted normal bytes declared
//        bottomLeft (opposite declared origins, physically the same samples);
//    C = B's normal bytes wrongly declared topLeft (colour held fixed; only
//        the actual normal lighting may differ);
//    D = row-inverted colour bytes declared bottomLeft + the baseline
//        topLeft normal (the opposite mixed assignment, physically A).
//  A, B and D must match under the renderer's existing A/B equivalence
//  criterion; C must show a material response over the same projected
//  front-face footprint. Absolute colour landmarks are asserted for ALL four
//  variants, so a renderer that drops either map, swaps a per-map origin, or
//  samples a cached image cannot pass. Every capture attaches its actual PNG
//  and a manifest carrying both authored image SHAs/origins/slots.
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
// each witness must stay independently readable; the normal and colour
// constants are pinned across all three witnesses).

private enum MaterialRenderWitnessFixture {
    static let slabMinMM = SIMD3<Float>(-50, -50, 0)
    static let slabMaxMM = SIMD3<Float>(50, 50, 12)
    static let frontFaceZMM: Float = 12

    /// 2x2 RGBA rows, memory top -> bottom. Green is +1.0 / -1.0 tangent Y
    /// (255 / 0; interpolation still crosses zero at the midpoint); red
    /// varies per column (96 / 160).
    static let rowTop: [[UInt8]] = [[96, 255, 164, 255], [160, 255, 164, 255]]
    static let rowBottom: [[UInt8]] = [[96, 0, 164, 255], [160, 0, 164, 255]]

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

    static func png(width: Int, height: Int, rows: [[UInt8]]) throws -> Data {
        XCTAssertEqual(rows.count, height)
        XCTAssertTrue(rows.allSatisfy { $0.count == width * 4 })
        var bytes: [UInt8] = []
        bytes.reserveCapacity(width * height * 4)
        for row in rows { bytes.append(contentsOf: row) }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
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

    static func normalPNG(_ variant: Variant) throws -> Data {
        try png(width: 2, height: 2, rows: [
                Array(variant.rows.prefix(2).joined()),
                Array(variant.rows.suffix(2).joined()),
            ])
    }

    /// Closed 100x100x12 mm slab, 24 vertices, per-face UVs spanning 0...1,
    /// outward normals, counter-clockwise front faces (same convention as the
    /// interop tests' quad). Shared by the normal and colour witnesses so both
    /// maps sample the same physical surface.
    static func slabBody(material: BodyMaterialSpec, name: String) -> Body {
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

        var body = Body(id: BodyID(), name: name,
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: indices, texcoords: texcoords),
                        revision: 1)
        body.material = material
        return body
    }

    static func slabBody(normalPNG png: Data,
                         orientation: MaterialTextureOrientation) -> Body {
        let metadata = CADMaterialTextureMetadata(
            assetID: UUID(), slot: .normal, mimeType: "image/png",
            colorSpace: .linear, orientation: orientation,
            sha256: CADMaterialTexture.digest(png), byteCount: png.count)
        return slabBody(material: BodyMaterialSpec(
            baseColor: SIMD4(0.6, 0.6, 0.66, 1), metallic: 0, roughness: 0.8,
            normalTexture: png, uvMapping: .mesh,
            textureMetadata: [metadata]), name: "X13 witness slab")
    }

    // MARK: Colour fixture

    static let colorWidth = 64
    static let colorHeight = 64

    /// Four solid quadrants in the authored top-left row order:
    /// red | green
    /// -----+------
    /// blue| yellow
    static let colorTopRow: [UInt8] = {
        var row: [UInt8] = []
        row.reserveCapacity(MaterialRenderWitnessFixture.colorWidth * 4)
        for column in 0..<MaterialRenderWitnessFixture.colorWidth {
            row.append(contentsOf: column < MaterialRenderWitnessFixture.colorWidth / 2
                       ? [255, 0, 0, 255] : [0, 255, 0, 255])
        }
        return row
    }()
    static let colorBottomRow: [UInt8] = {
        var row: [UInt8] = []
        row.reserveCapacity(MaterialRenderWitnessFixture.colorWidth * 4)
        for column in 0..<MaterialRenderWitnessFixture.colorWidth {
            row.append(contentsOf: column < MaterialRenderWitnessFixture.colorWidth / 2
                       ? [0, 0, 255, 255] : [255, 255, 0, 255])
        }
        return row
    }()

    enum ColorVariant {
        case a, b, c

        /// Memory rows top -> bottom. B is the exact lossless row inversion
        /// of A and is declared `bottomLeft`; C shares B's bytes but is
        /// declared `topLeft`, which makes the sampled rows a vertical
        /// mirror of A.
        var rows: [[UInt8]] {
            switch self {
            case .a:
                return Array(repeating: MaterialRenderWitnessFixture.colorTopRow,
                             count: MaterialRenderWitnessFixture.colorHeight / 2)
                    + Array(repeating: MaterialRenderWitnessFixture.colorBottomRow,
                            count: MaterialRenderWitnessFixture.colorHeight / 2)
            case .b, .c:
                return Array(repeating: MaterialRenderWitnessFixture.colorBottomRow,
                             count: MaterialRenderWitnessFixture.colorHeight / 2)
                    + Array(repeating: MaterialRenderWitnessFixture.colorTopRow,
                            count: MaterialRenderWitnessFixture.colorHeight / 2)
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
            case .a: return "A-colourTopLeft"
            case .b: return "B-colourBottomLeft"
            case .c: return "C-colourBottomLeftBytesTopLeft"
            }
        }
    }

    static func colorPNG(_ variant: ColorVariant) throws -> Data {
        try png(width: MaterialRenderWitnessFixture.colorWidth, height: MaterialRenderWitnessFixture.colorHeight, rows: variant.rows)
    }

    static func colorSlabBody(colorPNG png: Data,
                              orientation: MaterialTextureOrientation) -> Body {
        let metadata = CADMaterialTextureMetadata(
            assetID: UUID(), slot: .baseColor, mimeType: "image/png",
            colorSpace: .srgb, orientation: orientation,
            sha256: CADMaterialTexture.digest(png), byteCount: png.count)
        return slabBody(material: BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 1.0,
            baseColorTexture: png, uvMapping: .mesh,
            textureMetadata: [metadata]), name: "X13 colour witness slab")
    }

    // MARK: Mixed-material fixture (colour + normal in ONE material)

    /// One authored material carrying BOTH maps. The typed metadata records
    /// are separate per slot, exactly like a real imported material whose
    /// colour map and normal map were authored in opposite vertical
    /// directions.
    struct MixedSource {
        var colorPNG: Data
        var colorOrientation: MaterialTextureOrientation
        var normalPNG: Data
        var normalOrientation: MaterialTextureOrientation
    }

    enum MixedVariant: String, CaseIterable {
        case a, b, c, d

        /// A/B/C keep the exact authored colour bytes at topLeft; D is the
        /// lossless row inversion declared bottomLeft. B/C share the exact
        /// row-inverted normal bytes; only their declared normal origin
        /// differs. Every variant is one material carrying both maps.
        var source: MixedSource {
            get throws {
                switch self {
                case .a:
                    return MixedSource(
                        colorPNG: try MaterialRenderWitnessFixture.colorPNG(.a),
                        colorOrientation: .topLeft,
                        normalPNG: try MaterialRenderWitnessFixture.normalPNG(.a),
                        normalOrientation: .topLeft)
                case .b:
                    return MixedSource(
                        colorPNG: try MaterialRenderWitnessFixture.colorPNG(.a),
                        colorOrientation: .topLeft,
                        normalPNG: try MaterialRenderWitnessFixture.normalPNG(.b),
                        normalOrientation: .bottomLeft)
                case .c:
                    return MixedSource(
                        colorPNG: try MaterialRenderWitnessFixture.colorPNG(.a),
                        colorOrientation: .topLeft,
                        normalPNG: try MaterialRenderWitnessFixture.normalPNG(.b),
                        normalOrientation: .topLeft)
                case .d:
                    return MixedSource(
                        colorPNG: try MaterialRenderWitnessFixture.colorPNG(.b),
                        colorOrientation: .bottomLeft,
                        normalPNG: try MaterialRenderWitnessFixture.normalPNG(.a),
                        normalOrientation: .topLeft)
                }
            }
        }

        var displayName: String {
            switch self {
            case .a: return "A-colourTL_normalTL"
            case .b: return "B-colourTL_normalBL"
            case .c: return "C-colourTL_normalBLBytesTL"
            case .d: return "D-colourBL_normalTL"
            }
        }
    }

    static func mixedSlabBody(_ source: MixedSource) -> Body {
        let colorMetadata = CADMaterialTextureMetadata(
            assetID: UUID(), slot: .baseColor, mimeType: "image/png",
            colorSpace: .srgb, orientation: source.colorOrientation,
            sha256: CADMaterialTexture.digest(source.colorPNG),
            byteCount: source.colorPNG.count)
        let normalMetadata = CADMaterialTextureMetadata(
            assetID: UUID(), slot: .normal, mimeType: "image/png",
            colorSpace: .linear, orientation: source.normalOrientation,
            sha256: CADMaterialTexture.digest(source.normalPNG),
            byteCount: source.normalPNG.count)
        return slabBody(material: BodyMaterialSpec(
            baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 0.8,
            baseColorTexture: source.colorPNG, normalTexture: source.normalPNG,
            uvMapping: .mesh,
            textureMetadata: [colorMetadata, normalMetadata]),
            name: "X13 mixed-origin witness slab")
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

    /// Region statistics over the pixels that actually changed, plus the
    /// frame border. Whole-frame means are diluted by the unchanged
    /// background (~75% of the frame), so the negative control is
    /// additionally qualified by: (a) the fraction of frame pixels that
    /// changed (a flat/cached texture changes ~0%; a narrow specular streak
    /// stays small; the reversed map must manifest across the textured
    /// face), (b) the mean delta inside that changed region (dilution-free
    /// strength), and (c) the border staying exact (a stale frame, exposure
    /// drift or background change would move the border too).
    struct RegionStats {
        var changedFraction: Double
        var changedMean: Double
        var borderMax: Int
    }

    static func regionDiff(_ lhs: WitnessPixels, _ rhs: WitnessPixels,
                           noiseFloor: Int = 4,
                           borderFraction: Double = 0.01) -> RegionStats {
        let count = lhs.width * lhs.height
        var changed = 0
        var changedTotal = 0
        let border = max(8, Int(Double(min(lhs.width, lhs.height)) * borderFraction))
        var borderMax = 0
        for pixel in 0..<count {
            let base = pixel * 4
            var dmax = 0
            for channel in 0..<3 {
                dmax = max(dmax, abs(Int(lhs.rgba[base + channel])
                                     - Int(rhs.rgba[base + channel])))
            }
            let x = pixel % lhs.width, y = pixel / lhs.width
            if x < border || y < border
                || x >= lhs.width - border || y >= lhs.height - border {
                borderMax = max(borderMax, dmax)
                continue
            }
            if dmax >= noiseFloor {
                changed += 1
                for channel in 0..<3 {
                    changedTotal += abs(Int(lhs.rgba[base + channel])
                                        - Int(rhs.rgba[base + channel]))
                }
            }
        }
        return RegionStats(
            changedFraction: Double(changed) / Double(count),
            changedMean: changed > 0 ? Double(changedTotal) / Double(changed * 3) : 0,
            borderMax: borderMax)
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

// MARK: - Absolute colour-landmark projection (source-derived camera)

/// A convex projected polygon (the authored front face). The same geometry
/// bounds the absolute landmarks and the negative-control statistics, so a
/// narrow difference-selected streak cannot become the measured region.
private struct WitnessFootprint {
    var corners: [CGPoint]

    var area: CGFloat {
        guard corners.count >= 3 else { return 0 }
        var doubled: CGFloat = 0
        for index in corners.indices {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            doubled += a.x * b.y - b.x * a.y
        }
        return abs(doubled) * 0.5
    }

    /// `inset` is a distance in pixels. A point is inside only when it is at
    /// least that far from every projected face edge (interior erosion).
    func contains(_ point: CGPoint, inset: CGFloat = 0) -> Bool {
        guard corners.count >= 3 else { return false }
        var doubled: CGFloat = 0
        for index in corners.indices {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            doubled += a.x * b.y - b.x * a.y
        }
        let sign: CGFloat = doubled >= 0 ? 1 : -1
        for index in corners.indices {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            let ex = b.x - a.x
            let ey = b.y - a.y
            let length = (ex * ex + ey * ey).squareRoot()
            guard length > 0.0001 else { continue }
            let cross = ex * (point.y - a.y) - ey * (point.x - a.x)
            if cross * sign < inset * length { return false }
        }
        return true
    }
}

private struct ColorProjection {
    var matrix: simd_float4x4
    var width: Int
    var height: Int
    /// Millimetres -> projected world units. The engineering camera is in
    /// model millimetres; Present and the exported GLB are in metres.
    var worldScale: Float

    static func engineering(width: Int, height: Int) -> ColorProjection {
        // Renderer.makeSceneSnapshotPNG constructs a fresh TurntableCamera
        // and fits it to the snapshot's world bounds; the witness scene has
        // exactly this authored slab, so the same public-in-module helper
        // produces the same camera without a production seam.
        var camera = TurntableCamera()
        let aspect = Float(width) / Float(max(height, 1))
        camera.fit(boundsMin: MaterialRenderWitnessFixture.slabMinMM,
                   boundsMax: MaterialRenderWitnessFixture.slabMaxMM,
                   aspect: aspect)
        return ColorProjection(matrix: camera.viewProjection(aspect: aspect),
                               width: width, height: height, worldScale: 1)
    }

    func point(_ worldMM: SIMD3<Float>) -> CGPoint? {
        let clip = matrix * SIMD4<Float>(worldMM * worldScale, 1)
        guard clip.w > 0.000001, clip.w.isFinite else { return nil }
        let ndc = SIMD3<Float>(clip.x, clip.y, clip.z) / clip.w
        guard ndc.x.isFinite, ndc.y.isFinite else { return nil }
        let x = (Double(ndc.x) + 1) * 0.5 * Double(width)
        let y = (1 - Double(ndc.y)) * 0.5 * Double(height)
        return CGPoint(x: x, y: y)
    }

    func frontFaceFootprint() throws -> WitnessFootprint {
        let cornersMM = [
            SIMD3<Float>(MaterialRenderWitnessFixture.slabMinMM.x,
                         MaterialRenderWitnessFixture.slabMinMM.y,
                         MaterialRenderWitnessFixture.frontFaceZMM),
            SIMD3<Float>(MaterialRenderWitnessFixture.slabMaxMM.x,
                         MaterialRenderWitnessFixture.slabMinMM.y,
                         MaterialRenderWitnessFixture.frontFaceZMM),
            SIMD3<Float>(MaterialRenderWitnessFixture.slabMaxMM.x,
                         MaterialRenderWitnessFixture.slabMaxMM.y,
                         MaterialRenderWitnessFixture.frontFaceZMM),
            SIMD3<Float>(MaterialRenderWitnessFixture.slabMinMM.x,
                         MaterialRenderWitnessFixture.slabMaxMM.y,
                         MaterialRenderWitnessFixture.frontFaceZMM),
        ]
        var points: [CGPoint] = []
        for corner in cornersMM {
            points.append(try XCTUnwrap(point(corner),
                                        "colour landmark projection failed for \(corner)"))
        }
        return WitnessFootprint(corners: points)
    }
}

private enum ColorQuadrant: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var uv: SIMD2<Float> {
        switch self {
        case .topLeft: return SIMD2(0.25, 0.25)
        case .topRight: return SIMD2(0.75, 0.25)
        case .bottomLeft: return SIMD2(0.25, 0.75)
        case .bottomRight: return SIMD2(0.75, 0.75)
        }
    }

    /// World point on the authored front face (z = 12 mm) whose mesh UV is
    /// `uv`, because the slab's front face spans 0...1 across [-50, 50] mm.
    var worldMM: SIMD3<Float> {
        SIMD3<Float>(-50 + 100 * uv.x, -50 + 100 * uv.y,
                     MaterialRenderWitnessFixture.frontFaceZMM)
    }

    /// C shares B's row-inverted bytes but is declared topLeft, so it samples
    /// the authoured map at 1 - v: top and bottom quadrants swap.
    var mirrored: ColorQuadrant {
        switch self {
        case .topLeft: return .bottomLeft
        case .topRight: return .bottomRight
        case .bottomLeft: return .topLeft
        case .bottomRight: return .topRight
        }
    }

    var label: String {
        switch self {
        case .topLeft: return "topLeft"
        case .topRight: return "topRight"
        case .bottomLeft: return "bottomLeft"
        case .bottomRight: return "bottomRight"
        }
    }

    var expectedHue: String {
        switch self {
        case .topLeft: return "red"
        case .topRight: return "green"
        case .bottomLeft: return "blue"
        case .bottomRight: return "yellow"
        }
    }

    /// Dominant-channel identity of the authored quadrant. The margins are
    /// wide enough to survive each renderer's white key/environment lighting
    /// and display transfer, but a flat, mirrored or wrong-UV sample cannot
    /// satisfy them.
    func matches(red: Double, green: Double, blue: Double) -> Bool {
        switch self {
        case .topLeft:
            return red - max(green, blue) >= 16 && red >= 24
        case .topRight:
            return green - max(red, blue) >= 16 && green >= 24
        case .bottomLeft:
            return blue - max(red, green) >= 12 && blue >= 16
        case .bottomRight:
            return min(red, green) - blue >= 16 && min(red, green) >= 24
        }
    }
}

private struct ColorMean {
    var red: Double
    var green: Double
    var blue: Double
    var count: Int

    var description: String {
        "rgb=(\(String(format: "%.1f", red)), "
            + "\(String(format: "%.1f", green)), "
            + "\(String(format: "%.1f", blue))), n=\(count)"
    }
}

private struct ColorFootprintStats {
    var mean: Double
    var changedFraction: Double
    var pixelCount: Int
}

private extension WitnessPixels {
    func colorMean(at point: CGPoint, radius: Int,
                   footprint: WitnessFootprint) -> ColorMean? {
        let cx = Int(point.x.rounded())
        let cy = Int(point.y.rounded())
        let minX = max(0, cx - radius)
        let maxX = min(width - 1, cx + radius)
        let minY = max(0, cy - radius)
        let maxY = min(height - 1, cy + radius)
        guard minX <= maxX, minY <= maxY else { return nil }
        var red = 0, green = 0, blue = 0, count = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard footprint.contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) else {
                    continue
                }
                let base = (y * width + x) * 4
                red += Int(rgba[base])
                green += Int(rgba[base + 1])
                blue += Int(rgba[base + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return ColorMean(red: Double(red) / Double(count),
                         green: Double(green) / Double(count),
                         blue: Double(blue) / Double(count), count: count)
    }

    /// Fixed-footprint comparison: every pixel inside the projected authored
    /// face is counted, including unchanged ones. This is not a
    /// difference-selected region, so background dilution and self-selected
    /// narrow streaks cannot define the measurement.
    func footprintDiff(_ other: WitnessPixels,
                       footprint: WitnessFootprint,
                       inset: CGFloat = 0,
                       noiseFloor: Int = 4) -> ColorFootprintStats {
        guard width == other.width, height == other.height else {
            return ColorFootprintStats(mean: .infinity, changedFraction: 0,
                                       pixelCount: 0)
        }
        var total = 0
        var changed = 0
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                guard footprint.contains(CGPoint(x: CGFloat(x), y: CGFloat(y)), inset: inset) else {
                    continue
                }
                count += 1
                let base = (y * width + x) * 4
                var dmax = 0
                for channel in 0..<3 {
                    let delta = abs(Int(rgba[base + channel])
                                    - Int(other.rgba[base + channel]))
                    total += delta
                    dmax = max(dmax, delta)
                }
                if dmax >= noiseFloor { changed += 1 }
            }
        }
        guard count > 0 else {
            return ColorFootprintStats(mean: .infinity, changedFraction: 0,
                                       pixelCount: 0)
        }
        return ColorFootprintStats(mean: Double(total) / Double(count * 3),
                                   changedFraction: Double(changed) / Double(count),
                                   pixelCount: count)
    }

    /// RGB-channel mean over the same source-derived, fixed projected face.
    /// Every pixel and all three channels (including zero channels) contribute
    /// to the original mean >= 8 gate. Max-channel deltas are used only for
    /// the separate changed-pixel fraction, never to inflate this mean.
    func rgbMeanFootprintDiff(_ other: WitnessPixels,
                               footprint: WitnessFootprint,
                               inset: CGFloat = 0,
                               noiseFloor: Int = 4) -> MixedFootprintStats {
        guard width == other.width, height == other.height else {
            return MixedFootprintStats(mean: .infinity, changedFraction: 0,
                                          changedMean: .infinity, pixelCount: 0)
        }
        var total = 0
        var changed = 0
        var changedTotal = 0
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                guard footprint.contains(CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                        inset: inset) else {
                    continue
                }
                count += 1
                let base = (y * width + x) * 4
                var dmax = 0
                var channelTotal = 0
                for channel in 0..<3 {
                    let delta = abs(Int(rgba[base + channel]) - Int(other.rgba[base + channel]))
                    dmax = max(dmax, delta)
                    channelTotal += delta
                }
                total += channelTotal
                if dmax >= noiseFloor {
                    changed += 1
                    changedTotal += channelTotal
                }
            }
        }
        guard count > 0 else {
            return MixedFootprintStats(mean: .infinity, changedFraction: 0,
                                          changedMean: .infinity, pixelCount: 0)
        }
        return MixedFootprintStats(
            mean: Double(total) / Double(count * 3),
            changedFraction: Double(changed) / Double(count),
            changedMean: changed > 0 ? Double(changedTotal) / Double(changed * 3) : 0,
            pixelCount: count)
    }
}

private struct MixedFootprintStats {
    var mean: Double
    var changedFraction: Double
    var changedMean: Double
    var pixelCount: Int
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
        // Square capture: the fitted camera frames the slab's bounding
        // sphere with the same margin in both axes, so the textured face
        // covers ~1.3x more of the frame than 1024x768 and the whole-frame
        // contrast statistics measure the material, not the background.
        let result = try document.captureViewportPNG(width: 1024, height: 1024)
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

    private struct ColorCaptured {
        var variantName: String
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

    /// Actual engineering capture of the colour witness. Same entry point and
    /// same square framing as the normal witness; only the material slot and
    /// the authored image differ.
    private func captureColor(_ variant: MaterialRenderWitnessFixture.ColorVariant)
        async throws -> ColorCaptured {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("X13MetalColourWitness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let png = try MaterialRenderWitnessFixture.colorPNG(variant)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("colour-\(variant.displayName).floecad"),
            name: "X13 colour \(variant.displayName)")
        documents.append(document)
        let body = MaterialRenderWitnessFixture.colorSlabBody(
            colorPNG: png, orientation: variant.orientation)
        document.session.perform(AddBodyCommand(body: body,
                                                title: "Add colour witness slab"))
        let result = try document.captureViewportPNG(width: 1024, height: 1024)
        XCTAssertEqual(result.renderer, "engineering",
                       "the colour capture must name the actual renderer")
        XCTAssertFalse(result.pngData.isEmpty)
        XCTAssertEqual(result.pngData.prefix(2), Data([0x89, 0x50]),
                       "colour capture must be a real PNG")
        let pixels = try WitnessPixels.decode(result.pngData)
        XCTAssertEqual(pixels.width, 1024)
        XCTAssertEqual(pixels.height, 1024)
        return ColorCaptured(
            variantName: variant.displayName, png: result.pngData, pixels: pixels,
            sourceSHA256: CADMaterialTexture.digest(png),
            orientation: variant.orientation,
            revision: result.revision, changeCount: result.changeCount,
            contentSHA256: result.contentSHA256, imageSHA256: result.sha256,
            renderer: result.renderer)
    }

    private func attachColor(_ captured: ColorCaptured) {
        let attachment = XCTAttachment(data: captured.png,
                                       uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "x13-metal-colour-\(captured.variantName)-rev\(captured.revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let manifest: [String: Any] = [
            "witness": "X13 colour-map origins — engineering Metal viewport (absolute UV landmarks)",
            "variant": captured.variantName,
            "renderer": captured.renderer,
            "documentRevision": captured.revision,
            "documentChangeCount": captured.changeCount,
            "documentContentSHA256": captured.contentSHA256,
            "renderedImageSHA256": captured.imageSHA256,
            "authoredColorMapBytesSHA256": captured.sourceSHA256,
            "authoredColorMapOrientation": "\(captured.orientation)",
            "authoredColorMapColorSpace": "srgb",
            "captureEntryPoint": "FloeCADDocument.captureViewportPNG",
            "shader": "Shaders.metal fragment_litTextured (baseColorTex + orientedUV)",
            "landmarkCamera": "Renderer.makeSceneSnapshotPNG fitted TurntableCamera, reproduced from source",
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-metal-colour-\(captured.variantName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    // MARK: Mixed-material actual capture

    private struct MixedCaptured {
        var variantName: String
        var png: Data
        var pixels: WitnessPixels
        var source: MaterialRenderWitnessFixture.MixedSource
        var colorSHA256: String
        var normalSHA256: String
        var revision: Int
        var changeCount: Int
        var contentSHA256: String
        var imageSHA256: String
        var renderer: String
    }

    /// One actual engineering capture of a material that carries BOTH maps.
    /// Same square framing, same entry point and same slab as the normal and
    /// colour witnesses; only the single BodyMaterialSpec changes.
    private func captureMixed(_ variant: MaterialRenderWitnessFixture.MixedVariant)
        async throws -> MixedCaptured {
        let source = try variant.source
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("X13MetalMixedWitness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let body = MaterialRenderWitnessFixture.mixedSlabBody(source)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("mixed-\(variant.displayName).floecad"),
            name: "X13 mixed \(variant.displayName)")
        documents.append(document)
        document.session.perform(AddBodyCommand(body: body,
                                                title: "Add mixed witness slab"))
        // Commit before capture so documentContentSHA256 is the actual
        // material-bound identity, not the empty pre-edit baseline that a
        // debounced autosave would eventually replace.
        document.session.save()
        XCTAssertNil(document.session.lastSaveError,
                     "the mixed witness document must commit before capture")
        let result = try document.captureViewportPNG(width: 1024, height: 1024)
        XCTAssertEqual(result.renderer, "engineering",
                       "the mixed capture must name the actual renderer")
        XCTAssertFalse(result.pngData.isEmpty)
        XCTAssertEqual(result.pngData.prefix(2), Data([0x89, 0x50]),
                       "mixed capture must be a real PNG")
        let pixels = try WitnessPixels.decode(result.pngData)
        XCTAssertEqual(pixels.width, 1024)
        XCTAssertEqual(pixels.height, 1024)
        return MixedCaptured(
            variantName: variant.displayName, png: result.pngData, pixels: pixels,
            source: source,
            colorSHA256: CADMaterialTexture.digest(source.colorPNG),
            normalSHA256: CADMaterialTexture.digest(source.normalPNG),
            revision: result.revision, changeCount: result.changeCount,
            contentSHA256: result.contentSHA256, imageSHA256: result.sha256,
            renderer: result.renderer)
    }

    private func attachMixed(_ captured: MixedCaptured) {
        let png = XCTAttachment(data: captured.png,
                                uniformTypeIdentifier: UTType.png.identifier)
        png.name = "x13-metal-mixed-\(captured.variantName)-rev\(captured.revision)"
        png.lifetime = .keepAlways
        add(png)
        let colorSource = XCTAttachment(data: captured.source.colorPNG,
                                        uniformTypeIdentifier: UTType.png.identifier)
        colorSource.name = "x13-metal-mixed-\(captured.variantName)-baseColor-source.png"
        colorSource.lifetime = .keepAlways
        add(colorSource)
        let normalSource = XCTAttachment(data: captured.source.normalPNG,
                                         uniformTypeIdentifier: UTType.png.identifier)
        normalSource.name = "x13-metal-mixed-\(captured.variantName)-normal-source.png"
        normalSource.lifetime = .keepAlways
        add(normalSource)
        let manifest: [String: Any] = [
            "witness": "X13 mixed colour+normal map origins — engineering Metal viewport",
            "variant": captured.variantName,
            "renderer": captured.renderer,
            "sameMaterialCarriesBoth": true,
            "materialTextureSlots": ["baseColor", "normal"],
            "baseColorMap": [
                "slot": "baseColor",
                "bytesSHA256": captured.colorSHA256,
                "orientation": "\(captured.source.colorOrientation)",
                "colorSpace": "srgb",
                "mimeType": "image/png",
                "byteCount": captured.source.colorPNG.count,
            ],
            "normalMap": [
                "slot": "normal",
                "bytesSHA256": captured.normalSHA256,
                "orientation": "\(captured.source.normalOrientation)",
                "colorSpace": "linear",
                "mimeType": "image/png",
                "byteCount": captured.source.normalPNG.count,
            ],
            "documentRevision": captured.revision,
            "documentChangeCount": captured.changeCount,
            "documentContentSHA256": captured.contentSHA256,
            "renderedImageSHA256": captured.imageSHA256,
            "captureEntryPoint": "FloeCADDocument.captureViewportPNG",
            "shader": "Shaders.metal fragment_litTextured (baseColorTex + per-map flipV + shared-UV derivative TBN)",
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-metal-mixed-\(captured.variantName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    private func assertMixedEquivalent(_ lhs: MixedCaptured, _ rhs: MixedCaptured,
                                       footprint: WitnessFootprint, erosion: CGFloat,
                                       label: String) throws {
        let diff = try WitnessPixels.diff(lhs.pixels, rhs.pixels)
        XCTAssertLessThanOrEqual(diff.mean, 1.0,
                                 "\(label) mixed mean \(diff.mean) exceeds the "
                                 + "existing Metal A/B tolerance")
        XCTAssertGreaterThanOrEqual(diff.exactFraction, 0.97,
                                    "\(label) mixed exact fraction "
                                    + "\(diff.exactFraction)")
        XCTAssertLessThanOrEqual(diff.max, 12, "\(label) mixed max \(diff.max)")
        let fixed = lhs.pixels.footprintDiff(rhs.pixels, footprint: footprint,
                                             inset: erosion)
        XCTAssertGreaterThanOrEqual(fixed.pixelCount, 1_000)
        XCTAssertLessThanOrEqual(fixed.mean, 1.0,
                                 "\(label) mixed fixed-footprint mean \(fixed.mean)")
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

        // A and B describe identical physical normals. The deterministic
        // oracle (see the file header) evaluates this shader's math in
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
        // must differ clearly on the authored material. The fixed footprint
        // below excludes unchanged background without selecting pixels from
        // their observed difference. Full-frame peak/noise gates stay below.
        let projection = ColorProjection.engineering(width: a.pixels.width,
                                                     height: a.pixels.height)
        let footprint = try projection.frontFaceFootprint()
        let footprintFraction = Double(footprint.area) / Double(a.pixels.width * a.pixels.height)
        XCTAssertGreaterThanOrEqual(footprintFraction, 0.05)
        XCTAssertLessThanOrEqual(footprintFraction, 0.60)
        let erosion = CGFloat(max(6, Int(Double(min(a.pixels.width, a.pixels.height)) * 0.02)))
        let fixedAC = a.pixels.footprintDiff(c.pixels, footprint: footprint, inset: erosion)
        let fixedAB = a.pixels.footprintDiff(b.pixels, footprint: footprint, inset: erosion)
        XCTAssertGreaterThanOrEqual(fixedAC.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(fixedAC.mean, 8.0,
            "A/C authored-face mean \(fixedAC.mean); full-frame mean \(ac.mean)")
        XCTAssertGreaterThanOrEqual(fixedAC.changedFraction, 0.25,
            "Normal negative control must affect a substantial fixed material area")
        XCTAssertLessThanOrEqual(fixedAB.mean, 1.0)
        XCTAssertGreaterThanOrEqual(fixedAC.mean, 6 * max(fixedAB.mean, 0.25))
        let footprintRecord: [String: Any] = [
            "wholeFrameACMean": ac.mean, "fixedACMean": fixedAC.mean,
            "fixedABMean": fixedAB.mean, "fixedChangedFraction": fixedAC.changedFraction,
            "fixedPixelCount": fixedAC.pixelCount, "projectedFrameFraction": footprintFraction,
            "insetPixels": Double(erosion),
            "polygon": footprint.corners.map { [Double($0.x), Double($0.y)] },
            "source": "Authored +Z face projected from source/capture camera; not difference-selected",
        ]
        let footprintAttachment = XCTAttachment(string: String(decoding:
            try JSONSerialization.data(withJSONObject: footprintRecord, options: [.sortedKeys]),
            as: UTF8.self))
        footprintAttachment.name = "Normal fixed material footprint"
        footprintAttachment.lifetime = .keepAlways
        add(footprintAttachment)
        XCTAssertGreaterThanOrEqual(ac.p95, 48,
                                    "A/C p95 delta \(ac.p95)")
        XCTAssertGreaterThanOrEqual(ac.max, 64, "A/C max delta \(ac.max)")
        XCTAssertGreaterThanOrEqual(ac.mean, 6 * max(ab.mean, 0.25),
                                    "the negative control must dominate any "
                                    + "numerical noise")

        // Region gates (dilution-free): the changed region must cover a
        // substantial fraction of the frame (oracle: ~23%; a flat or cached
        // texture changes ~0%, a narrow streak stays far below), the mean
        // delta inside it must stay high (oracle: ~60), and the frame
        // border must be exact (a stale capture or lighting/exposure drift
        // would move the background too).
        let acRegion = WitnessPixels.regionDiff(a.pixels, c.pixels)
        XCTAssertGreaterThanOrEqual(acRegion.changedFraction, 0.06,
                                    "A/C changed fraction "
                                    + "\(acRegion.changedFraction): the "
                                    + "reversed green must manifest across "
                                    + "the textured face")
        XCTAssertLessThanOrEqual(acRegion.changedFraction, 0.60,
                                 "A/C changed fraction "
                                 + "\(acRegion.changedFraction): more than "
                                 + "the object changed (background/stale "
                                 + "frame?)")
        XCTAssertGreaterThanOrEqual(acRegion.changedMean, 24.0,
                                    "A/C changed-region mean "
                                    + "\(acRegion.changedMean): the "
                                    + "negative control must be strong "
                                    + "where it manifests")
        XCTAssertLessThanOrEqual(acRegion.borderMax, 4,
                                 "A/C border max \(acRegion.borderMax): the "
                                 + "background must be identical across "
                                 + "variants (stale/drifted frame?)")
    }

    private func assertColorLandmarks(_ pixels: WitnessPixels,
                                      projection: ColorProjection,
                                      footprint: WitnessFootprint,
                                      mirrored: Bool,
                                      label: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws {
        let radius = max(3, Int(Double(min(pixels.width, pixels.height)) * 0.008))
        for quadrant in ColorQuadrant.allCases {
            let expected = mirrored ? quadrant.mirrored : quadrant
            let point = try XCTUnwrap(
                projection.point(quadrant.worldMM),
                "\(label): \(quadrant.label) did not project into the capture",
                file: file, line: line)
            XCTAssertGreaterThanOrEqual(point.x, CGFloat(radius + 1),
                                        "\(label): \(quadrant.label) is outside the image",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(point.x, CGFloat(pixels.width - radius - 2),
                                     "\(label): \(quadrant.label) is outside the image",
                                     file: file, line: line)
            XCTAssertGreaterThanOrEqual(point.y, CGFloat(radius + 1),
                                        "\(label): \(quadrant.label) is outside the image",
                                        file: file, line: line)
            XCTAssertLessThanOrEqual(point.y, CGFloat(pixels.height - radius - 2),
                                     "\(label): \(quadrant.label) is outside the image",
                                     file: file, line: line)
            XCTAssertTrue(footprint.contains(point, inset: CGFloat(radius) * 2),
                          "\(label): \(quadrant.label) at world \(quadrant.worldMM) "
                          + "uv \(quadrant.uv) is not inside the eroded front-face footprint",
                          file: file, line: line)
            let mean = try XCTUnwrap(
                pixels.colorMean(at: point, radius: radius, footprint: footprint),
                "\(label): no pixels sampled at \(quadrant.label)",
                file: file, line: line)
            let expectedPixels = (2 * radius + 1) * (2 * radius + 1)
            XCTAssertGreaterThanOrEqual(mean.count, expectedPixels * 3 / 4,
                                        "\(label): \(quadrant.label) ROI escaped the "
                                        + "projected face (sampled \(mean.count) of "
                                        + "\(expectedPixels))",
                                        file: file, line: line)
            XCTAssertTrue(expected.matches(red: mean.red, green: mean.green, blue: mean.blue),
                          "\(label) \(quadrant.label) expected \(expected.expectedHue) "
                          + "at world \(quadrant.worldMM) uv \(quadrant.uv): "
                          + mean.description,
                          file: file, line: line)
        }
    }

    func testColorMapOriginsSampleAuthoredQuadrantsAtKnownWorldPoints()
        async throws {
        #if canImport(MetalKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            XCTFail("Metal is unavailable: the colour witness requires the "
                    + "real GPU renderer; it must not be skipped or faked.")
            return
        }
        #else
        XCTFail("MetalKit is unavailable in this build; the colour witness "
                + "cannot run and must not be faked.")
        return
        #endif

        let a = try await captureColor(.a)
        let b = try await captureColor(.b)
        let c = try await captureColor(.c)
        attachColor(a); attachColor(b); attachColor(c)

        let pngA = try MaterialRenderWitnessFixture.colorPNG(.a)
        let pngB = try MaterialRenderWitnessFixture.colorPNG(.b)
        let pngC = try MaterialRenderWitnessFixture.colorPNG(.c)
        XCTAssertEqual(pngB, pngC,
                       "B and C must share identical colour bytes; only the "
                       + "declared origin differs")
        XCTAssertNotEqual(pngA, pngB)
        XCTAssertEqual(a.sourceSHA256, CADMaterialTexture.digest(pngA))
        XCTAssertEqual(b.sourceSHA256, CADMaterialTexture.digest(pngB))
        XCTAssertEqual(c.sourceSHA256, CADMaterialTexture.digest(pngC))
        XCTAssertEqual(a.orientation, .topLeft)
        XCTAssertEqual(b.orientation, .bottomLeft)
        XCTAssertEqual(c.orientation, .topLeft)

        // A and B are the same physical samples: the row-inverted bytes are
        // declared bottomLeft, so the shader's per-map V flip restores A.
        let ab = try WitnessPixels.diff(a.pixels, b.pixels)
        XCTAssertLessThanOrEqual(ab.mean, 1.0,
                                 "A/B colour mean delta \(ab.mean) exceeds sampler rounding")
        XCTAssertGreaterThanOrEqual(ab.exactFraction, 0.97,
                                    "A/B colour exact fraction \(ab.exactFraction)")
        XCTAssertLessThanOrEqual(ab.max, 12, "A/B colour max delta \(ab.max)")

        // Absolute authored landmarks. The camera is reconstructed from the
        // same fitted snapshot camera the actual capture uses; the front face
        // corners then give a fixed, eroded material footprint.
        let projection = ColorProjection.engineering(width: a.pixels.width,
                                                     height: a.pixels.height)
        let footprint = try projection.frontFaceFootprint()
        let frameArea = Double(a.pixels.width * a.pixels.height)
        XCTAssertGreaterThanOrEqual(Double(footprint.area) / frameArea, 0.05,
                                    "projected front face is implausibly small: "
                                    + "\(Double(footprint.area) / frameArea)")
        XCTAssertLessThanOrEqual(Double(footprint.area) / frameArea, 0.60,
                                 "projected front face covers too much of the frame: "
                                 + "\(Double(footprint.area) / frameArea)")

        try assertColorLandmarks(a.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "A")
        try assertColorLandmarks(b.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "B")
        // C samples B's row-inverted bytes with topLeft declared, so its
        // authored top/bottom identity must be exactly the vertical mirror.
        try assertColorLandmarks(c.pixels, projection: projection,
                                 footprint: footprint, mirrored: true, label: "C")

        let erosion = CGFloat(max(6, Int(Double(min(a.pixels.width, a.pixels.height)) * 0.02)))
        let acFootprint = a.pixels.footprintDiff(c.pixels, footprint: footprint,
                                                 inset: erosion)
        XCTAssertGreaterThanOrEqual(acFootprint.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(acFootprint.mean, 20.0,
                                    "A/C fixed-footprint mean \(acFootprint.mean) "
                                    + "at \(acFootprint.pixelCount) pixels")
        XCTAssertGreaterThanOrEqual(acFootprint.changedFraction, 0.25,
                                    "A/C fixed-footprint changed fraction "
                                    + "\(acFootprint.changedFraction)")

        let abFootprint = a.pixels.footprintDiff(b.pixels, footprint: footprint,
                                                 inset: erosion)
        XCTAssertLessThanOrEqual(abFootprint.mean, 1.0,
                                 "A/B fixed-footprint mean \(abFootprint.mean)")

        let region = WitnessPixels.regionDiff(a.pixels, c.pixels)
        XCTAssertLessThanOrEqual(region.borderMax, 4,
                                 "A/C border max \(region.borderMax): the background "
                                 + "must be identical across colour variants")
    }

    /// Original X13: ONE material carries an asymmetric 64x64 colour map and
    /// an asymmetric 2x2 normal map with opposite declared origins; the
    /// actual samples must agree across the mixed assignment, and the
    /// reversed normal declaration must still move the actual lighting.
    func testMixedColorAndNormalOriginsRenderOneMaterialAtOnePlace()
        async throws {
        #if canImport(MetalKit)
        guard MTLCreateSystemDefaultDevice() != nil else {
            XCTFail("Metal is unavailable: the mixed-material witness requires "
                    + "the real GPU renderer; it must not be skipped or faked.")
            return
        }
        #else
        XCTFail("MetalKit is unavailable in this build; the mixed-material "
                + "witness cannot run and must not be faked.")
        return
        #endif

        let sourceA = try MaterialRenderWitnessFixture.MixedVariant.a.source
        let sourceB = try MaterialRenderWitnessFixture.MixedVariant.b.source
        let sourceC = try MaterialRenderWitnessFixture.MixedVariant.c.source
        let sourceD = try MaterialRenderWitnessFixture.MixedVariant.d.source

        // Source-level discriminant. A/B/C use the identical colour bytes and
        // declaration; B/C use the identical normal bytes with opposite
        // declarations; D is the lossless row inversion of A's colour bytes
        // declared bottomLeft and reuses A's baseline normal.
        XCTAssertEqual(sourceA.colorPNG, sourceB.colorPNG)
        XCTAssertEqual(sourceB.colorPNG, sourceC.colorPNG)
        XCTAssertEqual(sourceB.normalPNG, sourceC.normalPNG)
        XCTAssertNotEqual(sourceA.normalPNG, sourceB.normalPNG)
        XCTAssertNotEqual(sourceA.colorPNG, sourceD.colorPNG)
        XCTAssertEqual(sourceA.colorOrientation, .topLeft)
        XCTAssertEqual(sourceB.colorOrientation, .topLeft)
        XCTAssertEqual(sourceC.colorOrientation, .topLeft)
        XCTAssertEqual(sourceD.colorOrientation, .bottomLeft)
        XCTAssertEqual(sourceA.normalOrientation, .topLeft)
        XCTAssertEqual(sourceB.normalOrientation, .bottomLeft)
        XCTAssertEqual(sourceC.normalOrientation, .topLeft)
        XCTAssertEqual(sourceD.normalOrientation, .topLeft)

        // ONE BodyMaterialSpec carries both maps with separate typed metadata.
        let authoredBody = MaterialRenderWitnessFixture.mixedSlabBody(sourceA)
        let material = try XCTUnwrap(authoredBody.material)
        XCTAssertEqual(material.baseColorTexture, sourceA.colorPNG,
                       "the same material must carry the colour map")
        XCTAssertEqual(material.normalTexture, sourceA.normalPNG,
                       "the same material must carry the normal map")
        XCTAssertEqual(material.textureMetadata?.count, 2)
        let colorMetadata = try XCTUnwrap(
            material.verifiedTextureMetadata(for: .baseColor))
        let normalMetadata = try XCTUnwrap(
            material.verifiedTextureMetadata(for: .normal))
        XCTAssertEqual(colorMetadata.orientation, .topLeft)
        XCTAssertEqual(normalMetadata.orientation, .topLeft)
        XCTAssertEqual(colorMetadata.sha256,
                       CADMaterialTexture.digest(sourceA.colorPNG))
        XCTAssertEqual(normalMetadata.sha256,
                       CADMaterialTexture.digest(sourceA.normalPNG))

        // Every variant's body carries both maps with its own declared
        // per-slot origin; the actual capture is built from that same body.
        for source in [sourceA, sourceB, sourceC, sourceD] {
            let variantBody = MaterialRenderWitnessFixture.mixedSlabBody(source)
            let variantMaterial = try XCTUnwrap(variantBody.material)
            XCTAssertEqual(variantMaterial.baseColorTexture, source.colorPNG)
            XCTAssertEqual(variantMaterial.normalTexture, source.normalPNG)
            XCTAssertEqual(variantMaterial.verifiedTextureMetadata(for: .baseColor)?.orientation,
                           source.colorOrientation)
            XCTAssertEqual(variantMaterial.verifiedTextureMetadata(for: .normal)?.orientation,
                           source.normalOrientation)
        }

        let a = try await captureMixed(.a)
        let b = try await captureMixed(.b)
        let c = try await captureMixed(.c)
        let d = try await captureMixed(.d)
        attachMixed(a); attachMixed(b); attachMixed(c); attachMixed(d)

        // Actual capture receipts: each image hash is the digest of that
        // capture's own PNG; the authored maps and orientations are the ones
        // asserted above. The four documents differ in material bytes.
        for captured in [a, b, c, d] {
            XCTAssertEqual(captured.imageSHA256,
                           CADMaterialTexture.digest(captured.png))
            XCTAssertEqual(captured.colorSHA256,
                           CADMaterialTexture.digest(captured.source.colorPNG))
            XCTAssertEqual(captured.normalSHA256,
                           CADMaterialTexture.digest(captured.source.normalPNG))
            XCTAssertEqual(captured.renderer, "engineering")
        }
        XCTAssertEqual(a.revision, b.revision)
        XCTAssertEqual(a.revision, c.revision)
        XCTAssertEqual(a.revision, d.revision)
        XCTAssertEqual(a.changeCount, b.changeCount)
        XCTAssertEqual(a.changeCount, c.changeCount)
        XCTAssertEqual(a.changeCount, d.changeCount)
        XCTAssertEqual(Set([a.contentSHA256, b.contentSHA256,
                            c.contentSHA256, d.contentSHA256]).count, 4,
                       "each variant must be its own source-bound document")
        XCTAssertNotEqual(a.imageSHA256, c.imageSHA256,
                          "the reversed normal must produce a different actual frame")
        XCTAssertNotEqual(b.imageSHA256, c.imageSHA256)
        XCTAssertNotEqual(d.imageSHA256, c.imageSHA256)

        let projection = ColorProjection.engineering(width: a.pixels.width,
                                                     height: a.pixels.height)
        let footprint = try projection.frontFaceFootprint()
        let footprintFraction = Double(footprint.area)
            / Double(a.pixels.width * a.pixels.height)
        XCTAssertGreaterThanOrEqual(footprintFraction, 0.05)
        XCTAssertLessThanOrEqual(footprintFraction, 0.60)
        let erosion = CGFloat(max(6, Int(Double(min(a.pixels.width,
                                                      a.pixels.height)) * 0.02)))

        // B is one material with colour topLeft and normal bottomLeft; D is
        // the opposite mixed assignment. Both are physically A and must match
        // under the existing Metal equivalence criterion.
        try assertMixedEquivalent(a, b, footprint: footprint, erosion: erosion,
                                  label: "A/B mixed origins")
        try assertMixedEquivalent(a, d, footprint: footprint, erosion: erosion,
                                  label: "A/D mixed origins")

        // Absolute authored colour landmarks for every variant: A/B/C share
        // A's colour bytes and D is their row inversion declared bottomLeft,
        // so all four must show the authored quadrant identity at the same
        // world/UV points even while the normal maps differ.
        try assertColorLandmarks(a.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "A")
        try assertColorLandmarks(b.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "B")
        try assertColorLandmarks(c.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "C")
        try assertColorLandmarks(d.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "D")

        // Negative control: colour is held fixed byte-for-byte in A/B/C.
        // Measure all RGB channels over the same fixed projected face and
        // retain the original mean >= 8, changed-area and noise gates.
        let acFixed = a.pixels.rgbMeanFootprintDiff(c.pixels, footprint: footprint,
                                                     inset: erosion)
        let abNoise = a.pixels.footprintDiff(b.pixels, footprint: footprint,
                                             inset: erosion)
        let acDiff = try WitnessPixels.diff(a.pixels, c.pixels)
        XCTAssertGreaterThanOrEqual(acFixed.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(acFixed.mean, 8.0,
            "A/C mixed authored-face RGB-channel mean \(acFixed.mean) "
            + "at \(acFixed.pixelCount) pixels; whole-frame mean \(acDiff.mean)")
        XCTAssertGreaterThanOrEqual(acFixed.changedFraction, 0.25,
            "the reversed normal must affect a substantial fixed material area")
        XCTAssertGreaterThanOrEqual(acFixed.mean, 6 * max(abNoise.mean, 0.25),
            "the negative control must dominate the A/B numerical noise")
        let acRegion = WitnessPixels.regionDiff(a.pixels, c.pixels)
        XCTAssertLessThanOrEqual(acRegion.borderMax, 4,
            "A/C mixed border max \(acRegion.borderMax): the background must "
            + "be identical across variants")

        let footprintRecord: [String: Any] = [
            "witness": "X13 mixed colour+normal origins — engineering Metal viewport",
            "physicalEquivalence": ["A", "B", "D"],
            "negativeControl": "C",
            "sameMaterialCarriesBoth": true,
            "wholeFrameACMean": acDiff.mean,
            "fixedACRGBMean": acFixed.mean,
            "fixedACChangedFraction": acFixed.changedFraction,
            "fixedACChangedMean": acFixed.changedMean,
            "fixedABNoiseMean": abNoise.mean,
            "fixedPixelCount": acFixed.pixelCount,
            "projectedFrameFraction": footprintFraction,
            "insetPixels": Double(erosion),
            "polygon": footprint.corners.map { [Double($0.x), Double($0.y)] },
            "source": "Authored +Z face projected from source/capture camera; "
                + "not difference-selected",
        ]
        let footprintAttachment = XCTAttachment(string: String(decoding:
            try JSONSerialization.data(withJSONObject: footprintRecord,
                                       options: [.sortedKeys]),
            as: UTF8.self))
        footprintAttachment.name = "Mixed material fixed footprint"
        footprintAttachment.lifetime = .keepAlways
        add(footprintAttachment)
    }
}
