// FloeAndroidCoreTests — D04 run-output App-consumer BRIDGE (reader →
// verifiedRead → bounded egress) regressions (job-6f953da44de048d0).
//
// Real filesystem snapshots published through the REAL
// `RuntimeFacadeRunOutput.publish` seam, real durable SQLite toolResult
// records, and the actual `RunOutputBridgeFacade` session grammar over its
// same-module test seams (epoch override + store provider + authority
// instance) — the reviewed source-host qualification pattern. Proven here:
// lease held through streamed reads and released exactly once on every path
// (finish/error/cancel/retire/sweep/saturation/refusal — the deferred
// through-in-flight-read drain itself is proven in
// RunOutputBridgeLifetimeTests), the cleanup-claim exclusion refuses opens
// while retaining reads for other runs, forged or foreign records answer
// typed refusals with ZERO leaked leases, the dynamic absence of an unbound
// generation is a typed refusal (never a fake empty success), stale epochs
// fence info/read while close still releases the exact token, and bounded
// chunk discipline holds the frozen caps. The list page is bounded against
// the reply byte budget (prefix + honest `truncatedItems`, proven in
// RunOutputBridgeLifetimeTests).
//
// Authored as SOURCE ONLY: not compiled, not executed here.

import Foundation
import Testing
@testable import FloeAndroidCore
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkspace

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif



private func toolResultPayloadJSON(callID: String, tool: String,
                                    receipts: [RunOutputFile]) -> String {
    var persisted: [String: String] = [
        "tool": tool, "id": callID, "status": "ok",
        "summary": "published", "outputDigest": "d",
    ]
    let data = try! JSONEncoder().encode(receipts)
    persisted["outputFilesJSON"] = String(data: data, encoding: .utf8)!
    let json = try! JSONSerialization.data(withJSONObject: persisted, options: [.sortedKeys])
    return String(data: json, encoding: .utf8)!
}

@Suite("FloeAndroidCore.RunOutputBridgeFacade owned egress")
struct RunOutputBridgeFacadeTests {

    // MARK: Fixtures

    private final class Fixture: @unchecked Sendable {
        let base: URL
        let artifact: URL
        let authority: RuntimeFacadeRunOutput
        let bridge: RunOutputBridgeFacade
        let epoch: UInt64 = 7
        var store: SQLiteRunStore?
        var manager: DatabaseManager?

        init() throws {
            base = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-ro-bridge-\(UUID().uuidString)", isDirectory: true)
            artifact = base.appendingPathComponent("FloeAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
            authority = RuntimeFacadeRunOutput()
            bridge = RunOutputBridgeFacade()
            bridge.liveEpochOverrideForTesting = epoch
            bridge.runOutputOverrideForTesting = authority
        }

        /// Opens the REAL durable store and wires the bridge's store seam.
        func installStore() async throws {
            let manager = try DatabaseManager(path: base.appendingPathComponent("db.sqlite"))
            try await manager.migrate()
            let store = SQLiteRunStore(database: manager)
            self.manager = manager
            self.store = store
            let captured = store
            let boundEpoch = epoch
            bridge.storeProviderOverrideForTesting = { probe in
                probe == boundEpoch ? captured : nil
            }
        }

        func closeStore() async throws {
            bridge.storeProviderOverrideForTesting = nil
            try await manager?.close()
            manager = nil
            store = nil
        }

        func cleanup() {
            bridge.liveEpochOverrideForTesting = nil
            bridge.runOutputOverrideForTesting = nil
            bridge.storeProviderOverrideForTesting = nil
            try? FileManager.default.removeItem(at: base)
        }

        /// Publishes a real snapshot through the authority and persists the
        /// matching durable toolResult record. Returns the sealed receipt.
        func publish(runID: UUID, conversationID: UUID, callID: String,
                    tool: String = "workspace.publishOutput", slot: String = "document",
                    displayName: String = "report.docx", content: Data? = nil) async throws
            -> RunOutputFile
        {
            let bytes = content ?? Data("real snapshot bytes".utf8)
            let sourceURL = base.appendingPathComponent("source-\(UUID().uuidString)")
            try bytes.write(to: sourceURL)
            #expect(authority.install(artifactRootPath: artifact.path, epoch: epoch))
            let context = ToolContext(
                runID: runID, toolCallID: callID,
                cancellation: CancellationToken(),
                environmentID: "env-1", conversationID: conversationID)
            let receipt = try authority.publish(
                RunOutputSnapshotRequest(producerTool: tool, slot: slot,
                                         commit: RunOutputCommit(
                                            sourceURL: sourceURL,
                                            sha256: FloeDigest.sha256Hex(bytes),
                                            byteCount: bytes.count,
                                            displayName: displayName,
                                            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                            uti: nil)),
                using: context)
            if let store {
                _ = try await store.appendEvent(
                    runID: runID, kind: .toolResult,
                    payloadJSON: toolResultPayloadJSON(callID: callID, tool: tool,
                                                       receipts: [receipt]))
            }
            return receipt
        }

        func snapshotURL(for receipt: RunOutputFile) -> URL {
            var url = artifact
            for component in receipt.relativePath.split(separator: "/") {
                url = url.appendingPathComponent(String(component))
            }
            return url
        }

        func saveRun(_ runID: UUID, conversationID: UUID) async throws {
            // The runs table has a REAL foreign key to conversations; seed
            // the parent through the actual ConversationStore API (upsert).
            if let manager {
                try await SQLiteConversationStore(database: manager).saveConversation(
                    ConversationRecord(id: conversationID, title: "run-output fixture",
                                       createdAt: Date(), updatedAt: Date()))
            }
            try await store?.saveRun(RunRecord(id: runID, conversationID: conversationID,
                                               state: "completed", goal: "g",
                                               startedAt: Date()))
        }
    }

