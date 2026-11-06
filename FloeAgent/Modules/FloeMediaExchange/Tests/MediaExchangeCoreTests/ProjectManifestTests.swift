// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import MediaExchangeCore

final class ProjectManifestTests: XCTestCase {
    private func mediaFiles(in directory: URL) throws -> [String: URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var result: [String: URL] = [:]
        for (id, name, bytes) in [
            ("videoA", "a.mov", Data(repeating: 1, count: 32)),
            ("videoB", "b.mov", Data(repeating: 2, count: 48)),
            ("audio", "mix.wav", Data(repeating: 3, count: 16))
        ] {
            let url = directory.appendingPathComponent(name)
            try bytes.write(to: url)
            result[id] = url
        }
        return result
    }

    func testPackedManifestCopiesHashesAndResolvesMedia() throws {
        let root = try TestSupport.temporaryDirectory("packed")
        defer { TestSupport.remove(root) }
        let files = try mediaFiles(in: root.appendingPathComponent("inputs", isDirectory: true))
        let package = root.appendingPathComponent("Project.floe", isDirectory: true)
        let timeline = try TimelineFixture.makeTimeline()
        let manifest = try ExchangeProjectManifest.makePacked(
            projectName: "Project",
            projectID: "project-1",
            timeline: timeline,
            mediaFiles: files,
            destination: package
        )
        XCTAssertEqual(manifest.storageMode, .packed)
        XCTAssertEqual(manifest.media.count, 3)
        XCTAssertFalse(manifest.sourceSnapshot.manifestDigest.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("manifest.json").path))
        for entry in manifest.media {
            XCTAssertEqual(entry.source.storage, .packed)
            XCTAssertEqual(entry.source.ownsMedia, true)
            let url = package.appendingPathComponent(try XCTUnwrap(entry.source.relativePath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        let loaded = try ExchangeProjectManifest.load(from: package)
        XCTAssertEqual(loaded.projectID, "project-1")
        XCTAssertEqual(loaded.sourceRevision, timeline.sourceRevision)
        try loaded.verifyDigest()
        let open = loaded.resolveMedia(in: package)
        XCTAssertEqual(open.resolvedMedia.count, 3)
        XCTAssertTrue(open.missingMedia.isEmpty)
        XCTAssertTrue(open.warnings.isEmpty)
        XCTAssertEqual(open.resolvedMedia["videoA"].flatMap { try? Data(contentsOf: $0) }?.count, 32)
    }

    func testMissingAndChangedMediaAreReportedWithoutReplacement() throws {
        let root = try TestSupport.temporaryDirectory("missing")
        defer { TestSupport.remove(root) }
        let files = try mediaFiles(in: root.appendingPathComponent("inputs", isDirectory: true))
        let package = root.appendingPathComponent("Project.floe", isDirectory: true)
        let manifest = try ExchangeProjectManifest.makePacked(
            projectName: "Project",
            timeline: try TimelineFixture.makeTimeline(),
            mediaFiles: files,
            destination: package
        )
        let entry = try XCTUnwrap(manifest.media.first { $0.id == "videoA" })
        let mediaURL = package.appendingPathComponent(try XCTUnwrap(entry.source.relativePath))
        try FileManager.default.removeItem(at: mediaURL)
        let missing = manifest.resolveMedia(in: package)
        XCTAssertTrue(missing.missingMedia.contains("videoA"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mediaURL.path), "resolution must not recreate media")
        let other = try XCTUnwrap(manifest.media.first { $0.id == "videoB" })
        let otherURL = package.appendingPathComponent(try XCTUnwrap(other.source.relativePath))
        try Data(repeating: 9, count: 48).write(to: otherURL)
        let changed = manifest.resolveMedia(in: package)
        XCTAssertTrue(changed.warnings.contains { $0.contains("videoB") })
    }

    func testPackedRelinkRequiresExplicitOwnershipAndRecordsRevision() throws {
        let root = try TestSupport.temporaryDirectory("relink")
        defer { TestSupport.remove(root) }
        let files = try mediaFiles(in: root.appendingPathComponent("inputs", isDirectory: true))
        let package = root.appendingPathComponent("Project.floe", isDirectory: true)
        var manifest = try ExchangeProjectManifest.makePacked(
            projectName: "Project",
            timeline: try TimelineFixture.makeTimeline(),
            mediaFiles: files,
            destination: package
        )
        let target = root.appendingPathComponent("moved.mov")
        try Data(repeating: 7, count: 32).write(to: target)
        XCTAssertThrowsError(try manifest.relink(mediaID: "videoA", to: target, reason: "move")) { error in
            guard case ExchangeProjectError.ownershipTransferRequiresExplicitConsent = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
        let before = manifest.sourceRevision
        let record = try manifest.relink(
            mediaID: "videoA",
            to: target,
            reason: "staged rename",
            newPackageRelativePath: "media/renamed.mov",
            packageRoot: package
        )
        XCTAssertEqual(manifest.sourceRevision, before + 1)
        XCTAssertEqual(record.sourceRevisionBefore, before)
        XCTAssertEqual(record.sourceRevisionAfter, before + 1)
        XCTAssertEqual(manifest.media.first { $0.id == "videoA" }?.relinkHistory.count, 1)
        XCTAssertEqual(manifest.media.first { $0.id == "videoA" }?.source.relativePath, "media/renamed.mov")
        try manifest.write(to: package)
        let loaded = try ExchangeProjectManifest.load(from: package)
        XCTAssertEqual(loaded.sourceRevision, before + 1)
        XCTAssertEqual(loaded.media.first { $0.id == "videoA" }?.relinkHistory.first?.reason, "staged rename")
        let open = loaded.resolveMedia(in: package)
        XCTAssertNotNil(open.resolvedMedia["videoA"], "relinked packed media was not staged")
        XCTAssertFalse(open.missingMedia.contains("videoA"))
    }

    func testReferenceOnlyManifestPreservesOwnershipAndBookmarks() throws {
        let root = try TestSupport.temporaryDirectory("reference")
        defer { TestSupport.remove(root) }
        let files = try mediaFiles(in: root.appendingPathComponent("inputs", isDirectory: true))
        let timeline = try TimelineFixture.makeTimeline()
        let manifest = try ExchangeProjectManifest.makeReferenced(
            projectName: "Reference project",
            timeline: timeline,
            externalURLs: files,
            bookmarks: ["audio": Data([1, 2, 3, 4])]
        )
        XCTAssertEqual(manifest.storageMode, .referenced)
        for entry in manifest.media {
            XCTAssertEqual(entry.source.storage, .external)
            XCTAssertEqual(entry.source.ownsMedia, false)
        }
        XCTAssertEqual(manifest.media.first { $0.id == "audio" }?.source.securityScopedBookmark, Data([1, 2, 3, 4]))
        let package = root.appendingPathComponent("Reference", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try manifest.write(to: package)
        let loaded = try ExchangeProjectManifest.load(from: package)
        let open = loaded.resolveMedia(in: package)
        XCTAssertEqual(open.resolvedMedia.count, 3)
        XCTAssertEqual(open.externalSecurityScopedMedia, ["audio"])
        XCTAssertTrue(open.missingMedia.isEmpty)
    }

    func testDigestAndTraversalAndSymlinkEscapeAreRejected() throws {
        let root = try TestSupport.temporaryDirectory("security")
        defer { TestSupport.remove(root) }
        let files = try mediaFiles(in: root.appendingPathComponent("inputs", isDirectory: true))
        let package = root.appendingPathComponent("Project.floe", isDirectory: true)
        let manifest = try ExchangeProjectManifest.makePacked(
            projectName: "Project",
            timeline: try TimelineFixture.makeTimeline(),
            mediaFiles: files,
            destination: package
        )
        var tampered = manifest
        tampered.projectName = "Tampered"
        XCTAssertThrowsError(try tampered.verifyDigest())

        for unsafe in ["../escape", "/absolute", "a/../../b", "a\\b", "C:media", ""] {
            XCTAssertThrowsError(try ExchangeMediaSource(packedRelativePath: unsafe), unsafe)
        }

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([1]).write(to: outside.appendingPathComponent("payload.bin"))
        let link = package.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ExchangePathSafety.resolvePacked("link/payload.bin", in: package)) { error in
            guard case ExchangePathError.outsidePackageRoot = error else {
                return XCTFail("expected symlinkEscape, got \(error)")
            }
        }
        let leafLink = package.appendingPathComponent("leaf.bin")
        try FileManager.default.createSymbolicLink(at: leafLink, withDestinationURL: outside.appendingPathComponent("payload.bin"))
        XCTAssertThrowsError(try ExchangePathSafety.resolvePacked("leaf.bin", in: package))
        XCTAssertNoThrow(try ExchangePathSafety.resolvePacked("media/000-a.mov", in: package))
    }

    func testPackedDestinationMustBeNewOrEmpty() throws {
        let root = try TestSupport.temporaryDirectory("destination")
        defer { TestSupport.remove(root) }
        let files = try mediaFiles(in: root.appendingPathComponent("inputs", isDirectory: true))
        let package = root.appendingPathComponent("Project.floe", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data([1]).write(to: package.appendingPathComponent("unrelated"))
        XCTAssertThrowsError(try ExchangeProjectManifest.makePacked(
            projectName: "Project",
            timeline: try TimelineFixture.makeTimeline(),
            mediaFiles: files,
            destination: package
        ))
    }
}
