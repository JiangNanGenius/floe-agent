// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameNarrativeKit

final class NarrativeArtifactNoticeTests: XCTestCase {
    func testEveryArtifactCarriesFullMPLAndPreservesCustomAndHiddenOriginalNotices() throws {
        try NarrativeTestSupport.requireResources()
        let root = try NarrativeTestSupport.temporaryDirectory("artifact-notices")
        defer { try? FileManager.default.removeItem(at: root) }
        for engine in [GameEngineID.ink, .microStudio, .twine, .tic80, .wasm4] {
            let source = root.appendingPathComponent(engine.rawValue + "-source")
            try create(engine, at: source)
            let original = Data("Original fixture game license. Custom terms remain unchanged.\n".utf8)
            let hidden = Data("Hidden license notice, preserved.\n".utf8)
            let collision = Data("Original custom component notice. This is not Floe's generated notice.\n".utf8)
            try original.write(to: source.appendingPathComponent("LICENSE"))
            try hidden.write(to: source.appendingPathComponent(".license"))
            try collision.write(to: source.appendingPathComponent("licenses/FLOE-COMPONENT-MPL-2.0.txt"))
            let artifact = root.appendingPathComponent(engine.rawValue + "-artifact")
            try build(engine, project: source, to: artifact)
            XCTAssertEqual(try read(artifact, "licenses/original/LICENSE"), original)
            XCTAssertEqual(try read(artifact, "licenses/original/.license"), hidden)
            XCTAssertEqual(try read(artifact, "licenses/original/licenses/FLOE-COMPONENT-MPL-2.0.txt"), collision)
            XCTAssertNotEqual(try read(artifact, "licenses/FLOE-COMPONENT-MPL-2.0.txt"), collision)
            XCTAssertEqual(GameDigest.sha256(try read(artifact, "licenses/FLOE-MPL-2.0.txt")),
                           "3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04")
            let supportFiles = try NarrativeTestSupport.supportFiles(in: artifact)
            XCTAssertFalse(supportFiles.isEmpty, engine.rawValue)
            let boundaryNotice = try NarrativeTestSupport.text(
                artifact.appendingPathComponent("licenses/FLOE-COMPONENT-MPL-2.0.txt"))
            for file in supportFiles {
                XCTAssertTrue(boundaryNotice.contains("support/" + file), "\(engine.rawValue) notice omits \(file)")
            }
            XCTAssertTrue(boundaryNotice.contains("Original game content"))
            XCTAssertTrue(boundaryNotice.contains("NOT MPL-2.0"))
            XCTAssertEqual(try read(source, "LICENSE"), original)
            XCTAssertEqual(try read(source, "licenses/FLOE-COMPONENT-MPL-2.0.txt"), collision)

            // A user-modified file with a familiar generated filename must not
            // be discarded or replaced with the original template's MIT text.
            let custom = Data("Custom original starter-file terms, not an MIT grant.\n".utf8)
            try custom.write(to: source.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt"))
            let imported = root.appendingPathComponent(engine.rawValue + "-custom-artifact")
            try build(engine, project: source, to: imported)
            XCTAssertFalse(FileManager.default.fileExists(atPath: imported.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))
            XCTAssertEqual(try read(imported, "licenses/original/licenses/FLOE-STARTER-MIT.txt"), custom)
        }
    }

    func testLegacyStarterNoticeSurvivesWithoutNewMetadataMarkers() throws {
        try NarrativeTestSupport.requireResources()
        let root = try NarrativeTestSupport.temporaryDirectory("legacy-starter-notices")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try GameInkAdapter.createProject(at: source, title: "Legacy")
        let metadata = source.appendingPathComponent("project.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        object.removeValue(forKey: "template")
        object.removeValue(forKey: "starterLicense")
        try JSONSerialization.data(withJSONObject: object).write(to: metadata)
        let artifact = root.appendingPathComponent("artifact")
        try GameInkAdapter.buildArtifact(projectAt: source, to: artifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try read(artifact, "licenses/FLOE-STARTER-MIT.txt"),
                       try read(source, "licenses/FLOE-STARTER-MIT.txt"))
        XCTAssertEqual(try read(artifact, "licenses/original/licenses/FLOE-STARTER-MIT.txt"),
                       try read(source, "licenses/FLOE-STARTER-MIT.txt"))
    }

    private func read(_ root: URL, _ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }
    private func create(_ engine: GameEngineID, at source: URL) throws {
        switch engine {
        case .ink: try GameInkAdapter.createProject(at: source, title: "Fixture")
        case .microStudio: try GameMicroStudioAdapter.createProject(at: source, title: "Fixture")
        case .twine: try GameTwineAdapter.createProject(at: source, title: "Fixture")
        case .tic80: try GameTIC80Adapter.createProject(at: source, title: "Fixture")
        case .wasm4: try GameWasm4Adapter.createProject(at: source, title: "Fixture")
        default: XCTFail("Unexpected fixture engine")
        }
    }
    private func build(_ engine: GameEngineID, project: URL, to target: URL) throws {
        switch engine {
        case .ink: try GameInkAdapter.buildArtifact(projectAt: project, to: target, resources: NarrativeTestSupport.resources)
        case .microStudio: try GameMicroStudioAdapter.buildArtifact(projectAt: project, to: target, resources: NarrativeTestSupport.resources)
        case .twine: try GameTwineAdapter.buildArtifact(projectAt: project, to: target, resources: NarrativeTestSupport.resources)
        case .tic80: try GameTIC80Adapter.buildArtifact(projectAt: project, to: target, resources: NarrativeTestSupport.resources)
        case .wasm4: try GameWasm4Adapter.buildArtifact(projectAt: project, to: target, resources: NarrativeTestSupport.resources)
        default: XCTFail("Unexpected fixture engine")
        }
    }
}
