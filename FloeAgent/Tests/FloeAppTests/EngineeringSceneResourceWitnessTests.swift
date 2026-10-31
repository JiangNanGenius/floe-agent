// SPDX-License-Identifier: MPL-2.0
//
//  EngineeringSceneResourceWitnessTests.swift
//  FloeAppTests
//
//  VIEW-GLTF-SCENES / VIEW-RESOURCES native App-host witness.
//
//  Every render below goes through the REAL product path:
//  `EngineeringObservationService.observe` (or a real `EngineeringWebSession`
//  for native playback commands) -> `EngineeringWebSession.attach` ->
//  LocalPreviewServer -> the bundled `index.html`/`viewer.js` ->
//  `scene.js` (three.js r176 GLTFLoader + bundled Draco/meshopt/KTX2) ->
//  real WKWebView WebGL -> PNG frames. Nothing here is a Node/three parse,
//  a desktop self-importer, a Quick Look window or a success label: the
//  frames are decoded and compared, and the final source bytes are re-read.
//
//  Fixtures are Floe-authored (`Tests/Fixtures/EngineeringScene`,
//  regenerate with `generate_scene_fixtures.py`) except the Khronos Box
//  Draco sample (CC BY 4.0, pinned; see SOURCES.md). The meshopt and KTX2
//  files are produced from the owned quad by pinned gltfpack 0.20.0 /
//  basisu 1.16.3 encoders; the App still decodes them with the bundled
//  three.js decoders.
//
//  Not claimed: physical-device performance, CAD import/measurement
//  semantics, every extension in the glTF universe, or a >18 MB scene
//  (viewer.js bounds its base64 payload separately). Root owns the build,
//  the canonical Simulator run, visual judgment and acceptance.
//

#if canImport(UIKit)
import XCTest
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
@testable import FloeApp
import FloeCore
import FloeWorkbench
import FloeWorkspace

@MainActor
final class EngineeringSceneResourceWitnessTests: XCTestCase {
    private var workspaces: [URL] = []

    override func tearDown() async throws {
        for workspace in workspaces {
            try? FileManager.default.removeItem(at: workspace)
        }
        workspaces = []
    }

    // MARK: - Fixtures

    private enum Fixtures {
        static let folder = "EngineeringScene"
        static let hierarchy = "scene-hierarchy.glb"
        static let textureA = "scene-texture-a.glb"
        static let textureB = "scene-texture-b.glb"
        static let skin = "scene-skin.glb"
        static let morph = "scene-morph.glb"
        static let siblings = "scene-siblings.gltf"
        static let siblingsBinary = "scene-siblings.bin"
        static let siblingsTexture = "textures/quadrants.png"
        static let draco = "Box.gltf"
        static let dracoBinary = "Box.bin"
        static let meshopt = "scene-meshopt.glb"
        static let ktx2 = "scene-ktx2.glb"
    }

