// SPDX-License-Identifier: MPL-2.0
//
// G02PrivacyDomainExtension — the REAL optional-domain extension that binds
// the three privacy commands to the accepted generation.
//
// It follows the established `G02DomainExtension` seam exactly like the
// temporary package:
//   * registered in the idle pre-bootstrap window
//     (`G02PrivacyDomainRegistration.registerIfNeeded`);
//   * `attach` constructs the ONE privacy facade over the SAME owned
//     DatabaseManager/workspace/conversation stores, the SAME installed
//     vault, the REAL RB4 run fence/deletion lifecycle and the REAL shared
//     provider-operation coordinator;
//   * the three handlers are registered ONLY after every real service was
//     constructed, and `attach` self-rolls-back on any refusal;
//   * `beginRetirement(epoch:)` is epoch-exact: it fences the facade,
//     retires this epoch's confirmation capabilities and report handles and
//     unregisters exactly the keys this extension bound. A stale epoch can
//     never touch a newer generation's graph.
//
// The ordinary product (provider configuration, chat, memory, history)
// installs and works INDEPENDENTLY: a privacy attach refusal leaves only the
// three privacy keys unregistered (the frozen fail-closed
// `runtimeUnavailable` refusal) and never gates ordinary use.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime

final class G02PrivacyDomainExtension: G02DomainExtension, @unchecked Sendable {
    let id = G02DomainExtensionKey.privacy
    let domains: [G02DomainKey] = [.settingsPrivacy]

    private var facade: RuntimeFacadePrivacy?
    private var confirmation: PrivacyHostConfirmationStore?
    private var attachedEpoch: UInt64?
    private var registeredKeys: [String] = []
    private var attachedComposition: G02InstalledComposition?

    init() {}

    func expectedHandlerKeys(for domain: G02DomainKey) -> [String] {
        guard domain == .settingsPrivacy else { return [] }
        return Self.handlerKeys
    }

    static var handlerKeys: [String] {
        [
            BridgeV3.handlerKey(scope: .applicationConfiguration,
                                command: RuntimeFacadePrivacy.summaryCommand),
            BridgeV3.handlerKey(scope: .applicationConfiguration,
                                command: RuntimeFacadePrivacy.historyClearOperation),
            BridgeV3.handlerKey(scope: .applicationConfiguration,
                                command: RuntimeFacadePrivacy.modelConfigClearOperation),
        ]
    }

    func attach(to installed: G02InstalledComposition,
                gen: AndroidRuntimeBootstrap.Generation) async -> Bool {
        let epoch = gen.epoch
        guard attachedEpoch == nil else { return false }
        // The privacy clear drives the SAME run-domain fence and deletion
        // lifecycle conversation.delete uses; absent run domain is an honest
        // fail-closed attach refusal (ordinary base stays live).
        guard let (runDomain, deletionLifecycle) =
                RunDomainFacade.current(epoch: epoch) else {
            return false
        }
        let cluster = installed.cluster
        let rootToken = PrivacyRootIdentity.token(
            rootPath: cluster.identity.root.path)

        // The ACTUAL in-memory grant layer: the per-run runtime grants of
        // THIS generation's live run services (reusable-authorization state,
        // checkpoint restored/appended). No second grant store is created;
        // an empty live set truthfully reports zero.
        let grantsPort = G02RuntimeApprovalGrantsPort(domain: runDomain)
        let confirmationStore = PrivacyHostConfirmationStore(
            root: rootToken, epoch: epoch)
        let engine = PrivacySnapshotEngine(
            database: cluster.database,
            inMemoryGrants: grantsPort,
            rootPath: cluster.identity.root.path,
            epoch: epoch)
        let providerOwnership = ProviderOperationCoordinatorRegistry.shared
            .coordinator(for: cluster.database)
        let facade = RuntimeFacadePrivacy(
            database: cluster.database,
            snapshotEngine: engine,
            conversationStore: cluster.conversationStore,
            workspaceStore: cluster.workspaceStore,
            persistedGrants: cluster.workspaceStore,
            inMemoryGrants: grantsPort,
            globalFence: G02RunPrivacyGlobalFence(domain: runDomain),
            deletionLifecycle: deletionLifecycle,
            secretOrdering: G02PrivacySecretOrdering(
                database: cluster.database,
                gateway: SecretGatewayRegistry.shared),
            credentialDrain: G02VaultCredentialDrain(vault: installed.vault),
            providerOperations: G02PrivacyProviderOperations(
                ownership: providerOwnership),
            ownedWork: G02PrivacyOwnedWork(),
            workspaceCleaning: G02WorkspaceCleaning(
                root: cluster.identity.root),
            confirmation: confirmationStore,
            reportStore: PrivacyReportStore(
                rootPath: cluster.identity.root.path),
            hostEpoch: { epoch },
            rootIdentity: rootToken,
            rootPath: cluster.identity.root.path)

        let keys = Self.registerHandlers(gen: gen, facade: facade)
        guard keys.count == Self.handlerKeys.count else {
            Self.unregister(keys)
            return false
        }
        PrivacyHostConfirmationRegistry.shared.register(confirmationStore)
        installed.registeredHandlerKeys.append(contentsOf: keys)
        self.facade = facade
        self.confirmation = confirmationStore
        self.registeredKeys = keys
        self.attachedComposition = installed
        self.attachedEpoch = epoch
        return true
    }

