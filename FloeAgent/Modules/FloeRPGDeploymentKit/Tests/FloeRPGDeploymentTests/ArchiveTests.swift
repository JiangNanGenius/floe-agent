// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import Darwin
import Testing
import FloeGameCore
import FloeRPGCore
@testable import FloeRPGDeployment

struct WireManifest: Decodable {
    struct Archive: Decodable {
        struct File: Decodable { let path: String; let rawNameBase64: String; let bytes: Int; let sha256: String }
        let engine: String; let version: Int; let archive: String; let sha256: String; let files: [File]
    }
    let archives: [Archive]
}

func fixture(_ path: String = "") -> URL {
    Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent(path)
}
func testDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-rpg-deploy-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}
func sha(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

@Suite struct ArchiveTests {
    @Test func compiledModuleRetainsOriginalCopyrightAndFullLicenseTexts() throws {
        let licenses = try RPGDeploymentLicenses.documents()
        let mit = try #require(licenses["RPGMakerDecrypter-MIT"])
        #expect(sha(Data(mit.utf8)) == "e0506d6306bb0895f7a9dd3a1b701c3b7e97377be12dc0870b60698fe5fa15a5")
        #expect(mit.contains("Mikko Uuksulainen"))
        #expect(licenses["MPL-2.0"]?.contains("Source Code Form") == true)
    }

    @Test func allThreeGenerationsMatchIndependentGoldensAndOriginals() throws {
        let manifest = try JSONDecoder().decode(WireManifest.self, from: Data(contentsOf: fixture("manifest.json")))
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for expected in manifest.archives {
            let source = fixture(expected.archive), before = try Data(contentsOf: source)
            let index = try RGSSArchive.inspect(at: source)
            #expect(index.version == expected.version)
            #expect(index.entries.map(\.path.value) == expected.files.map(\.path))
            #expect(index.entries.map { $0.originalNameBytes.base64EncodedString() } == expected.files.map(\.rawNameBase64))
            let extracted = try RGSSArchive.extract(at: source, to: root.appendingPathComponent(expected.engine))
            #expect(extracted.originalArchivePreserved)
            for file in expected.files {
                let bytes = try Data(contentsOf: extracted.output.appendingPathComponent(file.path))
                #expect(bytes.count == file.bytes)
                #expect(sha(bytes) == file.sha256)
                #expect(try bytes == Data(contentsOf: fixture("plain/" + expected.engine + "/" + file.path)))
            }
            #expect(try Data(contentsOf: source) == before)
            #expect(sha(before) == expected.sha256)
        }
    }

    @Test func decodedOriginalMapsOpenAndRoundTripInActualRPGCodecs() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for (archive, engine, map) in [("xp.rgssad", RPGEngine.rpgMakerXP, "Data/Map001.rxdata"),
                                        ("vx.rgss2a", RPGEngine.rpgMakerVX, "Data/Map002.rvdata"),
                                        ("ace.rgss3a", RPGEngine.rpgMakerVXAce, "Data/Map003.rvdata2")] {
            let extracted = try RGSSArchive.extract(at: fixture(archive), to: root.appendingPathComponent(archive))
            let bytes = try Data(contentsOf: extracted.output.appendingPathComponent(map))
            let document = try RPGMapDocument.decode(bytes, engine: engine, pathName: map)
            #expect(document.width > 0 && document.height > 0)
            #expect(try document.encode() == bytes)
        }
    }

    @Test func traversalAbsoluteCaseAndFileDirectoryCollisionsNeverPublish() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for version in [1, 3] {
            for kind in ["traversal", "absolute", "collision", "prefix-file"] {
                let output = root.appendingPathComponent("v\(version)-\(kind)")
                #expect(throws: (any Error).self) { try RGSSArchive.extract(at: fixture("bad-v\(version)-\(kind).bin"), to: output) }
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.txt").path))
    }

    @Test func boundedCountsBytesAndNames() throws {
        let source = fixture("xp.rgssad")
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: source, limits: RPGDeploymentLimits(maximumFiles: 1)) }
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: source, limits: RPGDeploymentLimits(maximumEntryBytes: 64)) }
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: source, limits: RPGDeploymentLimits(maximumEntryBytes: 131_079, maximumTotalBytes: 131_079)) }
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: source, limits: RPGDeploymentLimits(maximumArchiveBytes: 32)) }
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: source, limits: RPGDeploymentLimits(maximumNameBytes: 4)) }
    }

    @Test func badHeadersVersionTruncatedIndexAndBodies() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        var original = try Data(contentsOf: fixture("ace.rgss3a"))
        for count in [0, 7, 8, 12, 30, original.count - 1] {
            let source = root.appendingPathComponent("truncated-\(count)")
            try original.prefix(count).write(to: source)
            #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: source) }
        }
        original[7] = 2
        let bad = root.appendingPathComponent("version2"); try original.write(to: bad)
        #expect(throws: RPGDeploymentError.unsupportedVersion(2)) { try RGSSArchive.inspect(at: bad) }
        original[0] = 0; try original.write(to: bad)
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: bad) }
    }

    @Test func aceOverlappingIndexAndEntriesRejected() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try Data(contentsOf: fixture("ace.rgss3a"))
        let key: UInt32 = 0x12345678 &* 9 &+ 3
        func word(_ bytes: Data, _ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) } }
        func set(_ bytes: inout Data, _ offset: Int, _ value: UInt32) {
            for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> UInt32(i * 8)) }
        }
        var inIndex = original; set(&inIndex, 12, 20 ^ key)
        let source = root.appendingPathComponent("index"); try inIndex.write(to: source)
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: source) }
        let next = 28 + Int(word(original, 24) ^ key)
        var overlap = original; set(&overlap, next, word(original, 12))
        try overlap.write(to: source)
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: source) }
    }

    @Test func existingOutputAndSymlinkSourceRefused() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("existing")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: target.appendingPathComponent("original.txt"))
        #expect(throws: RPGDeploymentError.destinationExists) { try RGSSArchive.extract(at: fixture("xp.rgssad"), to: target) }
        #expect(try String(contentsOf: target.appendingPathComponent("original.txt"), encoding: .utf8) == "keep")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture("xp.rgssad"))
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: link) }
    }

    @Test func cancellationDoesNotPublishPartialResult() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncStream<Void>.makeStream()
        let destination = root.appendingPathComponent("cancelled")
        let task = Task {
            for await _ in gate.stream { break }
            return try RGSSArchive.extract(at: fixture("xp.rgssad"), to: destination)
        }
        task.cancel(); gate.continuation.finish()
        do { _ = try await task.value; Issue.record("Cancelled import published a successful result") }
        catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func fifoInputIsRejectedWithoutOpeningAWriter() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("not-an-archive")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try RGSSArchive.inspect(at: fifo) }
    }
}

