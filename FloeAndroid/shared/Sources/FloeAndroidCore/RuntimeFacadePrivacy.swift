// SPDX-License-Identifier: MPL-2.0
//
// RuntimeFacadePrivacy — the REAL G02 privacy settings backend.
//
// Commands (frozen rev3 contract commandTable[24..26], canonical contract
// sha256 f3ddecdca061ae17fbe4280b7bfb549d8a1673fd8d9ae6e1ba363332ef5db46c):
//   * privacy.summary.get              (read; exact identity/state snapshot)
//   * privacy.history.clear            (async destructive batch)
//   * privacy.modelConfiguration.clear (async destructive batch)
//
// Behavioral authority (mirrored, never re-invented):
//   * SettingsActions.clearLocalHistory / clearModelConfiguration and
//     ConversationCenter.deleteAllConversations / stopRunsAndDelete;
//   * the native clear predicate purpose='ordinary' AND archived_at IS NULL;
//   * the ORIGINAL same-writer conversation delete, memory preservation and
//     V11/V36 triggers (`SQLiteConversationStore.deleteConversation(id:
//     expectedRow:beforeDelete:)`);
//   * the ORIGINAL grant layers (SQLiteWorkspaceStore + ApprovalGrantStore);
//   * the ORIGINAL V11 credential_deletion_queue ordering with the accepted
//     SecretGatewayRegistry physical seam;
//   * the EXISTING shared provider-operation reservation and RB4 global
//     launch fence / RB3 deletion lifecycle.
//
// Honesty invariants: a clear is NEVER one atomic transaction and never
// reported as one; per-item/per-phase typed failures are collected and the
// loop continues where safe; a process death mid-clear leaves only durable
// state and an orphan target spool (never a success); the post-execution
// remaining counts are REAL re-counts, and `remaining=null` is allowed ONLY
// with a typed nonempty `remainingFailure` and `partial=true`.
//
// Memory-bound invariant (2026-10-21): failures are collected INCREMENTALLY
// through a root-private staged/verified report spool — RAM holds at most
// the bounded initial page and exact counts, never the full failure
// inventory; every failure stays readable in stable order through the
// existing privacy.summary.get optional report request.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime

