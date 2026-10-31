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
//  Fixture: the exact same A/B/C slab and 2x2 asymmetric normal map as the
//  Metal witness (see that file and checks/witness_fixture_check.py):
//    A = topLeft bytes; B = row-inverted bytes declared bottomLeft
//      (identical physical normals -> identical lighting);
//    C = SAME bytes as B declared topLeft (green reversed -> different
//      lighting). B and C byte-identical origin discriminant kills cached /
//      stale-texture fakes.
//
//  RealityKit PBR/image-based lighting is not closed-form oracleable, so the
//  A/B bound is a justified numerical tolerance (same stage, same camera fit,
//  same environment, same normalized texture resource) and the A/C bound is
//  required to dominate it by an order of magnitude.
//
//  Environment: requires the App-hosted UIKit test target with a foreground
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

    // MARK: Fixture (constants pinned with the Metal witness + the checker)

    private enum Fixture {
        static let rowTop: [[UInt8]] = [[96, 204, 255, 255], [160, 204, 255, 255]]
        static let rowBottom: [[UInt8]] = [[96, 51, 255, 255], [160, 51, 255, 255]]

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

    private struct Captured {
        var variant: Fixture.Variant
        var png: Data
        var pixels: WitnessPixels
        var sourceSHA256: String
        var revision: Int
        var changeCount: Int
        var contentSHA256: String
        var imageSHA256: String
        var documentKey: String
    }

    // MARK: Capture through the REAL Present path

    private func capturePresent(_ variant: Fixture.Variant) async throws -> Captured {
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
        let png = try Fixture.normalPNG(variant)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("witness-\(variant.displayName).floecad"),
            name: "X13 \(variant.displayName)")
        documents.append(document)
        document.session.perform(AddBodyCommand(
            body: Fixture.slabBody(normalPNG: png, orientation: variant.orientation),
            title: "Add witness slab"))

        let store = CADPresentationSceneStore(document: document)
        let handle = CADPresentationHandle()
        stores.append(store)
        handles.append(handle)
        if previousKeyWindow == nil {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        }
        let testWindow = UIWindow(windowScene: scene)
        testWindow.frame = scene.coordinateSpace.bounds
        let hosting = UIHostingController(rootView: AnyView(
            CADPresentationPresentationPane(document: document, handle: handle,
                                            store: store, onEdit: {})
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
                    + "\(variant.displayName); no image was fabricated.")
            await unmount(hosting: hosting, window: testWindow, store: store,
                          handle: handle, document: document)
            throw CapturedError.presentNeverActive
        }
        // Settle: let the environment map finish any first-frame builds so the
        // snapshot service's stale check sees a stable render state token.
        try await Task.sleep(for: .milliseconds(800))

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
            variant: variant, png: capture.pngData, pixels: pixels,
            sourceSHA256: CADMaterialTexture.digest(png),
            revision: capture.revision, changeCount: capture.changeCount,
            contentSHA256: capture.contentSHA256,
            imageSHA256: capture.imageSHA256,
            documentKey: capture.documentKey)
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
        attachment.name = "x13-present-\(captured.variant.displayName)-rev\(captured.revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        let manifest: [String: Any] = [
            "witness": "X13 normal-map origins — RealityKit Present",
            "variant": captured.variant.displayName,
            "renderer": "presentation",
            "documentRevision": captured.revision,
            "documentChangeCount": captured.changeCount,
            "documentContentSHA256": captured.contentSHA256,
            "renderedImageSHA256": captured.imageSHA256,
            "normalMapBytesSHA256": captured.sourceSHA256,
            "normalMapOrientation": "\(captured.variant.orientation)",
            "captureEntryPoint": "FloeCADDocument.capturePresentedPNG",
            "documentKey": captured.documentKey,
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: manifest, options: [.sortedKeys])) ?? Data()
        let json = XCTAttachment(data: data, uniformTypeIdentifier: UTType.json.identifier)
        json.name = "x13-present-\(captured.variant.displayName)-manifest.json"
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

        // Negative control: reversed green must dominate by an order of
        // magnitude; anything less means flat/cached frames faked parity.
        XCTAssertGreaterThanOrEqual(ac.mean, 8.0,
                                    "A/C mean delta \(ac.mean) in Present")
        XCTAssertGreaterThanOrEqual(ac.p95, 32)
        XCTAssertGreaterThanOrEqual(ac.max, 48, "A/C max delta \(ac.max)")
        XCTAssertGreaterThanOrEqual(ac.mean, 4 * max(ab.mean, 0.5),
                                    "the negative control must dominate "
                                    + "numerical noise")
    }
}
#endif
