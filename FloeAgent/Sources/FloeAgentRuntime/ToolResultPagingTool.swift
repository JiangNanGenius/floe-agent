// FloeAgentRuntime — bounded, read-only paging over captured tool results.
//
// Provider-context compaction is not the same thing as execution-capture
// truncation: compaction replaces old messages with a summary, while a tool
// may itself have reported that its captured output was truncated. This tool
// pages through the bytes the tool layer actually captured (post-redaction),
// says which of the two situations applies, and never invents content when
// nothing was retained. It is task-scoped: the store resolves ownership from
// the runtime's trusted conversation, never from an argument.

import Foundation
import FloeCore
import FloeTools

public struct ToolResultPagingTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var callID: String?
        public var offset: Int?
        public var maxBytes: Int?

        public init(callID: String? = nil, offset: Int? = nil, maxBytes: Int? = nil) {
            self.callID = callID
            self.offset = offset
            self.maxBytes = maxBytes
        }
    }

    public static let name = "tools.readResult"
    public static let toolDescription =
        "Read a bounded page of a tool result captured for this run. Use it after context compaction hid part of an earlier output, or to page through a result the tool marked as truncated. Omit callID to list the retained results for this run. Reads are scoped to the current run: a call id from an earlier run of the same task is not returned, and if the same call id settled more than once in this run the latest settled capture is used. The page is the post-redaction output the tool captured; a copy already in model context may be a compacted excerpt, which is a different limitation from execution-capture truncation. Paging never re-runs the tool, and it never fabricates output for an evicted or unretained result."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "callID":{"type":"string","description":"Tool-call id to read. Omit to list retained results for this task."},
      "offset":{"type":"integer","minimum":0,"description":"UTF-8 byte offset into the captured text (default 0)."},
      "maxBytes":{"type":"integer","minimum":256,"maximum":32000,"description":"Maximum bytes in this page (default 4000)."}},
     "additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    public static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    public static let supportsConcurrentBatchDispatch = true

    public static let defaultMaxBytes = 4_000
    public static let maximumPageBytes = 32_000
    public static let maximumCallIDCharacters = 200
    /// The whole rendered view (metadata + notes + page) must stay below the
    /// result cap the runtime gives this tool. The page is at most 32,000
    /// bytes and every displayed metadata field is bounded, so this is a
    /// derived ceiling rather than a hope: 32,000 + bounded header/notes.
    public static let maximumRenderedBytes = 40 * 1024
    public static let displayCallIDCharacters = 200
    public static let displayCallIDBytes = 800
    public static let displayToolNameCharacters = 96
    public static let displayToolNameBytes = 384

    public static var descriptor: ToolCatalog.Descriptor {
        .init(name: name,
              toolDescription: toolDescription,
              parametersJSON: parametersJSON,
              riskLabels: riskLabels,
              isSideEffecting: isSideEffecting,
              executionBoundary: executionBoundary,
              supportsConcurrentBatchDispatch: supportsConcurrentBatchDispatch)
    }

    private let store: ToolResultCaptureStore

    public init(store: ToolResultCaptureStore) {
        self.store = store
    }

    public func validate(_ args: Arguments) throws {
        if let callID = args.callID {
            let trimmed = callID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= Self.maximumCallIDCharacters,
                  trimmed.utf8.count <= 800,
                  trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
                throw FloeError.validationFailed(
                    "callID must be a printable tool-call id no longer than \(Self.maximumCallIDCharacters) characters"
                )
            }
        }
        if let offset = args.offset, offset < 0 {
            throw FloeError.validationFailed("offset must be >= 0")
        }
        if let maxBytes = args.maxBytes, maxBytes < 256 || maxBytes > Self.maximumPageBytes {
            throw FloeError.validationFailed("maxBytes must be between 256 and \(Self.maximumPageBytes)")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard let conversationID = context.conversationID else {
            return Self.output(
                "status=missing reason=no-task-binding\nThis runtime has no trusted task binding, so captured tool results cannot be resolved. Do not fabricate the missing output.",
                exitStatus: 66
            )
        }
        guard let callID = args.callID?.trimmingCharacters(in: .whitespacesAndNewlines), !callID.isEmpty else {
            let index = await store.index(conversationID: conversationID, runID: context.runID)
            guard case .index(let rows, let evicted) = index else {
                return Self.output("status=indexUnavailable", exitStatus: 66)
            }
            var lines = ["status=ok mode=index retained=\(rows.count) evicted=\(evicted)"]
            if rows.isEmpty {
                lines.append("No retained tool results for this run. Older captures are not recreated; re-run a tool only if repeating its side effects is safe.")
            } else {
                lines.append("Retained results for this run (newest first):")
                for row in rows {
                    // Metadata is display-only and bounded: captured names can
                    // originate dynamic MCP descriptors, so a huge name must
                    // not consume the rendered budget. Lookup identity stays
                    // the raw stored call id.
                    lines.append("callID=\(Self.displayMetadata(row.callID, characters: Self.displayCallIDCharacters, bytes: Self.displayCallIDBytes)) tool=\(Self.displayMetadata(row.toolName, characters: Self.displayToolNameCharacters, bytes: Self.displayToolNameBytes)) bytes=\(row.totalBytes) capture=\(Self.captureState(row.executionReportedTruncation, row.retentionTruncated)) persistence=\(Self.persistenceState(row.durability)) capturedAt=\(ISO8601DateFormatter().string(from: row.capturedAt))")
                }
                lines.append("Read one with callID plus optional offset and maxBytes.")
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        }
        let offset = max(0, args.offset ?? 0)
        let maxBytes = min(max(256, args.maxBytes ?? Self.defaultMaxBytes), Self.maximumPageBytes)
        switch await store.page(
            conversationID: conversationID,
            runID: context.runID,
            callID: callID,
            offset: offset,
            maxBytes: maxBytes
        ) {
        case .page(let page):
            let provenance = page.restoredFromDisk ? "restored-from-disk" : "live-this-process"
            let evictionNote = page.evictedCopies > 0
                ? "\nretentionNote=\(page.evictedCopies) older capture(s) for this task were evicted under the retention bound."
                : ""
            let truncatedNote = page.capture.executionReportedTruncation
                ? "\ncaptureNote=the tool itself reported truncating this output; paging cannot recover bytes that were never captured."
                : ""
            let retentionNote = page.capture.retentionTruncated
                ? "\nretentionNote=this store retained only the leading \(page.totalBytes) bytes of the captured output."
                : ""
            let persistenceNote = Self.persistenceNote(page.capture.durability)
            let contextNote = "\ncontextNote=any copy already in model context may be a compacted excerpt (provider context compaction); this page is the retained capture."
            let displayCallID = Self.displayMetadata(
                page.capture.callID,
                characters: Self.displayCallIDCharacters,
                bytes: Self.displayCallIDBytes
            )
            let displayToolName = Self.displayMetadata(
                page.capture.toolName,
                characters: Self.displayToolNameCharacters,
                bytes: Self.displayToolNameBytes
            )
            var header = "status=ok callID=\(displayCallID) tool=\(displayToolName)"
            header += " offset=\(page.offset) returnedBytes=\(page.text.utf8.count) totalBytes=\(page.totalBytes)"
            header += " nextOffset=\(page.nextOffset.map(String.init) ?? "none")"
            header += " capture=\(Self.captureState(page.capture.executionReportedTruncation, page.capture.retentionTruncated))"
            header += " provenance=\(provenance) persistence=\(Self.persistenceState(page.capture.durability))"
            return Self.output(
                header + evictionNote + truncatedNote + retentionNote + persistenceNote + contextNote
                    + "\n--- output ---\n" + page.text,
                exitStatus: 0
            )
        case .outOfRange(let totalBytes, let callID):
            return Self.output(
                "status=offsetOutOfRange callID=\(callID) totalBytes=\(totalBytes)\nUse an offset between 0 and \(max(0, totalBytes - 1)).",
                exitStatus: 0
            )
        case .missing(let callID, let reason):
            return Self.output("status=missing callID=\(callID) reason=\(reason)", exitStatus: 66)
        case .index:
            return Self.output("status=indexUnavailable", exitStatus: 66)
        }
    }

    static func captureState(_ executionReportedTruncation: Bool, _ retentionTruncated: Bool) -> String {
        switch (executionReportedTruncation, retentionTruncated) {
        case (true, true): return "executionOutputTruncated+retentionTruncated"
        case (true, false): return "executionOutputTruncated"
        case (false, true): return "retentionTruncated"
        case (false, false): return "complete"
        }
    }

    static func persistenceState(_ durability: ToolResultCapture.Durability) -> String {
        switch durability {
        case .durable: return "durable"
        case .memoryOnlyTemporary: return "memory-only-temporary"
        case .memoryOnlyNoRoot: return "memory-only-no-durable-root"
        case .durableWriteFailed: return "memory-only-write-failed"
        }
    }

    /// A disk write failure or an intentionally RAM-only conversation must be
    /// stated explicitly so the model never treats the page as a durable copy.
    static func persistenceNote(_ durability: ToolResultCapture.Durability) -> String {
        switch durability {
        case .durable:
            return ""
        case .memoryOnlyTemporary:
            return "\npersistenceNote=this is a temporary conversation; the captured result is RAM-only and is discarded with the conversation."
        case .memoryOnlyNoRoot:
            return "\npersistenceNote=this process does not persist captured results; the page will not survive a restart."
        case .durableWriteFailed:
            return "\npersistenceNote=the durable copy could not be written; this page is the in-memory copy and will not survive a restart."
        }
    }

    /// Display-only metadata sanitisation: control characters become `?` so a
    /// captured tool name cannot inject header lines, then the field is
    /// clipped by both characters and UTF-8 bytes. The store's lookup identity
    /// is never changed by this.
    static func displayMetadata(_ value: String, characters: Int, bytes: Int) -> String {
        let sanitized = String(value.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar.value == 0x7f { return "?" }
            return Character(scalar)
        })
        var clipped = String(sanitized.prefix(max(0, characters)))
        if clipped.utf8.count > bytes {
            clipped = ToolResultCaptureStore.utf8Prefix(clipped, maxBytes: bytes)
        }
        return clipped
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        // The page is <= 32,000 bytes and every display-only metadata field is
        // bounded above, so the full render is strictly below this cap and the
        // reported nextOffset can never point past undelivered bytes. The
        // assertion makes a future unbounded field fail in tests instead of
        // silently truncating the page tail.
        assert(text.utf8.count <= maximumRenderedBytes,
               "tools.readResult render exceeded its byte envelope")
        return ToolExecutionOutput(
            digesting: text,
            exitStatus: exitStatus,
            maximumSummaryCharacters: maximumRenderedBytes
        )
    }
}
