// FloeAndroidCoreTests — N113 native child file-result receipt contracts.
//
// Source-only: authored, NOT compiled or executed in this lane. These tests
// drive the REAL `NativeChildFileArtifacts` production helpers and the
// durable toolResult envelope shape the runtime writes.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools

private struct ReceiptFixture {
    let runID = UUID()
    let taskID = UUID()
    let childID = UUID()
    let callID = "call-child-1"
    let artifactTool = "workspace.createFile"
    let outputTool = "workspace.publishOutput"
    let bytes = Data("created text\r\n".utf8)
    let outputBytes = Data("\u{FEFF}published text\r\n".utf8)
    let artifact: ToolArtifactReference
    let output: RunOutputFile

    init() {
        let digest = FloeDigest.sha256Hex(bytes)
        artifact = ToolArtifactReference(
            id: UUID(),
            relativePath: "ChangeArtifacts/\(runID.uuidString)/\(digest).diff",
            mimeType: "text/x-diff",
            byteCount: bytes.count,
            sha256: digest
        )
        let outputID = RunOutputFile.derivedOutputID(
            runID: runID, producerCallID: callID, slot: "output")
        output = RunOutputFile(
            outputID: outputID,
            slot: "output",
            runID: runID,
            taskID: taskID,
            environmentID: "env-1",
            producerCallID: callID,
            producerTool: "workspace.publishOutput",
            relativePath: RunOutputFile.canonicalRelativePath(
                runID: runID, outputID: outputID, displayName: "saved.txt"),
            displayName: "saved.txt",
            mimeType: "text/plain",
            uti: nil,
            byteCount: outputBytes.count,
            sha256: FloeDigest.sha256Hex(outputBytes),
            role: .userFile
        )
    }

    func artifactResult(status: ToolResult.Status = .ok,
                        callID: String? = nil,
                        artifacts: [ToolArtifactReference]? = nil) -> ToolResult {
        ToolResult(
            callID: callID ?? self.callID,
            status: status,
            outputSummary: "created",
            outputDigest: "",
            artifacts: artifacts ?? [artifact],
            outputFiles: []
        )
    }

    func outputResult(status: ToolResult.Status = .ok,
                      callID: String? = nil,
                      outputs: [RunOutputFile]? = nil) -> ToolResult {
        ToolResult(
            callID: callID ?? self.callID,
            status: status,
            outputSummary: "published",
            outputDigest: "",
            artifacts: [],
            outputFiles: outputs ?? [output]
        )
    }

