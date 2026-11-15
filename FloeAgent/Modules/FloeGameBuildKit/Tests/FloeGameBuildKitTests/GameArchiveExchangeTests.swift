// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

final class GameArchiveFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("FloeGameBuildKit-" + UUID().uuidString)
    init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    /// A project with binary bytes, an empty directory, an executable script
    /// and unicode content — the roundtrip must preserve all of it.
    func project() throws -> URL {
        let source = try directory("project")
        try Data(#"{"actors":[{"name":"英雄","hp":100}],"meta":{"保留":true}}"#.utf8)
            .write(to: source.appendingPathComponent("data.json"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Assets/Empty"), withIntermediateDirectories: true)
        try Data([0, 255, 1, 2, 0, 0, 7]).write(to: source.appendingPathComponent("Assets/blob.bin"))
        let script = source.appendingPathComponent("tools/run.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho hi\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return source
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

final class GameArchiveExchangeTests: XCTestCase {
    func testExportThenImportRoundTripPreservesEverything() throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let source = try fixture.project()
        let exchange = GameArchiveExchange()
        let zipURL = fixture.root.appendingPathComponent("out.zip")
        let publication = try exchange.archive(directory: source, to: zipURL)
        XCTAssertEqual(publication.entryCount, 6)
        XCTAssertEqual(publication.sha256, GameDigest.sha256(try Data(contentsOf: zipURL)))

        let target = fixture.root.appendingPathComponent("imported")
        let extraction = try exchange.extract(archive: zipURL, to: target)
        XCTAssertEqual(extraction.originalArchiveSHA256, publication.sha256)
        XCTAssertEqual(Set(extraction.manifest.files.map(\.path)), Set(publication.manifest.files.map(\.path)))
        XCTAssertEqual(Set(extraction.manifest.directories.map(\.value)),
                       Set(publication.manifest.directories.map(\.value)))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("data.json")),
                       try Data(contentsOf: source.appendingPathComponent("data.json")))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Assets/blob.bin")),
                       Data([0, 255, 1, 2, 0, 0, 7]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Assets/Empty").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.appendingPathComponent("tools/run.sh").path))
        // Re-export of the imported tree must be byte-stable in manifest.
        let zip2 = fixture.root.appendingPathComponent("out2.zip")
        let publication2 = try exchange.archive(directory: target, to: zip2)
        XCTAssertEqual(publication2.manifest, publication.manifest)
    }

    func testRejectsTraversalAbsoluteBackslashAndDuplicateEntries() throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let cases: [(String, [GameTestZIPCraft.Entry], GameArchiveError)] = [
            ("traversal", [.entry("a/../../escape.txt", data: Data("x".utf8))], .unsafeEntryPath("a/../../escape.txt")),
            ("absolute", [.entry("/etc/passwd", data: Data("x".utf8))], .unsafeEntryPath("/etc/passwd")),
            ("backslash", [.entry("a\\b.txt", data: Data("x".utf8))], .unsafeEntryPath("a\\b.txt")),
            ("dotdot", [.entry("..", data: Data("x".utf8))], .unsafeEntryPath("..")),
            ("duplicate", [.entry("a.txt", data: Data("1".utf8)), .entry("a.txt", data: Data("2".utf8))], .duplicateEntry("a.txt")),
            ("case", [.entry("A.txt", data: Data("1".utf8)), .entry("a.txt", data: Data("2".utf8))], .caseCollision("a.txt")),
            ("symlink", [.entry("link", data: Data("/tmp".utf8), symlink: true)], .symlinkEntry("link")),
        ]
        for (label, entries, expected) in cases {
            let url = fixture.root.appendingPathComponent("attack-\(label).zip")
            try GameTestZIPCraft.makeZIP(entries).write(to: url)
            XCTAssertThrowsError(try GameArchiveExchange().extract(archive: url,
                                                                   to: fixture.root.appendingPathComponent("target-\(label)"))) { error in
                XCTAssertEqual(error as? GameArchiveError, expected, label)
            }
        }
    }

    func testRejectsAncestorCollisionFileVersusDirectory() throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("ancestor.zip")
        let zip = GameTestZIPCraft.makeZIP([
            .entry("a", data: Data("file".utf8)),
            .entry("a/b.txt", data: Data("nested".utf8)),
        ])
        try zip.write(to: url)
        XCTAssertThrowsError(try GameArchiveExchange().extract(archive: url,
                                                               to: fixture.root.appendingPathComponent("target-ancestor"))) { error in
            XCTAssertEqual(error as? GameArchiveError, .ancestorCollision("a/b.txt"))
        }
    }

    func testRejectsCorruptCRCAndHonorsLimits() throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let badCRC = fixture.root.appendingPathComponent("badcrc.zip")
        try GameTestZIPCraft.makeZIP([.entry("a.txt", data: Data("hello".utf8), corruptCRC: true)]).write(to: badCRC)
        XCTAssertThrowsError(try GameArchiveExchange().extract(archive: badCRC,
                                                               to: fixture.root.appendingPathComponent("t1"))) { error in
            XCTAssertEqual(error as? GameArchiveError, .checksumMismatch("a.txt"))
        }
        let limited = try GameArchiveExchange(limits: GameArchiveExchangeLimits(maximumFileBytes: 8,
                                                                                maximumProjectBytes: 64,
                                                                                maximumEntries: 16))
        let big = fixture.root.appendingPathComponent("big.zip")
        try GameTestZIPCraft.makeZIP([.entry("big.bin", data: Data(count: 32))]).write(to: big)
        XCTAssertThrowsError(try limited.extract(archive: big, to: fixture.root.appendingPathComponent("t2"))) { error in
            XCTAssertEqual(error as? GameArchiveError, .fileLimitExceeded("big.bin"))
        }
        let many = fixture.root.appendingPathComponent("many.zip")
        try GameTestZIPCraft.makeZIP((0..<20).map { .entry("f\($0).txt", data: Data("x".utf8)) }).write(to: many)
        XCTAssertThrowsError(try limited.extract(archive: many, to: fixture.root.appendingPathComponent("t3"))) { error in
            XCTAssertEqual(error as? GameArchiveError, .entryLimitExceeded(16))
        }
    }

    func testNeverOverwritesExistingDestination() throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let source = try fixture.project()
        let exchange = GameArchiveExchange()
        let zipURL = fixture.root.appendingPathComponent("dup.zip")
        _ = try exchange.archive(directory: source, to: zipURL)
        XCTAssertThrowsError(try exchange.archive(directory: source, to: zipURL)) { error in
            XCTAssertEqual(error as? GameArchiveError, .destinationExists("dup.zip"))
        }
        let target = fixture.root.appendingPathComponent("exists")
        try Data("occupied".utf8).write(to: target)
        XCTAssertThrowsError(try exchange.extract(archive: zipURL, to: target)) { error in
            XCTAssertEqual(error as? GameArchiveError, .destinationExists("exists"))
        }
        // The failed import must not have disturbed the destination.
        XCTAssertEqual(try Data(contentsOf: target), Data("occupied".utf8))
    }

    func testRootChoiceIsExplicitAndStripsOnlyTheNamedContainer() throws {
        let fixture = try GameArchiveFixture()
        defer { fixture.cleanup() }
        let url = fixture.root.appendingPathComponent("wrapped.zip")
        try GameTestZIPCraft.makeZIP([
            .entry("MyGame/data.json", data: Data("{}".utf8)),
            .entry("MyGame/README.md", data: Data("readme".utf8)),
        ]).write(to: url)
        let exchange = GameArchiveExchange()
        let listing = try exchange.inspect(archive: url)
        XCTAssertEqual(listing.topLevelNames, ["MyGame"])
        XCTAssertEqual(listing.rootCandidates.first?.name, "MyGame")
        // asIs keeps the container directory.
        let flat = try exchange.extract(archive: url, to: fixture.root.appendingPathComponent("flat"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: flat.rootURL.appendingPathComponent("MyGame/data.json").path))
        // Explicit container choice strips the prefix.
        let stripped = try exchange.extract(archive: url, to: fixture.root.appendingPathComponent("stripped"),
                                            rootChoice: .container("MyGame"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stripped.rootURL.appendingPathComponent("data.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stripped.rootURL.appendingPathComponent("MyGame").path))
        // Unknown containers and sneaky names are rejected, never auto-selected.
        for bad in ["Other", "MyGame/..", ".", ""] {
            XCTAssertThrowsError(try exchange.extract(archive: url,
                                                      to: fixture.root.appendingPathComponent("bad-\(bad.count)-\(bad.hashValue)"),
                                                      rootChoice: .container(bad))) { error in
                XCTAssertEqual(error as? GameArchiveError, .invalidRootChoice(bad))
            }
        }
        // An explicit container choice keeps only that subtree; entries outside
        // it are excluded by that explicit action (the whole-tree import
        // default never prunes anything).
        let mixed = fixture.root.appendingPathComponent("mixed.zip")
        try GameTestZIPCraft.makeZIP([
            .entry("Wrap/game.js", data: Data("1".utf8)),
            .entry("game.js", data: Data("2".utf8)),
        ]).write(to: mixed)
        let mixedOut = try exchange.extract(archive: mixed,
                                            to: fixture.root.appendingPathComponent("mixed-out"),
                                            rootChoice: .container("Wrap"))
        XCTAssertEqual(mixedOut.manifest.files.map(\.path.value), ["game.js"])
    }
}
