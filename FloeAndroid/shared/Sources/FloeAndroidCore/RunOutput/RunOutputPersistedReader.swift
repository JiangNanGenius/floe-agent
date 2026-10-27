// SPDX-License-Identifier: MPL-2.0
//
// D04 App consumer (job-6f953da44de048d0) — the EXACT OWNED persisted-run
// receipt reader.
//
// This is the authorization step that `RuntimeFacadeRunOutput.verifiedRead`
// documents as its required predecessor (coordinator API review 2026-10-27):
// an App/bridge consumer must NEVER hand `verifiedRead` model-adjacent JSON.
// The only receipts this reader ever returns come from the run's OWN durable
// `toolResult` events in the trusted generation's persisted store:
//   * the `runs` row must exist and its `conversationID` must equal the
//     REQUESTING conversation (a foreign run is `notOwner`, indistinguishable
//     from a missing one at the wire);
//   * the sealed `outputFilesJSON` nested array of the matching durable
//     toolResult payload is decoded with the original `RunOutputFile`
//     Codable shape — no new receipt format, no MAC, no timestamp identity;
//   * every returned receipt must re-prove: `runID` equals the scanned run,
//     `taskID` equals the requesting conversation, `producerCallID`/
//     `producerTool` equal the SAME event's `id`/`tool` members (the receipt
//     is only owned through the exact persisted call record that carries it),
//     `hasRuntimeConsistentIdentity` (outputID re-derives from
//     run/call/slot), and `isCanonicalForCurrentRun` (canonical namespace
//     path, valid digest, bounded fields, explicit `.userFile` role).
// A model summary, document or tool output can quote a path or a whole
// receipt — none of it reaches this reader. Only the durable event written
// by the completion-critical service path does, and the runtime seal
// (`AgentRuntime.finalizeToolResult`, 8f ported by run-output-core10)
// guaranteed those values at write time.
//
// Scan discipline: bounded paged reads over the ORIGINAL per-run append-only
// sequence (`RunStore.events(runID:afterSequence:limit:)`, the same frozen
// page shape the event pump uses). Legacy runs with no output payloads read
// normally and yield nothing. A scan that hits its page ceiling NEVER
// silently reports "no outputs": it reports `.scanTruncated` / the honest
// `scanTruncated` flag so the consumer fails closed instead of pretending.
// Inconsistent duplicate claims for one outputID (same canonical identity
// with different sealed bytes) are counted as rejected, never laundered into
// whichever copy was seen last.
//
// This source is authored for Main's single frozen-batch Android ARM64
// compile: NOT compiled, NOT executed, NOT type-checked here.

import Foundation
import FloeCore
import FloeModels
import FloePersistence

/// One owned persisted receipt plus the durable event sequence that carries
/// it (stable ordering for the bounded list wire).
public struct RunOutputPersistedReceipt: Sendable, Equatable {
    public let receipt: RunOutputFile
    public let eventSequence: Int
}

/// Outcome of scanning one run's durable toolResult events for the sealed
/// receipts owned by one exact conversation.
public enum RunOutputReceiptScan: Sendable, Equatable {
    /// `items` are in (event sequence, payload order) order.
    /// `scanTruncated` means the bounded page walk stopped before the run's
    /// durable tail: callers must treat ABSENCE of an id in `items` as
    /// unproven, never as "no output".
    case owned(items: [RunOutputPersistedReceipt], scanTruncated: Bool, rejectedCount: Int)
    /// No `runs` row for this id in the trusted generation's durable store
    /// (a temporary/RAM-only run is structurally invisible here — that is
    /// the honest absence, not an error).
    case runMissing
    /// The run row exists but belongs to a different conversation, or the
    /// sealed receipts' `taskID` disagrees with the requester. Typed the
    /// same as unknown at the wire level: no ownership-probing oracle.
    case notOwner
    /// The durable store read failed (never downgraded to "no outputs").
    case storeUnavailable
}

/// Outcome of looking up ONE exact requested output.
public enum RunOutputReceiptLookup: Sendable, Equatable {
    case owned(RunOutputPersistedReceipt)
    case runMissing
    case notOwner
    /// The run's durable records own no sealed receipt with this outputID
    /// (and the scan completed — absence is proven, not truncated).
    case receiptMissing
    /// The bounded scan stopped before the durable tail without finding the
    /// id: unproven, callers must fail closed.
    case scanTruncated
    /// The requested id exists in a durable payload but the record itself
    /// violates the sealed identity contract (forged/relabelled/copied).
    case rejected(reason: String)
    case storeUnavailable
}

/// Reader over the durable toolResult events of ONE run in the CURRENT
/// trusted generation's owned store. Constructed per call by the bridge
/// facade with the store resolved from `RunDomainFacade` (never a caller
/// argument, never a singleton fallback, never a temporary bundle).
public struct RunOutputPersistedReader: Sendable {
    /// Frozen durable page size (mirrors `SQLiteRunStore.events` limit
    /// semantics and the event-pump window; the value is a page bound, not
    /// a scan budget).
    public static let defaultPageSize = 200
    /// Hard page ceiling for one scan at production defaults: 100 pages =
    /// 20,000 events per run. Reaching it without draining the run tail is
    /// reported honestly as truncation (open/lookup fail closed; list flags
    /// partial results). Injectable for focused qualification (the bridge
    /// always uses the defaults).
    public static let defaultMaximumScanPages = 100

    private let runStore: any RunStore
    public let pageSize: Int
    public let maximumScanPages: Int