    func envelope(_ receipt: NativeChildFileReceipt?,
                  tool: String? = nil,
                  callID: String? = nil,
                  status: String = "ok",
                  outcomeUnknown: String? = "false") -> String {
        var object: [String: Any] = [
            "tool": tool ?? self.outputTool,
            "callID": callID ?? self.callID,
            "status": status,
            "digest": "digest",
            "output": "bounded",
        ]
        if let outcomeUnknown { object["outcomeUnknown"] = outcomeUnknown }
        if let receipt,
           let data = try? JSONEncoder().encode(receipt),
           let nested = try? JSONSerialization.jsonObject(with: data) {
            object["inlineContentReceipt"] = nested
        }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("N113 native child file-result receipts")
struct NativeChildFileArtifactsTests {

    @Test("a successful child result carries only its sealed outputs and Floe-owned change artifacts")
    func factoryAcceptsSuccessfulRealOutcomes() throws {
        let fixture = ReceiptFixture()
        let outputReceipt = NativeChildFileArtifacts.receipt(
            result: fixture.outputResult(),
            parentRunID: fixture.runID,
            taskID: fixture.taskID,
            childID: fixture.childID,
            callID: fixture.callID,
            tool: fixture.outputTool)
        let value = try #require(outputReceipt)
        #expect(value.version == 1)
        #expect(value.parentRunID == fixture.runID)
        #expect(value.taskID == fixture.taskID)
        #expect(value.childID == fixture.childID)
        #expect(value.callID == fixture.callID)
        #expect(value.tool == fixture.outputTool)
        #expect(value.artifacts.isEmpty)
        #expect(value.outputs == [fixture.output])
        #expect(value.encodedByteCount <= NativeChildFileReceipt.maximumEncodedBytes)

        // A file-writer call carries its real change artifact, never a
        // fabricated user output.
        let artifactReceipt = NativeChildFileArtifacts.receipt(
            result: fixture.artifactResult(),
            parentRunID: fixture.runID,
            taskID: fixture.taskID,
            childID: fixture.childID,
            callID: fixture.callID,
            tool: fixture.artifactTool)
        let artifactValue = try #require(artifactReceipt)
        #expect(artifactValue.artifacts == [fixture.artifact])
        #expect(artifactValue.outputs.isEmpty)
        #expect(artifactValue.tool == fixture.artifactTool)
    }

    @Test("failed, wrong-call and unsealed outcomes never mint a receipt")
    func factoryRefusesUnsuccessfulOrForeignOutcomes() {
        let fixture = ReceiptFixture()
        #expect(NativeChildFileArtifacts.receipt(
            result: fixture.outputResult(status: .failed), parentRunID: fixture.runID,
            taskID: fixture.taskID, childID: fixture.childID,
            callID: fixture.callID, tool: fixture.outputTool) == nil)
        #expect(NativeChildFileArtifacts.receipt(
            result: fixture.outputResult(callID: "other-call"), parentRunID: fixture.runID,
            taskID: fixture.taskID, childID: fixture.childID,
            callID: fixture.callID, tool: fixture.outputTool) == nil)

        var foreignOutput = fixture.output
        foreignOutput.taskID = UUID()
        #expect(NativeChildFileArtifacts.receipt(
            result: fixture.outputResult(outputs: [foreignOutput]),
            parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, callID: fixture.callID, tool: fixture.outputTool) == nil)

        var foreignArtifact = fixture.artifact
        foreignArtifact.relativePath = "ChangeArtifacts/\(UUID().uuidString)/\(foreignArtifact.sha256).diff"
        #expect(NativeChildFileArtifacts.receipt(
            result: fixture.artifactResult(artifacts: [foreignArtifact]),
            parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, callID: fixture.callID, tool: fixture.artifactTool) == nil)
    }

    @Test("durable decode requires the exact child, parent, task, call, tool and original request pair")
    func decodeChecksEveryOwnershipFact() throws {
        let fixture = ReceiptFixture()
        let receipt = try #require(NativeChildFileArtifacts.receipt(
            result: fixture.outputResult(), parentRunID: fixture.runID,
            taskID: fixture.taskID, childID: fixture.childID,
            callID: fixture.callID, tool: fixture.outputTool))
        let requests = [fixture.callID: fixture.outputTool]
        let payload = fixture.envelope(receipt)
        #expect(NativeChildFileArtifacts.advertisesReceipt(payloadJSON: payload))
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: payload, parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: requests) == receipt)

        // No earlier request row / a different requested tool: refuse.
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: payload, parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: [:]) == nil)
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: payload, parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID,
            originalRequestTools: [fixture.callID: "workspace.writeFile"]) == nil)
        // Wrong durable child/parent/task.
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: payload, parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: UUID(), originalRequestTools: requests) == nil)
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: payload, parentRunID: UUID(), taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: requests) == nil)
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: payload, parentRunID: fixture.runID, taskID: UUID(),
            childID: fixture.childID, originalRequestTools: requests) == nil)
        // Envelope call/tool drift and failed/unknown outcomes.
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(receipt, callID: "other"),
            parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: requests) == nil)
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(receipt, tool: "workspace.writeFile"),
            parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: requests) == nil)
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(receipt, status: "failed"),
            parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: requests) == nil)
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(receipt, outcomeUnknown: "true"),
            parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: requests) == nil)
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(receipt, outcomeUnknown: nil),
            parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: requests) == nil)
    }

    @Test("forged nested identities, old history and oversized data are refused")
    func forgedOrLegacyReceiptsAreNeverAdvertised() throws {
        let fixture = ReceiptFixture()
        let receipt = try #require(NativeChildFileArtifacts.receipt(
            result: fixture.outputResult(), parentRunID: fixture.runID,
            taskID: fixture.taskID, childID: fixture.childID,
            callID: fixture.callID, tool: fixture.outputTool))
        let requests = [fixture.callID: fixture.outputTool]
        // A copied receipt with a different output call identity.
        var forged = receipt
        forged.outputs[0].producerCallID = "other-call"
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(forged), parentRunID: fixture.runID,
            taskID: fixture.taskID, childID: fixture.childID,
            originalRequestTools: requests) == nil)
        // A copied canonical path with a non-derived identity.
        var foreignIdentity = receipt
        foreignIdentity.outputs[0].outputID = String(repeating: "f", count: 64)
        foreignIdentity.outputs[0].relativePath = RunOutputFile.canonicalRelativePath(
            runID: fixture.runID, outputID: foreignIdentity.outputs[0].outputID,
            displayName: foreignIdentity.outputs[0].displayName)
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(foreignIdentity), parentRunID: fixture.runID,
            taskID: fixture.taskID, childID: fixture.childID,
            originalRequestTools: requests) == nil)
        // A receipt object claiming a later version is not this contract.
        var futureVersion = receipt
        futureVersion.version = 2
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(futureVersion), parentRunID: fixture.runID,
            taskID: fixture.taskID, childID: fixture.childID,
            originalRequestTools: requests) == nil)
        // A change-artifact receipt whose path names another run is forged
        // even when its digest looks canonical.
        let artifactReceipt = try #require(NativeChildFileArtifacts.receipt(
            result: fixture.artifactResult(), parentRunID: fixture.runID,
            taskID: fixture.taskID, childID: fixture.childID,
            callID: fixture.callID, tool: fixture.artifactTool))
        var forgedArtifact = artifactReceipt
        forgedArtifact.artifacts[0].relativePath =
            "ChangeArtifacts/\(UUID().uuidString)/\(forgedArtifact.artifacts[0].sha256).diff"
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: fixture.envelope(forgedArtifact, tool: fixture.artifactTool),
            parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID,
            originalRequestTools: [fixture.callID: fixture.artifactTool]) == nil)
        // Old/ordinary result histories do not advertise a receipt at all.
        let legacy = fixture.envelope(nil)
        #expect(!NativeChildFileArtifacts.advertisesReceipt(payloadJSON: legacy))
        #expect(NativeChildFileArtifacts.decode(
            payloadJSON: legacy, parentRunID: fixture.runID, taskID: fixture.taskID,
            childID: fixture.childID, originalRequestTools: requests) == nil)
    }
}
