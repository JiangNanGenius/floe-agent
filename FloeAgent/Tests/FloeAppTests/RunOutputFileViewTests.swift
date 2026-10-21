// Focused app tests for the in-surface run-output file card.
//
// These tests exercise the exact production predicates, not a mock:
//   * `RunOutputReceiptGate` — the ownership filter that decides whether a
//     persisted receipt may be shown inside one tool-result row. It rejects a
//     foreign run, a different call/tool/task, a non-canonical path and an
//     identity that does not re-derive from (run, call, slot).
//   * `RunOutputSnapshotStore.verify` — the real reader used by the card. A
//     binary snapshot must be retrievable byte-for-byte; tampering, resizing
//     and deletion must be reported as changed/missing, never repaired.
//
// No SwiftUI rendering is asserted here, and no simulated result is claimed as
// a native acceptance run.

import XCTest
import FloeCore
import FloeModels
import FloeTools
@testable import FloeApp

final class RunOutputFileViewTests: XCTestCase {
    private var artifactRoot: URL!

    override func setUpWithError() throws {
        artifactRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunOutputFileViewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let artifactRoot {
            try? FileManager.default.removeItem(at: artifactRoot)
        }
        artifactRoot = nil
    }

    // MARK: - Ownership gate

    func testOnlyOwnRunCallToolAndTaskReceiptIsAccepted() throws {
        let runID = UUID()
        let conversationID = UUID()
        let receipt = try makeReceipt(
            runID: runID,
            conversationID: conversationID,
            callID: "call-export",
            tool: "notes.export",
            slot: "export",
            bytes: Data("pdf-bytes".utf8),
            writeSnapshot: false
        )
        let own = RunOutputReceiptContext(
            runID: runID, conversationID: conversationID,
            callID: "call-export", toolName: "notes.export"
        )
        XCTAssertTrue(RunOutputReceiptGate.accepts(receipt, in: own))
        XCTAssertEqual(RunOutputReceiptGate.accepted([receipt], in: own), [receipt])

        let foreignRun = RunOutputReceiptContext(
            runID: UUID(), conversationID: conversationID,
            callID: "call-export", toolName: "notes.export"
        )
        XCTAssertFalse(RunOutputReceiptGate.accepts(receipt, in: foreignRun))

        let foreignCall = RunOutputReceiptContext(
            runID: runID, conversationID: conversationID,
            callID: "call-other", toolName: "notes.export"
        )
        XCTAssertFalse(RunOutputReceiptGate.accepts(receipt, in: foreignCall))

        let foreignTool = RunOutputReceiptContext(
            runID: runID, conversationID: conversationID,
            callID: "call-export", toolName: "document.convert"
        )
        XCTAssertFalse(RunOutputReceiptGate.accepts(receipt, in: foreignTool))

        let foreignConversation = RunOutputReceiptContext(
            runID: runID, conversationID: UUID(),
            callID: "call-export", toolName: "notes.export"
        )
        XCTAssertFalse(RunOutputReceiptGate.accepts(receipt, in: foreignConversation))

        // Without a provable call/tool envelope no receipt is shown.
        let unbound = RunOutputReceiptContext(runID: runID, conversationID: conversationID,
                                              callID: nil, toolName: nil)
        XCTAssertFalse(RunOutputReceiptGate.accepts(receipt, in: unbound))

        // The surface may not know the conversation; the runtime-sealed task
        // binding must still be present.
        let conversationUnknown = RunOutputReceiptContext(
            runID: runID, conversationID: nil,
            callID: "call-export", toolName: "notes.export"
        )
        XCTAssertTrue(RunOutputReceiptGate.accepts(receipt, in: conversationUnknown))

        var unboundTask = receipt
        unboundTask.taskID = nil
        XCTAssertFalse(RunOutputReceiptGate.accepts(unboundTask, in: conversationUnknown))

        // A copied receipt whose identity does not re-derive from its own
        // run/call/slot is never accepted, even with matching envelope text.
        var copied = receipt
        copied.outputID = String(repeating: "a", count: 64)
        XCTAssertFalse(RunOutputReceiptGate.accepts(copied, in: own))
    }

    // MARK: - Real snapshot verification

