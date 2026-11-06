import XCTest
@testable import FloeCanvasCore

final class JSONFidelityTests: XCTestCase {
    func testBigIntegerBeyondInt64PreservesLiteral() throws {
        let json = #"{"huge":18446744073709551615}"#.data(using: .utf8)!
        let value = try JSONFidelity.parse(json)
        XCTAssertEqual(value["huge"]?.numberLiteral, "18446744073709551615")
        let out = try JSONFidelity.serialize(value)
        XCTAssertEqual(String(data: out, encoding: .utf8), #"{"huge":18446744073709551615}"#)
    }

    func testHighPrecisionDecimalPreservesLiteral() throws {
        let json = #"{"pi":3.141592653589793238462643383279}"#.data(using: .utf8)!
        let value = try JSONFidelity.parse(json)
        XCTAssertEqual(value["pi"]?.numberLiteral, "3.141592653589793238462643383279")
        let out = try JSONFidelity.serialize(value)
        XCTAssertEqual(
            String(data: out, encoding: .utf8),
            #"{"pi":3.141592653589793238462643383279}"#)
    }

    func testExponentFormPreservesLiteral() throws {
        let json = #"{"big":1e400,"small":-2.5E-9}"#.data(using: .utf8)!
        let value = try JSONFidelity.parse(json)
        XCTAssertEqual(value["big"]?.numberLiteral, "1e400")
        XCTAssertEqual(value["small"]?.numberLiteral, "-2.5E-9")
        let out = try JSONFidelity.serialize(value)
        XCTAssertTrue(String(data: out, encoding: .utf8)!.contains(#""big":1e400"#))
        XCTAssertTrue(String(data: out, encoding: .utf8)!.contains(#""small":-2.5E-9"#))
    }

    func testIntegerSpellingNeverChanges() throws {
        // 1.0 stays 1.0, 2 stays 2 — no re-typing of unknown values.
        let json = #"{"a":1.0,"b":2,"c":-0.5}"#.data(using: .utf8)!
        let value = try JSONFidelity.parse(json)
        let out = try JSONFidelity.serialize(value)
        XCTAssertEqual(String(data: out, encoding: .utf8), #"{"a":1.0,"b":2,"c":-0.5}"#)
    }

    func testNestedUnknownFieldsAndUnicodeRoundTrip() throws {
        let json = """
        {"outer":{"deep":[{"x":true},null,"caf\\u00e9 \\uD83D\\uDE00"],"n":9007199254740993}}
        """.data(using: .utf8)!
        let value = try JSONFidelity.parse(json)
        let out = try JSONFidelity.serialize(value)
        let reparsed = try JSONFidelity.parse(out)
        XCTAssertEqual(reparsed, value)
        XCTAssertEqual(value["outer"]?["deep"]?.arrayValue?[2].stringValue, "café 😀")
    }

    func testSortedKeySerializationIsDeterministic() throws {
        let json = #"{"b":1,"a":{"d":2,"c":3}}"#.data(using: .utf8)!
        let value = try JSONFidelity.parse(json)
        let first = try JSONFidelity.serialize(value)
        let second = try JSONFidelity.serialize(value)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            String(data: first, encoding: .utf8),
            #"{"a":{"c":3,"d":2},"b":1}"#)
    }

    func testPrettyPrintedShape() throws {
        let json = #"{"a":[1,2]}"#.data(using: .utf8)!
        let value = try JSONFidelity.parse(json)
        let out = try JSONFidelity.serialize(
            value, options: .init(sortedKeys: true, prettyPrinted: true))
        XCTAssertEqual(String(data: out, encoding: .utf8),
                       "{\n  \"a\": [\n    1,\n    2\n  ]\n}")
    }

    func testTruncatedInputThrows() {
        XCTAssertThrowsError(try JSONFidelity.parse(#"{"a":[1,2"#.data(using: .utf8)!))
        XCTAssertThrowsError(try JSONFidelity.parse("".data(using: .utf8)!))
    }
}
