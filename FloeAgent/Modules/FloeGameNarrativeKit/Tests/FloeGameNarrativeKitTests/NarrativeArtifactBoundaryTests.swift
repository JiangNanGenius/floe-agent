// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameNarrativeKit

/// Cross-adapter proof that generated Web artifacts keep Floe MPL support code,
/// original game content and third-party runtimes in separate files, with a
/// deterministic total file manifest and accurate notices.
final class NarrativeArtifactBoundaryTests: XCTestCase {
    private func create(_ engine: GameEngineID, at project: URL) throws {
        switch engine {
        case .ink: try GameInkAdapter.createProject(at: project, title: "Boundary")
        case .twine: try GameTwineAdapter.createProject(at: project, title: "Boundary")
        case .wasm4: try GameWasm4Adapter.createProject(at: project, title: "Boundary")
        case .tic80: try GameTIC80Adapter.createProject(at: project, title: "Boundary")
        case .microStudio: try GameMicroStudioAdapter.createProject(at: project, title: "Boundary")
        default: XCTFail("unexpected engine")
        }
    }

    private func build(_ engine: GameEngineID, project: URL, to artifact: URL) throws {
        switch engine {
        case .ink: try GameInkAdapter.buildArtifact(projectAt: project, to: artifact,
                                                    resources: NarrativeTestSupport.resources)
        case .twine: try GameTwineAdapter.buildArtifact(projectAt: project, to: artifact,
                                                        resources: NarrativeTestSupport.resources)
        case .wasm4: try GameWasm4Adapter.buildArtifact(projectAt: project, to: artifact,
                                                        resources: NarrativeTestSupport.resources)
        case .tic80: try GameTIC80Adapter.buildArtifact(projectAt: project, to: artifact,
                                                        resources: NarrativeTestSupport.resources)
        case .microStudio: try GameMicroStudioAdapter.buildArtifact(projectAt: project, to: artifact,
                                                                    resources: NarrativeTestSupport.resources)
        default: XCTFail("unexpected engine")
        }
    }

    /// Adds a unique marker to the actual original game content for each engine.
    /// It must only ever appear in original-game-* files, never support/notice.
    @discardableResult
    private func injectMarker(_ engine: GameEngineID, project: URL, marker: String) throws -> String {
        switch engine {
        case .ink:
            let url = project.appendingPathComponent("story.ink")
            var text = try NarrativeTestSupport.text(url)
            text += "\n// \(marker)\n"
            try Data(text.utf8).write(to: url)
            return marker
        case .twine:
            let url = project.appendingPathComponent("story.twine.json")
            var object = try XCTUnwrap(try JSONSerialization.jsonObject(
                with: Data(contentsOf: url)) as? [String: Any])
            var passages = try XCTUnwrap(object["passages"] as? [[String: Any]])
            passages[0]["text"] = ((passages[0]["text"] as? String) ?? "") + "\n\(marker)"
            object["passages"] = passages
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
            return marker
        case .wasm4:
            let url = project.appendingPathComponent("cart.wasm")
            let original = try Data(contentsOf: url)
            let label = Data(GameWasm4Adapter.starterLabel.utf8)
            let replacement = Data("FLOE-WASM4-BOUND!!".utf8)
            XCTAssertEqual(label.count, replacement.count)
            let range = try XCTUnwrap(original.range(of: label))
            var modified = original
            modified.replaceSubrange(range, with: replacement)
            try modified.write(to: url)
            return "FLOE-WASM4-BOUND!!"
        case .tic80:
            let url = project.appendingPathComponent("cart.tic")
            var cart = try TICCart.parse(try Data(contentsOf: url))
            let index = try XCTUnwrap(cart.chunks.firstIndex { $0.type == TICCart.ChunkType.code.rawValue })
            cart.chunks[index].data.append(Data("\n// \(marker)\n".utf8))
            try cart.serialized().write(to: url)
            return marker
        case .microStudio:
            let url = project.appendingPathComponent("src/main.ms")
            var text = try NarrativeTestSupport.text(url)
            text += "\n// \(marker)\n"
            try Data(text.utf8).write(to: url)
            return marker
        default:
            XCTFail("unexpected engine")
            return marker
        }
    }

