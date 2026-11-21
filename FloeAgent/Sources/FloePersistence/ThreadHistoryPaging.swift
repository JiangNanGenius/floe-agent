// FloePersistence — Shared transcript pagination state extractor.
//
// SPDX-License-Identifier: MPL-2.0
//
// THE paging/state authority for a conversation transcript, extracted verbatim
// from the iPad `ThreadDetailViewModel` hydration/merge/cursor rules so the
// native Mac workspace (and any other host) reproduces the exact same
// experience for messages, loading and actions: same persisted models, same
// keyset windows, same coverage tracking, same "earlier activity" affordance.
// This type is pure in-memory state: it never reads a store and never invents
// a second persistence format. Hosts fetch pages through their own store and
// merge them here; the merged rows and cursors are identical on every host.
//
// Window rules of record (kept in lockstep with the iPad thread):
// - Latest message window: 20 rows; "load earlier" pages 30 rows at a time.
// - A run event page reads 51 rows: 50 displayed rows plus one boundary row
//   that only answers "is there even earlier history?".
// - Merging a search hit window NEVER claims page coverage: the bounded window
//   around a hit can sit in a gap, so "Load earlier" keeps its real cursor.
// - Id membership indexes make every merge O(new rows): pages are
//   sequence/cursor ordered, so only genuinely new rows are appended
//   (earlier pages) or prepended (newer live rows).

import Foundation
import FloeCore
import FloeModels

/// Tracks the merged transcript rows plus the read coverage behind them.
///
/// Value semantics make every merge race-free to reason about: a host fences
/// the async page fetch with its own generation/selection token, and only
/// merges a page whose fence is still current, so stale rows can never land.
public struct ThreadHistoryPaging: Sendable {

    /// The merged messages of ONE conversation, chronological.
    public private(set) var messages: [PersistedMessage] = []
    /// The conversation's run headers, newest first.
    public private(set) var runs: [RunRecord] = []
    /// Persisted events per run, each in sequence order.
    public private(set) var eventsByRun: [UUID: [RunEventRecord]] = [:]
    /// Runs that have earlier events available but none loaded yet. Drives the
    /// paged "earlier activity" row; membership is recomputed from coverage on
    /// every event merge, never guessed.
    public private(set) var earlierEventRunIDs: Set<UUID> = []

    /// Id membership indexes for the paged-in rows. Merging a page no longer
    /// rebuilds a dictionary over every loaded row just to dedup.
    private var messageIDs = Set<UUID>()
    private var eventIDsByRun: [UUID: Set<UUID>] = [:]
    /// Recorded separately from row identity: merging only row IDs loses the
    /// cursor for gaps after reconnecting to a bounded live snapshot.
    private var messageCoverage = TimelinePageCoverage<ConversationMessageCursor>()
    private var eventCoverage: [UUID: TimelinePageCoverage<Int>] = [:]

    public init() {}

    /// True while an earlier message page may exist beyond the merged window.
    public var hasEarlierMessages: Bool { messageCoverage.earlierCursor != nil }

    /// The newest uncovered message boundary, nil once history is contiguous
    /// from the beginning of the conversation.
    public var earlierMessageCursor: ConversationMessageCursor? { messageCoverage.earlierCursor }

    /// The newest uncovered sequence boundary for one run, nil once every
    /// loaded page connects to the start of that run's event thread.
    public func earlierEventCursor(runID: UUID) -> Int? {
        eventCoverage[runID]?.earlierCursor
    }

    /// Drops every merged row and cursor. Called exactly when the host binds
    /// the pager to a different conversation; a reload of the SAME
    /// conversation keeps previously loaded older rows.
    public mutating func reset() {
        self = ThreadHistoryPaging()
    }

    /// Run ids with no loaded event page yet — the candidates for the
    /// "earlier activity" affordance. Pure read; hosts merge the result via
    /// `markRunsWithEarlierEvents(_:)`.
    public func runIDsMissingEvents(_ candidates: Set<UUID>) -> Set<UUID> {
        candidates.filter { eventsByRun[$0] == nil }
    }

    /// Historical messages are immediately readable; fetch their tool chains
    /// only when requested. Marks every listed run that has no event page as
    /// having earlier activity, mirroring the iPad `hydrateVisibleRunDetails`.
    public mutating func markRunsWithEarlierEvents(_ runIDs: Set<UUID>) {
        earlierEventRunIDs.formUnion(runIDsMissingEvents(runIDs))
    }

    /// Merges run headers without disturbing the newest-first order. Returns
    /// true when the visible header set changed (the iPad timeline revision
    /// bumping rule: an unchanged republished header set must not rebuild).
    @discardableResult
    public mutating func mergeRunHeaders(_ incoming: [RunRecord]) -> Bool {
        var headers = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        var changed = false
        for header in incoming where headers[header.id] != header {
            headers[header.id] = header
            changed = true
        }
        guard changed else { return false }
        runs = headers.values.sorted { ($0.startedAt, $0.id.uuidString) > ($1.startedAt, $1.id.uuidString) }
        return true
    }

