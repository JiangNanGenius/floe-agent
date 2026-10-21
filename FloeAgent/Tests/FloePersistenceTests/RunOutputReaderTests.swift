// S3-D focused tests for the exact-run durable output projection.
//
// These seed REAL SQLite rows through the production stores (`DatabaseManager`
// in-memory + `SQLiteRunStore.appendEvent`) with payload maps encoded by
// `JSONEncoder` — never hand-concatenated JSON. They are isolated reader
// guard tests: the end-to-end runtime→producer→persistence→Intent proof is a
// separate App-hosted concern. The bounds that guard allocation are shrunk
// per-instance only inside these tests; production defaults stay untouched.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence

@Suite("FloePersistence.RunOutputReader")
struct RunOutputReaderTests {

    // MARK: - Helpers

    private struct World {
        var database: DatabaseManager
        var conversations: SQLiteConversationStore
        var runs: SQLiteRunStore
        var conversationID: UUID
        var runID: UUID
    }

    private func makeWorld() async throws -> World {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let conversations = SQLiteConversationStore(database: database)
        let runs = SQLiteRunStore(database: database)
        let conversationID = UUID()
        try await conversations.saveConversation(.init(
            id: conversationID, title: "Synthetic output owner",
            createdAt: Date(), updatedAt: Date()
        ))
        let runID = UUID()
        try await runs.saveRun(.init(
            id: runID, conversationID: conversationID, state: "completed",
            goal: "Synthetic output goal", startedAt: Date(), endedAt: Date()
        ))
        return World(database: database, conversations: conversations,
                     runs: runs, conversationID: conversationID, runID: runID)
    }

    private func sealedReceipt(
        runID: UUID,
        taskID: UUID?,
        callID: String,
        tool: String,
        slot: String = "document",
        displayName: String = "report.docx",
        byteCount: Int = 123,
        outputIDOverride: String? = nil,
        pathOverride: String? = nil,
        digestOverride: String? = nil
    ) -> RunOutputFile {
        let digest = digestOverride
            ?? FloeDigest.sha256Hex(Data("\(slot)-\(displayName)".utf8))
        let outputID = outputIDOverride
            ?? RunOutputFile.derivedOutputID(runID: runID, producerCallID: callID, slot: slot)
        let path = pathOverride
            ?? RunOutputFile.canonicalRelativePath(runID: runID, outputID: outputID, displayName: displayName)
        return RunOutputFile(
            outputID: outputID,
            slot: slot,
            runID: runID,
            taskID: taskID,
            environmentID: "env-test",
            producerCallID: callID,
            producerTool: tool,
            relativePath: path,
            displayName: displayName,
            mimeType: "application/octet-stream",
            uti: nil,
            byteCount: byteCount,
            sha256: digest,
            role: .userFile
        )
    }

    private func toolResultPayload(
        tool: String,
        id: String,
        status: String,
        receipts: [RunOutputFile]? = nil,
        summary: String = "bounded summary",
        extra: [String: String] = [:]
    ) throws -> String {
        var map: [String: String] = [
            "tool": tool,
            "id": id,
            "status": status,
            "summary": summary,
            "outputDigest": String(repeating: "0", count: 64),
            "durationMs": "10",
            "dispatched": "true"
        ]
        for (key, value) in extra { map[key] = value }
        if let receipts {
            map["outputFilesJSON"] = String(
                data: try JSONEncoder().encode(receipts), encoding: .utf8
            )!
        }
        // Canonical durable string-map shape, encoded exactly like the
        // runtime writes it.
        return String(data: try JSONEncoder().encode(map), encoding: .utf8)!
    }

    private func failureKind(_ error: any Error) -> String {
        guard let failure = error as? RunOutputManifestFailure else {
            return "other:\(error)"
        }
        switch failure {
        case .manifestRowOverflow: return "manifestRowOverflow"
        case .payloadOverLimit: return "payloadOverLimit"
        case .corruptOuterPayload: return "corruptOuterPayload"
        case .corruptManifestJSON: return "corruptManifestJSON"
        case .invalidReceipt: return "invalidReceipt"
        case .foreignBinding: return "foreignBinding"
        case .enclosingMismatch: return "enclosingMismatch"
        case .duplicateConflict: return "duplicateConflict"
        }
    }

    // MARK: - Exact-run binding

