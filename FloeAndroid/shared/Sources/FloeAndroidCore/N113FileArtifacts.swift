// FloeAndroidCore — Durable child transcript adapters for file-result cards.
//
// SPDX-License-Identifier: MPL-2.0
//
// The child transcript is the durable owner of a delegated child's tool
// results. `NativeChildFileArtifacts` (FloeTools) owns the trusted receipt
// shape and every identity rule; this file only translates the ORIGINAL
// durable `ChildRunEntry` rows into that decoder, including the earlier
// toolRequest rows that prove the call/tool pair really happened.
//
// A malformed/failed/foreign receipt is surfaced to the reader as a rejected
// claim (never silently dropped). An ordinary legacy row with no receipt
// claim contributes nothing. The reader re-verifies the actual snapshot bytes
// through the existing RunOutputSnapshotStore when the card is opened.

import Foundation
import FloePersistence
import FloeTools

public enum N113FileArtifacts {
    /// Bounded number of child runs considered for one parent run. A larger
    /// fan-out is reported as a truncated scan (absence of a card is never
    /// presented as proven when the walk stopped).
    public static let maximumChildRunsPerParent = 16
    /// One child transcript page/scan bound mirrors the run reader's frozen
    /// page semantics. Transcript entries are written serially by the child
    /// runtime, so a bounded page walk is honest about truncation.
    public static let defaultPageSize = 200
    public static let defaultMaximumScanPages = 100

    /// The original toolRequest pair `{tool, callID}` for a durable child
    /// row, or nil when the row is not a well-formed request. Required
    /// pairing metadata is bounded; a malformed request simply does not
    /// authorize a later result receipt.
    public static func requestTool(from entry: ChildRunEntry) -> (callID: String, tool: String)? {
        guard entry.kind == .toolRequest,
              entry.payloadJSON.utf8.count <= NativeChildFileArtifacts.maximumEnvelopeBytes,
              let data = entry.payloadJSON.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let callID = object["callID"] as? String,
              let tool = object["tool"] as? String,
              !callID.isEmpty, !tool.isEmpty else {
            return nil
        }
        return (callID, tool)
    }

    /// Decode one durable toolResult row into a trusted receipt. Returns nil
    /// for a legacy row with no receipt claim AND for every malformed or
    /// failed claim; callers use [advertisesReceipt] to distinguish those
    /// cases and count a rejected claim honestly.
    public static func receipt(
        from entry: ChildRunEntry,
        parentRunID: UUID,
        taskID: UUID,
        childID: UUID,
        originalRequestTools: [String: String]
    ) -> NativeChildFileReceipt? {
        guard entry.kind == .toolResult else { return nil }
        return NativeChildFileArtifacts.decode(
            payloadJSON: entry.payloadJSON,
            parentRunID: parentRunID,
            taskID: taskID,
            childID: childID,
            originalRequestTools: originalRequestTools)
    }

    public static func advertisesReceipt(_ entry: ChildRunEntry) -> Bool {
        entry.kind == .toolResult
            && NativeChildFileArtifacts.advertisesReceipt(payloadJSON: entry.payloadJSON)
    }
}
