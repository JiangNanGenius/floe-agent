// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore

enum Fixture {
    static var root: URL {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures/generated") else {
            fatalError("missing Fixtures/generated bundle resource")
        }
        return url
    }

    static func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: url(relative))
    }
}

final class MarshalRoundTripTests: XCTestCase {
    /// Byte-exact parse -> serialize roundtrip against Ruby-generated streams.
    func testEdgeCasesFixtureRoundTripsByteIdentically() throws {
        let original = try Fixture.data("edge-cases.rxdata")
        let root = try RubyMarshal.parse(original)
        let reserialized = try RubyMarshal.serialize(root)
        XCTAssertEqual(reserialized, original, "edge-cases graph must round-trip byte-identically")
    }

    /// Every generated binary project file round-trips byte-identically.
    func testAllBinaryProjectFilesRoundTrip() throws {
        let names = [
            "xp-project/Data/Actors.rxdata", "xp-project/Data/Items.rxdata",
            "xp-project/Data/Enemies.rxdata", "xp-project/Data/States.rxdata",
            "xp-project/Data/Tilesets.rxdata", "xp-project/Data/System.rxdata",
            "xp-project/Data/Map001.rxdata", "xp-project/Data/CommonEvents.rxdata",
            "xp-project/Data/Scripts.rxdata",
            "vx-project/Data/Map002.rvdata", "vx-project/Data/Actors.rvdata", "vx-project/Data/Scripts.rvdata",
            "ace-project/Data/Actors.rvdata2", "ace-project/Data/Map003.rvdata2",
            "ace-project/Data/CommonEvents.rvdata2", "ace-project/Data/Scripts.rvdata2",
        ]
        for name in names {
            let original = try Fixture.data(name)
            let root = try RubyMarshal.parse(original)
            let reserialized = try RubyMarshal.serialize(root)
            XCTAssertEqual(reserialized, original, "\(name) must round-trip byte-identically")
        }
    }

    func testScalarFormsDecodeToExpectedValues() throws {
        let root = try RubyMarshal.parse(Fixture.data("edge-cases.rxdata"))
        guard case .hash(let hash) = root.value.kind else { return XCTFail("expected hash root") }
        func entry(_ key: String) -> RubyNode? {
            hash.pairs.first(where: { $0.key.value.kind.stringValue?.utf8String == key })?.value
        }
        XCTAssertEqual(entry("nil")?.value.kind.isNil, true)
        XCTAssertEqual(entry("true")?.value.kind.boolValue, true)
        XCTAssertEqual(entry("utf8")?.value.kind.stringValue?.utf8String, "Brécyll 港")
        if case .string(let sjis) = entry("sjis-labeled")?.value.kind {
            guard case .named(let name) = sjis.encoding else { return XCTFail("expected named encoding") }
            XCTAssertEqual(name, "Shift_JIS")
        } else { XCTFail("missing sjis entry") }
        XCTAssertEqual(entry("bigint")?.value.kind.bigIntegerValue?.decimalString, String(UInt128String))
        // Shared identity: both array slots are the same node.
        guard case .array(let shared) = entry("shared")?.value.kind else { return XCTFail("missing shared") }
        XCTAssertTrue(shared.count == 2 && shared[0] === shared[1])
        // Cycle: hash self-reference resolves to itself.
        guard let cycle = entry("cycle"), case .hash(let cycleHash) = cycle.value.kind else {
            return XCTFail("missing cycle")
        }
        guard let selfPair = cycleHash.pairs.first(where: { $0.key.value.kind.stringValue?.utf8String == "self" }) else {
            return XCTFail("cycle self missing")
        }
        XCTAssertTrue(selfPair.value === cycle)
    }

    func testIntegerWireBoundariesRoundTripExactly() throws {
        let values: [Int64] = [0, 1, 122, 123, 255, 256, 65_535, 65_536, 2_147_483_647,
                               -124, -125, -300, -65_536, (1 << 30) - 1, 1 << 30, -(1 << 30), -(1 << 30) - 1]
        for value in values {
            let node = RubyNode(RubyValue(kind: .integer(value)))
            let bytes = try RubyMarshal.serialize(node)
            let parsed = try RubyMarshal.parse(bytes)
            XCTAssertEqual(parsed.value.kind.int64Value, value, "integer \(value) wire form")
            XCTAssertEqual(bytes, try RubyMarshal.serialize(parsed), "integer \(value) stable")
        }
    }

    func testFloatAndBignumFormsRoundTrip() throws {
        let floats: [Double] = [3.14, 3.0, -0.5, 1.0 / 3.0, 1e10]
        for value in floats {
            let node = RubyNode(RubyValue(kind: .float(RubyFloat(value))))
            let bytes = try RubyMarshal.serialize(node)
            let parsed = try RubyMarshal.parse(bytes)
            guard case .float(let float) = parsed.value.kind else { return XCTFail("float expected") }
            XCTAssertEqual(float.doubleValue, value, accuracy: 1e-12)
            XCTAssertEqual(bytes, try RubyMarshal.serialize(parsed))
        }
        // A magnitude beyond 64 bits stays a Bignum on both sides.
        let big = RubyBigInt(negative: true, words: [0xffff, 0x1234, 0x00ff, 0x0001, 0x8000, 0x0000, 0x0001])
        let node = RubyNode(RubyValue(kind: .bigInteger(big)))
        let bytes = try RubyMarshal.serialize(node)
        let parsed = try RubyMarshal.parse(bytes)
        guard case .bigInteger(let decoded) = parsed.value.kind else { return XCTFail("bigint expected") }
        XCTAssertEqual(decoded, big)
        XCTAssertEqual(bytes, try RubyMarshal.serialize(parsed))
    }
}

private let UInt128String = "1267650600228229401496703205376"

extension RubyKind {
    var bigIntegerValue: RubyBigInt? {
        if case .bigInteger(let value) = self { return value }
        return nil
    }
}
