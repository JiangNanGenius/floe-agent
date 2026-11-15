// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameTouch
import FloeGameRGSS

final class RGSSInputTouchInteropTests: XCTestCase {
    func testStandardWriterProducesSingleKeysThroughTheActualTouchDecoder() throws {
        for engine in [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce] {
            let source = try RGSSInputDeclaration.standard(for: engine)
            let decoded = try GameTouchProjectBindings(json: source.jsonData(), engine: engine)
            XCTAssertEqual(decoded.buttons.count, 5)
            XCTAssertEqual(decoded.buttons.first(where: { $0.id.rawValue == "confirm" })?.binding,
                           .key(engine == .rpgMakerXP ? .c : .z))
            XCTAssertEqual(decoded.buttons.first(where: { $0.id.rawValue == "cancel" })?.binding, .key(.x))
            XCTAssertEqual(decoded.buttons.first(where: { $0.id.rawValue == "action1" })?.binding, .key(.shift))
            XCTAssertTrue(source.buttons.allSatisfy { $0.keys.count == 1 })
        }
    }

    func testActualGeneratedProjectInputFileDoesNotPressAllConfirmAlternatives() throws {
        for engine in [GameEngineID.rpgMakerXP, .rpgMakerVX, .rpgMakerVXAce] {
            let files = try RGSSTemplateProvider.files(for: engine)
            let inputs = files.compactMap { change -> Data? in
                if case .write(let path, let bytes, _) = change, path.value == "floe-inputs.json" { return bytes }
                return nil
            }
            XCTAssertEqual(inputs.count, 1)
            let profile = GameTouchProfile.standard(engine,
                projectBindings: try GameTouchProjectBindings(json: XCTUnwrap(inputs.first), engine: engine))
            let confirm = try XCTUnwrap(profile.buttons.first { $0.id.rawValue == "confirm" })
            switch confirm.binding {
            case .key(let key): XCTAssertEqual(key, engine == .rpgMakerXP ? .c : .z)
            default: XCTFail("A default confirmation is one physical key, not a chord")
            }
        }
    }

    func testExplicitUserChordStillRoundTripsWithoutCollapsingKeys() throws {
        let source = RGSSInputDeclaration(engine: .rpgMakerVXAce,
            movement: .init(left: ["left"], right: ["right"], up: ["up"], down: ["down"]),
            buttons: [.init(id: "custom", label: "Ctrl+Z", keys: ["control", "z"])])
        let data = try source.jsonData()
        let original = try RGSSInputDeclaration.decode(data, expectedEngine: .rpgMakerVXAce)
        XCTAssertEqual(original, source)
        let decoded = try GameTouchProjectBindings(json: data, engine: .rpgMakerVXAce)
        guard case .chord(let chord) = try XCTUnwrap(decoded.buttons.first).binding else {
            return XCTFail("An explicit chord must remain a chord")
        }
        XCTAssertEqual(chord.keys, [.control, .z])
    }
}
