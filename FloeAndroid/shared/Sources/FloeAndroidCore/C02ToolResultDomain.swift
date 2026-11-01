// SPDX-License-Identifier: MPL-2.0
//
// C02 — trusted task/run result paging domain.
//
// The capture bytes and the model paging tool live in
// FloeAndroidToolResults. This file is the app-facing typed service used by
// the reserved trusted-host channel `floe.results/20`; it never exposes raw
// filesystem paths, credentials or another task's bytes. Ownership is the
// task UUID supplied by the trusted host UI or the runtime's ToolContext, not
// by model arguments.
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeAndroidToolResults

public enum C02ToolResultWire {
    /// Reserved trusted-host channel. Main owns the C ABI/bridge branch.
    public static let version = 20
    public static let schema = "floe.results/20"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 48 * 1_024
    public static let maximumPageBytes = ToolResultPagingTool.maximumPageBytes
    public static let defaultPageBytes = ToolResultPagingTool.defaultMaxBytes
    public static let maximumIndexRows = 20
    public static let maximumSearchHits = 10
    public static let maximumSearchExcerptBytes = 1_800
    public static let maximumTaskIDBytes = 64
    public static var modelToolName: String { ToolResultPagingTool.name }
}

public enum C02ToolResultError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case unsupportedOperation
    case temporaryTaskRefused
    case rootEpochUnavailable
    case notInstalled
    case timedOut
    case cancelled

    /// Stable machine-facing reason used by the trusted-host wire. Never
    /// includes a path, command, credential or captured content.
    public var code: String {
        switch self {
        case .invalidRequest(let reason): return "invalidRequest:\(reason)"
        case .unsupportedOperation: return "unsupportedOperation"
        case .temporaryTaskRefused: return "temporaryTaskRefused"
        case .rootEpochUnavailable: return "rootEpochUnavailable"
        case .notInstalled: return "notInstalled"
        case .timedOut: return "timedOut"
        case .cancelled: return "cancelled"
        }
    }

    public var message: String {
        switch self {
        case .invalidRequest(let reason):
            return "The result read request is invalid (\(reason))."
        case .unsupportedOperation:
            return "This result read operation is not supported."
        case .temporaryTaskRefused:
            return "Temporary chats are RAM-only and cannot read persistent tool results."
        case .rootEpochUnavailable:
            return "The native runtime generation that owns these results is no longer live."
        case .notInstalled:
            return "Tool result retention is not bound for this runtime generation."
        case .timedOut:
            return "The result read did not settle in time."
        case .cancelled:
            return "The result read was cancelled."
        }
    }

    public var retryable: Bool {
        switch self {
        case .timedOut, .rootEpochUnavailable: return true
        default: return false
        }
    }
}

public struct C02ToolResultIndexRow: Sendable, Equatable {
    public var ref: String
    public var runID: UUID
    public var callID: String
    public var toolName: String
    public var totalBytes: Int
    public var executionReportedTruncation: Bool
    public var retentionTruncated: Bool
    public var capturedAt: Date
    public var durability: String
    public var sha256: String
    public var originalDigest: String?