    private func fixtureURL(_ name: String,
                            file: StaticString = #filePath,
                            line: UInt = #line) throws -> URL {
        guard let root = Bundle(for: SceneFixtureBundleAnchor.self).url(
            forResource: Fixtures.folder, withExtension: nil) else {
            XCTFail("EngineeringScene fixture folder is missing from the test bundle",
                    file: file, line: line)
            throw FloeError.notFound("EngineeringScene fixture folder")
        }
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("fixture \(name) is missing", file: file, line: line)
            throw FloeError.notFound(name)
        }
        return url
    }

    /// Creates a disposable workspace and copies exactly the requested
    /// fixtures (relative subpaths preserved) into it.
    @discardableResult
    private func makeWorkspace(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-witness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workspaces.append(root)
        for name in names {
            let source = try fixtureURL(name)
            let destination = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try Data(contentsOf: source).write(to: destination, options: .atomic)
        }
        return root
    }

    private func write(_ bytes: Data, named name: String, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }

    // MARK: - Observation helpers

    private func observe(_ path: String, in root: URL,
                         _ request: CadModelObservationRequest,
                         file: StaticString = #filePath,
                         line: UInt = #line) async throws -> CadModelObservationResult {
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
        do {
            return try await EngineeringObservationService.shared.observe(
                path: path, service: service, request: request)
        } catch {
            // Keep the original error before XCTest formats an asynchronous
            // App-host failure at the application's entry point.
            let reason = (error as? FloeError)?.reason ?? String(reflecting: error)
            print("SCENE_OBSERVATION_FAILURE path=\(path) reason=\(reason)")
            let evidence = XCTAttachment(string: "path=\(path)\n\(reason)")
            evidence.name = "scene-observation-original-error"
            evidence.lifetime = .keepAlways
            add(evidence)
            throw error
        }
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8))
            as? [String: Any])
    }

    private func state(_ summary: [String: Any]) throws -> EngineeringSceneState {
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(summary["state"]))
        return try JSONDecoder().decode(EngineeringSceneState.self, from: data)
    }

    private func provenance(_ summary: [String: Any]) -> [String: Any] {
        (summary["provenance"] as? [String: Any]) ?? [:]
    }

    private func assertComplete(_ summary: [String: Any],
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertEqual(summary["partial"] as? Bool, false,
                       "the observation must be complete", file: file, line: line)
        XCTAssertEqual(summary["sourceUnchanged"] as? Bool, true,
                       "the observer must re-read the same bytes", file: file, line: line)
        XCTAssertEqual((summary["failures"] as? [Any])?.count, 0,
                       "no view may fail silently", file: file, line: line)
    }

    private func attachPNG(_ data: Data, name: String) {
        let attachment = XCTAttachment(
            data: data, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachManifest(_ values: [String: Any], name: String) {
        guard JSONSerialization.isValidJSONObject(values),
              let data = try? JSONSerialization.data(
                withJSONObject: values, options: [.sortedKeys]) else { return }
        let attachment = XCTAttachment(
            data: data, uniformTypeIdentifier: UTType.json.identifier)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Pixel evidence

    private struct Pixels {
        let width: Int
        let height: Int
        let rgba: [UInt8]

        static func decode(_ data: Data) throws -> Pixels {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw FloeError.validationFailed("not a decodable PNG")
            }
            let width = image.width
            let height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            try bytes.withUnsafeMutableBytes { storage in
                guard let context = CGContext(
                    data: storage.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw FloeError.validationFailed("could not create a pixel buffer")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            return Pixels(width: width, height: height, rgba: bytes)
        }

        func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let base = (y * width + x) * 4
            return (Int(rgba[base]), Int(rgba[base + 1]), Int(rgba[base + 2]))
        }

        /// Median-ish background inferred from the four corners; a flat scene
        /// clear colour is the only thing guaranteed to fill them.
        func background() -> (Int, Int, Int) {
            let samples = [rgb(0, 0), rgb(width - 1, 0),
                           rgb(0, height - 1), rgb(width - 1, height - 1)]
            let red = samples.map { $0.0 }.sorted()[1]
            let green = samples.map { $0.1 }.sorted()[1]
            let blue = samples.map { $0.2 }.sorted()[1]
            return (red, green, blue)
        }

        struct Bounds {
            let minimumX: Int
            let minimumY: Int
            let maximumX: Int
            let maximumY: Int
            let count: Int
            var width: Int { maximumX - minimumX + 1 }
            var height: Int { maximumY - minimumY + 1 }
        }

        func foreground(threshold: Int = 18) -> Bounds {
            let background = background()
            var minimumX = width
            var minimumY = height
            var maximumX = -1
            var maximumY = -1
            var count = 0
            for y in 0..<height {
                for x in 0..<width {
                    let foreground = rgb(x, y)
                    let delta = max(abs(foreground.0 - background.0),
                                    max(abs(foreground.1 - background.1),
                                        abs(foreground.2 - background.2)))
                    guard delta > threshold else { continue }
                    count += 1
                    minimumX = min(minimumX, x)
                    minimumY = min(minimumY, y)
                    maximumX = max(maximumX, x)
                    maximumY = max(maximumY, y)
                }
            }
            if count == 0 {
                return Bounds(minimumX: 0, minimumY: 0,
                              maximumX: width - 1, maximumY: height - 1, count: 0)
            }
            return Bounds(minimumX: minimumX, minimumY: minimumY,
                          maximumX: maximumX, maximumY: maximumY, count: count)
        }

        /// Fraction of pixels that differ by more than `threshold` channels.
        func differenceFraction(from other: Pixels, threshold: Int = 8) throws -> Double {
            guard width == other.width, height == other.height else {
                throw FloeError.validationFailed("frames have different dimensions")
            }
            var changed = 0
            let total = width * height
            for index in stride(from: 0, to: rgba.count, by: 4) {
                let delta = max(abs(Int(rgba[index]) - Int(other.rgba[index])),
                                max(abs(Int(rgba[index + 1]) - Int(other.rgba[index + 1])),
                                    abs(Int(rgba[index + 2]) - Int(other.rgba[index + 2]))))
                if delta >= threshold { changed += 1 }
            }
            return Double(changed) / Double(total)
        }

        /// Compare the rendered object, excluding unchanged clear-colour
        /// pixels. A quad occupies only part of the canvas; requiring a
        /// canvas-wide percentage makes a correct texture fail when fitted.
        func objectDifferenceFraction(from other: Pixels) throws -> Double {
            guard width == other.width, height == other.height else {
                throw FloeError.validationFailed("frames have different dimensions")
            }
            let firstBackground = background()
            let secondBackground = other.background()
            var samples = 0
            var changed = 0
            func distance(_ first: (Int, Int, Int), _ second: (Int, Int, Int)) -> Int {
                max(abs(first.0 - second.0), max(abs(first.1 - second.1), abs(first.2 - second.2)))
            }
            for y in 0..<height {
                for x in 0..<width {
                    let first = rgb(x, y)
                    let second = other.rgb(x, y)
                    guard distance(first, firstBackground) > 18
                        || distance(second, secondBackground) > 18 else { continue }
                    samples += 1
                    if distance(first, second) >= 8 { changed += 1 }
                }
            }
            guard samples > 0 else {
                throw FloeError.validationFailed("no rendered object pixels")
            }
            return Double(changed) / Double(samples)
        }

        func distinctColorCount(limit: Int = 4096) -> Int {
            var colors = Set<UInt32>()
            for index in stride(from: 0, to: rgba.count, by: 4) {
                let key = UInt32(rgba[index]) << 16 | UInt32(rgba[index + 1]) << 8
                    | UInt32(rgba[index + 2])
                colors.insert(key)
                if colors.count > limit { break }
            }
            return colors.count
        }

        enum Hue: String, CaseIterable {
            case red, green, blue, yellow, cyan, magenta, black, white, other
        }

        static func classify(_ color: (Int, Int, Int)) -> Hue {
            let (red, green, blue) = color
            if red < 78 && green < 78 && blue < 78 { return .black }
            if red > 188 && green > 188 && blue > 188 { return .white }
            if blue > 132 && green > 132 && red < 132 { return .cyan }
            if red > 132 && blue > 132 && green < 132 { return .magenta }
            if red > green + 36 && red > blue + 36 { return .red }
            if green > red + 36 && green > blue + 36 { return .green }
            if blue > red + 36 && blue > green + 36 { return .blue }
            if red > 140 && green > 140 && blue < 120 { return .yellow }
            return .other
        }

        func hueHistogram() -> [Hue: Int] {
            // Count only the actual textured object. The scene background is
            // a flat light colour and would otherwise satisfy the "white"
            // class without the texture ever being sampled.
            let bounds = foreground()
            guard bounds.count > 0 else { return [:] }
            let inset = 2
            let minimumX = max(bounds.minimumX + inset, 0)
            let maximumX = min(bounds.maximumX - inset, width - 1)
            let minimumY = max(bounds.minimumY + inset, 0)
            let maximumY = min(bounds.maximumY - inset, height - 1)
            guard minimumX < maximumX, minimumY < maximumY else { return [:] }
            var counts: [Hue: Int] = [:]
            for y in stride(from: minimumY, through: maximumY, by: 2) {
                for x in stride(from: minimumX, through: maximumX, by: 2) {
                    let hue = Self.classify(rgb(x, y))
                    counts[hue, default: 0] += 1
                }
            }
            return counts
        }
    }

    /// Asserts a four-quadrant texture was actually sampled. This cannot pass
    /// for a plain baseColorFactor material (one flat colour) or a dropped
    /// texture, and it is independent of the UV orientation because it checks
    /// the colour set rather than a specific corner.
    private func assertFourQuadrantTexture(_ pixels: Pixels, expected: Set<Pixels.Hue>,
                                           label: String,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        let counts = pixels.hueHistogram()
        let total = counts.values.reduce(0, +)
        XCTAssertGreaterThan(total, 0, "\(label): no pixels sampled", file: file, line: line)
        for hue in expected {
            let count = counts[hue] ?? 0
            XCTAssertGreaterThan(
                Double(count), Double(total) * 0.04,
                "\(label): \(hue.rawValue) is missing from the actual render "
                + "(\(count)/\(total)); histogram \(counts)",
                file: file, line: line)
        }
    }

    // MARK: - 1. Hierarchy, instances, materials, texture, scenes, camera

    func testHierarchyInstancesMaterialsScenesAndCameraAreTheLiveScene() async throws {
        let root = try makeWorkspace([Fixtures.hierarchy])
        let sourceURL = root.appendingPathComponent(Fixtures.hierarchy)
        let original = try Data(contentsOf: sourceURL)
        let digest = FloeDigest.sha256Hex(original)
        let result = try await observe(Fixtures.hierarchy, in: root, .init(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20)],
            width: 480, height: 360, cameraIndex: 0,
            expectedSourceSHA256: digest))
        let summary = try json(result.summaryJSON)
        assertComplete(summary)
        XCTAssertEqual(summary["backend"] as? String, "threeGLTF")
        let state = try state(summary)
        XCTAssertTrue(state.ready)
        XCTAssertEqual(state.scenes.map(\.name), ["Assembly", "Alternative"])
        XCTAssertEqual(state.activeSceneIndex, 0)
        XCTAssertEqual(state.meshCount, 3)
        XCTAssertEqual(state.instancedMeshCount, 1)
        XCTAssertEqual(state.materialCount, 3)
        XCTAssertEqual(state.textureCount, 1)
        XCTAssertEqual(state.skinnedMeshCount, 0)
        XCTAssertEqual(state.morphMeshCount, 0)
        XCTAssertEqual(state.cameras.map(\.name), ["WitnessCamera"])
        XCTAssertEqual(state.cameras.first?.type, "perspective")
        XCTAssertEqual(state.activeCameraIndex, 0)
        XCTAssertEqual(state.clips.map(\.name),
                       ["SlideX", "ScaleStep", "TurnCubic", "SlideStep"])
        XCTAssertEqual(state.clips.map(\.durationSeconds), [1, 1, 1, 1])
        let instanceNode = try XCTUnwrap(
            state.nodes.first(where: { $0.name == "InstancedBoxes" }))
        XCTAssertEqual(instanceNode.instanceCount, 3)
        XCTAssertEqual(result.frames.count, 1)
        let frame = try XCTUnwrap(result.frames.first)
        let metadata = try json(frame.metadataJSON)
        XCTAssertEqual(metadata["renderer"] as? String, "threeGLTF")
        XCTAssertEqual(metadata["sourceSHA256"] as? String, digest)
        XCTAssertEqual(metadata["imageSHA256"] as? String,
                       FloeDigest.sha256Hex(frame.pngData))
        let pixels = try Pixels.decode(frame.pngData)
        XCTAssertGreaterThan(pixels.distinctColorCount(), 20,
                             "a real hierarchy render has shaded materials")
        XCTAssertGreaterThan(pixels.foreground().count, 2_000)

        // Explicit alternate scene: the state must switch to the actual scene
        // rather than reusing scene 0's mesh set.
        let alternate = try await observe(Fixtures.hierarchy, in: root, .init(
            views: [], width: 320, height: 240, sceneIndex: 1, includeImages: false))
        let alternateSummary = try json(alternate.summaryJSON)
        let alternateState = try self.state(alternateSummary)
        XCTAssertEqual(alternateState.activeSceneIndex, 1)
        XCTAssertEqual(alternateState.meshCount, 1)
        XCTAssertEqual(alternate.frames.count, 0)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original,
                       "observation must never rewrite the source")
        attachPNG(frame.pngData, name: "scene-hierarchy-camera")
        attachManifest([
            "witness": "hierarchy/instances/material/texture/scene/camera",
            "sourceSHA256": digest,
            "imageSHA256": FloeDigest.sha256Hex(frame.pngData),
            "frameMetadata": metadata,
            "state": summary["state"] as? [String: Any] ?? [:],
        ], name: "scene-hierarchy-manifest")
    }

    // MARK: - 2. Clips, time and interpolation (actual pixels)

    func testClipTimeAndInterpolationModesChangeActualPixels() async throws {
        let root = try makeWorkspace([Fixtures.hierarchy])
        let digest = FloeDigest.sha256Hex(try Data(
            contentsOf: root.appendingPathComponent(Fixtures.hierarchy)))
        var frames: [Int: (Data, [String: Any])] = [:]
        for clip in 0..<4 {
            let result = try await observe(Fixtures.hierarchy, in: root, .init(
                views: [.init(azimuthDegrees: 35, elevationDegrees: 20)],
                width: 400, height: 300, clipIndex: clip, timeSeconds: 0.5,
                expectedSourceSHA256: digest))
            let summary = try json(result.summaryJSON)
            assertComplete(summary)
            let frame = try XCTUnwrap(result.frames.first)
            let metadata = try json(frame.metadataJSON)
            XCTAssertEqual(metadata["clipIndex"] as? Int, clip)
            XCTAssertEqual(try XCTUnwrap((metadata["timeSeconds"] as? NSNumber)?.doubleValue),
                           0.5, accuracy: 1e-9)
            let state = try state(summary)
            XCTAssertEqual(state.clips.count, 4)
            XCTAssertEqual(state.clips.map(\.interpolations), [
                ["LINEAR"], ["STEP"], ["CUBICSPLINE"], ["STEP"],
            ])
            frames[clip] = (frame.pngData, metadata)
        }
        let linear = try Pixels.decode(try XCTUnwrap(frames[0]).0)
        let scaleStep = try Pixels.decode(try XCTUnwrap(frames[1]).0)
        let cubic = try Pixels.decode(try XCTUnwrap(frames[2]).0)
        let translationStep = try Pixels.decode(try XCTUnwrap(frames[3]).0)
        // Same node, same time, LINEAR vs STEP: the real translation must
        // differ (x = 3.2 vs 2.2) and therefore the pixels must differ.
        XCTAssertGreaterThan(try linear.differenceFraction(from: translationStep), 0.01,
                             "LINEAR and STEP translation must not render identically")
        XCTAssertGreaterThan(try linear.differenceFraction(from: scaleStep), 0.01,
                             "step-scaled geometry must differ from the linear pose")
        XCTAssertGreaterThan(try linear.differenceFraction(from: cubic), 0.01,
                             "cubic rotation must differ from the linear pose")
        XCTAssertNotEqual(FloeDigest.sha256Hex(try XCTUnwrap(frames[0]).0),
                          FloeDigest.sha256Hex(try XCTUnwrap(frames[3]).0))
        attachPNG(try XCTUnwrap(frames[0]).0, name: "scene-clip-linear-0.5")
        attachPNG(try XCTUnwrap(frames[3]).0, name: "scene-clip-step-0.5")
        attachManifest([
            "witness": "clip/time/interpolation actual pixels",
            "sourceSHA256": digest,
            "linear": try XCTUnwrap(frames[0]).1,
            "stepTranslation": try XCTUnwrap(frames[3]).1,
            "stepScale": try XCTUnwrap(frames[1]).1,
            "cubicRotation": try XCTUnwrap(frames[2]).1,
        ], name: "scene-interpolation-manifest")
    }

    // MARK: - 3. Native playback commands on the live WK page

    func testNativePlayPauseSeekLoopSpeedClipCameraAndSceneCommands() async throws {
        let root = try makeWorkspace([Fixtures.hierarchy])
        let sourceURL = root.appendingPathComponent(Fixtures.hierarchy)
        let original = try Data(contentsOf: sourceURL)
        let package = try EngineeringPreviewPackage.load(
            fileURL: sourceURL, includeSiblingResources: false, limits: .standard)
        let session = EngineeringWebSession()
        let errors = Box<String?>(nil)
        let web = session.attach(package: package, identity: "witness-controls",
                                 error: errors.binding, onReview: nil, onSave: nil,
                                 onDirty: nil, dark: false, locale: "en")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIWindow(windowScene: scene)
        host.frame = scene.screen.bounds
        let controller = UIViewController()
        host.rootViewController = controller
        host.makeKeyAndVisible()
        controller.view.addSubview(web)
        web.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        web.layoutIfNeeded()
        XCTAssertTrue(web.window === host && !host.isHidden,
                      "Playback needs a real visible host; offscreen capture does not drive RAF")
        defer {
            web.removeFromSuperview()
            session.tearDown()
            host.isHidden = true
            previousKeyWindow?.makeKey()
        }
        try await waitUntil("the live scene never became ready") {
            session.sceneState?.ready == true
        }
        let autoPlaying = try XCTUnwrap(session.sceneState)
        XCTAssertEqual(autoPlaying.activeClipIndex, 0)
        XCTAssertTrue(autoPlaying.playing, "the scene auto-plays its first clip")

        let paused = try await sceneCommand(.pause, on: session)
        XCTAssertFalse(paused.playing)
        let seeked = try await sceneCommand(.seek(seconds: 0.25), on: session)
        XCTAssertEqual(seeked.timeSeconds, 0.25, accuracy: 1e-6)
        let faster = try await sceneCommand(.speed(2), on: session)
        XCTAssertEqual(faster.speed, 2, accuracy: 1e-9)
        let pingpong = try await sceneCommand(.loop(.pingPong), on: session)
        XCTAssertEqual(pingpong.loopMode, "pingpong")
        let pausedCubic = try await sceneCommand(.selectClip(index: 2), on: session)
        XCTAssertEqual(pausedCubic.activeClipIndex, 2)
        XCTAssertEqual(pausedCubic.clips[2].interpolations, ["CUBICSPLINE"])
        let camera = try await sceneCommand(.selectCamera(index: 0), on: session)
        XCTAssertEqual(camera.activeCameraIndex, 0)
        let alternate = try await sceneCommand(.selectScene(index: 1), on: session)
        XCTAssertEqual(alternate.activeSceneIndex, 1)
        XCTAssertEqual(alternate.meshCount, 1)
        let assembly = try await sceneCommand(.selectScene(index: 0), on: session)
        XCTAssertEqual(assembly.activeSceneIndex, 0)
        _ = await session.sceneCommand(.selectClip(index: 0))
        _ = await session.sceneCommand(.seek(seconds: 0))
        _ = await session.sceneCommand(.pause)
        _ = await session.sceneCommand(.fit)

        let first = try await session.captureScene(.init(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20)],
            width: 400, height: 300, clipIndex: 0, timeSeconds: 0,
            maximumFrames: 1, maximumPNGBytes: 8 * 1024 * 1024,
            maximumTotalBytes: 16 * 1024 * 1024))
        XCTAssertEqual(first.frames.count, 1)
        XCTAssertEqual(first.failures.count, 0)
        let before = try XCTUnwrap(first.frames.first)
        XCTAssertEqual(before.renderer, "threeGLTF")
        XCTAssertEqual(before.sourceSHA256, package.provenance.sourceSHA256)
        _ = try await sceneCommand(.seek(seconds: 0.5), on: session)
        let second = try await session.captureScene(.init(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20)],
            width: 400, height: 300, clipIndex: 0, timeSeconds: 0.5,
            maximumFrames: 1, maximumPNGBytes: 8 * 1024 * 1024,
            maximumTotalBytes: 16 * 1024 * 1024))
        let after = try XCTUnwrap(second.frames.first)
        XCTAssertGreaterThan(
            try Pixels.decode(after.pngData).differenceFraction(
                from: Pixels.decode(before.pngData)), 0.01,
            "seeking the live scene must produce different actual pixels")

        // Loop once must actually stop at the end, driven by the real mixer
        // tick rather than by copying a state flag.
        _ = await session.sceneCommand(.selectClip(index: 0))
        _ = await session.sceneCommand(.loop(.once))
        _ = try await sceneCommand(.seek(seconds: 0.95), on: session)
        _ = try await sceneCommand(.play, on: session)
        try await waitUntil("play-once did not stop at the clip end", timeout: 6) {
            session.sceneState.map { !$0.playing && $0.timeSeconds >= 0.98 } ?? false
        }
        let finished = try XCTUnwrap(session.sceneState)
        XCTAssertFalse(finished.playing)
        XCTAssertEqual(finished.timeSeconds, finished.durationSeconds, accuracy: 0.02)
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        attachPNG(before.pngData, name: "scene-controls-time-0")
        attachPNG(after.pngData, name: "scene-controls-time-0.5")
        attachManifest([
            "witness": "native play/pause/seek/loop/speed/clip/camera/scene commands",
            "sourceSHA256": package.provenance.sourceSHA256,
            "captureEntryPoint": "EngineeringWebSession.captureScene",
            "firstFrame": before.receipt,
            "secondFrame": after.receipt,
            "finishedState": "playing=\(finished.playing) time=\(finished.timeSeconds)",
        ], name: "scene-controls-manifest")
    }

    // MARK: - 4. Skin and morph (actual deformed pixels)

    func testSkinnedMeshAnimationChangesActualPixels() async throws {
        let root = try makeWorkspace([Fixtures.skin])
        let sourceURL = root.appendingPathComponent(Fixtures.skin)
        let original = try Data(contentsOf: sourceURL)
        let digest = FloeDigest.sha256Hex(original)
        let rest = try await observe(Fixtures.skin, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 400, height: 300, clipIndex: 0, timeSeconds: 0,
            expectedSourceSHA256: digest))
        let bent = try await observe(Fixtures.skin, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 400, height: 300, clipIndex: 0, timeSeconds: 0.75,
            expectedSourceSHA256: digest))
        let restSummary = try json(rest.summaryJSON)
        let bentSummary = try json(bent.summaryJSON)
        assertComplete(restSummary)
        assertComplete(bentSummary)
        let state = try state(restSummary)
        XCTAssertEqual(state.skinnedMeshCount, 1)
        XCTAssertEqual(state.morphMeshCount, 0)
        XCTAssertEqual(state.clips.map(\.name), ["Bend"])
        let skinNode = try XCTUnwrap(
            state.nodes.first(where: { $0.type == "SkinnedMesh" }))
        XCTAssertEqual(skinNode.name, "SkinnedBar")
        let restFrame = try XCTUnwrap(rest.frames.first)
        let bentFrame = try XCTUnwrap(bent.frames.first)
        let restMeta = try json(restFrame.metadataJSON)
        let bentMeta = try json(bentFrame.metadataJSON)
        XCTAssertEqual(try XCTUnwrap((restMeta["timeSeconds"] as? NSNumber)?.doubleValue),
                       0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap((bentMeta["timeSeconds"] as? NSNumber)?.doubleValue),
                       0.75, accuracy: 1e-9)
        let difference = try Pixels.decode(bentFrame.pngData)
            .differenceFraction(from: Pixels.decode(restFrame.pngData))
        XCTAssertGreaterThan(difference, 0.02,
                             "the skinned pose must change actual pixels")
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        attachPNG(restFrame.pngData, name: "scene-skin-rest")
        attachPNG(bentFrame.pngData, name: "scene-skin-bent")
        attachManifest([
            "witness": "skinned mesh actual pixels",
            "sourceSHA256": digest,
            "differenceFraction": difference,
            "rest": restMeta, "bent": bentMeta,
        ], name: "scene-skin-manifest")
    }

    func testMorphTargetAnimationChangesActualPixels() async throws {
        let root = try makeWorkspace([Fixtures.morph])
        let sourceURL = root.appendingPathComponent(Fixtures.morph)
        let original = try Data(contentsOf: sourceURL)
        let digest = FloeDigest.sha256Hex(original)
        let base = try await observe(Fixtures.morph, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 400, height: 300, clipIndex: 0, timeSeconds: 0,
            expectedSourceSHA256: digest))
        let grown = try await observe(Fixtures.morph, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 400, height: 300, clipIndex: 0, timeSeconds: 0.75,
            expectedSourceSHA256: digest))
        let summary = try json(base.summaryJSON)
        assertComplete(summary)
        let state = try state(summary)
        XCTAssertEqual(state.morphMeshCount, 1)
        XCTAssertEqual(state.skinnedMeshCount, 0)
        let baseFrame = try XCTUnwrap(base.frames.first)
        let grownFrame = try XCTUnwrap(grown.frames.first)
        let difference = try Pixels.decode(grownFrame.pngData)
            .differenceFraction(from: Pixels.decode(baseFrame.pngData))
        XCTAssertGreaterThan(difference, 0.02,
                             "the morph target must change actual pixels")
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        attachPNG(baseFrame.pngData, name: "scene-morph-base")
        attachPNG(grownFrame.pngData, name: "scene-morph-grown")
        attachManifest([
            "witness": "morph target actual pixels",
            "sourceSHA256": digest,
            "differenceFraction": difference,
            "base": try json(baseFrame.metadataJSON),
            "grown": try json(grownFrame.metadataJSON),
        ], name: "scene-morph-manifest")
    }

    // MARK: - 5. Bundled decoders (separate real samples)

    func testDracoCompressedGeometryDecodesAndRenders() async throws {
        let root = try makeWorkspace([Fixtures.draco, Fixtures.dracoBinary])
        let sourceURL = root.appendingPathComponent(Fixtures.draco)
        let original = try Data(contentsOf: sourceURL)
        let binary = try Data(contentsOf: root.appendingPathComponent(Fixtures.dracoBinary))
        let package = try EngineeringPreviewPackage.load(
            fileURL: sourceURL, includeSiblingResources: true, limits: .standard)
        XCTAssertTrue(package.diagnostics.usedExtensions.contains(
            "KHR_draco_mesh_compression"),
            "the Draco sample must declare its compression extension")
        XCTAssertTrue(package.diagnostics.issues.contains { $0.code == .compressedAsset },
                      "the compressed asset must be reported explicitly")
        XCTAssertTrue(package.diagnostics.isScenePreviewAvailable)
        let digest = FloeDigest.sha256Hex(original)
        let result = try await observe(Fixtures.draco, in: root, .init(
            views: [.init(azimuthDegrees: 35, elevationDegrees: 20)],
            width: 400, height: 300, expectedSourceSHA256: digest))
        let summary = try json(result.summaryJSON)
        assertComplete(summary)
        let state = try state(summary)
        XCTAssertEqual(state.meshCount, 1)
        XCTAssertGreaterThanOrEqual(state.nodeCount, 2)
        XCTAssertGreaterThan(try XCTUnwrap(state.bounds).radius, 0.5,
                             "decoded Box bounds must be non-degenerate")
        let frame = try XCTUnwrap(result.frames.first)
        let pixels = try Pixels.decode(frame.pngData)
        XCTAssertGreaterThan(pixels.distinctColorCount(), 12,
                             "decoded Draco geometry must be shaded, not a blank canvas")
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(
            Fixtures.dracoBinary)), binary)
        attachPNG(frame.pngData, name: "scene-draco-box")
        attachManifest([
            "witness": "Draco compressed geometry decoded by the bundled wasm decoder",
            "source": "Khronos glTF-Sample-Assets Box glTF-Draco (CC BY 4.0)",
            "sourceSHA256": digest,
            "binarySHA256": FloeDigest.sha256Hex(binary),
            "state": summary["state"] as? [String: Any] ?? [:],
        ], name: "scene-draco-manifest")
    }

    func testMeshoptCompressedGeometryAndTextureDecodeAndRender() async throws {
        let root = try makeWorkspace([Fixtures.meshopt])
        let sourceURL = root.appendingPathComponent(Fixtures.meshopt)
        let original = try Data(contentsOf: sourceURL)
        let package = try EngineeringPreviewPackage.load(
            fileURL: sourceURL, includeSiblingResources: false, limits: .standard)
        XCTAssertTrue(package.diagnostics.usedExtensions.contains(
            "EXT_meshopt_compression"),
            "the meshopt sample must declare EXT_meshopt_compression")
        XCTAssertTrue(package.diagnostics.isScenePreviewAvailable)
        let digest = FloeDigest.sha256Hex(original)
        let result = try await observe(Fixtures.meshopt, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 480, height: 360, expectedSourceSHA256: digest))
        let summary = try json(result.summaryJSON)
        assertComplete(summary)
        let state = try state(summary)
        XCTAssertEqual(state.meshCount, 1)
        XCTAssertEqual(state.textureCount, 1)
        XCTAssertGreaterThan(try XCTUnwrap(state.bounds).radius, 0.5)
        let frame = try XCTUnwrap(result.frames.first)
        let pixels = try Pixels.decode(frame.pngData)
        assertFourQuadrantTexture(pixels,
                                  expected: [.red, .green, .blue, .yellow],
                                  label: "meshopt")
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        attachPNG(frame.pngData, name: "scene-meshopt")
        attachManifest([
            "witness": "meshopt compressed geometry + embedded texture",
            "sourceSHA256": digest,
            "state": summary["state"] as? [String: Any] ?? [:],
        ], name: "scene-meshopt-manifest")
    }

    func testKTX2BasisTextureTranscodesAndRenders() async throws {
        let root = try makeWorkspace([Fixtures.ktx2])
        let sourceURL = root.appendingPathComponent(Fixtures.ktx2)
        let original = try Data(contentsOf: sourceURL)
        let package = try EngineeringPreviewPackage.load(
            fileURL: sourceURL, includeSiblingResources: false, limits: .standard)
        XCTAssertTrue(package.diagnostics.usedExtensions.contains(
            "KHR_texture_basisu"),
            "the KTX2 sample must declare KHR_texture_basisu")
        XCTAssertEqual(package.diagnostics.imageCount, 1)
        XCTAssertTrue(package.diagnostics.isScenePreviewAvailable)
        let digest = FloeDigest.sha256Hex(original)
        let result = try await observe(Fixtures.ktx2, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 480, height: 360, expectedSourceSHA256: digest))
        let summary = try json(result.summaryJSON)
        assertComplete(summary)
        let state = try state(summary)
        XCTAssertEqual(state.textureCount, 1,
                       "the Basis texture must be attached to the live material")
        let frame = try XCTUnwrap(result.frames.first)
        let pixels = try Pixels.decode(frame.pngData)
        assertFourQuadrantTexture(pixels,
                                  expected: [.red, .green, .blue, .yellow],
                                  label: "KTX2")
        XCTAssertEqual(try Data(contentsOf: sourceURL), original)
        attachPNG(frame.pngData, name: "scene-ktx2")
        attachManifest([
            "witness": "KTX2/Basis texture transcoded by the bundled transcoder",
            "sourceSHA256": digest,
            "state": summary["state"] as? [String: Any] ?? [:],
        ], name: "scene-ktx2-manifest")
    }

    // MARK: - 6. Material texture bytes (plain PNG baseline)

    func testMaterialTextureBytesDriveActualColour() async throws {
        let root = try makeWorkspace([Fixtures.textureA, Fixtures.textureB])
        let firstURL = root.appendingPathComponent(Fixtures.textureA)
        let secondURL = root.appendingPathComponent(Fixtures.textureB)
        let firstBytes = try Data(contentsOf: firstURL)
        let secondBytes = try Data(contentsOf: secondURL)
        let first = try await observe(Fixtures.textureA, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 480, height: 360,
            expectedSourceSHA256: FloeDigest.sha256Hex(firstBytes)))
        let second = try await observe(Fixtures.textureB, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 480, height: 360,
            expectedSourceSHA256: FloeDigest.sha256Hex(secondBytes)))
        let firstSummary = try json(first.summaryJSON)
        let secondSummary = try json(second.summaryJSON)
        assertComplete(firstSummary)
        assertComplete(secondSummary)
        let firstState = try state(firstSummary)
        XCTAssertEqual(firstState.materialCount, 1)
        XCTAssertEqual(firstState.textureCount, 1)
        let firstPixels = try Pixels.decode(try XCTUnwrap(first.frames.first).pngData)
        let secondPixels = try Pixels.decode(try XCTUnwrap(second.frames.first).pngData)
        assertFourQuadrantTexture(firstPixels,
                                  expected: [.red, .green, .blue, .yellow],
                                  label: "texture-A")
        assertFourQuadrantTexture(secondPixels,
                                  expected: [.black, .white, .cyan, .magenta],
                                  label: "texture-B")
        let unchanged = try await observe(Fixtures.textureA, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 480, height: 360,
            expectedSourceSHA256: FloeDigest.sha256Hex(firstBytes)))
        let unchangedPixels = try Pixels.decode(try XCTUnwrap(unchanged.frames.first).pngData)
        XCTAssertLessThan(try firstPixels.differenceFraction(from: unchangedPixels), 0.005,
                          "the same source texture is a negative control")
        XCTAssertGreaterThan(try firstPixels.objectDifferenceFraction(from: secondPixels), 0.8,
                             "changing all four source quadrants must change the actual object pixels")
        XCTAssertEqual(try Data(contentsOf: firstURL), firstBytes)
        XCTAssertEqual(try Data(contentsOf: secondURL), secondBytes)
        attachPNG(try XCTUnwrap(first.frames.first).pngData, name: "scene-texture-a")
        attachPNG(try XCTUnwrap(second.frames.first).pngData, name: "scene-texture-b")
        attachManifest([
            "witness": "material texture source bytes drive actual colour",
            "textureASHA256": FloeDigest.sha256Hex(firstBytes),
            "textureBSHA256": FloeDigest.sha256Hex(secondBytes),
            "textureAState": firstSummary["state"] as? [String: Any] ?? [:],
        ], name: "scene-texture-manifest")
    }

    // MARK: - 6. Controlled sibling .bin/texture association

    func testSiblingBufferAndTextureAssociationIsControlledAndSourceBound() async throws {
        let root = try makeWorkspace([
            Fixtures.siblings, Fixtures.siblingsBinary, Fixtures.siblingsTexture,
        ])
        let gltfURL = root.appendingPathComponent(Fixtures.siblings)
        let original = try Data(contentsOf: gltfURL)
        let binaryURL = root.appendingPathComponent(Fixtures.siblingsBinary)
        let textureURL = root.appendingPathComponent(Fixtures.siblingsTexture)
        let originalBinary = try Data(contentsOf: binaryURL)
        let originalTexture = try Data(contentsOf: textureURL)

        // The single-file grant (a chat attachment copy) must NOT silently
        // reach outside its grant: the missing buffer is a blocking diagnosis.
        let single = try EngineeringPreviewPackage.load(
            fileURL: gltfURL, includeSiblingResources: false, limits: .standard)
        XCTAssertEqual(single.files.map(\.name), [Fixtures.siblings])
        XCTAssertTrue(single.missingReferences.contains(Fixtures.siblingsBinary))
        XCTAssertTrue(single.missingReferences.contains(Fixtures.siblingsTexture))
        XCTAssertTrue(single.diagnostics.blockingIssues.contains {
            $0.code == .missingBuffer
        })
        XCTAssertFalse(single.diagnostics.isScenePreviewAvailable)

        // The explicit directory grant collects the exact .bin and nested
        // texture and produces a complete package.
        let bundled = try EngineeringPreviewPackage.load(
            fileURL: gltfURL, includeSiblingResources: true, limits: .expandedReadOnly)
        XCTAssertEqual(Set(bundled.files.map(\.name)),
                       [Fixtures.siblings, Fixtures.siblingsBinary,
                        Fixtures.siblingsTexture])
        XCTAssertTrue(bundled.missingReferences.isEmpty)
        XCTAssertTrue(bundled.diagnostics.blockingIssues.isEmpty)
        XCTAssertEqual(bundled.provenance.resourceCount, 3)
        XCTAssertEqual(bundled.provenance.maximumBytes, 64 * 1024 * 1024)
        XCTAssertEqual(bundled.provenance.maximumFiles, 128)

        let digest = FloeDigest.sha256Hex(original)
        let first = try await observe(Fixtures.siblings, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 400, height: 300, expectedSourceSHA256: digest))
        let firstSummary = try json(first.summaryJSON)
        assertComplete(firstSummary)
        let firstResources = try XCTUnwrap(
            provenance(firstSummary)["resources"] as? [[String: Any]])
        XCTAssertTrue(firstResources.contains {
            $0["name"] as? String == Fixtures.siblingsTexture
        }, "the observation receipt must name the exact texture bytes")

        // Change only the sibling texture: the main file hash still matches,
        // but the new capture must use the new texture and report its hash.
        let replacementTexture = try PixelsFixture.solidPNG(
            red: 24, green: 196, blue: 72)
        try replacementTexture.write(to: textureURL, options: .atomic)
        let second = try await observe(Fixtures.siblings, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 400, height: 300, expectedSourceSHA256: digest))
        let secondSummary = try json(second.summaryJSON)
        assertComplete(secondSummary)
        let secondResources = try XCTUnwrap(
            provenance(secondSummary)["resources"] as? [[String: Any]])
        XCTAssertTrue(secondResources.contains {
            ($0["name"] as? String) == Fixtures.siblingsTexture
                && ($0["sha256"] as? String) == FloeDigest.sha256Hex(replacementTexture)
        })
        XCTAssertFalse(secondResources.contains {
            ($0["name"] as? String) == Fixtures.siblingsTexture
                && ($0["sha256"] as? String) == FloeDigest.sha256Hex(originalTexture)
        })
        let firstFrame = try XCTUnwrap(first.frames.first)
        let secondFrame = try XCTUnwrap(second.frames.first)
        XCTAssertGreaterThan(
            try Pixels.decode(secondFrame.pngData)
                .differenceFraction(from: Pixels.decode(firstFrame.pngData)),
            0.05, "the changed sibling texture must change actual pixels")
        XCTAssertEqual(try Data(contentsOf: gltfURL), original,
                       "the .gltf must not be rewritten")
        XCTAssertEqual(try Data(contentsOf: binaryURL), originalBinary,
                       "the sibling .bin must not be rewritten")
        attachPNG(firstFrame.pngData, name: "scene-siblings-before")
        attachPNG(secondFrame.pngData, name: "scene-siblings-after-texture-change")
        attachManifest([
            "witness": "controlled sibling .bin/texture association",
            "sourceSHA256": digest,
            "beforeResources": firstResources,
            "afterResources": secondResources,
            "singleFileGrantBlocking": single.diagnostics.blockingIssues.map(\.code.rawValue),
        ], name: "scene-siblings-manifest")
    }

    // MARK: - 8. Missing and unsupported resources are explicit

    func testMissingAndUnsupportedResourcesAreExplicitRefusals() async throws {
        let root = try makeWorkspace([])
        let accessorJSON = """
        "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3",
        "min":[0,0,0],"max":[1,1,0]}],
        "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36}]
        """
        let missing = """
        {"asset":{"version":"2.0"},"scene":0,
        "scenes":[{"name":"Missing","nodes":[0]}],
        "nodes":[{"name":"MissingTriangle","mesh":0}],
        "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        "buffers":[{"uri":"absent.bin","byteLength":36}],
        "images":[{"uri":"absent.png"}],
        \(accessorJSON)}
        """
        try write(Data(missing.utf8), named: "missing.gltf", in: root)
        let missingURL = root.appendingPathComponent("missing.gltf")
        let missingPackage = try EngineeringPreviewPackage.load(
            fileURL: missingURL, includeSiblingResources: true, limits: .standard)
        XCTAssertTrue(missingPackage.diagnostics.blockingIssues.contains {
            $0.code == .missingBuffer && $0.detail == "absent.bin"
        })
        XCTAssertTrue(missingPackage.diagnostics.warnings.contains {
            $0.code == .missingResource && $0.detail == "absent.png"
        })
        XCTAssertFalse(missingPackage.diagnostics.isScenePreviewAvailable,
                       "a missing required buffer must block the preview")

        do {
            _ = try await observe("missing.gltf", in: root, .init(
                views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
                width: 320, height: 240))
            XCTFail("a blocking missing buffer must not produce frames")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot be rendered completely"),
                          "unexpected error: \(error.localizedDescription)")
            XCTAssertTrue(error.localizedDescription.contains("missingBuffer"))
        }

        let unsupported = """
        {"asset":{"version":"2.0"},
        "extensionsUsed":["KHR_materials_future"],
        "extensionsRequired":["KHR_materials_future"],
        "scene":0,"scenes":[{"name":"Future","nodes":[0]}],
        "nodes":[{"name":"FutureTriangle","mesh":0}],
        "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],
        "buffers":[{"uri":"positions.bin","byteLength":36}],
        \(accessorJSON)}
        """
        try write(Data(unsupported.utf8), named: "unsupported.gltf", in: root)
        try write(trianglePositions(), named: "positions.bin", in: root)
        let unsupportedURL = root.appendingPathComponent("unsupported.gltf")
        let unsupportedPackage = try EngineeringPreviewPackage.load(
            fileURL: unsupportedURL, includeSiblingResources: true, limits: .standard)
        XCTAssertTrue(unsupportedPackage.diagnostics.blockingIssues.contains {
            $0.code == .unsupportedRequiredExtension
                && $0.detail == "KHR_materials_future"
        })
        XCTAssertFalse(unsupportedPackage.diagnostics.isScenePreviewAvailable)
        do {
            _ = try await observe("unsupported.gltf", in: root, .init(
                views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
                width: 320, height: 240))
            XCTFail("an unsupported required extension must not produce frames")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "unsupportedRequiredExtension"),
                "unexpected error: \(error.localizedDescription)")
        }
        attachManifest([
            "witness": "missing/unsupported resources refuse instead of a silent fallback",
            "missingBlocking": missingPackage.diagnostics.blockingIssues.map(\.code.rawValue),
            "missingWarnings": missingPackage.diagnostics.warnings.map(\.code.rawValue),
            "unsupportedBlocking": unsupportedPackage.diagnostics.blockingIssues
                .map(\.code.rawValue),
        ], name: "scene-resource-refusal-manifest")
    }

    // MARK: - 9. Explicit 64 MiB / 128-file App route

    func testExplicit64MiB128FileRouteLoadsAndRendersAndOverflowIsRefused() async throws {
        let root = try makeWorkspace([])
        let success = try makeBudgetFixture(count: 126, name: "budget-128.gltf", in: root)
        let successBytes = try Data(contentsOf: success)
        let expanded = try EngineeringPreviewPackage.load(
            fileURL: success, includeSiblingResources: true, limits: .expandedReadOnly)
        XCTAssertEqual(expanded.files.count, 128)
        XCTAssertEqual(expanded.provenance.resourceCount, 128)
        XCTAssertEqual(expanded.provenance.maximumBytes, 64 * 1024 * 1024)
        XCTAssertEqual(expanded.provenance.maximumFiles, 128)
        XCTAssertTrue(expanded.missingReferences.isEmpty)
        XCTAssertTrue(expanded.diagnostics.blockingIssues.isEmpty)
        XCTAssertThrowsError(try EngineeringPreviewPackage.load(
            fileURL: success, includeSiblingResources: true, limits: .standard)) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadTooLargeError,
                           "the default 32-file route must not silently accept the package")
        }

        let digest = FloeDigest.sha256Hex(try Data(contentsOf: success))
        let result = try await observe(success.lastPathComponent, in: root, .init(
            views: [.init(azimuthDegrees: 0, elevationDegrees: 0)],
            width: 320, height: 240,
            expectedSourceSHA256: digest,
            maximumSourceBytes: 64 * 1024 * 1024, maximumResources: 128))
        let summary = try json(result.summaryJSON)
        assertComplete(summary)
        let state = try state(summary)
        XCTAssertTrue(state.ready)
        XCTAssertEqual(state.textureCount, 1)
        let frame = try XCTUnwrap(result.frames.first)
        XCTAssertGreaterThan(try Pixels.decode(frame.pngData).foreground().count, 300)
        XCTAssertEqual(try Data(contentsOf: success), successBytes,
                       "the source must remain byte-identical")

        let overflow = try makeBudgetFixture(count: 127, name: "budget-129.gltf", in: root)
        XCTAssertThrowsError(try EngineeringPreviewPackage.load(
            fileURL: overflow, includeSiblingResources: true, limits: .expandedReadOnly)) { error in
            XCTAssertEqual((error as NSError).code, NSFileReadTooLargeError,
                           "129 files must exceed the 128-file route")
        }
        attachPNG(frame.pngData, name: "scene-budget-128-files")
        attachManifest([
            "witness": "explicit 64 MiB / 128-file read-only App route",
            "sourceSHA256": digest,
            "fileCount": expanded.files.count,
            "maximumBytes": expanded.provenance.maximumBytes,
            "maximumFiles": expanded.provenance.maximumFiles,
            "state": summary["state"] as? [String: Any] ?? [:],
        ], name: "scene-budget-manifest")
    }

    // MARK: - Budget fixture

    /// Builds a glTF whose main file references `count` external PNGs plus
    /// one .bin, i.e. count + 2 files. Exactly 128 files are accepted by the
    /// explicit route; 129 are refused. 126 unused images do not need to be
    /// decoded by GLTFLoader; the used one is the visible textured quad.
    @discardableResult
    private func makeBudgetFixture(count: Int, name: String, in root: URL) throws -> URL {
        let png = try PixelsFixture.solidPNG(red: 210, green: 40, blue: 40)
        let positions = [
            Float(-1.25), -1.25, 0, 1.25, -1.25, 0, 1.25, 1.25, 0, -1.25, 1.25, 0,
        ]
        let uvs: [Float] = [0, 1, 1, 1, 1, 0, 0, 0]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        var binary = Data()
        positions.withUnsafeBytes { binary.append(contentsOf: $0) }
        uvs.withUnsafeBytes { binary.append(contentsOf: $0) }
        indices.withUnsafeBytes { binary.append(contentsOf: $0) }
        try write(binary, named: "budget.bin", in: root)
        var images: [[String: Any]] = []
        for index in 0..<count {
            let relative = String(format: "textures/t%03d.png", index)
            try write(png, named: relative, in: root)
            images.append(["uri": relative, "mimeType": "image/png"])
        }
        let document: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Floe budget witness"],
            "extensionsUsed": ["KHR_materials_unlit"],
            "scene": 0,
            "scenes": [["name": "BudgetScene", "nodes": [0]]],
            "nodes": [
                ["name": "BudgetQuad", "mesh": 0],
                ["name": "CameraNode", "camera": 0, "translation": [0, 0, 6]],
            ],
            "cameras": [["name": "BudgetCamera", "type": "perspective",
                         "perspective": ["yfov": 0.7, "znear": 0.01, "zfar": 100]]],
            "meshes": [[
                "name": "BudgetMesh",
                "primitives": [[
                    "attributes": ["POSITION": 0, "TEXCOORD_0": 1],
                    "indices": 2, "material": 0,
                ]],
            ]],
            "materials": [[
                "name": "BudgetRed",
                "extensions": ["KHR_materials_unlit": [String: Any]()],
                "pbrMetallicRoughness": ["baseColorTexture": ["index": 0],
                                         "metallicFactor": 0, "roughnessFactor": 1],
                "doubleSided": true,
            ]],
            "images": images,
            "textures": [["sampler": 0, "source": 0]],
            "samplers": [["magFilter": 9728, "minFilter": 9728,
                          "wrapS": 33071, "wrapT": 33071]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4,
                 "type": "VEC3", "min": [-1.25, -1.25, 0], "max": [1.25, 1.25, 0]],
                ["bufferView": 1, "componentType": 5126, "count": 4, "type": "VEC2"],
                ["bufferView": 2, "componentType": 5123, "count": 6, "type": "SCALAR"],
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 48, "target": 34962],
                ["buffer": 0, "byteOffset": 48, "byteLength": 32, "target": 34962],
                ["buffer": 0, "byteOffset": 80, "byteLength": 12, "target": 34963],
            ],
            "buffers": [["uri": "budget.bin", "byteLength": 92]],
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func trianglePositions() -> Data {
        var data = Data()
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Sends one typed native scene command and refuses a page that did not
    /// return a state. The command result is awaited before unwrapping so the
    /// assertion never hides an asynchronous failure.
    private func sceneCommand(_ command: EngineeringSceneCommand,
                              on session: EngineeringWebSession,
                              file: StaticString = #filePath,
                              line: UInt = #line) async throws -> EngineeringSceneState {
        guard let state = await session.sceneCommand(command) else {
            XCTFail("the live scene rejected \(command)", file: file, line: line)
            throw FloeError.validationFailed("the live scene rejected a command")
        }
        return state
    }

    // MARK: - Async wait

    private func waitUntil(_ message: String, timeout: TimeInterval = 45,
                           poll: Duration = .milliseconds(80),
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: poll)
        }
        XCTFail(message)
        throw FloeError.validationFailed(message)
    }
}

// MARK: - Test-only storage / PNG fixture helpers

/// Anchors `Bundle(for:)` to the App test bundle that carries
/// `Tests/Fixtures/EngineeringScene`.
private final class SceneFixtureBundleAnchor: NSObject {}

private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
    var binding: Binding<T> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

private enum PixelsFixture {
    static func solidPNG(red: UInt8, green: UInt8, blue: UInt8,
                         width: Int = 2, height: Int = 2) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            bytes[index] = red
            bytes[index + 1] = green
            bytes[index + 2] = blue
            bytes[index + 3] = 255
        }
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
        guard CGImageDestinationFinalize(destination) else {
            throw FloeError.validationFailed("could not encode the PNG fixture")
        }
        return output as Data
    }
}
#endif
