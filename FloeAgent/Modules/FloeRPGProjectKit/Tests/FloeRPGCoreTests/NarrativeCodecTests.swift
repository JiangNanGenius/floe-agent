// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore
@testable import FloeGameEditingCore

final class NarrativeCodecTests: XCTestCase {
    func testXPMapContainerDecodeEncodeRoundTrip() throws {
        let bytes = try Fixture.data("xp-project/Data/Map001.rxdata")
        let root = try RubyMarshal.parse(bytes)
        let codec = RPGNarrativeCodec(engine: .rpgMakerXP)
        let document = try codec.decodeBinaryEventContainer(root, title: "Map001")
        XCTAssertEqual(document.commands.count, 10) // two events x five commands
        XCTAssertEqual(document.labels.count, 2) // container labels (event-1-page-0, event-2-page-0)
        let merged = try codec.encodeBinaryEventContainer(document, mergingInto: root)
        XCTAssertEqual(try RubyMarshal.serialize(merged), bytes, "narrative roundtrip must be byte-identical")
    }

    func testXPTextEditChangesOnlyTargetCommand() throws {
        let bytes = try Fixture.data("xp-project/Data/Map001.rxdata")
        let root = try RubyMarshal.parse(bytes)
        let codec = RPGNarrativeCodec(engine: .rpgMakerXP)
        let document = try codec.decodeBinaryEventContainer(root, title: "Map001")
        guard let row = document.commands.first(where: { $0.code == "401" }) else { return XCTFail("no 401 row") }
        let edited = document.updating(id: row.id) { command in
            command.parameters["text"] = .string("The ferry leaves at dusk. Bring lantern.")
        }
        let merged = try codec.encodeBinaryEventContainer(edited, mergingInto: root)
        let reencoded = try RubyMarshal.serialize(merged)
        XCTAssertNotEqual(reencoded, bytes)
        let reread = try codec.decodeBinaryEventContainer(try RubyMarshal.parse(reencoded), title: "Map001")
        let newRow = try XCTUnwrap(reread.commands.first(where: { $0.code == "401" }))
        XCTAssertEqual(newRow.parameters["text"]?.stringValue, "The ferry leaves at dusk. Bring lantern.")
        // Unknown command row still present and untouched.
        XCTAssertTrue(reread.commands.contains(where: { $0.code == "unknown-999" && $0.isSupported == false }))
    }

    func testXPCommonEventsContainerPreservesTriggersAndNames() throws {
        let bytes = try Fixture.data("xp-project/Data/CommonEvents.rxdata")
        let root = try RubyMarshal.parse(bytes)
        let codec = RPGNarrativeCodec(engine: .rpgMakerXP)
        let document = try codec.decodeBinaryEventContainer(root, title: "CommonEvents")
        XCTAssertEqual(document.commands.count, 2) // one command per common event
        let merged = try codec.encodeBinaryEventContainer(document, mergingInto: root)
        XCTAssertEqual(try RubyMarshal.serialize(merged), bytes)
        // Names and triggers survived.
        let reread = try RPGDataDocument.decode(try RubyMarshal.serialize(merged), kind: .commonEvents, engine: .rpgMakerXP)
        XCTAssertEqual(reread.binaryRecord(1)?.stringMember("@name"), "GiveRope")
        XCTAssertEqual(reread.binaryRecord(2)?.stringMember("@name"), "FerryDeparts")
    }

    func testMVMapContainerTextEditAndUnknownPreserved() throws {
        let bytes = try Fixture.data("mv-project/data/Map001.json")
        let root = try JSONValue.parse(bytes)
        let codec = RPGNarrativeCodec(engine: .rpgMakerMV)
        let document = try codec.decodeJSONEventContainer(root, title: "Map001.json")
        XCTAssertEqual(document.commands.count, 7) // event 1: 4 commands, event 2: 3
        guard let row = document.commands.first(where: { $0.parameters["text"]?.stringValue == "The tide turns soon." }) else {
            return XCTFail("text row missing")
        }
        let edited = document.updating(id: row.id) { command in
            command.parameters["text"] = .string("The tide has turned.")
        }
        let merged = try codec.encodeJSONEventContainer(edited, mergingInto: root)
        let object = try XCTUnwrap(merged.objectValue)
        XCTAssertEqual(object["displayName"]?.stringValue, "Bracken Quay", "unknown map fields preserved")
        XCTAssertEqual(object["note"]?.stringValue, "<mapnote:original>")
        let reevents = merged["events"]?[1]?["pages"]?[0]?["list"]?.arrayValue
        XCTAssertEqual(reevents?.first(where: { $0["code"]?.intValue == 401 })?["parameters"]?.arrayValue?.first?.stringValue,
                       "The tide has turned.")
        XCTAssertEqual(reevents?.first(where: { $0["code"]?.intValue == 999 }), .object([
            "code": .number(999), "indent": .number(0),
            "parameters": .array([.string("plugin-marker"), .object(["k": .number(1)])]),
        ]))
    }

    func testMVCommonEventsContainer() throws {
        let bytes = try Fixture.data("mv-project/data/CommonEvents.json")
        let root = try JSONValue.parse(bytes)
        XCTAssertNotNil(root.arrayValue, "standard CommonEvents.json is a raw array")
        let codec = RPGNarrativeCodec(engine: .rpgMakerMV)
        let document = try codec.decodeJSONEventContainer(root, title: "CommonEvents.json")
        XCTAssertEqual(document.commands.count, 2)
        let merged = try codec.encodeJSONEventContainer(document, mergingInto: root)
        XCTAssertEqual(merged, root, "unchanged JSON common events roundtrip")
    }

    func testValidationFindsUnsupportedCommandsButNotBranches() throws {
        let bytes = try Fixture.data("xp-project/Data/Map001.rxdata")
        let root = try RubyMarshal.parse(bytes)
        let codec = RPGNarrativeCodec(engine: .rpgMakerXP)
        let document = try codec.decodeBinaryEventContainer(root, title: "Map001")
        let issues = document.validationIssues()
        XCTAssertTrue(issues.contains(where: { $0.kind == .unsupportedCommandPresent }))
        XCTAssertFalse(issues.contains(where: { $0.kind == .unbalancedOpen || $0.kind == .unbalancedClose }))
    }
}
