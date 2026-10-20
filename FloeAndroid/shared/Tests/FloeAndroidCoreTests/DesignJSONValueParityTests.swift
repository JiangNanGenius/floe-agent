import Foundation
import XCTest
import FloeCore

/// Regression coverage for the Android `DesignCanvasMetadata` overlay.
///
/// The Samsung API 33 device smoke showed JSON `true`/`false` arrive as
/// `Foundation.__NSCFBoolean` with `typeOfEqualsBoolSelf == false`, while
/// numeric `1`/`0` arrive as `Foundation.NSNumber` and still satisfy
/// `as? Bool`. The mapping therefore cannot use the dynamic Swift type or
/// `as? Bool`; it must use the public CoreFoundation runtime type identity.
/// These host tests exercise the same shared branch on Darwin and pin the
/// narrow NSNumber integer forms that a blanket objCType `"c"` heuristic would
/// silently turn into booleans.
final class DesignJSONValueParityTests: XCTestCase {
    private func numericCaseName(_ value: DesignJSONValue) -> String? {
        switch value {
        case .decimal: "decimal"
        case .number: "number"
        default: nil
        }
    }

    func testJSONSerializationBooleansStayBooleansWhileIntegersStayIntegers() throws {
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data("[true,false,1,0,1.5]".utf8)) as? [Any]
        )
        XCTAssertEqual(parsed.count, 5)
        XCTAssertEqual(DesignJSONValue.from(foundation: parsed[0]), .bool(true))
        XCTAssertEqual(DesignJSONValue.from(foundation: parsed[1]), .bool(false))
        XCTAssertEqual(DesignJSONValue.from(foundation: parsed[2]), .integer(1))
        XCTAssertEqual(DesignJSONValue.from(foundation: parsed[3]), .integer(0))
        XCTAssertNotNil(numericCaseName(DesignJSONValue.from(foundation: parsed[4])))
        let reencoded = try JSONEncoder().encode(parsed.map { DesignJSONValue.from(foundation: $0) })
        XCTAssertEqual(String(decoding: reencoded, as: UTF8.self), "[true,false,1,0,1.5]")
    }

    func testConstructedNarrowNSNumbersPreserveIntegerSemantics() {
        let cases: [(String, NSNumber, DesignJSONValue)] = [
            ("Int8(1)", NSNumber(value: Int8(1)), .integer(1)),
            ("Int8(0)", NSNumber(value: Int8(0)), .integer(0)),
            ("Int8(-1)", NSNumber(value: Int8(-1)), .integer(-1)),
            ("UInt8(1)", NSNumber(value: UInt8(1)), .integer(1)),
            ("Int16(1)", NSNumber(value: Int16(1)), .integer(1)),
            ("UInt16(1)", NSNumber(value: UInt16(1)), .integer(1)),
            ("Int32(1)", NSNumber(value: Int32(1)), .integer(1)),
            ("UInt32(1)", NSNumber(value: UInt32(1)), .integer(1)),
            ("Int64(1)", NSNumber(value: Int64(1)), .integer(1)),
            ("UInt64(1)", NSNumber(value: UInt64(1)), .integer(1)),
            ("Int64.max", NSNumber(value: Int64.max), .integer(Int64.max)),
            ("UInt64.max", NSNumber(value: UInt64.max), .unsigned(UInt64.max)),
            ("Bool(true)", NSNumber(value: true), .bool(true)),
            ("Bool(false)", NSNumber(value: false), .bool(false)),
        ]
        for (label, number, expected) in cases {
            XCTAssertEqual(DesignJSONValue.from(foundation: number), expected, label)
        }
    }

    func testNumericNSNumberNeverBecomesBoolEvenWhenBridgeCastSucceeds() {
        // `NSNumber(value: 1) as? Bool` is true on both Apple Foundation and
        // swift-corelibs Foundation, which is exactly why the mapping cannot
        // use that cast. The CFNumber type identity keeps it an integer.
        let one = NSNumber(value: 1)
        XCTAssertEqual(DesignJSONValue.from(foundation: one), .integer(1))
        XCTAssertNotEqual(DesignJSONValue.from(foundation: one), .bool(true))
        let narrow = NSNumber(value: Int8(1))
        XCTAssertEqual(DesignJSONValue.from(foundation: narrow), .integer(1))
        XCTAssertNotEqual(DesignJSONValue.from(foundation: narrow), .bool(true))
    }

    func testFloatingAndDecimalNumbersKeepTheirNumericCases() {
        XCTAssertEqual(DesignJSONValue.from(foundation: NSNumber(value: 1.5)), .number(1.5))
        XCTAssertEqual(DesignJSONValue.from(foundation: NSNumber(value: Float(1.25))), .number(1.25))
        let decimal = Decimal(string: "12345678901234567890.123456789")!
        XCTAssertEqual(
            DesignJSONValue.from(foundation: NSDecimalNumber(decimal: decimal)),
            .decimal(decimal)
        )
    }

    func testContainersPreserveBooleanIntegerAndNumericCasesRecursively() throws {
        let input: [String: Any] = [
            "flagTrue": true,
            "flagFalse": NSNumber(value: false),
            "one": 1,
            "zero": NSNumber(value: Int8(0)),
            "smallest": NSNumber(value: Int8(1)),
            "big": NSNumber(value: UInt64.max),
            "fraction": 1.5,
            "decimal": NSDecimalNumber(decimal: Decimal(string: "12345678901234567890.123456789")!),
            "text": "x",
            "none": NSNull(),
            "list": [true, 0] as [Any],
        ]
        guard case .object(let object) = DesignJSONValue.from(foundation: input) else {
            return XCTFail("top-level dictionary did not map to .object")
        }
        XCTAssertEqual(object["flagTrue"], .bool(true))
        XCTAssertEqual(object["flagFalse"], .bool(false))
        XCTAssertEqual(object["one"], .integer(1))
        XCTAssertEqual(object["zero"], .integer(0))
        XCTAssertEqual(object["smallest"], .integer(1))
        XCTAssertEqual(object["big"], .unsigned(UInt64.max))
        XCTAssertEqual(object["text"], .string("x"))
        XCTAssertEqual(object["none"], .null)
        XCTAssertEqual(object["list"], .array([.bool(true), .integer(0)]))
        XCTAssertNotNil(numericCaseName(object["fraction"] ?? .null))
        guard case .decimal = object["decimal"] else {
            return XCTFail("NSDecimalNumber did not preserve decimal digits")
        }
    }
}
