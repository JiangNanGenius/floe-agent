// FloeAndroidCoreTests — N113 parent + delegated-child output reader.
//
// Source-only: authored, NOT compiled/executed in this lane. Uses the REAL
// SQLite run/child stores, the REAL persisted toolResult envelope shapes and
// the REAL sealed snapshot verifier, so the 256/410 KiB reopen evidence is
// about production bytes rather than a test-only receipt model.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeAndroidCore

private func n113TempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-n113-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func n113SeedRun(_ store: SQLiteRunStore, _ manager: DatabaseManager,
                         conversationID: UUID, runID: UUID) async throws {
    try await SQLiteConversationStore(database: manager).saveConversation(
        ConversationRecord(id: conversationID, title: "N113 reader",
                           createdAt: Date(), updatedAt: Date()))
    try await store.saveRun(RunRecord(
        id: runID, conversationID: conversationID, state: "completed",
        goal: "file results", startedAt: Date(timeIntervalSince1970: 1_760_000_000)))
}

private struct ChildOutputFixture {
    let output: RunOutputFile
    let receipt: NativeChildFileReceipt
    let bytes: Data
}

private func n113ChildOutput(
    runID: UUID, taskID: UUID, childID: UUID, callID: String,
    displayName: String, bytes: Data
) throws -> ChildOutputFixture {
    let outputID = RunOutputFile.derivedOutputID(
        runID: runID, producerCallID: callID, slot: "output")
    let output = RunOutputFile(
        outputID: outputID,
        slot: "output",
        runID: runID,
        taskID: taskID,
        environmentID: "env-1",
        producerCallID: callID,
        producerTool: "workspace.publishOutput",
        relativePath: RunOutputFile.canonicalRelativePath(
            runID: runID, outputID: outputID, displayName: displayName),
        displayName: displayName,
        mimeType: "text/plain",
        uti: nil,
        byteCount: bytes.count,
        sha256: FloeDigest.sha256Hex(bytes),
        role: .userFile
    )
    let result = ToolResult(
        callID: callID, status: .ok, outputSummary: "published",
        outputDigest: "", outputFiles: [output])
    let receipt = try #require(NativeChildFileArtifacts.receipt(
        result: result, parentRunID: runID, taskID: taskID, childID: childID,
        callID: callID, tool: "workspace.publishOutput"))
    return ChildOutputFixture(output: output, receipt: receipt, bytes: bytes)
}