public actor RuntimeFacadePrivacy {
    public static let historyResourceID = "privacy.history"
    public static let modelConfigurationResourceID = "privacy.modelConfiguration"
    public static let summaryCommand = "privacy.summary.get"
    public static let historyClearOperation = "privacy.history.clear"
    public static let modelConfigClearOperation = "privacy.modelConfiguration.clear"

    private let database: DatabaseManager
    private let snapshotEngine: PrivacySnapshotEngine
    private let conversationStore: SQLiteConversationStore
    private let workspaceStore: SQLiteWorkspaceStore
    private let persistedGrants: any PrivacyPersistedGrantStore
    private let inMemoryGrants: any PrivacyInMemoryGrantStore
    private let globalFence: (any PrivacyGlobalAdmissionFencing)?
    private let deletionLifecycle: (any ConversationDeletionLifecycle)?
    private let secretOrdering: (any PrivacySecretDeletionOrdering)?
    private let credentialDrain: (any ConversationCredentialDeletionDraining)?
    private let providerOperations: (any PrivacyProviderOperationOwning)?
    private let ownedWork: (any PrivacyOwnedWorkOwning)?
    private let workspaceCleaning: (any ConversationOwnedWorkspaceCleaning)?
    private let confirmation: PrivacyHostConfirmationStore?
    private let reportStore: PrivacyReportStore
    private let hostEpochProvider: @Sendable () -> UInt64
    private let rootIdentity: String
    /// Normalized app-private root path. It backs the root-owned failure
    /// report spools and never appears on the wire (only its SHA-256 token
    /// does, via `rootIdentity`).
    private let rootPath: String
    private let clock: @Sendable () -> Date
    /// TEST-ONLY controlled hook at named boundaries; production nil. It is
    /// async so a fixture can model a concurrent save/insert at the DOCUMENTED
    /// between-snapshot-and-effect boundary on the same database.
    private let faultInjection: (@Sendable (String) async throws -> Void)?

    private let epoch: UInt64
    private var historyClearInFlight = false
    private var modelConfigClearInFlight = false
    private var retireRequested = false
    private var retired = false

    public init(database: DatabaseManager,
                snapshotEngine: PrivacySnapshotEngine,
                conversationStore: SQLiteConversationStore,
                workspaceStore: SQLiteWorkspaceStore,
                persistedGrants: any PrivacyPersistedGrantStore,
                inMemoryGrants: any PrivacyInMemoryGrantStore,
                globalFence: (any PrivacyGlobalAdmissionFencing)?,
                deletionLifecycle: (any ConversationDeletionLifecycle)?,
                secretOrdering: (any PrivacySecretDeletionOrdering)?,
                credentialDrain: (any ConversationCredentialDeletionDraining)?,
                providerOperations: (any PrivacyProviderOperationOwning)?,
                ownedWork: (any PrivacyOwnedWorkOwning)?,
                workspaceCleaning: (any ConversationOwnedWorkspaceCleaning)?,
                confirmation: PrivacyHostConfirmationStore?,
                reportStore: PrivacyReportStore,
                hostEpoch: @escaping @Sendable () -> UInt64,
                rootIdentity: String,
                rootPath: String,
                clock: @escaping @Sendable () -> Date = { Date() },
                faultInjection: (@Sendable (String) async throws -> Void)? = nil) {
        self.database = database
        self.snapshotEngine = snapshotEngine
        self.conversationStore = conversationStore
        self.workspaceStore = workspaceStore
        self.persistedGrants = persistedGrants
        self.inMemoryGrants = inMemoryGrants
        self.globalFence = globalFence
        self.deletionLifecycle = deletionLifecycle
        self.secretOrdering = secretOrdering
        self.credentialDrain = credentialDrain
        self.providerOperations = providerOperations
        self.ownedWork = ownedWork
        self.workspaceCleaning = workspaceCleaning
        self.confirmation = confirmation
        self.reportStore = reportStore
        self.hostEpochProvider = hostEpoch
        self.rootIdentity = rootIdentity
        self.rootPath = rootPath
        self.clock = clock
        self.faultInjection = faultInjection
        self.epoch = hostEpoch()
    }

    // MARK: - Lifecycle (called by G02PrivacyDomainExtension)

    /// RootStop for the EXACT attached epoch. It fences new commands and
    /// retires this epoch's confirmation/report entries. In-flight work
    /// observes `retireRequested` at its next item boundary, settles its
    /// EXACT global fence and detaches its owned-work token; a stale epoch's
    /// retirement can never touch a newer generation.
    public func markRetiring(epoch: UInt64) {
        guard epoch == self.epoch else { return }
        retireRequested = true
        reportStore.retire(epoch: epoch)
        confirmation?.retire()
    }

    public func markRetired(epoch: UInt64) {
        guard epoch == self.epoch else { return }
        retired = true
    }

    private func ensureActive() throws {
        guard !retired else {
            throw PrivacyDomainError.sessionFenced("generationRetired")
        }
        guard !retireRequested else {
            throw PrivacyDomainError.sessionFenced("generationRetiring")
        }
        guard hostEpochProvider() == epoch else {
            throw PrivacyDomainError.sessionFenced("generationEpochMismatch")
        }
    }

    private func injectFault(_ phase: String) async throws {
        try await faultInjection?(phase)
    }

    // MARK: - privacy.summary.get

    public func summary() async throws -> PrivacySnapshotReply {
        try ensureActive()
        let history = try await snapshotEngine.captureHistory(captureTargets: false)
        let modelConfiguration = try await snapshotEngine
            .captureModelConfiguration(captureTargets: false)
        let availability: PrivacyCredentialAvailability
        if let ordering = secretOrdering {
            availability = await ordering.credentialAvailability()
        } else {
            // Truthful default: without the ordered secret port the
            // credential sub-summary can never claim availability.
            availability = .needsConfiguration
        }
        return PrivacySnapshotReply(
            history: PrivacyHistorySnapshot(
                conversationCount: history.conversationCount,
                runCount: history.runCount,
                persistedGrantCount: history.persistedGrantCount,
                inMemoryGrantCount: history.inMemoryGrantCount,
                revision: history.digest),
            modelConfiguration: PrivacyModelConfigurationSnapshot(
                providerCount: modelConfiguration.providerCount,
                modelCount: modelConfiguration.modelCount,
                secretReferenceCount: modelConfiguration.secretReferenceCount,
                preferencesSyncRevision: modelConfiguration.preferencesSyncRevision,
                revision: modelConfiguration.digest),
            credentialAvailability: availability,
            snapshot: PrivacySnapshotReceipt(
                dbSnapshotTransaction: true,
                inMemoryGrantBracket: "g1==g2",
                retriesBounded: PrivacySnapshotEngine.maximumBracketAttempts))
    }

    /// Optional same-root/process-lifetime failure page. This is a READ of an
    /// already-issued immutable report; it never runs a clear and never
    /// reads a path/provider/secret.
    public func reportPage(handle: String, cursor: String?,
                           maxItems: Int) throws -> PrivacyFailurePage {
        try ensureActive()
        return try reportStore.page(handle: handle, root: rootIdentity,
                                    epoch: epoch, cursor: cursor,
                                    maxItems: maxItems)
    }

    // MARK: - Shared admission

    private func requireRevisionShape(_ revision: BaseRevision,
                                      resourceID: String) throws {
        guard revision.resourceID == resourceID else {
            throw PrivacyDomainError.invalidEnvelope("revisionResourceMismatch")
        }
        let version = revision.version
        guard version.hasPrefix("sha256:"),
              version.count == 71,
              version.dropFirst(7).allSatisfy({ $0.isHexDigit }) else {
            throw PrivacyDomainError.invalidEnvelope("revisionDigestShape")
        }
    }

    /// Consent = the privileged native capability minted after a real user
    /// tap, bound to root + epoch + operation + action + the exact preview
    /// digest + the exact command invocation. It is consumed ONCE, after the
    /// fresh snapshot proved the preview is still current and BEFORE any
    /// effect. A bare digest, model-authored JSON or a replay answers nil.
    private func consumeConfirmation(_ request: PrivacyClearRequest,
                                     operation: String,
                                     previewDigest: String,
                                     invocationID: String) throws {
        guard let confirmation else {
            throw PrivacyDomainError.runtimeUnavailable("hostConfirmationUnregistered")
        }
        guard let action = PrivacyHostConfirmationStore.expectedAction(
            for: operation) else {
            throw PrivacyDomainError.runtimeUnavailable("hostConfirmationOperation")
        }
        guard confirmation.consume(token: request.confirmToken,
                                   operation: operation,
                                   action: action,
                                   previewDigest: previewDigest,
                                   invocationID: invocationID) != nil else {
            throw PrivacyDomainError.runtimeUnavailable("hostConfirmationMissingOrInvalid")
        }
    }

    // MARK: - privacy.history.clear

    public func clearHistory(request: PrivacyClearRequest,
                             revision: BaseRevision,
                             invocationID: String) async throws
        -> PrivacyHistoryClearReport
    {
        try requireRevisionShape(revision, resourceID: Self.historyResourceID)
        try ensureActive()
        guard !historyClearInFlight else {
            throw PrivacyDomainError.duplicateInFlight
        }
        historyClearInFlight = true
        defer { historyClearInFlight = false }

        let operationID = UUID()
        var fence: GlobalAdmissionFenceToken?
        var ownedToken: RuntimeOwnedWorkToken?
        var spoolDescriptor: PrivacyClearSpoolDescriptor?
        var hasEffects = false
        var pausedForRetirement = false
        var collector: PrivacyFailureCollector<PrivacyClearFailure>!
        var deletedConversations = 0
        var deletedRuns = 0
        var deletedPersistedGrants = 0
        var deletedInMemoryGrants = 0

        defer {
            if let spoolDescriptor {
                PrivacyClearSpool.remove(descriptor: spoolDescriptor)
            }
            if let ownedToken {
                _ = ownedWork?.detach(ownedToken)
            }
            collector?.abort()
            G02RuntimeComposition.shared.noteHistoryClearInFlight(false)
        }

        do {
            guard let fenceOwner = globalFence else {
                throw PrivacyDomainError.runtimeUnavailable(
                    "globalAdmissionFenceUnregistered")
            }
            do {
                fence = try await fenceOwner.beginGlobalAdmissionFence(
                    expectedEpoch: epoch)
            } catch {
                throw Self.mapFenceError(error)
            }
            try await fenceOwner.awaitPendingLaunchesSettled(expectedEpoch: epoch)

            // (3) SNAPSHOT+CAS. The target spool is written and verified
            // inside the same bounded reader transaction; nothing is deleted
            // on a digest mismatch.
            let snapshot = try await snapshotEngine.captureHistory(
                captureTargets: true, operationID: operationID)
            // Own the staged spool immediately: a digest mismatch/unbound
            // port must remove it, never leave target evidence behind.
            spoolDescriptor = snapshot.spool
            guard snapshot.digest == revision.version else {
                throw PrivacyDomainError.staleRevision
            }
            guard let descriptor = snapshot.spool else {
                throw PrivacyDomainError.persistenceUnavailable("targetSpoolMissing")
            }
            let spool = try PrivacyClearSpool.open(descriptor: descriptor)

            // REQUIRED owner ports are checked AFTER the CAS and BEFORE the
            // first destructive effect: an unbound owner never sees a
            // half-cleared state.
            guard let lifecycle = deletionLifecycle else {
                throw PrivacyDomainError.runtimeUnavailable(
                    "conversationDeletionLifecycleUnregistered")
            }
            guard let owned = ownedWork else {
                throw PrivacyDomainError.runtimeUnavailable(
                    "ownedWorkRegistryUnregistered")
            }
            switch owned.attach(
                epoch: epoch, kind: .conversation,
                ownerID: "privacy.history.clear:\(operationID.uuidString)") {
            case .some(let token):
                ownedToken = token
            case .none:
                throw PrivacyDomainError.runtimeUnavailable(
                    "ownedWorkAdmissionRejected")
            }

            // The failure report spool is ARRANGED BEFORE the first
            // destructive effect and BEFORE the one-shot confirmation is
            // consumed: a staging failure refuses the clear typed with
            // nothing deleted and the capability unspent.
            collector = try PrivacyFailureCollector(
                rootPath: rootPath, kind: .history, root: rootIdentity,
                epoch: epoch, operationID: operationID,
                project: { $0.pageItem })

            try consumeConfirmation(request, operation: Self.historyClearOperation,
                                    previewDigest: revision.version,
                                    invocationID: invocationID)

            // P8 feeds observe the composition's REAL history-clear fence and
            // drop late personalization callbacks BEFORE any mutation.
            G02RuntimeComposition.shared.noteHistoryClearInFlight(true)

            // (5) Per-conversation deletion over the exact spool.
            let conversationReader = try spool.reader(section: "conversations")
            conversationLoop: while true {
                if retireRequested { pausedForRetirement = true; break }
                let page = try conversationReader.nextPage(limit: 64)
                if page.isEmpty { break }
                let ids = try page.map { try Self.parseConversationLine($0) }
                let runCounts = try Self.enumeratedRunCounts(
                    spool: spool, conversationIDs: Set(ids))
                for id in ids {
                    if retireRequested || Task.isCancelled {
                        pausedForRetirement = retireRequested
                        collector.record(PrivacyClearFailure(
                            itemID: nil, phase: .quiesce,
                            reason: retireRequested ? "generationRetiring" : "cancelled"))
                        break conversationLoop
                    }
                    if collector.degraded { break conversationLoop }
                    do {
                        try await injectFault("history.clear.conversation")
                        let result = try await deleteEnumeratedConversation(
                            id, lifecycle: lifecycle)
                        if result.deleted {
                            hasEffects = true
                            deletedConversations += 1
                            deletedRuns += runCounts[id] ?? 0
                        }
                        if let post = result.postCommitFailure {
                            collector.record(PrivacyClearFailure(
                                itemID: id, phase: .drain, reason: post))
                        }
                    } catch PrivacyDomainError.notFound {
                        // Concurrently removed: the state is already reached;
                        // the post-execution recount proves it. Not a failure
                        // and never a fabricated deletion count.
                        continue
                    } catch {
                        collector.record(PrivacyClearFailure(
                            itemID: id, phase: .deleteConversation,
                            reason: Self.boundedReason(error) ?? "deleteConversationUnavailable"))
                    }
                }
            }

            // (6) Grants, both layers, per-layer counts. Only ENUMERATED
            // grants are cleared; grants created after the snapshot survive.
            let persistedReader = try spool.reader(section: "persistedGrants")
            grantLoop: while !pausedForRetirement {
                let page = try persistedReader.nextPage(limit: 64)
                if page.isEmpty { break }
                for line in page {
                    if retireRequested || Task.isCancelled {
                        pausedForRetirement = retireRequested
                        break grantLoop
                    }
                    if collector.degraded { break grantLoop }
                    do {
                        let id = try Self.parsePrefixedUUID(line, prefix: "p")
                        try await injectFault("history.clear.persistedGrant")
                        try await persistedGrants.deleteGrant(id: id)
                        deletedPersistedGrants += 1
                        hasEffects = true
                    } catch PrivacyDomainError.notFound {
                        continue
                    } catch {
                        collector.record(PrivacyClearFailure(
                            itemID: try? Self.parsePrefixedUUID(line, prefix: "p"),
                            phase: .grantRevoke,
                            reason: Self.boundedReason(error) ?? "grantRevokeUnavailable"))
                    }
                }
            }
            let inMemoryReader = try spool.reader(section: "inMemoryGrants")
            inMemoryLoop: while !pausedForRetirement {
                let page = try inMemoryReader.nextPage(limit: 64)
                if page.isEmpty { break }
                for line in page {
                    if retireRequested || Task.isCancelled {
                        pausedForRetirement = retireRequested
                        break inMemoryLoop
                    }
                    if collector.degraded { break inMemoryLoop }
                    do {
                        let id = try Self.parsePrefixedUUID(line, prefix: "i")
                        try await injectFault("history.clear.inMemoryGrant")
                        await inMemoryGrants.revokeGrant(id: id)
                        deletedInMemoryGrants += 1
                        hasEffects = true
                    } catch {
                        collector.record(PrivacyClearFailure(
                            itemID: try? Self.parsePrefixedUUID(line, prefix: "i"),
                            phase: .grantRevoke,
                            reason: Self.boundedReason(error) ?? "grantRevokeUnavailable"))
                    }
                }
            }

            // (7) Credential deletion-queue drain (the vault owns the durable
            // queue and the real bootstrap replay).
            if let drain = credentialDrain {
                try await injectFault("history.clear.credentialDrain")
                let summary = await drain.drainDeletionQueue()
                if let failed = summary.failedCount, failed > 0 {
                    collector.record(PrivacyClearFailure(
                        itemID: nil, phase: .drain,
                        reason: "credentialDrainFailures"))
                }
            } else {
                collector.record(PrivacyClearFailure(
                    itemID: nil, phase: .drain,
                    reason: "credentialDrainUnregistered"))
            }

            // (8) REAL post-execution remaining re-count (summary mode; no
            // target spool). nil ONLY with a typed failure.
            var remaining: PrivacyHistoryRemaining?
            var remainingFailure: String?
            do {
                try await injectFault("history.clear.remaining")
                let recount = try await snapshotEngine.captureHistory(
                    captureTargets: false)
                remaining = PrivacyHistoryRemaining(
                    conversationCount: recount.conversationCount,
                    runCount: recount.runCount,
                    persistedGrantCount: recount.persistedGrantCount,
                    inMemoryGrantCount: recount.inMemoryGrantCount)
            } catch {
                remainingFailure = Self.boundedReason(error)
                collector.record(PrivacyClearFailure(
                    itemID: nil, phase: .drain,
                    reason: remainingFailure ?? "remainingRecountUnavailable"))
            }

            if let fence, let fenceOwner = globalFence {
                let settled = await fenceOwner.finishGlobalAdmissionFence(
                    fence, committed: hasEffects)
                if !settled {
                    collector.record(PrivacyClearFailure(
                        itemID: nil, phase: .quiesce,
                        reason: "globalFenceSettlementStale"))
                }
            }
            fence = nil

            return try makeHistoryReport(
                enumerated: PrivacyHistoryEnumerated(
                    conversations: snapshot.conversationCount,
                    runs: snapshot.runCount,
                    persistedGrants: snapshot.persistedGrantCount,
                    inMemoryGrants: snapshot.inMemoryGrantCount),
                deleted: PrivacyHistoryDeleted(
                    conversations: deletedConversations,
                    runs: deletedRuns,
                    persistedGrants: deletedPersistedGrants,
                    inMemoryGrants: deletedInMemoryGrants),
                collector: &collector,
                remaining: remaining,
                remainingFailure: remainingFailure,
                paused: pausedForRetirement)
        } catch {
            if let fence, let fenceOwner = globalFence {
                _ = await fenceOwner.finishGlobalAdmissionFence(
                    fence, committed: hasEffects)
            }
            throw error
        }
    }

    private func makeHistoryReport(
        enumerated: PrivacyHistoryEnumerated,
        deleted: PrivacyHistoryDeleted,
        collector: inout PrivacyFailureCollector<PrivacyClearFailure>,
        remaining: PrivacyHistoryRemaining?,
        remainingFailure: String?,
        paused: Bool
    ) throws -> PrivacyHistoryClearReport {
        let page = try collector.finish(reportStore: reportStore, now: clock())
        return PrivacyHistoryClearReport(
            enumerated: enumerated,
            deleted: deleted,
            failures: collector.initial,
            partial: collector.total > 0 || remainingFailure != nil || paused,
            remaining: remaining,
            remainingFailure: remainingFailure,
            failurePage: page)
    }

    /// Exact per-conversation path shared with conversation.delete:
    /// operation-owned fence -> real owned-work drain -> ONE same-writer
    /// transaction (row/purpose re-check, original memory preservation,
    /// original cascades/triggers) -> exact-token commit; every pre-commit
    /// exit aborts the EXACT fence.
    private struct ConversationDeletionResult: Sendable {
        var deleted: Bool
        var postCommitFailure: String?
    }

    private func deleteEnumeratedConversation(
        _ conversationID: UUID,
        lifecycle: any ConversationDeletionLifecycle
    ) async throws -> ConversationDeletionResult {
        let operationID = UUID()
        let fence: ConversationDeletionFence
        do {
            fence = try await lifecycle.beginDeletionFence(
                conversationID: conversationID, epoch: epoch,
                operationID: operationID)
        } catch let failure as ConversationDeletionLifecycleFailure {
            throw Self.mapLifecycleFailure(failure)
        } catch is CancellationError {
            throw PrivacyDomainError.sessionFenced("deletionFenceCancelled")
        } catch {
            throw PrivacyDomainError.runtimeUnavailable(
                "deletionFenceUnavailable")
        }
        guard fence.conversationID == conversationID,
              fence.epoch == epoch,
              fence.operationID == operationID,
              !fence.authorityReceipt
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            _ = await lifecycle.abortDeletionFence(fence)
            throw PrivacyDomainError.sessionFenced("deletionFenceIdentityMismatch")
        }

        var committed = false
        do {
            // The drain failure is mapped exactly like the fence failure:
            // the typed lifecycle reason (e.g. drainUnavailable(reason))
            // crosses the boundary; an unmapped raw error used to collapse
            // every drain refusal into the generic "internal" token
            // (2026-10-21 repair).
            let quiescence: ConversationQuiescenceReport
            do {
                quiescence = try await lifecycle.drainOwnedWork(fence: fence)
            } catch let failure as ConversationDeletionLifecycleFailure {
                throw Self.mapLifecycleFailure(failure)
            } catch is CancellationError {
                throw PrivacyDomainError.sessionFenced("conversationDrainCancelled")
            } catch {
                throw PrivacyDomainError.runtimeUnavailable(
                    "conversationDrainUnavailable")
            }
            guard quiescence.conversationID == conversationID,
                  quiescence.launchesFenced else {
                throw PrivacyDomainError.runtimeUnavailable("launchesNotFenced")
            }
            if let refusal = quiescence.refusalReason(
                conversationID: conversationID, expectedEpoch: epoch) {
                throw PrivacyDomainError.runtimeUnavailable(refusal)
            }
            let capturedTask = try await capturePrivateTask(conversationID)
            try await conversationStore.deleteConversation(
                id: conversationID,
                expectedRow: { row in
                    guard let row else {
                        throw PrivacyDomainError.notFound
                    }
                    let purpose: String = row["purpose"]
                    guard purpose == "ordinary" else {
                        throw PrivacyDomainError.persistenceUnavailable(
                            "conversationScopeChanged")
                    }
                    let archivedAt: String? = row["archived_at"]
                    guard archivedAt == nil else {
                        throw PrivacyDomainError.persistenceUnavailable(
                            "conversationArchived")
                    }
                },
                beforeDelete: { db in
                    let title: String = try String.fetchOne(
                        db,
                        sql: "SELECT title FROM conversations WHERE id = ?",
                        arguments: [conversationID.uuidString]) ?? "deleted-tasks"
                    try ConversationDeletionMemoryPreservation.preserve(
                        db: db, conversationID: conversationID,
                        ownerLabel: title)
                })
            committed = true
            let settlement = await lifecycle.commitDeletionFence(fence)
            var postCommitFailure: String?
            if settlement != .released && settlement != .alreadySettled {
                postCommitFailure = "deletionFenceSettlementUnavailable"
            }
            if let capturedTask {
                do {
                    try await workspaceCleaning?.removePrivateTaskDirectory(
                        relativePath: capturedTask)
                } catch {
                    postCommitFailure = postCommitFailure
                        ?? "privateWorkspaceCleanupUnavailable"
                }
            }
            return ConversationDeletionResult(deleted: true,
                                              postCommitFailure: postCommitFailure)
        } catch {
            if !committed {
                _ = await lifecycle.abortDeletionFence(fence)
            }
            throw error
        }
    }

    private func capturePrivateTask(_ conversationID: UUID) async throws -> String? {
        guard let workspaceID = try await workspaceStore.workspaceID(
            conversationID: conversationID) else { return nil }
        guard let record = try await workspaceStore.workspace(id: workspaceID),
              record.kind == .privateTask,
              let relative = record.internalRelativePath else { return nil }
        return relative
    }

    // MARK: - Spool line parsing / run accounting

    private static func parseConversationLine(_ line: String) throws -> UUID {
        try parsePrefixedUUID(line, prefix: "c")
    }

    private static func parsePrefixedUUID(_ line: String,
                                          prefix: String) throws -> UUID {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == Substring(prefix),
              let id = UUID(uuidString: String(parts[1])) else {
            throw PrivacyDomainError.persistenceUnavailable("spoolCorrupt")
        }
        return id
    }

    /// Counts the ENUMERATED runs for a bounded page of conversations by
    /// streaming the run section once. Memory stays O(page); no unbounded
    /// map of the whole history is created.
    private static func enumeratedRunCounts(
        spool: PrivacyClearSpool, conversationIDs: Set<UUID>
    ) throws -> [UUID: Int] {
        guard !conversationIDs.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        let reader = try spool.reader(section: "runs")
        try reader.forEachLine { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "r",
                  UUID(uuidString: String(parts[1])) != nil,
                  let owner = UUID(uuidString: String(parts[2])) else {
                throw PrivacyDomainError.persistenceUnavailable("spoolCorrupt")
            }
            if conversationIDs.contains(owner) {
                counts[owner, default: 0] += 1
            }
        }
        return counts
    }

    // MARK: - privacy.modelConfiguration.clear

    private enum ProviderSecretState: Sendable {
        case missing
        /// Current persisted secret reference AND row revision. The revision
        /// is the real "new secret generation" discriminator: a newer Set may
        /// reuse the deterministic provider.<uuid> account, so account/ref
        /// equality alone is NOT proof the enumerated secret is unchanged.
        case present(PrivacyProviderSecretReference?, syncRevision: Int64,
                     updatedAt: String?)
    }

    private struct ProviderTarget: Sendable {
        var id: UUID
        var secret: PrivacyProviderSecretReference?
        var syncRevision: Int64
    }

    private struct PreferencesResetOutcome: Sendable {
        var reset: Bool
        var newRevision: Int
        var failure: String?
        var superseded: Bool
    }

    public func clearModelConfiguration(
        request: PrivacyClearRequest,
        revision: BaseRevision,
        invocationID: String
    ) async throws -> PrivacyModelConfigClearReport {
        try requireRevisionShape(revision, resourceID: Self.modelConfigurationResourceID)
        try ensureActive()
        guard !modelConfigClearInFlight else {
            throw PrivacyDomainError.duplicateInFlight
        }
        modelConfigClearInFlight = true
        defer { modelConfigClearInFlight = false }

        let operationID = UUID()
        var ownedToken: RuntimeOwnedWorkToken?
        var spoolDescriptor: PrivacyClearSpoolDescriptor?
        var hasEffects = false
        var collector: PrivacyFailureCollector<PrivacyModelConfigDeletionFailure>!
        var deletedProviders = 0
        var deletedModels = 0
        var deletedSecrets = 0

        defer {
            if let spoolDescriptor {
                PrivacyClearSpool.remove(descriptor: spoolDescriptor)
            }
            if let ownedToken {
                _ = ownedWork?.detach(ownedToken)
            }
            collector?.abort()
        }

        // (2) Snapshot+CAS BEFORE any mutation.
        let snapshot = try await snapshotEngine.captureModelConfiguration(
            captureTargets: true, operationID: operationID)
        spoolDescriptor = snapshot.spool
        guard snapshot.digest == revision.version else {
            throw PrivacyDomainError.staleRevision
        }
        guard let descriptor = snapshot.spool else {
            throw PrivacyDomainError.persistenceUnavailable("targetSpoolMissing")
        }
        let spool = try PrivacyClearSpool.open(descriptor: descriptor)

        // REQUIRED ports / gateway admission BEFORE the first effect.
        let ordering: (any PrivacySecretDeletionOrdering)?
        if snapshot.secretReferenceCount > 0 {
            guard let bound = secretOrdering,
                  await bound.hasRegisteredGateway() else {
                throw PrivacyDomainError.needsConfiguration("gatewayUnregistered")
            }
            ordering = bound
        } else {
            ordering = secretOrdering
        }
        let operations: (any PrivacyProviderOperationOwning)?
        if snapshot.providerCount > 0 {
            guard let bound = providerOperations else {
                throw PrivacyDomainError.runtimeUnavailable(
                    "providerOperationCoordinatorUnregistered")
            }
            operations = bound
        } else {
            operations = providerOperations
        }
        guard let owned = ownedWork else {
            throw PrivacyDomainError.runtimeUnavailable(
                "ownedWorkRegistryUnregistered")
        }
        switch owned.attach(
            epoch: epoch, kind: .vaultMaintenance,
            ownerID: "privacy.modelConfiguration.clear:\(operationID.uuidString)") {
        case .some(let token):
            ownedToken = token
        case .none:
            throw PrivacyDomainError.runtimeUnavailable(
                "ownedWorkAdmissionRejected")
        }

        // The failure report spool is ARRANGED BEFORE the first destructive
        // effect and BEFORE the one-shot confirmation is consumed.
        collector = try PrivacyFailureCollector(
            rootPath: rootPath, kind: .modelConfiguration,
            root: rootIdentity, epoch: epoch, operationID: operationID,
            project: { $0.pageItem })

        try consumeConfirmation(request, operation: Self.modelConfigClearOperation,
                                previewDigest: revision.version,
                                invocationID: invocationID)

        // (3)+(4) Only the at-most-eleven captured preference references
        // can matter to reset CAS. Never materialize every deleted model ID.
        let preferenceModelIDs = Self.observedPreferenceModelIDs(
            snapshot.preferencesRecord)
        var deletedModelIDs = Set<UUID>()
        let providerReader = try spool.reader(section: "providers")
        providerLoop: while true {
            if retireRequested || Task.isCancelled { break }
            let page = try providerReader.nextPage(limit: 32)
            if page.isEmpty { break }
            let targets = try page.map { try Self.parseProviderLine($0) }
            let modelCounts = try Self.enumeratedModelCounts(
                spool: spool, providerIDs: Set(targets.map(\.id)))
            for target in targets {
                if retireRequested || Task.isCancelled {
                    collector.record(PrivacyModelConfigDeletionFailure(
                        providerID: target.id, phase: .enqueue,
                        reason: retireRequested ? "generationRetiring" : "cancelled"))
                    break providerLoop
                }
                if collector.degraded { break providerLoop }
                do {
                    try await injectFault("modelConfig.clear.provider")
                    let outcome = try await clearEnumeratedProvider(
                        target, ordering: ordering, operations: operations)
                    if outcome.deletedRow {
                        hasEffects = true
                        deletedProviders += 1
                        deletedModels += modelCounts[target.id] ?? 0
                        if let ids = try? Self.enumeratedModelIDs(
                            spool: spool, providerID: target.id,
                            matching: preferenceModelIDs) {
                            deletedModelIDs.formUnion(ids)
                        }
                    }
                    deletedSecrets += outcome.deletedSecrets
                    if let failure = outcome.failure {
                        collector.record(failure)
                    }
                } catch {
                    collector.record(PrivacyModelConfigDeletionFailure(
                        providerID: target.id, phase: .gatewayDelete,
                        reason: Self.boundedReason(error) ?? "gatewayDeleteUnavailable"))
                }
            }
        }

        // (5) Preferences: same-writer expected-state CAS + monotonic
        // revision. A newer save is never overwritten. If the exact epoch
        // retired mid-batch, no further user-visible effect is taken.
        var reset = PreferencesResetOutcome(
            reset: false, newRevision: 0, failure: nil, superseded: false)
        if retireRequested || Task.isCancelled {
            reset.failure = retireRequested ? "generationRetiring" : "cancelled"
        } else {
            reset = await resetPreferencesIfUnchanged(
                observedRecord: snapshot.preferencesRecord,
                deletedModelIDs: deletedModelIDs)
        }

        // Remaining REAL re-count.
        var remaining: PrivacyModelConfigRemaining?
        var remainingFailure: String?
        var recountedPreferencesRevision: Int?
        do {
            try await injectFault("modelConfig.clear.remaining")
            let recount = try await snapshotEngine.captureModelConfiguration(
                captureTargets: false)
            remaining = PrivacyModelConfigRemaining(
                providerCount: recount.providerCount,
                modelCount: recount.modelCount,
                secretReferenceCount: recount.secretReferenceCount)
            recountedPreferencesRevision = recount.preferencesSyncRevision
        } catch {
            remainingFailure = Self.boundedReason(error)
        }

        let pageSummary = try collector.finish(reportStore: reportStore,
                                               now: clock())
        return PrivacyModelConfigClearReport(
            enumerated: PrivacyModelConfigEnumerated(
                providers: snapshot.providerCount,
                models: snapshot.modelCount,
                secretReferences: snapshot.secretReferenceCount),
            deleted: PrivacyModelConfigDeleted(
                providers: deletedProviders,
                models: deletedModels,
                secrets: deletedSecrets),
            deletionFailures: collector.initial,
            preferencesReset: reset.reset,
            preferencesSyncRevision: reset.reset
                ? reset.newRevision
                : (recountedPreferencesRevision ?? reset.newRevision),
            remaining: remaining,
            partial: collector.total > 0 || reset.failure != nil
                || !reset.reset || remainingFailure != nil,
            preferencesFailure: reset.failure,
            remainingFailure: remainingFailure,
            failurePage: pageSummary)
    }

    private struct ProviderClearOutcome: Sendable {
        var deletedRow: Bool
        var deletedSecrets: Int
        var failure: PrivacyModelConfigDeletionFailure?
    }

    private func clearEnumeratedProvider(
        _ target: ProviderTarget,
        ordering: (any PrivacySecretDeletionOrdering)?,
        operations: (any PrivacyProviderOperationOwning)?
    ) async throws -> ProviderClearOutcome {
        guard let operations else {
            // Zero providers is the only path that reaches here; a real
            // provider never proceeds without the shared reservation.
            return ProviderClearOutcome(
                deletedRow: false, deletedSecrets: 0,
                failure: PrivacyModelConfigDeletionFailure(
                    providerID: target.id, phase: .enqueue,
                    reason: "providerOperationCoordinatorUnregistered"))
        }
        let begin = await operations.beginOperation(providerID: target.id,
                                                    kind: .delete)
        let ticket: ProviderOperationTicket
        switch begin {
        case .attached(let value):
            ticket = value
        case .conflict, .pendingReconciliation, .capacityUnavailable:
            return ProviderClearOutcome(
                deletedRow: false, deletedSecrets: 0,
                failure: PrivacyModelConfigDeletionFailure(
                    providerID: target.id, phase: .enqueue,
                    reason: "providerOperationConflict"))
        }

        /// ONE exit that releases the EXACT reservation unless the ticket
        /// was converted to a durable pending owner (unsettled physical
        /// claim). No detached Task, no timeout, no tokenless release.
        func finish(_ outcome: ProviderClearOutcome,
                    keepParked: Bool = false) async -> ProviderClearOutcome {
            if !keepParked {
                await operations.endOperation(ticket)
            }
            return outcome
        }

        // Re-read OUTSIDE any DB transaction; any drift skips the provider
        // so a newer secret is never orphaned. A read failure must release
        // the EXACT attached reservation through the same single exit —
        // a thrown read used to bypass every finish() and leak the real
        // provider ticket (2026-10-21 repair).
        let state: ProviderSecretState
        do {
            try await injectFault("modelConfig.clear.secretStateRead")
            state = try await currentSecretState(providerID: target.id)
        } catch {
            return await finish(ProviderClearOutcome(
                deletedRow: false, deletedSecrets: 0,
                failure: PrivacyModelConfigDeletionFailure(
                    providerID: target.id, phase: .enqueue,
                    reason: Self.boundedReason(error)
                        ?? "secretStateReadUnavailable")))
        }
        switch state {
        case .missing:
            return await finish(ProviderClearOutcome(
                deletedRow: false, deletedSecrets: 0, failure: nil))
        case .present(let current, let syncRevision, _):
            guard current == target.secret,
                  syncRevision == target.syncRevision else {
                return await finish(ProviderClearOutcome(
                    deletedRow: false, deletedSecrets: 0,
                    failure: PrivacyModelConfigDeletionFailure(
                        providerID: target.id, phase: .secretReferenceChanged,
                        reason: "secretReferenceChanged")))
            }
        }

        var deletedSecrets = 0
        var failure: PrivacyModelConfigDeletionFailure?
        if let secret = target.secret {
            guard let ordering else {
                return await finish(ProviderClearOutcome(
                    deletedRow: false, deletedSecrets: 0,
                    failure: PrivacyModelConfigDeletionFailure(
                        providerID: target.id, phase: .enqueue,
                        reason: "secretDeletionOrderingUnregistered")))
            }
            let generation: String
            do {
                generation = try await ordering.enqueuePendingDeletion(
                    account: secret.account,
                    synchronizable: secret.synchronizable)
            } catch {
                return await finish(ProviderClearOutcome(
                    deletedRow: false, deletedSecrets: 0,
                    failure: PrivacyModelConfigDeletionFailure(
                        providerID: target.id, phase: .enqueue,
                        reason: Self.boundedReason(error)
                            ?? "enqueueUnavailable")))
            }
            let reference = ConfigSecretIdentity.providerOpaqueReference(
                for: ConfigSecretIdentity.providerSecretReference(
                    account: secret.account,
                    synchronizable: secret.synchronizable))
            let deletion: PrivacySecretDeletionOutcome
            do {
                deletion = try await ordering.deleteSecret(reference: reference)
            } catch {
                try? await ordering.recordDeletionFailure(
                    account: secret.account, generation: generation,
                    message: Self.boundedReason(error) ?? "gatewayDeleteFailed")
                return await finish(ProviderClearOutcome(
                    deletedRow: false, deletedSecrets: 0,
                    failure: PrivacyModelConfigDeletionFailure(
                        providerID: target.id, phase: .gatewayDelete,
                        reason: Self.boundedReason(error)
                            ?? "gatewayDeleteUnavailable")))
            }
            guard deletion.settled else {
                let reason = deletion.reason ?? "secretSettlementDeferred"
                try? await ordering.recordDeletionFailure(
                    account: secret.account, generation: generation,
                    message: reason)
                var parked = false
                if deletion.physicalOutstanding, let receipt = deletion.receipt,
                   let witness = deletion.witness {
                    parked = await operations.parkPending(
                        ticket, receipt: receipt, witness: witness)
                }
                return await finish(ProviderClearOutcome(
                    deletedRow: false, deletedSecrets: 0,
                    failure: PrivacyModelConfigDeletionFailure(
                        providerID: target.id, phase: .gatewayDelete,
                        reason: reason)), keepParked: parked)
            }
            deletedSecrets = 1
            do {
                try await ordering.completeDeletion(
                    account: secret.account, generation: generation)
            } catch {
                failure = PrivacyModelConfigDeletionFailure(
                    providerID: target.id, phase: .complete,
                    reason: Self.boundedReason(error) ?? "completeUnavailable")
            }
        }

        // (4) ONE writer transaction re-reads the secret reference and
        // deletes only on exact equality (the original FK cascade).
        let rowOutcome: ProviderRowOutcome
        do {
            rowOutcome = try await deleteProviderRowIfUnchanged(
                providerID: target.id,
                enumeratedSecretReference: target.secret,
                enumeratedSyncRevision: target.syncRevision)
        } catch {
            return await finish(ProviderClearOutcome(
                deletedRow: false, deletedSecrets: deletedSecrets,
                failure: failure ?? PrivacyModelConfigDeletionFailure(
                    providerID: target.id, phase: .record,
                    reason: Self.boundedReason(error) ?? "recordUnavailable")))
        }
        switch rowOutcome {
        case .deleted:
            return await finish(ProviderClearOutcome(
                deletedRow: true, deletedSecrets: deletedSecrets,
                failure: failure))
        case .alreadyDeleted:
            return await finish(ProviderClearOutcome(
                deletedRow: false, deletedSecrets: deletedSecrets,
                failure: failure))
        case .secretReferenceChanged:
            return await finish(ProviderClearOutcome(
                deletedRow: false, deletedSecrets: deletedSecrets,
                failure: failure ?? PrivacyModelConfigDeletionFailure(
                    providerID: target.id, phase: .secretReferenceChanged,
                    reason: "secretReferenceChanged")))
        }
    }

    private enum ProviderRowOutcome: Sendable {
        case deleted
        case alreadyDeleted
        case secretReferenceChanged
    }

    private func currentSecretState(providerID: UUID) async throws
        -> ProviderSecretState
    {
        try await database.reader { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT secret_ref_account, secret_ref_synchronizable, sync_revision, updated_at FROM providers WHERE id = ?",
                arguments: [providerID.uuidString]) else {
                return .missing
            }
            let revision: Int64 = row["sync_revision"] ?? 0
            let updatedAt: String? = row["updated_at"]
            guard let account: String = row["secret_ref_account"] else {
                return .present(nil, syncRevision: revision,
                                updatedAt: updatedAt)
            }
            let synchronizable: Bool = row["secret_ref_synchronizable"] ?? false
            return .present(PrivacyProviderSecretReference(
                account: account, synchronizable: synchronizable),
                syncRevision: revision, updatedAt: updatedAt)
        }
    }

    private func deleteProviderRowIfUnchanged(
        providerID: UUID,
        enumeratedSecretReference: PrivacyProviderSecretReference?,
        enumeratedSyncRevision: Int64
    ) async throws -> ProviderRowOutcome {
        try await database.writer { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT secret_ref_account, secret_ref_synchronizable, sync_revision FROM providers WHERE id = ?",
                arguments: [providerID.uuidString]) else {
                return .alreadyDeleted
            }
            let current: PrivacyProviderSecretReference?
            if let account: String = row["secret_ref_account"] {
                let synchronizable: Bool = row["secret_ref_synchronizable"] ?? false
                current = PrivacyProviderSecretReference(
                    account: account, synchronizable: synchronizable)
            } else {
                current = nil
            }
            let revision: Int64 = row["sync_revision"] ?? 0
            guard current == enumeratedSecretReference,
                  revision == enumeratedSyncRevision else {
                return .secretReferenceChanged
            }
            try db.execute(sql: "DELETE FROM providers WHERE id = ?",
                           arguments: [providerID.uuidString])
            return .deleted
        }
    }

    // MARK: - Preferences reset (same-writer expected-state CAS)

    /// Narrow mirror of the ORIGINAL savePreferences upsert with the ADDITIVE
    /// full-record expected-state gate: the observed singleton record and
    /// sync revision must still be the persisted ones. Fresh defaults get
    /// `previous+1` (monotonic; overflow is typed, never wrapped to 0).
    ///
    /// 2026-10-21 repair: every model-reference preference column is
    /// `REFERENCES models(id) ON DELETE SET NULL` and THIS clear deletes the
    /// enumerated models, so the clear's own cascade legitimately nulls
    /// those columns between the confirmed snapshot and this CAS. The gate
    /// stays a FULL-record comparison; the ONLY tolerated drift is
    /// `observed id -> NULL` on a model-reference column whose exact model
    /// THIS clear deleted (enumerated and cascade-removed). Any other
    /// reference drift — a different id, an unrelated null, a null->id — is
    /// an external change and supersedes the reset.
    private static let cascadeNulledModelReferenceColumns: Set<String> = [
        "default_agent_model_id", "general_auxiliary_llm_model_id",
        "canvas_agent_model_id", "vision_model_id", "canvas_vision_model_id",
        "approval_model_id", "package_review_model_id",
        "shared_image_model_id", "image_generation_model_id",
        "image_editing_model_id", "default_video_model_id",
    ]

    private func resetPreferencesIfUnchanged(
        observedRecord: [SettingsDomainV1.CanonicalDigest.Field]?,
        deletedModelIDs: Set<UUID>
    ) async -> PreferencesResetOutcome {
        do {
            return try await database.writer { db in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM model_preferences WHERE id = 'default'") else {
                    return PreferencesResetOutcome(
                        reset: false, newRevision: 0,
                        failure: "preferencesSingletonMissing",
                        superseded: false)
                }
                var current: [SettingsDomainV1.CanonicalDigest.Field] = []
                current.reserveCapacity(
                    PrivacySnapshotEngine.preferenceColumns.count)
                for name in PrivacySnapshotEngine.preferenceColumns {
                    // Pinned-GRDB API repair (2026-10-21): hasColumn +
                    // DatabaseValue subscript replace the removed
                    // `databaseValue(atIndex:)` (storage-class exact).
                    guard row.hasColumn(name) else {
                        return PreferencesResetOutcome(
                            reset: false, newRevision: 0,
                            failure: "preferencesColumnMissing",
                            superseded: false)
                    }
                    let value = row[name] as DatabaseValue
                    switch value.storage {
                    case .null: current.append(.null)
                    case .int64(let raw): current.append(.integer(raw))
                    case .double(let raw): current.append(.real(raw))
                    case .string(let raw): current.append(.text(raw))
                    case .blob(let raw): current.append(.blob(raw))
                    }
                }
                let revisionValue: Int64 = row["sync_revision"] ?? 0
                let currentRevision = Int(revisionValue)
                // Full-record expected-state gate with the ONE bounded
                // exception documented above: a model-reference column may
                // drift ONLY from an observed id to NULL when THIS clear
                // deleted that exact enumerated model. Everything else —
                // any non-reference column, the revision, a different id,
                // an unrelated null — supersedes the reset.
                let columns = PrivacySnapshotEngine.preferenceColumns
                var superseded = observedRecord == nil
                    || observedRecord!.count != columns.count
                    || current.count != columns.count
                if !superseded {
                    for (index, name) in columns.enumerated() {
                        let observedField = observedRecord![index]
                        let currentField = current[index]
                        guard observedField != currentField else { continue }
                        guard Self.cascadeNulledModelReferenceColumns
                                .contains(name),
                              case .text(let rawID) = observedField,
                              currentField == .null,
                              let modelID = UUID(uuidString: rawID),
                              deletedModelIDs.contains(modelID) else {
                            superseded = true
                            break
                        }
                    }
                }
                if superseded {
                    // A newer preference save (or a row that appeared after a
                    // missing singleton) superseded the confirmed snapshot:
                    // never overwrite it and report the ACTUAL revision.
                    return PreferencesResetOutcome(
                        reset: false, newRevision: currentRevision,
                        failure: nil, superseded: true)
                }
                guard revisionValue < Int64.max else {
                    return PreferencesResetOutcome(
                        reset: false, newRevision: currentRevision,
                        failure: "preferencesSyncRevisionOverflow",
                        superseded: false)
                }
                let next = revisionValue + 1
                var fresh = ModelSelectionPreferences()
                fresh.updatedAt = self.clock()
                fresh.syncRevision = next
                try db.execute(
                    sql: ModelConfigurationFacade.preferencesCASUpsert,
                    arguments: [
                        fresh.onboardingStatus.rawValue,
                        fresh.defaultAgentModelID?.uuidString,
                        fresh.generalAuxiliaryLLMModelID?.uuidString,
                        fresh.canvasAgentModelID?.uuidString,
                        fresh.visionModelID?.uuidString,
                        fresh.canvasVisionModelID?.uuidString,
                        fresh.approvalModelID?.uuidString,
                        fresh.packageReviewModelID?.uuidString,
                        fresh.auxiliaryImageMode.rawValue,
                        fresh.sharedImageModelID?.uuidString,
                        fresh.imageGenerationModelID?.uuidString,
                        fresh.imageEditingModelID?.uuidString,
                        fresh.defaultVideoModelID?.uuidString,
                        fresh.autonomousImageRouting ?? false,
                        PrivacySnapshotEngine.iso8601Fractional(fresh.updatedAt),
                        fresh.syncRevision,
                        revisionValue,
                    ])
                guard db.changesCount == 1 else {
                    return PreferencesResetOutcome(
                        reset: false, newRevision: currentRevision,
                        failure: "preferencesCasChanges",
                        superseded: false)
                }
                return PreferencesResetOutcome(
                    reset: true, newRevision: Int(next), failure: nil,
                    superseded: false)
            }
        } catch {
            return PreferencesResetOutcome(
                reset: false, newRevision: 0,
                failure: Self.boundedReason(error), superseded: false)
        }
    }

    // MARK: - Model spool parsing / model accounting

    private static func parseProviderLine(_ line: String) throws -> ProviderTarget {
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 6, parts[0] == "v",
              let id = UUID(uuidString: String(parts[1])),
              parts[2] == "0" || parts[2] == "1",
              parts[3] == "0" || parts[3] == "1",
              let revision = Int64(parts[5]) else {
            throw PrivacyDomainError.persistenceUnavailable("spoolCorrupt")
        }
        let hasSecret = parts[2] == "1"
        var secret: PrivacyProviderSecretReference?
        if hasSecret {
            guard let account = PrivacyClearSpoolWriter.unhex(String(parts[4])) else {
                throw PrivacyDomainError.persistenceUnavailable("spoolCorrupt")
            }
            secret = PrivacyProviderSecretReference(
                account: account, synchronizable: parts[3] == "1")
        }
        return ProviderTarget(id: id, secret: secret, syncRevision: revision)
    }

    private static func enumeratedModelCounts(
        spool: PrivacyClearSpool, providerIDs: Set<UUID>
    ) throws -> [UUID: Int] {
        guard !providerIDs.isEmpty else { return [:] }
        var counts: [UUID: Int] = [:]
        let reader = try spool.reader(section: "models")
        try reader.forEachLine { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "m",
                  UUID(uuidString: String(parts[1])) != nil,
                  let owner = UUID(uuidString: String(parts[2])) else {
                throw PrivacyDomainError.persistenceUnavailable("spoolCorrupt")
            }
            if providerIDs.contains(owner) {
                counts[owner, default: 0] += 1
            }
        }
        return counts
    }

    /// Project only captured preference references (at most eleven).
    internal static func observedPreferenceModelIDs(
        _ record: [SettingsDomainV1.CanonicalDigest.Field]?
    ) -> Set<UUID> {
        let columns = PrivacySnapshotEngine.preferenceColumns
        guard let record, record.count == columns.count else { return [] }
        return Set(zip(columns, record).compactMap { name, field in
            guard cascadeNulledModelReferenceColumns.contains(name),
                  case .text(let rawID) = field else { return nil }
            return UUID(uuidString: rawID)
        })
    }

    /// Stream the target spool, retaining only the bounded preference IDs.
    private static func enumeratedModelIDs(
        spool: PrivacyClearSpool, providerID: UUID, matching: Set<UUID>
    ) throws -> Set<UUID> {
        var ids = Set<UUID>()
        let reader = try spool.reader(section: "models")
        try reader.forEachLine { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "m",
                  let id = UUID(uuidString: String(parts[1])),
                  let owner = UUID(uuidString: String(parts[2])) else {
                throw PrivacyDomainError.persistenceUnavailable("spoolCorrupt")
            }
            if owner == providerID && matching.contains(id) {
                ids.insert(id)
            }
        }
        return ids
    }

    // MARK: - Error mapping (bounded opaque reasons only)

    private static func mapFenceError(_ error: Error) -> PrivacyDomainError {
        if let privacy = error as? PrivacyDomainError { return privacy }
        if let run = error as? RunDomainError {
            switch run.code {
            case .duplicateInFlight:
                return .duplicateInFlight
            case .sessionFenced:
                return .sessionFenced(run.reason.rawValue)
            case .persistenceUnavailable:
                return .persistenceUnavailable(run.reason.rawValue)
            default:
                return .runtimeUnavailable(run.reason.rawValue)
            }
        }
        return .sessionFenced("globalAdmissionFenceUnavailable")
    }

    private static func mapLifecycleFailure(
        _ failure: ConversationDeletionLifecycleFailure
    ) -> PrivacyDomainError {
        switch failure {
        case .epochMismatch:
            return .sessionFenced("deletionFenceEpochMismatch")
        case .fenceHeld:
            return .duplicateInFlight
        case .conversationNotFound:
            return .notFound
        case .fenceTokenRefused:
            return .sessionFenced("deletionFenceTokenRefused")
        case .ownerUnavailable(let reason),
             .drainUnavailable(let reason),
             .reportUnavailable(let reason):
            return .runtimeUnavailable(reason)
        }
    }

    /// Redaction discipline: only bounded opaque tokens cross this line —
    /// never row content, paths, account names or secret material.
    private static func boundedReason(_ error: Error) -> String? {
        switch error {
        case let privacy as PrivacyDomainError:
            return PrivacyWireBounding.reason(privacy.wireReason ?? privacy.wireCode)
        case let floe as FloeError:
            switch floe {
            case .storageCorrupted(_): return "storageCorrupted"
            case .notFound(_): return "notFound"
            case .cancelled: return "cancelled"
            case .unauthorized: return "unauthorized"
            case .syncUnavailable(_): return "syncUnavailable"
            case .invalidConfiguration(_): return "invalidConfiguration"
            case .validationFailed(_): return "validationFailed"
            case .internalError(_): return "internal"
            }
        case is CancellationError:
            return "cancelled"
        default:
            return "internal"
        }
    }
}

