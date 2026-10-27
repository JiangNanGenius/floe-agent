// FloeAndroidCoreTests — D04 run-output App-consumer READER regressions
// (job-6f953da44de048d0). Real SQLite durability + reopen, real durable
// toolResult payload shapes (the exact service string-map + nested
// outputFilesJSON written by the completion-critical writer), real sealed
// receipt identities. No fakes for the thing under test.
//
// Authored as SOURCE ONLY: not compiled, not executed here. Main runs the
// focused suites inside the one frozen-batch Android ARM64 build.

import Foundation
import Testing
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private func makeReaderFixtureDirectory() throws -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-ro-reader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// Builds the durable event payload EXACTLY as the completion-critical
/// service writer does: a string map; sealed receipts ride the nested
/// `outputFilesJSON` string member of the SAME toolResult event (the
/// Main-integrated ConversationRunService delta — mirrors iOS 8f185ac; a
/// receipt encoding failure is a durability failure there, so a well-formed
/// payload always carries fully encoded receipts).
private func toolResultPayloadJSON(callID: String, tool: String,
                                    receipts: [RunOutputFile]?,
                                    summary: String = "ok summary") -> String {
    var persisted: [String: String] = [
        "tool": tool,
        "id": callID,
        "status": "ok",
        "summary": summary,
        "outputDigest": "digest",
        "durationMs": "12",
        "dispatched": "true",
    ]
    if let receipts,
       let data = try? JSONEncoder().encode(receipts),
       let encoded = String(data: data, encoding: .utf8) {
        persisted["outputFilesJSON"] = encoded
    }
    let data = try! JSONSerialization.data(withJSONObject: persisted, options: [.sortedKeys])
    return String(data: data, encoding: .utf8)!
}

