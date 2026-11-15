// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameEditingCore
@testable import FloeRPGCore

final class BinaryDatabaseTests: XCTestCase {
    func testXPActorRecordsReadEditAndPreserveUnknownFields() throws {
        let bytes = try Fixture.data("xp-project/Data/Actors.rxdata")
        var document = try RPGDataDocument.decode(bytes, kind: .actors, engine: .rpgMakerXP)
        let records = document.binaryRecords()
        XCTAssertEqual(records.count, 3)
        XCTAssertNil(records[0])
        let first = try XCTUnwrap(document.binaryRecord(1))
        XCTAssertEqual(RPGRecordView(node: first).name, "Kestrel")

        // Edit name; verify changed field and untouched unknown fields.
        var view = RPGRecordView(node: first)
        view.setName("Kestrel II")
        try document.setBinaryRecord(1, first)
        let reencoded = try document.encode()
        XCTAssertNotEqual(reencoded, bytes)
        let reread = try RPGDataDocument.decode(reencoded, kind: .actors, engine: .rpgMakerXP)
        let edited = try XCTUnwrap(reread.binaryRecord(1))
        XCTAssertEqual(RPGRecordView(node: edited).name, "Kestrel II")
        XCTAssertEqual(edited.intMember("@class_id"), 1)
        // Untouched actor (index 2) round-trips through the edit unchanged.
        let second = try XCTUnwrap(reread.binaryRecord(2))
        XCTAssertEqual(RPGRecordView(node: second).name, "Marlow")
        // Parameter table still decodes after edit.
        guard let params = edited[member: "@parameters"]?.value.kind.userDefinedData else {
            return XCTFail("parameters table lost")
        }
        XCTAssertEqual(params.className, "Table")
        _ = try RPGTable.decode(params.data)
    }

    func testUnchangedDatabaseFileRoundTripsByteIdentically() throws {
        for (name, kind) in [("xp-project/Data/Items.rxdata", RPGDataFileKind.items),
                             ("xp-project/Data/Enemies.rxdata", .enemies),
                             ("xp-project/Data/States.rxdata", .states),
                             ("xp-project/Data/System.rxdata", .system)] as [(String, RPGDataFileKind)] {
            let bytes = try Fixture.data(name)
            let document = try RPGDataDocument.decode(bytes, kind: kind, engine: .rpgMakerXP)
            XCTAssertEqual(try document.encode(), bytes, "\(name) unchanged roundtrip")
        }
    }

    func testVXAceActorNicknameAndUTF8Profile() throws {
        let bytes = try Fixture.data("ace-project/Data/Actors.rvdata2")
        let document = try RPGDataDocument.decode(bytes, kind: .actors, engine: .rpgMakerVXAce)
        let actor = try XCTUnwrap(document.binaryRecord(1))
        XCTAssertEqual(actor.stringMember("@nickname"), "the Sparrow")
        XCTAssertEqual(actor.stringMember("@profile"), "A courier who maps the fenlands.")
        // Unknown VX Ace field @note preserved through a no-op roundtrip.
        XCTAssertEqual(actor.stringMember("@note"), "<currency:glitter>")
    }

    func testSystemWordsHashAndEncodingsPreserved() throws {
        let bytes = try Fixture.data("xp-project/Data/System.rxdata")
        let document = try RPGDataDocument.decode(bytes, kind: .system, engine: .rpgMakerXP)
        let root = try XCTUnwrap(document.root)
        XCTAssertEqual(root.intMember("@magic_number"), 123_456)
        guard let words = root[member: "@words"]?.value.kind.hashValue else { return XCTFail("words lost") }
        guard let gold = words.pairs.first(where: { $0.key.value.kind.stringValue?.utf8String == "gold" }) else {
            return XCTFail("gold word lost")
        }
        XCTAssertEqual(gold.value.value.kind.stringValue?.utf8String, "Glimmer")
        XCTAssertEqual(try document.encode(), bytes)
    }

    func testMarshalJSONInterchangeRoundTripsLosslessly() throws {
        let bytes = try Fixture.data("xp-project/Data/Actors.rxdata")
        let root = try RubyMarshal.parse(bytes)
        let interchange = RPGMarshalJSON.encodeDocument(root)
        let data = try interchange.serialized()
        let decoded = try RPGMarshalJSON.decodeDocument(JSONValue.parse(data))
        let restored = try RubyMarshal.serialize(decoded)
        XCTAssertEqual(restored, bytes, "interchange must be lossless")
    }

    func testMarshalJSONInterchangePreservesCycleGraphs() throws {
        let bytes = try Fixture.data("edge-cases.rxdata")
        let root = try RubyMarshal.parse(bytes)
        let interchange = RPGMarshalJSON.encodeDocument(root)
        let decoded = try RPGMarshalJSON.decodeDocument(JSONValue.parse(try interchange.serialized()))
        XCTAssertEqual(try RubyMarshal.serialize(decoded), bytes)
    }
}