    func beginRetirement(epoch: UInt64) async {
        guard attachedEpoch == epoch else { return }
        await facade?.markRetiring(epoch: epoch)
        confirmation?.retire()
        PrivacyHostConfirmationRegistry.shared.unregister(epoch: epoch)
        Self.unregister(registeredKeys)
        await facade?.markRetired(epoch: epoch)
        facade = nil
        confirmation = nil
        attachedComposition = nil
        registeredKeys = []
        attachedEpoch = nil
    }

    // MARK: Handler registration (exact three frozen keys)

    private static func registerHandlers(
        gen: AndroidRuntimeBootstrap.Generation,
        facade: RuntimeFacadePrivacy
    ) -> [String] {
        var keys: [String] = []
        func bind(_ command: String,
                  _ body: @escaping @Sendable (RuntimeCommandEnvelopeJob) async
                      -> RuntimeCommandResult) {
            G02DomainBinder.registerSubmitHandler(
                scope: .applicationConfiguration, command: command,
                configurationScope: "privacy")
            let key = BridgeV3.handlerKey(
                scope: .applicationConfiguration, command: command)
            G02DomainBinder.registerProcessor(gen.registry, handlerKey: key,
                                              body: body)
            keys.append(key)
        }

        bind(RuntimeFacadePrivacy.summaryCommand) { job in
            do {
                switch try PrivacySummaryRequest.parse(
                    G02DomainBinder.settingsPayload(job)) {
                case .summary:
                    return G02DomainBinder.completedEncodable(
                        try await facade.summary())
                case .page(let handle, let cursor, let maxItems):
                    let page = try await facade.reportPage(
                        handle: handle, cursor: cursor, maxItems: maxItems)
                    return G02DomainBinder.completedEncodable(
                        PrivacyFailurePageReply(report: page))
                }
            } catch let error as PrivacyDomainError {
                return G02DomainBinder.wireError(error.wireCode,
                                                 reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }

        bind(RuntimeFacadePrivacy.historyClearOperation) { job in
            guard let revision = G02DomainBinder.baseRevision(job),
                  let token = confirmToken(job) else {
                return G02DomainBinder.wireError("invalidEnvelope",
                                                 reason: "malformedAfterValidation")
            }
            do {
                let report = try await facade.clearHistory(
                    request: PrivacyClearRequest(confirmToken: token),
                    revision: revision,
                    invocationID: job.correlationID)
                return G02DomainBinder.completedEncodable(report)
            } catch let error as PrivacyDomainError {
                return G02DomainBinder.wireError(error.wireCode,
                                                 reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }

        bind(RuntimeFacadePrivacy.modelConfigClearOperation) { job in
            guard let revision = G02DomainBinder.baseRevision(job),
                  let token = confirmToken(job) else {
                return G02DomainBinder.wireError("invalidEnvelope",
                                                 reason: "malformedAfterValidation")
            }
            do {
                let report = try await facade.clearModelConfiguration(
                    request: PrivacyClearRequest(confirmToken: token),
                    revision: revision,
                    invocationID: job.correlationID)
                return G02DomainBinder.completedEncodable(report)
            } catch let error as PrivacyDomainError {
                return G02DomainBinder.wireError(error.wireCode,
                                                 reason: error.wireReason)
            } catch {
                return G02DomainBinder.internalError()
            }
        }
        return keys
    }

    private static func confirmToken(_ job: RuntimeCommandEnvelopeJob) -> String? {
        guard let payload = G02DomainBinder.settingsPayload(job),
              case .object(let object) = payload,
              case .string(let token)? = object["confirmToken"],
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func unregister(_ keys: [String]) {
        let binder = RuntimeCommandBinder.shared
        for key in keys { binder.unregister(key) }
    }
}

/// Trusted-host registration hook called exactly once in the pre-bootstrap
/// idle window (next to the temporary package). `registerExtension` refuses
/// while a generation is installing/live, so repeated calls are idempotent.
enum G02PrivacyDomainRegistration {
    static func registerIfNeeded() {
        _ = G02RuntimeComposition.shared.registerExtension(
            G02PrivacyDomainExtension())
    }
}

// MARK: - Live owner adapters (no second store/gate/permission authority)

/// RB4 global launch-admission fence over the REAL run domain.
struct G02RunPrivacyGlobalFence: PrivacyGlobalAdmissionFencing {
    let domain: FacadeRunDomain

    func beginGlobalAdmissionFence(expectedEpoch: UInt64) async throws
        -> GlobalAdmissionFenceToken {
        try await domain.beginGlobalAdmissionFence(expectedEpoch: expectedEpoch)
    }

    func awaitPendingLaunchesSettled(expectedEpoch: UInt64) async throws {
        try await domain.awaitPendingLaunchesSettled(
            expectedEpoch: expectedEpoch)
    }

    func finishGlobalAdmissionFence(_ token: GlobalAdmissionFenceToken,
                                    committed: Bool) async -> Bool {
        await domain.finishGlobalAdmissionFence(token, committed: committed)
    }
}

/// The ACTUAL in-memory approval-grant layer for this generation: a narrow
/// adapter over the run domain's live `ConversationRunService`s (each holding
/// the real `FloeAgentRuntime` grants). Snapshot/revoke cross every live run
/// of this exact root/epoch; retirement removes the domain from
/// `RunDomainFacade.current(epoch:)` first, so a stale epoch can never reach
/// a newer generation's services.
struct G02RuntimeApprovalGrantsPort: PrivacyInMemoryGrantStore {
    let domain: FacadeRunDomain

    func snapshotGrants() async throws -> [ApprovalGrant] {
        try await domain.approvalGrantsSnapshot()
    }

    func revokeGrant(id: UUID) async {
        _ = await domain.revokeApprovalGrant(id: id)
    }
}

/// The ORIGINAL persisted grant store (same actor, same writer).
extension SQLiteWorkspaceStore: PrivacyPersistedGrantStore {}

/// Shared model-configuration provider reservation (model-repair owner).
struct G02PrivacyProviderOperations: PrivacyProviderOperationOwning {
    let ownership: any ProviderOperationOwning

    func beginOperation(providerID: UUID,
                        kind: ProviderOperationKind) async
        -> ProviderOperationBeginOutcome {
        await ownership.beginOperation(providerID: providerID, kind: kind)
    }

    func endOperation(_ ticket: ProviderOperationTicket) async {
        await ownership.endOperation(ticket)
    }

    func parkPending(_ ticket: ProviderOperationTicket,
                     receipt: PhysicalOperationReceipt?,
                     witness: (any PhysicalObservingSecretGateway)?) async -> Bool {
        await ownership.parkPending(ticket, intent: .secretClear,
                                    receipt: receipt, lease: nil,
                                    witness: witness)
    }
}

/// REAL RB1 owned-work registry attachment.
struct G02PrivacyOwnedWork: PrivacyOwnedWorkOwning {
    func attach(epoch: UInt64, kind: RuntimeOwnedWorkKind,
                ownerID: String) -> RuntimeOwnedWorkToken? {
        switch RuntimeOwnedWorkRegistry.shared.attach(
            epoch: epoch, kind: kind, ownerID: ownerID) {
        case .attached(let token): return token
        case .rejected, .invalidIdentity: return nil
        }
    }

    func detach(_ token: RuntimeOwnedWorkToken) -> Bool {
        RuntimeOwnedWorkRegistry.shared.detach(token)
    }
}

/// Receipt capture for one observed gateway attempt (bounded, lock-only).
final class PrivacyReceiptCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PhysicalOperationReceipt?

    func set(_ receipt: PhysicalOperationReceipt) {
        lock.lock(); value = receipt; lock.unlock()
    }

    var receipt: PhysicalOperationReceipt? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// Accepted SecretGatewayRegistry + ORIGINAL V11 credential_deletion_queue
/// ordering. The operator is the exact existing config.provider.delete order:
/// enqueue -> gateway.delete -> complete | record failure; the durable row
/// survives process death for the bootstrap drain.
struct G02PrivacySecretOrdering: PrivacySecretDeletionOrdering {
    let database: DatabaseManager
    let gateway: SecretGatewayRegistry

    func hasRegisteredGateway() async -> Bool {
        gateway.isRegistered
    }

    func credentialAvailability() async -> PrivacyCredentialAvailability {
        gateway.isRegistered ? .available : .needsConfiguration
    }

    func enqueuePendingDeletion(account: String,
                                synchronizable: Bool) async throws -> String {
        try await database.writer { db in
            // ORIGINAL V11 columns/semantics. INSERT OR IGNORE keeps an
            // older claim's generation intact (a second clear never resets
            // it); the read-back value is this intent's conditional token.
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO credential_deletion_queue (
                        keychain_account, synchronizable, enqueued_at, last_error
                    ) VALUES (?, ?, datetime('now'), NULL)
                    """,
                arguments: [account, synchronizable ? 1 : 0])
            guard let generation = try String.fetchOne(
                db,
                sql: """
                    SELECT enqueued_at FROM credential_deletion_queue
                    WHERE keychain_account = ?
                    """,
                arguments: [account]) else {
                throw PrivacyDomainError.persistenceUnavailable(
                    "credentialQueueUnavailable")
            }
            return generation
        }
    }

    func deleteSecret(reference: String) async throws
        -> PrivacySecretDeletionOutcome {
        // Resolve the observing seam for THIS attempt, never a cached
        // capability bit: a re-pointed registry cannot misclassify a later
        // CRUD path as physical evidence.
        guard let observer = gateway.currentPhysicalObserver() else {
            do {
                try await gateway.delete(reference: reference)
                // Frozen CRUD contract: delete success IS the terminal
                // completion (status 4 committed).
                return PrivacySecretDeletionOutcome(settled: true)
            } catch {
                throw error
            }
        }
        let capture = PrivacyReceiptCapture()
        do {
            try await observer.deleteObserved(reference: reference) { receipt in
                capture.set(receipt)
            }
        } catch {
            guard let receipt = capture.receipt else { throw error }
            let settlement = await observer.awaitPhysicalSettlement(
                claim: receipt.claim)
            switch settlement {
            case .settled:
                // The physical effect completed; the surfaced error is not
                // proof of non-deletion (same classification the accepted
                // provider delete uses).
                return PrivacySecretDeletionOutcome(settled: true)
            case .neverDispatched:
                return PrivacySecretDeletionOutcome(
                    settled: false, reason: "neverDispatched")
            case .claimedOutstanding, .queued:
                return PrivacySecretDeletionOutcome(
                    settled: false, reason: "physicalOutstanding",
                    physicalOutstanding: true, receipt: receipt,
                    witness: observer)
            case .notRecorded:
                throw error
            }
        }
        guard let receipt = capture.receipt else {
            // Success without a receipt on an observing gateway is the
            // frozen "unobserved" case: CRUD success remains authoritative.
            return PrivacySecretDeletionOutcome(settled: true)
        }
        let settlement = await observer.awaitPhysicalSettlement(
            claim: receipt.claim)
        switch settlement {
        case .settled, .notRecorded:
            _ = observer.resolvePhysical(claim: receipt.claim)
            return PrivacySecretDeletionOutcome(settled: true)
        case .neverDispatched:
            return PrivacySecretDeletionOutcome(
                settled: false, reason: "neverDispatched")
        case .claimedOutstanding, .queued:
            // Keep the exact claim/witness so the caller parks the provider
            // reservation instead of releasing on the logical return.
            return PrivacySecretDeletionOutcome(
                settled: false, reason: "physicalOutstanding",
                physicalOutstanding: true, receipt: receipt,
                witness: observer)
        }
    }

    func completeDeletion(account: String, generation: String) async throws {
        try await database.writer { db in
            // Conditional exact-row completion: a NEWER intent (different
            // enqueued_at) is never erased by a stale finalizer.
            try db.execute(
                sql: """
                    DELETE FROM credential_deletion_queue
                    WHERE keychain_account = ? AND enqueued_at = ?
                    """,
                arguments: [account, generation])
            guard db.changesCount == 1 else {
                throw PrivacyDomainError.persistenceUnavailable(
                    "credentialQueueGenerationAdvanced")
            }
        }
    }

    func recordDeletionFailure(account: String, generation: String,
                               message: String) async throws {
        let bounded = String(message.prefix(160))
        try await database.writer { db in
            try db.execute(
                sql: """
                    UPDATE credential_deletion_queue SET last_error = ?
                    WHERE keychain_account = ? AND enqueued_at = ?
                    """,
                arguments: [bounded, account, generation])
        }
    }
}
