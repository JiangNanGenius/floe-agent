// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import Foundation
import FloeGameCore
import FloeGameBuildKit
@testable import FloeApp

/// Source regression portfolio for archive authority/bounds and route-aware
/// build readiness. These tests are NOT executed in this source-only task.
final class GameArchiveAndBuildContractTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-game-archive-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func authority() -> GameArchiveRunAuthority {
        .init(runID: UUID(), conversationID: UUID(), environmentID: nil,
              executionBindingGeneration: nil)
    }

    func testCapabilitiesAreExactAndRARNeedsTheSignedHandler() async {
        let fixed = authority()
        let withoutRAR = MainGameExternalArchiveHost(
            root: FileManager.default.temporaryDirectory,
            authority: { fixed }, compressedHandler: nil)
        let values = await withoutRAR.capabilities()
        XCTAssertTrue(values.contains(.sevenZip))
        XCTAssertFalse(values.contains(.rar))
        XCTAssertEqual(values, [.zip, .tar, .tarGzip, .tarBzip2, .tarXz, .sevenZip])

        let withRAR = MainGameExternalArchiveHost(
            root: FileManager.default.temporaryDirectory,
            authority: { fixed }, compressedHandler: { _ in "{}" })
        let all = await withRAR.capabilities()
        XCTAssertTrue(all.contains(.rar))
    }

    func testDestinationMustNotExistBeforeAuthorityOrExtraction() async throws {
        let root = try temporaryDirectory()
        let destination = root.appendingPathComponent("tree", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let archive = root.appendingPathComponent("game.zip")
        try Data("not a real zip".utf8).write(to: archive)
        let fixed = authority()
        let host = MainGameExternalArchiveHost(root: root,
            authority: { XCTFail("authority must not be resolved for an existing destination"); return fixed })
        let request = GameExternalArchiveRequest(
            archiveURL: archive, format: .zip, destination: destination,
            maximumBytes: 1_024, maximumEntries: 10)
        do {
            try await host.extract(request)
            XCTFail("expected destinationExists")
        } catch let error as GameExternalArchiveError {
            XCTAssertEqual(error, .destinationExists)
        }
    }

    func testOutsideRootArchiveIsRejectedBeforeAuthority() async throws {
        let root = try temporaryDirectory()
        let outside = try temporaryDirectory()
        let archive = outside.appendingPathComponent("game.zip")
        try Data("not a real zip".utf8).write(to: archive)
        let fixed = authority()
        let host = MainGameExternalArchiveHost(root: root,
            authority: { XCTFail("authority must not be resolved for an escaping path"); return fixed })
        let request = GameExternalArchiveRequest(
            archiveURL: archive, format: .zip,
            destination: root.appendingPathComponent("tree", isDirectory: true),
            maximumBytes: 1_024, maximumEntries: 10)
        do {
            try await host.extract(request)
            XCTFail("expected insecureTree")
        } catch let error as GameExternalArchiveError {
            guard case .insecureTree = error else {
                return XCTFail("expected insecureTree, got \(error)")
            }
        }
    }

    func testPasswordProtectedArchiveIsRejectedHonestly() async throws {
        let root = try temporaryDirectory()
        let archive = root.appendingPathComponent("game.zip")
        try Data("not a real zip".utf8).write(to: archive)
        let fixed = authority()
        let host = MainGameExternalArchiveHost(root: root,
            authority: { fixed })
        let request = GameExternalArchiveRequest(
            archiveURL: archive, format: .zip,
            destination: root.appendingPathComponent("tree", isDirectory: true),
            maximumBytes: 1_024, maximumEntries: 10, password: "secret")
        do {
            try await host.extract(request)
            XCTFail("expected a refusal")
        } catch let error as GameExternalArchiveError {
            guard case .hostFailed(let detail) = error else {
                return XCTFail("expected hostFailed, got \(error)")
            }
            XCTAssertTrue(detail.contains("Password"))
        }
    }

    func testRouteAwareReadinessDoesNotGateConditionalNodeForStaticWeb() throws {
        let catalog = try GameBuildCatalogLoader.load()
        guard let phaser = catalog.engines.first(where: { $0.engine == .phaser }) else {
            return XCTFail("phaser catalog entry missing")
        }
        let required = GameBuildToolReadiness.requiredToolIDs(
            routes: phaser.routes, selectedRouteIDs: ["phaser-web"])
        XCTAssertTrue(required.isEmpty)
        XCTAssertFalse(required.contains("node-lts"))
    }

    func testCIProvidedToolsCoverEveryCIRequirement() throws {
        let catalog = try GameBuildCatalogLoader.load()
        for engine in catalog.engines {
            for route in engine.routes where route.producer == .ci {
                for tool in route.requires {
                    XCTAssertTrue(GameBuildToolReadiness.ciProvidedToolIDs.contains(tool),
                        "\(engine.engine.rawValue) \(route.id) requires unlisted \(tool)")
                }
            }
        }
    }

    func testWASM4JobsInstallTheirDeclaredCLIBeforeBundling() throws {
        let catalog = try GameBuildCatalogLoader.load()
        let engine = try XCTUnwrap(catalog.engines.first { $0.engine == .wasm4 })
        let cli = try XCTUnwrap(engine.prerequisites.first { $0.tool.id == "wasm4-cli" })
        let template = try XCTUnwrap(GameCIWorkflowTemplates.template(for: .wasm4))
        XCTAssertTrue(template.yaml.contains("FLOE_WASM4_VERSION: \"\(cli.tool.version)\""))
        XCTAssertEqual(Set(template.targets.map(\.job)), ["web", "native"])
        for target in template.targets {
            let header = try XCTUnwrap(template.yaml.range(of: "\n  \(target.job):\n"))
            let job = template.yaml[header.upperBound...].split(separator: "\n")
                .prefix { $0.hasPrefix("    ") }.joined(separator: "\n")
            var remaining = job[...]
            for step in ["w4-linux.zip", "sha256sum --check", "unzip -p",
                         "\"$tool_dir/w4\" --version", "\"$GITHUB_PATH\"", "w4 bundle"] {
                let match = try XCTUnwrap(remaining.range(of: step), "\(target.job) requires \(step)")
                remaining = remaining[match.upperBound...]
            }
        }
    }

    func testUnityWebRouteStillRequiresEditorAndWebGLModule() throws {
        let catalog = try GameBuildCatalogLoader.load()
        guard let unity = catalog.engines.first(where: { $0.engine == .unity }) else {
            return XCTFail("unity catalog entry missing")
        }
        let required = GameBuildToolReadiness.requiredToolIDs(
            routes: unity.routes, selectedRouteIDs: ["unity-web"])
        XCTAssertEqual(required, ["unity-editor", "unity-webgl-module"])
    }
}
#endif
