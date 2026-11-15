// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
@testable import FloeRPGCore

final class MarshalMalformedTests: XCTestCase {
    func testTruncatedStreamsThrow() throws {
        let good = try RubyMarshal.serialize(RubyNode(RubyValue(kind: .array(
            [RubyNode(RubyValue(kind: .integer(1)))]))))
        for length in 0..<good.count {
            XCTAssertThrowsError(try RubyMarshal.parse(good.prefix(length) as Data)) { error in
                // Prefixes fail as truncated reads or as collection-size
                // checks; both are genuine malformed-stream rejections.
                guard error is MarshalError else { return XCTFail("expected MarshalError, got \(error)") }
            }
        }
    }

    func testUnsupportedVersionThrows() {
        let bytes = Data([0x04, 0x09, 0x30])
        XCTAssertThrowsError(try RubyMarshal.parse(bytes)) { error in
            XCTAssertEqual(error as? MarshalError, .unsupportedVersion(4, 9))
        }
        let futureMajor = Data([0x05, 0x08, 0x30])
        XCTAssertThrowsError(try RubyMarshal.parse(futureMajor)) { error in
            XCTAssertEqual(error as? MarshalError, .unsupportedVersion(5, 8))
        }
    }

    func testLinkIndexOutOfRangeThrows() {
        // [ '@' 0 ] with empty object table.
        let bytes = Data([0x04, 0x08, 0x5b, 0x06, 0x40, 0x06])
        XCTAssertThrowsError(try RubyMarshal.parse(bytes)) { error in
            XCTAssertEqual(error as? MarshalError, .linkIndexOutOfRange(1))
        }
    }

    func testSymbolIndexOutOfRangeThrows() {
        let bytes = Data([0x04, 0x08, 0x3b, 0x06])
        XCTAssertThrowsError(try RubyMarshal.parse(bytes)) { error in
            XCTAssertEqual(error as? MarshalError, .symbolIndexOutOfRange(1))
        }
    }

    func testCollectionSizeExceedingInputThrows() {
        // Array claims 100 elements but only one follows.
        let bytes = Data([0x04, 0x08, 0x5b, 0x69, 0x30])
        XCTAssertThrowsError(try RubyMarshal.parse(bytes)) { error in
            guard case .collectionSizeExceedsInput = error as? MarshalError else {
                return XCTFail("expected collectionSizeExceedsInput, got \(error)")
            }
        }
    }

    func testDepthLimitThrowsOnDeepNesting() {
        var payload = Data()
        let depth = 400
        for _ in 0..<depth { payload.append(0x5b); payload.append(0x06) } // '[' 0
        for _ in 0..<depth { payload.append(0x30) } // hmm: arrays with count 0 need no close; use nil elements? count 0 needs nothing.
        let bytes = Data([0x04, 0x08]) + payload
        let limits = MarshalParseLimits(maximumDepth: 128)
        XCTAssertThrowsError(try RubyMarshal.parse(bytes, limits: limits)) { error in
            XCTAssertEqual(error as? MarshalError, .depthLimitExceeded)
        }
    }

    func testNodeLimitThrowsOnArrayBomb() {
        // 20_000 registered empty arrays with a node cap of 1_000.
        var payload = Data([0x04, 0x08, 0x5b])
        marshalWriteLong(20_000) { payload.append($0) }
        for _ in 0..<20_000 { payload.append(0x5b); payload.append(0x00) }
        let limits = MarshalParseLimits(maximumNodes: 1_000)
        XCTAssertThrowsError(try RubyMarshal.parse(payload, limits: limits)) { error in
            XCTAssertEqual(error as? MarshalError, .nodeLimitExceeded)
        }
    }

    func testSizeCapRejectsOversizedInput() {
        let data = Data(count: 1024)
        let limits = MarshalParseLimits(maximumBytes: 512)
        XCTAssertThrowsError(try RubyMarshal.parse(data, limits: limits))
    }

    func testUnknownTagThrows() {
        let bytes = Data([0x04, 0x08, 0x21]) // '!'
        XCTAssertThrowsError(try RubyMarshal.parse(bytes)) { error in
            guard case .malformed = error as? MarshalError else { return XCTFail("got \(error)") }
        }
    }
}
