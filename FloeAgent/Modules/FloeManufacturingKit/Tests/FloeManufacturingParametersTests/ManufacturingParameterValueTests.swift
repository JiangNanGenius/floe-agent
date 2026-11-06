// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeManufacturingParameters

final class ManufacturingParameterValueTests: XCTestCase {

    private func roundTrip(_ value: ManufacturingParameterValue) throws -> ManufacturingParameterValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(ManufacturingParameterValue.self, from: data)
    }

    func testAllCasesRoundTrip() throws {
        let cases: [ManufacturingParameterValue] = [
            .number(3.5), .integer(3), .boolean(true), .string("chipbreak"),
            .array([.number(1), .string("a")]),
            .object(["k": .integer(7), "nested": .object(["x": .null])]),
            .null,
        ]
        for value in cases {
            XCTAssertEqual(try roundTrip(value), value, "round-trip failed for \(value)")
        }
    }

    func testIntegerAndNumberStayDistinctAfterRoundTrip() throws {
        // JSON alone cannot distinguish 3 from 3.0; the tagged encoding must.
        let integer = try roundTrip(.integer(3))
        let number = try roundTrip(.number(3.0))
        XCTAssertEqual(integer, .integer(3))
        XCTAssertEqual(number, .number(3.0))
        XCTAssertNotEqual(integer, number)
    }

    func testLargeIntegerKeepsFullPrecisionBeyond2ToThe53() throws {
        // 2^53 + 1 — exactly representable in Int64, not in Double.
        let big: Int64 = 9_007_199_254_740_993
        let value = ManufacturingParameterValue.integer(big)
        let decoded = try roundTrip(value)
        XCTAssertEqual(decoded, .integer(big))
        if case .integer(let v) = decoded {
            XCTAssertEqual(v, big)
        } else {
            XCTFail("expected integer case")
        }
    }

    func testFromRawJSONPreservesIntegerOneVersusRealOne() throws {
        let intJSON = Data("1".utf8)
        let realJSON = Data("1.0".utf8)
        XCTAssertEqual(try ManufacturingParameterValue.fromRawJSON(intJSON), .integer(1))
        XCTAssertEqual(try ManufacturingParameterValue.fromRawJSON(realJSON), .number(1.0))
    }

    func testFromRawJSONBooleanIsNotNumberOne() throws {
        XCTAssertEqual(try ManufacturingParameterValue.fromRawJSON(Data("true".utf8)), .boolean(true))
        XCTAssertEqual(try ManufacturingParameterValue.fromRawJSON(Data("false".utf8)), .boolean(false))
    }

    func testUnknownNestedStructureRoundTripsUnchanged() throws {
        // A future parameter carrying a nested blob must survive untouched.
        let future = ManufacturingParameterValue.object([
            "vendor": .string("acme"),
            "payload": .object([
                "angles": .array([.number(-170), .number(170)]),
                "flags": .object(["rare": .boolean(true), "count": .integer(42)]),
                "empty": .null,
            ]),
        ])
        let set = ManufacturingParameterSet()
        var copy = set
        copy.set("future.vendor.blob", future)
        let data = try JSONEncoder().encode(copy)
        let decoded = try JSONDecoder().decode(ManufacturingParameterSet.self, from: data)
        XCTAssertEqual(decoded.value("future.vendor.blob"), future)
    }

    func testUnsetNullAndZeroAreDistinct() throws {
        var set = ManufacturingParameterSet()
        set.set("a", .number(0))
        set.set("b", .null)
        // "c" is absent -> unset.
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(ManufacturingParameterSet.self, from: data)
        XCTAssertEqual(decoded.value("a"), .number(0))
        XCTAssertTrue(decoded.value("b")!.isNull)
        XCTAssertNil(decoded.value("c"))
        XCTAssertNotEqual(decoded.value("a"), decoded.value("c"))
    }

    func testAccessors() {
        XCTAssertEqual(ManufacturingParameterValue.number(2.5).doubleValue, 2.5)
        XCTAssertEqual(ManufacturingParameterValue.integer(4).intValue, 4)
        XCTAssertNil(ManufacturingParameterValue.integer(4).doubleValue)
        XCTAssertTrue(ManufacturingParameterValue.boolean(true).boolValue == true)
        XCTAssertEqual(ManufacturingParameterValue.string("x").stringValue, "x")
        XCTAssertEqual(ManufacturingParameterValue.integer(9).numericMagnitude, 9)
        XCTAssertEqual(ManufacturingParameterValue.number(9.5).numericMagnitude, 9.5)
        XCTAssertNil(ManufacturingParameterValue.string("x").numericMagnitude)
    }
}
