// SPDX-License-Identifier: MPL-2.0
//
// G02 temporary session — RAM-backed routing for the ORDINARY command
// facade (private Alpha2 candidate repair; NOT compiled by the authoring
// package).
//
// WHY THIS FILE EXISTS
// --------------------
// The App does not address a conversation through a temporary-only command
// surface. Its real first-entry / first-run path is the ORIGINAL ordinary
// contract:
//
//   conversation.get -> conversation.messagePage -> run.start ->
//   run.snapshot -> event.poll -> run.cancel
//
// and its Keep/navigation path is temp.keep/temp.end. The RB5 temporary
// domain correctly owns the session and the ORIGINAL Ephemeral* stores, but
// only the three `temp.*` keys were wired into the facade: every ordinary
// reader/writer above still resolved the durable SQLite cluster, where a
// RAM-only hosted conversation does not exist. `conversation.get` therefore
// answered notFound, the App marked the thread missing ("This conversation
// is no longer available") and never reached run.start at all.
//
// This file supplies ONLY the missing read/launch routing seam:
//   * `TemporaryLiveRouting.route` resolves the exact LIVE session for one
//     hosted conversation from the installed temporary domain (epoch
//     checked; never a durable fallback);
//   * `TemporaryConversationProjection` projects the session's REAL
//     conversation/messages/runs/pending inputs into the EXISTING
//     ConversationSessionReply / ConversationMessagePageReply shapes, with
//     the SAME 48 KiB page discipline (oldest-row trim + honest
//     hasEarlier). Oversize rows use the SAME generation-owned bounded
//     content reader as the durable path, bound to the temporary
//     conversation + incarnation — RAM bytes, never a durable row and never
//     a truncated inline prefix;
//   * `TemporaryLiveRoute.runBundle` is the SAME ephemeral bundle used by
//     the launch port, for the snapshot/event reads.
//
// Every projection is called by the ordinary domain actor, reads the
// session's original stores, and is re-validated after the awaits. A
// discarded/promoted session (or a different incarnation) yields a typed
// notFound; process death and navigation leave nothing to restore because
// no durable row was ever written.
//
// This file intentionally adds NO command, NO payload key, NO authority and
// NO second store.
import Foundation
import FloeCore
import FloeModels
import FloePersistence

// MARK: - Live-route lookup

enum TemporaryLiveRouting {
    /// The exact live temporary route for [conversationID] in the accepted
    /// generation [epoch], or nil (ordinary conversation / no live session /
    /// different incarnation). Never falls back to the durable stores: the
    /// caller's ordinary path owns that decision.
    static func route(epoch: UInt64,
                      conversationID: UUID) async -> TemporaryLiveRoute? {
        guard let domain = TemporaryDomainFacade.current(epoch: epoch) else {
            return nil
        }
        return await domain.liveRoute(conversationID: conversationID)
    }

    /// Post-read identity proof. The route must still name the SAME live
    /// incarnation; a session ended/promoted across the read is a typed
    /// notFound, never a resurrected empty surface.
    static func requireStillLive(_ live: TemporaryLiveRoute,
                                 epoch: UInt64) async throws {
        guard let current = await Self.route(epoch: epoch,
                                             conversationID: live.conversationID),
              current.incarnation == live.incarnation else {
            throw ConversationDomainError.notFound
        }
    }
}

// MARK: - RAM projection into the ordinary reply shapes

enum TemporaryConversationProjection {

    /// `conversation.get` reply from the live session's REAL original
    /// stores. Counts are real; the first screen is the native 20-row
    /// window; runs use the native 160-row order; pending inputs are the
    /// ORIGINAL queue order. Budget trimming happens only on the tail and
    /// is flagged, exactly like the durable projection.
    static func sessionReply(route: TemporaryLiveRoute,
                             content: FacadeConversationContentAuthority,
                             firstScreenLimit: Int = 20) async throws
        -> ConversationSessionReply
    {
        let record: ConversationRecord?
        let messages: [PersistedMessage]
        let runRecords: [RunRecord]
        let pendingRecords: [PendingUserInput]
        do {
            record = try await route.stores.conversations
                .conversation(id: route.conversationID)
            messages = try await route.stores.conversations
                .messages(conversationID: route.conversationID)
            runRecords = try await route.stores.runs
                .runs(conversationID: route.conversationID)
            pendingRecords = try await route.stores.runningInputs
                .pending(conversationID: route.conversationID)
        } catch {
            throw ConversationDomainError.persistenceUnavailable("temporaryReadFailed")
        }
        guard let record, record.purpose == .temporary else {
            // The live session's own hosted record must be present and
            // temporary. Anything else is a typed notFound, never an
            // ordinary read through a temporary id.
            throw ConversationDomainError.notFound
        }

        let firstScreen = try await messagePageReply(
            messages: messages, before: nil, limit: firstScreenLimit,
            route: route, content: content)

        // Native snapshot run window/order (`started_at DESC, id`), with the
        // real total so truncation is honest.
        let snapshotRunsWindow = 160
        var runSummaries = runRecords.prefix(snapshotRunsWindow).map { run in
            ConversationRunSummaryWire(
                runID: run.id,
                state: run.state,
                startedAtRaw: ConversationWireDate.encode(run.startedAt),
                endedAtRaw: run.endedAt.map(ConversationWireDate.encode),
                providerName: run.providerName,
                modelName: run.modelName,
                conversationMode: run.conversationMode)
        }
        let runsTotal = runRecords.count
        var runsTruncated = runsTotal > snapshotRunsWindow

        var pendingWindow = pendingRecords.map(PendingUserInputWire.init(input:))
        var pendingTruncated = false

        // The temporary policy is the ORIGINAL default synthesized in RAM
        // by the run lane (no durable task_policies row exists for a
        // temporary conversation). Nothing is persisted here.
        let taskPolicy = TaskPolicy(conversationID: route.conversationID)

        func build(pending: [PendingUserInputWire],
                   runs: [ConversationRunSummaryWire],
                   pendingTruncated: Bool,
                   runsTruncated: Bool) -> ConversationSessionReply {
            ConversationSessionReply(
                conversationID: record.id,
                resourceID: route.revisionResourceID,
                revision: route.revisionVersion,
                title: record.title,
                createdAtRaw: ConversationWireDate.encode(record.createdAt),
                updatedAtRaw: ConversationWireDate.encode(record.updatedAt),
                titleOrigin: record.titleOrigin.rawValue,
                archivedAtRaw: nil,
                firstScreen: firstScreen,
                messagesTotalCount: messages.count,
                runs: runs,
                runsTotalCount: runsTotal,
                runsTruncated: runsTruncated,
                pendingInputs: pending,
                pendingInputsTotalCount: pendingRecords.count,
                pendingInputsTruncated: pendingTruncated,
                taskPolicy: taskPolicy,
                purpose: .temporary)
        }

        var reply = build(pending: pendingWindow, runs: runSummaries,
                          pendingTruncated: pendingTruncated,
                          runsTruncated: runsTruncated)
        while ConversationWireBudget.encodedObjectBytes(reply.wireObject)
                > SettingsDomainV1.pageBudgetBytes {
            if pendingWindow.count > 1 {
                pendingWindow.removeLast()
                pendingTruncated = true
            } else if pendingWindow.count == 1 {
                pendingWindow.removeAll()
                pendingTruncated = true
            } else if runSummaries.count > 1 {
                runSummaries.removeLast()
                runsTruncated = true
            } else {
                // The immutable header + already-budget-checked first screen
                // cannot fit: fail typed, never return a partial snapshot.
                throw ConversationDomainError.payloadTooLarge(
                    maxBytes: SettingsDomainV1.pageBudgetBytes)
            }
            reply = build(pending: pendingWindow, runs: runSummaries,
                          pendingTruncated: pendingTruncated,
                          runsTruncated: runsTruncated)
        }
        return reply
    }

