// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeGamePortableKit

final class InputAndTemplateTests: XCTestCase {
    func testInputDeclarationValidatesKnownKeys() throws {
        let value = try GamePortableInputDeclaration(engine: .rpgMakerMV,
            movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: [.init(id: "confirm", label: "Ctrl+Z", keys: ["control", "z"]),
                      .init(id: "dash", label: "Shift", keys: ["shift"]),
                      .init(id: "dom", label: "J", keys: ["KeyJ"])])
        let decoded = try GamePortableInputDeclaration.decode(try value.encoded())
        XCTAssertEqual(decoded, value)
        XCTAssertTrue(GamePortableKeyboardVocabulary.isValid("KeyZ"))
        XCTAssertTrue(GamePortableKeyboardVocabulary.isValid("pageUp"))
        XCTAssertFalse(GamePortableKeyboardVocabulary.isValid("exec:rm"))
    }

    func testDefaultsNeverTurnAlternativeKeysIntoAChord() throws {
        for starter in [GamePortableStarter.mv, .love, .renpy] {
            let template = try GamePortableTemplateCatalog.load(starter)
            let data = try GamePortableFileAccess.read(root: template.rootURL, path: "floe-inputs.json", maximumBytes: 65_536)
            let declaration = try GamePortableInputDeclaration.decode(data)
            XCTAssertTrue(declaration.buttons.allSatisfy { $0.keys.count == 1 }, "\(starter)")
            XCTAssertEqual(Set(declaration.buttons.map(\.keys)).count, declaration.buttons.count, "No duplicate preset keys: \(starter)")
        }
    }

    func testPortableDeclarationUsesTheNativeKeyboardContract() throws {
        let data = Data(#"{"schemaVersion":1,"engine":"love","movement":{},"buttons":[{"id":"key.custom-1","keys":["rightControl","NumpadEqual"]}]}"#.utf8)
        let value = try GamePortableInputDeclaration.decode(data)
        XCTAssertEqual(value.movement.left, [])
        XCTAssertEqual(value.buttons[0].id, "key.custom-1")
        XCTAssertEqual(value.buttons[0].keys, ["rightControl", "NumpadEqual"])
        let excessive = (0..<65).map { GamePortableInputDeclaration.Button(id: "key.\($0)", label: "", keys: ["z"]) }
        XCTAssertThrowsError(try GamePortableInputDeclaration(engine: .love, movement: .init(), buttons: excessive))
        let unknown = Data(#"{"schemaVersion":1,"engine":"love","movement":{},"buttons":[],"command":"run"}"#.utf8)
        XCTAssertThrowsError(try GamePortableInputDeclaration.decode(unknown))
    }

    func testInputDeclarationRejectsBadKeyAndDuplicateButton() throws {
        XCTAssertThrowsError(try GamePortableInputDeclaration(engine: .love,
            movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: [.init(id: "confirm", label: "Z", keys: ["z"]),
                      .init(id: "confirm", label: "X", keys: ["x"])]))
        XCTAssertThrowsError(try GamePortableInputDeclaration(engine: .love,
            movement: .init(left: ["shell"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: []))
    }

    func testRuntimePinsBundle() throws {
        let pins = try GamePortableRuntimePins.load()
        XCTAssertEqual(pins.count, 3)
        XCTAssertEqual(Set(pins.map(\.id)), ["rpg-maker-mv-corescript", "lovejs", "renpy-web"])
        for pin in pins {
            XCTAssertFalse(pin.licenseFiles.isEmpty)
            XCTAssertTrue(pin.prepareScript.hasSuffix(".py"))
        }
    }

    func testTemplateCatalogAndTemplates() throws {
        let summaries = try GamePortableTemplateCatalog.summaries()
        XCTAssertEqual(summaries.count, 3)
        for summary in summaries {
            XCTAssertGreaterThan(summary.files, 2)
            XCTAssertGreaterThan(summary.bytes, 100)
            let template = try GamePortableTemplateCatalog.load(summary.starter)
            XCTAssertEqual(template.engine, summary.engine)
            XCTAssertTrue(template.files.contains { $0.path == template.entry })
        }
        let mv = try GamePortableTemplateCatalog.load(.mv)
        let declarationData = try GamePortableFileAccess.read(root: mv.rootURL, path: "floe-inputs.json", maximumBytes: 65_536)
        let declaration = try GamePortableInputDeclaration.decode(declarationData)
        XCTAssertEqual(declaration.engine, .rpgMakerMV)
        XCTAssertTrue(declaration.buttons.contains { $0.id == "confirm" && $0.keys.contains("z") })
    }

    func testOverlayInstallerAddsBridgeAndScriptAndLeavesSourceTemplatesAlone() throws {
        let root = try TestSupport.temporaryDirectory("overlay")
        try TestSupport.write("<html><body></body></html>", to: root, path: "index.html")
        try GamePortableOverlayInstaller.install(engine: .love, into: root)
        let index = try String(contentsOf: root.appendingPathComponent("index.html"), encoding: .utf8)
        XCTAssertTrue(index.contains("floe_bridge.js"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("floe-inputs.json").path))
        let declaration = try GamePortableInputDeclaration.decode(
            Data(contentsOf: root.appendingPathComponent("floe-inputs.json")))
        XCTAssertEqual(declaration.engine, .love)

        let renpy = try TestSupport.temporaryDirectory("overlay-renpy")
        try TestSupport.write("<html><body>RenPy</body></html>", to: renpy, path: "index.html")
        try GamePortableOverlayInstaller.install(engine: .renpy, into: renpy)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renpy.appendingPathComponent("floe_bridge.js").path))
    }
}
