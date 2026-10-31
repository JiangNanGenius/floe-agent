//
//  CADAnimationExportOptionsTests.swift
//  FloeCADKitTests
//
//  Original X28 — Present MP4 export options, end to end.
//
//  Two layers, matching the acceptance contract:
//
//  1. CADAnimationExportOptionsMappingTests (pure): the options the UI offers
//     map EXACTLY onto the production CADAnimationExportSettings — nothing is
//     silently restored to defaults — the default selection reproduces the
//     historical export, and persistence is additive with graceful fallback.
//
//  2. CADAnimationExportReadbackTests (App-hosted UIKit/RealityKit): drives
//     the REAL Present path (production pane hosted in a UIWindow, capture
//     registry active, real stage) and exports a few REAL frames through the
//     production exporter, then reads the written MP4 back with AVFoundation
//     and checks the actual width/height/orientation, frame count/rate and
//     codec. No mock writer, no image-standing-in-for-video. Hostless runs
//     SKIP — nothing is fabricated.
//

import Foundation
import XCTest

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import SwiftUI
import RealityKit
import UIKit
import AVFoundation
import simd

@testable import FloeCAD

// MARK: - Options → settings mapping + persistence

@MainActor
final class CADAnimationExportOptionsMappingTests: XCTestCase {

    func testDefaultSelectionReproducesHistoricalExportSettings() {
        let settings = CADAnimationExportOptions.default.exportSettings()
        XCTAssertEqual(settings, .default)
        XCTAssertEqual(settings.width, 1920)
        XCTAssertEqual(settings.height, 1080)
        XCTAssertEqual(settings.frameRate, 30)
        XCTAssertEqual(settings.codec, .h264)
        XCTAssertNil(settings.bitrate)
    }

    func testPortraitSelectionIsNotSilentlyResetToDefaults() {
        var options = CADAnimationExportOptions.default
        options.orientation = .portrait
        options.resolution = .p720
        options.frameRate = .fps24
        options.codec = .hevc
        options.quality = .higher
        let settings = options.exportSettings()
        // Exact pass-through, orientation swapped, nothing re-defaulted.
        XCTAssertEqual(settings.width, 720)
        XCTAssertEqual(settings.height, 1280)
        XCTAssertEqual(settings.frameRate, 24)
        XCTAssertEqual(settings.codec, .hevc)
        XCTAssertNotEqual(settings, .default)
        XCTAssertNil(settings.validationError)
        // Higher quality doubles the exporter's own automatic budget.
        let auto = min(40_000_000, max(2_000_000,
                                       720 * 1280 * 24 / 3))
        XCTAssertEqual(settings.bitrate, min(80_000_000, auto * 2))
    }

    func testQualityPoliciesMapOntoValidatedBitrates() {
        var options = CADAnimationExportOptions.default
        options.quality = .automatic
        XCTAssertNil(options.exportSettings().bitrate)

        options.quality = .smaller
        let smaller = options.exportSettings()
        XCTAssertEqual(smaller.bitrate, max(250_000, options.automaticBitrate / 2))

        options.resolution = .p2160
        options.frameRate = .fps60
        options.quality = .higher
        let higher = options.exportSettings()
        XCTAssertEqual(higher.bitrate, 80_000_000)
        XCTAssertNil(higher.validationError)
    }

    func testEveryOfferedCombinationPassesExporterValidation() {
        for orientation in CADAnimationExportOrientation.allCases {
            for resolution in CADAnimationExportResolution.allCases {
                for frameRate in CADAnimationExportFrameRate.allCases {
                    for codec in CADAnimationVideoCodec.allCases {
                        for quality in CADAnimationExportQuality.allCases {
                            let options = CADAnimationExportOptions(
                                orientation: orientation, resolution: resolution,
                                frameRate: frameRate, codec: codec, quality: quality)
                            let settings = options.exportSettings()
                            XCTAssertNil(settings.validationError,
                                         "\(options) must export as-is")
                            XCTAssertEqual(settings.width % 2, 0)
                            XCTAssertEqual(settings.height % 2, 0)
                        }
                    }
                }
            }
        }
    }