// MARK: - Bounded incremental failure collector (producer side)

/// Collects per-item/per-phase failures during ONE clear WITHOUT an
/// unbounded in-RAM inventory:
///
///   * every failure is appended INCREMENTALLY to a root-private staged
///     report spool (verified immutable publication at the end);
///   * RAM keeps at most the bounded initial page (`initialFailureItems`),
///     a small post-degradation overflow cushion and exact counts;
///   * the spool is ARRANGED BEFORE the first destructive effect: a
///     creation failure refuses the clear typed with nothing deleted;
///   * the FIRST spool write failure stops further destructive work (the
///     loops break at the next item boundary) — failures already taken stay
///     truthful through the bounded initial array and, when the report is
///     larger, through the finalized verified spool;
///   * if the report cannot be finalized truthfully (finalize failure or
///     the bounded overflow cushion overflowed), the clear fails typed
///     `persistenceUnavailable` — it never returns a report that hides
///     truncation or claims full success.
private struct PrivacyFailureCollector<Failure: Sendable> {
    let kind: PrivacyReportKind
    private var writer: PrivacyFailureReportSpoolWriter
    private let project: @Sendable (Failure) -> PrivacyFailurePageItem
    /// Bounded initial page (the report's wire `failures` array).
    private(set) var initial: [Failure] = []
    /// Exact total failure count (spooled + overflow).
    private(set) var total = 0
    private var overflow: [PrivacyFailurePageItem] = []
    private var spoolAlive = true
    private var unrecordedGap = false

