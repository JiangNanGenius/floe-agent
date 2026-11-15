// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import CryptoKit
import FloeGameCore
import FloeGameTouch
@testable import FloeGameStarterKit

final class StarterCatalogTests: XCTestCase {
    func testExactlyTwentyDistinctEnginesAndValidDescriptors() throws {
        let catalog = try GameStarterCatalog.bundled()
        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.catalogVersion, "1.0.0")
        XCTAssertEqual(catalog.engines.count, 20)
        XCTAssertEqual(Set(catalog.engines.map(\.engine)), Set(GameEngineID.allCases))
        for descriptor in catalog.engines {
            XCTAssertEqual(descriptor.defaultInput.engine, descriptor.engine)
            XCTAssertFalse(descriptor.displayName.isEmpty)
            XCTAssertFalse(descriptor.entry.value.isEmpty)
            XCTAssertTrue(descriptor.expectedFiles.contains(descriptor.entry))
            XCTAssertFalse(descriptor.sourceLicense.isEmpty)
            XCTAssertFalse(descriptor.engineLicense.isEmpty)
            XCTAssertFalse(descriptor.prerequisites.isEmpty, descriptor.engine.rawValue)
            XCTAssertNoThrow(try descriptor.defaultInput.validate(), descriptor.engine.rawValue)
            if let web = descriptor.webEntry {
                XCTAssertFalse(web.value.isEmpty)
            }
            if descriptor.templateKind == .static {
                XCTAssertNotNil(descriptor.templateRoot)
                XCTAssertFalse(descriptor.files.isEmpty)
                XCTAssertEqual(Set(descriptor.files.map(\.path)), Set(descriptor.expectedFiles))
            }
            if descriptor.templateKind == .runtimePack {
                XCTAssertNotNil(descriptor.runtimePack)
                XCTAssertEqual(descriptor.readiness, .runtimePackRequired)
            }
        }
    }

    func testStaticTemplatesMatchCatalogHashes() throws {
        let catalog = try GameStarterCatalog.bundled()
        try catalog.verifyBundledStaticTemplates()
        for descriptor in catalog.engines where descriptor.templateKind == .static {
            guard let root = catalog.staticTemplateURL(for: descriptor) else {
                XCTFail("missing template root \(descriptor.engine.rawValue)"); continue
            }
            for file in descriptor.files {
                let url = root.appendingPathComponent(file.path.value)
                let data = try Data(contentsOf: url)
                XCTAssertEqual(data.count, file.bytes, file.path.value)
                XCTAssertEqual(sha256(data), file.sha256, file.path.value)
            }
        }
    }

    func testManifestIsDeterministicAndCatalogRecognitionUsesCandidates() throws {
        let catalog = try GameStarterCatalog.bundled()
        let first = try catalog.manifest()
        let second = try catalog.manifest()
        XCTAssertEqual(first, second)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("\"engines\""))
        let path = try GameRelativePath("Game.ini")
        let packagePath = try GameRelativePath("package.json")
        let evidence = GameEngineEvidence(path: path, kind: .projectMarker)
        let inspection = GameProjectInspection(
            rootURL: URL(fileURLWithPath: "/tmp/floe-catalog-probe"),
            context: nil,
            candidates: [GameEngineCandidate(engine: .rpgMakerVX, evidence: [evidence]),
                         GameEngineCandidate(engine: .phaser,
                                             evidence: [GameEngineEvidence(
                                                path: packagePath,
                                                kind: .packageDependency)])],
            inspectedPaths: [path])
        XCTAssertEqual(catalog.recognizedEngine(in: inspection), .rpgMakerVX)
        XCTAssertEqual(catalog.recognizedEngine(in: inspection, preferred: .phaser), .phaser)
        XCTAssertNil(catalog.recognizedEngine(in: inspection, preferred: .unity))
    }

    func testDefaultInputDeclarationsMatchTheSharedValidator() throws {
        let catalog = try GameStarterCatalog.bundled()
        for descriptor in catalog.engines {
            let data = try descriptor.defaultInput.encoded()
            XCTAssertLessThanOrEqual(data.count, GameTouchProjectBindings.maximumDeclarationBytes)
            XCTAssertNoThrow(try GameTouchProjectBindings(json: data, engine: descriptor.engine))
            let keys = descriptor.defaultInput.movement.left
                + descriptor.defaultInput.movement.right
                + descriptor.defaultInput.movement.up
                + descriptor.defaultInput.movement.down
                + descriptor.defaultInput.buttons.flatMap(\.keys)
            XCTAssertTrue(keys.allSatisfy { !$0.isEmpty })
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
