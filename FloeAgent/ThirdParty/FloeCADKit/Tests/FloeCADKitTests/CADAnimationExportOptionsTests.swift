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

import Dispatch
import Foundation
import XCTest

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import SwiftUI
import RealityKit
import UIKit
import AVFoundation
import UniformTypeIdentifiers
import CryptoKit
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

    func testFrameSequenceMapsToPngSettingsWithoutVideoOnlyOptions() {
        var options = CADAnimationExportOptions.default
        options.orientation = .portrait
        options.resolution = .p720
        options.frameRate = .fps24
        options.codec = .hevc
        options.quality = .higher
        options.format = .pngSequence
        let settings = options.exportSettings()
        XCTAssertEqual(settings.format, .pngSequence)
        XCTAssertEqual(settings.width, 720)
        XCTAssertEqual(settings.height, 1280)
        XCTAssertEqual(settings.frameRate, 24)
        XCTAssertNil(settings.bitrate, "PNG frames are lossless and have no video bitrate")
        XCTAssertEqual(settings.alpha, .opaque)
        XCTAssertNil(settings.validationError)

        // The historical video selection still carries its exact settings.
        options.format = .mp4
        let video = options.exportSettings()
        XCTAssertEqual(video.format, .mp4)
        XCTAssertEqual(video.codec, .hevc)
        XCTAssertNotNil(video.bitrate)
    }

    func testTransparentAlphaAndFrameDestinationAreValidatedBeforeOutput() throws {
        var settings = CADAnimationExportOptions.default.exportSettings()
        settings.alpha = .transparent
        XCTAssertNotNil(settings.validationError)
        XCTAssertThrowsError(try settings.validated()) { error in
            guard let exportError = error as? CADAnimationExportError,
                  case .invalidSettings(let message) = exportError else {
                return XCTFail("expected invalidSettings, got \(error)")
            }
            XCTAssertTrue(message.contains("Transparent"))
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("X29Destination-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var frames = CADAnimationExportOptions.default.exportSettings()
        frames.alpha = .opaque
        frames.format = .pngSequence
        frames.bitrate = nil
        XCTAssertNoThrow(try FloeCADDocument.validateAnimationExportDestination(
            directory.appendingPathComponent("frames.zip"), settings: frames))
        XCTAssertThrowsError(try FloeCADDocument.validateAnimationExportDestination(
            directory.appendingPathComponent("frames.mp4"), settings: frames))

        var video = CADAnimationExportOptions.default.exportSettings()
        video.format = .mp4
        XCTAssertNoThrow(try FloeCADDocument.validateAnimationExportDestination(
            directory.appendingPathComponent("video.mp4"), settings: video))
        XCTAssertThrowsError(try FloeCADDocument.validateAnimationExportDestination(
            directory.appendingPathComponent("video.zip"), settings: video))
    }

    func testRecoveryOptionsDecodeLegacyRecordsAndPreserveFrameIntent() throws {
        let legacy = Data("""
            {"orientation":"portrait","resolution":720,"frameRate":24,
             "codec":"hevc","quality":"higher","width":720,"height":1280,
             "bitrate":8000000,"overwrite":false,"posterEnabled":true}
            """.utf8)
        let decoded = try JSONDecoder().decode(
            CADAnimationExportRecoveryOptions.self, from: legacy)
        XCTAssertEqual(decoded.format, "mp4")
        XCTAssertEqual(decoded.alpha, "opaque")
        let restored = try XCTUnwrap(
            CADAnimationExportOptions(recoveryOptions: decoded))
        XCTAssertEqual(restored.format, .mp4)
        XCTAssertEqual(restored.alpha, .opaque)

        var frames = CADAnimationExportOptions.default
        frames.format = .pngSequence
        frames.frameRate = .fps24
        let roundTrip = try XCTUnwrap(CADAnimationExportOptions(
            recoveryOptions: frames.recoveryOptions))
        XCTAssertEqual(roundTrip, frames)
        XCTAssertEqual(roundTrip.recoveryOptions.format, "png_zip")
        XCTAssertEqual(roundTrip.recoveryOptions.alpha, "opaque")
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

    func testFrameOutputPreferenceRoundTripsAdditively() throws {
        let suite = "floe.cad.animationExportOptions.frames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var frames = CADAnimationExportOptions.default
        frames.format = .pngSequence
        frames.frameRate = .fps24
        frames.save(to: defaults)
        XCTAssertEqual(CADAnimationExportOptions.load(from: defaults), frames)

        // A payload written before X29 has no output fields and stays the
        // historical opaque MP4 instead of failing or inventing a format.
        let legacy = Data("""
            {"orientation":"portrait","codec":"hevc","frameRate":24}
            """.utf8)
        defaults.set(legacy, forKey: "floe.cad.animationExportOptions")
        let loaded = CADAnimationExportOptions.load(from: defaults)
        XCTAssertEqual(loaded.format, .mp4)
        XCTAssertEqual(loaded.alpha, .opaque)
    }
}

// MARK: - Writer readiness (deterministic; no encoder required)

/// The MP4 readiness rule must distinguish a terminal writer from a merely
/// busy one. These tests never create a video encoder; the real-writer probe
/// at the end only proves AVFoundation reports a cancelled writer as
/// terminal. They are the regression for native 146, where a writer that had
/// already stopped looked like an encoder that was "busy" for 10 s.
@MainActor
final class CADAnimationWriterReadinessTests: XCTestCase {
    private func snapshot(
        _ status: AVAssetWriter.Status,
        ready: Bool,
        error: NSError? = nil
    ) -> CADAnimationWriterReadinessSnapshot {
        CADAnimationWriterReadinessSnapshot(
            status: status,
            errorDomain: error?.domain,
            errorCode: error?.code,
            errorDescription: error?.localizedDescription,
            isReadyForMoreMediaData: ready)
    }

    func testFailedWriterStopsWithTheActualEncoderErrorBeforeTheBusyCeiling() {
        let encoderError = NSError(
            domain: "AVFoundationErrorDomain", code: -11800,
            userInfo: [NSLocalizedDescriptionKey: "The encoder failed."])
        let state = snapshot(.failed, ready: false, error: encoderError)
        let decision = CADAnimationWriterReadinessPolicy.decide(
            state, frameIndex: 4, waits: 0)
        guard case .stop(let message) = decision else {
            return XCTFail("a failed writer must stop the wait, got \(decision)")
        }
        XCTAssertTrue(message.contains("frame 5"))
        XCTAssertTrue(message.contains("The encoder failed"))
        XCTAssertFalse(message.contains("stayed busy"),
                       "a terminal writer must not be reported as busy")
        // The code is diagnostic, not user copy; the DEBUG observation keeps it.
        XCTAssertTrue(state.errorSummary.contains("AVFoundationErrorDomain -11800"))
        let observation = CADAnimationWriterReadinessPolicy.observation(
            state, frameIndex: 4, waits: 0, elapsedMilliseconds: 7)
        XCTAssertTrue(observation.contains("status=failed"))
        XCTAssertTrue(observation.contains("AVFoundationErrorDomain -11800"))
    }

    func testReadyWriterProceedsOnlyWhileStillWriting() {
        XCTAssertEqual(
            CADAnimationWriterReadinessPolicy.decide(
                snapshot(.writing, ready: true),
                frameIndex: 0, waits: 5_000),
            .proceed)
        XCTAssertEqual(
            CADAnimationWriterReadinessPolicy.decide(
                snapshot(.writing, ready: false),
                frameIndex: 3, waits: 1),
            .wait)
    }

    func testCancelledCompletedAndUnknownWritersAreTerminal() {
        let cancelled = CADAnimationWriterReadinessPolicy.decide(
            snapshot(.cancelled, ready: true), frameIndex: 1, waits: 0)
        guard case .stop(let cancelledMessage) = cancelled else {
            return XCTFail("cancelled writer must stop, got \(cancelled)")
        }
        XCTAssertTrue(cancelledMessage.contains("cancelled"))
        XCTAssertTrue(cancelledMessage.contains("frame 2"))

        let completed = CADAnimationWriterReadinessPolicy.decide(
            snapshot(.completed, ready: true), frameIndex: 2, waits: 0)
        guard case .stop(let completedMessage) = completed else {
            return XCTFail("completed writer must stop, got \(completed)")
        }
        XCTAssertTrue(completedMessage.contains("finished"))

        let unknown = CADAnimationWriterReadinessPolicy.decide(
            snapshot(.unknown, ready: true), frameIndex: 0, waits: 0)
        guard case .stop = unknown else {
            return XCTFail("an unstarted writer must not be treated as ready")
        }
    }

    func testBusyCeilingKeepsTheExistingBudgetAndNamesTheFrameState() {
        XCTAssertEqual(CADAnimationWriterReadinessPolicy.maximumWaits, 5_000)
        XCTAssertEqual(
            CADAnimationWriterReadinessPolicy.decide(
                snapshot(.writing, ready: false),
                frameIndex: 11, waits: 4_999),
            .wait,
            "the existing 10 s budget must not be increased or shortened")
        let busy = snapshot(.writing, ready: false)
        let decision = CADAnimationWriterReadinessPolicy.decide(
            busy, frameIndex: 11, waits: 5_000)
        guard case .stop(let message) = decision else {
            return XCTFail("the busy ceiling must stop, got \(decision)")
        }
        XCTAssertEqual(
            message,
            "The video encoder stayed busy for too long while writing frame 12.",
            "visible copy stays concise and names the frame")
        let observation = CADAnimationWriterReadinessPolicy.observation(
            busy, frameIndex: 11, waits: 5_000,
            elapsedMilliseconds: 10_007)
        XCTAssertTrue(observation.contains("frame=12"))
        XCTAssertTrue(observation.contains("waits=5000"))
        XCTAssertTrue(observation.contains("elapsedMs=10007"))
        XCTAssertTrue(observation.contains("status=writing"))
        XCTAssertTrue(observation.contains("ready=false"))
        XCTAssertTrue(observation.contains("error=none"))
    }

    func testErrorSummaryStaysSingleLineAndBounded() {
        let long = "first line\nsecond line "
            + String(repeating: "x", count: 300)
        let summary = CADAnimationWriterReadinessPolicy.errorSummary(
            domain: "AVFoundationErrorDomain", code: -11800, description: long)
        XCTAssertFalse(summary.contains("\n"))
        XCTAssertTrue(summary.hasPrefix("AVFoundationErrorDomain -11800: "))
        XCTAssertLessThanOrEqual(summary.count, 200)
        XCTAssertTrue(summary.hasSuffix("..."))
    }

    func testStatusFailureKeepsItsRealClassification() {
        let progress = CADAnimationExportProgress(
            phase: .failed, totalFrames: 12)
        let writerFailure = CADAnimationExportError.writer(
            "The video encoder failed before writing frame 12.")
        let writerStatus = CADAnimationExportStatus(
            id: UUID(), progress: progress,
            error: writerFailure.localizedDescription, failure: writerFailure)
        guard case .writer = writerStatus.failureError else {
            return XCTFail(
                "writer failure collapsed into \(writerStatus.failureError)")
        }
        let staleStatus = CADAnimationExportStatus(
            id: UUID(), progress: progress, error: "stale",
            failure: .stale)
        guard case .stale = staleStatus.failureError else {
            return XCTFail("stale failure collapsed into \(staleStatus.failureError)")
        }
        let cancelledStatus = CADAnimationExportStatus(
            id: UUID(), progress: progress, isCancelled: true)
        guard case .cancelled = cancelledStatus.failureError else {
            return XCTFail(
                "cancellation collapsed into \(cancelledStatus.failureError)")
        }
        let untyped = CADAnimationExportStatus(
            id: UUID(), progress: progress, error: "could not verify")
        guard case .verification = untyped.failureError else {
            return XCTFail("untyped failure must stay verification")
        }
    }

    /// Real AVFoundation probe: cancelling a started writer is terminal. The
    /// old polling loop would either append to a cancelled writer (if it were
    /// ready) or spin the whole busy budget; the fixed loop stops at once.
    func testRealCancelledWriterIsRejectedBeforeTheBusyCeiling() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CADWriterReadiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("probe.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw XCTSkip("The test host has no H.264 writer input.")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw XCTSkip("The test host has no H.264 encoder: "
                + (writer.error?.localizedDescription ?? "unknown"))
        }
        writer.startSession(atSourceTime: .zero)
        writer.cancelWriting()
        XCTAssertEqual(writer.status, .cancelled)

        let clock = ContinuousClock()
        let started = clock.now
        do {
            try await FloeCADDocument.waitUntilReady(
                input, writer: writer, frameIndex: 0)
            XCTFail("a cancelled writer must never be treated as ready")
        } catch let error as CADAnimationExportError {
            guard case .writer(let message) = error else {
                return XCTFail("expected .writer, got \(error)")
            }
            XCTAssertTrue(
                message.localizedCaseInsensitiveContains("cancelled"))
            XCTAssertFalse(message.contains("stayed busy"))
        }
        let duration = clock.now - started
        let seconds = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        XCTAssertLessThan(
            seconds, 5,
            "a terminal writer must be rejected at once, not after the busy ceiling")
    }
}

