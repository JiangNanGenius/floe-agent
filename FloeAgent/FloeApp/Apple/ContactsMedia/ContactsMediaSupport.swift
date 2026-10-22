// FloeApp — shared bounded-result support for Contacts and local media.
//
// SPDX-License-Identifier: MPL-2.0
//
// The two Apple reads in this folder share one task-owned, RAM-only snapshot
// store and one bounded request runner. Nothing in this file writes personal
// data to disk, logs it, or turns an empty system result into a permission
// claim. Cursors are opaque, task-owned and expire; contact snapshots are
// additionally namespaced by the observed Contacts authorization epoch so a
// limited-selection change cannot continue serving rows from the old scope.

#if canImport(UIKit)
import Foundation
import UIKit
import FloeCore
import FloeTools

enum ContactsMediaForeground {
    static func isActive() async -> Bool {
        await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
    }
}

enum ContactsMediaOutput {
    /// Keep a page plus its header inside the runtime's 4096-character tool
    /// summary budget. The cursor is chosen after the rows are sliced, so the
    /// emitted counts always describe exactly the visible rows.
    static let characterBudget = 4_000
    static let headerReserve = 512
    static let snapshotTTL: TimeInterval = 300
    static let maxSnapshotRows = 500

    static func make(_ text: String, exitStatus: Int32 = 0) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }

    static func page(header: String, page: PersonalToolPage) -> ToolExecutionOutput {
        guard !page.lines.isEmpty else { return make(header) }
        return make(header + "\n" + page.lines.joined(separator: "\n"))
    }

    static func iso(_ date: Date?) -> String {
        guard let date else { return "none" }
        return ISO8601DateFormatter().string(from: date)
    }
}

