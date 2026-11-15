// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import Foundation
import FloeGameCore
@testable import FloeApp

/// Contract tests for manifests, file hashes and runtime readiness.
final class GameRuntimeResourceContractTests: XCTestCase {
    private let hello = Data("hello".utf8)
    private let helloSHA256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-game-resource-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testManifestDecodesFilesMarkersAndRemoteArchive() throws {
        let manifest = try JSONDecoder().decode(GameRuntimeResourceManifest.self,
            from: Data(#"""
            {
              "schemaVersion": 1,
              "generatedFrom": "test",
              "packs": [{
                "id": "renpy-8.5.3-sdk",
                "role": "primary",
                "engines": ["renpy"],
                "displayName": "Ren'Py SDK",
                "version": "8.5.3",
                "license": "Ren'Py",
                "kind": "remoteArchive",
                "files": [],
                "licenseFiles": [],
                "markers": ["renpy.sh"],
                "archive": {
                  "url": "https://example.com/sdk.tar.bz2",
                  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                  "format": "tbz2",
                  "markers": ["renpy.sh"],
                  "markerContents": {}
                },
                "notes": []
              }]
            }
            """#.utf8))
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.packs.first?.engineIDs, [.renpy])
        XCTAssertEqual(manifest.packs.first?.archive?.format, "tbz2")
    }

    func testVerifiedFileAndMarkerBecomeReady() throws {
        let root = try temporaryDirectory()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: false)
        try hello.write(to: root.appendingPathComponent("runtime/engine.js"))
        try Data("hash".utf8).write(to: root.appendingPathComponent("web/hash.txt"))
        let input = GameRuntimeVerificationInput(
            root: root,
            files: [.init(path: "runtime/engine.js", sha256: helloSHA256,
                          bytes: hello.count, url: nil)],
            markers: ["runtime/engine.js"],
            markerContents: ["web/hash.txt": "hash"])
        XCTAssertNoThrow(try GameRuntimeResourceVerifier.verify(input))
    }

    func testDigestMismatchFailsClosed() throws {
        let root = try temporaryDirectory()
        try hello.write(to: root.appendingPathComponent("phaser.js"))
        let input = GameRuntimeVerificationInput(
            root: root,
            files: [.init(path: "phaser.js", sha256: String(repeating: "0", count: 64),
                          bytes: hello.count, url: nil)],
            markers: [],
            markerContents: [:])
        XCTAssertThrowsError(try GameRuntimeResourceVerifier.verify(input)) { error in
            guard let value = error as? GameRuntimeResourceError,
                  case .digestMismatch = value else {
                return XCTFail("expected digest mismatch, got \(error)")
            }
        }
    }

    func testTraversalPathAndMarkerContentMismatchFailClosed() throws {
        let root = try temporaryDirectory()
        try hello.write(to: root.appendingPathComponent("phaser.js"))
        let traversal = GameRuntimeVerificationInput(
            root: root,
            files: [.init(path: "../escape", sha256: helloSHA256,
                          bytes: hello.count, url: nil)],
            markers: [], markerContents: [:])
        XCTAssertThrowsError(try GameRuntimeResourceVerifier.verify(traversal)) { error in
            guard let value = error as? GameRuntimeResourceError,
                  case .corruptInstallation = value else {
                return XCTFail("expected path refusal, got \(error)")
            }
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("web"), withIntermediateDirectories: false)
        try Data("actual".utf8).write(to: root.appendingPathComponent("web/hash.txt"))
        let mismatch = GameRuntimeVerificationInput(
            root: root, files: [], markers: [],
            markerContents: ["web/hash.txt": "expected"])
        XCTAssertThrowsError(try GameRuntimeResourceVerifier.verify(mismatch)) { error in
            guard let value = error as? GameRuntimeResourceError,
                  case .digestMismatch = value else {
                return XCTFail("expected marker mismatch, got \(error)")
            }
        }
    }

    func testUnknownPackIsNeverPresentedAsReady() {
        let readiness = GameRuntimeEngineReadiness(
            engine: .phaser, packID: "phaser-3.90.0", displayName: "Phaser",
            version: "3.90.0", state: .unknown)
        XCTAssertFalse(readiness.isReady)
        XCTAssertFalse(readiness.canDownload)
        XCTAssertFalse(readiness.canRetry)
    }
}
#endif