/// A metadata-consistent sealed receipt exactly like the runtime seal
/// produces: deterministic outputID, canonical path, sealed identities.
private func sealedReceipt(runID: UUID, conversationID: UUID?, callID: String,
                           tool: String = "workspace.publishOutput", slot: String = "document",
                           displayName: String = "report.docx",
                           mimeType: String = "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
    -> (receipt: RunOutputFile, bytes: Data) {
    let bytes = Data("snapshot bytes for \(displayName)".utf8)
    let outputID = RunOutputFile.derivedOutputID(runID: runID, producerCallID: callID, slot: slot)
    let receipt = RunOutputFile(
        outputID: outputID,
        slot: slot,
        runID: runID,
        taskID: conversationID,
        environmentID: "env-1",
        producerCallID: callID,
        producerTool: tool,
        relativePath: RunOutputFile.canonicalRelativePath(
            runID: runID, outputID: outputID, displayName: displayName),
        displayName: displayName,
        mimeType: mimeType,
        uti: nil,
        byteCount: bytes.count,
        sha256: FloeDigest.sha256Hex(bytes),
        role: .userFile
    )
    return (receipt, bytes)
}

@Suite("FloeAndroidCore.RunOutputPersistedReader durable ownership")
struct RunOutputPersistedReaderTests {

    private func openStore(at directory: URL) async throws -> (DatabaseManager, SQLiteRunStore) {
        let manager = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await manager.migrate()
        return (manager, SQLiteRunStore(database: manager))
    }

    /// Saves a run row the way production does: the runs table has a REAL
    /// foreign key to conversations, so the parent conversation is seeded
    /// through the actual ConversationStore API first (upsert by id).
    private func saveRunSeeded(_ store: SQLiteRunStore, manager: DatabaseManager,
                               _ record: RunRecord) async throws {
        try await SQLiteConversationStore(database: manager).saveConversation(
            ConversationRecord(id: record.conversationID, title: "reader fixture",
                               createdAt: Date(), updatedAt: Date()))
        try await store.saveRun(record)
    }

    // MARK: - Real persist -> reopen -> exact owned read

    @Test("sealed receipts persist through SQLite, survive a reopen, and the reader answers the EXACT owned persisted receipt")
    func sqlitePersistThenReopenExactOwnedReceipts() async throws {
        let directory = try makeReaderFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let otherRun = UUID()
        let (manager, store) = try await openStore(at: directory)
        try await saveRunSeeded(store, manager: manager, RunRecord(id: runID, conversationID: conversationID,
                                          state: "completed", goal: "g",
                                          startedAt: Date(timeIntervalSince1970: 1_760_000_000)))
        try await saveRunSeeded(store, manager: manager, RunRecord(id: otherRun, conversationID: conversationID,
                                          state: "completed", goal: "g",
                                          startedAt: Date(timeIntervalSince1970: 1_760_000_001)))
        let first = sealedReceipt(runID: runID, conversationID: conversationID,
                                  callID: "call-1", tool: "workspace.publishOutput")
        let second = sealedReceipt(runID: otherRun, conversationID: conversationID,
                                   callID: "call-2", slot: "second",
                                   displayName: "notes.docx")
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-1",
                                               tool: "workspace.publishOutput",
                                               receipts: [first.receipt]))
        _ = try await store.appendEvent(
            runID: otherRun, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-2",
                                               tool: "workspace.publishOutput",
                                               receipts: [second.receipt]))
        // Kill-the-process fidelity: close and REOPEN the database file.
        try await manager.close()
        let reopened = try DatabaseManager(path: directory.appendingPathComponent("db.sqlite"))
        try await reopened.migrate()
        let reader = RunOutputPersistedReader(runStore: SQLiteRunStore(database: reopened))

        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        guard case .owned(let items, let truncated, let rejected) = scan else {
            Issue.record("expected owned scan, got \(scan)")
            return
        }
        #expect(items.count == 1)
        #expect(!truncated)
        #expect(rejected == 0)
        #expect(items.first?.receipt == first.receipt)
        // Cross-run association is exact: the other run's receipt never
        // leaks into this run's owned view.
        let otherScan = await reader.scan(conversationID: conversationID, runID: otherRun)
        if case .owned(let otherItems, _, _) = otherScan {
            #expect(otherItems.map(\.receipt) == [second.receipt])
        } else { Issue.record("expected owned scan for otherRun") }
        // The exact-output lookup returns the SAME persisted receipt object.
        let lookup = await reader.lookup(conversationID: conversationID, runID: runID,
                                         outputID: first.receipt.outputID)
        #expect(lookup == .owned(RunOutputPersistedReceipt(receipt: first.receipt,
                                                          eventSequence: items[0].eventSequence)))
        try await reopened.close()
    }

    @Test("legacy runs without output payloads read normally and contribute nothing")
    func legacyRecordsReadNormally() async throws {
        let directory = try makeReaderFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let (manager, store) = try await openStore(at: directory)
        defer { try? await manager.close() }
        try await saveRunSeeded(store, manager: manager, RunRecord(id: runID, conversationID: conversationID,
                                          state: "completed", goal: "g",
                                          startedAt: Date()))
        // Original service payload shapes: no outputFilesJSON member at all.
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-1", tool: "exec.shell",
                                               receipts: nil))
        // And an empty receipts array (sealed no-op) — still legacy-clean.
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-2", tool: "exec.shell",
                                               receipts: []))
        let reader = RunOutputPersistedReader(runStore: store)
        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        guard case .owned(let items, let truncated, let rejected) = scan else {
            Issue.record("expected owned scan")
            return
        }
        #expect(items.isEmpty)
        #expect(!truncated)
        #expect(rejected == 0)
    }

    @Test("one call with multiple outputs keeps payload order; multiple calls keep event order")
    func mixedReceiptsStableOrdering() async throws {
        let directory = try makeReaderFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let (manager, store) = try await openStore(at: directory)
        defer { try? await manager.close() }
        try await saveRunSeeded(store, manager: manager, RunRecord(id: runID, conversationID: conversationID,
                                          state: "completed", goal: "g",
                                          startedAt: Date()))
        let a = sealedReceipt(runID: runID, conversationID: conversationID,
                              callID: "call-1", slot: "page-1", displayName: "one.docx")
        let b = sealedReceipt(runID: runID, conversationID: conversationID,
                              callID: "call-1", slot: "page-2", displayName: "two.docx")
        let c = sealedReceipt(runID: runID, conversationID: conversationID,
                              callID: "call-2", slot: "cover", displayName: "cover.docx")
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-1", tool: "workspace.publishOutput",
                                               receipts: [b.receipt, a.receipt]))
        _ = try await store.appendEvent(
            runID: runID, kind: .assistantText, payloadJSON: "{\"text\":\"x\"}")
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-2", tool: "workspace.publishOutput",
                                               receipts: [c.receipt]))
        let reader = RunOutputPersistedReader(runStore: store)
        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        guard case .owned(let items, _, _) = scan, items.count == 3 else {
            Issue.record("expected three owned receipts")
            return
        }
        // Event sequence first, payload order inside one event.
        #expect(items.map(\.receipt.displayName) == ["two.docx", "one.docx", "cover.docx"])
    }

    // MARK: - Forged / inconsistent claims

    @Test("forged durable claims fail closed: foreign call association, cross-task sealing, identity non-derivation, and contradictory duplicates")
    func forgedClaimsRejected() async throws {
        let directory = try makeReaderFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let (manager, store) = try await openStore(at: directory)
        defer { try? await manager.close() }
        try await saveRunSeeded(store, manager: manager, RunRecord(id: runID, conversationID: conversationID,
                                          state: "completed", goal: "g",
                                          startedAt: Date()))
        // 1. Receipt names a DIFFERENT producer call than the event carrying
        //    it (model-copied sealed JSON pasted into another call).
        let trueReceipt = sealedReceipt(runID: runID, conversationID: conversationID,
                                        callID: "call-real", tool: "t")
        var mismatchedCall = trueReceipt.receipt
        mismatchedCall.producerCallID = "call-other"
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-real", tool: "t",
                                               receipts: [mismatchedCall]))
        // 2. taskID sealed to ANOTHER conversation.
        var crossTask = trueReceipt.receipt
        crossTask.taskID = UUID()
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-real", tool: "t",
                                               receipts: [crossTask]))
        // 3. outputID does not re-derive from (run, call, slot) — a copied
        //    canonical path with a foreign identity.
        var foreignIdentity = trueReceipt.receipt
        foreignIdentity.outputID = String(repeating: "f", count: 64)
        foreignIdentity.relativePath = RunOutputFile.canonicalRelativePath(
            runID: runID, outputID: foreignIdentity.outputID,
            displayName: foreignIdentity.displayName)
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-real", tool: "t",
                                               receipts: [foreignIdentity]))
        // 4. Contradictory duplicates: same canonical identity, different
        //    sealed bytes (relabelling attempt).
        let dupA = sealedReceipt(runID: runID, conversationID: conversationID,
                                 callID: "call-dup", slot: "document", displayName: "a.docx")
        var dupB = dupA.receipt
        dupB.sha256 = String(repeating: "0", count: 64)
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-dup", tool: "t",
                                               receipts: [dupA.receipt]))
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-dup", tool: "t",
                                               receipts: [dupB]))
        // One clean, fully sealed record proves the scan is not blanket-empty.
        let clean = sealedReceipt(runID: runID, conversationID: conversationID,
                                  callID: "call-clean", tool: "t")
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-clean", tool: "t",
                                               receipts: [clean.receipt]))

        let reader = RunOutputPersistedReader(runStore: store)
        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        guard case .owned(let items, let truncated, let rejected) = scan else {
            Issue.record("expected owned scan")
            return
        }
        #expect(items.map(\.receipt) == [clean.receipt])
        #expect(!truncated)
        #expect(rejected >= 4)
        // Lookups on every forged identity fail closed, and the contradictory
        // id can never resolve to either body.
        let forgedLookup = await reader.lookup(conversationID: conversationID, runID: runID,
                                               outputID: trueReceipt.receipt.outputID)
        if case .rejected = forgedLookup { } else { Issue.record("forged lookup must reject") }
        let dupLookup = await reader.lookup(conversationID: conversationID, runID: runID,
                                            outputID: dupA.receipt.outputID)
        if case .rejected = dupLookup { } else { Issue.record("contradictory lookup must reject") }
        // The clean record resolves EXACTLY.
        let cleanLookup = await reader.lookup(conversationID: conversationID, runID: runID,
                                              outputID: clean.receipt.outputID)
        #expect(cleanLookup ==
                    .owned(RunOutputPersistedReceipt(receipt: clean.receipt,
                                                     eventSequence: cleanLookupEvent(items))))
    }

    private func cleanLookupEvent(_ items: [RunOutputPersistedReceipt]) -> Int {
        items.first?.eventSequence ?? -1
    }

    @Test("idempotent re-persistence of the SAME sealed metadata does not duplicate or reject")
    func idempotentDuplicateCollapses() async throws {
        let directory = try makeReaderFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let (manager, store) = try await openStore(at: directory)
        defer { try? await manager.close() }
        try await saveRunSeeded(store, manager: manager, RunRecord(id: runID, conversationID: conversationID,
                                          state: "completed", goal: "g",
                                          startedAt: Date()))
        let r = sealedReceipt(runID: runID, conversationID: conversationID,
                              callID: "call-1", tool: "t")
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-1", tool: "t", receipts: [r.receipt]))
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-1", tool: "t", receipts: [r.receipt]))
        let reader = RunOutputPersistedReader(runStore: store)
        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        guard case .owned(let items, _, let rejected) = scan else {
            Issue.record("expected owned scan")
            return
        }
        #expect(items.count == 1)
        #expect(rejected == 0)
    }

    // MARK: - Ownership and absence

    @Test("a run row belonging to another conversation is notOwner; an unknown run is runMissing")
    func ownershipAndAbsence() async throws {
        let directory = try makeReaderFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let foreignConversation = UUID()
        let runID = UUID()
        let (manager, store) = try await openStore(at: directory)
        defer { try? await manager.close() }
        try await saveRunSeeded(store, manager: manager, RunRecord(id: runID, conversationID: foreignConversation,
                                          state: "completed", goal: "g",
                                          startedAt: Date()))
        let reader = RunOutputPersistedReader(runStore: store)
        let foreign = await reader.scan(conversationID: conversationID, runID: runID)
        #expect(foreign == .notOwner)
        let unknown = await reader.scan(conversationID: conversationID, runID: UUID())
        #expect(unknown == .runMissing)
        // Temporary/RAM runs are structurally absent from the durable store:
        // the same honest runMissing (no output-card backdoor for temporary
        // chat through this reader).
        let tempLookup = await reader.lookup(conversationID: conversationID,
                                             runID: UUID(),
                                             outputID: String(repeating: "a", count: 64))
        #expect(tempLookup == .runMissing)
        // A non-canonical requested outputID is refused BEFORE any read.
        let badID = await reader.lookup(conversationID: conversationID, runID: runID,
                                        outputID: "not-an-sha")
        if case .rejected = badID { } else { Issue.record("bad id must reject") }
    }

    @Test("a store read failure is typed storeUnavailable, never a silent empty list")
    func storeFailureIsTypedNotEmpty() async throws {
        let directory = try makeReaderFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let (manager, store) = try await openStore(at: directory)
        try await saveRunSeeded(store, manager: manager, RunRecord(id: runID, conversationID: conversationID,
                                          state: "completed", goal: "g",
                                          startedAt: Date()))
        let r = sealedReceipt(runID: runID, conversationID: conversationID,
                              callID: "call-1", tool: "t")
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-1", tool: "t", receipts: [r.receipt]))
        try await manager.close()
        let reader = RunOutputPersistedReader(runStore: store)
        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        #expect(scan == .storeUnavailable)
        let lookup = await reader.lookup(conversationID: conversationID, runID: runID,
                                         outputID: r.receipt.outputID)
        #expect(lookup == .storeUnavailable)
    }

    @Test("a bounded scan that hits its ceiling reports truncation instead of proving absence")
    func boundedScanCeilingHonest() async throws {
        let directory = try makeReaderFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let conversationID = UUID()
        let runID = UUID()
        let (manager, store) = try await openStore(at: directory)
        defer { try? await manager.close() }
        try await saveRunSeeded(store, manager: manager, RunRecord(id: runID, conversationID: conversationID,
                                          state: "completed", goal: "g",
                                          startedAt: Date()))
        // Fill six filler events, THEN the receipt, with a 2-page ceiling of
        // 2 pages x page size 2 (the injected test ceiling — production uses
        // 100 x 200): the ceiling consumes full pages and must flag.
        for index in 0..<6 {
            _ = try await store.appendEvent(
                runID: runID, kind: .usage,
                payloadJSON: "{\"inputTokens\":\"\(index)\"}")
        }
        let late = sealedReceipt(runID: runID, conversationID: conversationID,
                                 callID: "call-late", tool: "t")
        _ = try await store.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-late", tool: "t",
                                               receipts: [late.receipt]))
        let reader = RunOutputPersistedReader(runStore: store, pageSize: 2, maximumScanPages: 3)
        let scan = await reader.scan(conversationID: conversationID, runID: runID)
        guard case .owned(_, let truncated, _) = scan else {
            Issue.record("expected owned scan")
            return
        }
        #expect(truncated, "a ceiling stop on a full page must never claim completion")
        let lookup = await reader.lookup(conversationID: conversationID, runID: runID,
                                         outputID: late.receipt.outputID)
        #expect(lookup == .scanTruncated)
        // Same ceiling, but now drain to the tail with the production-like
        // ceiling: the receipt resolves and truncation is false.
        let full = RunOutputPersistedReader(runStore: store, pageSize: 2, maximumScanPages: 10)
        let fullLookup = await full.lookup(conversationID: conversationID, runID: runID,
                                           outputID: late.receipt.outputID)
        if case .owned(let resolved) = fullLookup {
            #expect(resolved.receipt == late.receipt)
        } else { Issue.record("full drain must resolve the receipt") }
    }
}
