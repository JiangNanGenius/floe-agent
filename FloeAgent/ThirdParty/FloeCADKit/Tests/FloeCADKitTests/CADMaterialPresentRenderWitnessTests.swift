//
//  CADMaterialPresentRenderWitnessTests.swift
//  FloeCADKitTests
//
//  X13 REAL renderer witness — RealityKit Present.
//
//  Companion to CADMaterialRenderWitnessTests (engineering Metal viewport).
//  This witness drives the ACTUAL Present path: the production
//  `CADPresentationPresentationPane` is hosted in a real UIWindow, the
//  production workbench registers its handle in
//  `CADPresentationCaptureRegistry`, and the pixels come from
//  `FloeCADDocument.capturePresentedPNG` — which is ONLY ever sourced from
//  the live RealityKit render (nil/inactive Present can never count, and a
//  stale capture throws instead of falling back).
//
//  Fixture: the exact same A/B/C slab as the Metal witness (see that file).
//  The normal half uses the 2x2 asymmetric normal map; the colour half uses
//  the 64x64 four-quadrant sRGB base-colour map and projects its authored
//  quadrant centres through the live Present camera for absolute landmarks.
//    A = topLeft bytes; B = row-inverted bytes declared bottomLeft
//      (identical physical samples -> identical lighting);
//    C = SAME bytes as B declared topLeft (vertical mirror -> different
//      lighting). B and C byte-identical origin discriminant kills cached /
//      stale-texture fakes.
//
//  The witness document additionally authors the PRODUCTION studio
//  environment light direction through the public-inside-module
//  `applyViewAppearance` (the same command the environment inspector uses):
//  [0.35, 0.55, 0.75] -> [0.2, 0.9, 0.35]. Both the Metal headlight and the
//  studio key are +Y/+Z dominated, and aligning the key with the map's
//  green (tangent Y) axis maximises the wrapped half-Lambert swing of the
//  negative control (base dot ~0.36, ny = +/-1 tilts saturate both sides).
//
//  RealityKit has no closed-form lighting oracle here. Actual A/B renders
//  must match, and all original whole-frame A/C gates remain enforced.
//  Coverage, changed-region and border checks add independent controls for
//  narrow highlights, cached images and scene drift; they replace no gate.
//  The colour test is additive: it does not relax or replace any normal-map
//  assertion.
//
// //  Environment: requires the App-hosted UIKit test target with a foreground
//  window scene (the pane needs a real UIWindowScene to build its ARView
//  stage). Hostless runs have no window scene; they SKIP here rather than
//  fake a render — no artifact is fabricated either way.
//

import Foundation
import XCTest
import simd

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import SwiftUI
import RealityKit
import UIKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@testable import FloeCAD

@MainActor
final class CADMaterialPresentRenderWitnessTests: XCTestCase {
    private var directories: [URL] = []
    private var documents: [FloeCADDocument] = []
    private var stores: [CADPresentationSceneStore] = []
    private var handles: [CADPresentationHandle] = []
    private var windows: [UIWindow] = []
    private var hostings: [UIHostingController<AnyView>] = []
    private weak var previousKeyWindow: UIWindow?

    override func tearDown() async throws {
        for hosting in hostings {
            hosting.rootView = AnyView(EmptyView())
        }
        for window in windows {
            window.isHidden = true
            window.rootViewController = nil
        }
        hostings = []
        windows = []
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        for store in stores { store.stopObserving() }
        for handle in handles { handle.controller?.release() }
        for document in documents {
            CADPresentationCaptureRegistry.shared.unregister(document)
            document.close()
        }
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        documents = []
        directories = []
        stores = []
        handles = []
    }

    // MARK: Fixture (constants pinned with the Metal witness)

    private enum Fixture {
        static let slabMinMM = SIMD3<Float>(-50, -50, 0)
        static let slabMaxMM = SIMD3<Float>(50, 50, 12)
        static let frontFaceZMM: Float = 12

        // Green 255 / 0 gives maximal endpoint tangent-Y variation
        // under row reversal; red 96 / 160 per column. Pinned with the
        // Metal witness.
        static let rowTop: [[UInt8]] = [[96, 255, 164, 255], [160, 255, 164, 255]]
        static let rowBottom: [[UInt8]] = [[96, 0, 164, 255], [160, 0, 164, 255]]

