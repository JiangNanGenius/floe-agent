// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import MediaExchangeCore

final class ExchangeTimeTests: XCTestCase {
    func testExactNTSCRationalTime() throws {
        let rate = try ExchangeFrameRate(numerator: 30000, denominator: 1001)
        XCTAssertEqual(rate.description, "30000/1001")
        let frames = try ExchangeTime.frames(30000, rate: rate)
        XCTAssertEqual(frames.value, 1001)
        XCTAssertEqual(frames.timescale, 1)
        XCTAssertEqual(try frames.multiplied(by: ExchangeTime(value: 1, timescale: 1)), frames)
        XCTAssertEqual(frames.seconds, 1001, accuracy: 1e-9)
        XCTAssertTrue(frames.isMultiple(of: rate.secondsPerFrame))
    }

    func testRationalApproximationFindsNTSCRate() throws {
        let rate = try ExchangeFrameRate.rationalApproximation(of: 29.97002997002997)
        XCTAssertEqual(rate, try ExchangeFrameRate(numerator: 30000, denominator: 1001))
        let rate24 = try ExchangeFrameRate.rationalApproximation(of: 23.976023976023978)
        XCTAssertEqual(rate24, try ExchangeFrameRate(numerator: 24000, denominator: 1001))
    }

    func testArithmeticAndOverflowAreExplicit() throws {
        let a = try ExchangeTime(value: 1, timescale: 3)
        let b = try ExchangeTime(value: 1, timescale: 6)
        XCTAssertEqual(try a + b, try ExchangeTime(value: 1, timescale: 2))
        XCTAssertEqual(try a - b, try ExchangeTime(value: 1, timescale: 6))
        XCTAssertThrowsError(try b - a)
        XCTAssertThrowsError(try ExchangeTime(value: 1, timescale: 0))
        XCTAssertThrowsError(try ExchangeTime(value: -1, timescale: 1))
        let huge = try ExchangeTime(value: Int64.max, timescale: 1)
        XCTAssertThrowsError(try huge + a)
    }

    func testTimeAndRateCodableRoundTrip() throws {
        let time = try ExchangeTime(value: 1001, timescale: 30000)
        let encoded = try JSONEncoder().encode(time)
        XCTAssertEqual(try JSONDecoder().decode(ExchangeTime.self, from: encoded), time)
        let rate = try ExchangeFrameRate(numerator: 60000, denominator: 1001)
        XCTAssertEqual(try JSONDecoder().decode(ExchangeFrameRate.self, from: JSONEncoder().encode(rate)), rate)
    }

    func testFCPXMLStringIsExact() throws {
        XCTAssertEqual(try ExchangeTime(value: 1001, timescale: 30000).fcpxmlString, "1001/30000s")
        XCTAssertEqual(try ExchangeTime(value: 2, timescale: 1).fcpxmlString, "2s")
    }
}
