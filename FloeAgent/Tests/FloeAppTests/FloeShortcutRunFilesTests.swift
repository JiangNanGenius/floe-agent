// S3-D focused tests for the exact-run file projection and the ONE
// Get Run Files intent.
//
// Two honest layers run here:
//   * REAL persistence + REAL snapshot verification: the production
//     `SQLiteRunOutputReader` reads real in-memory SQLite run events while
//     the production `RunOutputSnapshotStore.verify` re-checks bytes under a
//     private temporary artifact root. Canonical snapshot bytes are seeded
//     directly at the path core's publisher would have committed (producer
//     registration is the separate S4/native lane); nothing here stubs the
//     reader or the verifier.
//   * Hosted App Intent `perform()` through the DEBUG task-local seam,
//     exactly as Shortcuts invokes it.
// The end-to-end Runtime→native-creator→ToolExecutionOutput→seal→pump
// proof needs producer registration plus the full App/SIL build and stays
// with the primary integration owner (recorded pending in this package's
// REPORT.md; it is NOT claimed passed here). The seeded toolResult and
// terminal events below are fixtures for the READER/SERVICE verification
// layers only — production event ORDER (completion-critical toolResult
// before flushed assistant text and terminal) is respected so the policy
// gates under test are the real ones, but no seeded row is presented as a
// runtime-produced end-to-end result.

import XCTest
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
// The service/error types under test live in the App target itself.
@testable import FloeApp
#if canImport(AppIntents)
import AppIntents
import UniformTypeIdentifiers
#endif

final class FloeShortcutRunFilesTests: XCTestCase {

    private let conversationID = UUID(uuidString: "5C5C5C5C-0000-4000-8000-00000000F001")!
    private let otherConversationID = UUID(uuidString: "6D6D6D6D-0000-4000-8000-00000000F002")!
    private let runID = UUID(uuidString: "7E7E7E7E-0000-4000-8000-00000000F003")!