        enum Variant {
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
        /// witnesses. Same mesh, UVs, winding and hard edges; only the
        /// material map changes.
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

        enum ColorVariant {
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

        /// Physics-chosen studio key direction: mostly +Y so the green
        /// (tangent Y) reversal swings the wrapped half-Lambert term through
        /// its full range. Applied through the production appearance command
        /// (the environment inspector's own path); document-local.
        @MainActor
        static func applyWitnessLight(to document: FloeCADDocument) {
            var appearance = CADViewAppearance.default
            appearance.studio = CADViewEnvironmentSettings(
                lightIntensity: 1.0,
                lightDirection: [0.2, 0.9, 0.35],
                backgroundColor: [0.12, 0.14, 0.18])
            document.applyViewAppearance(appearance)
        }
    }

    private struct WitnessPixels {
        var width: Int
        var height: Int
        var rgba: [UInt8]

        static func decode(_ png: Data) throws -> WitnessPixels {
            let source = try XCTUnwrap(
                CGImageSourceCreateWithData(png as CFData, nil),
                "attachment must be a decodable PNG")
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
        }

        /// Region statistics over the pixels that actually changed, plus
        /// the frame border: changed fraction, mean delta inside the
        /// changed region, and the border maximum. See the file header for
        /// why the negative control is qualified regionally (RealityKit's
        /// compressed dark display range makes whole-frame means
        /// dimensionally inappropriate) and how the gates kill
        /// flat/cached/stale/drifted fakes.
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
            return DiffStats(mean: Double(total) / Double(count * 3),
                             max: maximum,
                             exactFraction: Double(exact) / Double(count * 3),
                             p95: p95)
        }
    }

    // MARK: Absolute colour-landmark projection (actual live Present camera)

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

