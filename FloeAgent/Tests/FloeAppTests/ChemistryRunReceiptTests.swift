// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) || FLOE_SCIENCE_RECEIPT_QUALIFICATION
import Foundation
import Testing
import FloeChemistryCore
#if FLOE_SCIENCE_RECEIPT_QUALIFICATION
@testable import ChemistryHostReceiptQualification
#else
@testable import FloeApp
#endif

@Suite("Actual chemistry Host result receipt")
struct ChemistryRunReceiptTests {
    private func run(_ result: JSONValue, method: String) -> ChemistryRun {
        let object = ChemicalObject(title:"Saved result contract",kind:.spectrum,format:"csv",source:"x,y\n0,0\n1,2\n2,0",revision:3)
        var run = ChemistryRun(input:object,inputDigest:ChemistryProjectStore.digest(Data(object.source.utf8)),
            method:method,options:.object([:]),environmentID:"native.local",engineVersion:"FloeChemistryCore-contract")
        run.status = .succeeded; run.result = result; return run
    }
    @Test("The actual receipt exposes the actual Core spectrum and reaction outputs, not a scalar whitelist")
    func smallEngineOutputsReachTheModelWithoutFieldLoss() throws {
        let spectrum = try SpectrumAnalysis.csv("x,y\n0,0\n1,2\n2,0")
        let value = try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(spectrum))
        let projectID = UUID(), first = run(value,method:"spectrum.analyze")
        let receipt = try ChemistryRunReceipt(projectID:projectID,run:first)
        let parsed = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(receipt)) as? [String:Any])
        let result = try #require(parsed["result"] as? [String:Any])
        #expect((result["points"] as? [[String:Any]])?.count == 3)
        #expect(result["area"] as? Double == 2 && (result["peaks"] as? [[String:Any]])?.count == 1)
        #expect(parsed["inputDigest"] as? String == first.inputDigest && parsed["inputRevision"] as? Int == 3)
        let coefficients = try ReactionBalancer.balance(reactants:["H2","O2"],products:["H2O"])
        let second = run(.object(["coefficients":.array(coefficients.map{.number(Double($0))})]),method:"reaction.balance")
        let reactionReceipt = try ChemistryRunReceipt(projectID:projectID,run:second)
        let reaction = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(reactionReceipt)) as? [String:Any])
        #expect((reaction["result"] as? [String:Any])?["coefficients"] as? [Int] == [2,1,2])
    }
    @Test("An oversized result cannot masquerade as complete; its real field directory and digest remain visible")
    func largeReceiptIsExplicitAboutCompleteness() throws {
        let value = JSONValue.object(["points":.array((0..<6000).map{.object(["x":.number(Double($0)),"y":.number(Double($0))])}),"area":.number(10)])
        let receipt = try ChemistryRunReceipt(projectID:UUID(),run:run(value,method:"spectrum.analyze"))
        let parsed = try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(receipt)) as? [String:Any])
        #expect(parsed["resultComplete"] as? Bool == false && parsed["result"] is NSNull)
        #expect((parsed["resultFields"] as? [[String:Any]])?.compactMap{$0["key"] as? String} == ["area","points"])
        #expect((parsed["resultSHA256"] as? String)?.count == 64 && (parsed["resultBytes"] as? Int ?? 0) > 48 * 1024)
    }
}
#endif
