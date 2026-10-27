// FloeAndroidCoreTests — D04 run-output egress LIFETIME + bounded-reply
// regressions (job-bd6d033ab1e34fad, pinned on the run-output-consumer12
// bridge accepted by Main).
//
// These are the source regressions for the two observed defects and the
// one bounded-reply edge:
//   * close/sweep/supersede racing an ACTUAL in-flight read: the read never
//     reports bytes after the exact owner released (post-I/O generation /
//     owner / close recheck before returning bytes), new admissions are
//     fenced immediately, and the physical FD + lease release is deferred
//     to the draining settle and runs EXACTLY ONCE;
//   * the egress streams the session's PINNED verified descriptor: a path
//     swap (unlink + same-size decoy file at the verified path) after open
//     cannot move the byte stream to a different inode, while a NEW open
//     honestly refuses the decoy;
//   * the open-hop timeout cleaner drains the pinned descriptor and the
//     exact lease token exactly once (no dangling owner, no fake success);
//   * the list page serializes with the REAL serializer down to an honest
//     byte-bounded PREFIX (whole trailing items dropped, `truncatedItems`
//     set, metadata never cut), and only an envelope that cannot fit even
//     with zero items answers the typed -106.
//
// Real filesystem snapshots published through the REAL
// `RuntimeFacadeRunOutput.publish` seam, real durable SQLite toolResult
// records, and the actual `RunOutputBridgeFacade` grammar over its
// same-module test seams (plus the lifetime-race seams added by this
// repair). Authored as SOURCE ONLY: not compiled, not executed here.

import Foundation
import Testing
import Synchronization
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

