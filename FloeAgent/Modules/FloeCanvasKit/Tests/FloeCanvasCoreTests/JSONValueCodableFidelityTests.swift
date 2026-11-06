import XCTest
@testable import FloeCanvasCore

/// Native Codable identity: encode→decode must reproduce EVERY legal
/// JSONValue exactly, including marker-shaped user data and literals that
/// plain number emission would re-type (2.0, -0, 1e0, bigints,
/// high-precision decimals).
final class JSONValueCodableFidelityTests: XCTestCase {
    private func roundTrip(_ value: JSONValue) throws -> JSONValue {
        let data = try JSONEncoder().encode(["v": value])
        let decoded = try JSONDecoder().decode(
            [String: JSONValue].self, from: data)
        return try XCTUnwrap(decoded["v"])
    }

    private func assertIdentity(_ value: JSONValue) throws {
        XCTAssertEqual(try roundTrip(value), value)
    }

    func testExactNumberLiteralPreserved() throws {
        try assertIdentity(.number("9223372036854775808123"))       // > Int64, > Double exact
        try assertIdentity(.number("0.12345678901234567890123456789")) // high precision
        try assertIdentity(.number("2.0"))    // JSONEncoder would emit 2
        try assertIdentity(.number("-0"))     // Int64 re-type would drop the sign
        try assertIdentity(.number("1e0"))    // Double spelling normalizes
        try assertIdentity(.number("1e400"))  // non-finite as Double
        try assertIdentity(.number("9007199254740993"))
        try assertIdentity(.number("42"))
        try assertIdentity(.number("-1.5"))
    }

    func testMarkerShapedUserObjectsAreNotMisread() throws {
        // The exact counterexamples: legitimate user data that LOOKS like
        // the tagged-number marker must survive untouched.
        try assertIdentity(.object([
            "$floecanvas.rawNumber": .object(["literal": .string("123")])
        ]))
        try assertIdentity(.object([
            "$floecanvas.rawNumber": .string("1e400")
        ]))
        try assertIdentity(.object([
            "$floecanvas.rawNumber.escape": .object(["x": .number("1")])
        ]))
        try assertIdentity(.object([
            "$floecanvas.rawNumber.escape": .string("payload")
        ]))
        // Marker key with non-number-grammar string is plain data.
        try assertIdentity(.object([
            "$floecanvas.rawNumber": .string("hello")
        ]))
        // Multi-key objects with marker keys are plain data.
        try assertIdentity(.object([
            "$floecanvas.rawNumber": .string("123"),
            "other": .bool(true),
        ]))
    }

    func testNestedMarkersAndEscapesRoundTripIdentically() throws {
        try assertIdentity(.array([
            .object(["$floecanvas.rawNumber": .object(["literal": .string("2")])]),
            .object([
                "$floecanvas.rawNumber.escape": .array([
                    .object(["$floecanvas.rawNumber": .string("x")]),
                ]),
            ]),
            .number("3.1400"),
            .object(["deep": .object(["$floecanvas.rawNumber": .object([
                "literal": .string("999"),
                "extra": .bool(true),
            ])])]),
        ]))
    }

    func testScalarsAndContainersRoundTrip() throws {
        try assertIdentity(.null)
        try assertIdentity(.bool(true))
        try assertIdentity(.string("unicode ✓ \"quoted\" \\ slash"))
        try assertIdentity(.array([]))
        try assertIdentity(.object([:]))
        try assertIdentity(.object(["a": .array([.number("1.10"), .string("s")])]))
    }

    func testP0FlatMarkerStillDecodesAsNumber() throws {
        // Backward compatibility with files written by the P0 encoder.
        let legacy = """
        {"$floecanvas.rawNumber": "1e400"}
        """.data(using: .utf8)!
        let value = try JSONDecoder().decode(JSONValue.self, from: legacy)
        XCTAssertEqual(value, .number("1e400"))
    }

    func testForeignPlainNumbersDecodeToNumberValues() throws {
        // Foreign-encoded plain numbers keep their parsed value.
        let foreign = """
        {"v": 0.5}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(
            [String: JSONValue].self, from: foreign)
        XCTAssertEqual(decoded["v"], .number("0.5"))
    }
}

final class JSONFidelityBoundsTests: XCTestCase {
    func testDepthLimitThrowsAndPreservesInput() throws {
        let deep = String(repeating: "[", count: 200) + "1"
            + String(repeating: "]", count: 200)
        let data = Data(deep.utf8)
        XCTAssertThrowsError(
            try JSONFidelity.parse(data, options: .init(maxDepth: 20))) { error in
            guard case CanvasKitError.io(let message) = error else {
                XCTFail("expected io, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("depth"))
        }
        XCTAssertEqual(data, Data(deep.utf8))
        // A depth within the limit still parses.
        let ok = String(repeating: "[", count: 20) + "1"
            + String(repeating: "]", count: 20)
        XCTAssertNoThrow(try JSONFidelity.parse(
            Data(ok.utf8), options: .init(maxDepth: 20)))
    }

    func testSizeLimitThrows() {
        let data = Data(count: 1024)
        XCTAssertThrowsError(try JSONFidelity.parse(
            data, options: .init(maxByteCount: 16))) { error in
            guard case CanvasKitError.io(let message) = error else {
                XCTFail("expected io, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("limit"))
        }
    }

    func testMalformedNumberLiteralsRejected() {
        // Partial spellings scanned as numbers must fail number grammar.
        for bad in ["-", "1.", "1e", "01", "-01", "1e+"] {
            let json = "[\(bad)]".data(using: .utf8)!
            XCTAssertThrowsError(
                try JSONFidelity.parse(json),
                "literal \(bad) must be rejected") { error in
                guard case CanvasKitError.io(let message) = error else {
                    XCTFail("expected io for \(bad), got \(error)")
                    return
                }
                XCTAssertTrue(message.contains("number"), message)
            }
        }
        // Non-number garbage must not parse either (generic value error).
        for bad in [".5", "+1", "nul", "tru"] {
            let json = "[\(bad)]".data(using: .utf8)!
            XCTAssertThrowsError(
                try JSONFidelity.parse(json),
                "literal \(bad) must be rejected")
        }
        // Valid spellings still parse with exact literals.
        for good in ["0", "-0", "1", "1.5", "1e2", "-1.5E-2", "0.25"] {
            let json = "[\(good)]".data(using: .utf8)!
            let value = try? JSONFidelity.parse(json)
            XCTAssertEqual(value?.arrayValue?.first?.numberLiteral, good, good)
        }
    }

    func testTruncatedAndTrailingInputThrow() {
        XCTAssertThrowsError(try JSONFidelity.parse(Data("{\"a\":".utf8)))
        XCTAssertThrowsError(try JSONFidelity.parse(Data("1 2".utf8)))
    }
}