    func testAllFiveArtifactsSeparateSupportFromOriginalGameContent() throws {
        try NarrativeTestSupport.requireResources()
        let root = try NarrativeTestSupport.temporaryDirectory("artifact-boundary")
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(GameEngineID, String)] = [
            (.ink, "FLOE-BOUNDARY-INK"),
            (.twine, "FLOE-BOUNDARY-TWINE"),
            (.wasm4, "FLOE-BOUNDARY-WASM4"),
            (.tic80, "FLOE-BOUNDARY-TIC80"),
            (.microStudio, "FLOE-BOUNDARY-MICROSTUDIO")
        ]
        for (engine, marker) in cases {
            let project = root.appendingPathComponent(engine.rawValue + "-project")
            try create(engine, at: project)
            let actualMarker = try injectMarker(engine, project: project, marker: marker)
            let artifact = root.appendingPathComponent(engine.rawValue + "-artifact")
            try build(engine, project: project, to: artifact)

            let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
            let support = try NarrativeTestSupport.supportText(in: artifact)
            let notice = try NarrativeTestSupport.text(
                artifact.appendingPathComponent("licenses/FLOE-COMPONENT-MPL-2.0.txt"))
            XCTAssertFalse(html.contains("window.FloeGame"), engine.rawValue)
            XCTAssertFalse(html.contains(actualMarker), engine.rawValue)
            XCTAssertFalse(support.contains(actualMarker), engine.rawValue)
            XCTAssertFalse(notice.contains(actualMarker), engine.rawValue)
            for file in try NarrativeTestSupport.supportFiles(in: artifact) {
                let text = try NarrativeTestSupport.text(artifact.appendingPathComponent("support").appendingPathComponent(file))
                XCTAssertTrue(text.hasPrefix("/* SPDX-License-Identifier: MPL-2.0"), "\(engine.rawValue)/\(file)")
                XCTAssertTrue(notice.contains("support/" + file), "\(engine.rawValue) notice omits \(file)")
            }
            XCTAssertTrue(notice.contains("Original game content"))
            XCTAssertTrue(notice.contains("NOT MPL-2.0"))

            // The actual engine/source bytes must stay in their own files.
            switch engine {
            case .ink:
                XCTAssertTrue(try NarrativeTestSupport.text(
                    artifact.appendingPathComponent("game/ink-sources.json")).contains(actualMarker))
                XCTAssertTrue(try NarrativeTestSupport.text(
                    artifact.appendingPathComponent("story.ink")).contains(actualMarker))
                XCTAssertTrue(try NarrativeTestSupport.text(
                    artifact.appendingPathComponent("game/source/story.ink")).contains(actualMarker))
                XCTAssertEqual(GameDigest.sha256(try NarrativeTestSupport.read(
                    artifact.appendingPathComponent("vendor/inkjs.js"))), GameInkAdapter.engineSHA256)
            case .twine:
                XCTAssertTrue(try NarrativeTestSupport.text(
                    artifact.appendingPathComponent("game/story.twine.json")).contains(actualMarker))
                XCTAssertFalse(html.contains("<tw-storydata"))
                XCTAssertEqual(GameDigest.sha256(try NarrativeTestSupport.read(
                    artifact.appendingPathComponent("vendor/sugarcube-format.js"))), GameTwineAdapter.formatSHA256)
            case .wasm4:
                XCTAssertNotNil(try NarrativeTestSupport.read(
                    artifact.appendingPathComponent("cart.wasm")).range(of: Data(actualMarker.utf8)))
                XCTAssertEqual(GameDigest.sha256(try NarrativeTestSupport.read(
                    artifact.appendingPathComponent("wasm4.js"))), GameWasm4Adapter.runtimeSHA256)
            case .tic80:
                XCTAssertNotNil(try NarrativeTestSupport.read(
                    artifact.appendingPathComponent("cart.tic")).range(of: Data(actualMarker.utf8)))
                XCTAssertEqual(GameDigest.sha256(try NarrativeTestSupport.read(
                    artifact.appendingPathComponent("tic80.js"))), GameTIC80Adapter.jsSHA256)
            case .microStudio:
                XCTAssertTrue(try NarrativeTestSupport.text(
                    artifact.appendingPathComponent("game/microstudio-sources.json")).contains(actualMarker))
                XCTAssertTrue(try NarrativeTestSupport.text(
                    artifact.appendingPathComponent("game/source/src/main.ms")).contains(actualMarker))
                XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("microengine.js")),
                               try GameMicroStudioAdapter.rebuildEngineBundle(resources: NarrativeTestSupport.resources))
            default:
                XCTFail("unexpected engine")
            }

            // Conditional engines must carry the selected transitive notices.
            if engine == .tic80 {
                XCTAssertTrue(FileManager.default.fileExists(atPath:
                    artifact.appendingPathComponent("licenses/LICENSES/LGPL-2.1-or-later-blip_buf.txt").path))
                XCTAssertTrue(FileManager.default.fileExists(atPath:
                    artifact.appendingPathComponent("licenses/BLIP-BUF-SOURCE-OFFER.md").path))
                XCTAssertTrue(notice.contains("LGPL"))
                for source in ["TIC-80-b3dbd59-source.tar.gz", "TIC-80-b3dbd59-source.tar.gz.sha256",
                               "blip-buf-330226d-source.tar.gz", "blip-buf-330226d-source.tar.gz.sha256",
                               "TIC80-SUBMODULE-PINS.json", "SOURCE-OFFER.md",
                               "TIC80-EXACT-CORRESPONDING-SOURCE.zip", "CURRENT-BUILD-AND-RELINK.json"] {
                    XCTAssertTrue(FileManager.default.fileExists(atPath:
                        artifact.appendingPathComponent("source/tic80/" + source).path), source)
                }
                XCTAssertTrue(notice.contains("not a full LGPL clearance"))
                let sourceManifest = try NarrativeTestSupport.manifest(in: artifact)
                let sourceFiles = sourceManifest["thirdPartySourceFiles"] as? [String] ?? []
                XCTAssertTrue(sourceFiles.contains("source/tic80/blip-buf-330226d-source.tar.gz"))
            } else if engine == .wasm4 {
                XCTAssertTrue(FileManager.default.fileExists(atPath:
                    artifact.appendingPathComponent("licenses/LIT-3.1.2-BSD-3-Clause.txt").path))
                XCTAssertTrue(FileManager.default.fileExists(atPath:
                    artifact.appendingPathComponent("licenses/PRESS-START-2P-OFL-1.1.txt").path))
                XCTAssertTrue(notice.contains("OFL"))
            } else if engine == .twine {
                XCTAssertTrue(FileManager.default.fileExists(atPath:
                    artifact.appendingPathComponent("licenses/licenses/jquery-3.7.1-LICENSE.txt").path))
                XCTAssertTrue(try NarrativeTestSupport.text(artifact.appendingPathComponent("licenses/THIRD-PARTY-NOTICES.txt")).contains("jQuery"))
            }

            let manifest = try NarrativeTestSupport.manifest(in: artifact)
            let files = try XCTUnwrap(manifest["files"] as? [[String: Any]])
            let supportEntry = files.first { ($0["path"] as? String) == "support/floe-host.js" }
            XCTAssertEqual(supportEntry?["role"] as? String, "floe-support-source")
            XCTAssertEqual(supportEntry?["license"] as? String, "MPL-2.0")
            let engineBridge = engine == .ink ? "support/ink-bridge.js"
                : engine == .twine ? "support/twine-bridge.js"
                : engine == .wasm4 ? "support/wasm4-bridge.js"
                : engine == .tic80 ? "support/tic80-bridge.js"
                : "support/microstudio-bridge.js"
            XCTAssertEqual(files.first { ($0["path"] as? String) == engineBridge }?["role"] as? String,
                           "floe-support-source")
            XCTAssertTrue(files.allSatisfy { ($0["sha256"] as? String)?.count == 64 })
        }
    }

    func testArtifactManifestIsDeterministicAndComplete() throws {
        try NarrativeTestSupport.requireResources()
        let root = try NarrativeTestSupport.temporaryDirectory("artifact-deterministic")
        defer { try? FileManager.default.removeItem(at: root) }
        for engine in [GameEngineID.ink, .twine, .wasm4, .tic80, .microStudio] {
            let project = root.appendingPathComponent(engine.rawValue + "-project")
            try create(engine, at: project)
            let first = root.appendingPathComponent(engine.rawValue + "-first")
            let second = root.appendingPathComponent(engine.rawValue + "-second")
            try build(engine, project: project, to: first)
            try build(engine, project: project, to: second)
            let firstFiles = try relativeFiles(in: first)
            let secondFiles = try relativeFiles(in: second)
            XCTAssertEqual(firstFiles, secondFiles, engine.rawValue)
            for path in firstFiles {
                XCTAssertEqual(try NarrativeTestSupport.read(first.appendingPathComponent(path)),
                               try NarrativeTestSupport.read(second.appendingPathComponent(path)),
                               "\(engine.rawValue)/\(path)")
            }
            let manifest = try NarrativeTestSupport.manifest(in: first)
            let listed = Set(try XCTUnwrap(manifest["files"] as? [[String: Any]])
                .compactMap { $0["path"] as? String })
            XCTAssertEqual(listed, Set(firstFiles.filter { $0 != "floe-artifact.json" }), engine.rawValue)
            XCTAssertEqual(manifest["fileCount"] as? Int ?? -1, listed.count, engine.rawValue)
        }
    }

    func testImportedFixtureSourcesKeepOriginalPathsAndBytes() throws {
        try NarrativeTestSupport.requireResources()
        guard let fixturePath = ProcessInfo.processInfo.environment["FLOE_NARRATIVE_IMPORT_FIXTURES"],
              !fixturePath.isEmpty else {
            throw XCTSkip("Set FLOE_NARRATIVE_IMPORT_FIXTURES to the reviewed import fixtures")
        }
        let fixtures = URL(fileURLWithPath: fixturePath)
        let inkFixture = fixtures.appendingPathComponent("ink-multifile")
        let studioFixture = fixtures.appendingPathComponent("microstudio-assets")
        guard FileManager.default.fileExists(atPath: inkFixture.path),
              FileManager.default.fileExists(atPath: studioFixture.path) else {
            throw XCTSkip("Original private import fixtures are not present")
        }
        let root = try NarrativeTestSupport.temporaryDirectory("artifact-fixtures")
        defer { try? FileManager.default.removeItem(at: root) }

        let inkProject = root.appendingPathComponent("ink-project")
        try GameInkAdapter.importProject(from: inkFixture, to: inkProject, title: "Imported ink")
        let inkArtifact = root.appendingPathComponent("ink-artifact")
        try GameInkAdapter.buildArtifact(projectAt: inkProject, to: inkArtifact,
                                        resources: NarrativeTestSupport.resources)
        for path in ["main.ink", "chapters/intro.ink", "chapters/endings.ink",
                     "shared/common.ink"] {
            XCTAssertEqual(try NarrativeTestSupport.read(inkArtifact.appendingPathComponent("game/source/" + path)),
                           try NarrativeTestSupport.read(inkFixture.appendingPathComponent(path)), path)
        }
        let inkSource = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: NarrativeTestSupport.read(inkArtifact.appendingPathComponent("game/ink-sources.json"))) as? [String: Any])
        XCTAssertEqual(inkSource["entry"] as? String, "main.ink")
        XCTAssertFalse(try NarrativeTestSupport.supportText(in: inkArtifact).contains("森林邮差"))

        let studioProject = root.appendingPathComponent("studio-project")
        try GameMicroStudioAdapter.importProject(from: studioFixture, to: studioProject, title: "Imported studio")
        let studioArtifact = root.appendingPathComponent("studio-artifact")
        try GameMicroStudioAdapter.buildArtifact(projectAt: studioProject, to: studioArtifact,
                                                 resources: NarrativeTestSupport.resources)
        for path in ["ms/main.ms", "ms/util.ms"] {
            XCTAssertEqual(try NarrativeTestSupport.read(studioArtifact.appendingPathComponent("game/source/" + path)),
                           try NarrativeTestSupport.read(studioFixture.appendingPathComponent(path)), path)
        }
        XCTAssertEqual(try NarrativeTestSupport.read(studioArtifact.appendingPathComponent("sprites/hero.png")),
                       try NarrativeTestSupport.read(studioFixture.appendingPathComponent("sprites/hero.png")))
        XCTAssertEqual(try NarrativeTestSupport.read(studioArtifact.appendingPathComponent("maps/field.json")),
                       try NarrativeTestSupport.read(studioFixture.appendingPathComponent("maps/field.json")))
        XCTAssertFalse(try NarrativeTestSupport.supportText(in: studioArtifact).contains("FLOE microStudio"))
    }

    private func relativeFiles(in root: URL) throws -> [String] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var result: [String] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard canonical.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadInvalidFileName) }
            let relative = String(canonical.dropFirst(root.path.count + 1))
            result.append(relative)
        }
        return result.sorted()
    }
}
