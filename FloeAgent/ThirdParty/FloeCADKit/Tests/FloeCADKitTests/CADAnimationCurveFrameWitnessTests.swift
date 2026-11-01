//
//  CADAnimationCurveFrameWitnessTests.swift
//  FloeCADKitTests
//
//  X23-X25 R2: actual rendered-frame evidence for the authored timing curve.
//
//  The oracle is independent of the evaluator under test:
//
//    x1 = 1/3, x2 = 2/3, y1 = 0, y2 = 1
//    => x(t) = t, y(t) = 3t^2 - 2t^3
//
//  so a curved clip sampled at t = 0.25 / 0.75 must reach exactly the same
//  authored pose as a LINEAR clip at s = 0.15625 / 0.84375. This test renders
//  both through the PRODUCTION capture path (`ARView` snapshot, real
//  RealityKit stage, live Present host) and compares the actual decoded PNG
//  pixels with a small justified renderer-noise tolerance. It also exports a
//  real PNG frame bundle and reads the written ZIP/manifest/PNGs back.
//
//  Hostless xctest runs SKIP: no image is fabricated, no mock raster and no
//  handwritten PNG is used.
//

import CryptoKit
import Foundation
import XCTest

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import RealityKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import simd

@testable import FloeCAD

@MainActor
final class CADAnimationCurveFrameWitnessTests: XCTestCase {
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
            document.session.savePrewarmSuspensionForTesting = nil
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

    // MARK: - Real capture oracle