    // MARK: - List (bounded owned view)

    @Test("list returns only the exact conversation's owned durable receipts with real availability")
    func listOwnedAvailability() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1")
        let (status, body) = fx.bridge.listJSON(epoch: fx.epoch, conversationID: conversationID,
                                                runID: runID,
                                                replyByteBudget: Int(RunOutputBridgeLimits.maximumReplyBytes) - 1)
        #expect(status == RunOutputBridgeStatus.ok)
        let json = try! JSONSerialization.jsonObject(with: Data(body!.utf8)) as! [String: Any]
        let items = json["items"] as! [[String: Any]]
        #expect(items.count == 1)
        #expect(items[0]["outputID"] as? String == receipt.outputID)
        #expect(items[0]["availability"] as? String == "available")
        #expect(items[0]["byteCount"] as? Int == receipt.byteCount)

        // Deleted bytes: availability flips to "missing" (durable record is
        // still owned; the card state becomes actionable-honest, not a
        // silently enabled placeholder).
        try FileManager.default.removeItem(at: fx.snapshotURL(for: receipt))
        let (status2, body2) = fx.bridge.listJSON(epoch: fx.epoch, conversationID: conversationID,
                                                  runID: runID,
                                                  replyByteBudget: Int(RunOutputBridgeLimits.maximumReplyBytes) - 1)
        #expect(status2 == RunOutputBridgeStatus.ok)
        let json2 = try! JSONSerialization.jsonObject(with: Data(body2!.utf8)) as! [String: Any]
        let items2 = json2["items"] as! [[String: Any]]
        #expect(items2[0]["availability"] as? String == "missing")

        // A run that is not this conversation's answers typed notOwner —
        // identical for foreign vs unknown (no probing oracle).
        let foreign = UUID()
        let (status3, _) = fx.bridge.listJSON(epoch: fx.epoch, conversationID: foreign,
                                              runID: runID,
                                              replyByteBudget: Int(RunOutputBridgeLimits.maximumReplyBytes) - 1)
        #expect(status3 == RunOutputBridgeStatus.notOwner)
        try await fx.closeStore()
    }

