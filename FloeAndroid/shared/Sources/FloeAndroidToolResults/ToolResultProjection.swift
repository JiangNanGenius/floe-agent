// SPDX-License-Identifier: MPL-2.0
//
// C02 — bounded model-visible projection of one settled result.
//
// The complete post-redaction bytes live in the capture store. Model context
// receives a bounded summary plus a tiny, stable reference the model can page
// with `tools.readResult`. A paging page is NEVER compacted again: its own
// header promises a nextOffset, so a second summary would make the cursor
// lie. Nothing here re-executes a tool or reads raw logs.
import Foundation
import FloeTools

public enum ToolResultProjection {
    /// Maximum size of the annotation appended to a durable/model summary.
    public static let maximumReferenceNoteBytes = 512

    /// Appends a reference to the retained capture, once. `summary` should
    /// already be the bounded projection (for example the runtime's compaction
    /// output); this helper neither expands nor re-compacts it.
    public static func annotated(
        _ summary: String,
        ref: String?,
        totalBytes: Int?,
        retentionTruncated: Bool = false,
        executionReportedTruncation: Bool = false,
        captureUnavailable: Bool = false
    ) -> String {
        var notes: [String] = []
        if captureUnavailable {
            notes.append("the complete output was not retained for paging")
        } else if let ref, !ref.isEmpty,
                  ToolResultCaptureStore.isGeneratedReference(ref) {
            if summary.contains("ref=\(ref)") { return summary }
            notes.append("full post-redaction output ref=\(ref)")
            if let totalBytes, totalBytes >= 0 {
                notes.append("bytes=\(totalBytes)")
            }
        } else {
            notes.append("no capture ref is available for paging")
        }
        if retentionTruncated {
            if let totalBytes {
                notes.append("the retained capture itself was truncated at \(totalBytes) bytes")
            } else {
                notes.append("the retained capture itself is truncated")
            }
        }
        if executionReportedTruncation {
            notes.append("the tool reported truncating its own output")
        }
        guard !notes.isEmpty else { return summary }
        let command = ref.map { "tools.readResult {\"ref\":\"\($0)\",\"offset\":\(0)}" } ?? ""
        var note = "\n[" + notes.joined(separator: "; ")
        if !command.isEmpty, !captureUnavailable {
            note += "; read from offset 0 with " + command
        }
        note += "]"
        if note.utf8.count > maximumReferenceNoteBytes {
            note = ToolResultUTF8.prefix(note, maxBytes: maximumReferenceNoteBytes)
        }
        return summary + note
    }

    /// True for the result of `tools.readResult` itself. Such a page is the
    /// model-requested byte window and must be forwarded verbatim (subject
    /// only to the hard result cap that the tool already respects).
    public static func isPagingPage(toolName: String) -> Bool {
        ToolAliasTable.canonical(toolName) == ToolResultPagingTool.name
    }
}
