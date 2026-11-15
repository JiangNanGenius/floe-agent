// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreFoundation
@testable import FloeGameDeveloperCore
import FloeGameCore

private func mutatedCapabilities(_ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
    let base = try JSONEncoder().encode(DeveloperTestSupport.capabilities())
    var object = try JSONSerialization.jsonObject(with: base) as! [String: Any]
    try mutate(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

@Test func decimalReadOnlyStateIsAccepted() throws {
    let capabilities = DeveloperTestSupport.capabilities()
    let state = DeveloperTestSupport.state()
    let data = try JSONEncoder().encode(state)
    let decoded = try GameDeveloperWire.decodeState(data, capabilities: capabilities, limits: .default)
    #expect(decoded.values["camera.roll"] == .number(1.25))
    #expect(decoded.values["player.x"] == .number(12.5))
}

@Test func fractionalIntegerStateIsRejected() throws {
    let capabilities = DeveloperTestSupport.capabilities()
    var object = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(DeveloperTestSupport.state())) as! [String: Any]
    var values = object["values"] as! [String: Any]
    values["party.gold"] = 12.5
    object["values"] = values
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(throws: GameDeveloperError.self) {
        _ = try GameDeveloperWire.decodeState(data, capabilities: capabilities, limits: .default)
    }
}

@Test func unknownStateFieldIsRejected() throws {
    let capabilities = DeveloperTestSupport.capabilities()
    var object = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(DeveloperTestSupport.state())) as! [String: Any]
    var values = object["values"] as! [String: Any]
    values["__proto__"] = 1
    object["values"] = values
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(throws: GameDeveloperError.self) {
        _ = try GameDeveloperWire.decodeState(data, capabilities: capabilities, limits: .default)
    }
}

@Test func hostileFieldIdentifierIsRejected() throws {
    let data = try mutatedCapabilities { object in
        var fields = object["fields"] as! [[String: Any]]
        fields[0]["id"] = "__proto__"
        object["fields"] = fields
    }
    #expect(throws: GameDeveloperError.self) {
        _ = try GameDeveloperWire.decodeCapabilities(data, expectedEngine: .phaser, limits: .default)
    }
}

@Test func oversizedAndDuplicateFieldListsAreRejected() throws {
    let duplicate = try mutatedCapabilities { object in
        var fields = object["fields"] as! [[String: Any]]
        fields.append(fields[0])
        object["fields"] = fields
    }
    #expect(throws: GameDeveloperError.self) {
        _ = try GameDeveloperWire.decodeCapabilities(duplicate, expectedEngine: .phaser, limits: .default)
    }
}

@Test func displayTextDoesNotTrapForHugeOrNonFiniteNumbers() {
    #expect(!GameDeveloperValue.number(1e300).displayText.isEmpty)
    #expect(GameDeveloperValue.number(.infinity).displayText == "—")
    #expect(GameDeveloperValue.number(.nan).displayText == "—")
    #expect(GameDeveloperValue.number(-0.0).displayText == "0")
}

@Test func wireValidationRejectsOutOfRangeAndWrongTypes() throws {
    let capabilities = DeveloperTestSupport.capabilities()
    let gold = try #require(capabilities.field("party.gold"))
    #expect(throws: GameDeveloperError.self) {
        try GameDeveloperWire.validate(value: .integer(100_000_000), against: gold, limits: .default)
    }
    #expect(throws: GameDeveloperError.self) {
        try GameDeveloperWire.validate(value: .text("12"), against: gold, limits: .default)
    }
    let roll = try #require(capabilities.field("camera.roll"))
    #expect(throws: Never.self) {
        try GameDeveloperWire.validate(value: .number(1.25), against: roll, limits: .default)
    }
    let paused = try #require(capabilities.field("engine.paused"))
    #expect(throws: GameDeveloperError.self) {
        try GameDeveloperWire.validate(value: .integer(1), against: paused, limits: .default)
    }
}

@Test func changeEncodingIsBounded() throws {
    let changes = (0..<33).map { _ in GameDeveloperFieldChange(id: "party.gold", value: .integer(1)) }
    #expect(throws: GameDeveloperError.self) {
        _ = try GameDeveloperWire.encodeChanges(changes, limits: .default)
    }
    let one = try GameDeveloperWire.encodeChanges(
        [.init(id: "party.gold", value: .integer(1))], limits: .default)
    #expect(!one.isEmpty)
}

@Test func snapshotEncodingKeepsNumericOneDistinctFromBoolean() throws {
    let object: [String: Any] = [
        "values": ["engine.speed": 1, "engine.paused": true, "ratio": 1.25]
    ]
    let data = try JSONEncoder().encode(AnyEncodable(object))
    let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let values = decoded["values"] as! [String: Any]
    let speed = try #require(values["engine.speed"] as? NSNumber)
    let paused = try #require(values["engine.paused"] as? NSNumber)
    #expect(CFGetTypeID(speed) != CFBooleanGetTypeID())
    #expect(CFGetTypeID(paused) == CFBooleanGetTypeID())
    #expect(speed.doubleValue == 1)
    #expect((values["ratio"] as? NSNumber)?.doubleValue == 1.25)
}
