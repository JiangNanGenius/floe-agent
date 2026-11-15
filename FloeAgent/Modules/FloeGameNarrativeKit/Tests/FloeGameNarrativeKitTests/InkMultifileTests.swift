// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameNarrativeKit

/// Standard multi-file ink INCLUDE coverage: the artifact must compile the same
/// graph the host imported, from an embedded bounded source map only.
final class InkMultifileTests: XCTestCase {
    func testNestedIncludesBuildFromEmbeddedSourceMap() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ink-multifile")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try writeProject(project, files: [
            "main.ink": """
            // INCLUDE chapters/ghost.ink
            /* INCLUDE chapters/also-ghost.ink
               this whole block is a comment */
            VAR visited = 0
            VAR lantern = 0

            INCLUDE chapters/intro.ink
            INCLUDE chapters/endings.ink

            -> intro
            """,
            "chapters/intro.ink": """
            -> intro

            === intro ===
            ~ visited = visited + 1
            雾从河谷升起。你带着 {lantern} 盏灯。
            + [继续赶路] -> crossroad
            + [数灯] -> count
            """,
            "chapters/endings.ink": """
            INCLUDE beats/count.ink
            INCLUDE beats/crossroad.ink
            INCLUDE ../shared/common.ink

            === pines ===
            松林里只有风。你有 {lantern} 盏灯。
            -> END
            """,
            "chapters/beats/count.ink": """
            === count ===
            ~ lantern = lantern + 1
            袋里现在是 {lantern} 盏灯。
            + [回到岔路] -> crossroad
            """,
            "chapters/beats/crossroad.ink": """
            === crossroad ===
            岔路在雾里分成两条。
            + [走石桥] -> bridge
            + [走松林] -> pines
            + [回头] -> turn
            """,
            "shared/common.ink": """
            INCLUDE beats/turn.ink

            === bridge ===
            ~ lantern = lantern + 2
            石桥尽头有人举灯相迎。你有 {lantern} 盏灯。
            -> END
            """,
            "shared/beats/turn.ink": """
            === turn ===
            你回头看了看来路。
            + [继续] -> crossroad
            """
        ])
        let unknown = Data([0x00, 0x01, 0xFE, 0xFF, 0x7A])
        try FileManager.default.createDirectory(at: project.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try unknown.write(to: project.appendingPathComponent("notes/readme.bin"))

        let artifact = work.appendingPathComponent("artifact")
        try GameInkAdapter.buildArtifact(projectAt: project, to: artifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("story.ink")),
                       try NarrativeTestSupport.read(project.appendingPathComponent("main.ink")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("notes/readme.bin").path))
        XCTAssertEqual(try NarrativeTestSupport.read(project.appendingPathComponent("notes/readme.bin")), unknown)

        let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
        let support = try NarrativeTestSupport.supportText(in: artifact)
        XCTAssertTrue(html.contains("support/ink-bridge.js"))
        XCTAssertTrue(support.contains("fileHandler"))
        XCTAssertTrue(support.contains("ResolveInkFilename"))
        XCTAssertTrue(support.contains("game/ink-sources.json"))
        XCTAssertFalse(html.contains("雾从河谷"))
        XCTAssertFalse(support.contains("雾从河谷"))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("game/source/main.ink")),
                       try NarrativeTestSupport.read(project.appendingPathComponent("main.ink")))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("game/source/chapters/intro.ink")),
                       try NarrativeTestSupport.read(project.appendingPathComponent("chapters/intro.ink")))

        let document = try embeddedSourceDocument(artifact)
        XCTAssertEqual(document["format"] as? String, "floe-ink-sources")
        XCTAssertEqual(document["entry"] as? String, "main.ink")
        let files = try XCTUnwrap(document["files"] as? [String: String])
        XCTAssertEqual(Set(files.keys), Set([
            "main.ink", "chapters/intro.ink", "chapters/endings.ink",
            "chapters/beats/count.ink", "chapters/beats/crossroad.ink",
            "shared/common.ink", "shared/beats/turn.ink"
        ]))
        // Nested relative includes become canonical project paths; commented
        // directives are neither resolved nor rewritten.
        XCTAssertTrue(files["chapters/endings.ink"]?.contains("INCLUDE shared/common.ink") == true)
        XCTAssertTrue(files["shared/common.ink"]?.contains("INCLUDE shared/beats/turn.ink") == true)
        XCTAssertFalse(files.keys.contains("chapters/ghost.ink"))
        XCTAssertFalse(files.keys.contains("chapters/also-ghost.ink"))
        XCTAssertTrue(files["main.ink"]?.contains("// INCLUDE chapters/ghost.ink") == true)

        let package = try NarrativeTestSupport.artifactPackage(sourceRoot: artifact, engine: .ink)
        try package.verify()
    }

    func testAmbiguousEntryNeedsExplicitChoice() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ink-entry")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try writeProject(project, files: [
            "a.ink": "-> a\n=== a ===\nA\n-> END\n",
            "b.ink": "-> b\n=== b ===\nB\n-> END\n"
        ])
        XCTAssertEqual(try InkSourceGraph.candidateEntries(projectAt: project), ["a.ink", "b.ink"])
        XCTAssertThrowsError(try GameInkAdapter.buildArtifact(projectAt: project, to: work.appendingPathComponent("ambiguous"),
                                                              resources: NarrativeTestSupport.resources)) { error in
            XCTAssertEqual(error as? InkArtifactError, .ambiguousEntry(candidates: ["a.ink", "b.ink"]))
        }
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: project)) { error in
            XCTAssertEqual(error as? InkArtifactError, .ambiguousEntry(candidates: ["a.ink", "b.ink"]))
        }
        // Explicit selection resolves deterministically.
        let graph = try InkSourceGraph.prepare(projectAt: project, entry: "b.ink")
        XCTAssertEqual(graph.entry, "b.ink")
        XCTAssertEqual(Set(graph.sources.keys), ["b.ink"])
        let artifact = work.appendingPathComponent("explicit")
        try GameInkAdapter.buildArtifact(projectAt: project, to: artifact,
                                        resources: NarrativeTestSupport.resources, entry: "b.ink")
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("story.ink")),
                       Data("-> b\n=== b ===\nB\n-> END\n".utf8))
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: project, entry: "missing.ink")) { error in
            XCTAssertEqual(error as? InkArtifactError, .entryNotFound("missing.ink"))
        }
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: project, entry: "../a.ink")) { error in
            guard let ink = error as? InkArtifactError, case .unsafeInclude = ink else {
                return XCTFail("expected unsafeInclude, got \(error)")
            }
        }
    }

    func testMissingCycleTraversalAndSymlinkDiagnostics() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("ink-bad")
        defer { try? FileManager.default.removeItem(at: work) }

        let missing = work.appendingPathComponent("missing")
        try writeProject(missing, files: ["main.ink": "INCLUDE gone.ink\n-> x\n=== x ===\nX\n-> END\n"])
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: missing)) { error in
            XCTAssertEqual(error as? InkArtifactError, .missingInclude(file: "gone.ink", includedFrom: "main.ink"))
        }

        let cycle = work.appendingPathComponent("cycle")
        try writeProject(cycle, files: [
            "main.ink": "INCLUDE a.ink\n",
            "a.ink": "INCLUDE b.ink\n",
            "b.ink": "INCLUDE a.ink\n"
        ])
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: cycle)) { error in
            guard let ink = error as? InkArtifactError, case .includeCycle(let path) = ink else {
                return XCTFail("expected includeCycle, got \(error)")
            }
            XCTAssertEqual(path, ["a.ink", "b.ink", "a.ink"])
        }

        let traversal = work.appendingPathComponent("traversal")
        try writeProject(traversal, files: ["main.ink": "INCLUDE ../outside.ink\n"])
        try Data("-> x\n=== x ===\nX\n-> END\n".utf8).write(to: work.appendingPathComponent("outside.ink"))
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: traversal)) { error in
            XCTAssertEqual(error as? InkArtifactError,
                           .unsafeInclude(path: "../outside.ink", includedFrom: "main.ink"))
        }

        let linked = work.appendingPathComponent("linked")
        try writeProject(linked, files: ["main.ink": "INCLUDE linked.ink\n"])
        let target = work.appendingPathComponent("linked-target.ink")
        try Data("-> x\n=== x ===\nX\n-> END\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("linked.ink"),
                                                   withDestinationURL: target)
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: linked)) { error in
            XCTAssertEqual(error as? InkArtifactError, .symbolicLink("linked.ink"))
        }

        let invalid = work.appendingPathComponent("invalid")
        try writeProject(invalid, files: ["main.ink": "INCLUDE broken.ink\n"])
        try Data([0xFF, 0xFE, 0x00]).write(to: invalid.appendingPathComponent("broken.ink"))
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: invalid)) { error in
            XCTAssertEqual(error as? InkArtifactError, .unreadableSource("broken.ink"))
        }

        let empty = work.appendingPathComponent("empty")
        try writeProject(empty, files: ["main.ink": ""])
        XCTAssertThrowsError(try InkSourceGraph.prepare(projectAt: empty)) { error in
            XCTAssertEqual(error as? InkArtifactError, .emptySource("main.ink"))
        }
    }


    func testLicensingScopesStarterAndPreservesImportedNotices() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ink-license")
        defer { try? FileManager.default.removeItem(at: work) }
        // Created starter keeps its additional MIT notice and marks metadata.
        let starter = work.appendingPathComponent("starter")
        try GameInkAdapter.createProject(at: starter, title: "Starter license")
        let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try NarrativeTestSupport.read(starter.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertEqual(metadata["template"] as? String, "floe-starter")
        XCTAssertEqual(metadata["starterLicense"] as? String, "MIT")
        XCTAssertEqual(metadata["engineLicense"] as? String, "MIT")
        let starterArtifact = work.appendingPathComponent("starter-artifact")
        try GameInkAdapter.buildArtifact(projectAt: starter, to: starterArtifact,
                                        resources: NarrativeTestSupport.resources)
        XCTAssertTrue(FileManager.default.fileExists(atPath: starterArtifact.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: starterArtifact.appendingPathComponent("licenses/FLOE-COMPONENT-MPL-2.0.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: starterArtifact.appendingPathComponent("licenses/INKJS-MIT.txt").path))

        // Imported user story: own license bytes preserved, no starter notice,
        // and the project metadata added at import does not claim a template.
        let source = work.appendingPathComponent("original")
        let license = "Original Story License — custom, non-MIT, all rights reserved.\n"
        try writeProject(source, files: ["main.ink": "-> x\n=== x ===\nX\n-> END\n", "LICENSE": license])
        let imported = work.appendingPathComponent("imported")
        try GameInkAdapter.importProject(from: source, to: imported, title: "Imported license")
        XCTAssertEqual(try NarrativeTestSupport.read(imported.appendingPathComponent("LICENSE")), Data(license.utf8))
        let importedMetadata = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try NarrativeTestSupport.read(imported.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertNil(importedMetadata["template"])
        let artifact = work.appendingPathComponent("imported-artifact")
        try GameInkAdapter.buildArtifact(projectAt: imported, to: artifact,
                                        resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("licenses/original/LICENSE")),
                       Data(license.utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/INKJS-MIT.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/FLOE-COMPONENT-MPL-2.0.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))
    }

    func testIncludeResolutionUsesActualFileCase() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("ink-case")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try writeProject(project, files: [
            "main.ink": "INCLUDE chapters/intro.ink\n",
            "Chapters/Intro.ink": "-> x\n=== x ===\nX\n-> END\n"
        ])
        let graph = try InkSourceGraph.prepare(projectAt: project)
        XCTAssertEqual(Array(graph.sources.keys).sorted(), ["Chapters/Intro.ink", "main.ink"])
        XCTAssertTrue(graph.sources["main.ink"]?.contains("INCLUDE Chapters/Intro.ink") == true)
    }

    // MARK: - Helpers

    func writeProject(_ root: URL, files: [String: String]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    func embeddedSourceDocument(_ artifact: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(
            with: NarrativeTestSupport.read(artifact.appendingPathComponent("game/ink-sources.json"))) as? [String: Any])
    }
}