    init(rootPath: String, kind: PrivacyReportKind, root: String,
         epoch: UInt64, operationID: UUID,
         project: @escaping @Sendable (Failure) -> PrivacyFailurePageItem)
        throws
    {
        self.kind = kind
        self.project = project
        self.writer = try PrivacyFailureReportSpoolWriter(
            rootPath: rootPath, kind: kind, root: root, epoch: epoch,
            operationID: operationID)
    }

    /// True once report storage has failed; the destructive loops must stop
    /// at their next item boundary ("stop further destructive work when
    /// report storage fails").
    var degraded: Bool { !spoolAlive }

    /// True when even the bounded overflow cannot hold what happened; the
    /// clear can no longer report truthfully and must fail typed.
    var unreportable: Bool { unrecordedGap }

    mutating func record(_ failure: Failure) {
        if initial.count < PrivacyReportLimits.initialFailureItems {
            initial.append(failure)
        }
        let item = project(failure)
        if spoolAlive {
            do {
                try writer.append(item)
            } catch {
                spoolAlive = false
                appendOverflow(item)
            }
        } else {
            appendOverflow(item)
        }
        total += 1
    }

    private mutating func appendOverflow(_ item: PrivacyFailurePageItem) {
        if overflow.count < PrivacyReportSpoolLimits.overflowItemLimit {
            overflow.append(item)
        } else {
            unrecordedGap = true
        }
    }

