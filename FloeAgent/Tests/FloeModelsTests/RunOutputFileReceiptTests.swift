// FloeModelsTests — S3-D run-output receipt transport.
// Focused REAL-type checks: legacy ToolResult JSON compatibility, additive
// round-trips, the deterministic slot identity algorithm and canonical-path
// validation. No stub types: these exercise the production Codable shims.

import Foundation
import Testing
@testable import FloeModels
@testable import FloeCore

private func sampleReceipt(
    runID: UUID = UUID(),
    callID: String = "call-1",
    slot: String = "document",
    name: String = "report.docx",
    mime: String = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    uti: String? = "org.openxmlformats.wordprocessingml.document",
    bytes: Int = 1234,
    digest: String = String(repeating: "ab", count: 32)
) -> RunOutputFile {
    let outputID = RunOutputFile.derivedOutputID(runID: runID, producerCallID: callID, slot: slot)
    return RunOutputFile(
        outputID: outputID,
        slot: slot,
        runID: runID,
        taskID: UUID(),
        environmentID: "env-1",
        producerCallID: callID,
        producerTool: "document.createWord",
        relativePath: RunOutputFile.canonicalRelativePath(
            runID: runID, outputID: outputID, displayName: name
        ),
        displayName: name,
        mimeType: mime,
        uti: uti,
        byteCount: bytes,
        sha256: digest,
        role: .userFile
    )
}

@Suite("FloeModels.RunOutputFile")
struct RunOutputFileTests {

    @Test("a canonical receipt validates against its own identity")
    func canonicalReceiptValidates() {
        let receipt = sampleReceipt()
        #expect(receipt.isCanonicalForCurrentRun)
        #expect(receipt.hasRuntimeConsistentIdentity)
        #expect(receipt.id == receipt.outputID)
    }

    @Test("stable identity is deterministic and call/slot/run scoped")
    func identityIsDeterministic() {
        let run = UUID()
        let a = RunOutputFile.derivedOutputID(runID: run, producerCallID: "call-1", slot: "page-1")
        let b = RunOutputFile.derivedOutputID(runID: run, producerCallID: "call-1", slot: "page-1")
        #expect(a == b)
        #expect(RunOutputFile.isValidSHA256Hex(a))
        let otherSlot = RunOutputFile.derivedOutputID(runID: run, producerCallID: "call-1", slot: "page-2")
        let otherCall = RunOutputFile.derivedOutputID(runID: run, producerCallID: "call-2", slot: "page-1")
        let otherRun = RunOutputFile.derivedOutputID(runID: UUID(), producerCallID: "call-1", slot: "page-1")
        #expect(a != otherSlot && a != otherCall && a != otherRun)
    }

    @Test("tampered receipts are never canonical")
    func tamperingRejected() {
        var foreignPath = sampleReceipt()
        foreignPath.relativePath = "GeneratedImages/fake.png"
        #expect(!foreignPath.isCanonicalForCurrentRun)

        var traversal = sampleReceipt()
        traversal.displayName = ".."
        traversal.relativePath = RunOutputFile.canonicalRelativePath(
            runID: traversal.runID, outputID: traversal.outputID, displayName: traversal.displayName
        )
        #expect(!traversal.isCanonicalForCurrentRun)
        #expect(!RunOutputFile.isValidDisplayName("../evil"))
        #expect(!RunOutputFile.isValidDisplayName(".hidden"))
        #expect(!RunOutputFile.isValidDisplayName(String(repeating: "x", count: 256)))
        #expect(RunOutputFile.isValidDisplayName("结果.pdf"))

        var upperDigest = sampleReceipt()
        upperDigest.sha256 = upperDigest.sha256.uppercased()
        #expect(!upperDigest.isCanonicalForCurrentRun)

        var relinked = sampleReceipt()
        relinked.outputID = RunOutputFile.derivedOutputID(
            runID: relinked.runID, producerCallID: "other-call", slot: relinked.slot
        )
        #expect(!relinked.hasRuntimeConsistentIdentity)

        var negative = sampleReceipt()
        negative.byteCount = -1
        #expect(!negative.isCanonicalForCurrentRun)
    }

    @Test("legacy ToolResult JSON without outputFiles decodes to the stable empty value")
    func legacyDecode() throws {
        let legacy = #"{"callID":"c1","status":"ok","outputSummary":"done","outputDigest":"d","artifacts":[{"id":"9A6A1A14-7D2D-4E3B-9F77-5C0D9A2B1C01","relativePath":"GeneratedImages/x.png","mimeType":"image/png","byteCount":10,"sha256":"aa"}]}"#
        let result = try JSONDecoder().decode(ToolResult.self, from: Data(legacy.utf8))
        #expect(result.outputFiles.isEmpty)
        #expect(result.artifacts.count == 1)
        #expect(result.status == .ok)
    }

    @Test("outputFiles round-trips and the key stays omitted when empty")
    func additiveRoundTrip() throws {
        let receipts = [sampleReceipt(), sampleReceipt(slot: "thumbnail", name: "t.png")]
        let result = ToolResult(
            callID: "c1", status: .ok, outputSummary: "done", outputDigest: "d",
            artifacts: [], outputFiles: receipts
        )
        let data = try JSONEncoder().encode(result)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["outputFiles"] != nil)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded == result)

        let empty = try JSONEncoder().encode(ToolResult(
            callID: "c1", status: .ok, outputSummary: "x", outputDigest: "d"
        ))
        let emptyObject = try #require(
            JSONSerialization.jsonObject(with: empty) as? [String: Any]
        )
        #expect(emptyObject["outputFiles"] == nil)
    }

    @Test("receipts survive decoding inside the AgentEvent toolResult case")
    func eventTransportCarriesReceipts() throws {
        let result = ToolResult(
            callID: "c9", status: .ok, outputSummary: "saved", outputDigest: "d",
            outputFiles: [sampleReceipt()]
        )
        let data = try JSONEncoder().encode(AgentEvent.toolResult(result))
        let decoded = try JSONDecoder().decode(AgentEvent.self, from: data)
        guard case .toolResult(let carried) = decoded else {
            Issue.record("event family changed"); return
        }
        #expect(carried.outputFiles.count == 1)
        #expect(carried.outputFiles[0] == result.outputFiles[0])
    }
}