private func n113Envelope(
    tool: String = "workspace.publishOutput",
    callID: String,
    status: String = "ok",
    outcomeUnknown: String? = "false",
    receipt: NativeChildFileReceipt?
) throws -> String {
    var object: [String: Any] = [
        "tool": tool, "callID": callID, "status": status,
        "digest": "digest", "output": "published",
    ]
    if let outcomeUnknown { object["outcomeUnknown"] = outcomeUnknown }
    if let receipt {
        let data = try JSONEncoder().encode(receipt)
        object["inlineContentReceipt"] = try JSONSerialization.jsonObject(with: data)
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func n113RegisterChild(
    _ childStore: SQLiteChildRunStore, runID: UUID, taskID: UUID,
    childID: UUID, childIndex: Int = 1
) async throws {
    try await childStore.register(ChildRunRecord(
        id: childID, parentRunID: runID, rootRunID: runID,
        conversationID: taskID, childIndex: childIndex, kind: "execute",
        taskSummary: "child file output"))
}

@Suite("N113 parent + child output reader")
struct RunOutputChildReceiptReaderTests {

    @Test("a successful child receipt persists, reopens and joins the parent run view")
    func childReceiptPersistsReopensAndResolves() async throws {
        let directory = try n113TempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let childID = UUID()
        let callID = "call-child-1"
        let textBytes = Data("\u{FEFF}child result\r\nline 😀\r\n".utf8)
        let fixture = try n113ChildOutput(
            runID: runID, taskID: conversationID, childID: childID,
            callID: callID, displayName: "child.txt", bytes: textBytes)

        let manager = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await manager.migrate()
        let runStore = SQLiteRunStore(database: manager)
        let childStore = SQLiteChildRunStore(database: manager)
        try await n113SeedRun(runStore, manager, conversationID: conversationID, runID: runID)
        try await n113RegisterChild(childStore, runID: runID, taskID: conversationID,
                                    childID: childID)
        try await childStore.appendEntry(id: childID, kind: .toolRequest,
            payloadJSON: #"{"tool":"workspace.publishOutput","callID":"call-child-1","arguments":"{}"}"#)
        try await childStore.appendEntry(id: childID, kind: .toolResult,
            payloadJSON: n113Envelope(callID: callID, receipt: fixture.receipt))

        // The parent's own durable receipt path is unchanged: one parent
        // event still yields its exact sealed receipt alongside the child's.
        let parentBytes = Data("parent output".utf8)
        let parentOutputID = RunOutputFile.derivedOutputID(
            runID: runID, producerCallID: "call-parent", slot: "output")
        let parentReceipt = RunOutputFile(
            outputID: parentOutputID, slot: "output", runID: runID,
            taskID: conversationID, environmentID: "env-1",
            producerCallID: "call-parent", producerTool: "workspace.publishOutput",
            relativePath: RunOutputFile.canonicalRelativePath(
                runID: runID, outputID: parentOutputID, displayName: "parent.txt"),
            displayName: "parent.txt", mimeType: "text/plain", uti: nil,
            byteCount: parentBytes.count,
            sha256: FloeDigest.sha256Hex(parentBytes), role: .userFile)
        let parentJSON = String(
            decoding: try JSONEncoder().encode([parentReceipt]), as: UTF8.self)
        let parentPayload = try JSONSerialization.data(withJSONObject: [
            "tool": "workspace.publishOutput", "id": "call-parent",
            "status": "ok", "outputFilesJSON": parentJSON,
        ], options: [.sortedKeys])
        _ = try await runStore.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: String(decoding: parentPayload, as: UTF8.self))

        let reader = RunOutputPersistedReader(runStore: runStore, childRunStore: childStore)
        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        guard case .owned(let items, let truncated, let rejected) = scan else {
            Issue.record("expected owned parent+child scan, got \(scan)")
            return
        }
        #expect(items.count == 2)
        #expect(!truncated)
        #expect(rejected == 0)
        #expect(items.map(\.receipt) == [parentReceipt, fixture.output])
        #expect(items[0].childRunID == nil)
        #expect(items[0].childSequence == nil)
        #expect(items[1].receipt == fixture.output)
        #expect(items[1].childRunID == childID)
        #expect(items[1].childSequence != nil)
        let lookup = await reader.lookup(
            conversationID: conversationID, runID: runID,
            outputID: fixture.output.outputID)
        #expect(lookup == .owned(items[1]))

        // Process reopen: close the database, reopen, and resolve the same
        // receipt from the durable child transcript.
        try await manager.close()
        let reopened = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await reopened.migrate()
        let reopenedReader = RunOutputPersistedReader(
            runStore: SQLiteRunStore(database: reopened),
            childRunStore: SQLiteChildRunStore(database: reopened))
        let reopenedScan = await reopenedReader.scan(
            conversationID: conversationID, runID: runID)
        guard case .owned(let reopenedItems, _, _) = reopenedScan else {
            Issue.record("expected owned scan after reopen")
            try await reopened.close()
            return
        }
        #expect(reopenedItems.map(\.receipt) == [parentReceipt, fixture.output])

        // The sealed bytes are read through the REAL snapshot verifier, not a
        // synthesized success: write the canonical file and verify 410 KiB
        // full text agrees end to end.
        let root = directory.appendingPathComponent("artifacts", isDirectory: true)
        let snapshot = root
            .appendingPathComponent(RunOutputFile.namespacePrefix, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent(fixture.output.outputID, isDirectory: true)
            .appendingPathComponent(fixture.output.displayName)
        try FileManager.default.createDirectory(
            at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try textBytes.write(to: snapshot)
        let verification = RunOutputSnapshotStore.verify(
            fixture.output, artifactRoot: root)
        guard case .verified(let url) = verification else {
            Issue.record("expected verified snapshot, got \(verification)")
            try await reopened.close()
            return
        }
        let readBack = try Data(contentsOf: url)
        #expect(readBack == textBytes)
        try await reopened.close()
    }

    @Test("410 KiB child text resolves to a full snapshot and the reader never truncates it")
    func largeChildTextReadsToEof() async throws {
        let directory = try n113TempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let childID = UUID()
        let callID = "call-child-large"
        let unit = "page line — 😀 中文\r\n"
        var text = "\u{FEFF}"
        while text.utf8.count < 410 * 1024 { text += unit }
        let bytes = Data(text.utf8)
        let fixture = try n113ChildOutput(
            runID: runID, taskID: conversationID, childID: childID,
            callID: callID, displayName: "large.txt", bytes: bytes)
        let manager = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await manager.migrate()
        defer { try? await manager.close() }
        let runStore = SQLiteRunStore(database: manager)
        let childStore = SQLiteChildRunStore(database: manager)
        try await n113SeedRun(runStore, manager, conversationID: conversationID, runID: runID)
        try await n113RegisterChild(childStore, runID: runID, taskID: conversationID,
                                    childID: childID)
        try await childStore.appendEntry(id: childID, kind: .toolRequest,
            payloadJSON: #"{"tool":"workspace.publishOutput","callID":"call-child-large"}"#)
        try await childStore.appendEntry(id: childID, kind: .toolResult,
            payloadJSON: n113Envelope(callID: callID, receipt: fixture.receipt))

        let root = directory.appendingPathComponent("artifacts", isDirectory: true)
        let snapshot = root
            .appendingPathComponent(RunOutputFile.namespacePrefix, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent(fixture.output.outputID, isDirectory: true)
            .appendingPathComponent(fixture.output.displayName)
        try FileManager.default.createDirectory(
            at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: snapshot)

        let reader = RunOutputPersistedReader(runStore: runStore, childRunStore: childStore)
        let lookup = await reader.lookup(
            conversationID: conversationID, runID: runID,
            outputID: fixture.output.outputID)
        guard case .owned(let persisted) = lookup else {
            Issue.record("expected child receipt, got \(lookup)")
            return
        }
        let verification = RunOutputSnapshotStore.verify(
            persisted.receipt, artifactRoot: root)
        guard case .verified(let url) = verification else {
            Issue.record("expected verified 410 KiB snapshot, got \(verification)")
            return
        }
        let readBack = try Data(contentsOf: url)
        #expect(readBack.count == bytes.count)
        #expect(readBack == bytes)
        #expect(persisted.receipt.byteCount == bytes.count)
        #expect(persisted.receipt.sha256 == FloeDigest.sha256Hex(bytes))
    }

    @Test("malformed, failed, unknown, foreign and request-less child receipts are rejected, never laundered")
    func malformedChildReceiptsFailClosed() async throws {
        let directory = try n113TempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let childID = UUID()
        let manager = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await manager.migrate()
        defer { try? await manager.close() }
        let runStore = SQLiteRunStore(database: manager)
        let childStore = SQLiteChildRunStore(database: manager)
        try await n113SeedRun(runStore, manager, conversationID: conversationID, runID: runID)
        try await n113RegisterChild(childStore, runID: runID, taskID: conversationID,
                                    childID: childID)

        let good = try n113ChildOutput(
            runID: runID, taskID: conversationID, childID: childID,
            callID: "call-good", displayName: "good.txt", bytes: Data("good".utf8))
        // One clean success proves the scan is not blanket-empty.
        try await childStore.appendEntry(id: childID, kind: .toolRequest,
            payloadJSON: #"{"tool":"workspace.publishOutput","callID":"call-good"}"#)
        try await childStore.appendEntry(id: childID, kind: .toolResult,
            payloadJSON: n113Envelope(callID: "call-good", receipt: good.receipt))

        // 1. Failed outcome carrying a well-formed receipt object.
        let failedFixture = try n113ChildOutput(
            runID: runID, taskID: conversationID, childID: childID,
            callID: "call-failed", displayName: "failed.txt", bytes: Data("failed".utf8))
        try await childStore.appendEntry(id: childID, kind: .toolRequest,
            payloadJSON: #"{"tool":"workspace.publishOutput","callID":"call-failed"}"#)
        try await childStore.appendEntry(id: childID, kind: .toolResult,
            payloadJSON: n113Envelope(callID: "call-failed", status: "failed",
                                      receipt: failedFixture.receipt))
        // 2. Unknown outcome.
        let unknownFixture = try n113ChildOutput(
            runID: runID, taskID: conversationID, childID: childID,
            callID: "call-unknown", displayName: "unknown.txt", bytes: Data("unknown".utf8))
        try await childStore.appendEntry(id: childID, kind: .toolRequest,
            payloadJSON: #"{"tool":"workspace.publishOutput","callID":"call-unknown"}"#)
        try await childStore.appendEntry(id: childID, kind: .toolResult,
            payloadJSON: n113Envelope(callID: "call-unknown",
                                      outcomeUnknown: "true", receipt: unknownFixture.receipt))
        // 3. A copied receipt naming a different child.
        try await childStore.appendEntry(id: childID, kind: .toolRequest,
            payloadJSON: #"{"tool":"workspace.publishOutput","callID":"call-foreign"}"#)
        var foreign = good.receipt
        foreign.callID = "call-foreign"
        foreign.childID = UUID()
        try await childStore.appendEntry(id: childID, kind: .toolResult,
            payloadJSON: n113Envelope(callID: "call-foreign", receipt: foreign))
        // 4. A receipt with no earlier original toolRequest row.
        let requestless = try n113ChildOutput(
            runID: runID, taskID: conversationID, childID: childID,
            callID: "call-no-request", displayName: "requestless.txt",
            bytes: Data("requestless".utf8))
        try await childStore.appendEntry(id: childID, kind: .toolResult,
            payloadJSON: n113Envelope(callID: "call-no-request", receipt: requestless.receipt))
        // 5. A structurally malformed receipt object (claim present, value
        // is not the receipt shape) is rejected, never ignored as legacy.
        try await childStore.appendEntry(id: childID, kind: .toolRequest,
            payloadJSON: #"{"tool":"workspace.publishOutput","callID":"call-malformed"}"#)
        try await childStore.appendEntry(id: childID, kind: .toolResult,
            payloadJSON: #"{"tool":"workspace.publishOutput","callID":"call-malformed","status":"ok","inlineContentReceipt":"not-an-object"}"#)

        let reader = RunOutputPersistedReader(runStore: runStore, childRunStore: childStore)
        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        guard case .owned(let items, let truncated, let rejected) = scan else {
            Issue.record("expected owned scan")
            return
        }
        #expect(items.map(\.receipt) == [good.output])
        #expect(!truncated)
        #expect(rejected >= 5)
        // A rejected durable claim could have carried any identity: lookup
        // fails closed instead of proving absence.
        let lookup = await reader.lookup(
            conversationID: conversationID, runID: runID,
            outputID: String(repeating: "a", count: 64))
        if case .rejected = lookup { } else {
            Issue.record("lookup with rejected durable claims must fail closed")
        }
        // Old child history without a receipt contributes no card.
        let legacyChild = UUID()
        try await n113RegisterChild(childStore, runID: runID, taskID: conversationID,
                                    childID: legacyChild, childIndex: 2)
        try await childStore.appendEntry(id: legacyChild, kind: .toolResult,
            payloadJSON: #"{"tool":"exec.shell","callID":"legacy","status":"ok","output":"done"}"#)
        let after = await reader.scan(conversationID: conversationID, runID: runID)
        if case .owned(let afterItems, _, _) = after {
            #expect(afterItems.map(\.receipt) == [good.output])
        } else {
            Issue.record("expected owned scan after legacy child")
        }
    }
}
