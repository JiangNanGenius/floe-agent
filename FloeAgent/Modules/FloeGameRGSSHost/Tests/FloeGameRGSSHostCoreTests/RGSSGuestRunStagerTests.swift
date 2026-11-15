// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import XCTest
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore
import FloeRPGCore

final class RGSSGuestRunStagerTests: XCTestCase {
    func testStageCopiesSourceAndNeverMutatesOriginals() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        let request = try RGSSGuestRunRequest(
            workspaceID: UUID(), context: context, engine: .rpgMakerXP,
            displayServiceID: "display-1")
        let before = try RGSSGuestSafeTreeDigestProbe.digest(source)
        let staged = try await RGSSGuestTestSupport.staged(request)
        let after = try RGSSGuestSafeTreeDigestProbe.digest(source)

        XCTAssertEqual(before, after, "the imported source must stay byte-identical")
        XCTAssertNotEqual(staged.runRoot.path, source.path)
        XCTAssertFalse(staged.runRoot.path.hasPrefix(source.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.runRoot.appendingPathComponent("Data/Scripts.rxdata").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.runRoot.appendingPathComponent("Game.rgssad").path),
            "encrypted archive bytes are preserved")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.runRoot.appendingPathComponent("RGSS104E.dll").path),
            "native DLL bytes are preserved, never executed")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: staged.runRoot.appendingPathComponent("Plugins/custom.rb").path),
            "unknown/plugin files are preserved")
        XCTAssertEqual(staged.importedSaveNames, [])
        XCTAssertEqual(staged.sourceDigest.count, 64)
    }

    func testStageExcludesAdministrativeVCSFromRunCopyOnly() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        try RGSSGuestTestSupport.write("secret", to: source.appendingPathComponent(".git/config"))
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        let request = try RGSSGuestRunRequest(
            workspaceID: UUID(), context: context, engine: .rpgMakerXP,
            displayServiceID: "display-1")
        let staged = try await RGSSGuestTestSupport.staged(request)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: staged.runRoot.appendingPathComponent(".git").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: source.appendingPathComponent(".git/config").path),
            "the administrative bytes remain in the source")
    }

    func testSourceSymlinkIsRejected() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        let outside = try RGSSGuestTestSupport.temporaryDirectory("rgss-outside")
        let target = outside.appendingPathComponent("bytes")
        try Data("outside".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("linked.bin"),
            withDestinationURL: target)
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        let request = try RGSSGuestRunRequest(
            workspaceID: UUID(), context: context, engine: .rpgMakerXP,
            displayServiceID: "display-1")
        do {
            _ = try await RGSSGuestTestSupport.staged(request)
            XCTFail("a symlink must not be copied")
        } catch let error as RGSSGuestRunError {
            if case .unsafeSourceEntry = error { return }
            XCTFail("unexpected error \(error)")
        }
    }

    func testSaveLayerIsStagedIntoRunAndCollectedBack() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        let request = try RGSSGuestRunRequest(
            workspaceID: UUID(), context: context, engine: .rpgMakerXP,
            displayServiceID: "display-1")
        let base = try RGSSGuestTestSupport.temporaryDirectory("rgss-save-runs")
        let stager = RGSSGuestRunStager(layout: try RGSSGuestRunLayout(baseDirectory: base))
        let staged = try await stager.stage(request)
        let store = try RGSSGuestSaveStore(root: staged.saveRoot, engine: .rpgMakerXP,
                                           sourceRoot: source)
        try store.write(Data("save-one".utf8), name: "Save1.rxdata")

        // A second stage at the same identity drains the old run copy and
        // imports the persistent save into the new copy.
        let second = try await stager.stage(request)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: second.runRoot.appendingPathComponent("Save1.rxdata").path))
        try Data("save-two".utf8).write(
            to: second.runRoot.appendingPathComponent("Save1.rxdata"))
        let result = try await stager.collectSaves(from: second)
        XCTAssertEqual(result.names, ["Save1.rxdata"])
        XCTAssertEqual(try store.read("Save1.rxdata"), Data("save-two".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: source.appendingPathComponent("Save1.rxdata").path),
            "saves never appear in the immutable source")
    }

    func testEngineMismatchFailsWithoutOverride() async throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject(engine: .rpgMakerXP)
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        let request = try RGSSGuestRunRequest(
            workspaceID: UUID(), context: context, engine: .rpgMakerVX,
            displayServiceID: "display-1")
        do {
            _ = try await RGSSGuestTestSupport.staged(request)
            XCTFail("engine mismatch must fail")
        } catch let error as RGSSGuestRunError {
            guard case .engineMismatch(let detected, let requested) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(detected, .rpgMakerXP)
            XCTAssertEqual(requested, .rpgMakerVX)
        }
    }

    func testInvalidRelativeRootIsRejected() throws {
        let projectID = UUID()
        let owner = RGSSGuestTestOwner.space(projectID)
        let source = try RGSSGuestTestSupport.makeProject()
        let context = try RGSSGuestTestSupport.context(for: projectID, owner: owner, root: source)
        XCTAssertThrowsError(try RGSSGuestRunRequest(
            workspaceID: UUID(), context: context, engine: .rpgMakerXP,
            rootRelative: "../escape", displayServiceID: "display-1"))
    }
}

enum RGSSGuestSafeTreeDigestProbe {
    static func digest(_ url: URL) throws -> String {
        // Public package helper is internal; tests exercise the same contract
        // through the stager's plan where possible. This probe keeps a local
        // bounded digest of the exact test tree.
        var hasher = SHA256()
        let names = try FileManager.default.subpathsOfDirectory(atPath: url.path).sorted()
        for name in names {
            let full = url.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue { hasher.update(data: Data(("D:" + name).utf8)); continue }
            let data = try Data(contentsOf: full)
            hasher.update(data: Data(("F:" + name + ":").utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