    @Test("An early receipt survives a long event tail")
    func earlyOutputBeyondTerminalTail() async throws {
        let world = try await makeWorld()
        let callID = "call-early"
        let receipt = sealedReceipt(
            runID: world.runID, taskID: world.conversationID,
            callID: callID, tool: "document.convert"
        )
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: toolResultPayload(
                tool: "document.convert", id: callID, status: "ok", receipts: [receipt]
            )
        )
        // 200 later ordinary tool results push the receipt far below the
        // 24×4=96-event terminal tail the C status scan reads.
        for index in 0..<200 {
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "exec.shell", id: "call-\(index)", status: "ok"
                )
            )
        }
        let reader = SQLiteRunOutputReader(database: world.database)
        let rows = try await reader.manifestRows(
            runID: world.runID, expectedConversationID: world.conversationID
        )
        #expect(rows.count == 1)
        #expect(rows.first?.sequence == 1)
        #expect(rows.first?.receipts == [receipt])
        let totalEvents = try await world.runs.events(runID: world.runID)
        #expect(totalEvents.count > 96, "the receipt must sit below the old tail bound")
    }

    @Test("A different run or a foreign conversation never leaks receipts")
    func exactRunAndConversationIsolation() async throws {
        let world = try await makeWorld()
        let otherRun = UUID()
        try await world.runs.saveRun(.init(
            id: otherRun, conversationID: world.conversationID, state: "completed",
            goal: "Later run", startedAt: Date(), endedAt: Date()
        ))
        let receiptA = sealedReceipt(
            runID: world.runID, taskID: world.conversationID,
            callID: "call-a", tool: "image.generate"
        )
        let receiptB = sealedReceipt(
            runID: otherRun, taskID: world.conversationID,
            callID: "call-b", tool: "image.generate"
        )
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: toolResultPayload(
                tool: "image.generate", id: "call-a", status: "ok", receipts: [receiptA])
        )
        _ = try await world.runs.appendEvent(
            runID: otherRun, kind: .toolResult,
            payloadJSON: toolResultPayload(
                tool: "image.generate", id: "call-b", status: "ok", receipts: [receiptB])
        )
        let reader = SQLiteRunOutputReader(database: world.database)
        let own = try await reader.manifestRows(
            runID: world.runID, expectedConversationID: world.conversationID)
        #expect(own.flatMap(\.receipts) == [receiptA])
        let later = try await reader.manifestRows(
            runID: otherRun, expectedConversationID: world.conversationID)
        #expect(later.flatMap(\.receipts) == [receiptB])
        // A foreign expected conversation yields nothing at all: the SQL
        // binds both IDs, so no result and no later filesystem verification.
        let foreign = try await reader.manifestRows(
            runID: world.runID, expectedConversationID: UUID())
        #expect(foreign.isEmpty)
        let missing = try await reader.manifestRows(
            runID: UUID(), expectedConversationID: world.conversationID)
        #expect(missing.isEmpty)
    }

    // MARK: - Prose vs manifest

    @Test("A payload that only quotes the key in prose is a no-output row")
    func proseQuoteIsNotAManifest() async throws {
        let world = try await makeWorld()
        // The redacted summary literally contains "outputFilesJSON"; the
        // map itself has no such key. The probe matches, the strict parse
        // does not, and the row is an ordinary legacy no-output row.
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: toolResultPayload(
                tool: "exec.shell", id: "call-prose", status: "ok",
                summary: "The tool echoed \"outputFilesJSON\" while explaining itself."
            )
        )
        let reader = SQLiteRunOutputReader(database: world.database)
        let rows = try await reader.manifestRows(
            runID: world.runID, expectedConversationID: world.conversationID)
        #expect(rows.isEmpty)
    }

    @Test("Legacy rows without the key are simply skipped")
    func legacyRowsSkipped() async throws {
        let world = try await makeWorld()
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: toolResultPayload(tool: "exec.shell", id: "c1", status: "ok")
        )
        let receipt = sealedReceipt(
            runID: world.runID, taskID: world.conversationID,
            callID: "c2", tool: "image.generate"
        )
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: toolResultPayload(
                tool: "image.generate", id: "c2", status: "ok", receipts: [receipt])
        )
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: toolResultPayload(tool: "exec.shell", id: "c3", status: "failed")
        )
        let reader = SQLiteRunOutputReader(database: world.database)
        let rows = try await reader.manifestRows(
            runID: world.runID, expectedConversationID: world.conversationID)
        #expect(rows.count == 1)
        #expect(rows.first?.sequence == 2)
    }

    @Test("Invalid outer JSON claiming the key fails precisely")
    func corruptOuterPayloadFails() async throws {
        let world = try await makeWorld()
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: "{not-json \"outputFilesJSON\" trailing"
        )
        let reader = SQLiteRunOutputReader(database: world.database)
        await #expect(throws: RunOutputManifestFailure.corruptOuterPayload(sequence: 1)) {
            _ = try await reader.manifestRows(
                runID: world.runID, expectedConversationID: world.conversationID)
        }
    }

    @Test("A present member that is not a string is a damaged outer payload")
    func nonStringMemberFails() async throws {
        let world = try await makeWorld()
        let receipt = sealedReceipt(
            runID: world.runID, taskID: world.conversationID,
            callID: "call-42", tool: "image.generate"
        )
        let manifestString = String(
            data: try JSONEncoder().encode([receipt]), encoding: .utf8)!
        // Durable rows are [String: String]. A NUMBER `id` means the outer
        // payload is not the durable map shape, even though the text is
        // valid JSON. Built with JSONSerialization so the mixed shape is
        // produced by a real serializer, not hand-concatenated quotes.
        let raw = try JSONSerialization.data(
            withJSONObject: [
                "tool": "image.generate",
                "id": 42,
                "status": "ok",
                "outputFilesJSON": manifestString,
                "summary": "ok"
            ],
            options: [.sortedKeys]
        )
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: String(data: raw, encoding: .utf8)!
        )
        let reader = SQLiteRunOutputReader(database: world.database)
        await #expect(throws: RunOutputManifestFailure.corruptOuterPayload(sequence: 1)) {
            _ = try await reader.manifestRows(
                runID: world.runID, expectedConversationID: world.conversationID)
        }
    }

    @Test("A corrupt nested manifest string fails precisely")
    func corruptNestedManifestFails() async throws {
        let world = try await makeWorld()
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: toolResultPayload(
                tool: "image.generate", id: "call-x", status: "ok",
                extra: ["outputFilesJSON": "[{\"broken\":"]
            )
        )
        let reader = SQLiteRunOutputReader(database: world.database)
        await #expect(throws: RunOutputManifestFailure.corruptManifestJSON(sequence: 1)) {
            _ = try await reader.manifestRows(
                runID: world.runID, expectedConversationID: world.conversationID)
        }
    }

    @Test("Only toolResult rows are scanned")
    func otherKindsAreIgnored() async throws {
        let world = try await makeWorld()
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .file,
            payloadJSON: toolResultPayload(
                tool: "image.generate", id: "call-file", status: "ok",
                extra: ["outputFilesJSON": "[]"]
            )
        )
        let reader = SQLiteRunOutputReader(database: world.database)
        let rows = try await reader.manifestRows(
            runID: world.runID, expectedConversationID: world.conversationID)
        #expect(rows.isEmpty)
    }

    // MARK: - Receipt validation

    @Test("Forged or unbound receipts fail with the exact cause")
    func receiptValidationFailsPrecisely() async throws {
        // Non-canonical path: points at another namespace.
        do {
            let world = try await makeWorld()
            let forged = sealedReceipt(
                runID: world.runID, taskID: world.conversationID,
                callID: "c", tool: "t", pathOverride: "GeneratedImages/whatever.png"
            )
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "t", id: "c", status: "ok", receipts: [forged])
            )
            let reader = SQLiteRunOutputReader(database: world.database)
            do {
                _ = try await reader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("non-canonical path must fail")
            } catch {
                #expect(failureKind(error) == "invalidReceipt")
            }
        }
        // Identity that does not re-derive from run+call+slot.
        do {
            let world = try await makeWorld()
            let wrongID = String(repeating: "f", count: 64)
            let forged = sealedReceipt(
                runID: world.runID, taskID: world.conversationID,
                callID: "c", tool: "t",
                outputIDOverride: wrongID,
                pathOverride: RunOutputFile.canonicalRelativePath(
                    runID: world.runID, outputID: wrongID, displayName: "report.docx")
            )
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "t", id: "c", status: "ok", receipts: [forged])
            )
            let reader = SQLiteRunOutputReader(database: world.database)
            do {
                _ = try await reader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("re-derived identity must be enforced")
            } catch {
                #expect(failureKind(error) == "invalidReceipt")
            }
        }
        // A receipt naming another run. It is canonical and identity-
        // consistent for ITS run; only the exact-run binding rejects it.
        do {
            let world = try await makeWorld()
            let foreign = sealedReceipt(
                runID: UUID(), taskID: world.conversationID,
                callID: "c", tool: "t"
            )
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "t", id: "c", status: "ok", receipts: [foreign])
            )
            let reader = SQLiteRunOutputReader(database: world.database)
            do {
                _ = try await reader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("another run's receipt must fail")
            } catch {
                #expect(failureKind(error) == "foreignBinding")
            }
        }
        // Unbound (nil) taskID: a real publisher never produces one; a
        // manifest without a task binding is rejected, never "probably mine".
        do {
            let world = try await makeWorld()
            let unbound = sealedReceipt(
                runID: world.runID, taskID: nil, callID: "c", tool: "t"
            )
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "t", id: "c", status: "ok", receipts: [unbound])
            )
            let reader = SQLiteRunOutputReader(database: world.database)
            do {
                _ = try await reader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("unbound task binding must fail")
            } catch {
                #expect(failureKind(error) == "foreignBinding")
            }
        }
        // Wrong taskID.
        do {
            let world = try await makeWorld()
            let forged = sealedReceipt(
                runID: world.runID, taskID: UUID(), callID: "c", tool: "t"
            )
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "t", id: "c", status: "ok", receipts: [forged])
            )
            let reader = SQLiteRunOutputReader(database: world.database)
            do {
                _ = try await reader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("foreign task must fail")
            } catch {
                #expect(failureKind(error) == "foreignBinding")
            }
        }
        // Uppercase digest is not the sealed lowercase 64-hex shape.
        do {
            let world = try await makeWorld()
            let forged = sealedReceipt(
                runID: world.runID, taskID: world.conversationID,
                callID: "c", tool: "t",
                digestOverride: String(repeating: "A", count: 64)
            )
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "t", id: "c", status: "ok", receipts: [forged])
            )
            let reader = SQLiteRunOutputReader(database: world.database)
            do {
                _ = try await reader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("uppercase digest must fail")
            } catch {
                #expect(failureKind(error) == "invalidReceipt")
            }
        }
    }

    @Test("Enclosing call identity must match the sealed producer")
    func enclosingMismatchFails() async throws {
        // Different persisted call id.
        do {
            let world = try await makeWorld()
            let receipt = sealedReceipt(
                runID: world.runID, taskID: world.conversationID,
                callID: "real-call", tool: "document.convert"
            )
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "document.convert", id: "other-call", status: "ok",
                    receipts: [receipt]
                )
            )
            let reader = SQLiteRunOutputReader(database: world.database)
            do {
                _ = try await reader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("manifest on a foreign recorded call must fail")
            } catch {
                #expect(failureKind(error) == "enclosingMismatch")
            }
        }
        // Different persisted tool name.
        do {
            let world = try await makeWorld()
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "exec.shell", id: "real-call", status: "ok",
                    receipts: [sealedReceipt(
                        runID: world.runID, taskID: world.conversationID,
                        callID: "real-call", tool: "document.convert"
                    )]
                )
            )
            let reader = SQLiteRunOutputReader(database: world.database)
            do {
                _ = try await reader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("manifest under a different tool name must fail")
            } catch {
                #expect(failureKind(error) == "enclosingMismatch")
            }
        }
    }

    @Test("Metadata-equal duplicates are idempotent; conflicts fail")
    func duplicates() async throws {
        let world = try await makeWorld()
        let receipt = sealedReceipt(
            runID: world.runID, taskID: world.conversationID,
            callID: "call-dup", tool: "image.generate"
        )
        let payload = try toolResultPayload(
            tool: "image.generate", id: "call-dup", status: "ok", receipts: [receipt]
        )
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult, payloadJSON: payload)
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult, payloadJSON: payload)
        let reader = SQLiteRunOutputReader(database: world.database)
        let rows = try await reader.manifestRows(
            runID: world.runID, expectedConversationID: world.conversationID)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.receipts == [receipt] })

        // Same outputID, different metadata → conflict, never an overwrite.
        let conflicting = sealedReceipt(
            runID: world.runID, taskID: world.conversationID,
            callID: "call-dup", tool: "image.generate", byteCount: 999_999
        )
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult,
            payloadJSON: toolResultPayload(
                tool: "image.generate", id: "call-dup", status: "ok",
                receipts: [conflicting]
            )
        )
        do {
            _ = try await reader.manifestRows(
                runID: world.runID, expectedConversationID: world.conversationID)
            Issue.record("conflicting duplicate must fail")
        } catch {
            #expect(failureKind(error) == "duplicateConflict")
        }
    }

    // MARK: - Bounds (per-instance shrinks; production defaults unchanged)

    @Test("Manifest row count overflow is explicit")
    func rowBoundOverflow() async throws {
        let world = try await makeWorld()
        for index in 0..<3 {
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "image.generate", id: "call-\(index)", status: "ok",
                    receipts: [sealedReceipt(
                        runID: world.runID, taskID: world.conversationID,
                        callID: "call-\(index)", tool: "image.generate",
                        slot: "slot-\(index)"
                    )]
                )
            )
        }
        let reader = SQLiteRunOutputReader(database: world.database, rowBound: 2)
        await #expect(throws: RunOutputManifestFailure.manifestRowOverflow(bound: 2)) {
            _ = try await reader.manifestRows(
                runID: world.runID, expectedConversationID: world.conversationID)
        }
    }

    @Test("Serialized byte bounds fail before any payload text is fetched")
    func payloadByteBounds() async throws {
        let padding = String(repeating: "x", count: 400)
        do {
            let world = try await makeWorld()
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult,
                payloadJSON: toolResultPayload(
                    tool: "image.generate", id: "call-big", status: "ok",
                    receipts: [sealedReceipt(
                        runID: world.runID, taskID: world.conversationID,
                        callID: "call-big", tool: "image.generate"
                    )],
                    summary: padding
                )
            )
            let perRowReader = SQLiteRunOutputReader(
                database: world.database, rowMaxBytes: 200
            )
            do {
                _ = try await perRowReader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("oversized single row must fail")
            } catch {
                #expect(failureKind(error) == "payloadOverLimit")
            }
        }
        do {
            let world = try await makeWorld()
            let payload = try toolResultPayload(
                tool: "image.generate", id: "call-a", status: "ok",
                receipts: [sealedReceipt(
                    runID: world.runID, taskID: world.conversationID,
                    callID: "call-a", tool: "image.generate"
                )],
                summary: padding
            )
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult, payloadJSON: payload)
            _ = try await world.runs.appendEvent(
                runID: world.runID, kind: .toolResult, payloadJSON: payload)
            let totalReader = SQLiteRunOutputReader(
                database: world.database, rowMaxBytes: 700, totalMaxBytes: 600
            )
            do {
                _ = try await totalReader.manifestRows(
                    runID: world.runID, expectedConversationID: world.conversationID)
                Issue.record("oversized projection total must fail")
            } catch {
                #expect(failureKind(error) == "payloadOverLimit")
            }
        }
    }

    @Test("Serialized bounds count UTF-8 BYTES, not characters (nonASCII payloads)")
    func payloadByteBoundsUseUTF8Bytes() async throws {
        // A manifest row whose summary is pure nonASCII text: its SQLite
        // CHARACTER length is smaller than its serialized UTF-8 byte size.
        // A bound equal to the character count must therefore still fail —
        // `length(payload_json)` counting characters would wrongly pass.
        let world = try await makeWorld()
        let cjk = String(repeating: "文档输出结果", count: 50) // 300 chars, 900 UTF-8 bytes
        let receipt = sealedReceipt(
            runID: world.runID, taskID: world.conversationID,
            callID: "call-cjk", tool: "document.convert"
        )
        let payload = try toolResultPayload(
            tool: "document.convert", id: "call-cjk", status: "ok",
            receipts: [receipt], summary: cjk
        )
        _ = try await world.runs.appendEvent(
            runID: world.runID, kind: .toolResult, payloadJSON: payload
        )
        // The persisted payload really is multi-byte: character length and
        // UTF-8 length must differ for this test to prove anything.
        #expect(payload.count < payload.utf8.count)
        let reader = SQLiteRunOutputReader(
            database: world.database, rowMaxBytes: payload.count
        )
        do {
            _ = try await reader.manifestRows(
                runID: world.runID, expectedConversationID: world.conversationID)
            Issue.record("the UTF-8 byte size exceeds the bound; character counting must not pass")
        } catch {
            #expect(failureKind(error) == "payloadOverLimit")
        }
        // Sanity: the same row fits a bound at its true byte size.
        let fitting = SQLiteRunOutputReader(
            database: world.database, rowMaxBytes: payload.utf8.count
        )
        let rows = try await fitting.manifestRows(
            runID: world.runID, expectedConversationID: world.conversationID)
        #expect(rows.count == 1)
        #expect(rows.first?.receipts == [receipt])
    }
}
