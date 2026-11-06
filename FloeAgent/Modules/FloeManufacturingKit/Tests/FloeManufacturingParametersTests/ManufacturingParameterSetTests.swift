// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeManufacturingParameters

final class ManufacturingParameterSetTests: XCTestCase {

    private let catalog = ManufacturingParameterCatalog.standard

    func testUnknownIDIsReportedAndPreserved() throws {
        var set = ManufacturingParameterSet()
        set.set("future.unknown.thing", .object(["x": .integer(1)]))
        set.set("stock.radiusMM", .number(12))
        let issues = set.validate(catalog: catalog)
        XCTAssertEqual(issues.filter { $0.code == .unknownParameter }.map(\.parameterID), ["future.unknown.thing"])
        // Value must not be deleted by validation.
        XCTAssertEqual(set.value("future.unknown.thing"), .object(["x": .integer(1)]))
        // And it must survive a save/load round trip untouched.
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(ManufacturingParameterSet.self, from: data)
        XCTAssertEqual(decoded, set)
    }

    func testTypeMismatchIsReported() {
        var set = ManufacturingParameterSet()
        set.set("stock.radiusMM", .string("twelve"))
        let issues = set.validate(catalog: catalog)
        XCTAssertTrue(issues.contains { $0.parameterID == "stock.radiusMM" && $0.code == .typeMismatch })
    }

    func testNonFiniteIsReported() {
        var set = ManufacturingParameterSet()
        set.set("stock.radiusMM", .number(.infinity))
        let issues = set.validate(catalog: catalog)
        XCTAssertTrue(issues.contains { $0.parameterID == "stock.radiusMM" && $0.code == .nonFinite })
    }

    func testOutOfRangeIsReported() {
        var set = ManufacturingParameterSet()
        set.set("stock.resolutionMM", .number(10)) // catalog max 4
        let issues = set.validate(catalog: catalog)
        XCTAssertTrue(issues.contains { $0.parameterID == "stock.resolutionMM" && $0.code == .outOfRange })
    }

    func testInvalidChoiceIsReported() {
        var set = ManufacturingParameterSet()
        set.set("milling.direction", .string("diagonal"))
        let issues = set.validate(catalog: catalog)
        XCTAssertTrue(issues.contains { $0.parameterID == "milling.direction" && $0.code == .invalidChoice })
    }

    func testIntegerKindRejectsFractionalNumber() {
        var set = ManufacturingParameterSet()
        set.set("budget.maxCells", .number(3.5))
        let issues = set.validate(catalog: catalog)
        XCTAssertTrue(issues.contains { $0.parameterID == "budget.maxCells" && $0.code == .typeMismatch })
        // Integral numbers and integers are both accepted for integer kind.
        var ok = ManufacturingParameterSet()
        ok.set("budget.maxCells", .integer(1024))
        ok.set("turning.finishPasses", .number(2.0))
        XCTAssertEqual(ok.validate(catalog: catalog), [])
    }

    func testNullIsAllowedForAnyParameter() {
        var set = ManufacturingParameterSet()
        set.set("stock.radiusMM", .null)
        set.set("milling.direction", .null)
        XCTAssertEqual(set.validate(catalog: catalog), [])
    }

    func testFutureVersionRejectedWithoutTouchingOriginalData() throws {
        // Simulate a future file: the decode must fail and callers keep bytes.
        let futureJSON = Data("""
        {"formatVersion": 999, "values": {"stock.radiusMM": {"type":"number","value":12}}}
        """.utf8)
        let originalBytes = futureJSON
        XCTAssertThrowsError(try JSONDecoder().decode(ManufacturingParameterSet.self, from: futureJSON)) { error in
            guard case DecodingError.dataCorrupted(let ctx) = error else {
                XCTFail("expected dataCorrupted, got \(error)"); return
            }
            XCTAssertTrue(ctx.debugDescription.contains("unsupported"))
        }
        XCTAssertEqual(futureJSON, originalBytes, "decode must never mutate the source bytes")
    }

    func testPresetDeltaMergeAndRoundTrip() throws {
        var base = ManufacturingParameterSet()
        base.set("stock.radiusMM", .number(12))
        base.set("turning.enabled", .boolean(true))
        let preset = ManufacturingParameterPreset(
            name: "Steel shaft",
            values: ["stock.radiusMM": .number(16), "turning.enabled": .boolean(false)])
        let merged = base.merged(with: preset)
        XCTAssertEqual(merged.value("stock.radiusMM"), .number(16))
        XCTAssertEqual(merged.value("turning.enabled"), .boolean(false))
        // Untouched keys stay as-is.
        var sparse = ManufacturingParameterSet()
        sparse.set("turning.feedMMPerMinute", .number(120))
        let mergedSparse = sparse.merged(with: preset)
        XCTAssertEqual(mergedSparse.value("turning.feedMMPerMinute"), .number(120))
        XCTAssertEqual(mergedSparse.value("stock.radiusMM"), .number(16))
        // Preset persists by itself.
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(ManufacturingParameterPreset.self, from: data)
        XCTAssertEqual(decoded, preset)
    }

    func testSetRoundTripWithCatalogValidation() throws {
        var set = ManufacturingParameterSet()
        for descriptor in catalog.parameters {
            if let def = descriptor.defaultValue { set.set(descriptor.id, def) }
        }
        let data = try JSONEncoder().encode(set)
        let decoded = try JSONDecoder().decode(ManufacturingParameterSet.self, from: data)
        XCTAssertEqual(decoded, set)
        XCTAssertEqual(decoded.validate(catalog: catalog), [])
    }
}