// MARK: - Streaming ZIP primitive (X29-R2 finalizer)

/// The off-main finalizer streams entries instead of buffering them. Its
/// incremental CRC must produce exactly the canonical directory value,
/// including across non-chunk-aligned sizes.
@MainActor
final class CADAnimationFrameFinalizerUnitTests: XCTestCase {
    func testStreamingZipCRCMatchesCanonicalCRC() {
        var seed: UInt32 = 0x1234_5678
        for size in [0, 1, 7, 65_535, 65_536, 65_537, 200_001] {
            var data = Data(count: size)
            for index in data.indices {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                data[index] = UInt8(truncatingIfNeeded: seed >> 24)
            }
            var crc = MinimalZipCRC32()
            crc.update(data.prefix(size / 3))
            crc.update(data.dropFirst(size / 3).prefix(size / 3))
            crc.update(data.dropFirst((size / 3) * 2))
            XCTAssertEqual(crc.checksum, MinimalZipWriter.crc32(data),
                           "chunked CRC32 diverged at size \(size)")
        }
    }

    func testFinalizationCancellationTokenIsThreadSafeAndObservable() {
        let cancellation = CADAnimationFrameFinalizationCancellation()
        XCTAssertFalse(cancellation.isCancelled)
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                cancellation.cancel()
                _ = cancellation.isCancelled
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertThrowsError(try cancellation.check()) { error in
            XCTAssertTrue(error is CancellationError)
        }
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

    /// A brief background transition cannot disappear between render turns.
    func testBriefBackgroundIsRememberedEvenAfterForegroundReturns() async throws {
        let fixture = try await hostedFixture(clipDuration: 0.5)
        let destination = fixture.directory.appendingPathComponent("background-fenced.mp4")
        var backgroundDelivered = false
        let handle = try fixture.document.startAnimationExportMP4(
            clipID: fixture.clip.id, to: destination,
            settings: CADAnimationExportOptions(
                orientation: .portrait, resolution: .p720, frameRate: .fps24,
                codec: .hevc, quality: .smaller).exportSettings()
        ) { progress in
            guard progress.phase == .rendering, progress.completedFrames == 1,
                  !backgroundDelivered else { return }
            backgroundDelivered = true
            // Deterministic brief-background delivery while the real native
            // encoder is running. UIKit is foreground again when the next
            // frame runs; an applicationState-only guard misses this. The
            // separate UI flow uses an actual Home/activate transition.
            NotificationCenter.default.post(
                name: UIApplication.didEnterBackgroundNotification,
                object: UIApplication.shared)
        }
        let status = await fixture.document.waitForAnimationExport(handle.id)
        XCTAssertTrue(backgroundDelivered, "the real first frame must be encoded before delivery")
        XCTAssertEqual(status.progress.phase, .failed)
        XCTAssertFalse(status.isCancelled, "the actual foreground-only refusal must be reported")
        XCTAssertEqual(status.error, CADAnimationExportError.presentationNotActive.localizedDescription)
        XCTAssertNil(status.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(fixture.handle.controller?.isAnimationLeased ?? true,
                       "terminal status must follow renderer ownership release")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
            .filter { $0.hasPrefix(".background-fenced.mp4.export-") }
        XCTAssertTrue(leftovers.isEmpty, "a backgrounded export cannot leave owned staging")
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

    /// Real native frame-sequence witness for X29. It uses the production
    /// Present host and the SAME evaluator/frame-settle path as MP4, then reads
    /// the produced ZIP back: ordered lossless PNGs, exact dimensions, real
    /// opaque alpha, manifest times matching the frozen frame plan, and a
    /// moving model. Root still performs the independent App/media read-back.
    func testFrameSequenceProducesOrderedOpaquePNGsAndManifest() async throws {
        let fixture = try await hostedFixture(clipDuration: 0.5)
        let settings = Self.frameSequenceSettings()
        let destination = fixture.directory.appendingPathComponent("frames.zip")
        let expectedFrames = fixture.clip.frameCount(at: settings.frameRate)

        let result = try await fixture.document.exportAnimation(
            clipID: fixture.clip.id, to: destination, settings: settings)

        XCTAssertEqual(result.format, .pngSequence)
        XCTAssertEqual(result.alpha, .opaque)
        XCTAssertEqual(result.codec, "png")
        XCTAssertEqual(result.width, settings.width)
        XCTAssertEqual(result.height, settings.height)
        XCTAssertEqual(result.frameRate, Double(settings.frameRate),
                       accuracy: 0.001)
        XCTAssertEqual(result.frameCount, expectedFrames)
        XCTAssertFalse(result.hasAudio)
        XCTAssertEqual(result.url.standardizedFileURL,
                       destination.standardizedFileURL)
        XCTAssertNotNil(result.posterPNG)
        XCTAssertEqual(try XCTUnwrap(result.frameTimes).count, expectedFrames)
        let manifestSHA = try XCTUnwrap(result.manifestSHA256)

        let zipData = try Data(contentsOf: destination)
        XCTAssertEqual(result.byteCount, Int64(zipData.count))
        let entries = try ZipReader.entries(in: zipData)
        XCTAssertEqual(entries.count, expectedFrames + 1,
                       "manifest + one real PNG per frame, never a renamed video")
        let manifestData = try XCTUnwrap(entries["manifest.json"])
        XCTAssertEqual(Self.sha256(manifestData), manifestSHA)
        let manifest = try JSONDecoder().decode(
            FrameManifestProbe.self, from: manifestData)
        XCTAssertEqual(manifest.format, "png_zip")
        XCTAssertEqual(manifest.schema, "floe.cad.animation.frames.v1")
        XCTAssertEqual(manifest.version, 1)
        XCTAssertEqual(manifest.clipID, fixture.clip.id.uuidString)
        XCTAssertEqual(manifest.width, settings.width)
        XCTAssertEqual(manifest.height, settings.height)
        XCTAssertEqual(manifest.frameRate, settings.frameRate)
        XCTAssertEqual(manifest.frameCount, expectedFrames)
        XCTAssertEqual(manifest.durationSeconds, fixture.clip.duration,
                       accuracy: 1e-9)
        XCTAssertEqual(manifest.alpha, "opaque")
        XCTAssertEqual(manifest.timescale, settings.frameRate)
        XCTAssertEqual(manifest.frames.count, expectedFrames)

        var frames: [[UInt8]] = []
        for entry in manifest.frames {
            XCTAssertEqual(entry.file,
                           String(format: "frames/frame_%06d.png", entry.index))
            XCTAssertEqual(entry.presentationValue, entry.index)
            XCTAssertEqual(entry.timescale, settings.frameRate)
            let expectedTime = FloeCADDocument.animationFrameTime(
                frame: entry.index, fps: settings.frameRate,
                duration: fixture.clip.duration)
            XCTAssertEqual(entry.timeSeconds, expectedTime, accuracy: 1e-9)
            let png = try XCTUnwrap(entries[entry.file])
            XCTAssertEqual(png.count, entry.byteCount)
            XCTAssertEqual(Self.sha256(png), entry.sha256)
            let decoded = try Self.rgbaPixels(png)
            XCTAssertEqual(decoded.width, settings.width)
            XCTAssertEqual(decoded.height, settings.height)
            XCTAssertEqual(Self.minimumAlpha(decoded.rgba), 255,
                           "frame \(entry.index) declares opaque and must be opaque")
            frames.append(decoded.rgba)
        }
        let resultTimes = try XCTUnwrap(result.frameTimes)
        XCTAssertEqual(resultTimes.count, manifest.frames.count)
        for (time, entry) in zip(resultTimes, manifest.frames) {
            XCTAssertEqual(time, entry.timeSeconds, accuracy: 1e-12)
        }
        XCTAssertEqual(try XCTUnwrap(result.posterPNG),
                       try XCTUnwrap(entries["frames/frame_000000.png"]))

        let first = try XCTUnwrap(frames.first)
        let last = try XCTUnwrap(frames.last)
        XCTAssertGreaterThan(Self.redFraction(first), 0.01,
                             "the first actual frame must contain the red fixture")
        XCTAssertGreaterThan(Self.redFraction(last), 0.01,
                             "the last actual frame must contain the red fixture")
        let changed = zip(first, last).filter { abs(Int($0) - Int($1)) > 20 }.count
        XCTAssertGreaterThan(Double(changed) / Double(first.count), 0.001,
                             "the camera animation must move the real model pixels")
        try assertNoStagingRemains(in: fixture.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        // Keep the exact verified bundle and PNG bytes before fixture cleanup.
        // Root archives these originals with the actual run's source receipt.
        let bundleAttachment = XCTAttachment(
            data: zipData, uniformTypeIdentifier: UTType.zip.identifier)
        bundleAttachment.name = "Actual ordered PNG frame bundle"
        bundleAttachment.lifetime = .keepAlways
        add(bundleAttachment)
        for entry in [try XCTUnwrap(manifest.frames.first),
                      try XCTUnwrap(manifest.frames.last)] {
            let attachment = XCTAttachment(
                data: try XCTUnwrap(entries[entry.file]),
                uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = "Actual PNG frame " + String(entry.index)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Part-motion witness: one real assembly instance moves while its source
    /// body stays fixed. Root can compare first/last decoded PNGs against this
    /// known 60 mm -> 140 mm translation through the same native settle path.
    func testFrameSequenceCapturesAnimatedPartGeometry() async throws {
        let fixture = try await hostedFixture(
            clipDuration: 0.5, animatedPart: true)
        let settings = Self.frameSequenceSettings()
        let destination = fixture.directory
            .appendingPathComponent("animated-part-frames.zip")
        let expectedFrames = fixture.clip.frameCount(at: settings.frameRate)

        let result = try await fixture.document.exportAnimation(
            clipID: fixture.clip.id, to: destination, settings: settings)
        XCTAssertEqual(result.format, .pngSequence)
        XCTAssertEqual(result.frameCount, expectedFrames)

        let entries = try ZipReader.entries(in: try Data(contentsOf: destination))
        let manifestData = try XCTUnwrap(entries["manifest.json"])
        let manifest = try JSONDecoder().decode(
            FrameManifestProbe.self, from: manifestData)
        XCTAssertEqual(manifest.frameCount, expectedFrames)
        XCTAssertEqual(try XCTUnwrap(manifest.frames.first).presentationValue, 0)
        XCTAssertEqual(try XCTUnwrap(manifest.frames.last).presentationValue,
                       expectedFrames - 1)

        let firstPNG = try XCTUnwrap(entries[try XCTUnwrap(
            manifest.frames.first?.file)])
        let lastPNG = try XCTUnwrap(entries[try XCTUnwrap(
            manifest.frames.last?.file)])
        let first = try Self.rgbaPixels(firstPNG)
        let last = try Self.rgbaPixels(lastPNG)
        XCTAssertEqual(first.width, settings.width)
        XCTAssertEqual(first.height, settings.height)
        XCTAssertEqual(last.width, settings.width)
        XCTAssertEqual(last.height, settings.height)
        XCTAssertEqual(Self.minimumAlpha(first.rgba), 255)
        XCTAssertEqual(Self.minimumAlpha(last.rgba), 255)
        XCTAssertGreaterThan(Self.redFraction(first.rgba), 0.005)
        XCTAssertGreaterThan(Self.redFraction(last.rgba), 0.005)
        let changed = zip(first.rgba, last.rgba)
            .filter { abs(Int($0) - Int($1)) > 20 }.count
        XCTAssertGreaterThan(Double(changed) / Double(first.rgba.count), 0.001,
                             "the placed instance must actually move")
        try assertNoStagingRemains(in: fixture.directory)
    }

    func testFrameSequenceCancelRemovesStagingAndPromotesNothing() async throws {
        let fixture = try await hostedFixture(clipDuration: 2.0)
        let settings = Self.frameSequenceSettings()
        let destination = fixture.directory
            .appendingPathComponent("cancelled-frames.zip")

        let handle = try fixture.document.startAnimationExport(
            clipID: fixture.clip.id, to: destination, settings: settings)
        try await waitUntilExportRenders(fixture.document, handle: handle)

        fixture.document.cancelAnimationExport(handle.id)
        let status = await fixture.document.waitForAnimationExport(handle.id)
        XCTAssertTrue(status.isCancelled)
        XCTAssertEqual(status.progress.phase, .cancelled)
        XCTAssertNil(status.result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingRemains(in: fixture.directory, status: status)
    }

#if DEBUG
    /// X29-R2: cancel while the REAL finalizer is packaging an already-rendered
    /// frame bundle. The DEBUG checkpoint holds the actual worker thread (never
    /// the main actor) at a real ZIP write boundary; the main actor cancels
    /// through the service, then releases the worker. The terminal status must
    /// arrive only after that worker exits and staging is removed, and a
    /// pre-existing destination must survive untouched.
    func testFrameSequenceCancelDuringFinalizationJoinsWorkerAndKeepsDestination() async throws {
        let fixture = try await hostedFixture(clipDuration: 0.5)
        var settings = Self.frameSequenceSettings()
        settings.overwrite = true
        let destination = fixture.directory
            .appendingPathComponent("cancelled-finalizing-frames.zip")
        let sentinel = Data("existing destination must survive".utf8)
        try sentinel.write(to: destination)
        let expectedFrames = fixture.clip.frameCount(at: settings.frameRate)
        XCTAssertGreaterThanOrEqual(expectedFrames, 4,
                                    "the witness needs a real multi-frame bundle")

        let gate = AnimationFinalizationGate(
            blockAt: .writingFrame, frameIndex: 1)
        CADAnimationFrameFinalizationProbe.shared.setObserver { visit in
            gate.record(visit)
        }
        defer {
            CADAnimationFrameFinalizationProbe.shared.setObserver(nil)
            gate.release()
        }

        let handle = try fixture.document.startAnimationExport(
            clipID: fixture.clip.id, to: destination, settings: settings)
        let blocked = try await gate.waitUntilBlocked(timeout: 90)
        XCTAssertTrue(blocked, "the real finalizer never reached the ZIP write checkpoints")
        let beforeRelease = gate.visits()
        XCTAssertFalse(beforeRelease.isEmpty)
        XCTAssertFalse(beforeRelease.contains { $0.isMainThread },
                       "frame finalization must run off the main actor")
        XCTAssertGreaterThanOrEqual(
            beforeRelease.filter { $0.point == .verifyingFrame }.count,
            expectedFrames,
            "every real staged frame must be verified off-main before packaging")
        XCTAssertEqual(beforeRelease.last?.point, .writingFrame)
        XCTAssertEqual(try Data(contentsOf: destination), sentinel,
                       "finalization must not touch the destination before promotion")
        // The real stage-2 worker has already written the manifest and frame 0
        // into this job's staged ZIP. Cancellation is therefore requested while
        // a real partial archive is on disk, not before packaging starts.
        let stagingNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.directory.path)
        let stagingName = try XCTUnwrap(
            stagingNames.first {
                $0.hasPrefix(".cancelled-finalizing-frames.zip.export-")
            },
            "the finalizer must stage beside the destination")
        let stagedZIP = fixture.directory
            .appendingPathComponent(stagingName)
            .appendingPathComponent("frames.zip")
        let stagedBytes = (try FileManager.default.attributesOfItem(
            atPath: stagedZIP.path)[.size] as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(stagedBytes, 0,
                             "the finalizer must be writing a real partial ZIP")

        fixture.document.cancelAnimationExport(handle.id)
        // Wait until the export task's cancellation handler has actually set
        // the finalizer token. The worker is still held at the write
        // checkpoint, so releasing it now must abort on the very next chunk
        // check instead of racing the cancellation delivery.
        let observedCancel = try await gate.waitFor(.cancelled, timeout: 15)
        XCTAssertTrue(observedCancel,
                      "the finalizer never observed the service cancellation")
        gate.release()

        let status = await fixture.document.waitForAnimationExport(handle.id)
        XCTAssertTrue(status.isCancelled)
        XCTAssertEqual(status.progress.phase, .cancelled)
        XCTAssertNil(status.result)
        let visitsAtStatus = gate.visits()
        XCTAssertEqual(visitsAtStatus.last?.point, .exited,
                       "the finalizer worker must have exited before the terminal status")
        XCTAssertEqual(try Data(contentsOf: destination), sentinel,
                       "cancellation during finalization must not replace an existing destination")
        try assertNoStagingRemains(in: fixture.directory, status: status)

        // A detached/orphan writer would keep reporting checkpoints after the
        // status. Give it a bounded window in which it must stay silent.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(gate.visits().count, visitsAtStatus.count,
                       "no orphan worker may keep writing after cancellation")
    }

    /// The same real finalizer must succeed completely off-main: every frame is
    /// verified and written from the worker, and the bundle still reads back as
    /// the ordered PNG manifest R1 established.
    func testFrameSequenceFinalizationSucceedsOffMain() async throws {
        let fixture = try await hostedFixture(clipDuration: 0.5)
        let settings = Self.frameSequenceSettings()
        let destination = fixture.directory
            .appendingPathComponent("offmain-frames.zip")
        let expectedFrames = fixture.clip.frameCount(at: settings.frameRate)
        let gate = AnimationFinalizationGate(blockAt: nil, frameIndex: nil)
        CADAnimationFrameFinalizationProbe.shared.setObserver { visit in
            gate.record(visit)
        }
        defer { CADAnimationFrameFinalizationProbe.shared.setObserver(nil) }

        let result = try await fixture.document.exportAnimation(
            clipID: fixture.clip.id, to: destination, settings: settings)

        XCTAssertEqual(result.frameCount, expectedFrames)
        XCTAssertEqual(result.format, .pngSequence)
        XCTAssertNotNil(result.manifestSHA256)
        let visits = gate.visits()
        XCTAssertFalse(visits.isEmpty)
        XCTAssertFalse(visits.contains { $0.isMainThread },
                       "frame finalization must run off the main actor")
        XCTAssertEqual(visits.filter { $0.point == .verifyingFrame }.count,
                       expectedFrames)
        XCTAssertEqual(visits.filter { $0.point == .writingFrame }.count,
                       expectedFrames)
        XCTAssertEqual(visits.last?.point, .exited)
        let entries = try ZipReader.entries(in: try Data(contentsOf: destination))
        XCTAssertEqual(entries.count, expectedFrames + 1)
        let manifest = try XCTUnwrap(entries["manifest.json"])
        XCTAssertEqual(Self.sha256(manifest), try XCTUnwrap(result.manifestSHA256))
        try assertNoStagingRemains(in: fixture.directory)
    }
#endif

    func testFrameSequenceAbortsWithStaleWhenDocumentEditedDuringRender() async throws {
        let fixture = try await hostedFixture(clipDuration: 2.0)
        let settings = Self.frameSequenceSettings()
        let destination = fixture.directory
            .appendingPathComponent("edited-frames.zip")

        let handle = try fixture.document.startAnimationExport(
            clipID: fixture.clip.id, to: destination, settings: settings)
        try await waitUntilExportRenders(fixture.document, handle: handle)

        fixture.document.session.perform(
            AddBodyCommand(body: Self.fixtureBox(), title: "Edit during frame export"))

        let status = await fixture.document.waitForAnimationExport(handle.id)
        XCTAssertEqual(status.progress.phase, .failed)
        XCTAssertEqual(status.error,
                       CADAnimationExportError.stale.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingRemains(in: fixture.directory, status: status)
    }

    func testTransparentFrameRequestIsRefusedBeforeAnyOutput() async throws {
        let fixture = try await hostedFixture(clipDuration: 0.5)
        var settings = Self.frameSequenceSettings()
        settings.alpha = .transparent
        let destination = fixture.directory
            .appendingPathComponent("transparent-frames.zip")

        XCTAssertThrowsError(try fixture.document.startAnimationExport(
            clipID: fixture.clip.id, to: destination, settings: settings)
        ) { error in
            guard let exportError = error as? CADAnimationExportError,
                  case .invalidSettings(let message) = exportError else {
                return XCTFail("expected a truthful invalidSettings refusal, got \(error)")
            }
            XCTAssertTrue(message.contains("Transparent"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try assertNoStagingRemains(in: fixture.directory)
        XCTAssertFalse(CADAnimationExportCenter.shared.hasActiveJob(
            documentKey: fixture.document.url.standardizedFileURL.path),
            "a refused transparent request must not leave an owned export job")
    }

    // MARK: X29 frame helpers / probes

    private static func frameSequenceSettings(
        width: Int = 720, height: Int = 1280, fps: Int = 24
    ) -> CADAnimationExportSettings {
        CADAnimationExportSettings(
            width: width, height: height, frameRate: fps,
            bitrate: nil, overwrite: false, posterEnabled: true,
            format: .pngSequence, alpha: .opaque)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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

    private static func minimumAlpha(_ rgba: [UInt8]) -> Int {
        var minimum = 255
        for offset in stride(from: 3, to: rgba.count, by: 4) {
            minimum = min(minimum, Int(rgba[offset]))
        }
        return minimum
    }

    private struct FrameManifestProbe: Decodable {
        var format: String
        var schema: String
        var version: Int
        var clipID: String
        var width: Int
        var height: Int
        var frameRate: Int
        var frameCount: Int
        var durationSeconds: Double
        var alpha: String
        var background: String
        var timescale: Int
        var frames: [FrameEntryProbe]
    }

    private struct FrameEntryProbe: Decodable {
        var index: Int
        var file: String
        var timeSeconds: Double
        var presentationValue: Int
        var timescale: Int
        var byteCount: Int
        var sha256: String
        var crc32: UInt32
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
        rescheduleAutosaveBeforeExport: Bool = false,
        animatedPart: Bool = false
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
        let body = Self.fixtureBox()
        document.session.perform(AddBodyCommand(body: body,
                                                title: "Add fixture box"))

        let clip = try document.createAnimationClip(name: "Orbit", duration: clipDuration)
        var rescheduleCameraTrack: CADAnimationTrack?
        if animatedPart {
            // Real placed geometry: one assembly instance moves 80 mm while the
            // source body stays put. This is the X29 part-motion witness, not a
            // synthetic frame producer.
            let instance = CADAssemblyInstance(
                name: "Animated fixture",
                bodyID: body.id.raw,
                transform: CADTransform(position: SIMD3(60, 0, 0)))
            let assembly = CADAssembly(instances: [instance])
            document.session.perform(SetAssemblyDataCommand(
                before: document.session.document.assemblyData,
                after: try assembly.encoded()))
            let track = try document.addAnimationTrack(
                clipID: clip.id,
                target: .instance(instance.id, sourceBodyID: body.id.raw))
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, time: 0,
                instance: CADAnimationInstanceValue(
                    translationMM: SIMD3(60, 0, 0)))
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, time: clipDuration,
                instance: CADAnimationInstanceValue(
                    translationMM: SIMD3(140, 0, 0)))
            // A fixed wide camera keeps both the source body (0...25 mm) and
            // the instance (60...165 mm) inside the exported frame.
            let cameraTrack = try document.addAnimationTrack(
                clipID: clip.id, target: .camera)
            for time in [0.0, clipDuration] {
                _ = try document.setAnimationKeyframe(
                    clipID: clip.id, trackID: cameraTrack.id, time: time,
                    camera: CADAnimationCameraValue(
                        target: SIMD3(0.07, 0, 0), distance: 0.28,
                        azimuthRadians: 0, elevationRadians: 0.3,
                        fovYDegrees: 60))
            }
        } else {
            let track = try document.addAnimationTrack(clipID: clip.id, target: .camera)
            rescheduleCameraTrack = track
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
        if rescheduleAutosaveBeforeExport, let track = rescheduleCameraTrack {
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

#if DEBUG
/// Deterministic, BOUNDED gate for the REAL off-main finalizer. The exporter
/// calls the DEBUG probe from its worker; `record` can hold that worker at one
/// exact checkpoint until the test cancels and releases. The wait has its own
/// 120 s bound and `release()` is idempotent, so a failed test can never leave
/// the worker or the export job suspended forever.
private nonisolated final class AnimationFinalizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let blockAt: CADAnimationFrameFinalizationPoint?
    private let blockFrame: Int?
    private var recorded: [CADAnimationFrameFinalizationProbe.Visit] = []
    private var blocked = false
    private var released = false

    init(blockAt: CADAnimationFrameFinalizationPoint?, frameIndex: Int?) {
        self.blockAt = blockAt
        self.blockFrame = frameIndex
    }

    func record(_ visit: CADAnimationFrameFinalizationProbe.Visit) {
        lock.lock()
        recorded.append(visit)
        let shouldBlock = !blocked && blockAt == visit.point
            && (blockFrame == nil || blockFrame == visit.frameIndex)
        if shouldBlock { blocked = true }
        lock.unlock()
        guard shouldBlock else { return }
        _ = semaphore.wait(timeout: .now() + 120)
    }

    var isBlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func waitUntilBlocked(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isBlocked { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return isBlocked
    }

    func waitFor(
        _ point: CADAnimationFrameFinalizationPoint,
        timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if visits().contains(where: { $0.point == point }) { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return visits().contains(where: { $0.point == point })
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        lock.unlock()
        semaphore.signal()
    }

    func visits() -> [CADAnimationFrameFinalizationProbe.Visit] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}
#endif

#endif
