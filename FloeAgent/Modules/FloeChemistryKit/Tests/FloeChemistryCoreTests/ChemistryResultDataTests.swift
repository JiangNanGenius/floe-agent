// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeChemistryCore

@Suite("Saved scientific result views and CSV")
struct ChemistryResultDataTests {
    private func spectrum() throws -> JSONValue {
        let actual = try SpectrumAnalysis.csv("x,y\n0,0\n1,2\n2,0\n3,1")
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(actual))
    }
    @Test("Actual spectrum points, area and peaks remain complete and CSV retains every sample")
    func actualSpectrumKeepsItsResults() throws {
        let result = try spectrum(), source = try ChemistryResultData.snapshot(result)
        #expect(source.complete && source.preview == result)
        #expect(result["area"] == .number(2.5) && result["points"]?.array?.count == 4 && result["peaks"]?.array?.count == 1)
        let csv = try ChemistryResultData.numericCSV(result, resultKey: "points")
        #expect(csv.columns == ["x","y"] && csv.rowCount == 4)
        #expect(String(decoding: csv.csv, as: UTF8.self) == "x,y\r\n0.0,0.0\r\n1.0,2.0\r\n2.0,0.0\r\n3.0,1.0\r\n")
        #expect(try JSONDecoder().decode(JSONValue.self, from: source.data) == result)
        let reread = try SpectrumAnalysis.csv(String(decoding: csv.csv, as: UTF8.self))
        #expect(reread.area == 2.5 && reread.points.count == 4 && reread.peaks.count == 1)
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(reread)) == result)
    }
    @Test("Exact atom-conservation coefficients reach the same unfiltered result view")
    func actualReactionCoefficientsRemainVisible() throws {
        let coefficients = try ReactionBalancer.balance(reactants: ["H2","O2"], products: ["H2O"])
        #expect(coefficients == [2,1,2])
        let result = JSONValue.object(["coefficients":.array(coefficients.map { .number(Double($0)) }),"method":.string("Exact atom and charge conservation")])
        let page = try ChemistryResultData.page(result)
        #expect(page.selectionComplete && page.value == result && !page.requiresResultKey)
        #expect(try ChemistryResultData.numericCSV(result, resultKey: "coefficients").rowCount == 3)
    }
    @Test("Large real-shape arrays are explicit and pages reconstruct the entire original without skipped items")
    func boundedPagesReconstructAllSamples() throws {
        let values: [JSONValue] = (0..<5_000).map { .object(["x":.number(Double($0)),"y":.number(Double($0 % 3))]) }
        let result = JSONValue.object(["points":.array(values),"area":.number(5000)])
        let source = try ChemistryResultData.snapshot(result)
        #expect(!source.complete && source.preview == .null && source.fields.map(\.key) == ["area","points"])
        let directory = try ChemistryResultData.page(result)
        #expect(directory.requiresResultKey && !directory.selectionComplete && directory.returnedItems == 0)
        var offset = 0, restored: [JSONValue] = []
        repeat {
            let page = try ChemistryResultData.page(result, resultKey: "points", offset: offset, limit: 1_000, expectedSHA256: source.sha256)
            #expect(page.totalItems == values.count && page.offset == offset && page.resultSHA256 == source.sha256)
            let items = try #require(page.value.array); restored += items
            if let next = page.nextOffset { #expect(next == offset + items.count && next > offset); offset = next }
            else { break }
        } while true
        #expect(restored == values)
    }
    @Test("Byte budgeting resumes the unreturned item rather than truncating or advancing past it")
    func byteBudgetDoesNotLoseAnItem() throws {
        let items: [JSONValue] = (0..<3).map { .object(["index":.number(Double($0)),"text":.string(String(repeating:"a",count:30_000))]) }
        let result = JSONValue.object(["rows":.array(items)])
        let first = try ChemistryResultData.page(result, resultKey: "rows", limit: 1000)
        #expect(first.returnedItems == 1 && first.nextOffset == 1 && first.value == .array([items[0]]))
        let second = try ChemistryResultData.page(result, resultKey: "rows", offset: 1, limit: 1000, expectedSHA256: first.resultSHA256)
        #expect(second.returnedItems == 1 && second.nextOffset == 2 && second.value == .array([items[1]]))
        let tooLarge = JSONValue.object(["rows":.array([.string(String(repeating:"a",count:60_000))])])
        #expect(throws: (any Error).self) { try ChemistryResultData.page(tooLarge, resultKey:"rows") }
    }
    @Test("Continuation cannot substitute a result or invent field/offset/limit values")
    func continuationAndSelectionAreFenced() throws {
        let result = try spectrum()
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,resultKey:"points",offset:1) }
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,resultKey:"points",offset:1,expectedSHA256:String(repeating:"0",count:64)) }
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,resultKey:"missing") }
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,resultKey:"points",offset:-1) }
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,resultKey:"points",limit:1001) }
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,resultKey:"points",offset:9,expectedSHA256:ChemistryResultData.snapshot(result).sha256) }
    }
    @Test("CSV keeps nulls empty and rejects ragged, strings, nested, mixed or non-finite data instead of coercing")
    func numericCSVIsLosslessOrRefuses() throws {
        let result = JSONValue.object(["table":.array([.array([.number(1),.null]),.array([.number(2),.number(3)])])])
        let csv = try ChemistryResultData.numericCSV(result,resultKey:"table")
        #expect(String(decoding:csv.csv,as:UTF8.self) == "value1,value2\r\n1.0,\r\n2.0,3.0\r\n")
        let bad: [JSONValue] = [
            .array([]), .array([.string("1")]), .array([.array([.number(1)]),.array([.number(2),.number(3)])]),
            .array([.object(["value":.number(1)]),.number(2)]),
            .array([.object(["x":.number(1)]),.object(["y":.number(2)])]),
            .array([.array([.object(["x":.number(1)])])]), .array([.number(.nan)]), .array([.number(.infinity)])]
        for value in bad { #expect(throws: (any Error).self) { try ChemistryResultData.numericCSV(.object(["table":value]),resultKey:"table") } }
    }
    @Test("Cancellation is observable before returning a page or a CSV export")
    func cancellationCannotReturnSuccess() throws {
        enum Cancelled: Error { case stopped }
        let result = try spectrum()
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,resultKey:"points",checkCancellation:{ throw Cancelled.stopped }) }
        #expect(throws: (any Error).self) { try ChemistryResultData.numericCSV(result,resultKey:"points",checkCancellation:{ throw Cancelled.stopped }) }
        final class AfterSnapshot: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func check() throws {
                lock.lock(); defer { lock.unlock() }; count += 1
                if count >= 2 { throw Cancelled.stopped }
            }
        }
        let directory = AfterSnapshot()
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,checkCancellation:{ try directory.check() }) }
        let scalar = AfterSnapshot()
        #expect(throws: (any Error).self) { try ChemistryResultData.page(result,resultKey:"area",checkCancellation:{ try scalar.check() }) }
    }
}
