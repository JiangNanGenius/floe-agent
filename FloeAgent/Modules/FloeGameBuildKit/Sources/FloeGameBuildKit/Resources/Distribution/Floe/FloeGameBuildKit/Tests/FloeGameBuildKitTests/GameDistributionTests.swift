// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameBuildKit

final class GameDistributionTests: XCTestCase {
    private struct SourceProvider: GameDistributionPairedSourceProvider {
        let resolution: GameDistributionPairedSourceResolution
        func resolve(_ artifactID: String) async throws -> GameDistributionPairedSourceResolution? { resolution }
    }

    private func pairedFixture(_ bytes: Data) throws -> GameDistributionProfile {
        let object: [String: Any] = ["id": "original-test-source-profile",
            "distributionClass": "pairedSource", "exportReadiness": "readyWithPairedSource",
            "embeddedNotices": ["Distribution/Notices/floe/MPL-2.0.txt"],
            "pairedSources": [["id": "original-source-fixture", "role": "Synthetic test source",
                "sha256": GameDigest.sha256(bytes), "bytes": bytes.count,
                "requiredForDistribution": true]]]
        return try JSONDecoder().decode(GameDistributionProfile.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    func testResolvedSourceTravelsInsideExportAfterOriginalCacheIsRemoved() async throws {
        let bytes = Data("Original synthetic corresponding-source fixture".utf8)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: source)
        let contentRoot = try content()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: contentRoot)
                try? FileManager.default.removeItem(at: output) }
        let provider = SourceProvider(resolution: .init(url: source, sha256: GameDigest.sha256(bytes), bytes: bytes.count))
        let receipt = try await GameDistributionBundle.build(profile: pairedFixture(bytes), engine: .tic80,
            contentRoot: contentRoot, outputURL: output, environment: .init(pairedProvider: provider))
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(receipt.distributionReady)
        let record = try XCTUnwrap(receipt.pairedSources.first)
        let relative = try XCTUnwrap(record.sourceFile)
        XCTAssertTrue(relative.hasPrefix("sources/third-party/"))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent(relative)), bytes)
        XCTAssertEqual(receipt.files[relative], GameDigest.sha256(bytes))
        let records = try JSONSerialization.jsonObject(with: Data(contentsOf:
            output.appendingPathComponent("PAIRED-SOURCE.json"))) as? [String: Any]
        XCTAssertEqual((records?["pairedSources"] as? [[String: Any]])?.first?["sourceFile"] as? String, relative)
    }

    func testChangedPairedSourceNeverPublishesAReadyExport() async throws {
        let expected = Data("Original expected source fixture".utf8)
        let changed = Data("Original tampered source fixture".utf8)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try changed.write(to: source)
        let contentRoot = try content()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source)
                try? FileManager.default.removeItem(at: contentRoot)
                try? FileManager.default.removeItem(at: output) }
        let provider = SourceProvider(resolution: .init(url: source,
            sha256: GameDigest.sha256(expected), bytes: expected.count))
        do {
            _ = try await GameDistributionBundle.build(profile: pairedFixture(expected), engine: .tic80,
                contentRoot: contentRoot, outputURL: output, environment: .init(pairedProvider: provider))
            XCTFail("changed corresponding source must fail closed")
        } catch { XCTAssertEqual(error as? GameDistributionError, .pairedSourceMismatch("original-source-fixture")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private func content() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>user game</title>".utf8)
            .write(to: root.appendingPathComponent("index.html"))
        try Data("user asset".utf8).write(to: root.appendingPathComponent("game.js"))
        try Data("original user license".utf8).write(to: root.appendingPathComponent("LICENSE-game.txt"))
        return root
    }

    func testSelfContainedProfileCarriesNoticesReadableSourceAndUserTerms() async throws {
        let profile = try GameDistributionProfileCatalog.profile(id: "narrative-ink")
        let contentRoot = try content()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let receipt = try await GameDistributionBundle.build(
            profile: profile, engine: .ink, contentRoot: contentRoot, outputURL: output,
            environment: .init())
        XCTAssertTrue(receipt.distributionReady)
        XCTAssertFalse(receipt.appStoreApprovalClaimed)
        XCTAssertFalse(receipt.writtenOfferCreated)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("licenses/narrative/ink/LICENSE.inkjs.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("sources/floe/FloeGameBuildKit/LICENSE").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("sources/floe/FloeGameBuildKit/Sources/FloeGameBuildKit/GameBuildCapabilities.swift").path))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("content/game.js")),
                       Data("user asset".utf8))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("user-content-notices/LICENSE-game.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("content/MPL-2.0.txt").path))
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: output.appendingPathComponent("bundle-manifest.json"))) as? [String: Any]
        XCTAssertEqual(manifest?["distributionReady"] as? Bool, true)
        XCTAssertNotNil(manifest?["files"])
        let files = try XCTUnwrap(manifest?["files"] as? [String: String])
        XCTAssertFalse(files.isEmpty)
        XCTAssertFalse(files.keys.contains { $0.hasPrefix("/") || $0.contains("../") })
        XCTAssertNotNil(files["user-content-notices/LICENSE-game.txt"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("user-content-notices/LICENSE-game.txt")),
                       Data("original user license".utf8))
    }

    func testPairedProfileIsConditionalForPrivatePlaybackAndFailsClosedForDistribution() async throws {
        let profile = try GameDistributionProfileCatalog.profile(id: "portable-love")
        let contentRoot = try content()
        let privateOutput = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let receipt = try await GameDistributionBundle.build(
            profile: profile, engine: .love, contentRoot: contentRoot, outputURL: privateOutput,
            environment: .init(pairedProvider: nil, mode: .privatePlayback))
        XCTAssertFalse(receipt.distributionReady)
        XCTAssertNotNil(receipt.conditionalReason)
        XCTAssertTrue(receipt.pairedSources.contains { !$0.resolved })

        let distributionOutput = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await GameDistributionBundle.build(
                profile: profile, engine: .love, contentRoot: contentRoot, outputURL: distributionOutput,
                environment: .init(pairedProvider: nil, mode: .distribution))
            XCTFail("distribution mode must fail closed without the paired source")
        } catch let error as GameDistributionError {
            if case .missingPairedSource = error {} else { XCTFail("unexpected error: \(error)") }
        }
    }

    func testDestinationAndEmptyContentAreRejected() async throws {
        let profile = try GameDistributionProfileCatalog.profile(id: "narrative-ink")
        let contentRoot = try content()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        do {
            _ = try await GameDistributionBundle.build(
                profile: profile, engine: .ink, contentRoot: contentRoot, outputURL: output,
                environment: .init())
            XCTFail("existing destination must be refused")
        } catch let error as GameDistributionError {
            XCTAssertEqual(error, .destinationExists)
        }
    }
}
