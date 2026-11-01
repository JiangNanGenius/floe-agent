// SPDX-License-Identifier: MPL-2.0
//
// C02 — bounded, post-redaction retention of real tool results.
//
// This is the value layer for the generic result capture contract ported from
// the fixed iOS donor (a59b4d40, ToolResultCaptureStore/ToolResultPagingTool).
// It intentionally carries no database, session, job or interpreter authority:
// bytes live under the app's existing artifact root, and ownership is the
// trusted task/run/call tuple supplied by the runtime.
import Foundation
import FloeCore

/// One captured tool result. `text` is the post-redaction output the tool
/// layer actually produced; it is never a reread of raw logs, argv,
/// environment or a workspace file.
public struct ToolResultCapture: Sendable, Equatable {
    /// Where the bytes backing a read live. Only `.durable` survives a process
    /// restart; every other state is reported at read time instead of being
    /// presented as persistence.
    public enum Durability: String, Sendable, Codable, Equatable {
        /// Temporary conversation: intentionally RAM-only.
        case memoryOnlyTemporary
        /// Ordinary conversation, but this runtime had no durable root.
        case memoryOnlyNoRoot
        /// Written atomically under the app-owned per-task directory.
        case durable
        /// A durable write was attempted and failed; this RAM copy is the only
        /// one and will not survive a restart.
        case durableWriteFailed
    }

    public var conversationID: UUID
    public var runID: UUID
    public var callID: String
    public var toolName: String
    public var status: String
    public var text: String
    /// The tool itself reported that it truncated its own output, so the
    /// retained text is not the complete execution result.
    public var executionReportedTruncation: Bool
    /// This store kept only the leading bytes of `text` at capture time.
    public var retentionTruncated: Bool
    public var capturedAt: Date
    public var durability: Durability
    /// SHA-256 of the retained (possibly retention-truncated) text. This is
    /// the digest a paged reassembly must reproduce.
    public var sha256: String
    /// SHA-256 reported by the tool for the complete pre-capture output, when
    /// the producer supplied one. It is metadata only: bytes the producer
    /// already dropped are never claimed recoverable.
    public var originalDigest: String?

    /// Deterministic, non-secret ownership reference derived from the trusted
    /// run/call identities (never from text). A compaction summary, a later
    /// turn, a resumed run or a delegated child of the same task can name the
    /// exact bytes without inventing a lookup key.
    public var ref: String {
        ToolResultCaptureStore.reference(runID: runID, callID: callID)
    }

    public init(
        conversationID: UUID,
        runID: UUID,
        callID: String,
        toolName: String,
        status: String,
        text: String,
        executionReportedTruncation: Bool,
        retentionTruncated: Bool,
        capturedAt: Date,
        durability: Durability,
        sha256: String,
        originalDigest: String? = nil
    ) {
        self.conversationID = conversationID
        self.runID = runID
        self.callID = callID
        self.toolName = toolName
        self.status = status
        self.text = text
        self.executionReportedTruncation = executionReportedTruncation
        self.retentionTruncated = retentionTruncated
        self.capturedAt = capturedAt
        self.durability = durability
        self.sha256 = sha256
        self.originalDigest = originalDigest
    }
}

/// Honest result of one retention attempt. `retained == false` means paging
/// cannot recover these bytes later; the caller must say so instead of
/// promising a readable copy.
public struct ToolResultCaptureReceipt: Sendable, Equatable {
    public enum Outcome: String, Sendable, Equatable {
        case retained
        /// No trusted conversation identity existed, so nothing was owned.
        case noTaskBinding
        /// The task was already deleted/fenced; retaining would resurrect it.
        case taskFenced
        /// The call id was empty or outside the addressable bounds.
        case invalidCallID
        /// The text could not be retained under the task byte/count bound.
        case evictedImmediately
    }

    public var outcome: Outcome
    public var ref: String
    public var runID: UUID?
    public var callID: String
    public var totalBytes: Int
    public var retainedBytes: Int
    public var retentionTruncated: Bool
    public var executionReportedTruncation: Bool
    public var durability: ToolResultCapture.Durability?
    public var sha256: String?
    public var originalDigest: String?
    public var retained: Bool { outcome == .retained }

    public init(
        outcome: Outcome,
        ref: String,
        runID: UUID?,
        callID: String,
        totalBytes: Int,
        retainedBytes: Int,
        retentionTruncated: Bool,
        executionReportedTruncation: Bool,
        durability: ToolResultCapture.Durability?,
        sha256: String? = nil,
        originalDigest: String? = nil
    ) {
        self.outcome = outcome
        self.ref = ref
        self.runID = runID
        self.callID = callID
        self.totalBytes = totalBytes
        self.retainedBytes = retainedBytes
        self.retentionTruncated = retentionTruncated
        self.executionReportedTruncation = executionReportedTruncation
        self.durability = durability
        self.sha256 = sha256
        self.originalDigest = originalDigest
    }
}

/// A bounded index row for one retained result.
public struct ToolResultCaptureSummary: Sendable, Equatable {
    public var ref: String
    public var runID: UUID
    public var callID: String
    public var toolName: String
    public var totalBytes: Int
    public var executionReportedTruncation: Bool
    public var retentionTruncated: Bool
    public var capturedAt: Date
    public var durability: ToolResultCapture.Durability
    public var sha256: String
    public var originalDigest: String?

