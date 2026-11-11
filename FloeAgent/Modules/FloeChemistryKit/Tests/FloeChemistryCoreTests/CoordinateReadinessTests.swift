import Foundation
import Testing
@testable import FloeChemistryCore

private func coordinateObject(_ coordinates: JSONValue?, elements: [JSONValue] = [.number(8), .number(1), .number(1)]) throws -> ChemicalObject {
    let molecule: JSONValue = .object(["atoms": .object([
        "elements": .object(["number": .array(elements)]),
        "coords": .object(coordinates.map { ["3d": $0] } ?? [:])
    ])])
    let encoded = String(decoding: try JSONEncoder().encode(molecule), as: UTF8.self)
    return ChemicalObject(title: "Coordinates", format: "cjson", source: encoded,
                          facts: .object(["coordinateSetCount": .number(0), "cjson": .string(encoded)]))
}

@Test func staticPlanarCoordinatesDoNotRequireExtraConformerSets() throws {
    let object = try coordinateObject(.array([0, 0, 0, 1.2, 0, 0, -0.2, 1.1, 0].map(JSONValue.number)))
    #expect(!object.requires3DPreparation)
    let reopened = try JSONDecoder().decode(ChemicalObject.self, from: JSONEncoder().encode(object))
    #expect(!reopened.requires3DPreparation)
    let singleAtom = try coordinateObject(.array([.number(0), .number(0), .number(0)]), elements: [.number(2)])
    #expect(!singleAtom.requires3DPreparation)
}

@Test func absentIncompleteAndInvalidCoordinatesStillRequirePreparation() throws {
    #expect(try coordinateObject(nil).requires3DPreparation)
    #expect(try coordinateObject(.array([.number(0)])).requires3DPreparation)
    #expect(try coordinateObject(.array([.string("0")] + Array(repeating: .number(0), count: 8))).requires3DPreparation)
    var corrupt = try coordinateObject(nil)
    corrupt.facts = .object(["coordinateSetCount": .number(0), "cjson": .string("invalid JSON")])
    #expect(corrupt.requires3DPreparation)
}

@Test func explicitDrawingCoordinatesRemainProtected() throws {
    var object = try coordinateObject(.array(Array(repeating: .number(0), count: 9)))
    object.sketchDocument = "drawing"
    #expect(object.requires3DPreparation)
    object.sketchDocument = nil
    object.facts = .object(["geometryDimension": .number(2)])
    #expect(object.requires3DPreparation)
    object.facts = nil
    object.format = "sdf"; object.source = "Drawing\n  generator2D\r\n\n"
    #expect(object.requires3DPreparation)
}