@Suite struct MediaTests {
    @Test func allMVAndMZExtensionsMatchKnownPlaintext() throws {
        for engine in ["mv", "mz"] {
            let system = try Data(contentsOf: fixture("media/\(engine)/data/System.json"))
            for (encryptedExtension, plainExtension, folder) in [(engine == "mv" ? "rpgmvp" : "png_", "png", "img/pictures"),
                                                               (engine == "mv" ? "rpgmvo" : "ogg_", "ogg", "audio/bgm"),
                                                               (engine == "mv" ? "rpgmvm" : "m4a_", "m4a", "audio/bgm")] {
                let path = try GameRelativePath(folder + "/original." + encryptedExtension)
                let decodedPath = try RPGEncryptedMedia.plaintextPath(for: path)
                let plainPath = try #require(decodedPath)
                #expect(plainPath.value == folder + "/original." + plainExtension)
                let encrypted = try Data(contentsOf: fixture("media/\(engine)/" + path.value))
                let decoded = try RPGEncryptedMedia.decode(encrypted, systemJSON: system)
                #expect(try decoded == Data(contentsOf: fixture("plain-media/\(engine)/" + plainPath.value)))
                try RPGEncryptedMedia.validatePlaintext(decoded, path: plainPath)
            }
        }
    }

    @Test func keyHeaderTruncationAndWrongKeyRemainExplicit() throws {
        let encrypted = try Data(contentsOf: fixture("media/mv/img/pictures/original.rpgmvp"))
        let system = try Data(contentsOf: fixture("media/mv/data/System.json"))
        #expect(throws: RPGDeploymentError.missingMediaKey) { try RPGEncryptedMedia.decode(encrypted, systemJSON: Data("{}".utf8)) }
        #expect(throws: RPGDeploymentError.invalidMediaKey) { try RPGEncryptedMedia.decode(encrypted, systemJSON: Data("{\"encryptionKey\":\"invalid\"}".utf8)) }
        #expect(throws: RPGDeploymentError.invalidMediaHeader) { try RPGEncryptedMedia.decode(encrypted.prefix(31), systemJSON: system) }
        var invalid = encrypted; invalid[1] = 0
        #expect(throws: RPGDeploymentError.invalidMediaHeader) { try RPGEncryptedMedia.decode(invalid, systemJSON: system) }
        #expect(throws: (any Error).self) { try RPGEncryptedMedia.decode(encrypted, systemJSON: system, maximumBytes: 32) }
        let wrong = try RPGEncryptedMedia.decode(encrypted, systemJSON: Data("{\"encryptionKey\":\"ffffffffffffffffffffffffffffffff\"}".utf8))
        #expect(throws: RPGDeploymentError.invalidMediaKey) { try RPGEncryptedMedia.validatePlaintext(wrong, path: GameRelativePath("image.png")) }
    }
}
