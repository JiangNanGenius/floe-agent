// SPDX-License-Identifier: MPL-2.0
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

/// Date fidelity: the native JSON codec preserves the exact reference-date
/// bit pattern of any finite Date (the earlier epoch-Double spelling lost
/// sub-microsecond precision to the 978307200-second offset shift), while
/// previous prototype spellings (epoch numbers, ISO8601 strings) keep
/// decoding. Equality here is exact — no accuracy slop, no random dates.
final class DateFidelityTests: XCTestCase {
    private struct DateBox: Codable, Hashable {
        var value: Date
    }

    /// The deterministic awkward date from the qualification review:
    /// `Date(timeIntervalSinceReferenceDate: 123.123456789012345)` exposes
    /// the epoch-shift precision loss, so it must round-trip bit-exactly.
    private let awkward = Date(timeIntervalSinceReferenceDate: 123.123456789012345)

    func testAwkwardDateSurvivesNativeArchiveBitExactly() async throws {
        let snapshot = CanvasSnapshot(
            name: "Dates",
            pages: [CanvasPageSnapshot(name: "P")],
            createdAt: awkward,
            updatedAt: awkward
        )
        let exported = try await CanvasNativeArchive.export(snapshot)
        let reopened = try CanvasNativeArchive.import(exported.data)
        XCTAssertEqual(reopened.snapshot.createdAt, awkward, "createdAt must restore the exact bit pattern")
        XCTAssertEqual(reopened.snapshot.updatedAt, awkward, "updatedAt must restore the exact bit pattern")
        XCTAssertEqual(
            reopened.manifest.createdAt.timeIntervalSinceReferenceDate,
            exported.manifest.createdAt.timeIntervalSinceReferenceDate,
            "manifest createdAt must round-trip bit-exactly"
        )

        // The encoded document must carry the unambiguous native tag.
        let entries = try CanvasLabZIP.unpack(exported.data)
        let document = String(data: try XCTUnwrap(entries[CanvasNativeArchive.documentPath]), encoding: .utf8) ?? ""
        XCTAssertTrue(document.contains("\"floeDateBits\""), "document dates encode with the tagged native marker")
        XCTAssertFalse(document.contains("\"createdAt\":9"), "document dates must not use the legacy epoch-number spelling")
        let manifestJSON = String(data: try XCTUnwrap(entries[CanvasNativeArchive.manifestPath]), encoding: .utf8) ?? ""
        XCTAssertTrue(manifestJSON.contains("\"floeDateBits\""), "manifest dates encode with the tagged native marker")

        // A codec-level encode/decode round trip restores the same bits.
        let encoded = try CanvasExchangeJSON.encode(DateBox(value: awkward))
        let decoded = try CanvasExchangeJSON.decode(DateBox.self, from: encoded)
        XCTAssertEqual(decoded.value, awkward)
        XCTAssertEqual(decoded.value.timeIntervalSinceReferenceDate.bitPattern, awkward.timeIntervalSinceReferenceDate.bitPattern)
    }

    func testDeterministicAwkwardDateAcrossExtremes() throws {
        // Negative reference seconds, whole seconds, and high-precision
        // positives all restore exactly through the tagged codec.
        let cases: [Double] = [
            -978_307_200.0,                       // 1970-01-01T00:00:00Z
            0.0,                                  // reference date exactly
            123.123456789012345,                  // the review's awkward case
            700_000_000.987654321012345,          // ~2023, sub-microsecond
            -0.000000001,                         // 1 nanosecond before 2001
        ]
        for seconds in cases {
            let date = Date(timeIntervalSinceReferenceDate: seconds)
            let decoded = try CanvasExchangeJSON.decode(
                DateBox.self,
                from: CanvasExchangeJSON.encode(DateBox(value: date))
            )
            XCTAssertEqual(
                decoded.value.timeIntervalSinceReferenceDate.bitPattern,
                date.timeIntervalSinceReferenceDate.bitPattern,
                "reference seconds \(seconds) must round-trip bit-exactly"
            )
        }
    }

    func testLegacyEpochNumberStillDecodes() throws {
        // Archives written by the previous prototype encoded dates as raw
        // epoch-seconds JSON numbers; they must keep decoding.
        let json = Data("{\"value\":978307323.123456789012345}".utf8)
        let decoded = try CanvasExchangeJSON.decode(DateBox.self, from: json)
        XCTAssertEqual(decoded.value.timeIntervalSince1970, 978307323.123456789012345)
        XCTAssertEqual(decoded.value, Date(timeIntervalSince1970: 978307323.123456789012345))
    }

    func testLegacyISO8601StringsStillDecode() throws {
        let fractionalJSON = Data("{\"value\":\"2026-11-03T09:27:03.123Z\"}".utf8)
        let fractional = try CanvasExchangeJSON.decode(DateBox.self, from: fractionalJSON)
        XCTAssertEqual(fractional.value.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.123, accuracy: 0.0005)
        let wholeJSON = Data("{\"value\":\"2026-11-03T09:27:03Z\"}".utf8)
        let whole = try CanvasExchangeJSON.decode(DateBox.self, from: wholeJSON)
        XCTAssertEqual(whole.value.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.0, accuracy: 0.0005)
    }

    func testUnparseableDateIsRejected() {
        let json = Data("{\"value\":\"not a date\"}".utf8)
        XCTAssertThrowsError(try CanvasExchangeJSON.decode(DateBox.self, from: json))
    }
}