    public init(
        ref: String, runID: UUID, callID: String, toolName: String,
        totalBytes: Int, executionReportedTruncation: Bool,
        retentionTruncated: Bool, capturedAt: Date, durability: String,
        sha256: String, originalDigest: String?
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

public struct C02ToolResultPageValue: Sendable, Equatable {
    public var ref: String
    public var runID: UUID
    public var callID: String
    public var toolName: String
    public var status: String
    public var offset: Int
    public var endOffset: Int
    public var nextOffset: Int?
    public var totalBytes: Int
    public var text: String
    public var sha256: String
    public var originalDigest: String?
    public var executionReportedTruncation: Bool
    public var retentionTruncated: Bool
    public var durability: String
    public var restoredFromDisk: Bool
    public var evictedCopies: Int
    public var capturedAt: Date

    public init(
        ref: String, runID: UUID, callID: String, toolName: String, status: String,
        offset: Int, endOffset: Int, nextOffset: Int?, totalBytes: Int, text: String,
        sha256: String, originalDigest: String?, executionReportedTruncation: Bool,
        retentionTruncated: Bool, durability: String, restoredFromDisk: Bool,
        evictedCopies: Int, capturedAt: Date
    ) {
        self.ref = ref
        self.runID = runID
        self.callID = callID
        self.toolName = toolName
        self.status = status
        self.offset = offset
        self.endOffset = endOffset
        self.nextOffset = nextOffset
        self.totalBytes = totalBytes
        self.text = text
        self.sha256 = sha256
        self.originalDigest = originalDigest
        self.executionReportedTruncation = executionReportedTruncation
        self.retentionTruncated = retentionTruncated
        self.durability = durability
        self.restoredFromDisk = restoredFromDisk
        self.evictedCopies = evictedCopies
        self.capturedAt = capturedAt
    }
}

public struct C02ToolResultSearchHit: Sendable, Equatable {
    public var ref: String
    public var runID: UUID
    public var callID: String
    public var toolName: String
    public var totalBytes: Int
    public var matchOffset: Int
    public var excerpt: String
    public var hasAdditionalMatches: Bool
    public var sha256: String
}

public struct C02ToolResultSearchValue: Sendable, Equatable {
    public var hits: [C02ToolResultSearchHit]
    public var searchedCaptures: Int
    public var searchedBytes: Int
    public var truncated: Bool
}

public enum C02ToolResultPageOutcome: Sendable, Equatable {
    case page(C02ToolResultPageValue)
    case outOfRange(totalBytes: Int, identity: String)
    case changed(identity: String, expectedSHA256: String, actualSHA256: String)
    case missing(identity: String, reason: String)
}

/// One generation-bound service. Main constructs it through
/// `C02ToolResultIntegration.install`; it does not open a database or a second
/// storage registry.
public actor C02ToolResultService {
    private let epoch: UInt64
    private let store: ToolResultCaptureStore
    private let liveEpoch: @Sendable () -> UInt64

    public init(
        epoch: UInt64,
        store: ToolResultCaptureStore,
        liveEpoch: @escaping @Sendable () -> UInt64
    ) {
        self.epoch = epoch
        self.store = store
        self.liveEpoch = liveEpoch
    }

    public var generationEpoch: UInt64 { epoch }

    private func requireLive() throws {
        guard epoch > 0, liveEpoch() == epoch else {
            throw C02ToolResultError.rootEpochUnavailable
        }
    }

    public func index(
        taskID: UUID,
        runID: UUID? = nil,
        limit: Int = C02ToolResultWire.maximumIndexRows
    ) async throws -> (rows: [C02ToolResultIndexRow], evicted: Int) {
        try requireLive()
        let read = await store.taskIndex(
            conversationID: taskID,
            runID: runID,
            limit: min(max(1, limit), 50)
        )
        guard case .index(let summaries, let evicted) = read else {
            throw C02ToolResultError.invalidRequest("indexUnavailable")
        }
        return (summaries.map(Self.row(from:)), evicted)
    }

    public func page(
        taskID: UUID,
        ref: String?,
        callID: String?,
        runID: UUID?,
        offset: Int,
        maxBytes: Int,
        expectedSHA256: String?,
        temporary: Bool,
        exactRun: Bool = false
    ) async throws -> C02ToolResultPageOutcome {
        try requireLive()
        guard !temporary else { throw C02ToolResultError.temporaryTaskRefused }
        guard let identity = Self.firstNonEmpty(ref, callID) else {
            throw C02ToolResultError.invalidRequest("missingRefOrCallID")
        }
        guard offset >= 0 else { throw C02ToolResultError.invalidRequest("negativeOffset") }
        let bounded = min(max(1, maxBytes), C02ToolResultWire.maximumPageBytes)
        let read: ToolResultCaptureRead
        if let ref, !ref.isEmpty {
            guard ToolResultCaptureStore.isGeneratedReference(ref) else {
                throw C02ToolResultError.invalidRequest("invalidRef")
            }
            read = await store.page(
                conversationID: taskID,
                ref: ref,
                offset: offset,
                maxBytes: bounded,
                expectedSHA256: expectedSHA256
            )
        } else {
            guard let callID, !callID.isEmpty else {
                throw C02ToolResultError.invalidRequest("missingRefOrCallID")
            }
            read = await store.page(
                conversationID: taskID,
                runID: runID ?? UUID(),
                callID: callID,
                offset: offset,
                maxBytes: bounded,
                expectedSHA256: expectedSHA256,
                fallbackToTask: !exactRun
            )
        }
        switch read {
        case .page(let page):
            return .page(C02ToolResultPageValue(
                ref: page.ref,
                runID: page.runID,
                callID: page.capture.callID,
                toolName: page.capture.toolName,
                status: page.capture.status,
                offset: page.offset,
                endOffset: page.endOffset,
                nextOffset: page.nextOffset,
                totalBytes: page.totalBytes,
                text: page.text,
                sha256: page.capture.sha256,
                originalDigest: page.capture.originalDigest,
                executionReportedTruncation: page.capture.executionReportedTruncation,
                retentionTruncated: page.capture.retentionTruncated,
                durability: page.capture.durability.rawValue,
                restoredFromDisk: page.restoredFromDisk,
                evictedCopies: page.evictedCopies,
                capturedAt: page.capture.capturedAt
            ))
        case .outOfRange(let totalBytes, let callID):
            return .outOfRange(totalBytes: totalBytes, identity: callID)
        case .changed(let callID, let expected, let actual):
            return .changed(identity: callID, expectedSHA256: expected, actualSHA256: actual)
        case .missing(_, let reason):
            return .missing(identity: identity, reason: reason)
        case .index, .search:
            throw C02ToolResultError.invalidRequest("unexpectedRead")
        }
    }

    public func search(
        taskID: UUID,
        query: String,
        limit: Int = C02ToolResultWire.maximumSearchHits,
        temporary: Bool
    ) async throws -> C02ToolResultSearchValue {
        try requireLive()
        guard !temporary else { throw C02ToolResultError.temporaryTaskRefused }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 120,
              trimmed.utf8.count <= 360 else {
            throw C02ToolResultError.invalidRequest("invalidQuery")
        }
        let read = await store.search(
            conversationID: taskID,
            query: trimmed,
            limit: min(max(1, limit), 50),
            maximumCaptures: 32,
            maximumBytes: 8 * 1024 * 1024
        )
        guard case .search(let result) = read else {
            throw C02ToolResultError.invalidRequest("searchUnavailable")
        }
        return C02ToolResultSearchValue(
            hits: result.hits.map {
                C02ToolResultSearchHit(
                    ref: $0.ref,
                    runID: $0.runID,
                    callID: $0.callID,
                    toolName: $0.toolName,
                    totalBytes: $0.totalBytes,
                    matchOffset: $0.matchOffset,
                    excerpt: $0.excerpt,
                    hasAdditionalMatches: $0.hasAdditionalMatches,
                    sha256: $0.sha256
                )
            },
            searchedCaptures: result.searchedCaptures,
            searchedBytes: result.searchedBytes,
            truncated: result.truncated
        )
    }

    @discardableResult
    public func purge(taskID: UUID) async -> ToolResultCapturePurgeResult {
        await store.purge(conversationID: taskID)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty == false) ? trimmed : nil
        }.first
    }

    private static func row(from summary: ToolResultCaptureSummary) -> C02ToolResultIndexRow {
        C02ToolResultIndexRow(
            ref: summary.ref,
            runID: summary.runID,
            callID: summary.callID,
            toolName: summary.toolName,
            totalBytes: summary.totalBytes,
            executionReportedTruncation: summary.executionReportedTruncation,
            retentionTruncated: summary.retentionTruncated,
            capturedAt: summary.capturedAt,
            durability: summary.durability.rawValue,
            sha256: summary.sha256,
            originalDigest: summary.originalDigest
        )
    }
}
