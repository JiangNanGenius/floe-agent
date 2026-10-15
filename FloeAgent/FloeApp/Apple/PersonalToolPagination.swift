// FloeApp — Task-owned opaque pagination for personal-data list tools.
//
// Calendar and reminder listings take a bounded page size (default 100,
// maximum 200) and page through a STABLE snapshot bound to the query filters
// at snapshot time. The cursor is an opaque token owned by the run that
// created it:
//
//   * a different run presenting the token gets an explicit not-owned error,
//     never another task's data and never an empty success;
//   * an expired snapshot reports its snapshot time instead of silently
//     returning results from a fresh query;
//   * filter drift between pages is an explicit mismatch;
//   * the store is resource-bounded and says so instead of evicting live
//     snapshots or dropping rows silently.
//
// Foundation-only on purpose: the same file is compiled into the app target
// and exercised by the local pagination harness.

import Foundation

/// Explicit failures for paginated personal listings. Never returned as an
/// empty page.
enum PersonalToolCursorError: Error, Equatable, LocalizedError {
    /// The token is not a well-formed cursor for this store.
    case malformed
    /// The token is well-formed but no live snapshot exists for it.
    case unknown
    /// The snapshot expired; `snapshotTime` is when it was taken.
    case expired(snapshotTime: Date)
    /// The token belongs to a different task/run.
    case notOwned
    /// Filters supplied with the cursor differ from the snapshot's filters.
    case filterMismatch
    /// The store cannot hold another live snapshot right now.
    case resourceLimit

    var errorDescription: String? {
        switch self {
        case .malformed: "The pagination cursor is malformed. Start a new listing."
        case .unknown: "The pagination cursor is no longer valid. Start a new listing."
        case .expired(let snapshotTime):
            "The pagination snapshot expired. It was taken at \(ISO8601DateFormatter().string(from: snapshotTime)); start a new listing."
        case .notOwned: "The pagination cursor belongs to a different task."
        case .filterMismatch: "The pagination cursor was created with different filters. Start a new listing."
        case .resourceLimit: "Too many listings are active; finish or restart one before paging again."
        }
    }

    /// Stable, secret-free code for tool output.
    var code: String {
        switch self {
        case .malformed: "cursorMalformed"
        case .unknown: "cursorUnknown"
        case .expired: "cursorExpired"
        case .notOwned: "cursorNotOwned"
        case .filterMismatch: "cursorFilterMismatch"
        case .resourceLimit: "resourceLimit"
        }
    }
}

/// Trusted owner of a pagination snapshot. The durable conversation identity
/// (plus the environment when both sides know one) is authoritative, so a new
/// run of the SAME conversation keeps paginating while another task is
/// rejected. Runs without a conversation fall back to the run identity.
struct PersonalToolOwnerID: Sendable, Equatable {
    var conversationID: UUID?
    var environmentID: String?
    var fallbackRunID: UUID

    init(conversationID: UUID?, environmentID: String?, fallbackRunID: UUID) {
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.fallbackRunID = fallbackRunID
    }

    /// Same durable conversation (never contradicted by a different known
    /// environment) or, for conversation-less runs, the same run.
    func matches(_ other: PersonalToolOwnerID) -> Bool {
        if let lhs = conversationID, let rhs = other.conversationID {
            guard lhs == rhs else { return false }
            if let lhsEnvironment = environmentID,
               let rhsEnvironment = other.environmentID,
               lhsEnvironment != rhsEnvironment {
                return false
            }
            return true
        }
        guard conversationID == nil, other.conversationID == nil else { return false }
        return fallbackRunID == other.fallbackRunID
    }
}

/// One rendered page of a stable snapshot. `lines` are already bounded to the
/// downstream character budget, so `returnedCount`/`nextCursor` always match
/// exactly what the caller can display: the cursor advances only past emitted
/// rows and no row is skipped silently.
struct PersonalToolPage: Equatable {
    var lines: [String]
    var returnedCount: Int
    /// Total rows inside the snapshot (the snapshot itself may be truncated).
    var totalCount: Int
    var hasMore: Bool
    var nextCursor: String?
    /// Nominal page count at this page's emitted row count (a stable estimate
    /// when rows have different lengths).
    var pageCount: Int
    var snapshotTime: Date
    /// `complete` or `truncated` (snapshot hit the store's row bound).
    var completeness: String
    /// Rows whose rendered line was shortened because the row alone exceeded
    /// the character budget. The row is still emitted (with its stable IDs at
    /// the head) and the cursor advances past it.
    var truncatedRows: Int = 0
}