    public init(runStore: any RunStore,
                pageSize: Int = RunOutputPersistedReader.defaultPageSize,
                maximumScanPages: Int = RunOutputPersistedReader.defaultMaximumScanPages) {
        self.runStore = runStore
        self.pageSize = max(1, pageSize)
        self.maximumScanPages = max(1, maximumScanPages)
    }

    // MARK: - Public surface

    public func scan(conversationID: UUID, runID: UUID) async -> RunOutputReceiptScan {
        let record: RunRecord?
        do {
            record = try await runStore.run(id: runID)
        } catch {
            return .storeUnavailable
        }
        guard let record else { return .runMissing }
        guard record.conversationID == conversationID else { return .notOwner }

        var items: [RunOutputPersistedReceipt] = []
        var seen: [String: RunOutputFile] = [:]
        var contradictoryIDs: Set<String> = []
        var rejectedCount = 0
        var scanTruncated = false
        var afterSequence = 0
        var pageReadFailed = false
        var pages = 0
        while pages < maximumScanPages {
            pages += 1
            let page: [RunEventRecord]
            do {
                page = try await runStore.events(
                    runID: runID, afterSequence: afterSequence, limit: pageSize)
            } catch {
                pageReadFailed = true
                break
            }
            for event in page where event.kind == .toolResult {
                switch Self.decodeOwnedReceipts(
                    from: event, runID: runID, conversationID: conversationID) {
                case .items(let decoded):
                    for receipt in decoded {
                        if let previous = seen[receipt.receipt.outputID] {
                            if previous == receipt.receipt { continue }
                            // Idempotent duplicate (same sealed metadata) is
                            // a legitimate re-persistence; a DIFFERENT sealed
                            // body under one canonical identity is a forged
                            // contradiction. A contradiction removes BOTH
                            // copies from the owned view (never first- or
                            // last-wins laundering) and counts rejected.
                            rejectedCount += 1
                            if contradictoryIDs.insert(receipt.receipt.outputID).inserted {
                                items.removeAll { $0.receipt.outputID == receipt.receipt.outputID }
                            }
                            continue
                        }
                        seen[receipt.receipt.outputID] = receipt.receipt
                        items.append(receipt)
                    }
                case .malformed:
                    rejectedCount += 1
                }
            }
            guard let last = page.last else { break }
            afterSequence = max(afterSequence, last.sequence)
            if page.count < pageSize { break }
            if pages == maximumScanPages {
                // The ceiling consumed a FULL page: more durable events may
                // exist behind it. Never claim the walk finished.
                scanTruncated = true
            }
        }
        if pageReadFailed { return .storeUnavailable }
        return .owned(items: items, scanTruncated: scanTruncated,
                      rejectedCount: rejectedCount)
    }

    public func lookup(conversationID: UUID, runID: UUID, outputID: String) async
        -> RunOutputReceiptLookup
    {
        guard Self.isCanonicalOutputID(outputID) else {
            return .rejected(reason: "output identity is not a canonical 64-hex SHA-256")
        }
        let scan = await scan(conversationID: conversationID, runID: runID)
        switch scan {
        case .storeUnavailable: return .storeUnavailable
        case .runMissing: return .runMissing
        case .notOwner: return .notOwner
        case .owned(let items, let scanTruncated, let rejectedCount):
            if let hit = items.first(where: { $0.receipt.outputID == outputID }) {
                return .owned(hit)
            }
            if scanTruncated { return .scanTruncated }
            if rejectedCount > 0 {
                // A rejected durable claim could have carried the requested
                // identity. Absence is NOT proven: fail closed instead of
                // laundering the forged record out of existence.
                return .rejected(reason: "durable output records for this run contain rejected claims")
            }
            return .receiptMissing
        }
    }

    // MARK: - Durable payload decode (strict)

    /// Decode outcomes for one event: parsed owned receipts, or a malformed
    /// payload (counted rejected — never a silent drop of advertised bytes).
    enum EventDecode {
        case items([RunOutputPersistedReceipt])
        case malformed
    }

    static func decodeOwnedReceipts(
        from event: RunEventRecord, runID: UUID, conversationID: UUID
    ) -> EventDecode {
        // The payload is the ORIGINAL service string map (`jsonPayload`);
        // only string-valued members exist there. A non-object payload is
        // not a toolResult this contract ever writes: count rejected.
        guard let data = event.payloadJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let callID = object["id"] as? String,
              let tool = object["tool"] as? String else {
            return .malformed
        }
        // Legacy records (no output payload) read normally and contribute
        // nothing — this is the compatibility rule, not a silent drop.
        guard let nested = object["outputFilesJSON"] as? String,
              !nested.isEmpty else {
            return .items([])
        }
        guard let receipts = (try? JSONDecoder().decode([RunOutputFile].self,
                                                        from: Data(nested.utf8))) else {
            return .malformed
        }
        var accepted: [RunOutputPersistedReceipt] = []
        for receipt in receipts {
            // Every identity/ownership/canonicality proof runs BEFORE the
            // receipt can ever be handed toward `verifiedRead`:
            guard receipt.role == .userFile,
                  receipt.runID == runID,
                  receipt.taskID == conversationID,
                  receipt.producerCallID == callID,
                  receipt.producerTool == tool,
                  receipt.hasRuntimeConsistentIdentity,
                  receipt.isCanonicalForCurrentRun else {
                // One bad member inside an advertised array taints the whole
                // payload record (the seal never produced mixed batches): the
                // event counts as malformed rather than partially trusted.
                return .malformed
            }
            accepted.append(RunOutputPersistedReceipt(receipt: receipt,
                                                      eventSequence: event.sequence))
        }
        return .items(accepted)
    }

    static func isCanonicalOutputID(_ raw: String) -> Bool {
        RunOutputFile.isValidSHA256Hex(raw)
    }
}
