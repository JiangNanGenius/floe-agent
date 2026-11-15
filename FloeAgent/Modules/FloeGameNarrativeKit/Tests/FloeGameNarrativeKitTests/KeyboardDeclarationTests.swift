// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameNarrativeKit

final class KeyboardDeclarationTests: XCTestCase {
    private func declaration(_ project: URL) throws -> NarrativeInputs.Declaration {
        let data = try Data(contentsOf: project.appendingPathComponent(NarrativeInputs.fileName))
        return try JSONDecoder().decode(NarrativeInputs.Declaration.self, from: data)
    }

    func testCreatedProjectsDeclareTruthfulDefaults() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("inputs")
        defer { try? FileManager.default.removeItem(at: work) }
        let cases: [(GameEngineID, (URL, String) throws -> Void)] = [
            (.ink, { try GameInkAdapter.createProject(at: $0, title: $1) }),
            (.twine, { try GameTwineAdapter.createProject(at: $0, title: $1) }),
            (.wasm4, { try GameWasm4Adapter.createProject(at: $0, title: $1) }),
            (.tic80, { try GameTIC80Adapter.createProject(at: $0, title: $1) }),
            (.microStudio, { try GameMicroStudioAdapter.createProject(at: $0, title: $1) })
        ]
        for (engine, create) in cases {
            let project = work.appendingPathComponent(engine.rawValue + "-project")
            try create(project, "Keyboard check")
            let declaration = try declaration(project)
            XCTAssertEqual(declaration.schemaVersion, 1, engine.rawValue)
            XCTAssertEqual(declaration.engine, engine.rawValue, engine.rawValue)
            XCTAssertLessThanOrEqual(declaration.buttons.count, 32)
            switch engine {
            case .ink, .twine:
                XCTAssertEqual(declaration.movement.up, ["up"])
                XCTAssertEqual(declaration.movement.down, ["down"])
                XCTAssertEqual(declaration.buttons.map(\.id), ["confirm"])
                // keys is a simultaneous chord: one physical key per entry.
                XCTAssertEqual(declaration.buttons.first?.keys, ["enter"])
            case .wasm4:
                XCTAssertEqual(declaration.movement.left, ["left"])
                XCTAssertEqual(declaration.movement.right, ["right"])
                XCTAssertEqual(declaration.movement.up, ["up"])
                XCTAssertEqual(declaration.movement.down, ["down"])
                XCTAssertEqual(declaration.buttons.map(\.label), ["X", "Z"])
                XCTAssertEqual(declaration.buttons.map(\.keys), [["x"], ["z"]])
            case .tic80:
                XCTAssertEqual(declaration.movement.left, ["left"])
                XCTAssertEqual(declaration.buttons.map(\.label), ["Z", "X", "A", "S"])
                XCTAssertEqual(declaration.buttons.map(\.keys), [["z"], ["x"], ["a"], ["s"]])
            case .microStudio:
                XCTAssertEqual(declaration.movement.left, ["left"])
                XCTAssertEqual(declaration.movement.right, ["right"])
                XCTAssertEqual(declaration.movement.up, ["up"])
                XCTAssertEqual(declaration.movement.down, ["down"])
                XCTAssertTrue(declaration.buttons.isEmpty) // movement-only starter
            default:
                XCTFail("unexpected engine")
            }
        }
    }

    func testArtifactsCarryDeclarationAndKeyHandlers() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("inputs-artifacts")
        defer { try? FileManager.default.removeItem(at: work) }
        let cases: [(GameEngineID, String, (URL, URL, URL) throws -> Void)] = [
            (.ink, "ink", { try GameInkAdapter.buildArtifact(projectAt: $0, to: $1, resources: $2) }),
            (.twine, "twine", { try GameTwineAdapter.buildArtifact(projectAt: $0, to: $1, resources: $2) }),
            (.wasm4, "wasm4", { try GameWasm4Adapter.buildArtifact(projectAt: $0, to: $1, resources: $2) }),
            (.tic80, "tic80", { try GameTIC80Adapter.buildArtifact(projectAt: $0, to: $1, resources: $2) }),
            (.microStudio, "microStudio", { try GameMicroStudioAdapter.buildArtifact(projectAt: $0, to: $1, resources: $2) })
        ]
        for (engine, name, build) in cases {
            let project = work.appendingPathComponent(name + "-project")
            try create(engine: engine, at: project)
            let artifact = work.appendingPathComponent(name + "-artifact")
            try build(project, artifact, NarrativeTestSupport.resources)
            let declared = try NarrativeTestSupport.read(project.appendingPathComponent(NarrativeInputs.fileName))
            let copied = try NarrativeTestSupport.read(artifact.appendingPathComponent(NarrativeInputs.fileName))
            XCTAssertEqual(copied, declared, engine.rawValue)
            let html = try NarrativeTestSupport.text(artifact.appendingPathComponent("index.html"))
            let scripts = html + "\n" + (try NarrativeTestSupport.supportText(in: artifact))
            XCTAssertTrue(scripts.contains("key: function (event)"), "missing key(event) handler for \(engine.rawValue)")
            if engine == .ink || engine == .twine {
                // Real DOM keyboard listeners, not only the semantic input API.
                XCTAssertTrue(scripts.contains("addEventListener(\"keydown\""), engine.rawValue)
                XCTAssertTrue(scripts.contains("addEventListener(\"keyup\""), engine.rawValue)
            }
            if engine == .tic80 || engine == .microStudio {
                XCTAssertTrue(scripts.contains("dispatchKey"), engine.rawValue)
            }
            let package = try NarrativeTestSupport.artifactPackage(sourceRoot: artifact, engine: engine)
            try package.verify()
        }
    }

    func testImportedCustomDeclarationIsPreservedAndInvalidFallsBack() throws {
        let work = try NarrativeTestSupport.temporaryDirectory("inputs-import")
        defer { try? FileManager.default.removeItem(at: work) }
        let source = work.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("VAR x = 1\n-> start\n=== start ===\nhi\n-> END\n".utf8)
            .write(to: source.appendingPathComponent("story.ink"))
        let custom = NarrativeInputs.Declaration(engine: "ink",
            movement: .init(left: [], right: [], up: ["w"], down: ["s"]),
            buttons: [.init(id: "confirm", label: "Q", keys: ["q"])])
        try NarrativeInputs.encoded(custom).write(to: source.appendingPathComponent(NarrativeInputs.fileName))

        let imported = work.appendingPathComponent("imported")
        try GameInkAdapter.importProject(from: source, to: imported, title: "Custom")
        XCTAssertEqual(try declaration(imported).buttons.first?.keys, ["q"])
        let artifact = work.appendingPathComponent("artifact")
        try GameInkAdapter.buildArtifact(projectAt: imported, to: artifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try declaration(artifact).buttons.first?.keys, ["q"])

        // A declaration for a different engine is never silently used.
        let foreign = work.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("VAR x = 1\n-> start\n=== start ===\nx\n-> END\n".utf8)
            .write(to: foreign.appendingPathComponent("story.ink"))
        try NarrativeInputs.encoded(NarrativeInputs.defaultDeclaration(for: .twine))
            .write(to: foreign.appendingPathComponent(NarrativeInputs.fileName))
        let foreignArtifact = work.appendingPathComponent("foreign-artifact")
        try GameInkAdapter.buildArtifact(projectAt: foreign, to: foreignArtifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try declaration(foreignArtifact).engine, "ink")
        XCTAssertEqual(try declaration(foreignArtifact).buttons.first?.label, "Enter")
    }

    func testInvalidDeclarationsNeverBecomeAuthority() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("inputs-bounds")
        defer { try? FileManager.default.removeItem(at: work) }

        // Oversize declaration (300 KiB > 256 KiB bound) is rejected before use.
        let oversize = work.appendingPathComponent("oversize")
        try FileManager.default.createDirectory(at: oversize, withIntermediateDirectories: true)
        try Data("VAR x = 1\n-> start\n=== start ===\nx\n-> END\n".utf8)
            .write(to: oversize.appendingPathComponent("story.ink"))
        let padding = String(repeating: " ", count: 300 * 1_024)
        try ("{\"schemaVersion\":1," + padding).write(to: oversize.appendingPathComponent(NarrativeInputs.fileName),
                                                        atomically: true, encoding: .utf8)
        if case .invalid(let reason) = NarrativeInputs.status(inProject: oversize, for: .ink) {
            XCTAssertTrue(reason.contains("larger"), reason)
        } else { XCTFail("oversize declaration was accepted") }
        let oversizeArtifact = work.appendingPathComponent("oversize-artifact")
        try GameInkAdapter.buildArtifact(projectAt: oversize, to: oversizeArtifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try declaration(oversizeArtifact).buttons.first?.label, "Enter")

        // A symlinked declaration is refused (no escape read) and falls back.
        let linkRoot = work.appendingPathComponent("symlink")
        try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        try Data("VAR x = 1\n-> start\n=== start ===\nx\n-> END\n".utf8)
            .write(to: linkRoot.appendingPathComponent("story.ink"))
        let outside = work.appendingPathComponent("outside-inputs.json")
        try NarrativeInputs.encoded(NarrativeInputs.defaultDeclaration(for: .twine))
            .write(to: outside)
        try FileManager.default.createSymbolicLink(at: linkRoot.appendingPathComponent(NarrativeInputs.fileName),
                                                   withDestinationURL: outside)
        if case .invalid(let reason) = NarrativeInputs.status(inProject: linkRoot, for: .ink) {
            XCTAssertTrue(reason.contains("symbolic"), reason)
        } else { XCTFail("symlinked declaration was accepted") }
        let linkArtifact = work.appendingPathComponent("symlink-artifact")
        try GameInkAdapter.buildArtifact(projectAt: linkRoot, to: linkArtifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try declaration(linkArtifact).engine, "ink")
        XCTAssertEqual(try declaration(linkArtifact).buttons.first?.label, "Enter")

        // Absent declaration is reported as such and the engine default applies.
        let absent = work.appendingPathComponent("absent")
        try FileManager.default.createDirectory(at: absent, withIntermediateDirectories: true)
        XCTAssertEqual(NarrativeInputs.status(inProject: absent, for: .wasm4), .absent)
        let resolution = try NarrativeInputs.resolutionForArtifact(project: absent, engine: .wasm4)
        XCTAssertTrue(resolution.usedDefault)
        XCTAssertNil(resolution.reason)
    }

    func testValidDeclarationIsCopiedByteExactAndReasonReported() throws {
        try NarrativeTestSupport.requireResources()
        let work = try NarrativeTestSupport.temporaryDirectory("inputs-resolution")
        defer { try? FileManager.default.removeItem(at: work) }
        let project = work.appendingPathComponent("project")
        try GameTIC80Adapter.createProject(at: project, title: "Bytes")
        let rawURL = project.appendingPathComponent(NarrativeInputs.fileName)
        // Reformat the declaration (still valid) and confirm the artifact keeps
        // exactly these bytes rather than re-encoding them.
        let declaration = try JSONDecoder().decode(NarrativeInputs.Declaration.self, from: Data(contentsOf: rawURL))
        let reformatted = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "engine": declaration.engine,
            "movement": ["left": ["left"], "right": ["right"], "up": ["up"], "down": ["down"]],
            "buttons": [["id": "confirm", "label": "Z", "keys": ["z"]]]
        ], options: [.sortedKeys])
        try reformatted.write(to: rawURL)
        let resolution = try NarrativeInputs.resolutionForArtifact(project: project, engine: .tic80)
        XCTAssertFalse(resolution.usedDefault)
        XCTAssertEqual(resolution.data, reformatted)
        let artifact = work.appendingPathComponent("artifact")
        try GameTIC80Adapter.buildArtifact(projectAt: project, to: artifact, resources: NarrativeTestSupport.resources)
        XCTAssertEqual(try NarrativeTestSupport.read(artifact.appendingPathComponent(NarrativeInputs.fileName)), reformatted)
        // Invalid content keeps the raw project file untouched and reports why.
        try Data("{ not json".utf8).write(to: rawURL)
        let fallback = try NarrativeInputs.resolutionForArtifact(project: project, engine: .tic80)
        XCTAssertTrue(fallback.usedDefault)
        XCTAssertEqual(fallback.reason, "invalid JSON shape")
        XCTAssertEqual(try NarrativeTestSupport.read(rawURL), Data("{ not json".utf8))
    }

    private func create(engine: GameEngineID, at project: URL) throws {
        switch engine {
        case .ink: try GameInkAdapter.createProject(at: project, title: "Keyboard")
        case .twine: try GameTwineAdapter.createProject(at: project, title: "Keyboard")
        case .wasm4: try GameWasm4Adapter.createProject(at: project, title: "Keyboard")
        case .tic80: try GameTIC80Adapter.createProject(at: project, title: "Keyboard")
        case .microStudio: try GameMicroStudioAdapter.createProject(at: project, title: "Keyboard")
        default: XCTFail("unexpected engine")
        }
    }
}