    /// Merges one message page (latest page or an earlier "load earlier"
    /// page) into the chronological transcript. Returns true when new rows
    /// were added; coverage is recorded either way so `hasEarlierMessages`
    /// stays honest after duplicate-only pages.
    @discardableResult
    public mutating func mergeMessagePage(
        _ page: ConversationMessagePage,
        before: ConversationMessageCursor? = nil
    ) -> Bool {
        func cursor(_ message: PersistedMessage) -> ConversationMessageCursor {
            .init(createdAt: message.createdAt, messageID: message.id)
        }
        messageCoverage.record(
            first: page.messages.first.map(cursor),
            last: page.messages.last.map(cursor),
            before: before,
            hasEarlier: page.hasEarlier
        )
        let existing = messages
        var added: [PersistedMessage] = []
        for message in page.messages where messageIDs.insert(message.id).inserted {
            added.append(message)
        }
        guard !added.isEmpty else { return false }
        let merged: [PersistedMessage]
        if existing.isEmpty {
            merged = added
        } else if cursor(added.last!) <= cursor(existing.first!) {
            // An earlier page (or an earlier reconnect snapshot): prepend.
            merged = added + existing
        } else if cursor(existing.last!) <= cursor(added.first!) {
            // The newest page: append after everything loaded.
            merged = existing + added
        } else {
            // Out-of-order overlap after reconnect: rare; restore the exact
            // cursor order over the merged superset.
            merged = (existing + added).sorted { cursor($0) < cursor($1) }
        }
        messages = merged
        return true
    }

    /// Merges a BOUNDED window around one search hit when it is not in the
    /// current page window. Deliberately does NOT claim page coverage: there
    /// can be a gap between this window and the recent page, so "Load earlier"
    /// keeps its real cursor. Returns true when new rows were added.
    @discardableResult
    public mutating func mergeSearchWindow(_ rows: [PersistedMessage]) -> Bool {
        let existing = Set(messages.map(\.id))
        let added = rows.filter { !existing.contains($0.id) }
        guard !added.isEmpty else { return false }
        for message in added { messageIDs.insert(message.id) }
        messages = (messages + added).sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        return true
    }

    /// Upserts same-ID replacements into the merged transcript (the iPad
    /// `refreshPresentedMessages` path: a durable attachment/text update must
    /// replace the loaded row, never sit beside it). Coverage and cursors are
    /// untouched, so a later "Load earlier" or live refresh can never restore
    /// the stale row. Rows not already loaded are added without claiming page
    /// coverage — the next real page read owns those cursors. Returns true
    /// when any visible row changed.
    @discardableResult
    public mutating func replaceMessages(_ rows: [PersistedMessage]) -> Bool {
        guard !rows.isEmpty else { return false }
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var changed = false
        for row in rows {
            if let existing = byID[row.id] {
                if existing != row {
                    byID[row.id] = row
                    changed = true
                }
            } else {
                byID[row.id] = row
                messageIDs.insert(row.id)
                changed = true
            }
        }
        guard changed else { return false }
        messages = byID.values.sorted {
            ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString)
        }
        return true
    }

    /// Merges one run event page (51 rows: 50 displayed plus one boundary
    /// probe). The 51st row answers `hasEarlier` and never renders. Returns
    /// true when new event rows were added; `earlierEventRunIDs` membership is
    /// always recomputed from coverage so a fully loaded run loses its
    /// "earlier activity" row exactly when the store confirms the beginning.
    @discardableResult
    public mutating func mergeEventPage(
        _ page: [RunEventRecord],
        runID: UUID,
        before: Int? = nil
    ) -> Bool {
        let tail = Array(page.suffix(50))
        eventCoverage[runID, default: .init()].record(
            first: tail.first?.sequence,
            last: tail.last?.sequence,
            before: before,
            hasEarlier: page.count > 50
        )
        let existing = eventsByRun[runID, default: []]
        let known = eventIDsByRun[runID, default: []]
        var added: [RunEventRecord] = []
        var knownUpdated = known
        for event in tail where knownUpdated.insert(event.id).inserted {
            added.append(event)
        }
        guard !added.isEmpty else {
            updateEarlierEventMembership(runID)
            return false
        }
        eventIDsByRun[runID] = knownUpdated
        let merged: [RunEventRecord]
        if existing.isEmpty {
            merged = added
        } else if added.last!.sequence <= existing.first!.sequence {
            // An earlier page: its rows precede everything loaded.
            merged = added + existing
        } else if existing.last!.sequence <= added.first!.sequence {
            // A newest page: its rows follow everything loaded.
            merged = existing + added
        } else {
            // Interleave after a reconnect gap: rare; keep the exact
            // sequence order over the merged superset.
            merged = (existing + added).sorted { $0.sequence < $1.sequence }
        }
        eventsByRun[runID] = merged
        updateEarlierEventMembership(runID)
        return true
    }

    private mutating func updateEarlierEventMembership(_ runID: UUID) {
        if eventCoverage[runID]?.earlierCursor != nil {
            earlierEventRunIDs.insert(runID)
        } else {
            earlierEventRunIDs.remove(runID)
        }
    }
}
