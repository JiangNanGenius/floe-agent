// SPDX-License-Identifier: MPL-2.0
//
//  CADMaterialGLBRenderWitnessTests.swift
//  FloeAppTests
//
//  X13 REAL renderer witness — pinned App three.js GLB viewer.
//
//  The source-level interop tests only simulate what a glTF consumer would
//  sample; this witness exports the A/B/C fixture slab with the production
//  `GLBExporter` and renders each GLB through the ACTUAL App observation
//  path: `EngineeringObservationService.observe` -> offscreen WKWebView ->
//  the bundled three.js r176 GLTFLoader scene viewer
//  (FloeApp/Resources/EngineeringViewers, hashes pinned in asset-hashes.json)
//  -> real WebGL camera render -> source- and resource-bound PNG frames.
//  A desktop self-importer, JS math or a handmade shader image is not this
//  path and can never count as its evidence.
//
//  Fixture (shared with the Metal/Present witnesses):
//    * NORMAL half: A = topLeft 2x2 normal bytes; B = row-inverted bytes
//      declared bottomLeft (identical physical samples; the exported GLB
//      keeps the exact authored bytes, adds KHR_texture_transform for B, and
//      emits the explicit VEC4 TANGENT from the shared TEXCOORD_0); C = SAME
//      bytes as B declared topLeft (green reversed relative to A; negative
//      control).
//    * COLOR half: A/B/C use the 64x64 four-quadrant sRGB base-colour map
//      under the same origin rules. The absolute landmarks are the authored
//      quadrant identities projected from the known front-face world points
//      through the actual three.js capture camera derived from the frame's
//      azimuth/elevation, the GLB bounds and the bundled viewer's fixed
//      45-degree FOV / 1.35 radius fit.
//
//  Negative-control gate: per the root's explicit fixed-footprint decision,
//  the original whole-frame mean floor is enforced as the same >=8 response
//  over the deterministic projected front-face interior; the whole-frame
//  dominance, p95, max, changed-region and border gates are preserved.
//
//  Provenance asserted for every frame: renderer "threeGLTF", source SHA-256
//  == the exported GLB bytes, requested camera azimuth/elevation, PNG
//  identity, no missing resources, no unsupported extensions (three.js
//  r176 honors both KHR_texture_transform and TANGENT), partial == false.
//  The colour test is additive and does not relax any normal-map assertion.
//
//  MIXED-MATERIAL witness (the original X13 criterion):
//  `testExportedMixedColorAndNormalOriginsRenderOneMaterialAtOnePlace` exports
//  ONE Body material carrying the 64x64 colour map and the 2x2 normal map
//  with separate typed metadata, then renders four variants through the same
//  pinned three.js viewer:
//    A = colour topLeft + normal topLeft;
//    B = the SAME colour topLeft + row-inverted normal bytes declared
//        bottomLeft (opposite declared origins, physically the same samples);
//    C = B's normal bytes wrongly declared topLeft (colour held fixed; only
//        the actual normal lighting may differ);
//    D = row-inverted colour bytes declared bottomLeft + the baseline
//        topLeft normal (the opposite mixed assignment, physically A).
//  A, B and D must match under the viewer's existing A/B equivalence
//  criterion; C must show a material response over the same projected
//  front-face footprint. Absolute colour landmarks are asserted for ALL four
//  variants, so a viewer that drops either map, swaps a per-map origin, or
//  serves a cached image cannot pass. Every frame attaches its actual PNG and
//  a manifest carrying both authored image SHAs/origins/slots.
//

#if canImport(UIKit)
import Foundation
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import simd
@testable import FloeApp
@testable import FloeCAD
import FloeCore
import FloeWorkbench
import FloeWorkspace

@MainActor
final class CADMaterialGLBRenderWitnessTests: XCTestCase {
    private var workspaces: [URL] = []

    override func tearDown() async throws {
        for workspace in workspaces {
            try? FileManager.default.removeItem(at: workspace)
        }
        workspaces = []
    }

    // MARK: Fixture (constants pinned with the native witnesses)

    private enum Fixture {
        static let slabMinMM = SIMD3<Float>(-50, -50, 0)
        static let slabMaxMM = SIMD3<Float>(50, 50, 12)
        static let frontFaceZMM: Float = 12
        static let modelMillimetresPerMeter: Float = 0.001

        // Green 255/0 gives maximal endpoint tangent-Y variation under row
        // reversal; red 96/160 per column.
        static let rowTop: [[UInt8]] = [[96, 255, 164, 255], [160, 255, 164, 255]]
        static let rowBottom: [[UInt8]] = [[96, 0, 164, 255], [160, 0, 164, 255]]