/// Serialized cursor page-owner. Actors guarantee single-threaded access to
/// the snapshot map.
actor PersonalToolCursorStore {
    static let shared = PersonalToolCursorStore()

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
        maxSnapshots: Int = 64,
        maxLinesPerSnapshot: Int = 2_000,
        ttl: TimeInterval = 600
    ) {
        self.maxSnapshots = max(1, maxSnapshots)
        self.maxLinesPerSnapshot = max(1, maxLinesPerSnapshot)
        self.ttl = max(1, ttl)
    }

    /// Starts a new snapshot and returns its first page. `lines` are the
    /// already-rendered, stable rows for the query; rows beyond the store
    /// bound are dropped and reported through `completeness = truncated`.
    func begin(
        kind: String,
        filterKey: String,
        lines: [String],
        owner: PersonalToolOwnerID,
        pageSize: Int,
        characterBudget: Int = 4_000,
        reservedHeaderCharacters: Int = 320,
        now: Date = Date()
    ) throws -> PersonalToolPage {
        pruneExpired(now: now)
        guard snapshots.count < maxSnapshots else { throw PersonalToolCursorError.resourceLimit }
        let clampedPageSize = Self.clampPageSize(pageSize)
        let truncated = lines.count > maxLinesPerSnapshot
        let stored = truncated ? Array(lines.prefix(maxLinesPerSnapshot)) : lines
        let id = UUID()
        let snapshot = Snapshot(
            owner: owner,
            kind: kind,
            filterKey: filterKey,
            createdAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            lines: stored,
            truncated: truncated
        )
        snapshots[id] = snapshot
        return page(
            snapshot: snapshot,
            id: id,
            offset: 0,
            pageSize: clampedPageSize,
            characterBudget: characterBudget,
            reservedHeaderCharacters: reservedHeaderCharacters
        )
    }

    /// Continues a snapshot page. The owner must match the trusted task
    /// identity that began the snapshot (same conversation across runs, or the
    /// same run); `filterKey` (when supplied) must match the snapshot's
    /// canonical filter string.
    func next(
        cursor: String,
        owner: PersonalToolOwnerID,
        kind: String,
        filterKey: String?,
        pageSize: Int,
        characterBudget: Int = 4_000,
        reservedHeaderCharacters: Int = 320,
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
            pageSize: Self.clampPageSize(pageSize),
            characterBudget: characterBudget,
            reservedHeaderCharacters: reservedHeaderCharacters
        )
    }

    /// Drops every snapshot owned by one task identity (finished/cancelled).
    func revoke(owner: PersonalToolOwnerID) {
        snapshots = snapshots.filter { !$0.value.owner.matches(owner) }
    }

    /// Drops every snapshot created by the given per-run identities. A
    /// temporary (ephemeral) session owns its snapshots per RUN — its
    /// conversation id can be reused by a later session epoch, so
    /// same-conversation matching would expose a previous session's rows.
    /// Ending the session revokes its run identities immediately instead of
    /// leaving RAM-only personal-data rows to expire on the TTL.
    func revoke(fallbackRunIDs: Set<UUID>) {
        guard !fallbackRunIDs.isEmpty else { return }
        snapshots = snapshots.filter { !fallbackRunIDs.contains($0.value.owner.fallbackRunID) }
    }

    private func pruneExpired(now: Date) {
        snapshots = snapshots.filter { $0.value.expiresAt > now }
    }

    private static func clampPageSize(_ pageSize: Int) -> Int {
        min(max(pageSize, 1), 200)
    }

    /// Slices one page under BOTH bounds: at most `pageSize` rows and at most
    /// `characterBudget - reservedHeaderCharacters` rendered characters. The
    /// cursor offset is the index of the first row NOT emitted, so a
    /// budget-shortened page advances exactly past its visible rows. A single
    /// row larger than the remaining budget is emitted truncated (stable IDs
    /// stay at the head) with `truncatedRows` reporting it; the cursor still
    /// advances, so no row is hidden and no cursor loops forever.
    private func page(
        snapshot: Snapshot,
        id: UUID,
        offset: Int,
        pageSize: Int,
        characterBudget: Int,
        reservedHeaderCharacters: Int
    ) -> PersonalToolPage {
        let total = snapshot.lines.count
        let start = min(offset, total)
        let remainingBudget = max(0, characterBudget - max(0, reservedHeaderCharacters))
        var lines: [String] = []
        var truncatedRows = 0
        var used = 0
        var index = start
        while index < total, lines.count < pageSize {
            let line = snapshot.lines[index]
            let separator = lines.isEmpty ? 0 : 1
            if used + separator + line.count <= remainingBudget {
                lines.append(line)
                used += separator + line.count
                index += 1
                continue
            }
            if lines.isEmpty {
                // The row alone exceeds the budget: deliver a bounded row with
                // an explicit marker rather than hiding it or looping.
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
            nextCursor: hasMore
                ? Self.encode(CursorPayload(v: 1, id: id, o: index))
                : nil,
            pageCount: total == 0 ? 0 : (total + emitted - 1) / emitted,
            snapshotTime: snapshot.createdAt,
            completeness: snapshot.truncated ? "truncated" : "complete",
            truncatedRows: truncatedRows
        )
    }

    private static func encode(_ payload: CursorPayload) -> String {
        guard let data = try? JSONEncoder().encode(payload) else { return "" }
        return "ptc1." + base64URL(data)
    }

    private static func decode(_ token: String) -> CursorPayload? {
        guard token.hasPrefix("ptc1.") else { return nil }
        let encoded = String(token.dropFirst("ptc1.".count))
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
