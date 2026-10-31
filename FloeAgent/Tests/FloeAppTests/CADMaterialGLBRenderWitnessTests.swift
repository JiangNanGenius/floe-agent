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
//  Fixture (identical to the Metal/Present witnesses):
//    A = topLeft 2x2 normal bytes; B = row-inverted bytes declared
//    bottomLeft (identical physical normals; the exported GLB keeps the
//    exact authored bytes, adds KHR_texture_transform for B, and emits the
//    explicit VEC4 TANGENT from the shared TEXCOORD_0); C = SAME bytes as B
//    declared topLeft (green reversed relative to A; negative control).
//
//  Provenance asserted for every frame: renderer "threeGLTF", source SHA-256
//  == the exported GLB bytes, requested camera azimuth/elevation, PNG
//  identity, no missing resources, no unsupported extensions (three.js
//  r176 honors both KHR_texture_transform and TANGENT), partial == false.
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
        static let rowTop: [[UInt8]] = [[96, 204, 255, 255], [160, 204, 255, 255]]
        static let rowBottom: [[UInt8]] = [[96, 51, 255, 255], [160, 51, 255, 255]]

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
                            render: RenderMesh(positions: positions,
                                               normals: normals,
                                               indices: indices,
                                               texcoords: texcoords),
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

    private struct Observed {
        var variant: Fixture.Variant
        var glb: Data
        var glbSHA256: String
        var framePNG: Data
        var pixels: WitnessPixels
        var metadataJSON: String
        var summaryJSON: String
    }

    /// Render one exported GLB through the real observation service and
    /// refuse anything that is not a complete, source-bound threeGLTF frame.
    private func observe(_ variant: Fixture.Variant,
                         in workspace: URL) async throws -> Observed {
        let png = try Fixture.normalPNG(variant)
        let glb = GLBExporter.glb(bodies: [
            Fixture.slabBody(normalPNG: png, orientation: variant.orientation),
        ])
        XCTAssertFalse(glb.isEmpty)
        let name = "witness-\(variant.rawValue).glb"
        try glb.write(to: workspace.appendingPathComponent(name))
        let digest = FloeDigest.sha256Hex(glb)
        let service = WorkspaceFileService(
            guard: WorkspacePathGuard(rootURL: workspace))
        let request = CadModelObservationRequest(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20)],
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
        let pixels = try WitnessPixels.decode(frame.pngData)
        XCTAssertGreaterThanOrEqual(pixels.stats().distinct, 8,
                                    "a real WebGL render has many colors; a "
                                    + "blank canvas cannot witness anything")
        return Observed(variant: variant, glb: glb, glbSHA256: digest,
                        framePNG: frame.pngData, pixels: pixels,
                        metadataJSON: frame.metadataJSON,
                        summaryJSON: result.summaryJSON)
    }

    private func attach(_ observed: Observed) {
        let png = XCTAttachment(data: observed.framePNG, uniformTypeIdentifier: UTType.png.identifier)
        png.name = "x13-threejs-\(observed.variant.displayName)"
        png.lifetime = .keepAlways
        add(png)
        let glb = XCTAttachment(data: observed.glb)
        glb.name = "x13-threejs-\(observed.variant.displayName).glb"
        glb.lifetime = .keepAlways
        add(glb)
        let manifest: [String: Any] = [
            "witness": "X13 normal-map origins — pinned App three.js GLB viewer",
            "variant": observed.variant.displayName,
            "renderer": "threeGLTF (bundled three.js r176 GLTFLoader scene)",
            "sourceGLBSHA256": observed.glbSHA256,
            "frameMetadata": observed.metadataJSON,
            "captureEntryPoint": "EngineeringObservationService.observe",
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-threejs-\(observed.variant.displayName)-manifest.json"
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
        XCTAssertGreaterThanOrEqual(ac.mean, 8.0,
                                    "A/C mean delta \(ac.mean) in the GLB viewer")
        XCTAssertGreaterThanOrEqual(ac.p95, 32)
        XCTAssertGreaterThanOrEqual(ac.max, 48, "A/C max delta \(ac.max)")
        XCTAssertGreaterThanOrEqual(ac.mean, 4 * max(ab.mean, 0.5),
                                    "the negative control must dominate "
                                    + "numerical noise")
    }
}
#endif