    func testPersistenceRoundTripsAndFallsBackGracefully() throws {
        let suite = "floe.cad.animationExportOptions.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Absent preference → historical default.
        XCTAssertEqual(CADAnimationExportOptions.load(from: defaults), .default)

        var saved = CADAnimationExportOptions.default
        saved.orientation = .portrait
        saved.resolution = .p1440
        saved.frameRate = .fps60
        saved.codec = .hevc
        saved.quality = .smaller
        saved.save(to: defaults)
        XCTAssertEqual(CADAnimationExportOptions.load(from: defaults), saved)

        // Corrupt payload → default, never a crash and never a half-parsed
        // selection silently changing the export.
        defaults.set(Data("not json".utf8), forKey: "floe.cad.animationExportOptions")
        XCTAssertEqual(CADAnimationExportOptions.load(from: defaults), .default)

        // Partial/legacy payload (fields missing or unknown) → per-field
        // historical defaults.
        let partial = Data("""
            {"orientation":"portrait","codec":"av1","frameRate":12}
            """.utf8)
        defaults.set(partial, forKey: "floe.cad.animationExportOptions")
        let loaded = CADAnimationExportOptions.load(from: defaults)
        XCTAssertEqual(loaded.orientation, .portrait)
        XCTAssertEqual(loaded.codec, .h264)
        XCTAssertEqual(loaded.frameRate, .fps30)
        XCTAssertEqual(loaded.resolution, .p1080)
        XCTAssertEqual(loaded.quality, .automatic)
    }
}

// MARK: - REAL export + AVFoundation media read-back

@MainActor
final class CADAnimationExportReadbackTests: XCTestCase {
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

    /// UI pick (portrait 720p, 24 fps, HEVC, smaller file) → real exporter →
    /// read the actual MP4 back and verify its metadata. Run on the canonical
    /// iPad; the exporter refuses codecs the device cannot encode, which is
    /// real validation, not a test failure.
    func testPortraitHevcSelectionSurvivesIntoOutputMetadata() async throws {
        let fixture = try await hostedFixture(clipDuration: 0.5)
        let options = CADAnimationExportOptions(
            orientation: .portrait, resolution: .p720, frameRate: .fps24,
            codec: .hevc, quality: .smaller)
        let destination = fixture.directory
            .appendingPathComponent("portrait-hevc.mp4")
        let expectedFrames = fixture.clip.frameCount(at: 24)

        let result = try await fixture.document.exportAnimationMP4(
            clipID: fixture.clip.id,
            to: destination,
            settings: options.exportSettings())

        // Receipt metadata agrees with the selection — NOT the defaults.
        XCTAssertEqual(result.width, 720)
        XCTAssertEqual(result.height, 1280)
        XCTAssertEqual(result.frameRate, 24, accuracy: 0.001)
        XCTAssertEqual(result.codec, "hevc")
        XCTAssertEqual(result.frameCount, expectedFrames)
        XCTAssertFalse(result.hasAudio)
        XCTAssertGreaterThan(result.byteCount, 1_024)
        XCTAssertEqual(result.url.standardizedFileURL, destination.standardizedFileURL)

        // Independent media read-back of the written file.
        let probe = try await Self.readVideo(destination)
        XCTAssertEqual(probe.width, 720)
        XCTAssertEqual(probe.height, 1280)
        XCTAssertGreaterThan(probe.height, probe.width, "portrait export must stay portrait")
        XCTAssertEqual(probe.frameRate, 24, accuracy: 1.0)
        XCTAssertEqual(probe.frameCount, expectedFrames, accuracy: 1)
        XCTAssertTrue(["hvc1", "hev1"].contains(probe.codecFourCC),
                      "expected HEVC, got \(probe.codecFourCC)")
        XCTAssertFalse(probe.hasAudio)
        XCTAssertGreaterThan(probe.byteCount, 1_024)
    }