        enum Variant: String {
            case a, b, c
            var rows: [[UInt8]] {
                switch self {
                case .a: return Fixture.rowTop + Fixture.rowBottom
                case .b, .c: return Fixture.rowBottom + Fixture.rowTop
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

        /// Closed 100x100x12 mm slab shared by the normal and colour
        /// witnesses. The GLB exporter bakes positions in mm and the root
        /// node applies 0.001, so the viewer bounds are in metres.
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
                            render: RenderMesh(positions: positions,
                                               normals: normals,
                                               indices: indices,
                                               texcoords: texcoords),
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

        /// Four solid quadrants in authored top-left row order:
        /// red | green
        /// -----+------
        /// blue| yellow
        static let colorTopRow: [UInt8] = {
            var row: [UInt8] = []
            row.reserveCapacity(Fixture.colorWidth * 4)
            for column in 0..<Fixture.colorWidth {
                row.append(contentsOf: column < Fixture.colorWidth / 2
                           ? [255, 0, 0, 255] : [0, 255, 0, 255])
            }
            return row
        }()
        static let colorBottomRow: [UInt8] = {
            var row: [UInt8] = []
            row.reserveCapacity(Fixture.colorWidth * 4)
            for column in 0..<Fixture.colorWidth {
                row.append(contentsOf: column < Fixture.colorWidth / 2
                           ? [0, 0, 255, 255] : [255, 255, 0, 255])
            }
            return row
        }()

        enum ColorVariant: String {
            case a, b, c

            var rows: [[UInt8]] {
                switch self {
                case .a:
                    return Array(repeating: Fixture.colorTopRow,
                                 count: Fixture.colorHeight / 2)
                        + Array(repeating: Fixture.colorBottomRow,
                                count: Fixture.colorHeight / 2)
                case .b, .c:
                    return Array(repeating: Fixture.colorBottomRow,
                                 count: Fixture.colorHeight / 2)
                        + Array(repeating: Fixture.colorTopRow,
                                count: Fixture.colorHeight / 2)
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
            try png(width: Fixture.colorWidth, height: Fixture.colorHeight, rows: variant.rows)
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

        /// One authored material carrying BOTH maps. The typed metadata
        /// records are separate per slot, exactly like a real imported
        /// material whose colour map and normal map were authored in
        /// opposite vertical directions.
        struct MixedSource {
            var colorPNG: Data
            var colorOrientation: MaterialTextureOrientation
            var normalPNG: Data
            var normalOrientation: MaterialTextureOrientation
        }

        enum MixedVariant: String, CaseIterable {
            case a, b, c, d

            /// A/B/C keep the exact authored colour bytes at topLeft; D is
            /// the lossless row inversion declared bottomLeft. B/C share the
            /// exact row-inverted normal bytes; only their declared normal
            /// origin differs. Every variant is one material carrying both.
            var source: MixedSource {
                get throws {
                    switch self {
                    case .a:
                        return MixedSource(
                            colorPNG: try Fixture.colorPNG(.a),
                            colorOrientation: .topLeft,
                            normalPNG: try Fixture.normalPNG(.a),
                            normalOrientation: .topLeft)
                    case .b:
                        return MixedSource(
                            colorPNG: try Fixture.colorPNG(.a),
                            colorOrientation: .topLeft,
                            normalPNG: try Fixture.normalPNG(.b),
                            normalOrientation: .bottomLeft)
                    case .c:
                        return MixedSource(
                            colorPNG: try Fixture.colorPNG(.a),
                            colorOrientation: .topLeft,
                            normalPNG: try Fixture.normalPNG(.b),
                            normalOrientation: .topLeft)
                    case .d:
                        return MixedSource(
                            colorPNG: try Fixture.colorPNG(.b),
                            colorOrientation: .bottomLeft,
                            normalPNG: try Fixture.normalPNG(.a),
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
                baseColorTexture: source.colorPNG,
                normalTexture: source.normalPNG,
                uvMapping: .mesh,
                textureMetadata: [colorMetadata, normalMetadata]),
                name: "X13 mixed-origin witness slab")
        }
    }

    private struct WitnessPixels {
        var width: Int
        var height: Int
        var rgba: [UInt8]

        static func decode(_ png: Data) throws -> WitnessPixels {
            let source = try XCTUnwrap(
                CGImageSourceCreateWithData(png as CFData, nil),
                "frame must be a decodable PNG")
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let width = image.width, height = image.height
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            try rgba.withUnsafeMutableBytes { storage in
                let context = try XCTUnwrap(CGContext(
                    data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return WitnessPixels(width: width, height: height, rgba: rgba)
        }

        struct DiffStats {
            var mean: Double
            var max: Int
            var exactFraction: Double
            var p95: Int
            var distinct: Int
        }

        func stats() -> DiffStats {
            var distinct = Set<UInt32>()
            let count = width * height
            distinct.reserveCapacity(min(count, 1 << 20))
            for pixel in 0..<count {
                let base = pixel * 4
                distinct.insert((UInt32(rgba[base]) << 16)
                                | (UInt32(rgba[base + 1]) << 8)
                                | UInt32(rgba[base + 2]))
            }
            return DiffStats(mean: 0, max: 0, exactFraction: 0, p95: 0,
                             distinct: distinct.count)
        }

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

        static func diff(_ lhs: WitnessPixels, _ rhs: WitnessPixels) throws -> DiffStats {
            XCTAssertEqual(lhs.width, rhs.width)
            XCTAssertEqual(lhs.height, rhs.height)
            _ = try XCTUnwrap(lhs.width == rhs.width && lhs.height == rhs.height ? true : nil,
                              "Renderer variants must have identical dimensions")
            let count = lhs.width * lhs.height
            var total = 0
            var maximum = 0
            var exact = 0
            var samples: [Int] = []
            samples.reserveCapacity(count * 3)
            for pixel in 0..<count {
                let base = pixel * 4
                for channel in 0..<3 {
                    let d = abs(Int(lhs.rgba[base + channel])
                                - Int(rhs.rgba[base + channel]))
                    total += d
                    maximum = max(maximum, d)
                    if d == 0 { exact += 1 } else { samples.append(d) }
                }
            }
            samples.sort()
            let p95 = samples.isEmpty ? 0 : samples[(samples.count - 1) * 95 / 100]
            var stats = lhs.stats()
            stats.mean = Double(total) / Double(count * 3)
            stats.max = maximum
            stats.exactFraction = Double(exact) / Double(count * 3)
            stats.p95 = p95
            return stats
        }
    }

    // MARK: Absolute colour-landmark projection (actual three.js capture camera)

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
        var worldScale: Float

        /// Reproduce the bundled `scene.js` capture camera exactly: world
        /// bounds from the GLB root (mm x 0.001), a 45-degree perspective
        /// lens, distance = radius / sin(fov/2) * 1.35 * distanceScale and
        /// lookAt(center) with +Y up. `azimuth`/`elevation` come from the
        /// actual frame metadata, not from a test-chosen pose.
        static func threeGLB(azimuthDegrees: Double, elevationDegrees: Double,
                             distanceScale: Double, width: Int, height: Int) -> ColorProjection {
            threeGLB(azimuthDegrees: azimuthDegrees,
                     elevationDegrees: elevationDegrees,
                     distanceScale: distanceScale, width: width, height: height,
                     boundsMinMM: Fixture.slabMinMM,
                     boundsMaxMM: Fixture.slabMaxMM)
        }

        /// Same pinned three.js camera math, for a GLB whose real accessor
        /// bounds are the X14 kernel box rather than the X13 slab.
        static func threeGLB(azimuthDegrees: Double, elevationDegrees: Double,
                             distanceScale: Double, width: Int, height: Int,
                             boundsMinMM: SIMD3<Float>,
                             boundsMaxMM: SIMD3<Float>) -> ColorProjection {
            let boundsMin = boundsMinMM * Fixture.modelMillimetresPerMeter
            let boundsMax = boundsMaxMM * Fixture.modelMillimetresPerMeter
            let center = (boundsMin + boundsMax) * 0.5
            let radius = max(simd_length(boundsMax - boundsMin) * 0.5, 1e-4)
            let fov = Float(45) * .pi / 180
            let azimuth = Float(azimuthDegrees) * .pi / 180
            let elevation = Float(elevationDegrees) * .pi / 180
            let direction = SIMD3<Float>(cos(elevation) * sin(azimuth),
                                         sin(elevation),
                                         cos(elevation) * cos(azimuth))
            let distance = radius / sin(fov * 0.5) * 1.35 * Float(distanceScale)
            let eye = center + direction * distance
            let aspect = Float(width) / Float(max(height, 1))
            let view = Matrices.lookAt(eye: eye, target: center,
                                       up: SIMD3<Float>(0, 1, 0))
            let lens = Matrices.perspective(
                fovYRadians: fov, aspect: aspect,
                near: max(radius / 10_000, 1e-6), far: max(radius * 10_000, 100))
            return ColorProjection(matrix: lens * view, width: width,
                                   height: height,
                                   worldScale: Fixture.modelMillimetresPerMeter)
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
                SIMD3<Float>(Fixture.slabMinMM.x, Fixture.slabMinMM.y, Fixture.frontFaceZMM),
                SIMD3<Float>(Fixture.slabMaxMM.x, Fixture.slabMinMM.y, Fixture.frontFaceZMM),
                SIMD3<Float>(Fixture.slabMaxMM.x, Fixture.slabMaxMM.y, Fixture.frontFaceZMM),
                SIMD3<Float>(Fixture.slabMinMM.x, Fixture.slabMaxMM.y, Fixture.frontFaceZMM),
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

        var worldMM: SIMD3<Float> {
            SIMD3<Float>(-50 + 100 * uv.x, -50 + 100 * uv.y, Fixture.frontFaceZMM)
        }

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

    private func colorMean(in pixels: WitnessPixels, at point: CGPoint, radius: Int,
                           footprint: WitnessFootprint) -> ColorMean? {
        let cx = Int(point.x.rounded())
        let cy = Int(point.y.rounded())
        let minX = max(0, cx - radius)
        let maxX = min(pixels.width - 1, cx + radius)
        let minY = max(0, cy - radius)
        let maxY = min(pixels.height - 1, cy + radius)
        guard minX <= maxX, minY <= maxY else { return nil }
        var red = 0, green = 0, blue = 0, count = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard footprint.contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) else {
                    continue
                }
                let base = (y * pixels.width + x) * 4
                red += Int(pixels.rgba[base])
                green += Int(pixels.rgba[base + 1])
                blue += Int(pixels.rgba[base + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return ColorMean(red: Double(red) / Double(count),
                         green: Double(green) / Double(count),
                         blue: Double(blue) / Double(count), count: count)
    }

    private func footprintDiff(_ lhs: WitnessPixels, _ rhs: WitnessPixels,
                               footprint: WitnessFootprint,
                               inset: CGFloat = 0,
                               noiseFloor: Int = 4) -> ColorFootprintStats {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return ColorFootprintStats(mean: .infinity, changedFraction: 0,
                                       pixelCount: 0)
        }
        var total = 0
        var changed = 0
        var count = 0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                guard footprint.contains(CGPoint(x: CGFloat(x), y: CGFloat(y)), inset: inset) else {
                    continue
                }
                count += 1
                let base = (y * lhs.width + x) * 4
                var dmax = 0
                for channel in 0..<3 {
                    let delta = abs(Int(lhs.rgba[base + channel])
                                    - Int(rhs.rgba[base + channel]))
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
    private func rgbMeanFootprintDiff(_ lhs: WitnessPixels, _ rhs: WitnessPixels,
                                       footprint: WitnessFootprint,
                                       inset: CGFloat = 0,
                                       noiseFloor: Int = 4) -> MixedFootprintStats {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return MixedFootprintStats(mean: .infinity, changedFraction: 0,
                                          changedMean: .infinity, pixelCount: 0)
        }
        var total = 0
        var changed = 0
        var changedTotal = 0
        var count = 0
        for y in 0..<lhs.height {
            for x in 0..<lhs.width {
                guard footprint.contains(CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                        inset: inset) else {
                    continue
                }
                count += 1
                let base = (y * lhs.width + x) * 4
                var dmax = 0
                var channelTotal = 0
                for channel in 0..<3 {
                    let delta = abs(Int(lhs.rgba[base + channel]) - Int(rhs.rgba[base + channel]))
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

    private struct MixedFootprintStats {
        var mean: Double
        var changedFraction: Double
        var changedMean: Double
        var pixelCount: Int
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
                colorMean(in: pixels, at: point, radius: radius, footprint: footprint),
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

    private struct Observed {
        var variantName: String
        var sourcePNG: Data
        var orientation: MaterialTextureOrientation
        var glb: Data
        var glbSHA256: String
        var framePNG: Data
        var pixels: WitnessPixels
        var metadataJSON: String
        var summaryJSON: String
        var azimuthDegrees: Double
        var elevationDegrees: Double
        var distanceScale: Double
    }

    private func observe(_ variant: Fixture.Variant,
                         in workspace: URL) async throws -> Observed {
        let png = try Fixture.normalPNG(variant)
        let body = Fixture.slabBody(normalPNG: png, orientation: variant.orientation)
        return try await observe(body: body, sourcePNG: png,
                                 orientation: variant.orientation,
                                 variantName: variant.displayName,
                                 rawName: variant.rawValue, in: workspace)
    }

    private func observeColor(_ variant: Fixture.ColorVariant,
                              in workspace: URL) async throws -> Observed {
        let png = try Fixture.colorPNG(variant)
        let body = Fixture.colorSlabBody(colorPNG: png, orientation: variant.orientation)
        return try await observe(body: body, sourcePNG: png,
                                 orientation: variant.orientation,
                                 variantName: variant.displayName,
                                 rawName: "color-\(variant.rawValue)", in: workspace)
    }

    /// Render one exported GLB through the real observation service and
    /// refuse anything that is not a complete, source-bound threeGLTF frame.
    private func observe(body: Body, sourcePNG: Data,
                         orientation: MaterialTextureOrientation,
                         variantName: String, rawName: String,
                         in workspace: URL) async throws -> Observed {
        let glb = GLBExporter.glb(bodies: [body])
        XCTAssertFalse(glb.isEmpty)
        let name = "witness-\(rawName).glb"
        try glb.write(to: workspace.appendingPathComponent(name))
        let digest = FloeDigest.sha256Hex(glb)
        let service = WorkspaceFileService(
            guard: WorkspacePathGuard(rootURL: workspace))
        let distanceScale = 1.0
        let request = CadModelObservationRequest(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20,
                          distanceScale: distanceScale)],
            width: 640, height: 480,
            expectedSourceSHA256: digest, includeImages: true)
        let result = try await EngineeringObservationService.shared.observe(
            path: name, service: service, request: request)
        XCTAssertEqual(result.frames.count, 1,
                       "one requested camera view must produce one frame")
        let frame = try XCTUnwrap(result.frames.first)
        let summary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.summaryJSON.utf8))
                as? [String: Any])
        // Actual renderer + no fallback: the pinned three.js GLTF scene path
        // must have produced complete frames for the exact source bytes.
        XCTAssertEqual(summary["partial"] as? Bool, false,
                       "observation must be complete: \(result.summaryJSON)")
        XCTAssertEqual(summary["sourceUnchanged"] as? Bool, true)
        let state = try XCTUnwrap(summary["state"] as? [String: Any])
        let missing = try XCTUnwrap(state["missingResources"] as? [Any])
        let unsupported = try XCTUnwrap(state["unsupportedExtensions"] as? [Any])
        XCTAssertEqual(missing.count, 0,
                       "a self-contained GLB must not report missing resources")
        XCTAssertEqual(unsupported.count, 0,
                       "three.js r176 must honor KHR_texture_transform and the "
                       + "explicit TANGENT accessor")
        let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(frame.metadataJSON.utf8)) as? [String: Any])
        XCTAssertEqual(metadata["renderer"] as? String, "threeGLTF")
        XCTAssertEqual(metadata["sourceSHA256"] as? String, digest)
        XCTAssertEqual(metadata["imageSHA256"] as? String, FloeDigest.sha256Hex(frame.pngData))
        XCTAssertEqual(try XCTUnwrap(metadata["azimuthDegrees"] as? Double), 35, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(metadata["elevationDegrees"] as? Double), 20, accuracy: 1e-9)
        let azimuth = try XCTUnwrap(metadata["azimuthDegrees"] as? Double)
        let elevation = try XCTUnwrap(metadata["elevationDegrees"] as? Double)
        let pixels = try WitnessPixels.decode(frame.pngData)
        XCTAssertGreaterThanOrEqual(pixels.stats().distinct, 8,
                                    "a real WebGL render has many colors; a "
                                    + "blank canvas cannot witness anything")
        return Observed(variantName: variantName, sourcePNG: sourcePNG,
                        orientation: orientation, glb: glb, glbSHA256: digest,
                        framePNG: frame.pngData, pixels: pixels,
                        metadataJSON: frame.metadataJSON,
                        summaryJSON: result.summaryJSON,
                        azimuthDegrees: azimuth, elevationDegrees: elevation,
                        distanceScale: distanceScale)
    }

    private func attach(_ observed: Observed) {
        let png = XCTAttachment(data: observed.framePNG, uniformTypeIdentifier: UTType.png.identifier)
        png.name = "x13-threejs-\(observed.variantName)"
        png.lifetime = .keepAlways
        add(png)
        let glb = XCTAttachment(data: observed.glb)
        glb.name = "x13-threejs-\(observed.variantName).glb"
        glb.lifetime = .keepAlways
        add(glb)
        let manifest: [String: Any] = [
            "witness": "X13 normal-map origins — pinned App three.js GLB viewer",
            "variant": observed.variantName,
            "renderer": "threeGLTF (bundled three.js r176 GLTFLoader scene)",
            "sourceGLBSHA256": observed.glbSHA256,
            "frameMetadata": observed.metadataJSON,
            "captureEntryPoint": "EngineeringObservationService.observe",
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-threejs-\(observed.variantName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    private func attachColor(_ observed: Observed) {
        let png = XCTAttachment(data: observed.framePNG,
                                uniformTypeIdentifier: UTType.png.identifier)
        png.name = "x13-threejs-colour-\(observed.variantName)"
        png.lifetime = .keepAlways
        add(png)
        let glb = XCTAttachment(data: observed.glb)
        glb.name = "x13-threejs-colour-\(observed.variantName).glb"
        glb.lifetime = .keepAlways
        add(glb)
        let manifest: [String: Any] = [
            "witness": "X13 colour-map origins — pinned App three.js GLB viewer (absolute UV landmarks)",
            "variant": observed.variantName,
            "renderer": "threeGLTF (bundled three.js r176 GLTFLoader scene)",
            "sourceGLBSHA256": observed.glbSHA256,
            "renderedImageSHA256": FloeDigest.sha256Hex(observed.framePNG),
            "authoredColorMapBytesSHA256": FloeDigest.sha256Hex(observed.sourcePNG),
            "authoredColorMapOrientation": "\(observed.orientation)",
            "authoredColorMapColorSpace": "srgb",
            "frameMetadata": observed.metadataJSON,
            "captureEntryPoint": "EngineeringObservationService.observe",
            "landmarkCamera": "scene.js capture: center/radius bounds, fov 45, "
                + "distance = radius/sin(fov/2)*1.35*distanceScale, lookAt(center)",
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-threejs-colour-\(observed.variantName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    // MARK: Mixed-material actual export + observation

    private struct MixedCaptured {
        var observation: Observed
        var source: Fixture.MixedSource
        var colorSHA256: String
        var normalSHA256: String
    }

    /// Export ONE body that carries BOTH maps and render it through the same
    /// actual `EngineeringObservationService.observe` path used above.
    private func observeMixed(_ variant: Fixture.MixedVariant,
                              in workspace: URL) async throws -> MixedCaptured {
        let source = try variant.source
        let body = Fixture.mixedSlabBody(source)
        let observed = try await observe(
            body: body, sourcePNG: source.normalPNG,
            orientation: source.normalOrientation,
            variantName: variant.displayName,
            rawName: "mixed-\(variant.rawValue)", in: workspace)
        return MixedCaptured(
            observation: observed, source: source,
            colorSHA256: FloeDigest.sha256Hex(source.colorPNG),
            normalSHA256: FloeDigest.sha256Hex(source.normalPNG))
    }

    private func attachMixed(_ mixed: MixedCaptured) {
        let observed = mixed.observation
        let png = XCTAttachment(data: observed.framePNG,
                                uniformTypeIdentifier: UTType.png.identifier)
        png.name = "x13-threejs-mixed-\(observed.variantName)"
        png.lifetime = .keepAlways
        add(png)
        let colorSource = XCTAttachment(data: mixed.source.colorPNG,
                                        uniformTypeIdentifier: UTType.png.identifier)
        colorSource.name = "x13-threejs-mixed-\(observed.variantName)-baseColor-source.png"
        colorSource.lifetime = .keepAlways
        add(colorSource)
        let normalSource = XCTAttachment(data: mixed.source.normalPNG,
                                         uniformTypeIdentifier: UTType.png.identifier)
        normalSource.name = "x13-threejs-mixed-\(observed.variantName)-normal-source.png"
        normalSource.lifetime = .keepAlways
        add(normalSource)
        let glb = XCTAttachment(data: observed.glb)
        glb.name = "x13-threejs-mixed-\(observed.variantName).glb"
        glb.lifetime = .keepAlways
        add(glb)
        let manifest: [String: Any] = [
            "witness": "X13 mixed colour+normal map origins — pinned App three.js GLB viewer",
            "variant": observed.variantName,
            "renderer": "threeGLTF (bundled three.js r176 GLTFLoader scene)",
            "sameMaterialCarriesBoth": true,
            "materialTextureSlots": ["baseColor", "normal"],
            "baseColorMap": [
                "slot": "baseColor",
                "bytesSHA256": mixed.colorSHA256,
                "orientation": "\(mixed.source.colorOrientation)",
                "colorSpace": "srgb",
                "mimeType": "image/png",
                "byteCount": mixed.source.colorPNG.count,
            ],
            "normalMap": [
                "slot": "normal",
                "bytesSHA256": mixed.normalSHA256,
                "orientation": "\(mixed.source.normalOrientation)",
                "colorSpace": "linear",
                "mimeType": "image/png",
                "byteCount": mixed.source.normalPNG.count,
            ],
            "sourceGLBSHA256": observed.glbSHA256,
            "renderedImageSHA256": FloeDigest.sha256Hex(observed.framePNG),
            "frameMetadata": observed.metadataJSON,
            "documentReceipt": "body-level GLB export: source identity is the "
                + "actual GLB SHA and the frame sourceSHA256/imageSHA256; there "
                + "is no FloeCADDocument revision/changeCount on this path",
            "captureEntryPoint": "EngineeringObservationService.observe",
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-threejs-mixed-\(observed.variantName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    private func assertMixedEquivalent(_ lhs: MixedCaptured, _ rhs: MixedCaptured,
                                       footprint: WitnessFootprint, erosion: CGFloat,
                                       label: String) throws {
        let diff = try WitnessPixels.diff(lhs.observation.pixels,
                                          rhs.observation.pixels)
        XCTAssertLessThanOrEqual(diff.mean, 2.0,
                                 "\(label) mixed mean \(diff.mean) exceeds the "
                                 + "existing GLB A/B tolerance")
        XCTAssertGreaterThanOrEqual(diff.exactFraction, 0.95,
                                    "\(label) mixed exact fraction "
                                    + "\(diff.exactFraction)")
        XCTAssertLessThanOrEqual(diff.max, 24, "\(label) mixed max \(diff.max)")
        let fixed = footprintDiff(lhs.observation.pixels, rhs.observation.pixels,
                                  footprint: footprint, inset: erosion)
        XCTAssertGreaterThanOrEqual(fixed.pixelCount, 1_000)
        XCTAssertLessThanOrEqual(fixed.mean, 2.0,
                                 "\(label) mixed fixed-footprint mean \(fixed.mean)")
    }

    func testExportedOppositeNormalOriginsRenderIdenticallyAndReversedGreenDoesNot()
        async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("X13GLBWitness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        workspaces.append(workspace)

        let pngA = try Fixture.normalPNG(.a)
        let pngB = try Fixture.normalPNG(.b)
        let pngC = try Fixture.normalPNG(.c)
        XCTAssertEqual(pngB, pngC,
                       "B and C must share identical bytes; only the declared "
                       + "origin differs")
        XCTAssertNotEqual(pngA, pngB)

        let a = try await observe(.a, in: workspace)
        let b = try await observe(.b, in: workspace)
        let c = try await observe(.c, in: workspace)
        attach(a); attach(b); attach(c)
        XCTAssertNotEqual(a.glbSHA256, b.glbSHA256)
        XCTAssertNotEqual(a.glbSHA256, c.glbSHA256)

        let ab = try WitnessPixels.diff(a.pixels, b.pixels)
        let ac = try WitnessPixels.diff(a.pixels, c.pixels)

        // A and B carry identical physical normals (exact bytes + KHR flip
        // for B + explicit shared-UV TANGENT). The pinned three.js r176 path
        // samples both with the same basis, so the WebGL renders must match
        // to sampler precision across the two independent observation jobs.
        XCTAssertLessThanOrEqual(ab.mean, 2.0,
                                 "A/B mean delta \(ab.mean) in the GLB viewer")
        XCTAssertGreaterThanOrEqual(ab.exactFraction, 0.95)
        XCTAssertLessThanOrEqual(ab.max, 24, "A/B max delta \(ab.max)")

        // Negative control: reversed green must dominate.
        XCTAssertEqual(a.azimuthDegrees, b.azimuthDegrees, accuracy: 1e-9)
        XCTAssertEqual(a.azimuthDegrees, c.azimuthDegrees, accuracy: 1e-9)
        XCTAssertEqual(a.elevationDegrees, b.elevationDegrees, accuracy: 1e-9)
        XCTAssertEqual(a.elevationDegrees, c.elevationDegrees, accuracy: 1e-9)
        XCTAssertEqual(a.distanceScale, b.distanceScale, accuracy: 1e-9)
        XCTAssertEqual(a.distanceScale, c.distanceScale, accuracy: 1e-9)
        let projection = ColorProjection.threeGLB(
            azimuthDegrees: a.azimuthDegrees, elevationDegrees: a.elevationDegrees,
            distanceScale: a.distanceScale, width: a.pixels.width, height: a.pixels.height)
        let footprint = try projection.frontFaceFootprint()
        let footprintFraction = Double(footprint.area) / Double(a.pixels.width * a.pixels.height)
        XCTAssertGreaterThanOrEqual(footprintFraction, 0.05)
        XCTAssertLessThanOrEqual(footprintFraction, 0.60)
        let erosion = CGFloat(max(6, Int(Double(min(a.pixels.width, a.pixels.height)) * 0.02)))
        let fixedAC = footprintDiff(a.pixels, c.pixels, footprint: footprint, inset: erosion)
        let fixedAB = footprintDiff(a.pixels, b.pixels, footprint: footprint, inset: erosion)
        XCTAssertGreaterThanOrEqual(fixedAC.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(fixedAC.mean, 8.0,
            "A/C authored-face mean \(fixedAC.mean); full-frame mean \(ac.mean)")
        XCTAssertGreaterThanOrEqual(fixedAC.changedFraction, 0.25,
            "Normal negative control must affect a substantial fixed material area")
        XCTAssertLessThanOrEqual(fixedAB.mean, 2.0)
        XCTAssertGreaterThanOrEqual(fixedAC.mean, 4 * max(fixedAB.mean, 0.5))
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
        XCTAssertGreaterThanOrEqual(ac.p95, 32)
        XCTAssertGreaterThanOrEqual(ac.max, 48, "A/C max delta \(ac.max)")
        XCTAssertGreaterThanOrEqual(ac.mean, 4 * max(ab.mean, 0.5),
                                    "the negative control must dominate "
                                    + "numerical noise")
    }

    func testExportedColorMapOriginsSampleAuthoredQuadrantsAtKnownWorldPoints()
        async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("X13GLBColourWitness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        workspaces.append(workspace)

        let pngA = try Fixture.colorPNG(.a)
        let pngB = try Fixture.colorPNG(.b)
        let pngC = try Fixture.colorPNG(.c)
        XCTAssertEqual(pngB, pngC,
                       "B and C must share identical colour bytes; only the "
                       + "declared origin differs")
        XCTAssertNotEqual(pngA, pngB)

        let a = try await observeColor(.a, in: workspace)
        let b = try await observeColor(.b, in: workspace)
        let c = try await observeColor(.c, in: workspace)
        attachColor(a); attachColor(b); attachColor(c)
        XCTAssertEqual(FloeDigest.sha256Hex(a.sourcePNG), CADMaterialTexture.digest(pngA))
        XCTAssertEqual(FloeDigest.sha256Hex(b.sourcePNG), CADMaterialTexture.digest(pngB))
        XCTAssertEqual(FloeDigest.sha256Hex(c.sourcePNG), CADMaterialTexture.digest(pngC))
        XCTAssertEqual(a.orientation, .topLeft)
        XCTAssertEqual(b.orientation, .bottomLeft)
        XCTAssertEqual(c.orientation, .topLeft)
        XCTAssertNotEqual(a.glbSHA256, b.glbSHA256,
                          "B must export KHR_texture_transform, not A's bytes")
        XCTAssertNotEqual(a.glbSHA256, c.glbSHA256)

        let ab = try WitnessPixels.diff(a.pixels, b.pixels)
        XCTAssertLessThanOrEqual(ab.mean, 2.0,
                                 "A/B colour mean delta \(ab.mean) in the GLB viewer")
        XCTAssertGreaterThanOrEqual(ab.exactFraction, 0.95)
        XCTAssertLessThanOrEqual(ab.max, 24, "A/B colour max delta \(ab.max)")

        // The frame receipt is the actual camera pose; the bundled viewer's
        // fixed 45-degree lens and 1.35 radius fit are source constants in
        // FloeApp/Resources/EngineeringViewers/scene.js.
        XCTAssertEqual(a.azimuthDegrees, b.azimuthDegrees, accuracy: 1e-9)
        XCTAssertEqual(a.azimuthDegrees, c.azimuthDegrees, accuracy: 1e-9)
        XCTAssertEqual(a.elevationDegrees, b.elevationDegrees, accuracy: 1e-9)
        XCTAssertEqual(a.elevationDegrees, c.elevationDegrees, accuracy: 1e-9)
        let projection = ColorProjection.threeGLB(
            azimuthDegrees: a.azimuthDegrees,
            elevationDegrees: a.elevationDegrees,
            distanceScale: a.distanceScale,
            width: a.pixels.width, height: a.pixels.height)
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
        try assertColorLandmarks(c.pixels, projection: projection,
                                 footprint: footprint, mirrored: true, label: "C")

        let erosion = CGFloat(max(6, Int(Double(min(a.pixels.width, a.pixels.height)) * 0.02)))
        let acFootprint = footprintDiff(a.pixels, c.pixels, footprint: footprint,
                                        inset: erosion)
        XCTAssertGreaterThanOrEqual(acFootprint.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(acFootprint.mean, 20.0,
                                    "A/C fixed-footprint mean \(acFootprint.mean) "
                                    + "at \(acFootprint.pixelCount) pixels")
        XCTAssertGreaterThanOrEqual(acFootprint.changedFraction, 0.25,
                                    "A/C fixed-footprint changed fraction "
                                    + "\(acFootprint.changedFraction)")

        let abFootprint = footprintDiff(a.pixels, b.pixels, footprint: footprint,
                                        inset: erosion)
        XCTAssertLessThanOrEqual(abFootprint.mean, 2.0,
                                 "A/B fixed-footprint mean \(abFootprint.mean)")
    }

    /// Original X13: ONE exported material carries an asymmetric 64x64 colour
    /// map and an asymmetric 2x2 normal map with opposite declared origins;
    /// the actual three.js samples must agree across the mixed assignment, and
    /// the reversed normal declaration must still move the actual lighting.
    func testExportedMixedColorAndNormalOriginsRenderOneMaterialAtOnePlace()
        async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("X13GLBMixedWitness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        workspaces.append(workspace)

        let sourceA = try Fixture.MixedVariant.a.source
        let sourceB = try Fixture.MixedVariant.b.source
        let sourceC = try Fixture.MixedVariant.c.source
        let sourceD = try Fixture.MixedVariant.d.source

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
        let authoredBody = Fixture.mixedSlabBody(sourceA)
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
            let variantBody = Fixture.mixedSlabBody(source)
            let variantMaterial = try XCTUnwrap(variantBody.material)
            XCTAssertEqual(variantMaterial.baseColorTexture, source.colorPNG)
            XCTAssertEqual(variantMaterial.normalTexture, source.normalPNG)
            XCTAssertEqual(variantMaterial.verifiedTextureMetadata(for: .baseColor)?.orientation,
                           source.colorOrientation)
            XCTAssertEqual(variantMaterial.verifiedTextureMetadata(for: .normal)?.orientation,
                           source.normalOrientation)
        }

        let a = try await observeMixed(.a, in: workspace)
        let b = try await observeMixed(.b, in: workspace)
        let c = try await observeMixed(.c, in: workspace)
        let d = try await observeMixed(.d, in: workspace)
        attachMixed(a); attachMixed(b); attachMixed(c); attachMixed(d)

        // Actual export/frame receipts: each GLB is the source of its own
        // observation, each frame hash is the digest of that frame's PNG, and
        // the four exported GLBs differ in material textures/origins.
        for mixed in [a, b, c, d] {
            let observed = mixed.observation
            XCTAssertEqual(observed.glbSHA256,
                           FloeDigest.sha256Hex(observed.glb))
            XCTAssertEqual(mixed.colorSHA256, FloeDigest.sha256Hex(mixed.source.colorPNG))
            XCTAssertEqual(mixed.normalSHA256, FloeDigest.sha256Hex(mixed.source.normalPNG))
            XCTAssertEqual(observed.azimuthDegrees, 35, accuracy: 1e-9)
            XCTAssertEqual(observed.elevationDegrees, 20, accuracy: 1e-9)
        }
        XCTAssertEqual(Set([a.observation.glbSHA256, b.observation.glbSHA256,
                            c.observation.glbSHA256,
                            d.observation.glbSHA256]).count, 4,
                       "each variant must export its own source-bound GLB")
        XCTAssertNotEqual(a.observation.framePNG, c.observation.framePNG,
                          "the reversed normal must produce a different actual frame")
        XCTAssertNotEqual(b.observation.framePNG, c.observation.framePNG)
        XCTAssertNotEqual(d.observation.framePNG, c.observation.framePNG)
        XCTAssertNotEqual(a.observation.sourcePNG, b.observation.sourcePNG)
        XCTAssertEqual(b.observation.sourcePNG, c.observation.sourcePNG)
        XCTAssertEqual(a.observation.orientation, .topLeft)
        XCTAssertEqual(b.observation.orientation, .bottomLeft)
        XCTAssertEqual(c.observation.orientation, .topLeft)
        XCTAssertEqual(d.observation.orientation, .topLeft)

        let projection = ColorProjection.threeGLB(
            azimuthDegrees: a.observation.azimuthDegrees,
            elevationDegrees: a.observation.elevationDegrees,
            distanceScale: a.observation.distanceScale,
            width: a.observation.pixels.width,
            height: a.observation.pixels.height)
        let footprint = try projection.frontFaceFootprint()
        let footprintFraction = Double(footprint.area)
            / Double(a.observation.pixels.width * a.observation.pixels.height)
        XCTAssertGreaterThanOrEqual(footprintFraction, 0.05)
        XCTAssertLessThanOrEqual(footprintFraction, 0.60)
        let erosion = CGFloat(max(6, Int(Double(min(a.observation.pixels.width,
                                                      a.observation.pixels.height)) * 0.02)))

        // B is one material with colour topLeft and normal bottomLeft; D is
        // the opposite mixed assignment. Both are physically A and must match
        // under the existing GLB equivalence criterion.
        try assertMixedEquivalent(a, b, footprint: footprint, erosion: erosion,
                                  label: "A/B mixed origins")
        try assertMixedEquivalent(a, d, footprint: footprint, erosion: erosion,
                                  label: "A/D mixed origins")

        // Absolute authored colour landmarks for every variant: A/B/C share
        // A's colour bytes and D is their row inversion declared bottomLeft,
        // so all four must show the authored quadrant identity at the same
        // world/UV points even while the normal maps differ.
        try assertColorLandmarks(a.observation.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "A")
        try assertColorLandmarks(b.observation.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "B")
        try assertColorLandmarks(c.observation.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "C")
        try assertColorLandmarks(d.observation.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "D")

        // Negative control: colour is held fixed byte-for-byte in A/B/C.
        // Measure all RGB channels over the same fixed projected face and
        // retain the original mean >= 8, changed-area and noise gates.
        let acFixed = rgbMeanFootprintDiff(a.observation.pixels,
                                            c.observation.pixels,
                                            footprint: footprint, inset: erosion)
        let abNoise = footprintDiff(a.observation.pixels,
                                    b.observation.pixels,
                                    footprint: footprint, inset: erosion)
        let acDiff = try WitnessPixels.diff(a.observation.pixels,
                                            c.observation.pixels)
        XCTAssertGreaterThanOrEqual(acFixed.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(acFixed.mean, 8.0,
            "A/C mixed authored-face RGB-channel mean \(acFixed.mean) "
            + "at \(acFixed.pixelCount) pixels; whole-frame mean \(acDiff.mean)")
        XCTAssertGreaterThanOrEqual(acFixed.changedFraction, 0.25,
            "the reversed normal must affect a substantial fixed material area")
        XCTAssertGreaterThanOrEqual(acFixed.mean, 4 * max(abNoise.mean, 0.5),
            "the negative control must dominate the A/B numerical noise")
        let acRegion = WitnessPixels.regionDiff(a.observation.pixels,
                                                c.observation.pixels)
        XCTAssertLessThanOrEqual(acRegion.borderMax, 4,
            "A/C mixed border max \(acRegion.borderMax): the background must "
            + "be identical across variants")

        let footprintRecord: [String: Any] = [
            "witness": "X13 mixed colour+normal origins — pinned App three.js GLB viewer",
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
            "source": "Authored +Z face projected from the actual three.js "
                + "capture camera; not difference-selected",
        ]
        let footprintAttachment = XCTAttachment(string: String(decoding:
            try JSONSerialization.data(withJSONObject: footprintRecord,
                                       options: [.sortedKeys]),
            as: UTF8.self))
        footprintAttachment.name = "Mixed material fixed footprint"
        footprintAttachment.lifetime = .keepAlways
        add(footprintAttachment)
    }

    // MARK: - X14: one body, two independently mapped faces

    /// Original X14 clause: 同体两面设置不同投影/尺度，已有 mesh UV 和无 UV 两组
    /// 均验证 Edit/Present/GLB 一致.
    ///
    /// This GLB witness exports the SAME real kernel box (120 mm X, 80 mm Z, 60 mm Y)
    /// used by the Edit/Present X14 witnesses through the production UI export
    /// entry point (`EditorViewModel.exportGLB`, which passes the live session
    /// face table), then renders the actual bytes through
    /// `EngineeringObservationService` -> offscreen WKWebView -> the bundled
    /// three.js r176 GLTFLoader viewer. Two faces carry different explicit
    /// planar projections:
    ///   * +Z front — the pinned 64x64 four-quadrant map over the whole face
    ///     (axis z, scale 160 x 80 mm, offset 0.1 / 0.1);
    ///   * +Y top   — a solid bottom-right yellow sample
    ///     (axis x, scale 200 x 200 mm, offset 0.55 / 0.9).
    /// The authored-UV variant adds a constant mesh UV set (0.25, 0.25): if the
    /// explicit per-face projection were ignored, both faces would sample red.
    /// The swapped variant exchanges the two face materials, so the front must
    /// become solid yellow and the first top landmark blue.
    private enum FaceWitnessConfig {
        static let mappingFront = CADMaterialUVMapping(
            source: .planarProjection, axis: .z,
            scaleMM: SIMD2(160, 80), offset: SIMD2(0.1, 0.1))
        static let mappingTop = CADMaterialUVMapping(
            source: .planarProjection, axis: .x,
            scaleMM: SIMD2(200, 200), offset: SIMD2(0.55, 0.9))
        static let authoredUV = SIMD2<Float>(0.25, 0.25)

        static func expectedUV(_ point: SIMD3<Float>,
                               mapping: CADMaterialUVMapping) -> SIMD2<Float> {
            let (u, v): (Float, Float)
            switch mapping.axis {
            case .x: (u, v) = (point.y, point.z)
            case .y: (u, v) = (point.x, point.z)
            case .z: (u, v) = (point.x, point.y)
            }
            return SIMD2(Float(Double(u) / mapping.scaleMM.x + mapping.offset.x),
                         Float(Double(v) / mapping.scaleMM.y + mapping.offset.y))
        }
    }

    private struct FaceLandmark {
        var name: String
        var worldMM: SIMD3<Float>
        var expected: ColorQuadrant
    }

    private struct FaceWitnessBox {
        var boundsMin: SIMD3<Float>
        var boundsMax: SIMD3<Float>
        var frontIndex: Int
        var topIndex: Int

        var frontQuadrants: [FaceLandmark] {
            let rows: [(String, SIMD2<Float>, ColorQuadrant)] = [
                ("front-topLeft", SIMD2(0.25, 0.25), .topLeft),
                ("front-topRight", SIMD2(0.75, 0.25), .topRight),
                ("front-bottomLeft", SIMD2(0.25, 0.75), .bottomLeft),
                ("front-bottomRight", SIMD2(0.75, 0.75), .bottomRight),
            ]
            return rows.map { name, uv, quadrant in
                let x = (Double(uv.x) - FaceWitnessConfig.mappingFront.offset.x)
                    * FaceWitnessConfig.mappingFront.scaleMM.x
                let y = (Double(uv.y) - FaceWitnessConfig.mappingFront.offset.y)
                    * FaceWitnessConfig.mappingFront.scaleMM.y
                return FaceLandmark(name: name,
                                    worldMM: SIMD3(Float(x), Float(y), boundsMax.z),
                                    expected: quadrant)
            }
        }

        var topLandmarks: [FaceLandmark] {
            let fractions: [(Float, Float)] = [(1.0 / 3.0, 1.0 / 3.0), (0.5, 0.5), (0.8, 0.8)]
            return fractions.enumerated().map { index, fraction in
                let x = boundsMin.x + (boundsMax.x - boundsMin.x) * fraction.0
                let z = boundsMin.z + (boundsMax.z - boundsMin.z) * fraction.1
                return FaceLandmark(name: "top-\(index)",
                                    worldMM: SIMD3(x, boundsMax.y, z),
                                    expected: .bottomRight)
            }
        }

        var frontFaceCornersMM: [SIMD3<Float>] {
            [SIMD3(boundsMin.x, boundsMin.y, boundsMax.z),
             SIMD3(boundsMax.x, boundsMin.y, boundsMax.z),
             SIMD3(boundsMax.x, boundsMax.y, boundsMax.z),
             SIMD3(boundsMin.x, boundsMax.y, boundsMax.z)]
        }

        var topFaceCornersMM: [SIMD3<Float>] {
            [SIMD3(boundsMin.x, boundsMax.y, boundsMin.z),
             SIMD3(boundsMax.x, boundsMax.y, boundsMin.z),
             SIMD3(boundsMax.x, boundsMax.y, boundsMax.z),
             SIMD3(boundsMin.x, boundsMax.y, boundsMax.z)]
        }
    }

    private struct FaceObserved {
        var variantName: String
        var hasAuthoredMeshUVs: Bool
        var swapped: Bool
        var glb: Data
        var glbSHA256: String
        var framePNG: Data
        var pixels: WitnessPixels
        var metadataJSON: String
        var summaryJSON: String
        var azimuthDegrees: Double
        var elevationDegrees: Double
        var distanceScale: Double
        var frontIndex: Int
        var topIndex: Int
        var boundsMinMM: SIMD3<Float>
        var boundsMaxMM: SIMD3<Float>
        var textureSHA256: String
        var documentRevision: Int
        var documentChangeCount: Int
        var documentContentSHA256: String
        var faceBindings: [[String: Any]]
    }

    private func runX14JSON(_ document: FloeCADDocument,
                            _ json: String) throws -> [String: Any] {
        let outcome = document.executeJSON(Data(json.utf8))
        XCTAssertTrue(outcome.isOK,
                      "X14 command failed (\(outcome.status)) "
                        + "\(outcome.errorCode ?? ""): \(outcome.message ?? "") — \(json)")
        return (try? JSONSerialization.jsonObject(with: outcome.payload))
            as? [String: Any] ?? [:]
    }

    private func makeX14Box(_ document: FloeCADDocument) throws -> Body {
        let sketch = try runX14JSON(
            document, #"{"op":"sketch.create","args":{"name":"X14 face box"}}"#)
        let sketchID = try XCTUnwrap(sketch["sketchID"] as? String)
        _ = try runX14JSON(document, """
        {"op":"sketch.addEntities","args":{"sketchID":"\(sketchID)",
         "entities":[{"kind":"rect","min":[0,0],"max":[120,80]}]}}
        """)
        _ = try runX14JSON(document, """
        {"op":"feature.extrude","args":{"sketchID":"\(sketchID)",
         "seedPoint":[60,40],"distance":60}}
        """)
        return try XCTUnwrap(document.session.document.bodies.first,
                             "the X14 extrusion must produce one body")
    }

    private func largestPlanarFace(
        _ table: FaceTable,
        normalComponent: (SIMD3<Double>) -> Double,
        label: String
    ) throws -> (index: Int, entry: FaceTable.Entry) {
        var candidates: [(index: Int, entry: FaceTable.Entry)] = []
        for (index, entry) in table.entries.enumerated() {
            guard case .planar = entry.signature.kind,
                  !entry.triangles.isEmpty,
                  normalComponent(entry.signature.normal) > 0.99 else { continue }
            candidates.append((index, entry))
        }
        return try XCTUnwrap(
            candidates.max { $0.entry.signature.area < $1.entry.signature.area },
            "the X14 face table has no planar \(label) face")
    }

    private func glbJSON(_ glb: Data) throws -> [String: Any] {
        func u32(_ offset: Int) -> UInt32 {
            glb.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset,
                                                   as: UInt32.self) }
        }
        XCTAssertEqual(u32(0), GLBExporter.magic)
        let length = Int(u32(12))
        XCTAssertGreaterThan(length, 0)
        let json = glb.subdata(in: 20..<(20 + length))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: json)
                                as? [String: Any])
    }

    private func doubleValues(_ value: Any?) -> [Double]? {
        if let values = value as? [Double] { return values }
        if let values = value as? [NSNumber] { return values.map(\.doubleValue) }
        return nil
    }

    private func glbBoundsMM(_ json: [String: Any]) throws
        -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let accessors = (json["accessors"] as? [[String: Any]]) ?? []
        var lo = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        var found = false
        for accessor in accessors {
            guard (accessor["type"] as? String) == "VEC3",
                  let minimum = doubleValues(accessor["min"]), minimum.count == 3,
                  let maximum = doubleValues(accessor["max"]), maximum.count == 3
            else { continue }
            found = true
            lo = simd_min(lo, SIMD3(Float(minimum[0]), Float(minimum[1]),
                                    Float(minimum[2])))
            hi = simd_max(hi, SIMD3(Float(maximum[0]), Float(maximum[1]),
                                    Float(maximum[2])))
        }
        XCTAssertTrue(found, "the exported GLB must carry POSITION accessor bounds")
        return (lo, hi)
    }

    /// Export the live X14 document through the production UI entry point,
    /// assert the actual GLB carries both resolved face primitives, then render
    /// those exact bytes through the real three.js observation path.
    private func observeFaceBox(hasAuthoredUVs: Bool,
                                swapped: Bool,
                                in workspace: URL) async throws -> FaceObserved {
        let variantName = "\(hasAuthoredUVs ? "authoredUV" : "noUV")"
            + "-\(swapped ? "swapped" : "declared")"
        let document = try await FloeCADDocument.create(
            at: workspace.appendingPathComponent("x14-\(variantName).floecad"),
            name: "X14 GLB \(variantName)")
        defer { document.close() }

        let body = try makeX14Box(document)
        XCTAssertEqual(body.transform, .identity,
                       "the X14 witness projects body-local faces, so the body "
                       + "must stay at identity")
        let bounds = body.render.localAABB
        XCTAssertEqual(bounds.max.x - bounds.min.x, 120, accuracy: 1e-3)
        XCTAssertEqual(bounds.max.y - bounds.min.y, 60, accuracy: 1e-3)
        XCTAssertEqual(bounds.max.z - bounds.min.z, 80, accuracy: 1e-3)
        XCTAssertEqual(bounds.min.y, 0, accuracy: 1e-3)
        XCTAssertEqual(bounds.max.y, 60, accuracy: 1e-3)
        XCTAssertEqual(bounds.max.z, 0, accuracy: 1e-3)
        let table = try XCTUnwrap(document.session.lastFaceTables[body.id],
                                  "the X14 extrusion must retain a face table")
        XCTAssertEqual(document.session.lastNamingRevisions[body.id],
                       body.meshRevision,
                       "the retained face table must describe the current mesh")
        let front = try largestPlanarFace(table, normalComponent: { $0.z },
                                          label: "+Z front")
        let top = try largestPlanarFace(table, normalComponent: { $0.y },
                                        label: "+Y top")
        XCTAssertTrue(Set(front.entry.triangles).isDisjoint(
                        with: Set(top.entry.triangles)),
                      "the two X14 faces must own disjoint triangle ranges")
        let box = FaceWitnessBox(boundsMin: bounds.min, boundsMax: bounds.max,
                                 frontIndex: front.index, topIndex: top.index)

        let colorPNG = try Fixture.colorPNG(.a)
        let metadata = CADMaterialTextureMetadata(
            assetID: UUID(), slot: .baseColor, mimeType: "image/png",
            colorSpace: .srgb, orientation: .topLeft,
            sha256: CADMaterialTexture.digest(colorPNG),
            byteCount: colorPNG.count)
        func material(_ name: String,
                      mapping: CADMaterialUVMapping) -> BodyMaterialSpec {
            BodyMaterialSpec(
                baseColor: SIMD4(1, 1, 1, 1), metallic: 0, roughness: 1.0,
                baseColorTexture: colorPNG, materialName: name,
                uvMapping: mapping, textureMetadata: [metadata])
        }
        let frontMaterial = material("X14 Front +Z",
                                     mapping: FaceWitnessConfig.mappingFront)
        let topMaterial = material("X14 Top +Y",
                                   mapping: FaceWitnessConfig.mappingTop)
        let bindings = [
            CADFaceMaterialBinding(
                key: CADFaceKey(signature: front.entry.signature,
                                capturedIndex: front.index + 1),
                material: swapped ? topMaterial : frontMaterial),
            CADFaceMaterialBinding(
                key: CADFaceKey(signature: top.entry.signature,
                                capturedIndex: top.index + 1),
                material: swapped ? frontMaterial : topMaterial),
        ]
        document.session.perform(SetMaterialAppearanceCommand(
            title: "X14 two-face projections", bodyIDs: [body.id],
            after: [body.id: SetMaterialAppearanceCommand.Snapshot(
                material: nil, faceBindings: bindings)],
            document: document.session.document))
        if hasAuthoredUVs {
            document.session.preview { design in
                guard let index = design.bodies.firstIndex(where: { $0.id == body.id })
                else { return }
                design.bodies[index].render.texcoords = Array(
                    repeating: FaceWitnessConfig.authoredUV,
                    count: design.bodies[index].render.positions.count)
            }
        }
        let updated = try XCTUnwrap(
            document.session.document.bodies.first(where: { $0.id == body.id }))
        if hasAuthoredUVs {
            let uvs = try XCTUnwrap(updated.render.texcoords,
                                    "the authored-UV variant must carry mesh UVs")
            XCTAssertEqual(uvs.count, updated.render.positions.count)
            XCTAssertTrue(uvs.allSatisfy { $0 == FaceWitnessConfig.authoredUV })
        } else {
            XCTAssertNil(updated.render.texcoords,
                         "the no-UV variant must not carry authored mesh UVs")
        }
        XCTAssertEqual(document.session.lastNamingRevisions[body.id],
                       updated.meshRevision,
                       "the authored/noUV fixture setup must not stale the "
                       + "face table")
        XCTAssertNotNil(document.session.lastFaceTables[body.id])
        let resolved = CADFaceMaterialResolver.resolve(
            updated.materialFaceBindings, in: updated)
        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(Set(resolved.compactMap(\.resolvedIndex)).count, 2,
                       "both X14 face bindings must resolve to distinct faces")

        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "the X14 GLB document must commit before export")
        let glb = try XCTUnwrap(document.viewModel().exportGLB(),
                                "the production GLB export must return bytes")
        XCTAssertEqual(glb.prefix(4), Data("glTF".utf8))
        let json = try glbJSON(glb)
        let meshes = try XCTUnwrap(json["meshes"] as? [[String: Any]])
        let mesh = try XCTUnwrap(meshes.first)
        let primitives = try XCTUnwrap(mesh["primitives"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(
            primitives.count, 3,
            "the X14 GLB must carry the base faces plus the two per-face "
                + "primitives, got \(primitives.count)")
        let materialNames = Set(((json["materials"] as? [[String: Any]]) ?? [])
            .compactMap { $0["name"] as? String })
        XCTAssertTrue(materialNames.contains("X14 Front +Z"))
        XCTAssertTrue(materialNames.contains("X14 Top +Y"))
        let extras = mesh["extras"] as? [String: Any] ?? [:]
        let unresolved = extras["floe_unresolved_face_bindings"]
            as? [[String: Any]] ?? []
        XCTAssertTrue(unresolved.isEmpty,
                      "a resolved X14 face binding must not be exported as "
                        + "unresolved: \(unresolved)")
        let faceRows = extras["floe_face_materials"] as? [[String: Any]] ?? []
        XCTAssertEqual(faceRows.count, 2,
                       "both X14 face materials must be exported")
        let glbBounds = try glbBoundsMM(json)
        XCTAssertEqual(glbBounds.max.x - glbBounds.min.x, 120, accuracy: 1e-3)
        XCTAssertEqual(glbBounds.max.y - glbBounds.min.y, 60, accuracy: 1e-3)
        XCTAssertEqual(glbBounds.max.z - glbBounds.min.z, 80, accuracy: 1e-3)
        XCTAssertEqual(glbBounds.min, bounds.min)
        XCTAssertEqual(glbBounds.max, bounds.max)

        let name = "x14-\(variantName).glb"
        try glb.write(to: workspace.appendingPathComponent(name))
        let digest = FloeDigest.sha256Hex(glb)
        let service = WorkspaceFileService(
            guard: WorkspacePathGuard(rootURL: workspace))
        let request = CadModelObservationRequest(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20,
                          distanceScale: 1)],
            width: 640, height: 480,
            expectedSourceSHA256: digest, includeImages: true)
        let result = try await EngineeringObservationService.shared.observe(
            path: name, service: service, request: request)
        XCTAssertEqual(result.frames.count, 1,
                       "one requested camera view must produce one frame")
        let frame = try XCTUnwrap(result.frames.first)
        let summary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(result.summaryJSON.utf8))
                as? [String: Any])
        XCTAssertEqual(summary["partial"] as? Bool, false,
                       "observation must be complete: \(result.summaryJSON)")
        XCTAssertEqual(summary["sourceUnchanged"] as? Bool, true)
        let state = try XCTUnwrap(summary["state"] as? [String: Any])
        let missing = try XCTUnwrap(state["missingResources"] as? [Any])
        let unsupported = try XCTUnwrap(state["unsupportedExtensions"] as? [Any])
        XCTAssertEqual(missing.count, 0,
                       "a self-contained GLB must not report missing resources")
        XCTAssertEqual(unsupported.count, 0,
                       "three.js r176 must honor the X14 GLB without "
                        + "unsupported extensions")
        let frameMetadata = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(frame.metadataJSON.utf8))
                as? [String: Any])
        XCTAssertEqual(frameMetadata["renderer"] as? String, "threeGLTF")
        XCTAssertEqual(frameMetadata["sourceSHA256"] as? String, digest)
        XCTAssertEqual(frameMetadata["imageSHA256"] as? String,
                       FloeDigest.sha256Hex(frame.pngData))
        XCTAssertEqual(try XCTUnwrap(frameMetadata["azimuthDegrees"] as? Double),
                       35, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(frameMetadata["elevationDegrees"] as? Double),
                       20, accuracy: 1e-9)
        let pixels = try WitnessPixels.decode(frame.pngData)
        XCTAssertGreaterThanOrEqual(pixels.stats().distinct, 8,
                                    "a real WebGL render has many colors; a "
                                    + "blank canvas cannot witness anything")

        let faceBindings: [[String: Any]] = bindings.map { binding -> [String: Any] in
            let mapping = binding.material.uvMapping
            return [
                "material": binding.material.materialName ?? "",
                "capturedFaceIndex": binding.key.capturedIndex ?? -1,
                "uvSource": mapping?.source.rawValue ?? "mesh",
                "axis": mapping?.axis.rawValue ?? "mesh",
                "scaleMM": [mapping?.scaleMM.x ?? 0, mapping?.scaleMM.y ?? 0],
                "offset": [mapping?.offset.x ?? 0, mapping?.offset.y ?? 0],
                "baseColorMapSHA256": binding.material.baseColorTexture.map {
                    CADMaterialTexture.digest($0)
                } ?? "",
            ]
        }
        return FaceObserved(
            variantName: variantName, hasAuthoredMeshUVs: hasAuthoredUVs,
            swapped: swapped, glb: glb, glbSHA256: digest,
            framePNG: frame.pngData, pixels: pixels,
            metadataJSON: frame.metadataJSON, summaryJSON: result.summaryJSON,
            azimuthDegrees: 35, elevationDegrees: 20, distanceScale: 1,
            frontIndex: front.index + 1, topIndex: top.index + 1,
            boundsMinMM: glbBounds.min, boundsMaxMM: glbBounds.max,
            textureSHA256: CADMaterialTexture.digest(colorPNG),
            documentRevision: document.revision,
            documentChangeCount: document.session.changeCount,
            documentContentSHA256: document.contentSHA256,
            faceBindings: faceBindings)
    }

    private func faceFootprint(_ projection: ColorProjection,
                               cornersMM: [SIMD3<Float>],
                               label: String) throws -> WitnessFootprint {
        var points: [CGPoint] = []
        for corner in cornersMM {
            points.append(try XCTUnwrap(
                projection.point(corner),
                "\(label) corner \(corner) did not project into the frame"))
        }
        return WitnessFootprint(corners: points)
    }

    private func projectedLandmark(_ landmark: FaceLandmark,
                                   projection: ColorProjection,
                                   footprint: WitnessFootprint,
                                   radius: Int,
                                   label: String) throws -> CGPoint {
        let point = try XCTUnwrap(
            projection.point(landmark.worldMM),
            "\(label) \(landmark.name) did not project into the frame")
        XCTAssertTrue(
            footprint.contains(point, inset: CGFloat(radius) * 2),
            "\(label) \(landmark.name) at \(landmark.worldMM) is not inside "
                + "the projected face")
        return point
    }

    private func sampleFaceLandmark(_ pixels: WitnessPixels,
                                    at point: CGPoint,
                                    radius: Int,
                                    footprint: WitnessFootprint,
                                    label: String) throws -> ColorMean {
        let mean = try XCTUnwrap(
            colorMean(in: pixels, at: point, radius: radius,
                      footprint: footprint),
            "\(label): no pixels sampled")
        let expectedPixels = (2 * radius + 1) * (2 * radius + 1)
        XCTAssertGreaterThanOrEqual(
            mean.count, expectedPixels * 3 / 4,
            "\(label): ROI escaped the projected face (sampled \(mean.count) "
                + "of \(expectedPixels))")
        return mean
    }

    private func landmarkRow(_ landmark: FaceLandmark, mean: ColorMean,
                             point: CGPoint) -> [String: Any] {
        return [
            "name": landmark.name,
            "worldMM": [Double(landmark.worldMM.x), Double(landmark.worldMM.y),
                        Double(landmark.worldMM.z)],
            "expectedHue": landmark.expected.expectedHue,
            "pixel": [Double(point.x), Double(point.y)],
            "meanRGB": [mean.red, mean.green, mean.blue],
            "sampleCount": mean.count,
        ]
    }

    private func assertFaceLandmarks(_ pixels: WitnessPixels,
                                     projection: ColorProjection,
                                     frontFootprint: WitnessFootprint,
                                     topFootprint: WitnessFootprint,
                                     box: FaceWitnessBox,
                                     label: String) throws -> [[String: Any]] {
        let radius = max(3, Int(Double(min(pixels.width, pixels.height)) * 0.008))
        var rows: [[String: Any]] = []
        for landmark in box.frontQuadrants {
            let uv = FaceWitnessConfig.expectedUV(
                landmark.worldMM, mapping: FaceWitnessConfig.mappingFront)
            XCTAssertEqual(uv.x, landmark.expected.uv.x, accuracy: 1e-4)
            XCTAssertEqual(uv.y, landmark.expected.uv.y, accuracy: 1e-4)
            let point = try projectedLandmark(
                landmark, projection: projection, footprint: frontFootprint,
                radius: radius, label: label)
            let mean = try sampleFaceLandmark(
                pixels, at: point, radius: radius, footprint: frontFootprint,
                label: "\(label) \(landmark.name)")
            XCTAssertTrue(
                landmark.expected.matches(red: mean.red, green: mean.green,
                                          blue: mean.blue),
                "\(label) \(landmark.name) expected "
                    + "\(landmark.expected.expectedHue): \(mean.description)")
            rows.append(landmarkRow(landmark, mean: mean, point: point))
        }
        for landmark in box.topLandmarks {
            let uv = FaceWitnessConfig.expectedUV(
                landmark.worldMM, mapping: FaceWitnessConfig.mappingTop)
            XCTAssertGreaterThan(uv.x, 0.5)
            XCTAssertGreaterThan(uv.y, 0.5)
            XCTAssertLessThan(uv.x, 1.0)
            XCTAssertLessThan(uv.y, 1.0)
            let point = try projectedLandmark(
                landmark, projection: projection, footprint: topFootprint,
                radius: radius, label: label)
            let mean = try sampleFaceLandmark(
                pixels, at: point, radius: radius, footprint: topFootprint,
                label: "\(label) \(landmark.name)")
            XCTAssertTrue(
                landmark.expected.matches(red: mean.red, green: mean.green,
                                          blue: mean.blue),
                "\(label) \(landmark.name) expected "
                    + "\(landmark.expected.expectedHue): \(mean.description)")
            rows.append(landmarkRow(landmark, mean: mean, point: point))
        }
        return rows
    }

    private func assertSwappedFaceLandmarks(
        _ pixels: WitnessPixels,
        projection: ColorProjection,
        frontFootprint: WitnessFootprint,
        topFootprint: WitnessFootprint,
        box: FaceWitnessBox,
        label: String
    ) throws -> [[String: Any]] {
        let radius = max(3, Int(Double(min(pixels.width, pixels.height)) * 0.008))
        var rows: [[String: Any]] = []
        let front = box.frontQuadrants[0]
        let frontPoint = try projectedLandmark(
            front, projection: projection, footprint: frontFootprint,
            radius: radius, label: label)
        let frontMean = try sampleFaceLandmark(
            pixels, at: frontPoint, radius: radius, footprint: frontFootprint,
            label: "\(label) \(front.name)")
        XCTAssertFalse(
            ColorQuadrant.topLeft.matches(red: frontMean.red,
                                          green: frontMean.green,
                                          blue: frontMean.blue),
            "\(label) front must NOT show the declared top-left red: "
                + frontMean.description)
        XCTAssertTrue(
            ColorQuadrant.bottomRight.matches(red: frontMean.red,
                                              green: frontMean.green,
                                              blue: frontMean.blue),
            "\(label) front must show the swapped +Y mapping's yellow: "
                + frontMean.description)
        var frontRow = landmarkRow(front, mean: frontMean, point: frontPoint)
        frontRow["declaredHue"] = front.expected.expectedHue
        frontRow["assertedHue"] = ColorQuadrant.bottomRight.expectedHue
        frontRow["negativeControl"] = true
        rows.append(frontRow)

        let top = box.topLandmarks[0]
        let topPoint = try projectedLandmark(
            top, projection: projection, footprint: topFootprint,
            radius: radius, label: label)
        let topMean = try sampleFaceLandmark(
            pixels, at: topPoint, radius: radius, footprint: topFootprint,
            label: "\(label) \(top.name)")
        XCTAssertFalse(
            ColorQuadrant.bottomRight.matches(red: topMean.red,
                                              green: topMean.green,
                                              blue: topMean.blue),
            "\(label) top must NOT show the declared yellow: "
                + topMean.description)
        XCTAssertTrue(
            ColorQuadrant.bottomLeft.matches(red: topMean.red,
                                             green: topMean.green,
                                             blue: topMean.blue),
            "\(label) top must show the swapped +Z mapping's blue: "
                + topMean.description)
        var topRow = landmarkRow(top, mean: topMean, point: topPoint)
        topRow["declaredHue"] = top.expected.expectedHue
        topRow["assertedHue"] = ColorQuadrant.bottomLeft.expectedHue
        topRow["negativeControl"] = true
        rows.append(topRow)
        return rows
    }

    private func attachX14JSON(_ name: String, _ object: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data()
        let attachment = XCTAttachment(data: data,
                                       uniformTypeIdentifier: UTType.json.identifier)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachFace(_ observed: FaceObserved) {
        let png = XCTAttachment(data: observed.framePNG,
                                uniformTypeIdentifier: UTType.png.identifier)
        png.name = "x14-threejs-\(observed.variantName)"
        png.lifetime = .keepAlways
        add(png)
        let glb = XCTAttachment(data: observed.glb)
        glb.name = "x14-threejs-\(observed.variantName).glb"
        glb.lifetime = .keepAlways
        add(glb)
        let manifest: [String: Any] = [
            "witness": "X14 same-body two-face explicit projections — "
                + "pinned App three.js GLB viewer",
            "variant": observed.variantName,
            "renderer": "threeGLTF (bundled three.js r176 GLTFLoader scene)",
            "hasAuthoredMeshUVs": observed.hasAuthoredMeshUVs,
            "swappedFaceMaterials": observed.swapped,
            "authoredMeshUVSample": observed.hasAuthoredMeshUVs
                ? [Double(FaceWitnessConfig.authoredUV.x),
                   Double(FaceWitnessConfig.authoredUV.y)]
                : "absent",
            "frontFaceTableIndex": observed.frontIndex,
            "topFaceTableIndex": observed.topIndex,
            "faceBindings": observed.faceBindings,
            "authoredColorMapBytesSHA256": observed.textureSHA256,
            "sourceGLBSHA256": observed.glbSHA256,
            "documentRevision": observed.documentRevision,
            "documentChangeCount": observed.documentChangeCount,
            "documentContentSHA256": observed.documentContentSHA256,
            "renderedImageSHA256": FloeDigest.sha256Hex(observed.framePNG),
            "captureEntryPoint": "EngineeringObservationService.observe",
            "frameMetadata": observed.metadataJSON,
            "observationSummary": observed.summaryJSON,
        ]
        attachX14JSON("x14-threejs-\(observed.variantName)-manifest.json",
                      manifest)
    }

    func testExportedSameBodyTwoFacesUseIndependentProjectionsWithAndWithoutAuthoredUVs()
        async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("X14GLBFaceWitness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        workspaces.append(workspace)

        let noUV = try await observeFaceBox(hasAuthoredUVs: false,
                                            swapped: false, in: workspace)
        let authored = try await observeFaceBox(hasAuthoredUVs: true,
                                                swapped: false, in: workspace)
        let swapped = try await observeFaceBox(hasAuthoredUVs: false,
                                               swapped: true, in: workspace)
        attachFace(noUV); attachFace(authored); attachFace(swapped)

        XCTAssertEqual(noUV.boundsMinMM, authored.boundsMinMM)
        XCTAssertEqual(noUV.boundsMaxMM, authored.boundsMaxMM)
        XCTAssertEqual(noUV.boundsMinMM, swapped.boundsMinMM)
        XCTAssertEqual(noUV.boundsMaxMM, swapped.boundsMaxMM)
        XCTAssertNotEqual(noUV.glbSHA256, authored.glbSHA256)
        XCTAssertNotEqual(noUV.glbSHA256, swapped.glbSHA256)
        XCTAssertNotEqual(noUV.documentContentSHA256,
                          authored.documentContentSHA256)
        XCTAssertNotEqual(noUV.documentContentSHA256,
                          swapped.documentContentSHA256)
        let expectedTextureSHA = CADMaterialTexture.digest(
            try Fixture.colorPNG(.a))
        for observed in [noUV, authored, swapped] {
            XCTAssertEqual(observed.textureSHA256, expectedTextureSHA)
            XCTAssertEqual(observed.azimuthDegrees, 35, accuracy: 1e-9)
            XCTAssertEqual(observed.elevationDegrees, 20, accuracy: 1e-9)
            XCTAssertEqual(observed.distanceScale, 1, accuracy: 1e-9)
        }

        let projection = ColorProjection.threeGLB(
            azimuthDegrees: noUV.azimuthDegrees,
            elevationDegrees: noUV.elevationDegrees,
            distanceScale: noUV.distanceScale,
            width: noUV.pixels.width, height: noUV.pixels.height,
            boundsMinMM: noUV.boundsMinMM, boundsMaxMM: noUV.boundsMaxMM)
        let box = FaceWitnessBox(boundsMin: noUV.boundsMinMM,
                                 boundsMax: noUV.boundsMaxMM,
                                 frontIndex: 0, topIndex: 0)
        let frontFootprint = try faceFootprint(
            projection, cornersMM: box.frontFaceCornersMM,
            label: "X14 front")
        let topFootprint = try faceFootprint(
            projection, cornersMM: box.topFaceCornersMM,
            label: "X14 top")

        // The constant authored mesh UV set is red. The explicit per-face
        // projections must override it, so the authored-UV and no-UV exported
        // GLBs must render the same physical result through the actual viewer.
        let equivalence = try WitnessPixels.diff(noUV.pixels, authored.pixels)
        XCTAssertLessThanOrEqual(equivalence.mean, 2.0,
                                 "X14 GLB authored/noUV mean "
                                    + "\(equivalence.mean) exceeds the "
                                    + "existing GLB A/B tolerance")
        XCTAssertGreaterThanOrEqual(equivalence.exactFraction, 0.95,
                                    "X14 GLB authored/noUV exact fraction "
                                        + "\(equivalence.exactFraction)")
        XCTAssertLessThanOrEqual(equivalence.max, 24,
                                 "X14 GLB authored/noUV max \(equivalence.max)")
        let erosion = CGFloat(max(6, Int(Double(min(noUV.pixels.width,
                                                       noUV.pixels.height)) * 0.02)))
        let frontEquivalence = footprintDiff(
            noUV.pixels, authored.pixels, footprint: frontFootprint,
            inset: erosion)
        let topEquivalence = footprintDiff(
            noUV.pixels, authored.pixels, footprint: topFootprint,
            inset: erosion)
        XCTAssertGreaterThanOrEqual(frontEquivalence.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(topEquivalence.pixelCount, 1_000)
        XCTAssertLessThanOrEqual(frontEquivalence.mean, 2.0,
                                 "X14 GLB front authored/noUV fixed-footprint "
                                    + "mean \(frontEquivalence.mean)")
        XCTAssertLessThanOrEqual(topEquivalence.mean, 2.0,
                                 "X14 GLB top authored/noUV fixed-footprint "
                                    + "mean \(topEquivalence.mean)")

        let noUVLandmarks = try assertFaceLandmarks(
            noUV.pixels, projection: projection,
            frontFootprint: frontFootprint, topFootprint: topFootprint,
            box: box, label: "noUV")
        let authoredLandmarks = try assertFaceLandmarks(
            authored.pixels, projection: projection,
            frontFootprint: frontFootprint, topFootprint: topFootprint,
            box: box, label: "authoredUV")
        let swappedLandmarks = try assertSwappedFaceLandmarks(
            swapped.pixels, projection: projection,
            frontFootprint: frontFootprint, topFootprint: topFootprint,
            box: box, label: "swapped")

        let metrics: [String: Any] = [
            "witness": "X14 same-body two-face explicit projections — "
                + "pinned App three.js GLB viewer",
            "variants": [noUV.variantName, authored.variantName,
                         swapped.variantName],
            "crossVariantEquivalent": [
                "mean": equivalence.mean,
                "exactFraction": equivalence.exactFraction,
                "max": equivalence.max,
                "frontFootprintMean": frontEquivalence.mean,
                "topFootprintMean": topEquivalence.mean,
                "frontFootprintPixels": frontEquivalence.pixelCount,
                "topFootprintPixels": topEquivalence.pixelCount,
            ],
            "exportedGLBSHA256": [noUV.variantName: noUV.glbSHA256,
                                  authored.variantName: authored.glbSHA256,
                                  swapped.variantName: swapped.glbSHA256],
            "noUVLandmarks": noUVLandmarks,
            "authoredUVLandmarks": authoredLandmarks,
            "swappedNegativeControl": swappedLandmarks,
            "authoredMeshUVSample": [Double(FaceWitnessConfig.authoredUV.x),
                                     Double(FaceWitnessConfig.authoredUV.y)],
            "note": "The explicit per-face projections must override the "
                + "constant authored mesh UV set; the swapped variant proves "
                + "the three.js landmarks discriminate the face assignment.",
        ]
        attachX14JSON("x14-threejs-metrics.json", metrics)
    }
}
#endif
