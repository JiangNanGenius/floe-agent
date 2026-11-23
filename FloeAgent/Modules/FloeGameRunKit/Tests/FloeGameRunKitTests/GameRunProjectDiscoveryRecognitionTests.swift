// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRunKit

final class GameRunProjectDiscoveryRecognitionTests: XCTestCase {
    func testNestedVisualNovelImportsKeepDistinctRoots() async throws {
        let workspace = try TestWorkspace()
        let contents = [
            "Library/Tyrano/index.html": "<script src=\"tyrano/tyrano.js\"></script>",
            "Library/Tyrano/tyrano/tyrano.js": "",
            "Library/Tyrano/tyrano/plugins/kag/kag.js": "",
            "Library/Tyrano/data/scenario/first.ks": "Original fixture",
            "Library/RenPy/game/script.rpyc": "compiled script marker",
            "Library/RenPyArchive/game/archive.rpa":
                "RPA-2.0 0000000000000018" + String(repeating: "x", count: 32),
            "Library/Other/game/other.rpa": "unrelated .rpa suffix",
            "Library/KiriPacked/base/data.xp3": "packed entry marker",
            "Library/KiriLoose/startup.tjs": "var window = new Window();",
            "Library/AssetOnly/sound.xp3": "not an entry archive"
        ]
        let project = try await TestProject.make(workspace: workspace,
                                                 files: contents.mapValues { Data($0.utf8) })
        let stored = try await project.repository.open(project.projectID, owner: project.owner)
        let roots = try await GameRunProjectDiscovery(contexts: project.host)
            .discover(context: project.context, files: stored.files)
        XCTAssertEqual(roots.first { $0.root?.value == "Library/Tyrano" }?.engines, [.tyranoScript])
        XCTAssertEqual(roots.first { $0.root?.value == "Library/RenPy" }?.engines, [.renpy])
        XCTAssertEqual(roots.first { $0.root?.value == "Library/RenPyArchive" }?.engines, [.renpy])
        XCTAssertEqual(roots.first { $0.root?.value == "Library/Other" }?.engines, [])
        XCTAssertEqual(roots.first { $0.root?.value == "Library/KiriPacked/base" }?.engines, [.kirikiri])
        XCTAssertEqual(roots.first { $0.root?.value == "Library/KiriLoose" }?.engines, [.kirikiri])
        XCTAssertFalse(roots.contains { $0.root?.value == "Library/AssetOnly" })
    }

    func testNestedArbitraryNativeJSONAndExportedRootsAreDiscovered() async throws {
        let workspace = try TestWorkspace()
        let prelude = String(repeating: " ", count: 12_000)
        let gdevelop = prelude + #"{"firstLayout":"Main","gdVersion":{"major":5,"minor":6,"revision":0,"build":287},"properties":{"name":"Nested GDevelop"},"layouts":[]}"#
        let files: [String: Data] = [
            "Games/GD/MyGame.json": Data(gdevelop.utf8),
            "Games/Ink/story.json": Data(#"{"inkVersion":21,"root":["^Hello","\n","end",null]}"#.utf8),
            "Games/Export/index.html": Data("<!doctype html><html></html>".utf8),
            "Games/Export/data.js": Data("gdjs.projectData = {};".utf8),
            "Games/Export/gd.js": Data("// unexecuted".utf8),
            "Games/Export/code0.js": Data("// unexecuted".utf8),
            "Unrelated/data.json": Data(#"{"name":"data","version":1}"#.utf8),
            "node_modules/vendor/package.json": Data(#"{"dependencies":{"phaser":"1.0.0"}}"#.utf8)
        ]
        let project = try await TestProject.make(workspace: workspace, files: files)
        let stored = try await project.repository.open(project.projectID, owner: project.owner)
        let roots = try await GameRunProjectDiscovery(contexts: project.host)
            .discover(context: project.context, files: stored.files)

        XCTAssertTrue(roots.contains {
            $0.root?.value == "Games/GD" && $0.engines == [.gdevelop]
        }, "nested arbitrary-name GDevelop JSON must be a real choice")
        XCTAssertTrue(roots.contains {
            $0.root?.value == "Games/Ink" && $0.engines == [.ink]
        }, "nested compiled ink story.json must be a real choice")
        XCTAssertTrue(roots.contains {
            $0.root?.value == "Games/Export" && $0.engines == [.gdevelop]
        }, "nested exported GDevelop root must be a real choice")
        XCTAssertFalse(roots.contains { $0.root?.value == "Unrelated" },
                       "unrelated JSON must not become a choice")

        let reopened = try await project.repository.open(project.projectID, owner: project.owner)
        XCTAssertEqual(reopened.revision, stored.revision)
        XCTAssertEqual(Set(reopened.files.map(\.path.value)), Set(files.keys))
    }

    func testAdditionalNativeJSONRootsStillRespectTheRootLimit() async throws {
        let workspace = try TestWorkspace()
        let files: [String: Data] = [
            "Games/GD/MyGame.json": Data(#"{"gdVersion":{"major":5,"minor":6,"revision":0,"build":287},"properties":{"name":"G"},"layouts":[]}"#.utf8),
            "Games/Ink/story.json": Data(#"{"inkVersion":21,"root":[]}"#.utf8)
        ]
        let project = try await TestProject.make(workspace: workspace, files: files)
        let stored = try await project.repository.open(project.projectID, owner: project.owner)
        let discovery = GameRunProjectDiscovery(contexts: project.host, maximumRoots: 2)
        do {
            _ = try await discovery.discover(context: project.context, files: stored.files)
            XCTFail("Two extra nested roots plus the captured root must exceed maximumRoots")
        } catch GameRunPreparationError.invalidProject(_) {
            // Expected explicit budget failure, never an automatic first choice.
        }
    }
}
