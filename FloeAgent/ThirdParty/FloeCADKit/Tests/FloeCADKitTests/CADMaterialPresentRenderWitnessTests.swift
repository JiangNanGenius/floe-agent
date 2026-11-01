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
//  must match. Per the root's explicit fixed-footprint decision, the original
//  whole-frame mean gate is now the same >=8 floor over the deterministic
//  projected front-face interior (not the background-diluted whole frame);
//  every other original A/C gate (whole-frame dominance, p95, max,
//  changed-region and border) is preserved. Coverage, changed-region and border checks add independent
//  controls for narrow highlights, cached images and scene drift; they
//  replace no gate. The colour test is additive: it does not relax or
//  replace any normal-map assertion.
//
//  MIXED-MATERIAL witness (the original X13 criterion):
//  `testMixedColorAndNormalOriginsPresentOneMaterialAtOnePlace` puts the
//  64x64 colour map and the 2x2 normal map into ONE BodyMaterialSpec with
//  separate typed metadata, then captures four variants through the same
//  live Present pane:
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
            try png(width: 2, height: 2, rows: [
                Array(variant.rows.prefix(2).joined()),
                Array(variant.rows.suffix(2).joined()),
            ])
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
                                variantName: String,
                                flushBeforeCapture: Bool = false) async throws -> Captured {
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
        if flushBeforeCapture {
            // Commit before the live mount so documentContentSHA256 is the
            // actual material-bound identity, not the pre-edit baseline.
            document.session.save()
            XCTAssertNil(document.session.lastSaveError,
                         "the mixed Present document must commit before capture")
        }

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

    // MARK: Mixed-material actual capture

    private struct MixedCaptured {
        var capture: Captured
        var source: Fixture.MixedSource
        var colorSHA256: String
        var normalSHA256: String
    }

    /// One actual Present mount of a material carrying BOTH maps. This reuses
    /// the exact live-pane mount and `capturePresentedPNG` helper above; only
    /// the single BodyMaterialSpec differs.
    private func capturePresentMixed(_ variant: Fixture.MixedVariant)
        async throws -> MixedCaptured {
        let source = try variant.source
        let body = Fixture.mixedSlabBody(source)
        let capture = try await capturePresent(
            png: source.normalPNG, body: body,
            orientation: source.normalOrientation,
            variantName: variant.displayName,
            flushBeforeCapture: true)
        return MixedCaptured(
            capture: capture, source: source,
            colorSHA256: CADMaterialTexture.digest(source.colorPNG),
            normalSHA256: CADMaterialTexture.digest(source.normalPNG))
    }

    private func attachMixed(_ mixed: MixedCaptured) {
        let captured = mixed.capture
        let png = XCTAttachment(data: captured.png,
                                uniformTypeIdentifier: UTType.png.identifier)
        png.name = "x13-present-mixed-\(captured.variantName)-rev\(captured.revision)"
        png.lifetime = .keepAlways
        add(png)
        let colorSource = XCTAttachment(data: mixed.source.colorPNG,
                                        uniformTypeIdentifier: UTType.png.identifier)
        colorSource.name = "x13-present-mixed-\(captured.variantName)-baseColor-source.png"
        colorSource.lifetime = .keepAlways
        add(colorSource)
        let normalSource = XCTAttachment(data: mixed.source.normalPNG,
                                         uniformTypeIdentifier: UTType.png.identifier)
        normalSource.name = "x13-present-mixed-\(captured.variantName)-normal-source.png"
        normalSource.lifetime = .keepAlways
        add(normalSource)
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
            "witness": "X13 mixed colour+normal map origins — RealityKit Present",
            "variant": captured.variantName,
            "renderer": "presentation",
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
            "documentRevision": captured.revision,
            "documentChangeCount": captured.changeCount,
            "documentContentSHA256": captured.contentSHA256,
            "renderedImageSHA256": captured.imageSHA256,
            "captureEntryPoint": "FloeCADDocument.capturePresentedPNG",
            "documentKey": captured.documentKey,
            "cameraReceipt": cameraJSON,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-present-mixed-\(captured.variantName)-manifest.json"
        json.lifetime = .keepAlways
        add(json)
    }

    private func assertMixedEquivalent(_ lhs: MixedCaptured, _ rhs: MixedCaptured,
                                       footprint: WitnessFootprint, erosion: CGFloat,
                                       label: String) throws {
        let diff = try WitnessPixels.diff(lhs.capture.pixels, rhs.capture.pixels)
        XCTAssertLessThanOrEqual(diff.mean, 2.0,
                                 "\(label) mixed mean \(diff.mean) exceeds the "
                                 + "existing Present A/B tolerance")
        XCTAssertGreaterThanOrEqual(diff.exactFraction, 0.95,
                                    "\(label) mixed exact fraction "
                                    + "\(diff.exactFraction)")
        XCTAssertLessThanOrEqual(diff.max, 24, "\(label) mixed max \(diff.max)")
        let fixed = footprintDiff(lhs.capture.pixels, rhs.capture.pixels,
                                  footprint: footprint, inset: erosion)
        XCTAssertGreaterThanOrEqual(fixed.pixelCount, 1_000)
        XCTAssertLessThanOrEqual(fixed.mean, 2.0,
                                 "\(label) mixed fixed-footprint mean \(fixed.mean)")
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

    /// Original X13: ONE material carries an asymmetric 64x64 colour map and
    /// an asymmetric 2x2 normal map with opposite declared origins; the
    /// actual Present samples must agree across the mixed assignment, and the
    /// reversed normal declaration must still move the actual lighting.
    func testMixedColorAndNormalOriginsPresentOneMaterialAtOnePlace()
        async throws {
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

        let a = try await capturePresentMixed(.a)
        let b = try await capturePresentMixed(.b)
        let c = try await capturePresentMixed(.c)
        let d = try await capturePresentMixed(.d)
        attachMixed(a); attachMixed(b); attachMixed(c); attachMixed(d)

        // Actual capture receipts: each image hash is the digest of that
        // capture's own PNG; the authored maps and orientations are the ones
        // asserted above. The four documents differ in material bytes.
        for mixed in [a, b, c, d] {
            let captured = mixed.capture
            XCTAssertEqual(captured.imageSHA256,
                           CADMaterialTexture.digest(captured.png))
            XCTAssertEqual(mixed.colorSHA256,
                           CADMaterialTexture.digest(mixed.source.colorPNG))
            XCTAssertEqual(mixed.normalSHA256,
                           CADMaterialTexture.digest(mixed.source.normalPNG))
        }
        XCTAssertEqual(a.capture.revision, b.capture.revision)
        XCTAssertEqual(a.capture.revision, c.capture.revision)
        XCTAssertEqual(a.capture.revision, d.capture.revision)
        XCTAssertEqual(a.capture.changeCount, b.capture.changeCount)
        XCTAssertEqual(a.capture.changeCount, c.capture.changeCount)
        XCTAssertEqual(a.capture.changeCount, d.capture.changeCount)
        XCTAssertEqual(Set([a.capture.contentSHA256, b.capture.contentSHA256,
                            c.capture.contentSHA256,
                            d.capture.contentSHA256]).count, 4,
                       "each variant must be its own source-bound document")
        XCTAssertNotEqual(a.capture.imageSHA256, c.capture.imageSHA256,
                          "the reversed normal must produce a different actual frame")
        XCTAssertNotEqual(b.capture.imageSHA256, c.capture.imageSHA256)
        XCTAssertNotEqual(d.capture.imageSHA256, c.capture.imageSHA256)

        // Same deterministic mount pose for every variant.
        XCTAssertEqual(a.capture.camera, b.capture.camera)
        XCTAssertEqual(a.capture.camera, c.capture.camera)
        XCTAssertEqual(a.capture.camera, d.capture.camera)
        let camera = try XCTUnwrap(a.capture.camera,
            "Present did not expose its live camera; mixed landmarks cannot "
            + "be projected and the witness must fail rather than skip.")
        let projection = ColorProjection.present(camera: camera,
                                                 width: a.capture.pixels.width,
                                                 height: a.capture.pixels.height)
        let footprint = try projection.frontFaceFootprint()
        let footprintFraction = Double(footprint.area)
            / Double(a.capture.pixels.width * a.capture.pixels.height)
        XCTAssertGreaterThanOrEqual(footprintFraction, 0.05)
        XCTAssertLessThanOrEqual(footprintFraction, 0.60)
        let erosion = CGFloat(max(6, Int(Double(min(a.capture.pixels.width,
                                                      a.capture.pixels.height)) * 0.02)))

        // B is one material with colour topLeft and normal bottomLeft; D is
        // the opposite mixed assignment. Both are physically A and must match
        // under the existing Present equivalence criterion.
        try assertMixedEquivalent(a, b, footprint: footprint, erosion: erosion,
                                  label: "A/B mixed origins")
        try assertMixedEquivalent(a, d, footprint: footprint, erosion: erosion,
                                  label: "A/D mixed origins")

        // Absolute authored colour landmarks for every variant: A/B/C share
        // A's colour bytes and D is their row inversion declared bottomLeft,
        // so all four must show the authored quadrant identity at the same
        // world/UV points even while the normal maps differ.
        try assertColorLandmarks(a.capture.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "A")
        try assertColorLandmarks(b.capture.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "B")
        try assertColorLandmarks(c.capture.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "C")
        try assertColorLandmarks(d.capture.pixels, projection: projection,
                                 footprint: footprint, mirrored: false, label: "D")

        // Negative control: colour is held fixed byte-for-byte in A/B/C.
        // Measure all RGB channels over the same fixed projected face and
        // retain the original mean >= 8, changed-area and noise gates.
        let acFixed = rgbMeanFootprintDiff(a.capture.pixels, c.capture.pixels,
                                            footprint: footprint, inset: erosion)
        let abNoise = footprintDiff(a.capture.pixels, b.capture.pixels,
                                    footprint: footprint, inset: erosion)
        let acDiff = try WitnessPixels.diff(a.capture.pixels, c.capture.pixels)
        XCTAssertGreaterThanOrEqual(acFixed.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(acFixed.mean, 8.0,
            "A/C mixed authored-face RGB-channel mean \(acFixed.mean) "
            + "at \(acFixed.pixelCount) pixels; whole-frame mean \(acDiff.mean)")
        XCTAssertGreaterThanOrEqual(acFixed.changedFraction, 0.25,
            "the reversed normal must affect a substantial fixed material area")
        XCTAssertGreaterThanOrEqual(acFixed.mean, 4 * max(abNoise.mean, 0.5),
            "the negative control must dominate the A/B numerical noise")
        let acRegion = WitnessPixels.regionDiff(a.capture.pixels, c.capture.pixels)
        XCTAssertLessThanOrEqual(acRegion.borderMax, 4,
            "A/C mixed border max \(acRegion.borderMax) in Present: the "
            + "background must be identical across variants")

        let footprintRecord: [String: Any] = [
            "witness": "X13 mixed colour+normal origins — RealityKit Present",
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
            "source": "Authored +Z face projected from the live Present camera; "
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

    // MARK: - X14: one body, two independently mapped faces

    /// Original X14 clause: 同体两面设置不同投影/尺度，已有 mesh UV 和无 UV 两组
    /// 均验证 Edit/Present/GLB 一致.
    ///
    /// This Present witness mounts the SAME real kernel box (120 mm X, 80 mm Z, 60 mm Y)
    /// used by the Edit/GLB X14 witnesses and gives two faces different
    /// explicit planar projections:
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

    private struct FaceCaptured {
        var capture: Captured
        var box: FaceWitnessBox
        var hasAuthoredMeshUVs: Bool
        var swapped: Bool
        var textureSHA256: String
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

    /// Mount the production Present pane for a document the X14 fixture has
    /// already prepared. This is the same real mount/wait/capture/unmount
    /// sequence as the X13 helper above, kept separate so the X13 path is
    /// byte-for-byte unchanged.
    private func mountAndCaptureFacePresent(
        document: FloeCADDocument,
        variantName: String,
        sourcePNG: Data
    ) async throws -> Captured {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive
        }) else {
            throw XCTSkip("Present render witness requires the App-hosted "
                          + "UIKit target with a foreground window scene; "
                          + "hostless xctest has none and no render is faked.")
        }
        let store = CADPresentationSceneStore(document: document)
        let handle = CADPresentationHandle()
        stores.append(store)
        handles.append(handle)
        if previousKeyWindow == nil {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        }
        let testWindow = UIWindow(windowScene: scene)
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
        try await Task.sleep(for: .milliseconds(800))

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

        await unmount(hosting: hosting, window: testWindow, store: store,
                      handle: handle, document: document)

        return Captured(
            variantName: variantName, png: capture.pngData, pixels: pixels,
            sourceSHA256: CADMaterialTexture.digest(sourcePNG),
            orientation: .topLeft,
            revision: capture.revision, changeCount: capture.changeCount,
            contentSHA256: capture.contentSHA256,
            imageSHA256: capture.imageSHA256,
            documentKey: capture.documentKey, camera: camera)
    }

    private func captureFaceBox(hasAuthoredUVs: Bool,
                                swapped: Bool) async throws -> FaceCaptured {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard scenes.contains(where: { $0.activationState == .foregroundActive })
        else {
            throw XCTSkip("Present render witness requires the App-hosted "
                          + "UIKit target with a foreground window scene; "
                          + "hostless xctest has none and no render is faked.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("X14FaceUVPresent-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let variantName = "\(hasAuthoredUVs ? "authoredUV" : "noUV")"
            + "-\(swapped ? "swapped" : "declared")"
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("face-\(variantName).floecad"),
            name: "X14 Present \(variantName)")
        documents.append(document)

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

        // The same authored studio key as the X13 Present witnesses; the
        // engineering viewport keeps its own headlight rig.
        Fixture.applyWitnessLight(to: document)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "the X14 Present document must commit before capture")

        let capture = try await mountAndCaptureFacePresent(
            document: document, variantName: variantName, sourcePNG: colorPNG)
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
        return FaceCaptured(
            capture: capture, box: box, hasAuthoredMeshUVs: hasAuthoredUVs,
            swapped: swapped, textureSHA256: CADMaterialTexture.digest(colorPNG),
            faceBindings: faceBindings)
    }

    private func faceFootprint(_ projection: ColorProjection,
                               cornersMM: [SIMD3<Float>],
                               label: String) throws -> WitnessFootprint {
        var points: [CGPoint] = []
        for corner in cornersMM {
            points.append(try XCTUnwrap(
                projection.point(corner),
                "\(label) corner \(corner) did not project into the capture"))
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
            "\(label) \(landmark.name) did not project into the capture")
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

    private func attachFace(_ captured: FaceCaptured) {
        let png = XCTAttachment(data: captured.capture.png,
                                uniformTypeIdentifier: UTType.png.identifier)
        png.name = "x14-present-\(captured.capture.variantName)"
            + "-rev\(captured.capture.revision)"
        png.lifetime = .keepAlways
        add(png)
        var cameraJSON: [String: Any] = ["available": false]
        if let camera = captured.capture.camera {
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
            "witness": "X14 same-body two-face explicit projections — "
                + "RealityKit Present",
            "variant": captured.capture.variantName,
            "renderer": "presentation",
            "hasAuthoredMeshUVs": captured.hasAuthoredMeshUVs,
            "swappedFaceMaterials": captured.swapped,
            "authoredMeshUVSample": captured.hasAuthoredMeshUVs
                ? [Double(FaceWitnessConfig.authoredUV.x),
                   Double(FaceWitnessConfig.authoredUV.y)]
                : "absent",
            "frontFaceTableIndex": captured.box.frontIndex + 1,
            "topFaceTableIndex": captured.box.topIndex + 1,
            "faceBindings": captured.faceBindings,
            "authoredColorMapBytesSHA256": captured.textureSHA256,
            "documentRevision": captured.capture.revision,
            "documentChangeCount": captured.capture.changeCount,
            "documentContentSHA256": captured.capture.contentSHA256,
            "renderedImageSHA256": captured.capture.imageSHA256,
            "captureEntryPoint": "FloeCADDocument.capturePresentedPNG",
            "documentKey": captured.capture.documentKey,
            "cameraReceipt": cameraJSON,
        ]
        attachX14JSON("x14-present-\(captured.capture.variantName)-manifest.json",
                      manifest)
    }

    func testSameBodyTwoFacesUseIndependentProjectionsWithAndWithoutAuthoredUVs()
        async throws {
        let noUV = try await captureFaceBox(hasAuthoredUVs: false, swapped: false)
        let authored = try await captureFaceBox(hasAuthoredUVs: true, swapped: false)
        let swapped = try await captureFaceBox(hasAuthoredUVs: false, swapped: true)
        attachFace(noUV); attachFace(authored); attachFace(swapped)

        XCTAssertEqual(noUV.box.boundsMin, authored.box.boundsMin)
        XCTAssertEqual(noUV.box.boundsMax, authored.box.boundsMax)
        XCTAssertEqual(noUV.box.boundsMin, swapped.box.boundsMin)
        XCTAssertEqual(noUV.box.boundsMax, swapped.box.boundsMax)
        XCTAssertEqual(noUV.box.frontIndex, authored.box.frontIndex)
        XCTAssertEqual(noUV.box.topIndex, authored.box.topIndex)
        XCTAssertNotEqual(noUV.capture.contentSHA256,
                          authored.capture.contentSHA256)
        XCTAssertNotEqual(noUV.capture.contentSHA256,
                          swapped.capture.contentSHA256)
        for captured in [noUV, authored, swapped] {
            XCTAssertEqual(captured.capture.sourceSHA256,
                           captured.textureSHA256)
            XCTAssertEqual(captured.capture.imageSHA256,
                           CADMaterialTexture.digest(captured.capture.png))
        }

        XCTAssertEqual(noUV.capture.camera, authored.capture.camera,
                       "Present camera drifted between X14 variants")
        XCTAssertEqual(noUV.capture.camera, swapped.capture.camera,
                       "Present camera drifted between the X14 negative control")
        let camera = try XCTUnwrap(noUV.capture.camera,
            "Present did not expose its live camera; X14 landmarks cannot be "
            + "projected and the witness must fail rather than skip.")
        let projection = ColorProjection.present(
            camera: camera, width: noUV.capture.pixels.width,
            height: noUV.capture.pixels.height)
        let frontFootprint = try faceFootprint(
            projection, cornersMM: noUV.box.frontFaceCornersMM,
            label: "X14 front")
        let topFootprint = try faceFootprint(
            projection, cornersMM: noUV.box.topFaceCornersMM,
            label: "X14 top")

        // The constant authored mesh UV set is red. The explicit per-face
        // projections must override it, so the authored-UV and no-UV Present
        // renders describe the same physical result.
        let equivalence = try WitnessPixels.diff(noUV.capture.pixels,
                                                 authored.capture.pixels)
        XCTAssertLessThanOrEqual(equivalence.mean, 2.0,
                                 "X14 Present authored/noUV mean "
                                    + "\(equivalence.mean) exceeds the "
                                    + "existing Present A/B tolerance")
        XCTAssertGreaterThanOrEqual(equivalence.exactFraction, 0.95,
                                    "X14 Present authored/noUV exact fraction "
                                        + "\(equivalence.exactFraction)")
        XCTAssertLessThanOrEqual(equivalence.max, 24,
                                 "X14 Present authored/noUV max \(equivalence.max)")
        let erosion = CGFloat(max(6, Int(Double(min(noUV.capture.pixels.width,
                                                       noUV.capture.pixels.height)) * 0.02)))
        let frontEquivalence = footprintDiff(
            noUV.capture.pixels, authored.capture.pixels,
            footprint: frontFootprint, inset: erosion)
        let topEquivalence = footprintDiff(
            noUV.capture.pixels, authored.capture.pixels,
            footprint: topFootprint, inset: erosion)
        XCTAssertGreaterThanOrEqual(frontEquivalence.pixelCount, 1_000)
        XCTAssertGreaterThanOrEqual(topEquivalence.pixelCount, 1_000)
        XCTAssertLessThanOrEqual(frontEquivalence.mean, 2.0,
                                 "X14 Present front authored/noUV "
                                    + "fixed-footprint mean "
                                    + "\(frontEquivalence.mean)")
        XCTAssertLessThanOrEqual(topEquivalence.mean, 2.0,
                                 "X14 Present top authored/noUV "
                                    + "fixed-footprint mean "
                                    + "\(topEquivalence.mean)")

        let noUVLandmarks = try assertFaceLandmarks(
            noUV.capture.pixels, projection: projection,
            frontFootprint: frontFootprint, topFootprint: topFootprint,
            box: noUV.box, label: "noUV")
        let authoredLandmarks = try assertFaceLandmarks(
            authored.capture.pixels, projection: projection,
            frontFootprint: frontFootprint, topFootprint: topFootprint,
            box: authored.box, label: "authoredUV")
        let swappedLandmarks = try assertSwappedFaceLandmarks(
            swapped.capture.pixels, projection: projection,
            frontFootprint: frontFootprint, topFootprint: topFootprint,
            box: swapped.box, label: "swapped")

        let metrics: [String: Any] = [
            "witness": "X14 same-body two-face explicit projections — "
                + "RealityKit Present",
            "variants": [noUV.capture.variantName,
                         authored.capture.variantName,
                         swapped.capture.variantName],
            "crossVariantEquivalent": [
                "mean": equivalence.mean,
                "exactFraction": equivalence.exactFraction,
                "max": equivalence.max,
                "frontFootprintMean": frontEquivalence.mean,
                "topFootprintMean": topEquivalence.mean,
                "frontFootprintPixels": frontEquivalence.pixelCount,
                "topFootprintPixels": topEquivalence.pixelCount,
            ],
            "noUVLandmarks": noUVLandmarks,
            "authoredUVLandmarks": authoredLandmarks,
            "swappedNegativeControl": swappedLandmarks,
            "authoredMeshUVSample": [Double(FaceWitnessConfig.authoredUV.x),
                                     Double(FaceWitnessConfig.authoredUV.y)],
            "note": "The explicit per-face projections must override the "
                + "constant authored mesh UV set; the swapped variant proves "
                + "the live Present landmarks discriminate the face assignment.",
        ]
        attachX14JSON("x14-present-metrics.json", metrics)
    }
}
#endif
