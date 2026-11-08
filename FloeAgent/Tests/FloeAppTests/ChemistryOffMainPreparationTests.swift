// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) || FLOE_SCIENCE_OFFMAIN_QUALIFICATION
import Foundation
import Testing
import FloeChemistryCore
#if FLOE_SCIENCE_OFFMAIN_QUALIFICATION
@testable import ChemistryPreparationQualification
#else
@testable import FloeApp
#endif

@MainActor @Suite("Scientific result background preparation", .serialized)
struct ChemistryOffMainPreparationTests {
    private func run(samples: Int = 3) throws -> ChemistryRun {
        let text = "x,y\n" + (0..<samples).map { String($0) + "," + String($0 % 3) }.joined(separator:"\n")
        let object = ChemicalObject(title:"Background preparation",kind:.spectrum,format:"csv",source:text,revision:3)
        let value = try SpectrumAnalysis.csv(text)
        var run = ChemistryRun(input:object,inputDigest:ChemistryProjectStore.digest(Data(text.utf8)),
            method:"spectrum.analyze",options:.object([:]),environmentID:"native.local",engineVersion:"FloeChemistryCore-contract")
        run.status = .succeeded; run.result = try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(value))
        return run
    }
    @Test("The exact production large-result receipt bytes are prepared off MainActor and retain the same digest and fields")
    func actualLargeReceiptPreparesOffMain() async throws {
        let run = try run(samples:20_000), projectID = UUID()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let expected = try encoder.encode(ChemistryRunReceipt(projectID:projectID,run:run))
        let prepared = try await personalPreviewOffMain { () throws -> (Data,Bool) in
            let onMain = Thread.isMainThread
            let data = try ChemistryRunOutputPreparation.receipt(projectID:projectID,run:run,
                checkCancellation:{try Task.checkCancellation()})
            return (data,onMain)
        }
        #expect(!prepared.1 && prepared.0 == expected)
        let output = try #require(JSONSerialization.jsonObject(with:prepared.0) as? [String:Any])
        #expect(output["resultComplete"] as? Bool == false && output["result"] is NSNull)
        #expect((output["resultFields"] as? [[String:Any]])?.contains{$0["key"] as? String == "points"} == true)
        #expect((output["resultBytes"] as? Int ?? 0) > 48 * 1024)
    }
    @Test("The exact production export preparation retains real JSON/CSV bytes, hashes and source provenance off MainActor")
    func actualExportsKeepTheirDataAndProvenance() async throws {
        let run = try run(), projectID = UUID()
        let snapshot = try ChemistryResultData.snapshot(try #require(run.result))
        for format in ["csv","json"] {
            let result = try await personalPreviewOffMain { () throws -> (ChemistryPreparedExport,Bool) in
                let onMain = Thread.isMainThread
                let prepared = try ChemistryResultPreparation.export(projectID:projectID,run:run,owner:nil,format:format,
                    resultKey:format == "csv" ? "points":nil,expectedSHA256:snapshot.sha256,
                    checkCancellation:{try Task.checkCancellation()})
                return (prepared,onMain)
            }
            #expect(!result.1 && result.0.files.count == (format == "csv" ? 2:1))
            let receipt = try #require(JSONSerialization.jsonObject(with:result.0.receipt) as? [String:Any])
            let provenance = try #require(receipt["provenance"] as? [String:Any])
            #expect(provenance["resultSHA256"] as? String == snapshot.sha256 && provenance["inputRevision"] as? String == "3")
            for file in result.0.files {
                #expect(file.sha256 == ChemistryProjectStore.digest(file.data))
                if file.name.hasSuffix(".csv") {
                    let reread = try SpectrumAnalysis.csv(String(decoding:file.data,as:UTF8.self))
                    #expect(reread.points.count == 3 && reread.points[1].y == 1)
                } else if format == "json" {
                    let all = try #require(JSONSerialization.jsonObject(with:file.data) as? [String:Any])
                    #expect((all["result"] as? [String:Any])?["points"] is [[String:Any]])
                }
            }
        }
    }
    @Test("Cancelling the caller cancels and joins its cooperative owned preparation before any value returns")
    func cancellationJoinsOwnedPreparation() async throws {
        final class Gate: @unchecked Sendable {
            private let condition = NSCondition()
            private var started = false, released = false, finished = false
            func work() throws -> Int {
                condition.lock(); started = true; condition.broadcast()
                while !released { condition.wait() }
                condition.unlock()
                defer { condition.lock(); finished = true; condition.broadcast(); condition.unlock() }
                try Task.checkCancellation(); return 1
            }
            func state() -> (Bool,Bool) { condition.lock(); defer {condition.unlock()}; return (started,finished) }
            func release() {condition.lock();released=true;condition.broadcast();condition.unlock()}
        }
        let gate = Gate()
        let task = Task { @MainActor in try await personalPreviewOffMain {try gate.work()} }
        let deadline = Date().addingTimeInterval(5)
        while !gate.state().0 && Date() < deadline { await Task.yield() }
        #expect(gate.state().0)
        task.cancel(); gate.release()
        do { _ = try await task.value; Issue.record("Cancelled cooperative preparation returned a value") }
        catch { #expect(error is CancellationError) }
        #expect(gate.state().1)
    }
}
#endif
