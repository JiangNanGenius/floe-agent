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
import ImageIO
import UniformTypeIdentifiers
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

    // MARK: - Real inline bitmap loader

    func testVerifiedPNGProducesBoundedThumbnailWithOriginalAspect() async throws {
        let bytes = try makePNG()
        let request = try imageRequest(bytes: bytes)
        var limits = RunOutputImagePreviewLoader.Limits()
        limits.thumbnailDimension = 128
        let loaded = await RunOutputImagePreviewLoader.load(request, limits: limits)
        let preview = try XCTUnwrap(loaded)
        XCTAssertEqual(preview.request, request)
        XCTAssertEqual(preview.sourceByteCount, bytes.count)
        XCTAssertGreaterThan(preview.metadataByteCount, 0)
        XCTAssertLessThanOrEqual(preview.metadataByteCount, limits.metadataBytes)
        XCTAssertLessThanOrEqual(preview.pngData.count, limits.thumbnailBytes)
        XCTAssertEqual(preview.pixelWidth, 128)
        XCTAssertEqual(preview.pixelHeight, 64)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(preview.pngData as CFData, nil))
        let bitmap = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(bitmap.width, preview.pixelWidth)
        XCTAssertEqual(bitmap.height, preview.pixelHeight)

        // A loaded result is bound to the entire receipt/envelope, not only
        // the stable outputID that SwiftUI may reuse for a changed row.
        var changed = request.receipt
        changed.sha256 = String(repeating: "b", count: 64)
        let replacement = RunOutputImagePreviewRequest(
            receipt: changed, context: request.context, artifactRoot: artifactRoot)
        XCTAssertEqual(replacement.receipt.id, preview.request.receipt.id)
        XCTAssertNotEqual(preview.request, replacement)
    }

    func testInlineLoaderRefusesTamperedMissingAndSymlinkSnapshots() async throws {
        let bytes = try makePNG()
        let request = try imageRequest(bytes: bytes)
        let url = artifactRoot.appendingPathComponent(request.receipt.relativePath)
        var tampered = bytes
        tampered[tampered.count - 1] ^= 0xFF
        try tampered.write(to: url)
        let changed = await RunOutputImagePreviewLoader.load(request)
        XCTAssertNil(changed)

        try FileManager.default.removeItem(at: url)
        let missing = await RunOutputImagePreviewLoader.load(request)
        XCTAssertNil(missing)

        let target = artifactRoot.appendingPathComponent("unowned.png")
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        let linked = await RunOutputImagePreviewLoader.load(request)
        XCTAssertNil(linked)
        // Refusal never repairs, replaces or removes the receipt's snapshot.
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), target.path)
    }

    func testInlineLoaderRefusesUnownedNonImageAndInvalidBitmap() async throws {
        let request = try imageRequest(bytes: makePNG())
        let foreignContext = RunOutputReceiptContext(
            runID: request.context.runID, conversationID: UUID(),
            callID: request.context.callID, toolName: request.context.toolName)
        let foreign = await RunOutputImagePreviewLoader.load(.init(
            receipt: request.receipt, context: foreignContext, artifactRoot: artifactRoot))
        XCTAssertNil(foreign)

        var receipt = request.receipt
        receipt.taskID = nil
        let unbound = await RunOutputImagePreviewLoader.load(.init(
            receipt: receipt, context: request.context, artifactRoot: artifactRoot))
        XCTAssertNil(unbound)

        receipt = request.receipt
        receipt.mimeType = "application/octet-stream"
        let nonImage = await RunOutputImagePreviewLoader.load(.init(
            receipt: receipt, context: request.context, artifactRoot: artifactRoot))
        XCTAssertNil(nonImage)

        let invalid = try imageRequest(bytes: Data("not an image".utf8))
        let invalidPreview = await RunOutputImagePreviewLoader.load(invalid)
        XCTAssertNil(invalidPreview)
    }

    func testInlineLoaderEnforcesByteMetadataPixelAndThumbnailBounds() async throws {
        let request = try imageRequest(bytes: makePNG())
        var byteLimit = RunOutputImagePreviewLoader.Limits()
        byteLimit.inputBytes = request.receipt.byteCount - 1
        var metadataLimit = RunOutputImagePreviewLoader.Limits()
        metadataLimit.metadataBytes = 1
        var pixelLimit = RunOutputImagePreviewLoader.Limits()
        pixelLimit.sourcePixels = 400 * 200 - 1
        var dimensionLimit = RunOutputImagePreviewLoader.Limits()
        dimensionLimit.sourceDimension = 399
        var outputLimit = RunOutputImagePreviewLoader.Limits()
        outputLimit.thumbnailBytes = 1
        for limits in [byteLimit, metadataLimit, pixelLimit, dimensionLimit, outputLimit] {
            let preview = await RunOutputImagePreviewLoader.load(request, limits: limits)
            XCTAssertNil(preview)
        }
        // The real fixture remains usable with the production bounds.
        let preview = await RunOutputImagePreviewLoader.load(request)
        XCTAssertNotNil(preview)
    }

    func testCancelledInlineLoadPublishesNoPreview() async throws {
        let request = try imageRequest(bytes: makePNG())
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RunOutputImagePreviewLoader.load(request)
        }
        let preview = await worker.value
        XCTAssertNil(preview)
    }

    private func imageRequest(bytes: Data) throws -> RunOutputImagePreviewRequest {
        let runID = UUID()
        let taskID = UUID()
        let receipt = try makeReceipt(
            runID: runID, conversationID: taskID, callID: "call-qr",
            tool: "image.qrcode", slot: "image", displayName: "QR.png",
            mimeType: "image/png", uti: UTType.png.identifier,
            bytes: bytes, writeSnapshot: true)
        return RunOutputImagePreviewRequest(receipt: receipt,
            context: RunOutputReceiptContext(runID: runID, conversationID: taskID,
                callID: "call-qr", toolName: "image.qrcode"), artifactRoot: artifactRoot)
    }

    private func makePNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8,
            bytesPerRow: 400 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 120))
        let image = try XCTUnwrap(context.makeImage())
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return encoded as Data
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
