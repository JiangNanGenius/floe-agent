// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore

final class ScriptsArchiveTests: XCTestCase {
    func testXPArchiveDecodesOrderTitlesAndSources() throws {
        let scripts = try RPGScriptArchive.decode(Fixture.data("xp-project/Data/Scripts.rxdata"))
        XCTAssertEqual(scripts.count, 3)
        XCTAssertEqual(scripts[0].magic, 1)
        XCTAssertEqual(scripts[0].title.utf8String, "Main")
        XCTAssertEqual(String(data: scripts[0].source, encoding: .utf8), "puts 'Brackenfell boot'")
        XCTAssertEqual(scripts[1].title.utf8String, "FerryPlugin")
        XCTAssertTrue(String(data: scripts[1].source, encoding: .utf8)?.contains("ferry_ready?") == true)
        // Binary script payload preserved exactly (non-UTF8 bytes).
        XCTAssertEqual([UInt8](scripts[2].source), [137, 80, 0, 255])
    }

    func testUnmodifiedArchiveRoundTripsByteIdentically() throws {
        let original = try Fixture.data("xp-project/Data/Scripts.rxdata")
        let scripts = try RPGScriptArchive.decode(original)
        let reencoded = try RPGScriptArchive.encode(scripts)
        XCTAssertEqual(reencoded, original)
    }

    func testEditedScriptReencodesAndDecodesWithChangeOnlyThere() throws {
        let original = try Fixture.data("xp-project/Data/Scripts.rxdata")
        var scripts = try RPGScriptArchive.decode(original)
        scripts[1].source = Data("# encoding: utf-8\ndef ferry_ready?\n  false\nend".utf8)
        let reencoded = try RPGScriptArchive.encode(scripts)
        XCTAssertNotEqual(reencoded, original)
        let decoded = try RPGScriptArchive.decode(reencoded)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(String(data: decoded[0].source, encoding: .utf8), "puts 'Brackenfell boot'")
        XCTAssertTrue(String(data: decoded[1].source, encoding: .utf8)?.contains("false") == true)
        XCTAssertEqual([UInt8](decoded[2].source), [137, 80, 0, 255])
        XCTAssertEqual(decoded[1].title.utf8String, "FerryPlugin")
    }

    func testScriptReorderAndInsert() throws {
        var scripts = try RPGScriptArchive.decode(Fixture.data("xp-project/Data/Scripts.rxdata"))
        let first = scripts.removeFirst()
        scripts.insert(first, at: 1)
        scripts.append(RPGScript(magic: 9, title: .utf8("LateAddon"), source: Data("puts 9".utf8)))
        let decoded = try RPGScriptArchive.decode(try RPGScriptArchive.encode(scripts))
        XCTAssertEqual(decoded.map { $0.title.utf8String }, ["FerryPlugin", "Main", "UnknownGameData", "LateAddon"])
    }

    func testCorruptCompressedPayloadThrows() throws {
        var scripts = try RPGScriptArchive.decode(Fixture.data("xp-project/Data/Scripts.rxdata"))
        scripts[0].source = Data("changed".utf8)
        scripts[0] = RPGScript(magic: scripts[0].magic, title: scripts[0].title, source: scripts[0].source)
        let bytes = try RPGScriptArchive.encode(scripts)
        // Corrupt the zlib payload of the first entry by rebuilding manually.
        let root = try RubyMarshal.parse(bytes)
        guard case .array(let entries) = root.value.kind,
              case .array(let triple) = entries[0].value.kind,
              case .string(var payload) = triple[2].value.kind else { return XCTFail("shape") }
        payload.bytes[4] ^= 0xff
        triple[2].value.kind = .string(payload)
        XCTAssertThrowsError(try RPGScriptArchive.decode(root: root))
    }

    func testMalformedArchiveEntryThrows() throws {
        let root = RubyNode(RubyValue(kind: .array([
            RubyNode(RubyValue(kind: .array([RubyNode(RubyValue(kind: .integer(1)))]))), // too few
        ])))
        XCTAssertThrowsError(try RPGScriptArchive.decode(root: root)) { error in
            guard case .malformedArchive = error as? RPGCodecError else { return XCTFail("got \(error)") }
        }
    }
}

final class TableCodecTests: XCTestCase {
    func testTableRoundTripThroughFixtureMap() throws {
        let root = try RubyMarshal.parse(Fixture.data("xp-project/Data/Map001.rxdata"))
        guard let data = root[member: "@data"]?.value.kind.userDefinedData else { return XCTFail("table missing") }
        XCTAssertEqual(data.className, "Table")
        let table = try RPGTable.decode(data.data)
        XCTAssertEqual(table.xSize, 20)
        XCTAssertEqual(table.ySize, 15)
        XCTAssertEqual(table.zSize, 3)
        XCTAssertEqual(table.values.count, 20 * 15 * 3)
        XCTAssertEqual(table.encoded, data.data, "table re-encode must be byte-identical")
        XCTAssertEqual(table.value(x: 3, y: 4, z: 0), Int16((3 + 4) % 8))
    }

    func testTableSetValueAndBounds() throws {
        let root = try RubyMarshal.parse(try Fixture.data("xp-project/Data/Map001.rxdata"))
        let payload = try XCTUnwrap(root[member: "@data"]?.value.kind.userDefinedData)
        var table = try RPGTable.decode(payload.data)
        try table.setValue(777, x: 0, y: 0, z: 1)
        XCTAssertEqual(table.value(x: 0, y: 0, z: 1), 777)
        XCTAssertThrowsError(try table.setValue(1, x: -1, y: 0, z: 0))
        XCTAssertThrowsError(try RPGTable.decode(Data(count: 8)))
        XCTAssertThrowsError(try RPGTable(dimensions: 3, xSize: 2, ySize: 2, zSize: 2, values: [0, 0, 0]))
    }

    func testColorAndToneRoundTrip() throws {
        let color = RPGColor(red: 1.0, green: 0.5, blue: 0.25, alpha: 1.0)
        XCTAssertEqual(try RPGColor.decode(color.encoded), color)
        let tone3 = RPGTone(red: -10, green: 20, blue: 30, gray: 0, componentCount: 3)
        XCTAssertEqual(tone3.encoded.count, 24)
        XCTAssertEqual(try RPGTone.decode(tone3.encoded), tone3)
        let tone4 = RPGTone(red: -10, green: 20, blue: 30, gray: 5)
        XCTAssertEqual(try RPGTone.decode(tone4.encoded), tone4)
        XCTAssertThrowsError(try RPGTone.decode(Data(count: 16)))
    }
}

