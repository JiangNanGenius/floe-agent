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
//  Provenance asserted for every frame: renderer "threeGLTF", source SHA-256
//  == the exported GLB bytes, requested camera azimuth/elevation, PNG
//  identity, no missing resources, no unsupported extensions (three.js
//  r176 honors both KHR_texture_transform and TANGENT), partial == false.
//  The colour test is additive and does not relax any normal-map assertion.
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
            try png(width: 2, height: 2, rows: variant.rows)
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
            let boundsMin = Fixture.slabMinMM * Fixture.modelMillimetresPerMeter
            let boundsMax = Fixture.slabMaxMM * Fixture.modelMillimetresPerMeter
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
}
#endif
