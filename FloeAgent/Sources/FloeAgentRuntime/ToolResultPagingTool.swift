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
        public var ref: String?
        public var offset: Int?
        /// Exact number of bytes requested from `offset`. Omitted means the
        /// bounded `maxBytes` window.
        public var length: Int?
        public var maxBytes: Int?
        /// Literal search over this task's retained captures.
        public var query: String?

        public init(
            callID: String? = nil,
            ref: String? = nil,
            offset: Int? = nil,
            length: Int? = nil,
            maxBytes: Int? = nil,
            query: String? = nil
        ) {
            self.callID = callID
            self.ref = ref
            self.offset = offset
            self.length = length
            self.maxBytes = maxBytes
            self.query = query
        }
    }

    public static let name = "tools.readResult"
    public static let toolDescription =
        "Read a bounded range of a tool result captured for this task, or search all retained results. Use it after context compaction hides part of an earlier output, or to page through a result the tool marked as truncated. Every result has a stable ref (also in the index); `ref` reads exactly that occurrence, while a bare callID resolves the current run first and then the same task's earlier run (useful after resume or from a delegated child). Omit both to list retained results for the whole task. `query` performs a literal search and returns refs plus match offsets. Reads never re-run the tool and never fabricate output for an evicted or unretained result. A page is returned byte-complete with nextOffset/endOffset so the caller can continue; paging pages are never summarized again."
    public static let parametersJSON = #"""
    {"type":"object","properties":{
      "ref":{"type":"string","description":"Stable capture ref (tr_...) from an earlier index page or result note."},
      "callID":{"type":"string","description":"Tool-call id to read. The current run wins, then an earlier run of the same task."},
      "query":{"type":"string","description":"Literal text to search across this task's retained tool results. Returns refs and byte offsets."},
      "offset":{"type":"integer","minimum":0,"description":"UTF-8 byte offset into the captured text (default 0)."},
      "length":{"type":"integer","minimum":1,"maximum":32000,"description":"Exact bytes to return from offset (default: maxBytes window)."},
      "maxBytes":{"type":"integer","minimum":256,"maximum":32000,"description":"Maximum bytes in this page (default 12000)."}},
     "additionalProperties":false}
    """#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly
    /// Paging is runtime metadata over the SAME task's already-redacted
    /// captures, so a delegated child of that task may read them too. The
    /// runtime still resolves the owning conversation itself; no child or
    /// model argument can widen the scope.
    public static let executionBoundary: ToolExecutionBoundary = .any
    public static let supportsConcurrentBatchDispatch = true

    public static let defaultMaxBytes = 12_000
    public static let maximumPageBytes = 32_000
    public static let maximumCallIDCharacters = 200
    /// The whole rendered view (metadata + notes + page) must stay below the
    /// result cap the runtime gives this tool. The page is at most 32,000
    /// bytes and every displayed metadata field is bounded, so this is a
    /// derived ceiling rather than a hope: 32,000 + bounded header/notes.
    public static let maximumRenderedBytes = 40 * 1024
    public static let displayCallIDCharacters = 200
    public static let displayCallIDBytes = 800
    public static let displayRefCharacters = 32
    public static let displayToolNameCharacters = 96
    public static let displayToolNameBytes = 384
    public static let displayQueryCharacters = 120
    public static let displayQueryBytes = 360

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
        if let ref = args.ref {
            let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ToolResultCaptureStore.isGeneratedReference(trimmed) else {
                throw FloeError.validationFailed(
                    "ref must be a generated capture ref (tr_ followed by 24 lowercase hex characters)"
                )
            }
        }
        if let offset = args.offset, offset < 0 {
            throw FloeError.validationFailed("offset must be >= 0")
        }
        if let length = args.length,
           length < 1 || length > Self.maximumPageBytes {
            throw FloeError.validationFailed("length must be between 1 and \(Self.maximumPageBytes)")
        }
        if let maxBytes = args.maxBytes, maxBytes < 256 || maxBytes > Self.maximumPageBytes {
            throw FloeError.validationFailed("maxBytes must be between 256 and \(Self.maximumPageBytes)")
        }
        if let query = args.query {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.count <= Self.displayQueryCharacters,
                  trimmed.utf8.count <= Self.displayQueryBytes,
                  trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f }) else {
                throw FloeError.validationFailed(
                    "query must be printable text no longer than \(Self.displayQueryCharacters) characters"
                )
            }
        }
        // One intent per call: a search is not combined with an offset read.
        if args.query != nil,
           args.callID != nil || args.ref != nil || args.offset != nil || args.length != nil {
            throw FloeError.validationFailed("query cannot be combined with callID/ref/offset/length")
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
        if let query = args.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
            let read = await store.search(
                conversationID: conversationID,
                query: query,
                limit: 10,
                maximumCaptures: 32,
                maximumBytes: 8 * 1024 * 1024
            )
            guard case .search(let result) = read else {
                return Self.output("status=searchUnavailable", exitStatus: 66)
            }
            var lines = [
                "status=ok mode=search query=\(Self.displayMetadata(query, characters: Self.displayQueryCharacters, bytes: Self.displayQueryBytes))"
                    + " hits=\(result.hits.count) searched=\(result.searchedCaptures) searchedBytes=\(result.searchedBytes)"
                    + " truncated=\(result.truncated ? "true" : "false")"
            ]
            if result.hits.isEmpty {
                lines.append("No retained tool result in this task contains that literal text. Do not assume the tool never ran; the capture may be absent or evicted.")
            } else {
                lines.append("Matches (newest first). Read exact bytes with ref plus offset:")
                for hit in result.hits {
                    let displayCallID = Self.displayMetadata(
                        hit.callID,
                        characters: Self.displayCallIDCharacters,
                        bytes: Self.displayCallIDBytes
                    )
                    let displayTool = Self.displayMetadata(
                        hit.toolName,
                        characters: Self.displayToolNameCharacters,
                        bytes: Self.displayToolNameBytes
                    )
                    lines.append("ref=\(hit.ref) run=\(hit.runID.uuidString) callID=\(displayCallID) tool=\(displayTool)"
                        + " totalBytes=\(hit.totalBytes) matchOffset=\(hit.matchOffset)"
                        + " more=\(hit.hasAdditionalMatches ? "true" : "false")")
                    lines.append("  excerpt: \(Self.displayMetadata(hit.excerpt, characters: 600, bytes: 1_800))")
                }
            }
            if result.truncated {
                lines.append("SearchNote=the scan stopped at a bound before examining every retained capture.")
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        }
        let explicitRef = args.ref?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitCallID = args.callID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (explicitRef?.isEmpty == false) || (explicitCallID?.isEmpty == false) else {
            let index = await store.taskIndex(conversationID: conversationID, limit: 20)
            guard case .index(let rows, let evicted) = index else {
                return Self.output("status=indexUnavailable", exitStatus: 66)
            }
            var lines = ["status=ok mode=index retained=\(rows.count) evicted=\(evicted)"]
            if rows.isEmpty {
                lines.append("No retained tool results for this task. Older captures are not recreated; re-run a tool only if repeating its side effects is safe.")
            } else {
                lines.append("Retained results for this task (newest first):")
                for row in rows {
                    // Metadata is display-only and bounded: captured names can
                    // originate dynamic MCP descriptors, so a huge name must
                    // not consume the rendered budget. Lookup identity stays
                    // the raw stored ref/call id.
                    let displayCallID = Self.displayMetadata(
                        row.callID,
                        characters: Self.displayCallIDCharacters,
                        bytes: Self.displayCallIDBytes
                    )
                    let displayTool = Self.displayMetadata(
                        row.toolName,
                        characters: Self.displayToolNameCharacters,
                        bytes: Self.displayToolNameBytes
                    )
                    lines.append("ref=\(row.ref) run=\(row.runID.uuidString) callID=\(displayCallID) tool=\(displayTool)"
                        + " bytes=\(row.totalBytes) capture=\(Self.captureState(row.executionReportedTruncation, row.retentionTruncated))"
                        + " persistence=\(Self.persistenceState(row.durability))"
                        + " capturedAt=\(ISO8601DateFormatter().string(from: row.capturedAt))")
                }
                lines.append("Read one with ref (or callID) plus optional offset/length/maxBytes.")
            }
            return Self.output(lines.joined(separator: "\n"), exitStatus: 0)
        }
        let offset = max(0, args.offset ?? 0)
        // An explicit `length` is honored down to one byte; `maxBytes` keeps
        // its 256-byte floor. Both stay under the page envelope.
        let requestedBytes = args.length ?? args.maxBytes ?? Self.defaultMaxBytes
        let floor = args.length == nil ? 256 : 1
        let maxBytes = min(max(floor, requestedBytes), Self.maximumPageBytes)
        let read: ToolResultCaptureRead
        if let ref = explicitRef, !ref.isEmpty {
            read = await store.page(
                conversationID: conversationID,
                ref: ref,
                offset: offset,
                maxBytes: maxBytes
            )
        } else {
            read = await store.page(
                conversationID: conversationID,
                runID: context.runID,
                callID: explicitCallID ?? "",
                offset: offset,
                maxBytes: maxBytes
            )
        }
        switch read {
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
            var header = "status=ok ref=\(page.ref) run=\(page.runID.uuidString) callID=\(displayCallID) tool=\(displayToolName)"
            header += " offset=\(page.offset) returnedBytes=\(page.text.utf8.count) endOffset=\(page.endOffset) totalBytes=\(page.totalBytes)"
            header += " nextOffset=\(page.nextOffset.map(String.init) ?? "none")"
            header += " capture=\(Self.captureState(page.capture.executionReportedTruncation, page.capture.retentionTruncated))"
            header += " provenance=\(provenance) persistence=\(Self.persistenceState(page.capture.durability))"
            return Self.output(
                header + evictionNote + truncatedNote + retentionNote + persistenceNote + contextNote
                    + "\n--- output ---\n" + page.text,
                exitStatus: 0
            )
        case .outOfRange(let totalBytes, let identity):
            return Self.output(
                "status=offsetOutOfRange ref=\(identity) totalBytes=\(totalBytes)\nUse an offset between 0 and \(max(0, totalBytes - 1)).",
                exitStatus: 0
            )
        case .missing(let identity, let reason):
            return Self.output("status=missing ref=\(identity) reason=\(reason)", exitStatus: 66)
        case .index:
            return Self.output("status=indexUnavailable", exitStatus: 66)
        case .search:
            return Self.output("status=searchUnavailable", exitStatus: 66)
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