    func testCurvedAndEquivalentLinearSelectedFramesRenderMatchingPixels() async throws {
        let fixture = try await hostedFixture()
        let curve = fixture.curve
        let linear = fixture.linear
        XCTAssertEqual(curve.duration, 1, accuracy: 1e-12)
        XCTAssertEqual(linear.duration, 1, accuracy: 1e-12)

        // The independent oracle: x(t)=t, y(t)=3t^2-2t^3.
        XCTAssertEqual(CADAnimationTimingCurve(x1: 1.0 / 3, y1: 0,
                                               x2: 2.0 / 3, y2: 1)
            .progress(0.25), 0.15625, accuracy: 1e-9)
        XCTAssertEqual(CADAnimationTimingCurve(x1: 1.0 / 3, y1: 0,
                                               x2: 2.0 / 3, y2: 1)
            .progress(0.75), 0.84375, accuracy: 1e-9)

        let assemblyBefore = fixture.document.session.document.assemblyData
        let baselineBefore = try XCTUnwrap(
            fixture.document.animationSceneContext()
                .instances[fixture.instanceID]?.baseline)

        let curvedQuarter = try await fixture.document.captureAnimationFramePNG(
            clipID: curve.id, time: 0.25,
            width: 320, height: 240, frameRate: 32)
        let curvedThreeQuarter = try await fixture.document.captureAnimationFramePNG(
            clipID: curve.id, time: 0.75,
            width: 320, height: 240, frameRate: 32)
        let linearEquivalent = try await fixture.document.captureAnimationFramePNG(
            clipID: linear.id, time: 0.15625,
            width: 320, height: 240, frameRate: 32)
        let linearThreeQuarter = try await fixture.document.captureAnimationFramePNG(
            clipID: linear.id, time: 0.84375,
            width: 320, height: 240, frameRate: 32)

        // The actual captured PNG bytes are the witness, not a success string.
        for (capture, expectedTime, expectedClip) in [
            (curvedQuarter, 0.25, curve.id),
            (curvedThreeQuarter, 0.75, curve.id),
            (linearEquivalent, 0.15625, linear.id),
            (linearThreeQuarter, 0.84375, linear.id),
        ] {
            XCTAssertEqual(capture.mimeType, "image/png")
            XCTAssertTrue(Self.isPNG(capture.imageData), "not a real PNG payload")
            XCTAssertGreaterThan(capture.imageData.count, 2_048)
            XCTAssertEqual(capture.sha256, Self.sha256(capture.imageData))
            XCTAssertEqual(capture.timeSeconds, expectedTime, accuracy: 1e-9)
            XCTAssertEqual(capture.clipID, expectedClip)
        }
        XCTAssertEqual(curvedQuarter.clipID, curve.id)
        XCTAssertEqual(linearEquivalent.clipID, linear.id)

        let curvedQuarterPixels = try Self.rgbaPixels(curvedQuarter.imageData)
        let curvedThreePixels = try Self.rgbaPixels(curvedThreeQuarter.imageData)
        let linearQuarterPixels = try Self.rgbaPixels(linearEquivalent.imageData)
        let linearThreePixels = try Self.rgbaPixels(linearThreeQuarter.imageData)
        XCTAssertEqual(curvedQuarterPixels.width, linearQuarterPixels.width)
        XCTAssertEqual(curvedQuarterPixels.height, linearQuarterPixels.height)
        XCTAssertEqual(curvedThreePixels.width, linearThreePixels.width)
        XCTAssertEqual(curvedThreePixels.height, linearThreePixels.height)

        // Same authored pose => the actual renderer output must match within
        // ordinary GPU/antialiasing noise. The fixture is static and both
        // captures use the same live stage/material/environment/camera plan.
        let quarterDifference = Self.pixelDifference(
            curvedQuarterPixels.rgba, linearQuarterPixels.rgba)
        let threeQuarterDifference = Self.pixelDifference(
            curvedThreePixels.rgba, linearThreePixels.rgba)
        XCTAssertLessThan(quarterDifference.meanChannelDelta, 3.0,
                          "curved t=0.25 and linear s=0.15625 must render the same pose")
        XCTAssertLessThan(quarterDifference.fractionOver(24), 0.02,
                          "too many materially different pixels at the equivalent pose")
        XCTAssertLessThan(threeQuarterDifference.meanChannelDelta, 3.0,
                          "curved t=0.75 and linear s=0.84375 must render the same pose")
        XCTAssertLessThan(threeQuarterDifference.fractionOver(24), 0.02,
                          "too many materially different pixels at the equivalent pose")

        // Control: the animation must actually be visible. The two endpoints
        // of the curved clip differ in both camera and placed-part pose.
        let motionDifference = Self.pixelDifference(
            curvedQuarterPixels.rgba, curvedThreePixels.rgba)
        XCTAssertGreaterThan(motionDifference.meanChannelDelta, 1.0,
                             "the animated camera/part motion must be visible")
        XCTAssertGreaterThan(motionDifference.fractionOver(24), 0.005,
                             "the animated camera/part motion must move real pixels")
        XCTAssertGreaterThan(Self.nonBackgroundFraction(curvedQuarterPixels.rgba),
                             0.002,
                             "the real placed part must be visible in the frame")

        // The evaluator pose (independent math) and the pixels agree.
        let curvedPose = try fixture.document.evaluateAnimation(
            clipID: curve.id, time: 0.25)
        let linearPose = try fixture.document.evaluateAnimation(
            clipID: linear.id, time: 0.15625)
        XCTAssertEqual(curvedPose.camera?.distance ?? -1,
                       linearPose.camera?.distance ?? -2,
                       accuracy: 1e-9)
        XCTAssertEqual(curvedPose.camera?.azimuthRadians ?? -1,
                       linearPose.camera?.azimuthRadians ?? -2,
                       accuracy: 1e-9)
        XCTAssertEqual(
            curvedPose.instances[fixture.instanceID]?.translationMM.x ?? -1,
            linearPose.instances[fixture.instanceID]?.translationMM.x ?? -2,
            accuracy: 1e-9)
        let curvedRotation = try XCTUnwrap(
            curvedPose.instances[fixture.instanceID]?.rotation)
        let linearRotation = try XCTUnwrap(
            linearPose.instances[fixture.instanceID]?.rotation)
        XCTAssertEqual(simd_length(curvedRotation - linearRotation), 0,
                       accuracy: 1e-9)

        // Capturing is transient: the assembly baseline and placement are
        // untouched.
        XCTAssertEqual(fixture.document.session.document.assemblyData, assemblyBefore)
        XCTAssertEqual(
            fixture.document.animationSceneContext()
                .instances[fixture.instanceID]?.baseline,
            baselineBefore)

        // Persist the actual bytes/files with timestamps and read them back.
        for (name, capture) in [
            ("curve-t025", curvedQuarter),
            ("curve-t075", curvedThreeQuarter),
            ("linear-s015625", linearEquivalent),
            ("linear-s084375", linearThreeQuarter),
        ] {
            let url = fixture.directory.appendingPathComponent("\(name).png")
            try capture.imageData.write(to: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(try XCTUnwrap(
                (attributes[.size] as? NSNumber)?.intValue),
                           capture.imageData.count)
            XCTAssertNotNil(attributes[.modificationDate] as? Date)
            XCTAssertEqual(try Data(contentsOf: url), capture.imageData)
            let attachment = XCTAttachment(
                data: capture.imageData, uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = "Actual GPU PNG \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    // MARK: - Real PNG sequence export

    func testPNGSequenceExportWritesSelectedCurvedFrames() async throws {
        let fixture = try await hostedFixture()
        let settings = CADAnimationExportSettings(
            width: 320, height: 240, frameRate: 4,
            codec: .h264, bitrate: nil, overwrite: false,
            posterEnabled: false, format: .pngSequence, alpha: .opaque)
        let destination = fixture.directory.appendingPathComponent("curve-frames.zip")
        let started = Date()
        let result = try await fixture.document.exportAnimation(
            clipID: fixture.curve.id, to: destination, settings: settings)

        XCTAssertEqual(result.format, .pngSequence)
        XCTAssertEqual(result.frameCount, 4)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 240)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let bytes = try Data(contentsOf: destination)
        XCTAssertEqual(result.byteCount, Int64(bytes.count))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.path)
        let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        XCTAssertGreaterThanOrEqual(modified, started.addingTimeInterval(-1))
        let plannedTimes = try XCTUnwrap(result.frameTimes)
        XCTAssertEqual(plannedTimes.count, 4)

        let entries = try ZipReader.entries(in: bytes)
        let manifestData = try XCTUnwrap(entries["manifest.json"])
        let manifest = try JSONDecoder().decode(
            FrameManifestProbe.self, from: manifestData)
        XCTAssertEqual(manifest.format, "png_zip")
        XCTAssertEqual(manifest.frameCount, 4)
        XCTAssertEqual(manifest.width, 320)
        XCTAssertEqual(manifest.height, 240)
        let expectedTimes = [0.0, 0.25, 0.5, 0.75]
        XCTAssertEqual(manifest.frames.count, expectedTimes.count)
        for (entry, expected) in zip(manifest.frames, expectedTimes) {
            XCTAssertEqual(entry.timeSeconds, expected, accuracy: 1e-9)
        }
        let resultTimes = try XCTUnwrap(result.frameTimes)
        XCTAssertEqual(resultTimes.count, expectedTimes.count)
        for (actual, expected) in zip(resultTimes, expectedTimes) {
            XCTAssertEqual(actual, expected, accuracy: 1e-9)
        }
        let manifestSHA256 = try XCTUnwrap(result.manifestSHA256)
        XCTAssertEqual(Self.sha256(manifestData), manifestSHA256)
        let firstFrame = try XCTUnwrap(manifest.frames.first)
        let lastFrame = try XCTUnwrap(manifest.frames.last)
        XCTAssertEqual(firstFrame.presentationValue, 0)
        XCTAssertEqual(lastFrame.presentationValue, 3)

        var selected: [(Int, [UInt8])] = []
        for entry in manifest.frames {
            let data = try XCTUnwrap(entries[entry.file])
            XCTAssertTrue(Self.isPNG(data), "frame \(entry.index) is not a PNG")
            XCTAssertEqual(Self.sha256(data), entry.sha256)
            let pixels = try Self.rgbaPixels(data)
            XCTAssertEqual(pixels.width, 320)
            XCTAssertEqual(pixels.height, 240)
            XCTAssertEqual(Self.minimumAlpha(pixels.rgba), 255)
            XCTAssertGreaterThan(Self.nonBackgroundFraction(pixels.rgba), 0.002,
                                 "the real model must be visible in frame \(entry.index)")
            selected.append((entry.index, pixels.rgba))
            let attachment = XCTAttachment(
                data: data, uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = "Actual exported PNG frame \(entry.index)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(selected.count, 4)
        let difference = Self.pixelDifference(selected[1].1, selected[3].1)
        XCTAssertGreaterThan(difference.meanChannelDelta, 1.0,
                             "selected exported frames must show real motion")
        XCTAssertGreaterThan(difference.fractionOver(24), 0.005)
        let bundle = XCTAttachment(
            data: bytes, uniformTypeIdentifier: UTType.zip.identifier)
        bundle.name = "Actual selected-frame PNG bundle"
        bundle.lifetime = .keepAlways
        add(bundle)
    }

    // MARK: - Fixture

    private struct HostedFixture {
        var document: FloeCADDocument
        var curve: CADAnimationClip
        var linear: CADAnimationClip
        var instanceID: UUID
        var directory: URL
        var hosting: UIHostingController<AnyView>
        var window: UIWindow
        var store: CADPresentationSceneStore
        var handle: CADPresentationHandle
    }

    private func hostedFixture() async throws -> HostedFixture {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive
        }) else {
            throw XCTSkip("Actual frame capture requires the App-hosted UIKit "
                          + "target with a foreground window scene; hostless "
                          + "xctest has none and no PNG is fabricated.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("X25CurveFrame-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("curve-\(UUID().uuidString).floecad"),
            name: "Curve frame witness")
        documents.append(document)
        let body = Self.fixtureBox()
        document.session.perform(AddBodyCommand(body: body,
                                                title: "Add fixture box"))
        let instance = CADAssemblyInstance(
            name: "Curved fixture",
            bodyID: body.id.raw,
            transform: CADTransform(position: SIMD3(60, 0, 0)))
        let assembly = CADAssembly(instances: [instance])
        document.session.perform(SetAssemblyDataCommand(
            before: document.session.document.assemblyData,
            after: try assembly.encoded()))

        let startCamera = CADAnimationCameraValue(
            target: SIMD3(0.07, 0, 0), distance: 0.28,
            azimuthRadians: 0, elevationRadians: 0.3,
            fovYDegrees: 60)
        var endCamera = startCamera
        endCamera.distance = 0.38
        endCamera.azimuthRadians = 0.8
        endCamera.elevationRadians = 0.42
        let startPart = CADAnimationInstanceValue(
            translationMM: SIMD3(60, 0, 0))
        let endPart = CADAnimationInstanceValue(
            translationMM: SIMD3(140, 0, 0))

        let curveClip = try document.createAnimationClip(
            name: "Curved", duration: 1)
        let linearClip = try document.createAnimationClip(
            name: "Linear", duration: 1)
        let clipCurves: [(CADAnimationClip, CADAnimationTimingCurve?)] = [
            (curveClip, CADAnimationTimingCurve(
                x1: 1.0 / 3, y1: 0, x2: 2.0 / 3, y2: 1)),
            (linearClip, nil),
        ]
        for (clip, curve) in clipCurves {
            let partTrack = try document.addAnimationTrack(
                clipID: clip.id,
                target: .instance(instance.id, sourceBodyID: body.id.raw))
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: partTrack.id, time: 0,
                interpolation: .linear, timingCurve: curve,
                instance: startPart)
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: partTrack.id, time: 1,
                interpolation: .linear, instance: endPart)
            let cameraTrack = try document.addAnimationTrack(
                clipID: clip.id, target: .camera)
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: cameraTrack.id, time: 0,
                interpolation: .linear, timingCurve: curve,
                camera: startCamera)
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: cameraTrack.id, time: 1,
                interpolation: .linear, camera: endCamera)
        }