    public init(
        ref: String, runID: UUID, callID: String, toolName: String,
        totalBytes: Int, executionReportedTruncation: Bool,
        retentionTruncated: Bool, capturedAt: Date,
        durability: ToolResultCapture.Durability, sha256: String,
        originalDigest: String? = nil
    ) {
        self.ref = ref
        self.runID = runID
        self.callID = callID
        self.toolName = toolName
        self.totalBytes = totalBytes
        self.executionReportedTruncation = executionReportedTruncation
        self.retentionTruncated = retentionTruncated
        self.capturedAt = capturedAt
        self.durability = durability
        self.sha256 = sha256
        self.originalDigest = originalDigest
    }
}

public enum ToolResultCaptureRead: Sendable, Equatable {
    public struct Page: Sendable, Equatable {
        public var capture: ToolResultCapture
        public var ref: String
        public var runID: UUID
        public var offset: Int
        /// Exclusive end of this page in UTF-8 bytes. `nextOffset` equals
        /// `endOffset` when more bytes exist and is nil at the end.
        public var endOffset: Int
        public var text: String
        public var totalBytes: Int
        public var nextOffset: Int?
        /// The bytes came from the durable per-task directory (for example
        /// after a restart) rather than this process's RAM.
        public var restoredFromDisk: Bool
        /// How many captures with the same call id were evicted from RAM
        /// before this read (informational only).
        public var evictedCopies: Int
    }

    public struct SearchHit: Sendable, Equatable {
        public var ref: String
        public var runID: UUID
        public var callID: String
        public var toolName: String
        public var totalBytes: Int
        /// UTF-8 byte offset of the first occurrence in the retained text.
        public var matchOffset: Int
        /// A bounded excerpt around the match (never the whole multi-MB body).
        public var excerpt: String
        /// More occurrences of this query exist in this capture.
        public var hasAdditionalMatches: Bool
        public var sha256: String
    }

    public struct SearchResult: Sendable, Equatable {
        public var hits: [SearchHit]
        public var searchedCaptures: Int
        public var searchedBytes: Int
        /// The search stopped at a bound before examining every retained
        /// capture; the result is honest about being partial.
        public var truncated: Bool
    }

    case page(Page)
    case outOfRange(totalBytes: Int, callID: String)
    case changed(callID: String, expectedSHA256: String, actualSHA256: String)
    /// Nothing retained for this ref/call id in this task. `reason` is
    /// user-safe and states whether the value is unknown, never captured,
    /// evicted or belongs to a different task — the caller must not fabricate
    /// output.
    case missing(callID: String, reason: String)
    case index([ToolResultCaptureSummary], evicted: Int)
    case search(SearchResult)
}

/// Honest result of removing one task's captured results. Deliberately not a
/// bare Bool: a caller must be able to report whether the durable directory is
/// gone and whether a launch retry was persisted.
public struct ToolResultCapturePurgeResult: Sendable, Equatable {
    public enum Failure: String, Sendable, Equatable {
        /// The task directory exists but could not be removed.
        case removalFailed
    }
    public var removedDurableDirectory: Bool
    public var failure: Failure?
    /// A retry tombstone was persisted under the store root, so the existing
    /// launch reconciliation pass can reattempt the removal.
    public var retryScheduled: Bool
    public var succeeded: Bool { failure == nil }

    public init(removedDurableDirectory: Bool, failure: Failure?, retryScheduled: Bool) {
        self.removedDurableDirectory = removedDurableDirectory
        self.failure = failure
        self.retryScheduled = retryScheduled
    }
}

/// Display-only metadata sanitisation shared by the paging tool and the host
/// bridge: control characters become `?` so captured tool output cannot forge
/// a header line, then the field is clipped by characters and UTF-8 bytes.
/// Lookup identity is never changed by this.
public enum ToolResultDisplay {
    public static func metadata(_ value: String, characters: Int, bytes: Int) -> String {
        let sanitized = String(value.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x20 || scalar.value == 0x7f { return "?" }
            return Character(scalar)
        })
        var clipped = String(sanitized.prefix(max(0, characters)))
        if clipped.utf8.count > bytes {
            clipped = ToolResultUTF8.prefix(clipped, maxBytes: bytes)
        }
        return clipped
    }
}

public enum ToolResultUTF8 {
    /// Longest whole-scalar prefix fitting `maxBytes` UTF-8 bytes.
    public static func prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var bytes = Array(text.utf8.prefix(maxBytes))
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }

    /// Longest whole-scalar window starting at a UTF-8 byte offset.
    public static func window(_ text: String, offset: Int, maxBytes: Int) -> String {
        let view = text.utf8
        guard offset >= 0, offset < view.count, maxBytes > 0 else { return "" }
        let start = view.index(view.startIndex, offsetBy: offset)
        let end = view.index(start, offsetBy: maxBytes, limitedBy: view.endIndex) ?? view.endIndex
        var bytes = Array(view[start..<end])
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeLast()
        }
        return ""
    }

    /// Longest whole-scalar suffix fitting `maxBytes` UTF-8 bytes.
    public static func suffix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0, text.utf8.count > maxBytes else {
            return maxBytes > 0 ? text : ""
        }
        let view = text.utf8
        let start = view.index(view.endIndex, offsetBy: -maxBytes)
        var bytes = Array(view[start...])
        while !bytes.isEmpty {
            if let value = String(bytes: bytes, encoding: .utf8) { return value }
            bytes.removeFirst()
        }
        return ""
    }
}
