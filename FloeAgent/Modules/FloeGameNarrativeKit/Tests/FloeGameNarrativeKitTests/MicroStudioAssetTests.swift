// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameNarrativeKit

/// Ordinary microStudio archive/export layouts with sprites, maps, sounds,
/// music and assets: the artifact must carry the official flat runtime names
/// and the real `resources` metadata the pinned canvas2d player consumes.
final class MicroStudioAssetTests: XCTestCase {
    func testArchiveLayoutPacksResourcesAndOfficialMetadata() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ms-assets")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        let map = #"{"width":2,"height":2,"block_width":16,"block_height":16,"sprites":[0,"tiles-grass"],"data":[1,0,0,1]}"#
        let projectJSON: [String: Any] = [
            "owner": "floe", "title": "<script>alert(1)</script>", "slug": "lantern-field",
            "orientation": "landscape", "aspect": "16/9", "type": "game",
            "language": "microscript_v2", "graphics": "M1", "libs": [], "networking": false,
            "files": [
                "ms/main.ms": ["version": 3, "size": 10, "properties": [:]],
                "ms/util.ms": ["version": 4],
                "sprites/hero.png": ["version": 7, "properties": ["frames": 2, "fps": 8, "bogus": 99]],
                "sounds/beep.wav": ["version": 2],
                "music/theme.mp3": ["version": 1],
                "assets/notes.txt": ["version": 4],
                "maps/field.json": ["version": 5]
            ],
            "unknownExtra": ["preserved": true]
        ]
        try writeProject(project, files: [
            "project.json": String(decoding: try JSONSerialization.data(withJSONObject: projectJSON,
                                                                      options: [.sortedKeys]), as: UTF8.self),
            "ms/main.ms": """
            // FLOE microStudio asset fixture (MIT)
            init = function()
              x = 24
              y = 40
              asset_ready = 0
              notes = asset_manager.loadText("notes")
              screen.clear("rgb(10,20,30)")
            end

            update = function()
              if asset_ready == 0 and notes.ready then
                asset_ready = 1
              end
              if keyboard.RIGHT then x = x + 3 end
              screen.clear("rgb(10,20,30)")
              screen.drawMap("field", 60, 40, 320, 192)
              screen.drawSprite("hero", x, y, 16, 16)
            end

            floe_snapshot = function(seed)
              return [x, y, asset_ready]
            end

            floe_restore = function(sx, sy, sa)
              x = sx
              y = sy
              asset_ready = sa
              return 1
            end
            """,
            "ms/util.ms": """
            // FLOE util fixture (MIT)
            floe_clamp = function(v, lo, hi)
              if v < lo then return lo end
              if v > hi then return hi end
              return v
            end
            """,
            "sprites/hero.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
            "sprites/tiles/grass.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0B]),
            "sprites/.hidden.png": Data([0x00]),
            "maps/field.json": map,
            "sounds/beep.wav": Data("RIFF0000WAVE".utf8),
            "music/theme.mp3": Data("ID3floe".utf8),
            "assets/notes.txt": Data("FLOE-ASSET-OK".utf8),
            "assets/photo.png": Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0C]),
            "assets/nested/data.json": Data("{\"nested\":true}".utf8),
            "docs/readme.bin": Data([0x01, 0x02, 0x03]),
            "LICENSE": Data("Original Fixture License 1.0 — non-MIT, all rights reserved.\n".utf8),
            "NOTICE": Data("Fixture notice: original procedural content only.\n".utf8),
            "assets/vendor/COPYING": Data("Vendor fixture terms (custom, not MIT).\n".utf8)
        ])

        let plan = try MicroStudioProjectPlan.prepare(projectAt: project)
        XCTAssertEqual(plan.sources.map(\.runtimeName), ["ms-main.ms", "ms-util.ms"])
        XCTAssertEqual(plan.title, "<script>alert(1)</script>")
        XCTAssertEqual(plan.graphics, "M1")
        XCTAssertEqual(plan.orientation, "landscape")
        XCTAssertEqual(plan.aspect, "16/9")
        let hero = try XCTUnwrap(plan.resources.first { $0.runtimeFile == "hero.png" })
        XCTAssertEqual(hero.version, 7)
        XCTAssertEqual(hero.imageProperties?["frames"], 2)
        XCTAssertEqual(hero.imageProperties?["fps"], 8)
        XCTAssertNil(hero.imageProperties?["bogus"])
        let grass = try XCTUnwrap(plan.resources.first { $0.runtimeFile == "tiles-grass.png" })
        XCTAssertEqual(grass.sourcePath, "sprites/tiles/grass.png")
        XCTAssertEqual(plan.resources.first { $0.runtimeFile == "beep.wav" }?.version, 2)
        XCTAssertEqual(plan.resources.first { $0.runtimeFile == "nested-data.json" }?.kind, .asset)
        XCTAssertEqual(plan.maps.map(\.name), ["field"])
        XCTAssertEqual(plan.maps.first?.text, map)

        let artifact = work.appendingPathComponent("artifact")
        try GameMicroStudioAdapter.buildArtifact(projectAt: project, to: artifact,
                                                 resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("sprites/hero.png")),
                       try NarrativeTestSupport.read(project.appendingPathComponent("sprites/hero.png")))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("sprites/tiles-grass.png")),
                       try NarrativeTestSupport.read(project.appendingPathComponent("sprites/tiles/grass.png")))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("sounds/beep.wav")),
                       Data("RIFF0000WAVE".utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("music/theme.mp3")),
                       Data("ID3floe".utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("assets/notes.txt")),
                       Data("FLOE-ASSET-OK".utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("assets/nested-data.json")),
                       Data("{\"nested\":true}".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("sprites/.hidden.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("docs/readme.bin").path))
        // Imported game notices ride with the carried content, byte-exact and
        // namespaced away from engine/bridge notices.
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("licenses/original/LICENSE")),
                       Data("Original Fixture License 1.0 — non-MIT, all rights reserved.\n".utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("licenses/original/NOTICE")),
                       Data("Fixture notice: original procedural content only.\n".utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("licenses/original/assets/vendor/COPYING")),
                       Data("Vendor fixture terms (custom, not MIT).\n".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/LICENSE.microstudio.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/FLOE-COMPONENT-MPL-2.0.txt").path))
        // The imported project is not a Floe starter: no blanket starter MIT notice.
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))

        let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
        let support = try NarrativeTestSupport.supportText(in: artifact)
        let resources = try resourceDocument(artifact)
        let images = try XCTUnwrap(resources["images"] as? [[String: Any]])
        XCTAssertEqual(images.map { $0["file"] as? String }, ["hero.png", "tiles-grass.png"])
        let heroJSON = try XCTUnwrap(images.first)
        XCTAssertEqual(heroJSON["version"] as? Int, 7)
        let properties = try XCTUnwrap(heroJSON["properties"] as? [String: Any])
        XCTAssertEqual(properties["frames"] as? Int, 2)
        XCTAssertEqual(properties["fps"] as? Int, 8)
        XCTAssertNil(properties["bogus"])
        let maps = try XCTUnwrap(resources["maps"] as? [String: String])
        XCTAssertEqual(maps, ["field": map])
        XCTAssertEqual((resources["sounds"] as? [[String: Any]])?.first?["file"] as? String, "beep.wav")
        XCTAssertEqual((resources["music"] as? [[String: Any]])?.first?["file"] as? String, "theme.mp3")
        let assets = try XCTUnwrap(resources["assets"] as? [[String: Any]])
        XCTAssertEqual(assets.compactMap { $0["file"] as? String }, ["nested-data.json", "notes.txt", "photo.png"])

        // Multi-file execution source uses upstream's file-local wrappers and
        // the exact original text through a JSON block.
        let document = try sourceDocument(artifact)
        XCTAssertEqual(document["format"] as? String, "floe-microstudio-sources")
        let code = try XCTUnwrap(document["code"] as? String)
        XCTAssertTrue(code.contains("// file: ms/main.ms"))
        XCTAssertTrue(code.contains("// file: ms/util.ms"))
        XCTAssertTrue(code.contains("function()"))
        XCTAssertTrue(code.contains("floe_clamp = function(v, lo, hi)"))
        XCTAssertLessThan(try XCTUnwrap(code.range(of: "// file: ms/main.ms")).lowerBound,
                          try XCTUnwrap(code.range(of: "// file: ms/util.ms")).lowerBound)
        XCTAssertTrue(support.contains("code.textContent = sourceDocument.code"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(support.contains("window.ms_use_server = false"))
        XCTAssertTrue(support.contains("window.skip_service_worker = true"))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("game/source/ms/main.ms")),
                       try NarrativeTestSupport.read(project.appendingPathComponent("ms/main.ms")))

        let package = try NarrativeTestSupport.artifactPackage(sourceRoot: artifact, engine: .microStudio)
        try package.verify()
    }

    func testUnsupportedRuntimeMetadataIsExplicit() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("ms-unsupported")
        defer { try? FileManager.default.removeItem(at: work) }
        func project(_ name: String, _ info: [String: Any]) throws -> URL {
            let root = work.appendingPathComponent(name)
            let json = String(decoding: try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]),
                              as: UTF8.self)
            try writeProject(root, files: ["project.json": json, "ms/main.ms": "update = function()\nend\n"])
            return root
        }
        let graphics = try project("graphics", ["language": "microscript_v2", "graphics": "PIXI", "libs": []])
        XCTAssertThrowsError(try MicroStudioProjectPlan.prepare(projectAt: graphics)) { error in
            XCTAssertEqual(error as? MicroStudioArtifactError, .unsupportedGraphics("PIXI"))
        }
        let language = try project("language", ["language": "javascript", "graphics": "M1", "libs": []])
        XCTAssertThrowsError(try MicroStudioProjectPlan.prepare(projectAt: language)) { error in
            XCTAssertEqual(error as? MicroStudioArtifactError, .unsupportedLanguage("javascript"))
        }
        let libs = try project("libs", ["language": "microscript_v2", "graphics": "M1", "libs": ["matterjs_v019"]])
        XCTAssertThrowsError(try MicroStudioProjectPlan.prepare(projectAt: libs)) { error in
            XCTAssertEqual(error as? MicroStudioArtifactError, .unsupportedLibraries(["matterjs_v019"]))
        }
        let networking = try project("networking", ["language": "microscript_v2", "graphics": "M1",
                                                    "libs": [], "networking": true])
        XCTAssertThrowsError(try MicroStudioProjectPlan.prepare(projectAt: networking)) { error in
            XCTAssertEqual(error as? MicroStudioArtifactError, .networkingUnsupported)
        }
    }

    func testInvalidMapAndSymlinkedResourcesAreRejected() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("ms-invalid")
        defer { try? FileManager.default.removeItem(at: work) }
        let badMap = work.appendingPathComponent("bad-map")
        try writeProject(badMap, files: [
            "ms/main.ms": "update = function()\nend\n",
            "maps/field.json": #"{"width":2,"height":2,"block_width":16,"block_height":16,"sprites":[0,"tile"],"data":[1,0]}"#
        ])
        XCTAssertThrowsError(try MicroStudioProjectPlan.prepare(projectAt: badMap)) { error in
            XCTAssertEqual(error as? MicroStudioArtifactError, .invalidMap("maps/field.json"))
        }

        let linked = work.appendingPathComponent("linked")
        try writeProject(linked, files: ["ms/main.ms": "update = function()\nend\n"])
        try FileManager.default.createDirectory(at: linked.appendingPathComponent("sprites"), withIntermediateDirectories: true)
        let target = work.appendingPathComponent("hero-target.png")
        try Data([0x89, 0x50]).write(to: target)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("sprites/hero.png"),
                                                   withDestinationURL: target)
        XCTAssertThrowsError(try MicroStudioProjectPlan.prepare(projectAt: linked)) { error in
            XCTAssertEqual(error as? MicroStudioArtifactError, .symbolicLink("sprites/hero.png"))
        }

        // A host-managed symlink outside sources/resources must not block a build.
        let inputs = work.appendingPathComponent("linked-inputs")
        try writeProject(inputs, files: ["ms/main.ms": "update = function()\nend\n",
                                         "story.txt": "kept\n"])
        let outside = work.appendingPathComponent("outside-floe-inputs.json")
        try NarrativeInputs.encodedDefault(for: .microStudio).write(to: outside)
        try FileManager.default.createSymbolicLink(at: inputs.appendingPathComponent(NarrativeInputs.fileName),
                                                   withDestinationURL: outside)
        let plan = try MicroStudioProjectPlan.prepare(projectAt: inputs)
        XCTAssertEqual(plan.sources.count, 1)
    }


    func testImportPreservesOriginalLicensesAndAddsNoStarterNotice() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ms-license-import")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("original")
        let license = "Original Game License 1.0 — custom, non-MIT.\n"
        let notice = "Original game NOTICE — assets by the fixture author.\n"
        try writeProject(source, files: [
            "src/main.ms": "update = function()\nend\n",
            "LICENSE": license,
            "NOTICE": notice,
            "licenses/THIRD-PARTY.txt": "third-party terms, preserved\n"
        ])
        let imported = work.appendingPathComponent("imported")
        try GameMicroStudioAdapter.importProject(from: source, to: imported, title: "Imported license")
        XCTAssertEqual(try NarrativeTestSupport.read(imported.appendingPathComponent("LICENSE")), Data(license.utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(imported.appendingPathComponent("NOTICE")), Data(notice.utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(imported.appendingPathComponent("licenses/THIRD-PARTY.txt")),
                       Data("third-party terms, preserved\n".utf8))
        // Import adds only metadata/input declarations, never licensing files.
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: imported.appendingPathComponent("licenses/LICENSE.microstudio.txt").path))
        let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try NarrativeTestSupport.read(imported.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertNil(metadata["template"])
        XCTAssertEqual(metadata["engineLicense"] as? String, "MIT")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported.appendingPathComponent(NarrativeInputs.fileName).path))

        let artifact = work.appendingPathComponent("artifact")
        try GameMicroStudioAdapter.buildArtifact(projectAt: imported, to: artifact,
                                                 resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("licenses/original/LICENSE")),
                       Data(license.utf8))
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent("licenses/original/NOTICE")),
                       Data(notice.utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/LICENSE.microstudio.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/FLOE-COMPONENT-MPL-2.0.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))
    }

    func testCreatedStarterKeepsStarterNotice() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ms-starter-license")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try GameMicroStudioAdapter.createProject(at: project, title: "Starter license")
        let metadata = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try NarrativeTestSupport.read(project.appendingPathComponent("project.json"))) as? [String: Any])
        XCTAssertEqual(metadata["template"] as? String, "floe-starter")
        XCTAssertEqual(metadata["starterLicense"] as? String, "MIT")
        let artifact = work.appendingPathComponent("artifact")
        try GameMicroStudioAdapter.buildArtifact(projectAt: project, to: artifact,
                                                 resources: NarrativeTestSupport.resources)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/FLOE-STARTER-MIT.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.appendingPathComponent("licenses/LICENSE.microstudio.txt").path))
    }

    func testSingleOrdinarySourceKeepsUnwrappedCodeInDataFile() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("ms-single")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try writeProject(project, files: [
            "src/main.ms": "init = function()\n  x = 1\nend\n"
        ])
        let artifact = work.appendingPathComponent("artifact")
        try GameMicroStudioAdapter.buildArtifact(projectAt: project, to: artifact,
                                                 resources: NarrativeTestSupport.resources)
        let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
        let support = try NarrativeTestSupport.supportText(in: artifact)
        XCTAssertFalse(html.contains("<script id=\"code\""))
        XCTAssertTrue(support.contains("code.textContent = sourceDocument.code"))
        let document = try sourceDocument(artifact)
        XCTAssertEqual(document["format"] as? String, "floe-microstudio-sources")
        XCTAssertEqual((document["code"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       "init = function()\n  x = 1\nend")
        let resources = try resourceDocument(artifact)
        XCTAssertEqual((resources["images"] as? [Any])?.count, 0)
        XCTAssertEqual((resources["maps"] as? [String: Any])?.count, 0)
    }

    // MARK: - Helpers

    func writeProject(_ root: URL, files: [String: Any]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (path, value) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch value {
            case let data as Data: try data.write(to: url)
            case let text as String: try Data(text.utf8).write(to: url)
            default: throw XCTSkip("unsupported fixture value for \(path)")
            }
        }
    }

    func resourceDocument(_ artifact: URL) throws -> [String: Any] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: NarrativeTestSupport.read(artifact.appendingPathComponent("game/resources.json"))) as? [String: Any])
        return try XCTUnwrap(object["resources"] as? [String: Any])
    }

    func sourceDocument(_ artifact: URL) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(
            with: NarrativeTestSupport.read(artifact.appendingPathComponent("game/microstudio-sources.json"))) as? [String: Any])
    }
}