        let store = CADPresentationSceneStore(document: document)
        let handle = CADPresentationHandle()
        stores.append(store)
        handles.append(handle)
        if previousKeyWindow == nil {
            previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let hosting = UIHostingController(rootView: AnyView(
            CADPresentationPresentationPane(document: document, handle: handle,
                                            store: store, onEdit: {})
                .id(ObjectIdentifier(document))))
        window.rootViewController = hosting
        windows.append(window)
        hostings.append(hosting)
        window.makeKeyAndVisible()
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()

        let deadline = Date().addingTimeInterval(90)
        var ready = false
        while Date() < deadline {
            try Task.checkCancellation()
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
            XCTFail("Present never became active with a built stage; "
                    + "no frame was fabricated.")
            throw NSError(domain: "X25R2", code: 1)
        }
        try await Task.sleep(for: .milliseconds(800))
        return HostedFixture(
            document: document, curve: curveClip, linear: linearClip,
            instanceID: instance.id, directory: directory,
            hosting: hosting, window: window, store: store, handle: handle)
    }

    /// A small untextured box so the selected frames carry real scene pixels.
    private static func fixtureBox() -> Body {
        let h: Float = 25
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func addFace(_ corners: [SIMD3<Float>], _ normal: SIMD3<Float>) {
            let base = UInt32(positions.count)
            for corner in corners {
                positions.append(corner)
                normals.append(normal)
            }
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }
        let p = h
        let n = -h
        addFace([SIMD3(n, n, p), SIMD3(p, n, p), SIMD3(p, p, p), SIMD3(n, p, p)],
                SIMD3(0, 0, 1))
        addFace([SIMD3(p, n, n), SIMD3(n, n, n), SIMD3(n, p, n), SIMD3(p, p, n)],
                SIMD3(0, 0, -1))
        addFace([SIMD3(p, n, p), SIMD3(p, n, n), SIMD3(p, p, n), SIMD3(p, p, p)],
                SIMD3(1, 0, 0))
        addFace([SIMD3(n, n, n), SIMD3(n, n, p), SIMD3(n, p, p), SIMD3(n, p, n)],
                SIMD3(-1, 0, 0))
        addFace([SIMD3(n, p, p), SIMD3(p, p, p), SIMD3(p, p, n), SIMD3(n, p, n)],
                SIMD3(0, 1, 0))
        addFace([SIMD3(n, n, n), SIMD3(p, n, n), SIMD3(p, n, p), SIMD3(n, n, p)],
                SIMD3(0, -1, 0))
        var body = Body(id: BodyID(), name: "X25 curve fixture",
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: indices),
                        revision: 1)
        body.material = BodyMaterialSpec(baseColor: SIMD4(0.85, 0.05, 0.02, 1),
                                         metallic: 0, roughness: 0.6,
                                         emissive: SIMD3(0.9, 0.03, 0.01),
                                         emissiveStrength: 0.5)
        return body
    }

    // MARK: - Decoded-pixel probe

    private struct FrameManifestProbe: Decodable {
        var format: String
        var frameCount: Int
        var width: Int
        var height: Int
        var frames: [FrameEntryProbe]
    }

    private struct FrameEntryProbe: Decodable {
        var index: Int
        var file: String
        var timeSeconds: Double
        var presentationValue: Int
        var sha256: String
    }

    private struct PixelDifference {
        var meanChannelDelta: Double
        var differing: Int
        var total: Int
        func fractionOver(_ threshold: Int) -> Double {
            total == 0 ? 1 : Double(differing) / Double(total)
        }
    }

    private static func rgbaPixels(_ data: Data) throws
    -> (rgba: [UInt8], width: Int, height: Int) {
        let image = try XCTUnwrap(UIImage(data: data))
        let cgImage = try XCTUnwrap(image.cgImage)
        var rgba = [UInt8](repeating: 0,
                           count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &rgba, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0,
                                         width: cgImage.width,
                                         height: cgImage.height))
        return (rgba, cgImage.width, cgImage.height)
    }

    private static func pixelDifference(_ lhs: [UInt8],
                                        _ rhs: [UInt8]) -> PixelDifference {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return PixelDifference(meanChannelDelta: .infinity,
                                   differing: max(lhs.count, rhs.count),
                                   total: max(lhs.count, rhs.count))
        }
        var sum = 0
        for (a, b) in zip(lhs, rhs) {
            sum += abs(Int(a) - Int(b))
        }
        var differing = 0
        var channel = 0
        while channel < lhs.count {
            let delta = abs(Int(lhs[channel]) - Int(rhs[channel]))
                + abs(Int(lhs[channel + 1]) - Int(rhs[channel + 1]))
                + abs(Int(lhs[channel + 2]) - Int(rhs[channel + 2]))
            if delta > 24 { differing += 1 }
            channel += 4
        }
        return PixelDifference(meanChannelDelta: Double(sum) / Double(lhs.count),
                               differing: differing,
                               total: lhs.count / 4)
    }

    private static func minimumAlpha(_ rgba: [UInt8]) -> Int {
        var minimum = 255
        for offset in stride(from: 3, to: rgba.count, by: 4) {
            minimum = min(minimum, Int(rgba[offset]))
        }
        return minimum
    }

    /// A cheap "real model" probe against the red fixture material: count
    /// pixels with a clearly non-background/red-dominant value.
    private static func nonBackgroundFraction(_ rgba: [UInt8]) -> Double {
        guard !rgba.isEmpty else { return 0 }
        var count = 0
        var index = 0
        while index < rgba.count {
            let r = Int(rgba[index])
            let g = Int(rgba[index + 1])
            let b = Int(rgba[index + 2])
            if r > 40, r > g + 20, r > b + 20 { count += 1 }
            index += 4
        }
        return Double(count) / Double(rgba.count / 4)
    }

    private static func isPNG(_ data: Data) -> Bool {
        data.count > 8 && Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47,
                                                    0x0D, 0x0A, 0x1A, 0x0A]
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

#endif
