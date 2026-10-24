// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 trusted source coordinator — the Swift-side authority port the
// frozen `core/safgateway` OS gateway (and later webdav/smb producers)
// registers through. It binds MAIN's `AndroidWorkspaceSourceStore` journal 47
// (metadata-only authority) to NATIVE-VALIDATED facts:
//
//   * a source becomes known ONLY through exact task/workspace/logical-path
//     IDs re-validated against the ORIGINAL durable records, plus the ACTUAL
//     imported bytes the coordinator itself hashes — a picker URI string or
//     a Kotlin "success" callback is never an authority input;
//   * provider replacement follows the frozen two-phase journal sequence:
//     validate owned backup bytes -> prepareRecovery (binding revision CAS)
//     -> fresh observed source hash -> ONE-TIME claimRecovery -> transport
//     write -> actual read-back hash -> finishRecovery. Every phase re-checks
//     exact identity and holds a REAL `.conversation` owned-work token
//     through the OS transport IO (attached before, detached only after the
//     IO actually settles — never a timeout detach, never a fabricated
//     token);
//   * the OS transport is a protocol Main's JNI/SAF adapter implements.
//     While unbound, every provider-touching call answers typed
//     `transportNotBound` — no fake granted/written callbacks, no generic
//     provider CAS claim, and normal workspace payloads can never reach or
//     widen this surface (the closed bridge grammar carries no source
//     fields at all).
//
// Process-death honesty: a persisted `writing` receipt is NEVER re-permitted
// and never auto-greens. `reconcileInterruptedReplacements` decides each
// unfinished receipt ONLY from the ACTUAL observed provider bytes: matching
// replacement -> committed (binding CAS), matching backup -> retained
// (retryable after review), anything else -> conflict. Recovery metadata
// survives source/workspace deletion; the BYTES stay in the caller-owned
// native staging/recovery files exactly as the frozen gateway module
// requires, and this coordinator never deletes them.
import Foundation
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkspace
import GRDB

public enum G04SourceCoordinatorError: Error, Sendable, Equatable {
    case retired
    case conversationMissing
    case purposeNotOrdinary
    case workspaceUnbound
    case ownerChanged
    case invalidMetadata(String)
    case stagedBytesUnavailable(String)
    case digestMismatch(expected: String, actual: String)
    case transportNotBound
    case sourceMissing
    case staleRevision
    case transitionRefused(String)
    case readbackMismatch
    case providerFailed(code: String)
    case tooLarge(limit: Int)
    /// Trusted-host staging/commit ran out of physical space (typed; the
    /// caller-owned staged bytes and the workspace file stay exactly as they
    /// were — recoverable, never a partial success claim).
    case diskFull
    /// A file-backed source operation refused against the ACTUAL on-disk
    /// working-copy state (existing different bytes, missing file, unsafe
    /// shape). Additive to the frozen enum; old cases keep their meaning.
    case invalidWorkingCopy(String)
}