    /// The untouched default path still produces the historical 1920x1080
    /// @30 H.264 video.
    func testDefaultSelectionStillProducesHistoricalOutput() async throws {
        let fixture = try await hostedFixture(clipDuration: 0.5)
        let destination = fixture.directory
            .appendingPathComponent("landscape-default.mp4")
        let expectedFrames = fixture.clip.frameCount(at: 30)

        let result = try await fixture.document.exportAnimationMP4(
            clipID: fixture.clip.id,
            to: destination,
            settings: CADAnimationExportOptions.default.exportSettings())

        XCTAssertEqual(result.width, 1920)
        XCTAssertEqual(result.height, 1080)
        XCTAssertEqual(result.frameCount, expectedFrames)

        let probe = try await Self.readVideo(destination)
        XCTAssertEqual(probe.width, 1920)
        XCTAssertEqual(probe.height, 1080)
        XCTAssertGreaterThan(probe.width, probe.height)
        XCTAssertEqual(probe.frameRate, 30, accuracy: 1.0)
        XCTAssertTrue(["avc1", "avc3"].contains(probe.codecFourCC),
                      "expected H.264, got \(probe.codecFourCC)")
        XCTAssertFalse(probe.hasAudio)
    }

    // MARK: Fixture (production Present host seam)

    private struct HostedFixture {
        var document: FloeCADDocument
        var clip: CADAnimationClip
        var directory: URL
        var hosting: UIHostingController<AnyView>
        var window: UIWindow
        var store: CADPresentationSceneStore
        var handle: CADPresentationHandle
    }

    private func hostedFixture(clipDuration: Double) async throws -> HostedFixture {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive
        }) else {
            throw XCTSkip("Export read-back requires the App-hosted UIKit target "
                          + "with a foreground window scene; hostless xctest has "
                          + "none and no video is fabricated.")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("X28ExportReadback-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        directories.append(directory)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("export-\(UUID().uuidString).floecad"),
            name: "X28 export read-back")
        documents.append(document)
        document.session.perform(AddBodyCommand(body: Self.fixtureBox(),
                                                title: "Add fixture box"))

        let clip = try document.createAnimationClip(name: "Orbit", duration: clipDuration)
        let track = try document.addAnimationTrack(clipID: clip.id, target: .camera)
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: 0,
            camera: CADAnimationCameraValue(target: SIMD3(0, 0, 0), distance: 80,
                                            azimuthRadians: 0, elevationRadians: 0.3,
                                            fovYDegrees: 60))
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: clipDuration,
            camera: CADAnimationCameraValue(target: SIMD3(0, 0, 0), distance: 120,
                                            azimuthRadians: 1.2, elevationRadians: 0.4,
                                            fovYDegrees: 60))

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

        // Only an active Present with a built stage may be exported; anything
        // else fails here, never falls back to a fake renderer.
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
            XCTFail("Present never became active with a built stage; "
                    + "no export was fabricated.")
            throw NSError(domain: "X28", code: 1)
        }
        try await Task.sleep(for: .milliseconds(800))
        return HostedFixture(document: document, clip: clip, directory: directory,
                             hosting: hosting, window: window, store: store,
                             handle: handle)
    }

    /// A small untextured box so the exported frames carry real scene pixels.
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
        var body = Body(id: BodyID(), name: "X28 export fixture",
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: indices),
                        revision: 1)
        body.material = BodyMaterialSpec(baseColor: SIMD4(0.75, 0.78, 0.85, 1),
                                         metallic: 0, roughness: 0.6)
        return body
    }

    // MARK: Independent media probe (AVFoundation, public API only)

    private struct VideoProbe {
        var width: Int
        var height: Int
        var frameRate: Double
        var frameCount: Int
        var codecFourCC: String
        var hasAudio: Bool
        var byteCount: Int64
    }

    private static func readVideo(_ url: URL) async throws -> VideoProbe {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(videoTracks.first, "exported MP4 must have a video track")
        let size = try await track.load(.naturalSize)
        let rate = try await track.load(.nominalFrameRate)
        let descriptions = try await track.load(.formatDescriptions)
        let fourCC = descriptions.first
            .map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        let codec = fourCCString(fourCC)
        let frames = max(1, Int((duration * Double(rate)).rounded()))
        return VideoProbe(width: Int(size.width.rounded()),
                          height: Int(size.height.rounded()),
                          frameRate: Double(rate),
                          frameCount: frames,
                          codecFourCC: codec,
                          hasAudio: !audioTracks.isEmpty,
                          byteCount: bytes)
    }

    private static func fourCCString(_ value: FourCharCode) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? "----"
    }
}

#endif
