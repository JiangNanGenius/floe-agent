import Foundation
import Testing
@testable import FloeApp

@Suite("Bounded MetricKit stack evidence")
struct RuntimeDiagnosticStackTests {
@Test("Deep App frames survive the system stack preamble and feedback upload")
func metricKitDeepApplicationFrameSurvivesUpload() throws {
    var frame: [String: Any] = ["binaryName": "FloeExecution", "offsetIntoBinaryTextSegment": 1234]
    for _ in 0..<48 { frame = ["binaryName": "SwiftUICore", "subFrames": [frame]] }
    let payload: [String: Any] = ["crashDiagnostics": [[
        "diagnosticMetaData": ["terminationReason": "watchdog scene-update"],
        "callStackTree": ["callStacks": [["threadAttributed": true, "callStackRootFrames": [frame]]]]
    ]]]
    let summary = RuntimeDiagnostics.compactEvidence(try JSONSerialization.data(withJSONObject: payload))
    let object = try #require(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
    let record = try #require((object["diagnostics"] as? [[String: Any]])?.first)
    let appFrames = try #require(record["applicationFrames"] as? [[String: Any]])
    #expect(appFrames.first?["binaryName"] as? String == "FloeExecution")
    #expect(appFrames.first?["offsetIntoBinaryTextSegment"] as? Int == 1234)
    #expect(appFrames.first?["depth"] as? Int == 48)
    #expect(record["framesOmitted"] as? Bool == true)
    #expect(record["stackScanTruncated"] as? Bool == false)
    let upload = FeedbackUploadService.boundedDiagnostics("== section metrickit_summaries ==\n" + summary)
    #expect(upload.contains("FloeExecution") && upload.contains("watchdog scene-update"))
}

@Test("CPU diagnostics retain bounded stack evidence without an attributed thread")
func metricKitUnattributedCPUFramesAreNotDiscarded() throws {
    let source: [String: Any] = ["cpuExceptionDiagnostics": [[
        "diagnosticMetaData": ["totalCPUTime": "90 sec"],
        "callStackTree": ["callStacks": [["threadAttributed": false, "callStackRootFrames": [
            ["binaryName": "FloeApp", "offsetIntoBinaryTextSegment": 987, "sampleCount": 42]
        ]]]]
    ]]]
    let summary = RuntimeDiagnostics.compactEvidence(try JSONSerialization.data(withJSONObject: source))
    let object = try #require(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
    let record = try #require((object["diagnostics"] as? [[String: Any]])?.first)
    #expect(record["attributedThreadFound"] as? Bool == false)
    #expect(record["unattributedStacksSampled"] as? Int == 1)
    let frames = try #require(record["applicationFrames"] as? [[String: Any]])
    #expect(frames.first?["sampleCount"] as? Int == 42)
    #expect(summary.utf8.count < 12_000)
}

@Test("Tight summary budgets preserve App frames before the system preamble")
func metricKitBudgetKeepsApplicationEvidence() throws {
    var frame: [String: Any] = ["binaryName": "FloeApp", "offsetIntoBinaryTextSegment": 5678]
    for _ in 0..<24 {
        frame = ["binaryName": "SwiftUICore", "binaryUUID": "11111111-2222-3333-4444-555555555555",
                 "offsetIntoBinaryTextSegment": 42, "subFrames": [frame]]
    }
    let diagnostic: [String: Any] = [
        "diagnosticMetaData": ["terminationReason": "watchdog"],
        "callStackTree": ["callStacks": [["threadAttributed": true, "callStackRootFrames": [frame]]]]
    ]
    let source: [String: Any] = ["crashDiagnostics": Array(repeating: diagnostic, count: 4)]
    let summary = RuntimeDiagnostics.compactEvidence(try JSONSerialization.data(withJSONObject: source))
    #expect(summary.utf8.count < 12_000)
    let object = try #require(JSONSerialization.jsonObject(with: Data(summary.utf8)) as? [String: Any])
    let records = try #require(object["diagnostics"] as? [[String: Any]])
    #expect(records.count == 4)
    for record in records {
        #expect((record["diagnosticMetaData"] as? [String: String])?["terminationReason"] == "watchdog")
        let frames = try #require(record["applicationFrames"] as? [[String: Any]])
        #expect(frames.first?["offsetIntoBinaryTextSegment"] as? Int == 5678)
    }
}

}