public actor G04WorkspaceSourceCoordinator {
    /// The native-owned staged working copy a trusted platform producer
    /// hands BEFORE any provider touch. Bytes, not strings: the coordinator
    /// re-hashes them itself.
    public struct StagedBytes: Sendable {
        public let data: Data
        public init(data: Data) { self.data = data }
    }

    /// Main's JNI/SAF adapter implements this over the frozen
    /// `SafGatewayService` (cancellable PFD/stream reads, serialized
    /// `wt` writes, provider read-back). Unbound = typed refusal, never a
    /// simulated success.
    public protocol Transport: Sendable {
        func readSource(taskID: UUID, workspaceID: UUID, logicalPath: String,
                        sourceReference: String, sourceDocumentID: String?,
                        maxBytes: Int, cancellation: CancellationToken) async throws -> Data
        func writeSource(taskID: UUID, workspaceID: UUID, logicalPath: String,
                         sourceReference: String, sourceDocumentID: String?,
                         bytes: Data, cancellation: CancellationToken) async throws
        /// True when this transport can ACTUALLY dispatch provider IO for the
        /// given live root epoch right now. A transport OBJECT is attached at
        /// generation attach; the trusted host pump becomes dispatch-ready
        /// only when it binds THIS epoch (`floe_g04_source_bind`). Before
        /// that, provider-touching entries answer the documented typed
        /// `transportNotBound` instead of a generic success — including a
        /// reconcile sweep that happens to have no outstanding receipt.
        func isDispatchReady(rootEpoch: UInt64) async -> Bool
    }

    /// Result of one accepted prepared replacement.
    public struct ReplacementReceipt: Sendable, Equatable {
        public let recovery: AndroidWorkspaceRecovery
        public let source: AndroidWorkspaceSource
    }

    public static let maximumSourceBytes = G04WorkspaceDocumentSession.maximumDocumentBytes

    /// The ORIGINAL G03 transfer entry budget
    /// (`WorkspaceTransferLimits.defaults.maximumEntryBytes`): ordinary
    /// provider file copy/import/export streams under THIS cap. The 4 MiB
    /// `maximumSourceBytes` above is the editable-TEXT document budget for
    /// the mailbox/Data transport and is NOT a copy ceiling — the trusted
    /// host chunk channel moves bytes under this larger, original limit.
    public static let maximumProviderCopyBytes = Int(Int64(1) << 30)

    public let epoch: UInt64
    private let cluster: G02OwnedStoreCluster
    private let store: AndroidWorkspaceSourceStore
    private var transport: (any Transport)?
    private var retired = false

    init(epoch: UInt64, cluster: G02OwnedStoreCluster) {
        self.epoch = epoch
        self.cluster = cluster
        self.store = AndroidWorkspaceSourceStore(database: cluster.database)
    }

    /// Trusted composition attaches the platform transport EXACTLY ONCE
    /// while the same root/epoch is live. Never called from a bridge
    /// payload, a picker result or model output.
    public func attachTransport(_ transport: any Transport) -> Bool {
        guard !retired, self.transport == nil,
              G02NativeRootEpoch.readback() == epoch,
              G02RuntimeComposition.shared.installedComposition?.epoch == epoch else { return false }
        self.transport = transport
        return true
    }

    public var isTransportBound: Bool { transport != nil }

    /// Exact-epoch RootStop: refuses all later provider admissions. The IO
    /// leases already attached settle through the REAL RB1 owned-work drain
    /// before the database closes; this call never detaches them itself.
    public func retire() { retired = true; transport = nil }

    // MARK: - Exact identity validation (original durable records, across awaits)

    private var compositionIsLive: Bool {
        !retired && epoch == G02NativeRootEpoch.readback()
            && G02RuntimeComposition.shared.installedComposition?.epoch == epoch
            && RunDomainFacade.current(epoch: epoch) != nil
    }

    private func requireOrdinaryConversation(taskID: UUID, workspaceID: UUID) async throws {
        guard compositionIsLive else { throw G04SourceCoordinatorError.retired }
        guard let conversation = try await cluster.conversationStore.conversation(id: taskID)
        else { throw G04SourceCoordinatorError.conversationMissing }
        guard conversation.purpose == .ordinary else { throw G04SourceCoordinatorError.purposeNotOrdinary }
        guard try await cluster.workspaceStore.workspaceID(conversationID: taskID) == workspaceID,
              try await cluster.workspaceStore.workspace(id: workspaceID) != nil
        else { throw G04SourceCoordinatorError.ownerChanged }
        guard compositionIsLive else { throw G04SourceCoordinatorError.retired }
    }

    /// The REAL `.conversation` owned-work lease through OS IO. The frozen
    /// run-domain helper attaches before any provider touch and detaches
    /// only after the actual IO settles; admission while the root is
    /// draining/retired honestly returns nil.
    private func beginLease(taskID: UUID) async -> G04WorkspaceOwnedOperation? {
        guard let (domain, _) = RunDomainFacade.current(epoch: epoch) else { return nil }
        return await domain.beginG04WorkspaceOperation(conversationID: taskID, expectedEpoch: epoch)
    }

    private func endLease(_ operation: G04WorkspaceOwnedOperation) async {
        guard let (domain, _) = RunDomainFacade.current(epoch: epoch) else { return }
        await domain.endG04WorkspaceOperation(operation)
    }

    private func settledTransport() throws -> any Transport {
        guard let transport else { throw G04SourceCoordinatorError.transportNotBound }
        return transport
    }

    // MARK: - Trusted source registration

    /// Registers (or CAS-rebinds) the OS source behind a workspace logical
    /// path. `staged` carries the ACTUAL imported bytes the trusted producer
    /// read from the provider; the coordinator hashes them itself and stores
    /// ONLY metadata rows (reference string, opaque IDs, digests — never
    /// bytes, never credentials). The `content://` shape and path canons are
    /// enforced by the journal; a POSIX path or credential-bearing URL
    /// refuses typed.
    public func registerImportedSource(sourceID: UUID, taskID: UUID, workspaceID: UUID,
                                       logicalPath: String, sourceReference: String,
                                       sourceDocumentID: String?, staged: StagedBytes,
                                       entityTag: String? = nil,
                                       expectedRevision: String? = nil) async throws
        -> AndroidWorkspaceSource {
        guard staged.data.count <= Self.maximumSourceBytes else {
            throw G04SourceCoordinatorError.tooLarge(limit: Self.maximumSourceBytes)
        }
        guard !staged.data.isEmpty else {
            throw G04SourceCoordinatorError.stagedBytesUnavailable("empty")
        }
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        let digest = FloeDigest.sha256Hex(staged.data)
        let bound = try await store.bind(id: sourceID, workspaceID: workspaceID,
                                          logicalPath: logicalPath, kind: .saf,
                                          sourceReference: sourceReference,
                                          sourceDocumentID: sourceDocumentID,
                                          sourceSHA256: digest, entityTag: entityTag,
                                          expectedRevision: expectedRevision)
        guard bound.sourceSHA256 == digest else {
            throw G04SourceCoordinatorError.digestMismatch(expected: digest,
                                                            actual: bound.sourceSHA256 ?? "")
        }
        return bound
    }

    // MARK: - Two-phase provider replacement

    /// Phase 1 — validate the owned backup bytes ACTUALLY match the recorded
    /// source state, re-observe the CURRENT provider bytes through the bound
    /// transport (fresh hash — a stale snapshot never opens a permit), then
    /// commit ONE `prepared` journal row with CAS on the binding revision.
    public func prepareReplacement(sourceID: UUID, taskID: UUID, workspaceID: UUID,
                                    logicalPath: String, backup: StagedBytes,
                                    replacement: StagedBytes) async throws -> ReplacementReceipt {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        guard backup.data.count <= Self.maximumSourceBytes,
              replacement.data.count <= Self.maximumSourceBytes else {
            throw G04SourceCoordinatorError.tooLarge(limit: Self.maximumSourceBytes)
        }
        guard let source = try await store.source(id: sourceID),
              source.workspaceID == workspaceID, source.logicalPath == logicalPath,
              let recorded = source.sourceSHA256
        else { throw G04SourceCoordinatorError.sourceMissing }
        let backupDigest = FloeDigest.sha256Hex(backup.data)
        guard backupDigest == recorded else {
            throw G04SourceCoordinatorError.digestMismatch(expected: recorded, actual: backupDigest)
        }
        let transport = try settledTransport()
        guard let lease = await beginLease(taskID: taskID) else {
            throw G04SourceCoordinatorError.retired
        }
        let fresh: Data
        do {
            fresh = try await transport.readSource(taskID: taskID, workspaceID: workspaceID,
                                                    logicalPath: logicalPath,
                                                    sourceReference: source.sourceReference,
                                                    sourceDocumentID: source.sourceDocumentID,
                                                    maxBytes: Self.maximumSourceBytes,
                                                    cancellation: lease.cancellation)
        } catch {
            await endLease(lease)
            throw error
        }
        let freshDigest = FloeDigest.sha256Hex(fresh)
        guard freshDigest == recorded else {
            // External drift since registration: NO prepared permit is
            // created for the stale backup; the caller must re-import.
            await endLease(lease)
            throw G04SourceCoordinatorError.digestMismatch(expected: recorded, actual: freshDigest)
        }
        let replacementDigest = FloeDigest.sha256Hex(replacement.data)
        let receiptID = UUID()
        // Trusted native-owned recovery reference for the caller-staged
        // backup identity; the journal records the path + digests only, and
        // the bytes stay owned by the platform producer (never deleted here).
        let backupRelativePath = "Source Recovery/\(sourceID.uuidString)/\(receiptID.uuidString).bin"
        do {
            let recovery = try await store.prepareRecovery(id: receiptID, sourceID: sourceID,
                                                            expectedRevision: source.revision,
                                                            backupRelativePath: backupRelativePath,
                                                            backupSHA256: backupDigest,
                                                            replacementSHA256: replacementDigest)
            await endLease(lease)
            return ReplacementReceipt(recovery: recovery, source: source)
        } catch {
            await endLease(lease)
            throw error
        }
    }

    /// Phase 2 — ONE durable `prepared -> writing` claim, admitted only with
    /// a FRESH provider observation. Replaying a claimed receipt never issues
    /// a second write permit.
    public func claimReplacement(recoveryID: UUID, sourceID: UUID, taskID: UUID, workspaceID: UUID,
                                  logicalPath: String) async throws -> AndroidWorkspaceRecovery {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        let transport = try settledTransport()
        guard let source = try await store.source(id: sourceID), source.workspaceID == workspaceID,
              source.logicalPath == logicalPath
        else { throw G04SourceCoordinatorError.sourceMissing }
        guard let lease = await beginLease(taskID: taskID) else {
            throw G04SourceCoordinatorError.retired
        }
        let fresh: Data
        do {
            fresh = try await transport.readSource(taskID: taskID, workspaceID: workspaceID,
                                                    logicalPath: logicalPath,
                                                    sourceReference: source.sourceReference,
                                                    sourceDocumentID: source.sourceDocumentID,
                                                    maxBytes: Self.maximumSourceBytes,
                                                    cancellation: lease.cancellation)
        } catch {
            await endLease(lease)
            throw error
        }
        do {
            let claimed = try await store.claimRecovery(id: recoveryID,
                                                          observedSourceSHA256: FloeDigest.sha256Hex(fresh))
            await endLease(lease)
            return claimed
        } catch {
            await endLease(lease)
            throw error
        }
    }

    /// Phase 3 — transport write under a REAL owned-work lease, then the
    /// ACTUAL read-back decides the journal terminal. A read-back that does
    /// not equal the replacement never receives `committed`: it is honestly
    /// recorded `conflict` (bytes stay for reconciliation).
    public func writeReplacement(recoveryID: UUID, sourceID: UUID, taskID: UUID, workspaceID: UUID,
                                  logicalPath: String, replacement: StagedBytes) async throws
        -> AndroidWorkspaceRecovery {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        guard replacement.data.count <= Self.maximumSourceBytes else {
            throw G04SourceCoordinatorError.tooLarge(limit: Self.maximumSourceBytes)
        }
        let transport = try settledTransport()
        guard let source = try await store.source(id: sourceID), source.workspaceID == workspaceID,
              source.logicalPath == logicalPath
        else { throw G04SourceCoordinatorError.sourceMissing }
        let replacementDigest = FloeDigest.sha256Hex(replacement.data)
        guard let lease = await beginLease(taskID: taskID) else {
            throw G04SourceCoordinatorError.retired
        }
        let terminal: AndroidWorkspaceRecovery
        do {
            // The write attempt may settle with a real failure; the receipt
            // stays exactly where it is (`writing`) and reconcile decides
            // its truth from the provider later. Never a fake rollback.
            try await transport.writeSource(taskID: taskID, workspaceID: workspaceID,
                                             logicalPath: logicalPath,
                                             sourceReference: source.sourceReference,
                                             sourceDocumentID: source.sourceDocumentID,
                                             bytes: replacement.data, cancellation: lease.cancellation)
            let readBack = try await transport.readSource(taskID: taskID, workspaceID: workspaceID,
                                                           logicalPath: logicalPath,
                                                           sourceReference: source.sourceReference,
                                                           sourceDocumentID: source.sourceDocumentID,
                                                           maxBytes: Self.maximumSourceBytes,
                                                           cancellation: lease.cancellation)
            let observed = FloeDigest.sha256Hex(readBack)
            if observed == replacementDigest {
                terminal = try await store.finishRecovery(id: recoveryID, requestedState: .committed,
                                                            observedSHA256: observed, entityTag: nil)
            } else {
                terminal = try await store.finishRecovery(id: recoveryID, requestedState: .conflict,
                                                            observedSHA256: observed, entityTag: nil)
            }
        } catch {
            await endLease(lease)
            throw error
        }
        await endLease(lease)
        return terminal
    }

    /// Honest abandon: keeps the journaled recovery reference (the caller
    /// still owns the backup bytes) and records `retained`. Never deletes.
    public func retainReplacement(recoveryID: UUID, taskID: UUID, workspaceID: UUID) async throws
        -> AndroidWorkspaceRecovery {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        return try await store.finishRecovery(id: recoveryID, requestedState: .retained,
                                               observedSHA256: nil, entityTag: nil)
    }

    public func pendingRecovery(workspaceID: UUID?, afterID: String? = nil, limit: Int = 100) async throws
        -> [AndroidWorkspaceRecovery] {
        try await store.pendingRecovery(workspaceID: workspaceID, afterID: afterID, limit: limit)
    }

    /// METADATA journal page over EVERY recovery state (settled `committed`
    /// included), stable id order, same bounds as the pending view. This is
    /// the host receipts page the trusted UI reads; reconcile sweeps keep
    /// using `pendingRecovery` (unfinished receipts only). No bytes, no
    /// provider identity beyond the journaled reference/revision.
    public func recoveryJournal(workspaceID: UUID?, afterID: String? = nil, limit: Int = 100) async throws
        -> [AndroidWorkspaceRecovery] {
        try await store.recoveryJournal(workspaceID: workspaceID, afterID: afterID, limit: limit)
    }

    /// Reconcile interrupted (process-death) receipts from ACTUAL provider
    /// observation ONLY. Requires the bound transport; with none attached
    /// every unfinished row stays honestly pending. Never re-permits a
    /// `writing` claim and never retries-to-green.
    public func reconcileInterruptedReplacements(workspaceID: UUID? = nil) async throws -> Int {
        guard compositionIsLive else { throw G04SourceCoordinatorError.retired }
        let transport = try settledTransport()
        // Attached is not dispatchable: the SAF pump counts only once the
        // trusted host binds THIS live epoch. With no pump bound this
        // provider-touching entry answers the documented typed refusal
        // BEFORE any receipt/row is touched — never a generic `ok` because
        // the sweep happened to have nothing outstanding.
        guard await transport.isDispatchReady(rootEpoch: epoch) else {
            throw G04SourceCoordinatorError.transportNotBound
        }
        let pending = try await store.pendingRecovery(workspaceID: workspaceID, limit: 200)
        var settled = 0
        for receipt in pending where receipt.state == .prepared || receipt.state == .writing {
            guard let source = try await store.source(id: receipt.sourceID),
                  source.workspaceID == receipt.workspaceID,
                  source.sourceReference == receipt.sourceReference
            else {
                _ = try await store.finishRecovery(id: receipt.id, requestedState: .conflict,
                                                    observedSHA256: nil, entityTag: nil)
                settled += 1
                continue
            }
            // The conversation owning the source row (the ORIGINAL
            // `conversation_workspace_ownership` authority) is the ONLY
            // lifecycle identity that may admit IO for this receipt; without
            // a live ordinary conversation owner the row stays honestly
            // pending — no lease, no IO, no state claim.
            let owners = try await cluster.workspaceStore.conversations(workspaceID: receipt.workspaceID)
            guard let ownerID = owners.first, owners.count == 1,
                  let conversation = try await cluster.conversationStore.conversation(id: ownerID),
                  conversation.purpose == .ordinary
            else { continue }
            guard let lease = await beginLease(taskID: conversation.id) else { continue }
            let observed: Data
            do {
                observed = try await transport.readSource(taskID: conversation.id,
                                                           workspaceID: receipt.workspaceID,
                                                           logicalPath: source.logicalPath,
                                                           sourceReference: source.sourceReference,
                                                           sourceDocumentID: source.sourceDocumentID,
                                                           maxBytes: Self.maximumSourceBytes,
                                                           cancellation: lease.cancellation)
            } catch {
                await endLease(lease)
                continue   // provider offline: stays pending, honestly
            }
            let digest = FloeDigest.sha256Hex(observed)
            do {
                if digest == receipt.replacementSHA256 {
                    // The write DID land before the process died: commit
                    // with the binding revision CAS (refused on drift).
                    let finished = try await store.finishRecovery(id: receipt.id,
                                                                   requestedState: .committed,
                                                                   observedSHA256: digest, entityTag: nil)
                    if finished.state == .committed { settled += 1 }
                } else if digest == receipt.backupSHA256 {
                    // Provider still holds the backed-up original: the
                    // replacement never happened. Retained for review.
                    _ = try await store.finishRecovery(id: receipt.id, requestedState: .retained,
                                                        observedSHA256: digest, entityTag: nil)
                    settled += 1
                } else {
                    _ = try await store.finishRecovery(id: receipt.id, requestedState: .conflict,
                                                        observedSHA256: digest, entityTag: nil)
                    settled += 1
                }
            } catch {
                // Journal refused: the row remains unfinished — honest.
            }
            await endLease(lease)
        }
        return settled
    }

    // MARK: - Trusted host file-backed authority overloads (G04-R1 provider source host)
    //
    // These overloads exist so the narrow `G04WorkspaceSourceHostAPI` C ABI
    // can run the SAME authority ladder over ORDINARY provider files that
    // exceed the 4 MiB editable-document budget: bytes reach native through
    // bounded chunk staging inside the trusted host lane, every digest that
    // enters journal 47 is computed by NATIVE over the staged/committed
    // bytes it actually holds (never a Kotlin-computed string), and the
    // working copy is created only through the ORIGINAL
    // `WorkspaceFileService.importUserFile` atomic verified commit under the
    // exact private-task binding. No second store, no second authority, no
    // caller-named POSIX root: the only paths these methods ever touch are
    // the guard-resolved workspace destination and the trusted host staging
    // URLs produced by the SAME module's session table.

    /// The accepted native storage root for trusted host staging lanes
    /// (never crosses the C boundary; only same-module HostAPI code
    /// allocates under it, exactly like the accepted attachment staging
    /// derives its directories from the owned identity root).
    nonisolated public var storageRootPath: String { cluster.identity.root.path }

    /// Outcome of one host-chunked import: the EXACT committed digest the
    /// coordinator itself observed after the atomic commit + independent
    /// read-back, and the durably bound journal-47 row.
    public struct ImportedFileOutcome: Sendable, Equatable {
        public let source: AndroidWorkspaceSource
        public let committedSHA256: String
        public let committedBytes: Int
    }

    /// Registers a provider file the trusted host has ALREADY streamed into
    /// a native-owned staging file: hash the staged bytes (streaming),
    /// commit them through the ORIGINAL `importUserFile` (same-directory
    /// temp + size/mtime clamp + digest-verified no-overwrite move), then
    /// RE-HASH the committed workspace file and only then bind journal 47
    /// with that post-commit digest. Idempotent by construction: a retry
    /// after a crash between commit and bind sees the same-digest file and
    /// completes the binding; a same-path file with DIFFERENT bytes is a
    /// typed refusal (nothing is overwritten, both bodies stay recoverable).
    public func importStagedFile(sourceID: UUID, taskID: UUID, workspaceID: UUID,
                                 logicalPath: String, sourceReference: String,
                                 sourceDocumentID: String?, stagedURL: URL,
                                 stagedBytes: Int, entityTag: String? = nil,
                                 expectedRevision: String? = nil) async throws
        -> ImportedFileOutcome {
        try await importStagedFileCore(sourceID: sourceID, taskID: taskID,
                                       workspaceID: workspaceID, logicalPath: logicalPath,
                                       kind: .saf, sourceReference: sourceReference,
                                       sourceDocumentID: sourceDocumentID,
                                       stagedURL: stagedURL, stagedBytes: stagedBytes,
                                       entityTag: entityTag, expectedRevision: expectedRevision)
    }

    /// NETWORK counterpart of `importStagedFile` (lane job-20000d7c450d4353,
    /// additive): the SAME verified commit ladder binding a
    /// `webdav`/`smb` source row. `sourceReference` is the durable mount
    /// identity (canonical UUID — the journal's own grammar for non-SAF
    /// kinds) and `sourceDocumentID` carries the mount-relative remote path
    /// the native mount owner re-reads for drift/claim/read-back. Nothing
    /// else differs: identical lease, `importUserFile` atomic no-overwrite
    /// commit, post-commit re-hash, same-digest retry vs
    /// `workingCopyExists` refusal, and the ORIGINAL journal-47 bind.
    public func importStagedSourceFile(sourceID: UUID, taskID: UUID, workspaceID: UUID,
                                       logicalPath: String, kind: AndroidWorkspaceSourceKind,
                                       sourceReference: String, sourceDocumentID: String?,
                                       stagedURL: URL, stagedBytes: Int,
                                       entityTag: String? = nil,
                                       expectedRevision: String? = nil) async throws
        -> ImportedFileOutcome {
        guard kind == .webdav || kind == .smb else {
            throw G04SourceCoordinatorError.invalidMetadata("use importStagedFile for saf")
        }
        return try await importStagedFileCore(sourceID: sourceID, taskID: taskID,
                                              workspaceID: workspaceID, logicalPath: logicalPath,
                                              kind: kind, sourceReference: sourceReference,
                                              sourceDocumentID: sourceDocumentID,
                                              stagedURL: stagedURL, stagedBytes: stagedBytes,
                                              entityTag: entityTag, expectedRevision: expectedRevision)
    }

    private func importStagedFileCore(sourceID: UUID, taskID: UUID, workspaceID: UUID,
                                      logicalPath: String, kind: AndroidWorkspaceSourceKind,
                                      sourceReference: String, sourceDocumentID: String?,
                                      stagedURL: URL, stagedBytes: Int,
                                      entityTag: String?,
                                      expectedRevision: String?) async throws
        -> ImportedFileOutcome {
        guard stagedBytes > 0, stagedBytes <= Self.maximumProviderCopyBytes else {
            throw stagedBytes == 0 ? G04SourceCoordinatorError.stagedBytesUnavailable("empty")
                                   : G04SourceCoordinatorError.tooLarge(limit: Self.maximumProviderCopyBytes)
        }
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        guard let lease = await beginLease(taskID: taskID) else {
            throw G04SourceCoordinatorError.retired
        }
        do {
            let owner = G04WorkspaceOwner(epoch: epoch, taskID: taskID, workspaceID: workspaceID)
            let service = try await G04LiveWorkspaceAccess.privateTaskService(owner,
                                                                              cancellation: lease.cancellation)
            let stagedDigest = try FloeDigest.sha256Hex(ofFileAt: stagedURL,
                                                        isCancelled: { lease.cancellation.isCancelled })
            let destinationURL = try service.guardResolver.resolve(logicalPath)
            var committedDigest = stagedDigest
            var committedBytes = stagedBytes
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                let existing = try FloeDigest.sha256Hex(ofFileAt: destinationURL,
                                                        isCancelled: { lease.cancellation.isCancelled })
                let existingSize = (try? FileManager.default
                    .attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.intValue ?? -1
                guard existing == stagedDigest, existingSize == stagedBytes else {
                    await endLease(lease)
                    throw G04SourceCoordinatorError.transitionRefused("workingCopyExists")
                }
                // Interrupted-attempt retry: the verified body already sits
                // at the exact path; skip re-import and finish the binding.
            } else {
                _ = try service.importUserFile(from: stagedURL, to: logicalPath,
                                               expectedSHA256: stagedDigest,
                                               cancellation: lease.cancellation)
                committedDigest = try FloeDigest.sha256Hex(ofFileAt: destinationURL,
                                                           isCancelled: { lease.cancellation.isCancelled })
                committedBytes = (try? FileManager.default
                    .attributesOfItem(atPath: destinationURL.path)[.size] as? NSNumber)?.intValue ?? -1
                guard committedDigest == stagedDigest, committedBytes == stagedBytes else {
                    await endLease(lease)
                    throw G04SourceCoordinatorError.digestMismatch(expected: stagedDigest,
                                                                    actual: committedDigest)
                }
            }
            let bound = try await store.bind(id: sourceID, workspaceID: workspaceID,
                                             logicalPath: logicalPath, kind: kind,
                                             sourceReference: sourceReference,
                                             sourceDocumentID: sourceDocumentID,
                                             sourceSHA256: committedDigest,
                                             entityTag: entityTag,
                                             expectedRevision: expectedRevision)
            guard bound.sourceSHA256 == committedDigest else {
                await endLease(lease)
                throw G04SourceCoordinatorError.digestMismatch(expected: committedDigest,
                                                                actual: bound.sourceSHA256 ?? "")
            }
            await endLease(lease)
            return ImportedFileOutcome(source: bound, committedSHA256: committedDigest,
                                       committedBytes: committedBytes)
        } catch {
            await endLease(lease)
            throw Self.remapFileError(error)
        }
    }

    /// Freezes one EXACT native working copy into a trusted host snapshot
    /// for chunked egress (save/export replacement bytes). Single-pass copy
    /// with an incremental digest plus a streaming re-hash of the snapshot:
    /// the digest that later enters the journal is native-observed over the
    /// snapshot the host will actually stream, not a caller claim.
    public struct WorkingCopySnapshot: Sendable, Equatable {
        public let sha256: String
        public let bytes: Int
    }

    public func snapshotWorkingCopy(taskID: UUID, workspaceID: UUID, logicalPath: String,
                                    snapshotURL: URL) async throws -> WorkingCopySnapshot {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        guard let lease = await beginLease(taskID: taskID) else {
            throw G04SourceCoordinatorError.retired
        }
        do {
            let owner = G04WorkspaceOwner(epoch: epoch, taskID: taskID, workspaceID: workspaceID)
            let service = try await G04LiveWorkspaceAccess.privateTaskService(owner,
                                                                              cancellation: lease.cancellation)
            let sourceURL = try service.guardResolver.resolve(logicalPath)
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            let before = try sourceURL.resourceValues(forKeys: keys)
            guard before.isRegularFile == true, before.isSymbolicLink != true,
                  let size = before.fileSize, size > 0,
                  size <= Self.maximumProviderCopyBytes else {
                await endLease(lease)
                throw G04SourceCoordinatorError.invalidWorkingCopy("notRegularFile")
            }
            try Self.streamCopy(from: sourceURL, to: snapshotURL,
                                freeReservePath: snapshotURL.deletingLastPathComponent().path,
                                cancellation: lease.cancellation)
            let streamedDigest = try FloeDigest.sha256Hex(ofFileAt: sourceURL,
                                                          isCancelled: { lease.cancellation.isCancelled })
            let snapshotDigest = try FloeDigest.sha256Hex(ofFileAt: snapshotURL,
                                                          isCancelled: { lease.cancellation.isCancelled })
            let after = try sourceURL.resourceValues(forKeys: keys)
            let snapshotSize = (try? snapshotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            guard snapshotSize == size, after.fileSize == before.fileSize,
                  snapshotDigest == streamedDigest else {
                await endLease(lease)
                throw G04SourceCoordinatorError.digestMismatch(expected: streamedDigest,
                                                                actual: snapshotDigest)
            }
            await endLease(lease)
            return WorkingCopySnapshot(sha256: snapshotDigest, bytes: size)
        } catch {
            await endLease(lease)
            throw Self.remapFileError(error)
        }
    }

    /// Journal phase 1 for the file-backed ladder: the trusted host has
    /// streamed the CURRENT provider bytes into native staging and native
    /// hashed them (`freshBackupSHA256`). This is the fresh observation —
    /// drift against the recorded digest creates NO permit (the original
    /// rule, byte-for-byte). The backup body itself stays caller-owned
    /// (`backupRelativePath` is a journaled identity reference only).
    public func prepareReplacementStaged(sourceID: UUID, taskID: UUID, workspaceID: UUID,
                                         logicalPath: String, recoveryID: UUID,
                                         freshBackupSHA256: String, backupRelativePath: String,
                                         replacementSHA256: String) async throws
        -> ReplacementReceipt {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        guard let source = try await store.source(id: sourceID),
              source.workspaceID == workspaceID, source.logicalPath == logicalPath,
              let recorded = source.sourceSHA256
        else { throw G04SourceCoordinatorError.sourceMissing }
        guard freshBackupSHA256 == recorded else {
            throw G04SourceCoordinatorError.digestMismatch(expected: recorded,
                                                            actual: freshBackupSHA256)
        }
        let recovery = try await store.prepareRecovery(id: recoveryID, sourceID: sourceID,
                                                        expectedRevision: source.revision,
                                                        backupRelativePath: backupRelativePath,
                                                        backupSHA256: freshBackupSHA256,
                                                        replacementSHA256: replacementSHA256)
        return ReplacementReceipt(recovery: recovery, source: source)
    }

    /// Journal phase 2 for the file-backed ladder: ONE durable
    /// `prepared -> writing` claim admitted only with a FRESH native-
    /// observed provider digest (`freshSHA256`, streamed and hashed by the
    /// host lane AFTER the prepare). Replay/drift is refused exactly like
    /// the transport-backed claim: no second permit, no soft branch.
    public func claimReplacementStaged(recoveryID: UUID, sourceID: UUID, taskID: UUID,
                                       workspaceID: UUID, logicalPath: String,
                                       freshSHA256: String) async throws
        -> AndroidWorkspaceRecovery {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        guard let source = try await store.source(id: sourceID),
              source.workspaceID == workspaceID, source.logicalPath == logicalPath,
              let recorded = source.sourceSHA256
        else { throw G04SourceCoordinatorError.sourceMissing }
        guard freshSHA256 == recorded else {
            throw G04SourceCoordinatorError.digestMismatch(expected: recorded, actual: freshSHA256)
        }
        return try await store.claimRecovery(id: recoveryID, observedSourceSHA256: freshSHA256)
    }

    /// Journal phase 3 terminal for the file-backed ladder: the trusted
    /// host streamed the ACTUAL provider read-back into native staging and
    /// native hashed it (`readbackSHA256`). A read-back equal to the
    /// journaled replacement commits (binding CAS inside the store);
    /// anything else records conflict with the observed digest — bytes the
    /// caller owns stay preserved either way, never a retry-to-green.
    ///
    /// ADDITIVE (lane job-20000d7c450d4353): `entityTag` carries the
    /// provider's fresh tag at commit time (WebDAV ETag; the delivered
    /// limitation "SMB entries carry no entity tag" means `nil` there). It
    /// advances the durable binding ONLY through the existing CAS update in
    /// `finishRecovery`, and existing SAF/gateway callers are unchanged by
    /// the default.
    public func settleReplacementStaged(recoveryID: UUID, sourceID: UUID, taskID: UUID,
                                        workspaceID: UUID, logicalPath: String,
                                        readbackSHA256: String,
                                        entityTag: String? = nil) async throws
        -> AndroidWorkspaceRecovery {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        guard let source = try await store.source(id: sourceID),
              source.workspaceID == workspaceID, source.logicalPath == logicalPath
        else { throw G04SourceCoordinatorError.sourceMissing }
        guard let pending = try await store.pendingRecovery(workspaceID: workspaceID, limit: 200)
            .first(where: { $0.id == recoveryID && $0.sourceID == sourceID })
        else { throw G04SourceCoordinatorError.sourceMissing }
        let requested: AndroidWorkspaceRecoveryState =
            readbackSHA256 == pending.replacementSHA256 ? .committed : .conflict
        return try await store.finishRecovery(id: recoveryID, requestedState: requested,
                                              observedSHA256: readbackSHA256, entityTag: entityTag)
    }

    /// Reconcile ONE interrupted receipt from a native-observed staged
    /// provider read (`observedSHA256` streamed through the host lane — the
    /// >4 MiB counterpart of `reconcileInterruptedReplacements`). Same
    /// decision ladder: replacement -> committed (CAS), backup -> retained,
    /// anything else -> conflict. Never re-permits, never deletes bytes.
    public func reconcileReceiptStaged(recoveryID: UUID, taskID: UUID, workspaceID: UUID,
                                       observedSHA256: String) async throws
        -> AndroidWorkspaceRecovery {
        try await requireOrdinaryConversation(taskID: taskID, workspaceID: workspaceID)
        guard let receipt = try await store.pendingRecovery(workspaceID: workspaceID, limit: 200)
            .first(where: { $0.id == recoveryID })
        else { throw G04SourceCoordinatorError.sourceMissing }
        guard receipt.state == .prepared || receipt.state == .writing else {
            throw G04SourceCoordinatorError.transitionRefused("alreadySettled")
        }
        guard let source = try await store.source(id: receipt.sourceID),
              source.workspaceID == receipt.workspaceID,
              source.sourceReference == receipt.sourceReference
        else {
            return try await store.finishRecovery(id: recoveryID, requestedState: .conflict,
                                                  observedSHA256: nil, entityTag: nil)
        }
        if observedSHA256 == receipt.replacementSHA256 {
            return try await store.finishRecovery(id: recoveryID, requestedState: .committed,
                                                  observedSHA256: observedSHA256, entityTag: nil)
        } else if observedSHA256 == receipt.backupSHA256 {
            return try await store.finishRecovery(id: recoveryID, requestedState: .retained,
                                                  observedSHA256: observedSHA256, entityTag: nil)
        }
        return try await store.finishRecovery(id: recoveryID, requestedState: .conflict,
                                              observedSHA256: observedSHA256, entityTag: nil)
    }

    /// ONE source row by exact workspace+path (ORIGINAL store lookup — the
    /// Files inspector enrichment).
    public func sourceRecord(workspaceID: UUID, logicalPath: String) async throws
        -> AndroidWorkspaceSource? {
        try await store.source(workspaceID: workspaceID, logicalPath: logicalPath)
    }

    /// Bounded metadata-only page of the workspace's durable source rows.
    /// READ-ONLY over the SAME journal-47 table through the ONE original
    /// `DatabaseManager` (the store exposes no per-workspace listing; this
    /// is the precise read overload inside the scoped coordinator, NOT a
    /// second store or authority — it never writes and never widens the
    /// schema). Bootstrap reference reconciliation consumes exactly these
    /// rows before any release UI is enabled.
    public func sourcesPage(workspaceID: UUID, afterID: String? = nil, limit: Int = 64) async throws
        -> [AndroidWorkspaceSource] {
        guard compositionIsLive else { throw G04SourceCoordinatorError.retired }
        let bounded = min(max(limit, 1), 64)
        return try await cluster.database.reader { db in
            try Self.decodeSourceRows(db, workspaceID: workspaceID, afterID: afterID, limit: bounded)
        }
    }

    private static func decodeSourceRows(_ db: Database, workspaceID: UUID,
                                         afterID: String?, limit: Int) throws -> [AndroidWorkspaceSource] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT * FROM android_workspace_sources
            WHERE workspace_id = ? AND (? IS NULL OR id > ?) ORDER BY id LIMIT ?
            """, arguments: [workspaceID.uuidString, afterID, afterID, limit])
        return try rows.map { row in
            guard let id = UUID(uuidString: row["id"]),
                  let ws = UUID(uuidString: row["workspace_id"]),
                  let kind = AndroidWorkspaceSourceKind(rawValue: row["kind"])
            else { throw AndroidWorkspaceSourceError.invalidMetadata }
            return AndroidWorkspaceSource(id: id, workspaceID: ws, logicalPath: row["logical_path"],
                                          kind: kind, sourceReference: row["source_reference"],
                                          sourceDocumentID: row["source_document_id"],
                                          sourceSHA256: row["source_sha256"],
                                          entityTag: row["entity_tag"], revision: row["revision"])
        }
    }

    /// One streaming chunked copy with the ORIGINAL free-space discipline
    /// (pre-reserve check like `importUserFile`), cancellation between
    /// chunks, and an fsync before the caller re-hashes the result.
    static func streamCopy(from source: URL, to destination: URL,
                           freeReservePath: String,
                           cancellation: CancellationToken) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard size > 0, Int(size) <= maximumProviderCopyBytes else {
            throw G04SourceCoordinatorError.tooLarge(limit: maximumProviderCopyBytes)
        }
        if let available = try fileManager.attributesOfFileSystem(forPath: freeReservePath)[.systemFreeSize] as? NSNumber,
           available.uint64Value < UInt64(size) {
            throw G04SourceCoordinatorError.diskFull
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw G04SourceCoordinatorError.diskFull
        }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        var written: Int64 = 0
        do {
            while true {
                try cancellation.throwIfCancelled()
                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
            try output.synchronize()
            try input.close()
            try output.close()
        } catch {
            try? input.close()
            try? output.close()
            throw error
        }
        guard written == size else {
            throw G04SourceCoordinatorError.readbackMismatch
        }
    }

    /// Maps ORIGINAL file-service refusals onto the frozen coordinator
    /// error vocabulary (additive cases included); anything unknown passes
    /// through unchanged so journal/store errors keep their exact types.
    private static func remapFileError(_ error: Error) -> G04SourceCoordinatorError {
        if let typed = error as? G04SourceCoordinatorError { return typed }
        if let document = error as? G04DocumentError {
            switch document {
            case .retired: return .retired
            case .ownerChanged: return .ownerChanged
            default: return .transitionRefused("documentAccess")
            }
        }
        if let tool = error as? WorkspaceToolError {
            switch tool {
            case .alreadyExists, .alreadyExistsOverwritable:
                return .transitionRefused("workingCopyExists")
            case .escapesRoot, .secretFile:
                return .transitionRefused("pathRefused")
            case .notFound:
                return .sourceMissing
            case .tooLarge(let limit):
                return .tooLarge(limit: limit)
            case .conflict(let expected, let actual):
                return .digestMismatch(expected: expected, actual: actual)
            case .isDirectory(let path):
                return .invalidWorkingCopy("isDirectory:\(path)")
            case .invalidArguments(let reason):
                return .invalidWorkingCopy(reason)
            default:
                return .invalidWorkingCopy("fileService")
            }
        }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace { return .diskFull }
        if error is CancellationError { return .transitionRefused("cancelled") }
        return .providerFailed(code: "io")
    }
}

// MARK: - Transport dispatch-readiness defaults

extension G04WorkspaceSourceCoordinator.Transport {
    /// Default: a transport that carries no external pump contract is
    /// dispatch-ready once attached (preserves every existing conformer).
    public func isDispatchReady(rootEpoch: UInt64) async -> Bool { true }
}