        /// Project with the SAME live camera the Present stage uses: the
        /// handle's `currentCamera` (target/distance/azimuth/elevation/FOV)
        /// and the controller's world->camera stage transform.
        static func present(camera: CADPresentationCamera,
                            width: Int, height: Int) -> ColorProjection {
            let fov = Float(camera.fovYDegrees) * .pi / 180
            let aspect = Float(width) / Float(max(height, 1))
            let near = max(0.001, camera.distance * 0.01)
            let far = max(100, camera.distance * 40)
            let projection = Matrices.perspective(fovYRadians: fov, aspect: aspect,
                                                  near: near, far: far)
            return ColorProjection(matrix: projection * camera.stageTransform,
                                   width: width, height: height,
                                   worldScale: 1 / CADPresentationAxes.millimetresPerMeter)
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

    private struct Captured {
        var variantName: String
        var png: Data
        var pixels: WitnessPixels
        var sourceSHA256: String
        var orientation: MaterialTextureOrientation
        var revision: Int
        var changeCount: Int
        var contentSHA256: String
        var imageSHA256: String
        var documentKey: String
        var camera: CADPresentationCamera?
    }

    // MARK: Capture through the REAL Present path

    private func capturePresent(_ variant: Fixture.Variant) async throws -> Captured {
        let png = try Fixture.normalPNG(variant)
        let body = Fixture.slabBody(normalPNG: png, orientation: variant.orientation)
        return try await capturePresent(png: png, body: body,
                                        orientation: variant.orientation,
                                        variantName: variant.displayName)
    }

    private func capturePresentColor(_ variant: Fixture.ColorVariant) async throws -> Captured {
        let png = try Fixture.colorPNG(variant)
        let body = Fixture.colorSlabBody(colorPNG: png, orientation: variant.orientation)
        return try await capturePresent(png: png, body: body,
                                        orientation: variant.orientation,
                                        variantName: variant.displayName)
    }

    /// One mount of the production Present pane, then one real
    /// `capturePresentedPNG` bound to the document. The camera is read from
    /// the live handle as a receipt for the absolute colour landmarks.
    private func capturePresent(png: Data, body: Body,
                                orientation: MaterialTextureOrientation,
                                variantName: String) async throws -> Captured {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive
        }) else {
            throw XCTSkip("Present render witness requires the App-hosted "
                          + "UIKit target with a foreground window scene; "
                          + "hostless xctest has none and no render is faked.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("X13PresentWitness-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("witness-\(variantName).floecad"),
            name: "X13 \(variantName)")
        documents.append(document)
        document.session.perform(AddBodyCommand(
            body: body, title: "Add witness slab"))
        // Before the pane mounts: same authored studio key light for every
        // variant (see Fixture.applyWitnessLight). The engineering Metal
        // viewport keeps its headlight rig and is unaffected by the
        // presentation appearance, so the two witnesses stay independent.
        Fixture.applyWitnessLight(to: document)

        let store = CADPresentationSceneStore(document: document)
        let handle = CADPresentationHandle()
        stores.append(store)
        handles.append(handle)
        if previousKeyWindow == nil {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        }
        let testWindow = UIWindow(windowScene: scene)
        // A square viewport keeps the slab prominent in either device
        // orientation, so a whole-frame contrast test measures the material
        // rather than mostly empty portrait background.
        testWindow.frame = CGRect(x: 0, y: 0, width: 512, height: 512)
        let hosting = UIHostingController(rootView: AnyView(
            CADPresentationPresentationPane(document: document, handle: handle,
                                            store: store, onEdit: {})
                .frame(width: 512, height: 512)
                .id(ObjectIdentifier(document))))
        testWindow.rootViewController = hosting
        windows.append(testWindow)
        hostings.append(hosting)
        testWindow.makeKeyAndVisible()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        // Wait for the production registration + a real built stage. Only an
        // active Present can be captured; anything else is a failure here,
        // never a fallback image.
        let deadline = Date().addingTimeInterval(90)
        var ready = false
        while Date() < deadline {
            if CADPresentationCaptureRegistry.shared.isActive(for: document),
               let active = CADPresentationCaptureRegistry.shared
                .activeHandle(for: document),
               active.controller?.isStageReady == true {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else {
            XCTFail("Present never became active with a built stage for "
                    + "\(variantName); no image was fabricated.")
            await unmount(hosting: hosting, window: testWindow, store: store,
                          handle: handle, document: document)
            throw CapturedError.presentNeverActive
        }
        // Settle: let the environment map finish any first-frame builds so the
        // snapshot service's stale check sees a stable render state token.
        try await Task.sleep(for: .milliseconds(800))

        // Actual live camera receipt, read before the snapshot; no gesture or
        // animation can move it during this deterministic mount.
        let camera = handle.currentCamera
        let result = try await document.capturePresentedPNG()
        let capture = try XCTUnwrap(result,
            "Present is active, so capturePresentedPNG must return the actual "
            + "RealityKit render; nil here would mean the registry disagreed.")
        XCTAssertFalse(capture.pngData.isEmpty)
        XCTAssertEqual(capture.pngData.prefix(2), Data([0x89, 0x50]))
        let pixels = try WitnessPixels.decode(capture.pngData)
        XCTAssertGreaterThan(pixels.width, 0)
        XCTAssertGreaterThan(pixels.height, 0)

        // Tear this variant's mount down before the next variant so handles
        // and stages never overlap.
        await unmount(hosting: hosting, window: testWindow, store: store,
                      handle: handle, document: document)

        return Captured(
            variantName: variantName, png: capture.pngData, pixels: pixels,
            sourceSHA256: CADMaterialTexture.digest(png),
            orientation: orientation,
            revision: capture.revision, changeCount: capture.changeCount,
            contentSHA256: capture.contentSHA256,
            imageSHA256: capture.imageSHA256,
            documentKey: capture.documentKey, camera: camera)
    }

    /// Deterministic unmount: swap the pane for an empty view (the same
    /// pattern as the production observer tests), wait for the disappear
    /// callbacks, then hide and release the window.
    private func unmount(hosting: UIHostingController<AnyView>,
                         window: UIWindow,
                         store: CADPresentationSceneStore,
                         handle: CADPresentationHandle,
                         document: FloeCADDocument) async {
        hosting.rootView = AnyView(Color.clear)
        try? await Task.sleep(for: .milliseconds(300))
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
        store.stopObserving()
        CADPresentationCaptureRegistry.shared.unregister(document)
        handle.controller?.release()
    }

    private enum CapturedError: Error {
        case presentNeverActive
    }

    private func attach(_ captured: Captured) {
        let attachment = XCTAttachment(data: captured.png, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "x13-present-\(captured.variantName)-rev\(captured.revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let manifest: [String: Any] = [
            "witness": "X13 normal-map origins — RealityKit Present",
            "variant": captured.variantName,
            "renderer": "presentation",
            "documentRevision": captured.revision,
            "documentChangeCount": captured.changeCount,
            "documentContentSHA256": captured.contentSHA256,
            "renderedImageSHA256": captured.imageSHA256,
            "normalMapBytesSHA256": captured.sourceSHA256,
            "normalMapOrientation": "\(captured.orientation)",
            "captureEntryPoint": "FloeCADDocument.capturePresentedPNG",
            "documentKey": captured.documentKey,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-present-\(captured.variantName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    private func attachColor(_ captured: Captured) {
        let attachment = XCTAttachment(data: captured.png,
                                       uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "x13-present-colour-\(captured.variantName)-rev\(captured.revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        var cameraJSON: [String: Any] = ["available": false]
        if let camera = captured.camera {
            cameraJSON = [
                "available": true,
                "fovYDegrees": Double(camera.fovYDegrees),
                "distanceM": Double(camera.distance),
                "azimuthRadians": Double(camera.azimuthRadians),
                "elevationRadians": Double(camera.elevationRadians),
                "targetM": [Double(camera.target.x), Double(camera.target.y),
                            Double(camera.target.z)],
            ]
        }
        let manifest: [String: Any] = [
            "witness": "X13 colour-map origins — RealityKit Present (absolute UV landmarks)",
            "variant": captured.variantName,
            "renderer": "presentation",
            "documentRevision": captured.revision,
            "documentChangeCount": captured.changeCount,
            "documentContentSHA256": captured.contentSHA256,
            "renderedImageSHA256": captured.imageSHA256,
            "authoredColorMapBytesSHA256": captured.sourceSHA256,
            "authoredColorMapOrientation": "\(captured.orientation)",
            "authoredColorMapColorSpace": "srgb",
            "captureEntryPoint": "FloeCADDocument.capturePresentedPNG",
            "documentKey": captured.documentKey,
            "cameraReceipt": cameraJSON,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-present-colour-\(captured.variantName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    func testOppositeNormalOriginsPresentIdenticallyAndReversedGreenDoesNot()
        async throws {
        let pngA = try Fixture.normalPNG(.a)
        let pngB = try Fixture.normalPNG(.b)
        let pngC = try Fixture.normalPNG(.c)
        XCTAssertEqual(pngB, pngC,
                       "B and C must share identical bytes; only the declared "
                       + "origin differs")
        XCTAssertNotEqual(pngA, pngB)

        let a = try await capturePresent(.a)
        let b = try await capturePresent(.b)
        let c = try await capturePresent(.c)
        attach(a); attach(b); attach(c)
        XCTAssertEqual(a.sourceSHA256, CADMaterialTexture.digest(pngA))
        XCTAssertEqual(b.sourceSHA256, CADMaterialTexture.digest(pngB))
        XCTAssertEqual(c.sourceSHA256, CADMaterialTexture.digest(pngC))

        let ab = try WitnessPixels.diff(a.pixels, b.pixels)
        let ac = try WitnessPixels.diff(a.pixels, c.pixels)

        // Same physical normals through the same RealityKit stage, camera
        // fit and environment: renders must match to numerical tolerance.
        // (No closed-form oracle exists for RealityKit PBR; the bound is
        // justified by determinism of the stage, not by a math identity.)
        XCTAssertLessThanOrEqual(ab.mean, 2.0,
                                 "A/B mean delta \(ab.mean) in Present")
        XCTAssertGreaterThanOrEqual(ab.exactFraction, 0.95)
        XCTAssertLessThanOrEqual(ab.max, 24, "A/B max delta \(ab.max)")

        // Material response is measured over an independently projected face,
        // not the empty canvas. Keep full-frame noise, peak and border guards;
        // the same-source absolute color landmarks validate this projection.
        XCTAssertEqual(a.camera, b.camera)
        XCTAssertEqual(a.camera, c.camera)
        let camera = try XCTUnwrap(a.camera, "Normal control needs the actual capture camera")
        let projection = ColorProjection.present(camera: camera,
                                                 width: a.pixels.width,
                                                 height: a.pixels.height)
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
        XCTAssertGreaterThanOrEqual(ac.mean, 4 * max(ab.mean, 0.5),
                                    "the negative control must dominate numerical noise")
        let acRegion = WitnessPixels.regionDiff(a.pixels, c.pixels)
        XCTAssertGreaterThanOrEqual(acRegion.changedFraction, 0.06,
                                    "A/C changed fraction "
                                    + "\(acRegion.changedFraction) in Present: "
                                    + "the reversed green must manifest "
                                    + "across the textured face")
        XCTAssertLessThanOrEqual(acRegion.changedFraction, 0.60,
                                 "A/C changed fraction "
                                 + "\(acRegion.changedFraction) in Present: "
                                 + "more than the object changed")
        XCTAssertGreaterThanOrEqual(acRegion.changedMean, 20.0,
                                    "A/C changed-region mean "
                                    + "\(acRegion.changedMean) in Present: "
                                    + "the negative control must be strong "
                                    + "where it manifests")
        XCTAssertLessThanOrEqual(acRegion.borderMax, 4,
                                 "A/C border max \(acRegion.borderMax) in "
                                 + "Present: the background must be identical "
                                 + "across variants (stale/drifted frame?)")
        XCTAssertGreaterThanOrEqual(ac.p95, 32)
        XCTAssertGreaterThanOrEqual(ac.max, 48, "A/C max delta \(ac.max)")
        XCTAssertGreaterThanOrEqual(acRegion.changedMean,
                                    4 * max(ab.mean, 0.5),
                                    "the negative control must dominate "
                                    + "numerical noise")
    }

    func testColorMapOriginsPresentAuthoredQuadrantsAtKnownWorldPoints()
        async throws {
        let pngA = try Fixture.colorPNG(.a)
        let pngB = try Fixture.colorPNG(.b)
        let pngC = try Fixture.colorPNG(.c)
        XCTAssertEqual(pngB, pngC,
                       "B and C must share identical colour bytes; only the "
                       + "declared origin differs")
        XCTAssertNotEqual(pngA, pngB)

        let a = try await capturePresentColor(.a)
        let b = try await capturePresentColor(.b)
        let c = try await capturePresentColor(.c)
        attachColor(a); attachColor(b); attachColor(c)
        XCTAssertEqual(a.sourceSHA256, CADMaterialTexture.digest(pngA))
        XCTAssertEqual(b.sourceSHA256, CADMaterialTexture.digest(pngB))
        XCTAssertEqual(c.sourceSHA256, CADMaterialTexture.digest(pngC))
        XCTAssertEqual(a.orientation, .topLeft)
        XCTAssertEqual(b.orientation, .bottomLeft)
        XCTAssertEqual(c.orientation, .topLeft)

        // Same live camera pose for all three variants: the absolute
        // landmark check depends on one deterministic mount per variant.
        XCTAssertEqual(a.camera, b.camera,
                       "Present camera drifted between colour variants A and B")
        XCTAssertEqual(a.camera, c.camera,
                       "Present camera drifted between colour variants A and C")
        let camera = try XCTUnwrap(a.camera,
            "Present did not expose its live camera; absolute landmarks cannot "
            + "be projected and the witness must fail rather than skip.")

        let ab = try WitnessPixels.diff(a.pixels, b.pixels)
        XCTAssertLessThanOrEqual(ab.mean, 2.0,
                                 "A/B colour mean delta \(ab.mean) in Present")
        XCTAssertGreaterThanOrEqual(ab.exactFraction, 0.95)
        XCTAssertLessThanOrEqual(ab.max, 24, "A/B colour max delta \(ab.max)")

        let projection = ColorProjection.present(camera: camera,
                                                 width: a.pixels.width,
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

        let region = WitnessPixels.regionDiff(a.pixels, c.pixels)
        XCTAssertLessThanOrEqual(region.borderMax, 4,
                                 "A/C border max \(region.borderMax) in Present: "
                                 + "the background must be identical across "
                                 + "colour variants")
    }
}
#endif