    func testBinarySnapshotIsRetrievableThenTamperAndDeletionAreReported() throws {
        let runID = UUID()
        let conversationID = UUID()
        var bytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37]) // %PDF-1.7
        bytes.append(Data((0..<4_096).map { UInt8($0 % 251) }))
        let receipt = try makeReceipt(
            runID: runID,
            conversationID: conversationID,
            callID: "call-pdf",
            tool: "notes.export",
            slot: "export",
            displayName: "Report.pdf",
            mimeType: "application/pdf",
            uti: "com.adobe.pdf",
            bytes: bytes,
            writeSnapshot: true
        )

        guard case .verified(let url) = RunOutputSnapshotStore.verify(receipt, artifactRoot: artifactRoot) else {
            return XCTFail("the exact binary snapshot must verify")
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(receipt.byteCount, bytes.count)

        // Same size, different bytes: digest mismatch, never silently adopted.
        var sameSizeTamper = bytes
        sameSizeTamper[0] = 0x00
        try sameSizeTamper.write(to: url)
        guard case .changed(let name) = RunOutputSnapshotStore.verify(receipt, artifactRoot: artifactRoot) else {
            return XCTFail("a changed snapshot must be reported as changed")
        }
        XCTAssertEqual(name, "Report.pdf")

        // Different size is also changed (checked before hashing).
        try (bytes + Data([0x00])).write(to: url)
        guard case .changed = RunOutputSnapshotStore.verify(receipt, artifactRoot: artifactRoot) else {
            return XCTFail("a resized snapshot must be reported as changed")
        }

        // Restoring the exact bytes verifies again; deletion is reported as
        // missing rather than recreated from the receipt.
        try bytes.write(to: url)
        guard case .verified = RunOutputSnapshotStore.verify(receipt, artifactRoot: artifactRoot) else {
            return XCTFail("restored exact bytes must verify")
        }
        try FileManager.default.removeItem(at: url)
        guard case .missing(let missingName) = RunOutputSnapshotStore.verify(receipt, artifactRoot: artifactRoot) else {
            return XCTFail("a deleted snapshot must be reported as missing")
        }
        XCTAssertEqual(missingName, "Report.pdf")
    }

    func testReceiptPointingAtAnotherIdentityIsRejectedBeforeAnyRead() throws {
        let runID = UUID()
        let conversationID = UUID()
        let bytes = Data("real bytes".utf8)
        let receipt = try makeReceipt(
            runID: runID,
            conversationID: conversationID,
            callID: "call-1",
            tool: "document.convert",
            slot: "document",
            bytes: bytes,
            writeSnapshot: true
        )

        var foreign = receipt
        foreign.runID = UUID()
        guard case .rejected(let reason) = RunOutputSnapshotStore.verify(foreign, artifactRoot: artifactRoot) else {
            return XCTFail("a receipt whose path/identity disagrees must be rejected")
        }
        XCTAssertFalse(reason.isEmpty)

        var renamed = receipt
        renamed.displayName = "Other.pdf"
        guard case .rejected = RunOutputSnapshotStore.verify(renamed, artifactRoot: artifactRoot) else {
            return XCTFail("a renamed receipt must not resolve the original snapshot")
        }
    }

    // MARK: - Fixture

    private func makeReceipt(
        runID: UUID,
        conversationID: UUID,
        callID: String,
        tool: String,
        slot: String,
        displayName: String = "export.bin",
        mimeType: String = "application/octet-stream",
        uti: String? = nil,
        bytes: Data,
        writeSnapshot: Bool
    ) throws -> RunOutputFile {
        let outputID = RunOutputFile.derivedOutputID(
            runID: runID, producerCallID: callID, slot: slot
        )
        let relative = RunOutputFile.canonicalRelativePath(
            runID: runID, outputID: outputID, displayName: displayName
        )
        if writeSnapshot {
            let url = artifactRoot.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try bytes.write(to: url)
        }
        return RunOutputFile(
            outputID: outputID,
            slot: slot,
            runID: runID,
            taskID: conversationID,
            environmentID: "env-test",
            producerCallID: callID,
            producerTool: tool,
            relativePath: relative,
            displayName: displayName,
            mimeType: mimeType,
            uti: uti,
            byteCount: bytes.count,
            sha256: FloeDigest.sha256Hex(bytes),
            role: .userFile
        )
    }
}
