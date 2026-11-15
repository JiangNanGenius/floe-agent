// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore

final class MapDocumentTests: XCTestCase {
    func testXPMapTilesEventsAndUnknownCommands() throws {
        var map = try RPGMapDocument.decode(Fixture.data("xp-project/Data/Map001.rxdata"),
                                            engine: .rpgMakerXP, pathName: "Map001.rxdata")
        XCTAssertEqual(map.width, 20)
        XCTAssertEqual(map.height, 15)
        XCTAssertEqual(map.tileLayerCount, 3)
        XCTAssertEqual(map.tile(x: 3, y: 4, z: 0), (3 + 4) % 8)
        XCTAssertEqual(map.tile(x: 3, y: 4, z: 2), (3 + 4 * 2) % 12)
        let events = map.events
        XCTAssertEqual(events.map(\.id), [1, 2])
        XCTAssertEqual(events[0].name, "Ferryman")
        let commands = map.eventCommands(eventID: 1, pageIndex: 0)
        XCTAssertEqual(commands.map(\.code), [101, 401, 117, 999, 0])
        // Unknown command 999 keeps its original parameters.
        XCTAssertEqual(commands[3].parameters, [.string("custom-plugin-payload"), .integer(42), .bool(true)])

        // Edit a tile and an event position; verify.
        try map.setTile(1234, x: 0, y: 0, z: 1)
        XCTAssertEqual(map.tile(x: 0, y: 0, z: 1), 1234)
        try map.moveEvent(id: 2, x: 12, y: 13)
        let movedEvent = map.events.first(where: { $0.id == 2 })
        XCTAssertEqual(movedEvent?.x, 12)
        XCTAssertEqual(movedEvent?.y, 13)
        let reencoded = try map.encode()
        let reread = try RPGMapDocument.decode(reencoded, engine: .rpgMakerXP, pathName: "Map001.rxdata")
        XCTAssertEqual(reread.tile(x: 0, y: 0, z: 1), 1234)
        let rereadMoved = reread.events.first(where: { $0.id == 2 })
        XCTAssertEqual(rereadMoved?.x, 12)
        XCTAssertEqual(rereadMoved?.y, 13)
        XCTAssertEqual(reread.eventCommands(eventID: 1, pageIndex: 0).map(\.code), [101, 401, 117, 999, 0])
    }

    func testUnchangedXPMapRoundTripsByteIdentically() throws {
        let bytes = try Fixture.data("xp-project/Data/Map001.rxdata")
        let map = try RPGMapDocument.decode(bytes, engine: .rpgMakerXP, pathName: "Map001.rxdata")
        XCTAssertEqual(try map.encode(), bytes)
    }

    func testVXMapUsesThreeLayers() throws {
        let bytes = try Fixture.data("vx-project/Data/Map002.rvdata")
        let map = try RPGMapDocument.decode(bytes, engine: .rpgMakerVX, pathName: "Map002.rvdata")
        XCTAssertEqual(map.tileLayerCount, 3)
        XCTAssertEqual(map.tile(x: 4, y: 5, z: 2), (4 + 5 + 2) % 12)
        XCTAssertEqual(try map.encode(), bytes)
    }

    func testMVMapTilesEventsUnknownFields() throws {
        var map = try RPGMapDocument.decode(Fixture.data("mv-project/data/Map001.json"),
                                            engine: .rpgMakerMV, pathName: "Map001.json")
        XCTAssertEqual(map.width, 6)
        XCTAssertEqual(map.height, 5)
        XCTAssertEqual(map.tileLayerCount, 4)
        XCTAssertEqual(map.tile(x: 2, y: 3, z: 1), (2 + 3 * 2 + 1) % 9)
        // Shadow and region channels share the data array; preserved intact.
        XCTAssertEqual(map.json?["data"]?.arrayValue?.count, 6 * 5 * 4)
        let events = map.events
        XCTAssertEqual(events.map(\.id), [1, 2])
        let commands = map.eventCommands(eventID: 1, pageIndex: 0)
        XCTAssertEqual(commands.map(\.code), [101, 401, 999, 0])
        XCTAssertEqual(commands[2].jsonParameters, [.string("plugin-marker"), .object(["k": .number(1)])])

        try map.setTile(77, x: 0, y: 0, z: 3)
        try map.moveEvent(id: 2, x: 1, y: 1)
        // Unknown map-level fields survive.
        let reencoded = try map.encode()
        let reread = try RPGMapDocument.decode(reencoded, engine: .rpgMakerMV, pathName: "Map001.json")
        XCTAssertEqual(reread.tile(x: 0, y: 0, z: 3), 77)
        XCTAssertEqual(reread.json?["note"]?.stringValue, "<mapnote:original>")
        XCTAssertEqual(reread.json?["displayName"]?.stringValue, "Bracken Quay")
        let rereadMoved = reread.events.first(where: { $0.id == 2 })
        XCTAssertEqual(rereadMoved?.x, 1)
        XCTAssertEqual(rereadMoved?.y, 1)
    }

    func testMZMapUnknownPluginCommandPreserved() throws {
        let map = try RPGMapDocument.decode(Fixture.data("mz-project/data/Map002.json"),
                                            engine: .rpgMakerMZ, pathName: "Map002.json")
        let commands = map.eventCommands(eventID: 1, pageIndex: 0)
        XCTAssertEqual(commands.map(\.code), [101, 401, 357, 999, 0])
        // Unknown-to-schema MZ plugin command keeps its payload.
        XCTAssertEqual(commands[2].jsonParameters, [.string("MZPlugin"), .string("setWeather"), .string("rain"), .object([:])])
    }

    func testMapTileBoundsRejected() throws {
        var map = try RPGMapDocument.decode(Fixture.data("mv-project/data/Map001.json"),
                                            engine: .rpgMakerMV, pathName: "Map001.json")
        XCTAssertThrowsError(try map.setTile(1, x: -1, y: 0, z: 0))
        XCTAssertThrowsError(try map.setTile(-5, x: 0, y: 0, z: 0))
        XCTAssertThrowsError(try map.setTile(1, x: 0, y: 0, z: 9))
    }
}
