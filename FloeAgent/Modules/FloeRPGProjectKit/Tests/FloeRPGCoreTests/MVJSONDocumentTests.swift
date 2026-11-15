// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore

final class MVJSONDocumentTests: XCTestCase {
    func testMVActorsEditPreservesUnknownFields() throws {
        let bytes = try Fixture.data("mv-project/data/Actors.json")
        var document = try RPGDataDocument.decode(bytes, kind: .actors, engine: .rpgMakerMV)
        // Standard MV/MZ database files are raw [null, {...}] arrays.
        XCTAssertNotNil(document.json?.arrayValue)
        XCTAssertEqual(document.jsonRecords().count, 3)
        try document.updateJSONRecord(1) { record in
            var object = record.objectValue ?? [:]
            object["name"] = .string("Kestrel II")
            record = .object(object)
        }
        let reencoded = try document.encode()
        let reread = try RPGDataDocument.decode(reencoded, kind: .actors, engine: .rpgMakerMV)
        XCTAssertEqual(reread.json?[1]?["name"]?.stringValue, "Kestrel II")
        // Unknown/plugin fields preserved.
        XCTAssertEqual(reread.json?[2]?["note"]?.stringValue, "<custom:tag>")
        XCTAssertEqual(reread.json?[1]?["profile"]?.stringValue, "Keeps the crossing safe.")
        XCTAssertEqual(reread.json?[1]?["equips"]?.arrayValue?.count, 5)
        XCTAssertTrue(reread.json?.arrayValue != nil, "raw array shape preserved")
    }

    func testMVSystemEditPreservesUnknownKeys() throws {
        let bytes = try Fixture.data("mv-project/data/System.json")
        var document = try RPGDataDocument.decode(bytes, kind: .system, engine: .rpgMakerMV)
        // System is not record-based; edit via json tree directly.
        guard var json = document.json else { return XCTFail("no json") }
        json.setKey(.string("Brackenfell II"), "gameTitle")
        document = RPGDataDocument(kind: .system, engine: .rpgMakerMV, json: json)
        let reread = try RPGDataDocument.decode(try document.encode(), kind: .system, engine: .rpgMakerMV)
        XCTAssertEqual(reread.json?["gameTitle"]?.stringValue, "Brackenfell II")
        XCTAssertEqual(reread.json?["currencyUnit"]?.stringValue, "G")
        XCTAssertEqual(reread.json?["battleBgm"]?.objectValue?["volume"]?.intValue, 90)
    }

    func testMZSystemAdvancedBlockPreserved() throws {
        let bytes = try Fixture.data("mz-project/data/System.json")
        let document = try RPGDataDocument.decode(bytes, kind: .system, engine: .rpgMakerMZ)
        XCTAssertEqual(document.json?["advanced"]?.objectValue?["gameId"]?.intValue, 812_001)
    }

    func testMVItems() throws {
        let bytes = try Fixture.data("mv-project/data/Items.json")
        var document = try RPGDataDocument.decode(bytes, kind: .items, engine: .rpgMakerMV)
        try document.updateJSONRecord(1) { record in
            var object = record.objectValue ?? [:]
            object["price"] = .number(18)
            record = .object(object)
        }
        let reread = try RPGDataDocument.decode(try document.encode(), kind: .items, engine: .rpgMakerMV)
        XCTAssertEqual(reread.json?[1]?["price"]?.intValue, 18)
        XCTAssertEqual(reread.json?[1]?["consumable"]?.boolValue, true)
        XCTAssertEqual(reread.json?[2]?["note"]?.stringValue, "<plugin:keep>")
    }

    func testMVCommonEventsDocument() throws {
        let bytes = try Fixture.data("mv-project/data/CommonEvents.json")
        let document = try RPGDataDocument.decode(bytes, kind: .commonEvents, engine: .rpgMakerMV)
        let records = document.jsonRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1]["name"]?.stringValue, "EnableFerry")
    }
}