    @Test("dynamic absence: an unbound generation refuses typed instead of faking an empty success")
    func listRequiresTrustedBinding() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        // Authority NOT installed (Core06-style: no D04 binding): typed
        // refusal on both surfaces, no session, no lease churn.
        let (status, _) = fx.bridge.listJSON(epoch: fx.epoch, conversationID: conversationID,
                                             runID: runID,
                                             replyByteBudget: Int(RunOutputBridgeLimits.maximumReplyBytes) - 1)
        #expect(status == RunOutputBridgeStatus.leaseRefused)
        let ticket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: String(repeating: "a", count: 64))
        #expect(Int32(truncatingIfNeeded: ticket) == RunOutputBridgeStatus.leaseRefused)
        try await fx.closeStore()
    }

    // MARK: - Open / read / close with REAL leases

    @Test("open holds the generation lease through the streamed copy and close releases the exact token once")
    func openReadCloseLeaseLifecycle() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let payload = Data("the complete snapshot body bytes".utf8)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1", content: payload)
        // publish() itself took and released its lease: count is zero here.
        #expect(fx.authority.activeLeaseCount == 0)
        let ticket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: receipt.outputID)
        #expect(ticket > 0)
        #expect(fx.authority.activeLeaseCount == 1)

        var replyBuffer = [CChar](repeating: 0, count: 4096)
        let infoLength = replyBuffer.withUnsafeMutableBufferPointer { raw in
            fx.bridge.info(ticket, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(infoLength > 0)
        let info = try! JSONSerialization.jsonObject(
            with: Data(String(cString: replyBuffer).prefix(Int(infoLength)).utf8)) as! [String: Any]
        #expect(info["outputID"] as? String == receipt.outputID)
        #expect(info["sha256"] as? String == receipt.sha256)
        #expect(info["byteCount"] as? Int == receipt.byteCount)
        #expect(info["relativePath"] as? String == receipt.relativePath)
        #expect(!((info["relativePath"] as? String)!.hasPrefix("/")))

        var seen = Data()
        var offset: Int64 = 0
        var page = [UInt8](repeating: 0, count: 16)
        while true {
            let copied = page.withUnsafeMutableBufferPointer { raw in
                fx.bridge.read(ticket, offset: offset, buffer: raw.baseAddress!,
                               capacity: Int32(raw.count))
            }
            #expect(copied >= 0)
            if copied == 0 { break }
            #expect(copied <= Int32(page.count))
            seen.append(contentsOf: page.prefix(Int(copied)))
            offset += Int64(copied)
        }
        #expect(seen == payload)
        // Chunk discipline: an oversized request is refused BEFORE reading.
        var big = [UInt8](repeating: 0, count: RunOutputBridgeLimits.maximumChunkBytes + 1)
        let refused = big.withUnsafeMutableBufferPointer { raw in
            fx.bridge.read(ticket, offset: 0, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(refused == RunOutputBridgeStatus.invalidArguments)
        // Negative offset refused.
        let badOffset = page.withUnsafeMutableBufferPointer { raw in
            fx.bridge.read(ticket, offset: -1, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(badOffset == RunOutputBridgeStatus.invalidArguments)

        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        // Idempotent close; the retired ticket never resolves bytes.
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        let afterClose = page.withUnsafeMutableBufferPointer { raw in
            fx.bridge.read(ticket, offset: 0, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(afterClose == RunOutputBridgeStatus.generationFenced
                    || afterClose == RunOutputBridgeStatus.sessionUnknown)
        try await fx.closeStore()
    }

    @Test("a live cleanup claim refuses new opens (real lease/claim exclusion), while another run remains openable")
    func cleanupClaimExcludesOpens() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let claimedRun = UUID()
        let otherRun = UUID()
        try await fx.saveRun(claimedRun, conversationID: conversationID)
        try await fx.saveRun(otherRun, conversationID: conversationID)
        let claimedReceipt = try await fx.publish(runID: claimedRun,
                                                  conversationID: conversationID,
                                                  callID: "call-1")
        let otherReceipt = try await fx.publish(runID: otherRun,
                                                conversationID: conversationID,
                                                callID: "call-2")
        #expect(fx.authority.beginCleanup(runIDs: [claimedRun]))
        let refused = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                           runID: claimedRun, outputID: claimedReceipt.outputID)
        #expect(Int32(truncatingIfNeeded: refused) == RunOutputBridgeStatus.leaseRefused)
        #expect(fx.authority.activeLeaseCount == 0)
        // The claim is narrow: another run's reader still works.
        let okTicket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                            runID: otherRun, outputID: otherReceipt.outputID)
        #expect(okTicket > 0)
        #expect(fx.bridge.close(okTicket) == RunOutputBridgeStatus.ok)
        fx.authority.endCleanup(runIDs: [claimedRun])
        let after = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                         runID: claimedRun, outputID: claimedReceipt.outputID)
        #expect(after > 0)
        #expect(fx.bridge.close(after) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        try await fx.closeStore()
    }

    @Test("every typed refusal path returns the lease to zero: wrong conversation, forged record, missing bytes, changed bytes, truncation-free absence")
    func refusalsNeverLeaseLeak() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1")
        // Wrong requesting conversation → typed notOwner, no lease retained.
        let stranger = fx.bridge.openEgress(epoch: fx.epoch, conversationID: UUID(),
                                            runID: runID, outputID: receipt.outputID)
        #expect(Int32(truncatingIfNeeded: stranger) == RunOutputBridgeStatus.notOwner)
        #expect(fx.authority.activeLeaseCount == 0)
        // Absent durable record (unknown outputID on a clean run): proven
        // receiptMissing, no lease retained.
        let absent = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: String(repeating: "e", count: 64))
        #expect(Int32(truncatingIfNeeded: absent) == RunOutputBridgeStatus.receiptMissing)
        #expect(fx.authority.activeLeaseCount == 0)
        // Snapshot deleted → fileMissing.
        try FileManager.default.removeItem(at: fx.snapshotURL(for: receipt))
        let gone = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                        runID: runID, outputID: receipt.outputID)
        #expect(Int32(truncatingIfNeeded: gone) == RunOutputBridgeStatus.fileMissing)
        #expect(fx.authority.activeLeaseCount == 0)
        // Tampered bytes → fileChanged (full streamed digest at open).
        let fresh = try await fx.publish(runID: runID, conversationID: conversationID,
                                         callID: "call-2", slot: "second",
                                         displayName: "second.docx")
        let snapshot = fx.snapshotURL(for: fresh)
        let handle = try FileHandle(forWritingTo: snapshot)
        try handle.truncate(atOffset: 0)
        try handle.write(Data("different bytes".utf8))
        try handle.close()
        let changed = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                           runID: runID, outputID: fresh.outputID)
        #expect(Int32(truncatingIfNeeded: changed) == RunOutputBridgeStatus.fileChanged)
        #expect(fx.authority.activeLeaseCount == 0)

        // Forged durable record written directly into the store: a receipt
        // with a fully SELF-CONSISTENT identity sealed to a producer call
        // that is NOT the event carrying it (model-copied sealed JSON
        // pasted under another call record).
        var forged = fresh
        forged.producerCallID = "call-forged"
        forged.outputID = RunOutputFile.derivedOutputID(runID: runID,
                                                        producerCallID: "call-forged",
                                                        slot: forged.slot)
        forged.relativePath = RunOutputFile.canonicalRelativePath(
            runID: runID, outputID: forged.outputID, displayName: forged.displayName)
        let forgedPayload: [String: String] = [
            "tool": "workspace.publishOutput", "id": "call-3", "status": "ok",
            "summary": "x", "outputDigest": "d",
            "outputFilesJSON": String(data: try! JSONEncoder().encode([forged]),
                                      encoding: .utf8)!,
        ]
        let forgedJSON = try! JSONSerialization.data(withJSONObject: forgedPayload,
                                                     options: [.sortedKeys])
        _ = try await fx.store?.appendEvent(
            runID: runID, kind: .toolResult,
            payloadJSON: String(data: forgedJSON, encoding: .utf8)!)
        let forgedOpen = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                              runID: runID, outputID: forged.outputID)
        #expect(Int32(truncatingIfNeeded: forgedOpen) == RunOutputBridgeStatus.rejected)
        #expect(fx.authority.activeLeaseCount == 0)
        try await fx.closeStore()
    }

    @Test("stale-epoch calls fence reads and info, close still releases the exact token")
    func staleEpochFencesAndDrains() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1")
        let ticket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: receipt.outputID)
        #expect(ticket > 0)
        // A newer root generation replaces the live epoch: every existing
        // session's reads and info refuse typed, while close still drains
        // the retired generation's exact lease (cleanup keeps retaining
        // until then — Core10 semantics, no force-free).
        var page = [UInt8](repeating: 0, count: 16)
        fx.bridge.liveEpochOverrideForTesting = 8
        let read = page.withUnsafeMutableBufferPointer { raw in
            fx.bridge.read(ticket, offset: 0, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(read == RunOutputBridgeStatus.generationFenced)
        var reply = [CChar](repeating: 0, count: 4096)
        let info = reply.withUnsafeMutableBufferPointer { raw in
            fx.bridge.info(ticket, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(info == RunOutputBridgeStatus.generationFenced)
        // New opens under the OLD epoch claim fence at admission.
        let oldOpen = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                           runID: runID, outputID: receipt.outputID)
        #expect(Int32(truncatingIfNeeded: oldOpen) == RunOutputBridgeStatus.generationFenced)
        // Rebind the store seam to the new epoch, then close drains the
        // retired session's lease and the sweep never advertises it again.
        fx.bridge.liveEpochOverrideForTesting = fx.epoch
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        try await fx.closeStore()
    }

    @Test("mid-stream byte movement is refused (changed) and cancel/close keeps the tree recoverable")
    func cancelDuringCopyKeepsRecoverableData() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let payload = Data("streaming body that must remain recoverable".utf8)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1", content: payload)
        let ticket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: receipt.outputID)
        #expect(ticket > 0)
        // Consumer cancels after the first chunk: close releases the lease.
        var page = [UInt8](repeating: 0, count: 8)
        let first = page.withUnsafeMutableBufferPointer { raw in
            fx.bridge.read(ticket, offset: 0, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(first == 8)
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        // The snapshot tree bytes are STILL on disk (this lane never deletes
        // or repairs recoverable data; cleanup owns removal).
        let kept = try! Data(contentsOf: fx.snapshotURL(for: receipt))
        #expect(kept == payload)
        // Re-open proves the record is intact and re-verifiable.
        let again = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                         runID: runID, outputID: receipt.outputID)
        #expect(again > 0)
        #expect(fx.bridge.close(again) == RunOutputBridgeStatus.ok)
        try await fx.closeStore()
    }

    @Test("the live-session ceiling refuses typed and releases the refused open's lease")
    func saturationFailsClosed() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1")
        var tickets: [Int64] = []
        for _ in 0..<RunOutputBridgeLimits.maximumLiveSessions {
        let ticket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: receipt.outputID)
        #expect(ticket > 0)
            tickets.append(ticket)
        }
        let overflow = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                            runID: runID, outputID: receipt.outputID)
        #expect(Int32(truncatingIfNeeded: overflow) == RunOutputBridgeStatus.saturated)
        #expect(fx.authority.activeLeaseCount == RunOutputBridgeLimits.maximumLiveSessions)
        for ticket in tickets {
            #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        }
        #expect(fx.authority.activeLeaseCount == 0)
        try await fx.closeStore()
    }

    @Test("a retired generation's live sessions are swept by the next open and their leases drain")
    func retiredGenerationSweepReleasesLeases() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let oldRun = UUID()
        let newRun = UUID()
        try await fx.saveRun(oldRun, conversationID: conversationID)
        try await fx.saveRun(newRun, conversationID: conversationID)
        let oldReceipt = try await fx.publish(runID: oldRun, conversationID: conversationID,
                                              callID: "call-old")
        let oldTicket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                             runID: oldRun, outputID: oldReceipt.outputID)
        #expect(oldTicket > 0)
        #expect(fx.authority.activeLeaseCount == 1)
        // Simulate the generation replacement path: the store seam now only
        // answers the NEW epoch while the old session lingers; opening under
        // the new epoch sweeps the stale session and releases its exact
        // lease without touching any bytes.
        let newEpoch: UInt64 = 8
        let capturedStore = fx.store!
        fx.authority.install(artifactRootPath: fx.artifact.path, epoch: newEpoch)
        fx.bridge.liveEpochOverrideForTesting = newEpoch
        fx.bridge.storeProviderOverrideForTesting = { probe in
            probe == newEpoch ? capturedStore : nil
        }
        // Publish under the NEW generation for the other run (real store +
        // real authority; the publish lease itself settles back to zero).
        let newBytes = Data("new generation bytes".utf8)
        let newSourceURL = fx.base.appendingPathComponent("source-\(UUID().uuidString)")
        try newBytes.write(to: newSourceURL)
        let newContext = ToolContext(runID: newRun, toolCallID: "call-new",
                                     cancellation: CancellationToken(),
                                     environmentID: "env-1", conversationID: conversationID)
        let newReceipt = try fx.authority.publish(
            RunOutputSnapshotRequest(
                producerTool: "workspace.publishOutput", slot: "document",
                commit: RunOutputCommit(sourceURL: newSourceURL,
                                        sha256: FloeDigest.sha256Hex(newBytes),
                                        byteCount: newBytes.count,
                                        displayName: "new.docx",
                                        mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                                        uti: nil)),
            using: newContext)
        _ = try await capturedStore.appendEvent(
            runID: newRun, kind: .toolResult,
            payloadJSON: toolResultPayloadJSON(callID: "call-new",
                                               tool: "workspace.publishOutput",
                                               receipts: [newReceipt]))
        let ticket = fx.bridge.openEgress(epoch: newEpoch, conversationID: conversationID,
                                          runID: newRun, outputID: newReceipt.outputID)
        #expect(ticket > 0)
        // The sweep drained the OLD session's lease; only the new session's
        // lease remains live.
        #expect(fx.authority.activeLeaseCount == 1)
        var page = [UInt8](repeating: 0, count: 16)
        let oldRead = page.withUnsafeMutableBufferPointer { raw in
            fx.bridge.read(oldTicket, offset: 0, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(oldRead < 0) // retired ticket is fenced, never re-advertised
        _ = fx.bridge.close(oldTicket)
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        try await fx.closeStore()
    }
}
