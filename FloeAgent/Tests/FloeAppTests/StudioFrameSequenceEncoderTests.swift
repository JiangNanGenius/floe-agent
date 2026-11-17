// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import XCTest
import FloeTools
@testable import FloeApp

@MainActor final class StudioFrameSequenceEncoderTests: XCTestCase {
    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testEncodedFramesAreReadableAndRetainFrameOrder() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("floe-frames-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("frames.bgra")
        var bytes = Data()
        for frame in 0..<4 {
            let pixel: [UInt8] = frame.isMultiple(of: 2) ? [0, 0, 255, 255] : [255, 0, 0, 255]
            for _ in 0..<(32 * 32) { bytes.append(contentsOf: pixel) }
        }
        try bytes.write(to: source)
        let spec = StudioFrameSequenceEncoder.Specification(width: 32, height: 32, frameRate: 4,
            frameCount: 4, expectedSHA256: digest(bytes))
        let result = try await StudioFrameSequenceEncoder.encode(source: source, workspaceRoot: root, spec: spec, cancellation: CancellationToken())
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertEqual(result.sourceSHA256, digest(bytes))
        XCTAssertEqual(result.outputSHA256, digest(try Data(contentsOf: result.url)))
        let asset = AVURLAsset(url: result.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        XCTAssertTrue(reader.canAdd(output)); reader.add(output); XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            let pixel = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            if frames.isMultiple(of: 2) { XCTAssertGreaterThan(Int(pointer[2]), Int(pointer[0]) + 100) }
            else { XCTAssertGreaterThan(Int(pointer[0]), Int(pointer[2]) + 100) }
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            frames += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(frames, 4)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 1, accuracy: 0.1)
    }

    func testBoundsChecksumSymlinkAndCancellationAreRejected() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("floe-frames-invalid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("frames.bgra"), link = root.appendingPathComponent("link.bgra")
        let bytes = Data(repeating: 255, count: 32 * 32 * 4)
        try bytes.write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let valid = StudioFrameSequenceEncoder.Specification(width: 32, height: 32, frameRate: 4, frameCount: 1, expectedSHA256: digest(bytes))
        XCTAssertThrowsError(try StudioFrameSequenceEncoder.Specification(width: 2048, height: 2048, frameRate: 30, frameCount: 33, expectedSHA256: digest(bytes)).validate())
        let token = CancellationToken(); token.cancel()
        do { _ = try await StudioFrameSequenceEncoder.encode(source: source, workspaceRoot: root, spec: valid, cancellation: token); XCTFail("Cancelled frame sequence was encoded") } catch {}
        do { _ = try await StudioFrameSequenceEncoder.encode(source: link, workspaceRoot: root, spec: valid, cancellation: CancellationToken()); XCTFail("Symbolic link was accepted") } catch {}
        let wrongHash = StudioFrameSequenceEncoder.Specification(width: 32, height: 32, frameRate: 4, frameCount: 1, expectedSHA256: String(repeating: "0", count: 64))
        do { _ = try await StudioFrameSequenceEncoder.encode(source: source, workspaceRoot: root, spec: wrongHash, cancellation: CancellationToken()); XCTFail("Incorrect digest was accepted") } catch {}
        let wrongCount = StudioFrameSequenceEncoder.Specification(width: 32, height: 32, frameRate: 4, frameCount: 2, expectedSHA256: digest(bytes))
        do { _ = try await StudioFrameSequenceEncoder.encode(source: source, workspaceRoot: root, spec: wrongCount, cancellation: CancellationToken()); XCTFail("Truncated frame data was accepted") } catch {}
    }

    func testStagingCleanupSkipsActiveAndUnsafeEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("frame-staging-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var active: StudioFrameStagingLease? = try .create(root: root)
        let activeDirectory = try XCTUnwrap(active).url.deletingLastPathComponent()
        let stale = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: false)
        try Data().write(to: stale.appendingPathComponent(".lock"))
        try Data("old".utf8).write(to: stale.appendingPathComponent("output.mp4"))
        let external = root.appendingPathComponent("untouched.txt")
        try Data("keep".utf8).write(to: external)
        let unsafe = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false)
        try Data().write(to: unsafe.appendingPathComponent(".lock"))
        try FileManager.default.createSymbolicLink(at: unsafe.appendingPathComponent("output.mp4"), withDestinationURL: external)
        let old = Date().addingTimeInterval(-90_000)
        for directory in [activeDirectory, stale, unsafe] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: directory.path)
        }
        let collector = try StudioFrameStagingLease.create(root: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertEqual(try Data(contentsOf: external), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unsafe.appendingPathComponent(".lock").path))
        withExtendedLifetime(collector) {}
        active = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeDirectory.path))
    }
}
#endif
