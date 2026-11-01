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

        // Metadata alone accepted a video containing only the background
        // (native UI run113). Independently decode the real encoded frames:
        // the red fixture must be visible and the camera must actually move.
        let frames = try await Self.readPixels(destination)
        XCTAssertEqual(frames.count, expectedFrames)
        let first = try XCTUnwrap(frames.first)
        let last = try XCTUnwrap(frames.last)
        XCTAssertGreaterThan(Self.redFraction(first), 0.01,
                             "the first encoded frame must contain the actual model")
        XCTAssertGreaterThan(Self.redFraction(last), 0.01,
                             "the last encoded frame must contain the actual model")
        let changed = zip(first, last).filter { abs(Int($0) - Int($1)) > 20 }.count
        XCTAssertGreaterThan(Double(changed) / Double(first.count), 0.001,
                             "camera animation must change the encoded model pixels")
        for (name, bytes) in [("HEVC first actual frame", first),
                              ("HEVC last actual frame", last)] {
            var rgba = bytes
            let context = try XCTUnwrap(CGContext(
                data: &rgba, width: 720, height: 1280,
                bitsPerComponent: 8, bytesPerRow: 720 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try XCTUnwrap(context.makeImage())
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
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

    /// Run-11 regression: a debounced autosave still pending when the default
    /// export starts is settled BEFORE the exporter pins the committed
    /// identity — the identity then matches the rendered content and the video
    /// is written instead of discarded as stale (the unfixed code fails here
    /// with caught CADAnimationExportError.stale mid-render). The settle goes
    /// through the existing async save path: afterwards nothing is pending or
    /// dirty.
    func testDefaultExportSurvivesPendingAutosaveAtStart() async throws {
        let fixture = try await hostedFixture(
            clipDuration: 0.5, rescheduleAutosaveBeforeExport: true)
        XCTAssertTrue(fixture.document.session.hasPendingAutosaveForTesting,
                      "fixture must leave a real debounced autosave pending")
        let destination = fixture.directory
            .appendingPathComponent("landscape-default-settled.mp4")
        let expectedFrames = fixture.clip.frameCount(at: 30)

        let result = try await fixture.document.exportAnimationMP4(
            clipID: fixture.clip.id,
            to: destination,
            settings: CADAnimationExportOptions.default.exportSettings())

        XCTAssertEqual(result.width, 1920)
        XCTAssertEqual(result.height, 1080)
        XCTAssertEqual(result.frameCount, expectedFrames)
        XCTAssertFalse(fixture.document.session.hasPendingAutosaveForTesting)
        XCTAssertFalse(fixture.document.hasUnsavedChanges)

        let probe = try await Self.readVideo(destination)
        XCTAssertEqual(probe.width, 1920)
        XCTAssertEqual(probe.height, 1080)
        XCTAssertGreaterThan(probe.width, probe.height)
        XCTAssertEqual(probe.frameRate, 30, accuracy: 1.0)
        XCTAssertTrue(["avc1", "avc3"].contains(probe.codecFourCC),
                      "expected H.264, got \(probe.codecFourCC)")
        XCTAssertFalse(probe.hasAudio)
    }

    /// A real edit that lands while the exporter is settling an in-flight save
    /// must abort the FROZEN export (the clip value and its live generation
    /// were pinned by `startAnimationExportMP4`): nothing is promoted, no
    /// staging is left, and the edit's own debounced autosave stays owned by
    /// the normal lifecycle and commits later.
    func testExportAbortsWhenDocumentEditedWhileSettling() async throws {
        let fixture = try await hostedFixture(clipDuration: 2.0)
        let session = fixture.document.session
        // Let the fixture's own edits finish (state-based, deadline-bounded)
        // so the only save in flight below is the one this test holds.
        let idle = try await waitForAnimationTestState(timeout: 30) {
            !session.hasPendingAutosaveForTesting
                && session.inFlightSaveCountForTesting == 0
                && !fixture.document.hasUnsavedChanges
        }
        XCTAssertTrue(idle, "the fixture never reached an idle, written-out state")
        guard idle else { throw NSError(domain: "X28", code: 3) }

        let gate = AnimationSaveGate()
        defer { gate.release() }
        session.savePrewarmSuspensionForTesting = { @MainActor in
            await gate.suspend()
        }
        let heldSave = Task { @MainActor in await session.saveAsync() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered, "the in-flight save never reached prewarm")
        guard entered else { throw NSError(domain: "X28", code: 3) }

        let destination = fixture.directory
            .appendingPathComponent("edited-while-settling.mp4")
        let handle = try fixture.document.startAnimationExportMP4(
            clipID: fixture.clip.id,
            to: destination,
            settings: CADAnimationExportOptions.default.exportSettings())
        let waiting = try await waitForAnimationTestState(timeout: 30) {
            session.inFlightSaveWaiterCountForTesting == 1
        }
        XCTAssertTrue(waiting, "the exporter never waited for the in-flight save")
        guard waiting else {
            session.savePrewarmSuspensionForTesting = nil
            gate.release()
            _ = await heldSave.value
            throw NSError(domain: "X28", code: 4)
        }

        session.perform(AddBodyCommand(body: Self.fixtureBox(),
                                       title: "Edit while settling"))
        XCTAssertTrue(session.hasPendingAutosaveForTesting,
                      "the edit must keep its normal debounced autosave")

        session.savePrewarmSuspensionForTesting = nil
        gate.release()
        let status = await fixture.document.waitForAnimationExport(handle.id)
        _ = await heldSave.value

        XCTAssertFalse(gate.timedOut)
        XCTAssertEqual(status.progress.phase, .failed)
        XCTAssertEqual(status.error,
                       CADAnimationExportError.stale.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingRemains(in: fixture.directory, status: status)
        XCTAssertEqual(session.document.bodies.count, 2,
                       "the edit must survive the aborted export")

        let autosaved = try await waitForAnimationTestState(timeout: 30) {
            !session.hasPendingAutosaveForTesting
                && !fixture.document.hasUnsavedChanges
        }
        XCTAssertTrue(autosaved, "the edit's autosave never completed")
        XCTAssertEqual(session.document.bodies.count, 2)
    }

    /// A REAL edit after the render pin must still abort: the next frame check
    /// discards the video as stale, the staging directory is removed and
    /// nothing is promoted over the newer document.
    func testExportAbortsWithStaleWhenDocumentEditedDuringRender() async throws {
        let fixture = try await hostedFixture(clipDuration: 2.0)
        let destination = fixture.directory
            .appendingPathComponent("edited-during-render.mp4")

        let handle = try fixture.document.startAnimationExportMP4(
            clipID: fixture.clip.id,
            to: destination,
            settings: CADAnimationExportOptions.default.exportSettings())
        try await waitUntilExportRenders(fixture.document, handle: handle)

        fixture.document.session.perform(
            AddBodyCommand(body: Self.fixtureBox(), title: "Edit during export"))

        let status = await fixture.document.waitForAnimationExport(handle.id)
        XCTAssertEqual(status.progress.phase, .failed)
        XCTAssertEqual(status.error,
                       CADAnimationExportError.stale.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingRemains(in: fixture.directory, status: status)
    }

    /// Cancellation through the service removes the staging directory and
    /// promotes nothing.
    func testExportCancelRemovesStagingAndPromotesNothing() async throws {
        let fixture = try await hostedFixture(clipDuration: 2.0)
        let destination = fixture.directory
            .appendingPathComponent("cancelled.mp4")

        let handle = try fixture.document.startAnimationExportMP4(
            clipID: fixture.clip.id,
            to: destination,
            settings: CADAnimationExportOptions.default.exportSettings())
        try await waitUntilExportRenders(fixture.document, handle: handle)

        fixture.document.cancelAnimationExport(handle.id)

        let status = await fixture.document.waitForAnimationExport(handle.id)
        XCTAssertTrue(status.isCancelled)
        XCTAssertEqual(status.progress.phase, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingRemains(in: fixture.directory, status: status)
    }

    /// Closing the document aborts the service-owned export job, removes the
    /// staging directory and promotes nothing.
    func testExportCloseRemovesStagingAndPromotesNothing() async throws {
        let fixture = try await hostedFixture(clipDuration: 2.0)
        let destination = fixture.directory
            .appendingPathComponent("closed-during-render.mp4")

        let handle = try fixture.document.startAnimationExportMP4(
            clipID: fixture.clip.id,
            to: destination,
            settings: CADAnimationExportOptions.default.exportSettings())
        try await waitUntilExportRenders(fixture.document, handle: handle)

        fixture.document.close()

        let status = await fixture.document.waitForAnimationExport(handle.id)
        XCTAssertTrue(status.isCancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingRemains(in: fixture.directory, status: status)
    }

    // MARK: Mid-render helpers

    /// Wait until the export job has rendered at least one frame — its
    /// identity/render-generation pin is then established — so a subsequent
    /// edit/cancel/close exercises the real mid-render fences.
    private func waitUntilExportRenders(
        _ document: FloeCADDocument,
        handle: CADAnimationExportHandle
    ) async throws {
        let rendered = try await waitForAnimationTestState(timeout: 60) {
            guard let status = document.animationExportStatus(handle.id) else {
                return false
            }
            return status.progress.completedFrames >= 1
        }
        guard rendered else {
            XCTFail("Export never reached the render phase; "
                    + "the mid-render fence was not exercised.")
            throw NSError(domain: "X28", code: 2)
        }
    }

    /// The exporter stages beside the destination and must remove that
    /// directory on failure/cancel — never leave a partial video tree behind.
    /// A failure message names the actual leftovers and the terminal status so
    /// a run can be reviewed without guessing which phase leaked.
    private func assertNoStagingRemains(
        in directory: URL,
        status: CADAnimationExportStatus? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: directory.path)
        let leftovers = names
            .filter { $0.hasPrefix(".") && $0.contains(".export-") }
            .sorted()
        let phase = status?.progress.phase.rawValue ?? "nil"
        let error = status?.error ?? "nil"
        XCTAssertTrue(
            leftovers.isEmpty,
            "staging directory must be removed on failure/cancel; "
                + "leftovers=\(leftovers) terminalPhase=\(phase) terminalError=\(error)",
            file: file, line: line)
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

    /// - Parameter rescheduleAutosaveBeforeExport: when true, the fixture
    ///   performs one trailing clip edit before returning WITHOUT awaiting the
    ///   debounce, deterministically leaving a real pending autosave for the
    ///   caller's export start (the run-11 precondition).
    private func hostedFixture(
        clipDuration: Double,
        rescheduleAutosaveBeforeExport: Bool = false
    ) async throws -> HostedFixture {
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
            camera: CADAnimationCameraValue(target: SIMD3(0, 0, 0), distance: 0.08,
                                            azimuthRadians: 0, elevationRadians: 0.3,
                                            fovYDegrees: 60))
        _ = try document.setAnimationKeyframe(
            clipID: clip.id, trackID: track.id, time: clipDuration,
            camera: CADAnimationCameraValue(target: SIMD3(0, 0, 0), distance: 0.12,
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
                    + "no export was fabricated.")
            throw NSError(domain: "X28", code: 1)
        }
        try await Task.sleep(for: .milliseconds(800))
        if rescheduleAutosaveBeforeExport {
            // A trailing clip edit reschedules the 2s debounce without
            // awaiting it, so the caller starts the export while a real
            // autosave of the just-edited content is still pending.
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, time: clipDuration / 2,
                camera: CADAnimationCameraValue(target: SIMD3(0, 0, 0), distance: 0.1,
                                                azimuthRadians: 0.6,
                                                elevationRadians: 0.35,
                                                fovYDegrees: 60))
        }
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
        body.material = BodyMaterialSpec(baseColor: SIMD4(0.85, 0.05, 0.02, 1),
                                         metallic: 0, roughness: 0.6,
                                         emissive: SIMD3(0.9, 0.03, 0.01),
                                         emissiveStrength: 0.5)
        return body
    }

    // MARK: Independent media probe (AVFoundation, public API only)

    private static func readPixels(_ url: URL) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames: [[UInt8]] = []
        while let sample = output.copyNextSampleBuffer() {
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(pixel), 720)
            XCTAssertEqual(CVPixelBufferGetHeight(pixel), 1280)
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            let source = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
                .assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            var rgba = [UInt8](repeating: 0, count: 720 * 1280 * 4)
            for y in 0..<1280 {
                for x in 0..<720 {
                    let from = y * stride + x * 4
                    let to = (y * 720 + x) * 4
                    rgba[to] = source[from + 2]
                    rgba[to + 1] = source[from + 1]
                    rgba[to + 2] = source[from]
                    rgba[to + 3] = 255
                }
            }
            frames.append(rgba)
            guard frames.count <= 12 else {
                reader.cancelReading()
                XCTFail("the half-second 24fps witness contains unexpected extra frames")
                return frames
            }
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "decode failed")
        return frames
    }

    private static func redFraction(_ rgba: [UInt8]) -> Double {
        var red = 0
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let r = Int(rgba[offset]), g = Int(rgba[offset + 1]), b = Int(rgba[offset + 2])
            if r > 80, r > g * 2, r > b * 2 { red += 1 }
        }
        return Double(red) / Double(rgba.count / 4)
    }

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

// MARK: - Export-start save settle (deterministic interleave, real services)

/// The production export pins the COMMITTED identity (`revision`,
/// `liveChangeCount`, `contentSHA256`) and re-checks it every frame. A
/// debounced autosave of the same live content advancing the committed
/// identity mid-render tripped the stale fence (run-11). These tests pin the
/// `DocumentSession.settleSaveStateBeforeIdentityPin(expectingChangeCount:)`
/// contract through the REAL session save lifecycle — race order comes from the
/// DEBUG prewarm suspension on the actual save path, never from sleep/yield
/// guesses.
@MainActor
final class CADAnimationExportSaveSettleTests: XCTestCase {
    private var directory: URL?
    private var documents: [FloeCADDocument] = []

    override func tearDown() async throws {
        for document in documents {
            document.session.savePrewarmSuspensionForTesting = nil
            document.close()
        }
        documents = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("X28SaveSettle-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: base,
                                                withIntermediateDirectories: true)
        directory = base
        let document = try await FloeCADDocument.create(
            at: base.appendingPathComponent("\(name)-\(UUID().uuidString).floecad"),
            name: name)
        documents.append(document)
        return document
    }

    /// Bounded state wait on the REAL committed identity — never a fixed
    /// duration guess. Checks cancellation and throws on its own deadline so a
    /// broken wait can never hang the canonical Simulator run.
    private func waitFor(
        _ condition: @MainActor () -> Bool,
        _ message: String,
        timeout: TimeInterval = 30,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let matched = try await waitForAnimationTestState(
            timeout: timeout, condition)
        guard matched else {
            XCTFail(message, file: file, line: line)
            throw AnimationSettleTimeout()
        }
    }

    /// A small untextured box (same shape family as the read-back fixture).
    private static func box(_ name: String) -> Body {
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
        var body = Body(id: BodyID(), name: name,
                        transform: .identity, primitive: nil,
                        render: RenderMesh(positions: positions, normals: normals,
                                           indices: indices),
                        revision: 1)
        body.material = BodyMaterialSpec(baseColor: SIMD4(0.75, 0.78, 0.85, 1),
                                         metallic: 0, roughness: 0.6)
        return body
    }

    /// Pending debounced autosave → the settle commits it through the existing
    /// ASYNC save path (never the synchronous main-actor save); the committed
    /// identity then matches the live content, no save is left pending and the
    /// document is clean (the run-11 precondition, neutralized).
    func testSettleFlushesPendingAutosaveBeforeIdentityPin() async throws {
        let document = try await makeDocument("Pending")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"),
                                       title: "First"))
        XCTAssertTrue(session.hasPendingAutosaveForTesting)
        XCTAssertTrue(document.hasUnsavedChanges)
        let pinnedBefore = document.revision

        let result = try await session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)

        XCTAssertEqual(result, .ready)
        XCTAssertFalse(session.hasPendingAutosaveForTesting)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertEqual(document.revision, pinnedBefore + 1)
        XCTAssertEqual(session.document.bodies.count, 1)
    }

    /// Clean document → the settle is a no-op: no revision bump and no save
    /// scheduled. Ordinary exports of an unchanged document observe a stable
    /// identity without extra commits.
    func testSettleWithNothingPendingLeavesIdentityUnchanged() async throws {
        let document = try await makeDocument("Clean")
        let session = document.session
        let revision = document.revision

        let result = try await session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)

        XCTAssertEqual(result, .ready)
        XCTAssertEqual(document.revision, revision)
        XCTAssertFalse(session.hasPendingAutosaveForTesting)
        XCTAssertFalse(document.hasUnsavedChanges)
    }

    /// The caller's frozen generation is authoritative: a mismatch must abort
    /// before ANY save, leaving the real pending autosave normally owned.
    func testSettleRejectsAStaleExpectedGenerationWithoutCommitting() async throws {
        let document = try await makeDocument("StaleGeneration")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"), title: "First"))
        let revision = document.revision

        let result = try await session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount - 1)

        XCTAssertEqual(result, .sourceChanged)
        XCTAssertEqual(document.revision, revision,
                       "a stale generation must not trigger a commit")
        XCTAssertTrue(session.hasPendingAutosaveForTesting,
                      "the edit keeps its normal autosave")
        XCTAssertTrue(document.hasUnsavedChanges)
    }

    /// (a) An UNCHANGED save already in flight is waited out asynchronously;
    /// the settle then reports ready without issuing an extra clean commit.
    func testSettleWaitsForUnchangedInFlightSaveWithoutExtraCommit() async throws {
        let document = try await makeDocument("InFlightUnchanged")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"), title: "First"))
        // Let the edit's own debounce finish first: the held save below is
        // then a save of UNCHANGED content, exactly the run-11 autosave class.
        let idle = try await waitForAnimationTestState(timeout: 30) {
            !session.hasPendingAutosaveForTesting
                && session.inFlightSaveCountForTesting == 0
                && !document.hasUnsavedChanges
        }
        XCTAssertTrue(idle, "the edit's autosave never settled before the held save")
        guard idle else { return }
        let baseRevision = document.revision
        let expected = document.liveChangeCount

        let gate = AnimationSaveGate()
        defer { gate.release() }
        session.savePrewarmSuspensionForTesting = { @MainActor in
            await gate.suspend()
        }
        let save = Task { @MainActor in await session.saveAsync() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered, "the in-flight save never reached prewarm")
        guard entered else { return }

        let completion = SettleCompletion()
        _ = Task { @MainActor in
            do {
                completion.result = .success(
                    try await session.settleSaveStateBeforeIdentityPin(
                        expectingChangeCount: expected))
            } catch {
                completion.result = .failure(error)
            }
            completion.finished = true
        }
        try await waitFor({ session.inFlightSaveWaiterCountForTesting == 1 },
                          "the settle never waited for the in-flight save",
                          timeout: 10)
        session.savePrewarmSuspensionForTesting = nil
        gate.release()

        let outcome = try await waitForSettleCompletion(completion)
        _ = await save.value

        guard let outcome else { return }
        switch outcome {
        case .success(let result):
            XCTAssertEqual(result, .ready)
        case .failure(let error):
            XCTFail("the settle failed instead of reporting ready: \(error)")
        }
        XCTAssertFalse(gate.timedOut)
        XCTAssertEqual(document.revision, baseRevision + 1,
                       "only the pre-existing save may commit; the settle must not add a clean commit")
        XCTAssertFalse(session.hasPendingAutosaveForTesting)
        XCTAssertFalse(document.hasUnsavedChanges)
    }

    /// (b) A REAL edit while the settle waits for a held save must return
    /// `.sourceChanged` (the caller aborts the frozen export), never "wait for
    /// the newer edit and continue the old export". The edit keeps its own
    /// debounced autosave and survives/commits through the normal lifecycle.
    func testSettleReportsSourceChangedWhenAnEditLandsWhileWaiting() async throws {
        let document = try await makeDocument("EditWhileWaiting")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"), title: "First"))
        let idle = try await waitForAnimationTestState(timeout: 30) {
            !session.hasPendingAutosaveForTesting
                && session.inFlightSaveCountForTesting == 0
                && !document.hasUnsavedChanges
        }
        XCTAssertTrue(idle, "the first edit's autosave never settled")
        guard idle else { return }
        let expected = document.liveChangeCount

        let gate = AnimationSaveGate()
        defer { gate.release() }
        session.savePrewarmSuspensionForTesting = { @MainActor in
            await gate.suspend()
        }
        let save = Task { @MainActor in await session.saveAsync() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered, "the in-flight save never reached prewarm")
        guard entered else { return }

        let completion = SettleCompletion()
        _ = Task { @MainActor in
            do {
                completion.result = .success(
                    try await session.settleSaveStateBeforeIdentityPin(
                        expectingChangeCount: expected))
            } catch {
                completion.result = .failure(error)
            }
            completion.finished = true
        }
        try await waitFor({ session.inFlightSaveWaiterCountForTesting == 1 },
                          "the settle never waited for the in-flight save",
                          timeout: 10)

        session.perform(AddBodyCommand(body: Self.box("two"), title: "Second"))
        XCTAssertTrue(session.hasPendingAutosaveForTesting,
                      "the edit keeps its own debounced autosave")

        let outcome = try await waitForSettleCompletion(completion, timeout: 5)
        XCTAssertGreaterThan(session.inFlightSaveCountForTesting, 0,
                             "source invalidation must return while the save is still held")
        session.savePrewarmSuspensionForTesting = nil
        gate.release()
        _ = await save.value

        guard let outcome else { return }
        switch outcome {
        case .success(let result):
            XCTAssertEqual(result, .sourceChanged)
        case .failure(let error):
            XCTFail("the settle failed instead of reporting a source change: \(error)")
        }
        XCTAssertEqual(session.document.bodies.count, 2,
                       "the edit must survive the aborted preparation")
        let autosaved = try await waitForAnimationTestState(timeout: 30) {
            !session.hasPendingAutosaveForTesting
                && !document.hasUnsavedChanges
        }
        XCTAssertTrue(autosaved, "the newer autosave never completed")
        XCTAssertEqual(session.document.bodies.count, 2)
    }

    /// (b2) The same source-change contract when the edit lands during the
    /// settle's OWN async commit (payload built after prewarm): no ready
    /// report, the frozen generation fails, and the edit keeps its autosave.
    func testSettleReportsSourceChangedWhenAnEditLandsDuringItsSave() async throws {
        let document = try await makeDocument("EditDuringCommit")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"), title: "First"))
        let expected = document.liveChangeCount

        let gate = AnimationSaveGate()
        defer { gate.release() }
        session.savePrewarmSuspensionForTesting = { @MainActor in
            await gate.suspend()
        }
        let completion = SettleCompletion()
        _ = Task { @MainActor in
            do {
                completion.result = .success(
                    try await session.settleSaveStateBeforeIdentityPin(
                        expectingChangeCount: expected))
            } catch {
                completion.result = .failure(error)
            }
            completion.finished = true
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered, "the settle's own save never reached prewarm")
        guard entered else { return }

        session.perform(AddBodyCommand(body: Self.box("two"), title: "Second"))
        XCTAssertTrue(session.hasPendingAutosaveForTesting,
                      "the edit keeps its own debounced autosave")

        let outcome = try await waitForSettleCompletion(completion, timeout: 5)
        XCTAssertGreaterThan(session.inFlightSaveCountForTesting, 0,
                             "the frozen export must abort before its own save finishes")
        session.savePrewarmSuspensionForTesting = nil
        gate.release()

        guard let outcome else { return }
        switch outcome {
        case .success(let result):
            XCTAssertEqual(result, .sourceChanged)
        case .failure(let error):
            XCTFail("the settle failed instead of reporting a source change: \(error)")
        }
        XCTAssertEqual(session.document.bodies.count, 2)
        let autosaved = try await waitForAnimationTestState(timeout: 30) {
            !session.hasPendingAutosaveForTesting
                && !document.hasUnsavedChanges
        }
        XCTAssertTrue(autosaved, "the newer autosave never completed")
        XCTAssertEqual(session.document.bodies.count, 2)
    }

    /// (c) Cancellation while waiting for a HELD in-flight save returns
    /// promptly and does not cancel that independent durability work.
    func testCancellingSettleWaitDoesNotCancelHeldSave() async throws {
        let document = try await makeDocument("CancelWait")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"), title: "First"))
        let idle = try await waitForAnimationTestState(timeout: 30) {
            !session.hasPendingAutosaveForTesting
                && session.inFlightSaveCountForTesting == 0
                && !document.hasUnsavedChanges
        }
        XCTAssertTrue(idle, "the edit's autosave never settled")
        guard idle else { return }
        let baseRevision = document.revision
        let expected = document.liveChangeCount

        let gate = AnimationSaveGate()
        defer { gate.release() }
        session.savePrewarmSuspensionForTesting = { @MainActor in
            await gate.suspend()
        }
        let save = Task { @MainActor in await session.saveAsync() }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered, "the in-flight save never reached prewarm")
        guard entered else { return }

        let completion = SettleCompletion()
        let cancelledSettle = Task { @MainActor in
            do {
                completion.result = .success(
                    try await session.settleSaveStateBeforeIdentityPin(
                        expectingChangeCount: expected))
            } catch {
                completion.result = .failure(error)
            }
            completion.finished = true
        }
        try await waitFor({ session.inFlightSaveWaiterCountForTesting == 1 },
                          "the settle never waited for the in-flight save",
                          timeout: 10)

        cancelledSettle.cancel()
        let outcome = try await waitForSettleCompletion(completion, timeout: 5)
        XCTAssertFalse(save.isCancelled,
                       "cancelling the export wait must not cancel durability work")
        XCTAssertEqual(session.inFlightSaveWaiterCountForTesting, 0)
        XCTAssertEqual(document.revision, baseRevision,
                       "the held save must still be in flight")
        guard let outcome else {
            gate.release()
            return
        }
        switch outcome {
        case .failure(let error):
            XCTAssertTrue(error is CancellationError,
                          "expected CancellationError, got \(error)")
        case .success(let result):
            XCTFail("a cancelled settle must not report \(result)")
        }

        session.savePrewarmSuspensionForTesting = nil
        gate.release()
        let error = await save.value
        XCTAssertNil(error)
        XCTAssertEqual(document.revision, baseRevision + 1)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertFalse(gate.timedOut)
    }

    /// A save refusal is surfaced with its ACTUAL error; the settle never
    /// claims ready over undurable state and never retries forever.
    func testSettleSurfacesTheActualSaveFailure() async throws {
        let document = try await makeDocument("SaveFailure")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"), title: "First"))
        session.saveFailureForTesting = "Injected settle save failure"

        let result = try await session.settleSaveStateBeforeIdentityPin(
            expectingChangeCount: document.liveChangeCount)

        XCTAssertEqual(result, .saveFailed("Injected settle save failure"))
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertFalse(session.hasPendingAutosaveForTesting)
    }

    func testCancellingPreparationDuringItsOwnSaveKeepsDurabilityRunning() async throws {
        let document = try await makeDocument("CancelOwnSave")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"), title: "First"))
        let expected = document.liveChangeCount
        let baseRevision = document.revision
        let gate = AnimationSaveGate()
        defer { gate.release() }
        session.savePrewarmSuspensionForTesting = { @MainActor in await gate.suspend() }
        let completion = SettleCompletion()
        let preparation = Task { @MainActor in
            do {
                completion.result = .success(try await session.settleSaveStateBeforeIdentityPin(
                    expectingChangeCount: expected))
            } catch {
                completion.result = .failure(error)
            }
            completion.finished = true
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { return }
        XCTAssertEqual(session.identitySaveWaiterCountForTesting, 1)
        preparation.cancel()
        let result = try await waitForSettleCompletion(completion, timeout: 5)
        guard case .failure(let error)? = result else {
            XCTFail("cancelled preparation must stop waiting before the save is released")
            return
        }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(session.identitySaveWaiterCountForTesting, 0)
        XCTAssertGreaterThan(session.inFlightSaveCountForTesting, 0)
        XCTAssertEqual(document.revision, baseRevision)
        session.savePrewarmSuspensionForTesting = nil
        gate.release()
        try await waitFor({ session.inFlightSaveCountForTesting == 0 && !document.hasUnsavedChanges },
                          "the independent durability task did not finish")
        XCTAssertEqual(document.revision, baseRevision + 1)
        XCTAssertEqual(session.document.bodies.count, 1)
        XCTAssertFalse(gate.timedOut)
    }

    func testConcurrentPreparationsShareOneNecessaryCommit() async throws {
        let document = try await makeDocument("ConcurrentPreparations")
        let session = document.session
        session.perform(AddBodyCommand(body: Self.box("one"), title: "First"))
        let expected = document.liveChangeCount
        let baseRevision = document.revision
        let gate = AnimationSaveGate()
        defer { gate.release() }
        session.savePrewarmSuspensionForTesting = { @MainActor in await gate.suspend() }
        let first = Task { @MainActor in
            try await session.settleSaveStateBeforeIdentityPin(expectingChangeCount: expected)
        }
        let entered = await gate.waitUntilEntered()
        XCTAssertTrue(entered)
        guard entered else { return }
        let second = Task { @MainActor in
            try await session.settleSaveStateBeforeIdentityPin(expectingChangeCount: expected)
        }
        try await waitFor({ session.inFlightSaveWaiterCountForTesting == 1 },
                          "the second observer did not wait for the reserved writer")
        XCTAssertEqual(session.identitySaveWaiterCountForTesting, 1)
        session.savePrewarmSuspensionForTesting = nil
        gate.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        XCTAssertEqual(firstResult, .ready)
        XCTAssertEqual(secondResult, .ready)
        XCTAssertEqual(document.revision, baseRevision + 1)
        XCTAssertFalse(document.hasUnsavedChanges)
        XCTAssertFalse(gate.timedOut)
    }

    /// Deadline-bounded observation of the detached settle task.
    private func waitForSettleCompletion(
        _ completion: SettleCompletion,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Result<AnimationIdentitySettleResult, Error>? {
        let finished = try await waitForAnimationTestState(timeout: timeout) {
            completion.finished
        }
        guard finished else {
            XCTFail("the settle did not finish before the test deadline",
                    file: file, line: line)
            return nil
        }
        return completion.result
    }
}

// MARK: - Race-test helpers (real services only)

/// State-based wait shared by the App-hosted race tests. It checks
/// cancellation and has an explicit deadline so a broken wait fails the test
/// instead of hanging the canonical Simulator run.
@MainActor
private func waitForAnimationTestState(
    timeout: TimeInterval = 30,
    _ condition: @MainActor () -> Bool
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        try Task.checkCancellation()
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return false
}

/// Result box for a detached settle task, written/read only on the main actor.
@MainActor
private final class SettleCompletion {
    var finished = false
    var result: Result<AnimationIdentitySettleResult, Error>?
}

private struct AnimationSettleTimeout: Error {}

/// Deterministic suspension on the REAL save prewarm path. Ordering is driven
/// by the explicit entry/release events; the watchdog only prevents a buggy
/// wait from hanging the test run and always records `timedOut`.
@MainActor
private final class AnimationSaveGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Bool, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var timedOut = false

    func suspend() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume(returning: true) }
        if released { return }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, !self.released else { return }
            self.timedOut = true
            self.release()
        }
        await withCheckedContinuation { releaseWaiters.append($0) }
        watchdog.cancel()
    }

    func waitUntilEntered(timeout: TimeInterval = 20) async -> Bool {
        if entered { return true }
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, let self, !self.entered else { return }
            self.timedOut = true
            let waiters = self.enteredWaiters
            self.enteredWaiters.removeAll()
            waiters.forEach { $0.resume(returning: false) }
            self.release()
        }
        let result = await withCheckedContinuation { enteredWaiters.append($0) }
        watchdog.cancel()
        return result
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

#endif
