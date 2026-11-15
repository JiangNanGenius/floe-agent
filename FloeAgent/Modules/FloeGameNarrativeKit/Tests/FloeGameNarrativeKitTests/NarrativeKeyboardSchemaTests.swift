// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeGameNarrativeKit
import FloeGameCore

final class NarrativeKeyboardSchemaTests: XCTestCase {
    private func withProject(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testNativeSchemaAcceptsSixtyFourCustomChordsAndPreservesRawBytes() throws {
        try withProject { root in
            let buttons: [[String: Any]] = (0..<64).map {
                ["id": "custom-\($0)", "keys": ["ControlRight", "KeyZ"]]
            }
            let raw = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "engine": "ink",
                "movement": ["right": ["ArrowRight"]], "buttons": buttons
            ], options: [.prettyPrinted])
            try raw.write(to: root.appendingPathComponent(NarrativeInputs.fileName))
            guard case .valid(let declaration) = NarrativeInputs.status(inProject: root, for: .ink) else {
                return XCTFail("Native-valid keyboard settings must survive narrative import")
            }
            XCTAssertEqual(declaration.buttons.count, 64)
            XCTAssertEqual(declaration.buttons[63].keys, ["ControlRight", "KeyZ"])
            XCTAssertEqual(declaration.buttons[0].label, "")
            XCTAssertEqual(declaration.movement.left, [])
            let result = try NarrativeInputs.resolutionForArtifact(project: root, engine: .ink)
            XCTAssertFalse(result.usedDefault)
            XCTAssertEqual(result.data, raw)
        }
    }

    func testExplicitEmptyControlsRemainUnboundAndUnknownFieldsCannotHide() throws {
        try withProject { root in
            let file = root.appendingPathComponent(NarrativeInputs.fileName)
            let raw = Data(#"{"schemaVersion":1,"engine":"ink","movement":{},"buttons":[]}"#.utf8)
            try raw.write(to: file)
            guard case .valid(let declaration) = NarrativeInputs.status(inProject: root, for: .ink) else {
                return XCTFail("Explicit empty controls are meaningful")
            }
            XCTAssertTrue(declaration.buttons.isEmpty)
            XCTAssertTrue(declaration.movement.up.isEmpty)
            XCTAssertEqual(try NarrativeInputs.resolutionForArtifact(project: root, engine: .ink).data, raw)
            for invalid in [
                #"{"schemaVersion":1,"engine":"ink","buttons":[],"command":"run"}"#,
                #"{"schemaVersion":1,"engine":"ink","buttons":[{"id":"custom","keys":["not-a-real-key"]}]}"#
            ] {
                try Data(invalid.utf8).write(to: file)
                guard case .invalid = NarrativeInputs.status(inProject: root, for: .ink) else {
                    return XCTFail("Unknown fields and unsupported keys must be rejected")
                }
                XCTAssertTrue(try NarrativeInputs.resolutionForArtifact(project: root, engine: .ink).usedDefault)
            }
        }
    }
}