private func lifetimeToolResultPayloadJSON(callID: String, tool: String,
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

/// One-shot pause gate for a read's owned I/O window: armed once, pauses
/// exactly one read, later reads pass straight through.
private final class LifetimeWindow: @unchecked Sendable {
    let entered = AsyncGate()
    let resume = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var armed = false

    func arm() { stateLock.lock(); armed = true; stateLock.unlock() }

    func pauseIfNeeded() {
        stateLock.lock()
        let shouldPause = armed
        armed = false
        stateLock.unlock()
        guard shouldPause else { return }
        entered.signal()
        resume.wait()
    }
}

/// One-shot async gate: signal() from ANY context (sync bridge hook or
/// detached task); await wait() resumes exactly once. Replaces
/// DispatchSemaphore waits that the macOS 27 SDK forbids inside async test
/// functions — the coordination semantics are unchanged.
private final class AsyncGate: @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Never>?
        var signaled = false
    }
    private let mutex = Mutex<State>(State())

    func signal() {
        let pending = mutex.withLock { state -> CheckedContinuation<Void, Never>? in
            if let continuation = state.continuation {
                state.continuation = nil
                return continuation
            }
            state.signaled = true
            return nil
        }
        pending?.resume()
    }

    func wait() async {
        let immediate = mutex.withLock { state -> Bool in
            if state.signaled {
                state.signaled = false
                return true
            }
            return false
        }
        if immediate { return }
        await withCheckedContinuation { continuation in
            let already = mutex.withLock { state -> Bool in
                if state.signaled {
                    state.signaled = false
                    return true
                }
                state.continuation = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }
}

private final class LifetimeBox<Value>: @unchecked Sendable {
    private let stateLock = NSLock()
    private var stored: Value?
    func store(_ value: Value) { stateLock.lock(); stored = value; stateLock.unlock() }
    var value: Value? { stateLock.lock(); defer { stateLock.unlock() }; return stored }
}

private func waitUntil(timeoutSeconds: Double = 5.0, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !condition() {
        if Date() >= deadline { return false }
        usleep(25_000)
    }
    return true
}

@Suite("FloeAndroidCore.RunOutputBridgeLifetime pinned egress + bounded reply")
struct RunOutputBridgeLifetimeTests {

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
                .appendingPathComponent("floe-ro-lifetime-\(UUID().uuidString)", isDirectory: true)
            artifact = base.appendingPathComponent("FloeAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)
            authority = RuntimeFacadeRunOutput()
            bridge = RunOutputBridgeFacade()
            bridge.liveEpochOverrideForTesting = epoch
            bridge.runOutputOverrideForTesting = authority
        }

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
            bridge.readIOWindowHookForTesting = nil
            bridge.fileHopSecondsOverrideForTesting = nil
            bridge.openHopPostVerifyPauseForTesting = nil
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
                    payloadJSON: lifetimeToolResultPayloadJSON(callID: callID, tool: tool,
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

        func stats() -> [String: Any] {
            let data = Data(bridge.statsJSON().utf8)
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
    }

    // MARK: - Close/read lifetime (defect 1)

    @Test("close fences new admissions immediately, an in-flight read never reports bytes after release, and the FD + lease drain exactly once")
    func closeDuringInFlightReadDrainsExactlyOnce() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let payload = Data(repeating: 0x5A, count: 64)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1", content: payload)
        let ticket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: receipt.outputID)
        #expect(ticket > 0)
        #expect(fx.authority.activeLeaseCount == 1)

        let window = LifetimeWindow()
        window.arm()
        fx.bridge.readIOWindowHookForTesting = { window.pauseIfNeeded() }
        let settled = LifetimeBox<Int32>()
        let finished = AsyncGate()
        Task.detached(priority: .userInitiated) {
            var page = [UInt8](repeating: 0, count: 16)
            let copied = page.withUnsafeMutableBufferPointer { raw in
                fx.bridge.read(ticket, offset: 0, buffer: raw.baseAddress!,
                               capacity: Int32(raw.count))
            }
            settled.store(copied)
            finished.signal()
        }
        await window.entered.wait()  // read #1 holds its REAL in-flight claim
        // close fences immediately and answers OK (the reviewed grammar)…
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        // …but the physical lease (+ FD) release is DEFERRED: a claimed
        // running read still owns the session, so cleanup cannot yet see a
        // released owner (the exact defect-1 lifetime join).
        #expect(fx.authority.activeLeaseCount == 1)
        // A NEW admission during the drain is fenced immediately, never bytes:
        var latePage = [UInt8](repeating: 0, count: 16)
        let late = latePage.withUnsafeMutableBufferPointer { raw in
            fx.bridge.read(ticket, offset: 0, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(late == RunOutputBridgeStatus.stateConflict)
        window.resume.signal()
        await finished.wait()
        // The paused read performed its pread AFTER close — yet the settle
        // recheck must discard the bytes: success is never silently reported
        // after the exact owner released.
        #expect(settled.value == RunOutputBridgeStatus.stateConflict)
        // The drain ran the physical release EXACTLY ONCE:
        #expect(fx.authority.activeLeaseCount == 0)
        // Duplicate close stays idempotent (no second release):
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        // The drained ticket is retired — never re-advertised:
        var afterPage = [UInt8](repeating: 0, count: 16)
        let afterDrain = afterPage.withUnsafeMutableBufferPointer { raw in
            fx.bridge.read(ticket, offset: 0, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(afterDrain == RunOutputBridgeStatus.generationFenced)
        // Typed counters-only stats: one close, one deferred drain, one
        // exactly-once lease release + FD release, zero reported chunks.
        let stats = fx.stats()
        #expect(stats["closes"] as? Int == 1)
        #expect(stats["leaseReleased"] as? Int == 1)
        #expect(stats["fdReleased"] as? Int == 1)
        #expect(stats["delayedReleases"] as? Int == 1)
        #expect(stats["fencedReads"] as? Int == 1)
        #expect(stats["chunksRead"] as? Int == 0)
        // The snapshot bytes are untouched (this lane deletes nothing).
        let kept = try Data(contentsOf: fx.snapshotURL(for: receipt))
        #expect(kept == payload)
        try await fx.closeStore()
    }

    @Test("a generation superseded mid-read fences the read and holds the lease until close drains it (retirement never force-frees)")
    func supersededGenerationFencesInFlightRead() async throws {
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

        let window = LifetimeWindow()
        window.arm()
        fx.bridge.readIOWindowHookForTesting = { window.pauseIfNeeded() }
        let settled = LifetimeBox<Int32>()
        let finished = AsyncGate()
        Task.detached(priority: .userInitiated) {
            var page = [UInt8](repeating: 0, count: 16)
            let copied = page.withUnsafeMutableBufferPointer { raw in
                fx.bridge.read(ticket, offset: 0, buffer: raw.baseAddress!,
                               capacity: Int32(raw.count))
            }
            settled.store(copied)
            finished.signal()
        }
        await window.entered.wait()
        // The live root generation is replaced while the read is claimed.
        fx.bridge.liveEpochOverrideForTesting = fx.epoch + 1
        window.resume.signal()
        await finished.wait()
        #expect(settled.value == RunOutputBridgeStatus.generationFenced)
        // Core10 semantics: retirement never force-frees — the lease stays
        // live (cleanup keeps retaining) until the exact owner closes.
        #expect(fx.authority.activeLeaseCount == 1)
        // The exact close still releases the exact token exactly once.
        fx.bridge.liveEpochOverrideForTesting = fx.epoch
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        try await fx.closeStore()
    }

    @Test("a clean-EOF success is fenced like any bytes once close has fired during the read")
    func eofSuccessIsFencedAfterClose() async throws {
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
        let window = LifetimeWindow()
        window.arm()
        fx.bridge.readIOWindowHookForTesting = { window.pauseIfNeeded() }
        let settled = LifetimeBox<Int32>()
        let finished = AsyncGate()
        Task.detached(priority: .userInitiated) {
            var page = [UInt8](repeating: 0, count: 16)
            // At the sealed size this read WOULD answer 0 (clean EOF).
            let copied = page.withUnsafeMutableBufferPointer { raw in
                fx.bridge.read(ticket, offset: Int64(receipt.byteCount),
                               buffer: raw.baseAddress!, capacity: Int32(raw.count))
            }
            settled.store(copied)
            finished.signal()
        }
        await window.entered.wait()
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        window.resume.signal()
        await finished.wait()
        // Never a silent success after release — not even the zero-length
        // EOF answer: the session closed while the claim was live.
        #expect(settled.value == RunOutputBridgeStatus.stateConflict)
        #expect(fx.authority.activeLeaseCount == 0)
        try await fx.closeStore()
    }

    // MARK: - Pinned descriptor (defect 2)

    @Test("egress streams the pinned verified descriptor: a post-open path swap cannot move the byte stream")
    func pinnedDescriptorSurvivesPathSwap() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let payload = Data(repeating: 0x11, count: 48)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1", content: payload)
        let ticket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: receipt.outputID)
        #expect(ticket > 0)
        // Move the verified file away and drop a DIFFERENT file of the SAME
        // SIZE at its path: a reader reopening by path per chunk would now
        // serve the decoy bytes; the pinned session must not.
        let snapshot = fx.snapshotURL(for: receipt)
        let movedAside = fx.base.appendingPathComponent("moved-aside.bin")
        try FileManager.default.moveItem(at: snapshot, to: movedAside)
        let decoy = Data(repeating: 0x22, count: payload.count)
        try decoy.write(to: snapshot)
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
            seen.append(contentsOf: page.prefix(Int(copied)))
            offset += Int64(copied)
        }
        // The pinned, digest-verified inode — never the swapped-in decoy.
        #expect(seen == payload)
        #expect(fx.bridge.close(ticket) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        // A NEW open honestly refuses the decoy (full streamed digest at
        // resolution): the swap is typed, never laundered as a success.
        let reopened = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                            runID: runID, outputID: receipt.outputID)
        #expect(Int32(truncatingIfNeeded: reopened) == RunOutputBridgeStatus.fileChanged)
        try await fx.closeStore()
    }

    // MARK: - Open-hop timeout drain

    @Test("the open-hop timeout cleaner drains the pinned descriptor and the exact lease exactly once, then a clean open succeeds")
    func hopTimeoutDrainsPinnedDescriptorAndLease() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        let payload = Data("bytes that must stay recoverable".utf8)
        let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                           callID: "call-1", content: payload)
        // The hop verifies fully, then holds the pinned descriptor open
        // past the caller's shortened hop budget.
        fx.bridge.fileHopSecondsOverrideForTesting = 0.05
        fx.bridge.openHopPostVerifyPauseForTesting = 0.4
        let ticket = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                          runID: runID, outputID: receipt.outputID)
        #expect(Int32(truncatingIfNeeded: ticket) == RunOutputBridgeStatus.hopTimeout)
        #expect(fx.authority.activeLeaseCount == 1)  // orphan hop is still a real owner
        var stats = fx.stats()
        #expect(stats["hopsTimedOut"] as? Int == 1)
        #expect(stats["opens"] as? Int == 0)
        // The bounded cleaner waits the SAME gate, disposes the late hop's
        // pinned descriptor and releases the exact token — once.
        let drained = waitUntil { fx.authority.activeLeaseCount == 0 }
        #expect(drained)
        stats = fx.stats()
        #expect(stats["leaseReleased"] as? Int == 1)
        #expect(stats["fdReleased"] as? Int == 1)
        // Seams clear; the lane is fully reusable with nothing dangling.
        fx.bridge.fileHopSecondsOverrideForTesting = nil
        fx.bridge.openHopPostVerifyPauseForTesting = nil
        let again = fx.bridge.openEgress(epoch: fx.epoch, conversationID: conversationID,
                                         runID: runID, outputID: receipt.outputID)
        #expect(again > 0)
        #expect(fx.bridge.close(again) == RunOutputBridgeStatus.ok)
        #expect(fx.authority.activeLeaseCount == 0)
        let kept = try Data(contentsOf: fx.snapshotURL(for: receipt))
        #expect(kept == payload)
        try await fx.closeStore()
    }

    // MARK: - Bounded list reply (the -106 page-loss edge)

    @Test("the list reply stays byte-bounded with the REAL serializer: honest prefix + truncatedItems, never a whole-page -106")
    func listReplyStaysWithinByteBudget() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try await fx.installStore()
        let conversationID = UUID()
        let runID = UUID()
        try await fx.saveRun(runID, conversationID: conversationID)
        // The list path requires the trusted artifact-root binding for this
        // generation (typed leaseRefused without it — the dynamic-absence
        // rule); publish normally installs it, so bind it explicitly here.
        _ = fx.authority.install(artifactRootPath: fx.artifact.path, epoch: fx.epoch)
        let fullBudget = Int(RunOutputBridgeLimits.maximumReplyBytes) - 1
        // Empty owned page: well-formed, honest, never -106.
        let (emptyStatus, emptyBody) = fx.bridge.listJSON(epoch: fx.epoch,
                                                          conversationID: conversationID,
                                                          runID: runID,
                                                          replyByteBudget: fullBudget)
        #expect(emptyStatus == RunOutputBridgeStatus.ok)
        let emptyJSON = try JSONSerialization.jsonObject(
            with: Data(emptyBody!.utf8)) as! [String: Any]
        #expect((emptyJSON["items"] as? [Any])?.isEmpty == true)
        #expect(emptyJSON["truncatedItems"] as? Int == 0)

        // 32 legitimately sealed outputs whose metadata is quote-heavy
        // (escaped size grows past 32 KiB in total): the WHOLE page must not
        // collapse into -106 — the reply serializes down to an honest prefix.
        let heavyName = String(repeating: "\"", count: 255)   // 255 UTF-8 bytes (cap), 511 escaped
        let heavyCall = String(repeating: "\"", count: 256)   // 256 characters (cap), 513 escaped
        var sealed: [RunOutputFile] = []
        for index in 0..<RunOutputBridgeLimits.maximumListedItems {
            let receipt = try await fx.publish(runID: runID, conversationID: conversationID,
                                               callID: heavyCall,
                                               slot: "slot-\(index)",
                                               displayName: heavyName)
            sealed.append(receipt)
        }
        let (status, body) = fx.bridge.listJSON(epoch: fx.epoch,
                                                conversationID: conversationID,
                                                runID: runID,
                                                replyByteBudget: fullBudget)
        #expect(status == RunOutputBridgeStatus.ok)
        let text = try #require(body)
        #expect(text.utf8.count <= fullBudget)
        let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let items = try #require(json["items"] as? [[String: Any]])
        #expect(items.count > 0)
        #expect(items.count < RunOutputBridgeLimits.maximumListedItems)
        #expect(json["truncatedItems"] as? Int == 1)
        #expect(json["scanTruncated"] as? Int == 0)
        #expect(json["rejectedCount"] as? Int == 0)
        // The retained page is the ORDERED prefix — whole items only: no
        // UTF-8/metadata is ever cut, and nothing is silently hidden.
        for (index, item) in items.enumerated() {
            #expect(item["outputID"] as? String == sealed[index].outputID)
            #expect(item["displayName"] as? String == heavyName)
            #expect(item["producerCallID"] as? String == heavyCall)
            #expect(item["slot"] as? String == "slot-\(index)")
            #expect(item["availability"] as? String == "available")
        }
        // A tighter budget still yields a well-formed bounded prefix.
        let (smallStatus, smallBody) = fx.bridge.listJSON(epoch: fx.epoch,
                                                          conversationID: conversationID,
                                                          runID: runID,
                                                          replyByteBudget: 2048)
        #expect(smallStatus == RunOutputBridgeStatus.ok)
        let smallText = try #require(smallBody)
        #expect(smallText.utf8.count <= 2048)
        let smallJSON = try JSONSerialization.jsonObject(
            with: Data(smallText.utf8)) as! [String: Any]
        let smallItems = smallJSON["items"] as? [[String: Any]]
        #expect(smallItems?.isEmpty == false)
        #expect(smallJSON["truncatedItems"] as? Int == 1)
        // Only an envelope that cannot fit even EMPTY answers the typed
        // bounded refusal (never a cut page, never a hidden item).
        let (tinyStatus, tinyBody) = fx.bridge.listJSON(epoch: fx.epoch,
                                                        conversationID: conversationID,
                                                        runID: runID,
                                                        replyByteBudget: 48)
        #expect(tinyStatus == RunOutputBridgeStatus.bufferTooSmall)
        #expect(tinyBody == nil)
        // The C-boundary copy of the bounded page succeeds at the EXACT
        // copied length (the wrapper budget minus NUL is respected).
        var replyBuffer = [CChar](repeating: 0, count: RunOutputBridgeLimits.maximumReplyBytes)
        let copied = replyBuffer.withUnsafeMutableBufferPointer { raw in
            RunOutputBridgeFacade.copy(text, buffer: raw.baseAddress!, capacity: Int32(raw.count))
        }
        #expect(copied == Int32(text.utf8.count))
        try await fx.closeStore()
    }
}