enum ContactsMediaText {
    static func bounded(_ value: String, limit: Int) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(max(0, limit)))
    }

    /// One quoted, escaped field. The quotes make the row self-describing even
    /// when a contact has spaces or separators in a name or organization.
    static func quoted(_ value: String, limit: Int) -> String {
        let escaped = bounded(value, limit: limit)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func quotedList(_ values: [String], itemLimit: Int, totalLimit: Int) -> String {
        let joined = values
            .prefix(3)
            .map { bounded($0, limit: itemLimit) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        return quoted(joined, limit: totalLimit)
    }

    static func boundedRow(_ line: String, limit: Int) -> String {
        guard line.count > limit else { return line }
        return String(line.prefix(max(0, limit - 16))) + "…[row truncated]"
    }
}

/// Exactly-once result gate for system authorization requests. The system
/// prompt cannot be cancelled programmatically, so a cancelled/timed-out
/// caller returns without reading data and a later user choice only finishes
/// this gate: no continuation is resumed twice and no data path is retried.
final class ContactsMediaOnceGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var result: Result<Value, any Error>?

    func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        let ready: Result<Value, any Error>?
        lock.lock()
        if let result {
            ready = result
        } else {
            ready = nil
            self.continuation = continuation
        }
        lock.unlock()
        if let ready { continuation.resume(with: ready) }
    }

    func finish(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

enum ContactsMediaRequestError: Error, Equatable, Sendable, LocalizedError {
    case cancelled
    case timedOut

    var errorDescription: String? {
        switch self {
        case .cancelled: "The request was cancelled."
        case .timedOut: "The request timed out."
        }
    }
}

enum ContactsMediaRequestRunner {
    /// Runs one system authorization request with a cancellation poll and a
    /// hard deadline. The OS prompt itself may outlive the call; this runner
    /// never lets its late answer resume a finished tool call.
    static func run<Value: Sendable>(
        cancellation: CancellationToken,
        timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        if cancellation.isCancelled { throw ContactsMediaRequestError.cancelled }
        let gate = ContactsMediaOnceGate<Value>()
        let worker = Task {
            do {
                gate.finish(.success(try await operation()))
            } catch {
                gate.finish(.failure(error))
            }
        }
        let watcher = Task {
            let deadline = Date().addingTimeInterval(max(1, timeout))
            while true {
                if cancellation.isCancelled {
                    gate.finish(.failure(ContactsMediaRequestError.cancelled))
                    worker.cancel()
                    return
                }
                if Date() >= deadline {
                    gate.finish(.failure(ContactsMediaRequestError.timedOut))
                    worker.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        defer {
            watcher.cancel()
            worker.cancel()
        }
        return try await withCheckedThrowingContinuation { continuation in
            gate.attach(continuation)
        }
    }
}

/// Bounded, task-owned RAM snapshots for Contacts rows and local-media search
/// rows. This deliberately lives beside the two readers instead of extending
/// the shared Calendar/Health cursor store: Contacts cursors must be
/// invalidated as a group when authorization scope changes, and contact rows
/// must never be written to disk.
actor ContactsMediaSnapshotStore {
    static let shared = ContactsMediaSnapshotStore()

    private struct Snapshot {
        var owner: PersonalToolOwnerID
        var kind: String
        var filterKey: String
        var createdAt: Date
        var expiresAt: Date
        var lines: [String]
        var truncated: Bool
    }

    private struct CursorPayload: Codable {
        var v: Int
        var id: UUID
        var o: Int
    }

    private let maxSnapshots: Int
    private let maxLinesPerSnapshot: Int
    private let ttl: TimeInterval
    private var snapshots: [UUID: Snapshot] = [:]

    init(
        maxSnapshots: Int = 24,
        maxLinesPerSnapshot: Int = ContactsMediaOutput.maxSnapshotRows,
        ttl: TimeInterval = ContactsMediaOutput.snapshotTTL
    ) {
        self.maxSnapshots = max(1, maxSnapshots)
        self.maxLinesPerSnapshot = max(1, maxLinesPerSnapshot)
        self.ttl = max(1, ttl)
    }

    func begin(
        kind: String,
        filterKey: String,
        lines: [String],
        owner: PersonalToolOwnerID,
        pageSize: Int,
        truncated: Bool = false,
        characterBudget: Int = ContactsMediaOutput.characterBudget,
        reservedHeaderCharacters: Int = ContactsMediaOutput.headerReserve,
        now: Date = Date()
    ) throws -> PersonalToolPage {
        pruneExpired(now: now)
        guard snapshots.count < maxSnapshots else { throw PersonalToolCursorError.resourceLimit }
        let rowsTruncated = lines.count > maxLinesPerSnapshot
        let stored = rowsTruncated ? Array(lines.prefix(maxLinesPerSnapshot)) : lines
        let id = UUID()
        let snapshot = Snapshot(
            owner: owner,
            kind: kind,
            filterKey: filterKey,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            lines: stored,
            truncated: truncated || rowsTruncated
        )
        snapshots[id] = snapshot
        return page(
            snapshot: snapshot,
            id: id,
            offset: 0,
            pageSize: pageSize,
            characterBudget: characterBudget,
            reservedHeaderCharacters: reservedHeaderCharacters
        )
    }

    func next(
        cursor: String,
        owner: PersonalToolOwnerID,
        kind: String,
        filterKey: String?,
        pageSize: Int,
        characterBudget: Int = ContactsMediaOutput.characterBudget,
        reservedHeaderCharacters: Int = ContactsMediaOutput.headerReserve,
        now: Date = Date()
    ) throws -> PersonalToolPage {
        guard let payload = Self.decode(cursor), payload.v == 1, payload.o >= 0 else {
            throw PersonalToolCursorError.malformed
        }
        guard let snapshot = snapshots[payload.id] else {
            throw PersonalToolCursorError.unknown
        }
        guard snapshot.owner.matches(owner) else {
            throw PersonalToolCursorError.notOwned
        }
        guard snapshot.kind == kind else { throw PersonalToolCursorError.filterMismatch }
        if let filterKey, filterKey != snapshot.filterKey {
            throw PersonalToolCursorError.filterMismatch
        }
        guard now < snapshot.expiresAt else {
            snapshots.removeValue(forKey: payload.id)
            throw PersonalToolCursorError.expired(snapshotTime: snapshot.createdAt)
        }
        guard payload.o <= snapshot.lines.count else { throw PersonalToolCursorError.unknown }
        return page(
            snapshot: snapshot,
            id: payload.id,
            offset: payload.o,
            pageSize: pageSize,
            characterBudget: characterBudget,
            reservedHeaderCharacters: reservedHeaderCharacters
        )
    }

    /// Drops every snapshot of one concrete kind namespace. Contacts uses an
    /// authorization-epoch suffix, so this also clears cursors issued under an
    /// older limited/full scope after an authorization change.
    func invalidateKindPrefix(_ prefix: String) {
        snapshots = snapshots.filter { !$0.value.kind.hasPrefix(prefix) }
    }

    func revoke(owner: PersonalToolOwnerID) {
        snapshots = snapshots.filter { !$0.value.owner.matches(owner) }
    }

    func liveSnapshotCount() -> Int {
        snapshots.count
    }

    private func pruneExpired(now: Date) {
        snapshots = snapshots.filter { $0.value.expiresAt > now }
    }

    private func page(
        snapshot: Snapshot,
        id: UUID,
        offset: Int,
        pageSize: Int,
        characterBudget: Int,
        reservedHeaderCharacters: Int
    ) -> PersonalToolPage {
        let total = snapshot.lines.count
        let start = min(max(0, offset), total)
        let clampedPageSize = min(max(1, pageSize), 200)
        let remainingBudget = max(0, characterBudget - max(0, reservedHeaderCharacters))
        var lines: [String] = []
        var truncatedRows = 0
        var used = 0
        var index = start
        while index < total, lines.count < clampedPageSize {
            let line = snapshot.lines[index]
            let separator = lines.isEmpty ? 0 : 1
            if used + separator + line.count <= remainingBudget {
                lines.append(line)
                used += separator + line.count
                index += 1
                continue
            }
            if lines.isEmpty {
                let marker = "…[row truncated]"
                let allowance = max(0, remainingBudget - separator - marker.count)
                let bounded = String(line.prefix(allowance)) + marker
                lines.append(bounded)
                truncatedRows += 1
                used = separator + bounded.count
                index += 1
            }
            break
        }
        let hasMore = index < total
        let emitted = max(1, lines.count)
        return PersonalToolPage(
            lines: lines,
            returnedCount: lines.count,
            totalCount: total,
            hasMore: hasMore,
            nextCursor: hasMore ? Self.encode(CursorPayload(v: 1, id: id, o: index)) : nil,
            pageCount: total == 0 ? 0 : (total + emitted - 1) / emitted,
            snapshotTime: snapshot.createdAt,
            completeness: snapshot.truncated ? "truncated" : "complete",
            truncatedRows: truncatedRows
        )
    }

    private static func encode(_ payload: CursorPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload) else { return "" }
        return "cmc1." + base64URL(data)
    }

    private static func decode(_ token: String) -> CursorPayload? {
        guard token.hasPrefix("cmc1.") else { return nil }
        let encoded = String(token.dropFirst("cmc1.".count))
        guard let data = base64URLDecode(encoded) else { return nil }
        return try? JSONDecoder().decode(CursorPayload.self, from: data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        return Data(base64Encoded: text)
    }
}
#endif