    private var database: DatabaseManager!
    private var conversations: SQLiteConversationStore!
    private var runs: SQLiteRunStore!
    private var artifactRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        database = try DatabaseManager.inMemory()
        try await database.migrate()
        conversations = SQLiteConversationStore(database: database)
        runs = SQLiteRunStore(database: database)
        artifactRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeRunFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: artifactRoot)
        database = nil
        conversations = nil
        runs = nil
        artifactRoot = nil
        try await super.tearDown()
    }

    // MARK: - Seeding helpers (real durable shapes, real encoders)

    private func seedConversation(_ id: UUID, purpose: ConversationPurpose = .ordinary,
                                  isolation: isolated (any Actor)? = #isolation) async throws {
        try await conversations.saveConversation(.init(
            id: id, title: "Synthetic files task",
            createdAt: Date(), updatedAt: Date(), purpose: purpose))
    }

    @discardableResult
    private func seedRun(
        conversationID: UUID,
        runID: UUID,
        state: String,
        withTerminalProof answer: String? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> UUID {
        try await runs.saveRun(.init(
            id: runID, conversationID: conversationID, state: state,
            goal: "Synthetic files goal",
            startedAt: Date(),
            endedAt: answer != nil || ["failed", "cancelled", "interrupted"].contains(state)
                ? Date() : nil))
        if let answer {
            try await appendTerminalProof(runID: runID, conversationID: conversationID, answer: answer)
        }
        return runID
    }

    /// Seeds a run row ONLY (no proof events) so the caller can append all
    /// tool events FIRST and then `appendTerminalProof`, matching the
    /// production durable order: toolRequest → completion-critical
    /// toolResult → flushed assistant text → terminal. A terminal proof
    /// written before later tool events is not a final reply the
    /// production reader accepts.
    private func seedRunShell(conversationID: UUID, runID: UUID, state: String, ended: Bool,
                              isolation: isolated (any Actor)? = #isolation) async throws {
        try await runs.saveRun(.init(
            id: runID, conversationID: conversationID, state: state,
            goal: "Synthetic files goal",
            startedAt: Date(), endedAt: ended ? Date() : nil))
    }

    /// Appends the durable completion proof in production order. Call only
    /// AFTER every tool event for the run has been appended.
    private func appendTerminalProof(runID: UUID, conversationID: UUID, answer: String,
                                     isolation: isolated (any Actor)? = #isolation) async throws {
        let messageID = UUID()
        try await conversations.appendMessage(.init(
            id: messageID, conversationID: conversationID, role: "assistant",
            content: answer, createdAt: Date(), runID: runID))
        _ = try await runs.appendEvent(
            runID: runID, kind: .assistantText,
            payloadJSON: "{\"text\":\"\(answer)\"}")
        _ = try await runs.appendEvent(
            runID: runID, kind: .terminal,
            payloadJSON: "{\"stopReason\":\"endTurn\",\"finalMessageID\":\"\(messageID.uuidString)\"}")
    }

    private func snapshotBytes(_ text: String = "run produced bytes") -> Data {
        Data(text.utf8)
    }

    /// Seals a receipt exactly like core's store would and writes the
    /// canonical snapshot bytes under the private artifact root. Returns the
    /// receipt to embed plus its commit bytes for later comparison.
    @discardableResult
    private func publishCanonicalSnapshot(
        runID: UUID,
        conversationID: UUID,
        callID: String,
        tool: String,
        slot: String = "document",
        displayName: String = "report.docx",
        uti: String? = "org.openxmlformats.wordprocessingml.document",
        mimeType: String = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        bytes: Data? = nil
    ) throws -> RunOutputFile {
        let content = bytes ?? snapshotBytes()
        let digest = FloeDigest.sha256Hex(content)
        let outputID = RunOutputFile.derivedOutputID(
            runID: runID, producerCallID: callID, slot: slot
        )
        let url = artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent(outputID, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try content.write(to: url.appendingPathComponent(displayName))
        return RunOutputFile(
            outputID: outputID,
            slot: slot,
            runID: runID,
            taskID: conversationID,
            environmentID: "env-seed",
            producerCallID: callID,
            producerTool: tool,
            relativePath: RunOutputFile.canonicalRelativePath(
                runID: runID, outputID: outputID, displayName: displayName
            ),
            displayName: displayName,
            mimeType: mimeType,
            uti: uti,
            byteCount: content.count,
            sha256: digest,
            role: .userFile
        )
    }

    private func appendToolResult(
        runID: UUID,
        tool: String,
        callID: String,
        status: String,
        receipts: [RunOutputFile]? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        var map: [String: String] = [
            "tool": tool, "id": callID, "status": status,
            "summary": "bounded summary",
            "outputDigest": String(repeating: "0", count: 64),
            "durationMs": "5", "dispatched": "true"
        ]
        if let receipts {
            map["outputFilesJSON"] = String(
                data: try JSONEncoder().encode(receipts), encoding: .utf8)!
        }
        _ = try await runs.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: String(data: try JSONEncoder().encode(map), encoding: .utf8)!)
    }

    /// Instrumentation counters around the REAL production deps.
    private final class CallCounters: @unchecked Sendable {
        var manifestCalls = 0
        var verifyCalls = 0
    }

    private func makeService(
        counters: CallCounters,
        includeManifest: Bool = true,
        includeVerifier: Bool = true,
        manifestError: (any (Error & Sendable))? = nil,
        verifyOverride: (@Sendable (RunOutputFile) async -> RunOutputSnapshotVerification)? = nil,
        capabilityEnabled: @escaping @Sendable () -> Bool = { true }
    ) -> FloeShortcutRunService {
        let store = runs!
        let conversations = self.conversations!
        let database = self.database!
        let reader = SQLiteRunOutputReader(database: database)
        let root = artifactRoot!
        let counters = counters
        let manifest: (@Sendable (UUID, UUID) async throws -> [RunOutputManifestRow])?
        if includeManifest {
            manifest = { runID, conversationID in
                counters.manifestCalls += 1
                if let manifestError { throw manifestError }
                return try await reader.manifestRows(
                    runID: runID, expectedConversationID: conversationID)
            }
        } else { manifest = nil }
        let verifier: (@Sendable (RunOutputFile) async -> RunOutputSnapshotVerification)?
        if includeVerifier {
            verifier = { receipt in
                counters.verifyCalls += 1
                if let verifyOverride { return await verifyOverride(receipt) }
                return RunOutputSnapshotStore.verify(receipt, artifactRoot: root)
            }
        } else { verifier = nil }
        return FloeShortcutRunService(deps: FloeShortcutRunDeps(
            ensureReady: { _ in },
            capabilityEnabled: capabilityEnabled,
            defaultModel: { nil },
            startTask: { _ in throw FloeShortcutRunError.noDefaultModelConfigured },
            cancelRun: { _ in },
            hasLiveOwner: { _ in false },
            loadRun: { try await store.run(id: $0) },
            loadConversation: { try await conversations.conversation(id: $0) },
            recentRunEvents: { runID, limit in
                try await store.recentEvents(runID: runID, limit: limit)
            },
            earlierRunEvents: { runID, sequence, limit in
                try await store.earlierEvents(runID: runID, beforeSequence: sequence, limit: limit)
            },
            provenFinalReplyText: { runID, conversationID, messageID in
                try await SQLiteRunReplyReader(database: database)
                    .provenFinalReplyText(runID: runID, conversationID: conversationID, messageID: messageID)
            },
            runOutputManifest: manifest,
            verifyRunOutputSnapshot: verifier,
            monotonicNow: { 0 },
            pause: { _ in }
        ))
    }

    // MARK: - Default success policy (real reader + real verifier)

    func testSuccessfulRunReturnsOnlyVerifiedCanonicalFiles() async throws {
        try await seedConversation(conversationID)
        let receipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-doc", tool: "document.convert"
        )
        // Production durable order: completion-critical toolResult BEFORE
        // the flushed assistant text and terminal event.
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        try await appendToolResult(
            runID: runID, tool: "document.convert", callID: "call-doc",
            status: "ok", receipts: [receipt]
        )
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "converted"
        )
        let counters = CallCounters()
        let service = makeService(counters: counters)
        let result = try await service.fileResult(
            runID: runID, expectedConversationID: conversationID)
        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.files.count, 1)
        let descriptor = try XCTUnwrap(result.files.first)
        XCTAssertEqual(descriptor.displayName, "report.docx")
        XCTAssertEqual(descriptor.url.lastPathComponent, "report.docx")
        let stored = try Data(contentsOf: descriptor.url)
        XCTAssertEqual(FloeDigest.sha256Hex(stored), receipt.sha256)
        XCTAssertEqual(stored, snapshotBytes())
        XCTAssertEqual(counters.verifyCalls, 1)
    }

    func testSeedOrderingAssistantTextMustFollowToolEvents() async throws {
        // Durable order check: with every tool event BEFORE the flushed
        // assistant text and the terminal marker, the complete-success file
        // path serves normally (production semantics of
        // `finalTextFollowsAllTools`). The negative control below appends a
        // tool event AFTER the proof and must be refused by the default
        // policy instead of reaching caps or disk.
        try await seedConversation(conversationID)
        let run = UUID()
        try await runs.saveRun(.init(
            id: run, conversationID: conversationID, state: "completed",
            goal: "Ordered files goal", startedAt: Date(), endedAt: Date()))
        let receipt = try publishCanonicalSnapshot(
            runID: run, conversationID: conversationID,
            callID: "call-ordered", tool: "network.download", slot: "file"
        )
        _ = try await runs.appendEvent(
            runID: run, kind: .toolRequest,
            payloadJSON: "{\"tool\":\"network.download\",\"id\":\"call-ordered\"}")
        try await appendToolResult(
            runID: run, tool: "network.download", callID: "call-ordered",
            status: "ok", receipts: [receipt])
        let messageID = UUID()
        try await conversations.appendMessage(.init(
            id: messageID, conversationID: conversationID, role: "assistant",
            content: "downloaded", createdAt: Date(), runID: run))
        _ = try await runs.appendEvent(
            runID: run, kind: .assistantText, payloadJSON: "{\"text\":\"downloaded\"}")
        _ = try await runs.appendEvent(
            runID: run, kind: .terminal,
            payloadJSON: "{\"stopReason\":\"endTurn\",\"finalMessageID\":\"\(messageID.uuidString)\"}")
        let counters = CallCounters()
        let service = makeService(counters: counters)
        let result = try await service.fileResult(runID: run, expectedConversationID: conversationID)
        XCTAssertEqual(result.completeness, .complete)
        XCTAssertEqual(result.files.map(\.displayName), ["report.docx"])

        // Negative control: the terminal proof is complete, then ONE more
        // tool event lands after it — the latest assistant text no longer
        // follows all tools, so the default policy must refuse before the
        // manifest read ever reaches caps or filesystem work.
        let lateToolRun = UUID()
        try await seedRunShell(conversationID: conversationID, runID: lateToolRun, state: "completed", ended: true)
        try await appendTerminalProof(
            runID: lateToolRun, conversationID: conversationID, answer: "converted early")
        let lateReceipt = try publishCanonicalSnapshot(
            runID: lateToolRun, conversationID: conversationID,
            callID: "call-late", tool: "network.download", slot: "late",
            displayName: "late.bin")
        try await appendToolResult(
            runID: lateToolRun, tool: "network.download", callID: "call-late",
            status: "ok", receipts: [lateReceipt])
        let lateCounters = CallCounters()
        let lateService = makeService(counters: lateCounters)
        do {
            _ = try await lateService.fileResult(
                runID: lateToolRun, expectedConversationID: conversationID)
            XCTFail("a tool event after the terminal proof must not serve files by default")
        } catch let error as FloeRunFilesError {
            XCTAssertEqual(error, .notReady)
        }
        XCTAssertEqual(lateCounters.verifyCalls, 0,
            "an unprovable run must never reach snapshot verification")
    }

    func testSuccessfulRunWithoutOutputsIsHonestNoFiles() async throws {
        try await seedConversation(conversationID)
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        try await appendToolResult(
            runID: runID, tool: "exec.shell", callID: "c-plain", status: "ok")
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "no files here")
        let counters = CallCounters()
        let service = makeService(counters: counters)
        let result = try await service.fileResult(
            runID: runID, expectedConversationID: conversationID)
        XCTAssertEqual(result.completeness, .noFiles)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(counters.verifyCalls, 0)
    }

    // MARK: - Ownership before any filesystem access

    func testForgedEntityConversationNeverTouchesManifestOrDisk() async throws {
        try await seedConversation(conversationID)
        let receipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-doc", tool: "document.convert"
        )
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        try await appendToolResult(
            runID: runID, tool: "document.convert", callID: "call-doc",
            status: "ok", receipts: [receipt])
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "converted"
        )
        let counters = CallCounters()
        let service = makeService(counters: counters)
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: otherConversationID)
            XCTFail("a foreign owner reference must be rejected")
        } catch let error as FloeRunFilesError {
            XCTAssertEqual(error, .ownership)
        }
        XCTAssertEqual(counters.manifestCalls, 0)
        XCTAssertEqual(counters.verifyCalls, 0,
            "ownership must fail before any filesystem verification starts")
    }

    // MARK: - Partial policy

    func testDefaultRefusesActiveRunAndServesExplicitPartial() async throws {
        try await seedConversation(conversationID)
        try await runs.saveRun(.init(
            id: runID, conversationID: conversationID, state: "streamingModel",
            goal: "Active files goal", startedAt: Date(), endedAt: nil))
        let receipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-live", tool: "image.generate", slot: "image",
            displayName: "frame.png",
            uti: "public.png", mimeType: "image/png",
            bytes: snapshotBytes("png bytes")
        )
        try await appendToolResult(
            runID: runID, tool: "image.generate", callID: "call-live",
            status: "ok", receipts: [receipt])
        let counters = CallCounters()
        let service = makeService(counters: counters)
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: conversationID,
                includePartial: false)
            XCTFail("active runs must not serve files by default")
        } catch let error as FloeRunFilesError {
            XCTAssertEqual(error, .notReady)
        }
        XCTAssertEqual(counters.verifyCalls, 0, "the default gate must fail before disk reads")
        let partial = try await service.fileResult(
            runID: runID, expectedConversationID: conversationID,
            includePartial: true)
        XCTAssertEqual(partial.completeness, .partialRun)
        XCTAssertEqual(partial.files.map(\.displayName), ["frame.png"])
        XCTAssertFalse(partial.status.isFullSuccess,
            "partial must never reclassify the run's own status")
    }

    func testPartialNeverSkipsMissingOrChangedFiles() async throws {
        try await seedConversation(conversationID)
        try await runs.saveRun(.init(
            id: runID, conversationID: conversationID, state: "failed",
            goal: "Failed run with outputs", startedAt: Date(), endedAt: Date()))
        let present = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-a", tool: "network.download", slot: "a")
        let deleted = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-b", tool: "network.download", slot: "b",
            displayName: "gone.bin")
        try FileManager.default.removeItem(
            at: artifactRoot
                .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue)
                .appendingPathComponent(runID.uuidString)
                .appendingPathComponent(deleted.outputID)
                .appendingPathComponent("gone.bin"))
        try await appendToolResult(
            runID: runID, tool: "network.download", callID: "call-a",
            status: "ok", receipts: [present])
        try await appendToolResult(
            runID: runID, tool: "network.download", callID: "call-b",
            status: "failed", receipts: [deleted])
        let counters = CallCounters()
        let service = makeService(counters: counters)
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: conversationID,
                includePartial: true)
            XCTFail("a missing snapshot must be an honest error even under partial")
        } catch let error as FloeRunFilesError {
            guard case .fileMissing(let name) = error else {
                return XCTFail("expected fileMissing, got \(error)")
            }
            XCTAssertEqual(name, "gone.bin")
        }
    }

    func testTamperedSnapshotReportsChanged() async throws {
        try await seedConversation(conversationID)
        let receipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-doc", tool: "document.convert")
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        try await appendToolResult(
            runID: runID, tool: "document.convert", callID: "call-doc",
            status: "ok", receipts: [receipt])
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "done")
        // Tamper the snapshot itself (workspace original edits can never
        // reach here; only direct snapshot tampering changes these bytes).
        let snapshot = artifactRoot
            .appendingPathComponent(ArtifactNamespace.runOutputs.rawValue)
            .appendingPathComponent(runID.uuidString)
            .appendingPathComponent(receipt.outputID)
            .appendingPathComponent(receipt.displayName)
        try snapshotBytes("tampered").write(to: snapshot)
        let counters = CallCounters()
        let service = makeService(counters: counters)
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: conversationID)
            XCTFail("tampered snapshot bytes must fail as changed")
        } catch let error as FloeRunFilesError {
            guard case .fileChanged(let name) = error else {
                return XCTFail("expected fileChanged, got \(error)")
            }
            XCTAssertEqual(name, "report.docx")
        }
    }

    // MARK: - Row policy and damaged attachments

    func testFailedCallReceiptsInvisibleByDefaultVisibleUnderPartial() async throws {
        try await seedConversation(conversationID)
        let okReceipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-ok", tool: "document.convert", slot: "final")
        let failedReceipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-failed", tool: "document.convert", slot: "attempt",
            displayName: "attempt.docx")
        // Production ordering: tool events, flushed text, terminal.
        try await runs.saveRun(.init(
            id: runID, conversationID: conversationID, state: "completed",
            goal: "Mixed calls", startedAt: Date(), endedAt: Date()))
        try await appendToolResult(
            runID: runID, tool: "document.convert", callID: "call-ok",
            status: "ok", receipts: [okReceipt])
        try await appendToolResult(
            runID: runID, tool: "document.convert", callID: "call-failed",
            status: "failed", receipts: [failedReceipt])
        let messageID = UUID()
        try await conversations.appendMessage(.init(
            id: messageID, conversationID: conversationID, role: "assistant",
            content: "done", createdAt: Date(), runID: runID))
        _ = try await runs.appendEvent(runID: runID, kind: .assistantText,
                                       payloadJSON: "{\"text\":\"done\"}")
        _ = try await runs.appendEvent(
            runID: runID, kind: .terminal,
            payloadJSON: "{\"stopReason\":\"endTurn\",\"finalMessageID\":\"\(messageID.uuidString)\"}")
        let counters = CallCounters()
        let service = makeService(counters: counters)
        let strict = try await service.fileResult(
            runID: runID, expectedConversationID: conversationID)
        XCTAssertEqual(strict.files.map(\.displayName), ["report.docx"],
            "default policy consumes only successful-call receipts")
        let partial = try await service.fileResult(
            runID: runID, expectedConversationID: conversationID, includePartial: true)
        XCTAssertEqual(Set(partial.files.map(\.displayName)),
                       Set(["report.docx", "attempt.docx"]))
        XCTAssertEqual(partial.completeness, .complete,
            "a proven successful run stays complete even with the option on")
    }

    func testManifestOnDeniedCallIsDamagedUnderEveryPolicy() async throws {
        try await seedConversation(conversationID)
        let receipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-denied", tool: "document.convert")
        // A completed run whose durable record nonetheless carries a
        // manifest on a "denied" call: structurally impossible for the
        // runtime, so it must fail as damaged under BOTH policies — the
        // anomaly check is about the record, not about the run state.
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        try await appendToolResult(
            runID: runID, tool: "document.convert", callID: "call-denied",
            status: "denied", receipts: [receipt])
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "denied anomaly")
        for partial in [false, true] {
            let counters = CallCounters()
            let service = makeService(counters: counters)
            do {
                _ = try await service.fileResult(
                    runID: runID, expectedConversationID: conversationID,
                    includePartial: partial)
                XCTFail("denied-call manifest must fail (partial=\(partial))")
            } catch let error as FloeRunFilesError {
                guard case .manifestDamaged = error else {
                    return XCTFail("expected manifestDamaged, got \(error)")
                }
            }
        }
    }

    func testStorageFailureSurfaceIsDurableRead() async throws {
        try await seedConversation(conversationID)
        try await seedRun(conversationID: conversationID, runID: runID,
                      state: "completed", withTerminalProof: "done")
        let counters = CallCounters()
        let service = makeService(
            counters: counters,
            manifestError: FloeError.storageCorrupted("db gone"))
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: conversationID)
            XCTFail("a projection read failure must surface as durableReadFailed")
        } catch let error as FloeRunFilesError {
            XCTAssertEqual(error, .durableReadFailed)
        }
    }

    func testMissingDependencyIsHonestUnavailableNotEmptySuccess() async throws {
        try await seedConversation(conversationID)
        try await seedRun(conversationID: conversationID, runID: runID,
                      state: "completed", withTerminalProof: "done")
        let counters = CallCounters()
        let service = makeService(counters: counters, includeManifest: false)
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: conversationID)
            XCTFail("unwired projection must never fake an empty success")
        } catch let error as FloeRunFilesError {
            XCTAssertEqual(error, .serviceUnavailable)
        }
    }

    func testNotesAndTemporaryWorkspacesStayInvisible() async throws {
        for purpose in [ConversationPurpose.notes, .temporary] {
            let conversation = UUID()
            try await seedConversation(conversation, purpose: purpose)
            let run = UUID()
            try await seedRun(conversationID: conversation, runID: run,
                          state: "completed", withTerminalProof: "irrelevant")
            let counters = CallCounters()
            let service = makeService(counters: counters)
            do {
                _ = try await service.fileResult(
                    runID: run, expectedConversationID: conversation)
                XCTFail("purpose \(purpose) must stay rejected")
            } catch let error as FloeRunFilesError {
                XCTAssertEqual(error, .runUnavailable)
            }
            XCTAssertEqual(counters.manifestCalls, 0)
            XCTAssertEqual(counters.verifyCalls, 0)
        }
    }

    // MARK: - Caps and cancellation

    func testAggregateCapsFailExplicitlyBeforeVerification() async throws {
        try await seedConversation(conversationID)
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        // 33 distinct single-byte receipts (one per call) — over the 32-file
        // run cap. Only count/claim math is exercised; no files are needed
        // because caps must reject before ANY filesystem work.
        var allReceipts: [RunOutputFile] = []
        for index in 0..<33 {
            let outputID = RunOutputFile.derivedOutputID(
                runID: runID, producerCallID: "call-\(index)", slot: "s")
            allReceipts.append(RunOutputFile(
                outputID: outputID, slot: "s", runID: runID,
                taskID: conversationID, environmentID: nil,
                producerCallID: "call-\(index)", producerTool: "image.generate",
                relativePath: RunOutputFile.canonicalRelativePath(
                    runID: runID, outputID: outputID, displayName: "f\(index).bin"),
                displayName: "f\(index).bin", mimeType: "application/octet-stream",
                uti: nil, byteCount: 1,
                sha256: FloeDigest.sha256Hex(Data([UInt8(index)])), role: .userFile))
        }
        // One row per call keeps enclosing identity honest; all tool events
        // precede the terminal proof (production durable order).
        for receipt in allReceipts {
            try await appendToolResult(
                runID: runID, tool: "image.generate",
                callID: receipt.producerCallID, status: "ok", receipts: [receipt])
        }
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "generated many")
        let counters = CallCounters()
        let service = makeService(counters: counters)
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: conversationID)
            XCTFail("33 claims must exceed the 32-file run cap")
        } catch let error as FloeRunFilesError {
            guard case .overLimit = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(counters.verifyCalls, 0,
            "cap errors must fire before any snapshot verification")
    }

    func testPerFileCapFailsWithoutReadingBytes() async throws {
        try await seedConversation(conversationID)
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        let outputID = RunOutputFile.derivedOutputID(
            runID: runID, producerCallID: "call-huge", slot: "s")
        let claim = RunOutputFile(
            outputID: outputID, slot: "s", runID: runID,
            taskID: conversationID, environmentID: nil,
            producerCallID: "call-huge", producerTool: "image.generate",
            relativePath: RunOutputFile.canonicalRelativePath(
                runID: runID, outputID: outputID, displayName: "huge.bin"),
            displayName: "huge.bin", mimeType: "application/octet-stream",
            uti: nil, byteCount: 256 * 1024 * 1024 + 1,
            sha256: String(repeating: "a", count: 64), role: .userFile)
        try await appendToolResult(
            runID: runID, tool: "image.generate", callID: "call-huge",
            status: "ok", receipts: [claim])
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "oversize claim")
        let counters = CallCounters()
        let service = makeService(counters: counters)
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: conversationID)
            XCTFail("over-per-file claims must fail before verification")
        } catch let error as FloeRunFilesError {
            guard case .overLimit = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(counters.verifyCalls, 0)
    }

    func testCancellationDuringVerificationReturnsNoPartialList() async throws {
        try await seedConversation(conversationID)
        var receipts: [RunOutputFile] = []
        for index in 0..<3 {
            let receipt = try publishCanonicalSnapshot(
                runID: runID, conversationID: conversationID,
                callID: "call-\(index)", tool: "network.download",
                slot: "s\(index)", displayName: "file\(index).bin")
            receipts.append(receipt)
        }
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        for receipt in receipts {
            try await appendToolResult(
                runID: runID, tool: "network.download",
                callID: receipt.producerCallID, status: "ok", receipts: [receipt])
        }
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "downloaded")
        let counters = CallCounters()
        let root = artifactRoot!
        let service = makeService(counters: counters, verifyOverride: { receipt in
            // Cancel the TASK EXECUTING the projection (the verifier closure
            // runs inside the service task): there is no static
            // `Task.cancel()` API — the current task handle cancels. The
            // loop must observe this at the NEXT boundary and return no
            // partial list.
            withUnsafeCurrentTask { $0?.cancel() }
            return RunOutputSnapshotStore.verify(receipt, artifactRoot: root)
        })
        do {
            _ = try await service.fileResult(
                runID: runID, expectedConversationID: conversationID)
            XCTFail("cancelled verification must not return files")
        } catch let error as FloeRunFilesError {
            XCTAssertEqual(error, .verificationCancelled)
        }
        XCTAssertLessThan(counters.verifyCalls, 3,
            "the loop must stop at the cancellation boundary")
    }

    func testCapabilityDisabledStillRefusesBeforeAnyRead() async throws {
        try await seedConversation(conversationID)
        try await seedRun(conversationID: conversationID, runID: runID,
                      state: "completed", withTerminalProof: "done")
        let counters = CallCounters()
        let service = makeService(
            counters: counters, capabilityEnabled: { false })
        await XCTAssertThrowsErrorAsync {
            try await service.fileResult(
                runID: runID, expectedConversationID: conversationID)
        }
        XCTAssertEqual(counters.manifestCalls, 0)
    }

    // MARK: - Restart without provider: the read path only needs durable storage

    func testProjectionReadsAfterFreshStoresWithoutAnyProvider() async throws {
        // The service above already has `defaultModel: { nil }` and a
        // throwing start dep: file reads succeed with zero provider/model
        // capability — the durable-only read split inherited from C.
        try await seedConversation(conversationID)
        let receipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-doc", tool: "document.convert")
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        try await appendToolResult(
            runID: runID, tool: "document.convert", callID: "call-doc",
            status: "ok", receipts: [receipt])
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "converted")
        // Fresh service instance over the SAME stores — a new "process".
        let counters = CallCounters()
        let restarted = makeService(counters: counters)
        let result = try await restarted.fileResult(
            runID: runID, expectedConversationID: conversationID)
        XCTAssertEqual(result.files.count, 1)
    }

    // MARK: - Hosted GetFloeRunFilesIntent.perform

    #if canImport(AppIntents) && DEBUG
    private func entity(conversationID: UUID = UUID(uuidString: "5C5C5C5C-0000-4000-8000-00000000F001")!) -> FloeShortcutRunEntity {
        FloeShortcutRunEntity(
            runID: runID, conversationID: conversationID,
            title: "Synthetic files task", state: .running,
            isFinished: false, isSuccessful: false, requiresUserAction: false)
    }

    @MainActor
    func testHostedFilesIntentReturnsVerifiedTypedFilesWithFalseRemovedOnCompletion() async throws {
        try await seedConversation(conversationID)
        let receipt = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-doc", tool: "document.convert")
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        try await appendToolResult(
            runID: runID, tool: "document.convert", callID: "call-doc",
            status: "ok", receipts: [receipt])
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "converted")
        let counters = CallCounters()
        let service = makeService(counters: counters)
        var intent = GetFloeRunFilesIntent()
        intent.run = entity()
        intent.includePartial = false
        let result = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
            try await intent.perform()
        }
        let files = try XCTUnwrap(result.value)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.filename, "report.docx")
        XCTAssertEqual(file.type, UTType(
            "org.openxmlformats.wordprocessingml.document"))
        XCTAssertFalse(file.removedOnCompletion,
            "durable run snapshots must never be removed on shortcut completion")
        let delivered = try XCTUnwrap(file.fileURL)
        XCTAssertEqual(FloeDigest.sha256Hex(Data(try Data(contentsOf: delivered))), receipt.sha256)
    }

    @MainActor
    func testHostedFilesIntentFallsBackToMIMEThenPlainDataForTyping() async throws {
        try await seedConversation(conversationID)
        let mimeOnly = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-mime", tool: "network.download", slot: "a",
            displayName: "page.html", uti: nil, mimeType: "text/html")
        let unusable = try publishCanonicalSnapshot(
            runID: runID, conversationID: conversationID,
            callID: "call-bad", tool: "network.download", slot: "b",
            displayName: "blob.bin", uti: "///not-a-uti///",
            mimeType: "not a mime")
        try await seedRunShell(conversationID: conversationID, runID: runID, state: "completed", ended: true)
        try await appendToolResult(
            runID: runID, tool: "network.download", callID: "call-mime",
            status: "ok", receipts: [mimeOnly])
        try await appendToolResult(
            runID: runID, tool: "network.download", callID: "call-bad",
            status: "ok", receipts: [unusable])
        try await appendTerminalProof(
            runID: runID, conversationID: conversationID, answer: "ok")
        let counters = CallCounters()
        let service = makeService(counters: counters)
        var intent = GetFloeRunFilesIntent()
        intent.run = entity()
        let result = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
            try await intent.perform()
        }
        let files = try XCTUnwrap(result.value)
        XCTAssertEqual(files.count, 2)
        let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.filename, $0) })
        XCTAssertEqual(byName["page.html"]?.type, .html)
        XCTAssertEqual(byName["blob.bin"]?.type, .data)
    }

    @MainActor
    func testHostedFilesIntentErrorCopyIsLocalizedAndConcise() async throws {
        try await seedConversation(conversationID)
        try await runs.saveRun(.init(
            id: runID, conversationID: conversationID, state: "streamingModel",
            goal: "Active", startedAt: Date(), endedAt: nil))
        let counters = CallCounters()
        let service = makeService(counters: counters)
        var intent = GetFloeRunFilesIntent()
        intent.run = entity()
        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await intent.perform()
            }
            XCTFail("active run default policy must throw")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message,
                FloeL10n.l("shortcuts.run.error.files.not_ready"))
            XCTAssertFalse(error.message.contains("RunOutputManifestRow"))
            XCTAssertFalse(error.message.contains("sha256"))
        }
        // Forged owner.
        var forged = intent
        forged.run = entity(conversationID: otherConversationID)
        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await forged.perform()
            }
            XCTFail("forged entity must throw")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.ownership"))
        }
        // Malformed entity id is rejected by the shared identifier fence.
        var malformed = intent
        malformed.run = entity(conversationID: UUID())
        malformed.run.conversationID = ""
        do {
            _ = try await FloeShortcutRunIntentBridge.$debugService.withValue(service) {
                try await malformed.perform()
            }
            XCTFail("empty task identifier must be rejected")
        } catch let error as FloeShortcutActionError {
            XCTAssertEqual(error.message, FloeL10n.l("shortcuts.run.error.invalid_id"))
        }
    }

    // MARK: - SDK compatibility metadata (openAppWhenRun → supportedModes)

    @MainActor
    func testAllRunActionsDeclareBackgroundSupportedModes() {
        // Metadata-only migration from the deprecated openAppWhenRun; the
        // background-only semantics are unchanged. This does NOT claim any
        // real system automation trigger works — that stays device work.
        XCTAssertEqual(StartFloeRunIntent.supportedModes, .background)
        XCTAssertEqual(GetFloeRunStatusIntent.supportedModes, .background)
        XCTAssertEqual(WaitForFloeRunIntent.supportedModes, .background)
        XCTAssertEqual(GetFloeRunTextIntent.supportedModes, .background)
        XCTAssertEqual(CancelFloeRunIntent.supportedModes, .background)
        XCTAssertEqual(GetFloeRunFilesIntent.supportedModes, .background)
    }
    #endif

    // MARK: - Production factory wiring (isolated environment)

    #if canImport(UIKit) && DEBUG
    @MainActor
    func testProductionFactoryReadsRealManifestAndReportsMissingSnapshot() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        environment.markIsolatedLaunchReadyForTesting()
        let conversation = UUID()
        let run = UUID()
        try await environment.conversationStore.saveConversation(.init(
            id: conversation, title: "Isolated files task",
            createdAt: Date(), updatedAt: Date()))
        try await environment.runStore.saveRun(.init(
            id: run, conversationID: conversation, state: "completed",
            goal: "Isolated files goal", startedAt: Date(), endedAt: Date()))
        // A canonical sealed-shape receipt whose snapshot bytes are NOT at
        // the production artifact root: the wired real reader must find the
        // row and the wired real verifier must report it missing — proving
        // both deps are live in production wiring without writing anything
        // into the shared store.
        let outputID = RunOutputFile.derivedOutputID(
            runID: run, producerCallID: "call-wired", slot: "document")
        let receipt = RunOutputFile(
            outputID: outputID, slot: "document", runID: run,
            taskID: conversation, environmentID: nil,
            producerCallID: "call-wired", producerTool: "document.convert",
            relativePath: RunOutputFile.canonicalRelativePath(
                runID: run, outputID: outputID, displayName: "missing-e2e.docx"),
            displayName: "missing-e2e.docx",
            mimeType: "application/octet-stream", uti: nil,
            byteCount: 4, sha256: FloeDigest.sha256Hex(Data("bytes".utf8)),
            role: .userFile)
        var map: [String: String] = [
            "tool": "document.convert", "id": "call-wired", "status": "ok",
            "summary": "wired", "outputDigest": String(repeating: "0", count: 64),
            "durationMs": "1", "dispatched": "true"
        ]
        map["outputFilesJSON"] = String(
            data: try JSONEncoder().encode([receipt]), encoding: .utf8)!
        _ = try await environment.runStore.appendEvent(
            runID: run, kind: .toolResult,
            payloadJSON: String(data: try JSONEncoder().encode(map), encoding: .utf8)!)
        // Durable completion proof AFTER the tool event (production order)
        // so the default complete-success policy reaches verification.
        let proofMessageID = UUID()
        try await environment.conversationStore.appendMessage(.init(
            id: proofMessageID, conversationID: conversation, role: "assistant",
            content: "wired", createdAt: Date(), runID: run))
        _ = try await environment.runStore.appendEvent(
            runID: run, kind: .assistantText, payloadJSON: "{\"text\":\"wired\"}")
        _ = try await environment.runStore.appendEvent(
            runID: run, kind: .terminal,
            payloadJSON: "{\"stopReason\":\"endTurn\",\"finalMessageID\":\"\(proofMessageID.uuidString)\"}")
        let service = environment.floeShortcutRunService()
        do {
            _ = try await service.fileResult(runID: run, expectedConversationID: conversation)
            XCTFail("real wiring must surface the missing snapshot honestly")
        } catch let error as FloeRunFilesError {
            guard case .fileMissing(let name) = error else {
                return XCTFail("expected fileMissing via production wiring, got \(error)")
            }
            XCTAssertEqual(name, "missing-e2e.docx")
        }
    }
    #endif
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    isolation: isolated (any Actor)? = #isolation,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        // expected
    }
}