    /// Finalizes the staged spool into an immutable verified report and
    /// registers it with the store. Returns the terminal-page summary, or
    /// nil when the bounded initial array already holds every failure (the
    /// staged spool is removed and no handle is minted). Throws typed when
    /// the report cannot be published truthfully.
    mutating func finish(reportStore: PrivacyReportStore,
                         now: Date) throws
        -> PrivacyFailurePageSummary?
    {
        if total <= PrivacyReportLimits.initialFailureItems {
            writer.abort()
            return nil
        }
        if !overflow.isEmpty {
            // Drain the bounded overflow through the writer (covers a
            // transient write failure). A still-broken spool fails the clear
            // typed rather than publishing an incomplete report.
            for item in overflow {
                do {
                    try writer.append(item)
                } catch {
                    writer.abort()
                    throw PrivacyDomainError.persistenceUnavailable(
                        "reportSpoolFinalize")
                }
            }
            overflow.removeAll()
        }
        guard !unrecordedGap else {
            writer.abort()
            throw PrivacyDomainError.persistenceUnavailable(
                "reportSpoolOverflow")
        }
        let handle = PrivacyFailureReportHandle.mint()
        let descriptor = try writer.finish(
            reportHandle: handle, createdAt: now)
        return try reportStore.adopt(descriptor)
    }

    /// Removes the staged spool (clear aborted before completion).
    mutating func abort() {
        writer.abort()
        spoolAlive = false
        overflow.removeAll()
    }
}