    /// `conversation.messagePage` reply from the live session's RAM
    /// messages. Uses the SAME keyset predicate/order as the original
    /// ephemeral store and the SAME builder/page budget as the durable
    /// path. Oversize rows are staged in the shared bounded reader with a
    /// real temporary conversation + incarnation binding; the page carries
    /// the owned handle and the App fetches the full content through
    /// content.read. Nothing is truncated and no durable row is created.
    static func messagePageReply(messages: [PersistedMessage],
                                 before: ConversationMessageCursor?,
                                 limit: Int,
                                 route: TemporaryLiveRoute,
                                 content: FacadeConversationContentAuthority) async throws
        -> ConversationMessagePageReply
    {
        let eligible: [PersistedMessage]
        if let before {
            eligible = messages.filter {
                ($0.createdAt, $0.id.uuidString)
                    < (before.createdAt, before.messageID.uuidString)
            }
        } else {
            eligible = messages
        }
        let bounded = max(1, limit)
        var working = Array(eligible.suffix(bounded))
        let originalPage = ConversationMessagePage(
            messages: working,
            earlierCursor: working.first.map {
                ConversationMessageCursor(createdAt: $0.createdAt,
                                          messageID: $0.id)
            },
            hasEarlier: eligible.count > working.count)

        // Oversize rows go through the SAME generation-owned bounded reader
        // as the durable path, bound to this temporary conversation AND
        // incarnation. The bytes stay in RAM; the page carries a handle
        // instead of an incomplete inline prefix. Nothing durable is touched
        // and no arbitrary content-size feature cap is introduced.
        var staged: [UUID: (handle: String, totalBytes: Int)] = [:]
        func releaseStaged() async {
            for entry in staged.values {
                await content.release(handle: entry.handle)
            }
            staged.removeAll(keepingCapacity: false)
        }
        for message in working
        where ConversationMessageReplyBuilder.requiresHandle(message: message) {
            guard let entry = await content.publishTemporary(
                conversationID: route.conversationID,
                messageID: message.id,
                incarnation: route.incarnation,
                text: message.content) else {
                await releaseStaged()
                // A vanished session is a typed notFound; a still-live one
                // whose shared reader refused is the honest saturated code.
                try await TemporaryLiveRouting.requireStillLive(
                    route, epoch: route.epoch)
                throw ConversationDomainError.runtimeUnavailable(
                    "contentReaderSaturated")
            }
            staged[message.id] = entry
        }

        var trimmed = false
        while true {
            var reencoded: String?
            if trimmed {
                guard let earliest = working.first else {
                    await releaseStaged()
                    throw ConversationDomainError
                        .persistenceUnavailable("temporaryPageEmpty")
                }
                reencoded = try FacadeConversationDomain.encodeMessageCursor(
                    ConversationMessageCursor(createdAt: earliest.createdAt,
                                              messageID: earliest.id))
            }
            let reply = ConversationMessageReplyBuilder.build(
                messages: working,
                staged: staged,
                originalPage: originalPage,
                reencodedEarlierCursor: reencoded,
                forceHasEarlier: trimmed)
            if ConversationWireBudget.encodedObjectBytes(reply.wireObject)
                    <= SettingsDomainV1.pageBudgetBytes {
                return reply
            }
            guard working.count > 1 else {
                await releaseStaged()
                throw ConversationDomainError.payloadTooLarge(
                    maxBytes: SettingsDomainV1.pageBudgetBytes)
            }
            let dropped = working.removeFirst()
            if let entry = staged.removeValue(forKey: dropped.id) {
                await content.release(handle: entry.handle)
            }
            trimmed = true
        }
    }
}
