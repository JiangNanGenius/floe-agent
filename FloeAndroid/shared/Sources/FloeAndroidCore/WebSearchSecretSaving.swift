// SPDX-License-Identifier: MPL-2.0
//
// RB2-MC-WEBSEARCH-3 — secure web-search credential ingress + durable
// cleanup + privacy retention hook. Private source candidate; NOT compiled,
// NOT executed (GRAMMAR-ONLY evidence in evidence/).
//
// Authority: MAIN_WEB_SEARCH_SECURE_INGRESS_DECISION_20261019.json
// (Main architecture decision — this file is the implementation, not the
// decision) + the App-consumer contract in
// runtime-app-host-fence-websearch-repair-source/HANDOFF.md §2.B:
//   * SAME frozen command `config.websearch.save` (+ `config.websearch.get`
//     unchanged). The optional closed payload entry is
//     `credential:{configurationID,intent:keep|set|clear,saveIntentToken?}`.
//     Legacy omission == keep. NO new public v3 command, permission, JNI
//     signature, namespace or store.
//   * Set consumes the one-shot SecretSaveIntentVault lease with
//     expectedSubject .webSearchSave (vault mirror in THIS package; the
//     consume equality already refuses providerSave/mcpSave tokens). The
//     value bytes are the ORIGINAL WebSearchCredential JSON {"values":{...}}
//     delivered through the existing binary submit ingress only — never a
//     plaintext JSON command/saved state/log/file/prompt.
//   * Route: the command does NOT carry a route object. The handler resolves
//     the trusted route from the host route registry (the same
//     ConfigRouteContextProviding seam the provider Set path uses); the
//     vault consume re-checks token+generation equality against the slot
//     frozen at save-tap.
//   * Exact namespace/account ownership: the secret is written/deleted ONLY
//     at ConfigSecretIdentity.webSearchOpaqueReference(credentialAccount:)
//     (namespace org.floeagent.ios.web-search, original credentialAccount
//     rule). The reference is derived natively — a command can never supply
//     raw reference authority. UUID collisions across model/web-search/MCP
//     namespaces cannot alias secrets: the reference is a SHA-256 over
//     NAMESPACE + ACCOUNT, not over the bare UUID.
//   * Keep preserves the current exact account (zero secret effects, the
//     legacy byte path). Set validates all mandatory fields by kind with the
//     ORIGINAL frozen rules. Clear uses the current stored/validated account
//     and never deletes a newer/live referenced secret.
//   * Physical ownership: every effect runs under the SHARED
//     ProviderOperationOwning reservation keyed by the exact configurationID
//     (MC-CAPACITY-1 reserve-before-effects), the ACTUAL RB1 owned-work
//     registry lease (root close waits the real owner — the registry is
//     process-wide, so the lease survives facade/context recreation exactly
//     like the provider lane), and the INDIVIDUAL mailbox physical receipt
//     (neverDispatched/settled only; an unsettled lifetime PARKS ticket +
//     lease + receipt and blocks newer operations with
//     pendingReconciliation).
//   * Durable cleanup journal: ONE new fixed app_settings key
//     `floe.webSearch.secretCleanup.v1` (Main-authorized), strict bounded
//     all-or-fail codec mirroring the provider ledger (MC-R2 semantics:
//     absent ≠ corrupt; corrupt bytes are preserved, never rewritten empty,
//     truncated or filtered; valid later entries survive). It is INDEPENDENT
//     of the provider cleanup ledger and of unrelated account clears — a
//     provider cleanup drain never touches web-search state and vice versa.
//
// Privacy (adapter delta for the later privacy qualifier — NOT a sibling
// privacy implementation): `webSearchPrivacyInventory()` returns the exact
// metadata-only inventory of web-search state (configurations row presence
// + count, cleanup journal row presence + count, configured-secret reference
// count), and `enqueueRetentionParticipationClears()` lets the privacy
// clear-all participate by recording DURABLE clear intents (bounded,
// recoverable, coordinated) instead of a broad unaccountable wipe. The
// existing iOS clear-model-config scope is metadata+provider-secret only;
// these two hooks are the whole web-search participation surface.

import Foundation
import GRDB
import FloeCore
import FloePersistence
import FloeAndroidWebTools

// MARK: - Closed credential request grammar

/// The optional `credential` entry of `config.websearch.save`. Closed keys:
/// `configurationID` (exact UUID present in the accompanying configurations
/// list), `intent` (keep|set|clear), `saveIntentToken` (strict `int:v1:`
/// handle; REQUIRED for set; ABSENT for keep/clear — a token riding a
/// keep/clear body is refused before any effect).
public struct WebSearchSaveCredentialRequest: Sendable, Equatable {
    public enum Intent: String, Sendable, Equatable {
        case keep
        case set
        case clear
    }

    public let configurationID: UUID
    public let intent: Intent
    public let saveIntentToken: String?

    public init(configurationID: UUID, intent: Intent, saveIntentToken: String?) {
        self.configurationID = configurationID
        self.intent = intent
        self.saveIntentToken = saveIntentToken
    }
}

enum WebSearchCredentialRequestParser {
    /// Strict closed-form parse. `nil` payload ⇒ legacy keep (the original
    /// metadata-only save semantics, byte-preserved). Unknown keys, wrong
    /// value shapes, token on keep/clear, missing token on set, or an id
    /// absent from the validated configurations list all refuse TYPED
    /// BEFORE any effect (pre-ticket, pre-lease, pre-queue).
    ///
    /// `validConfigurationIDs == nil` is used by the caller to parse the
    /// intent FIRST: Clear legitimately targets a configuration that is no
    /// longer in the incoming list (it was removed/replaced), and its target
    /// is resolved from the CURRENT stored list by the engine. Set/Keep are
    /// still required to name a configuration of the incoming list by the
    /// caller's post-parse check.
    static func parse(_ raw: Any?,
                      validConfigurationIDs: Set<UUID>?) throws -> WebSearchSaveCredentialRequest? {
        guard let raw else { return nil }
        guard let object = raw as? [String: Any] else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchCredentialShape")
        }
        guard Set(object.keys).isSubset(of: ["configurationID", "intent", "saveIntentToken"]) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchCredentialKeys")
        }
        guard let idString = object["configurationID"] as? String,
              let configurationID = UUID(uuidString: idString),
              validConfigurationIDs?.contains(configurationID) ?? true else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchCredentialTarget")
        }
        guard let intentString = object["intent"] as? String,
              let intent = WebSearchSaveCredentialRequest.Intent(rawValue: intentString) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchCredentialIntent")
        }
        let token = object["saveIntentToken"] as? String
        switch intent {
        case .set:
            guard let token, SecretGatewayIdentity.isCanonicalIngressToken(token) else {
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "websearchCredentialTokenMissing")
            }
        case .keep, .clear:
            guard token == nil else {
                // A one-shot handle is meaningful only for Set; a token on
                // keep/clear would be a cross-intent smuggle attempt.
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "websearchCredentialTokenUnexpected")
            }
        }
        return WebSearchSaveCredentialRequest(configurationID: configurationID,
                                              intent: intent,
                                              saveIntentToken: token)
    }
}

// MARK: - Original per-kind credential field validation

/// Validates the secret VALUE bytes against the ORIGINAL frozen per-kind
/// requirements (WebSearchService.makeRequest table, FloeAndroidWebTools
/// WebSearchService.swift:316-411 — the same authority
/// `WebSearchService.isConfigured` exercises). Only closed field IDENTIFIERS
/// appear in refusal reasons; values never leave this check.
enum WebSearchCredentialValidator {
    static func validate(bytes: Data, for configuration: WebSearchProviderConfiguration)
        throws -> WebSearchCredential
    {
        guard bytes.count <= ConfigWebSearchLimits.maximumCredentialBytes else {
            throw ConfigDomainError(code: .payloadTooLarge, reason: "websearchCredentialBytes")
        }
        let credential: WebSearchCredential
        do {
            credential = try JSONDecoder().decode(WebSearchCredential.self, from: bytes)
        } catch {
            // The value bytes must decode the ORIGINAL WebSearchCredential
            // JSON shape ({"values":{...}}); anything else is a schema
            // refusal BEFORE any effect.
            throw ConfigDomainError(code: .invalidEnvelope, reason: "websearchCredentialSchema")
        }
        let cleaned = WebSearchCredential(
            values: credential.values.mapValues {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            })
        func require(_ key: String) throws -> String {
            guard let value = cleaned.values[key], !value.isEmpty else {
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "websearchCredentialField.\(key)")
            }
            return value
        }
        switch configuration.kind {
        case .bochaWeb, .bochaAI:
            _ = try require("apiKey")
        case .tencentWSA:
            _ = try require("secretId")
            _ = try require("secretKey")
        case .brave, .tavily, .exa:
            _ = try require("apiKey")
        case .googleProgrammable:
            _ = try require("apiKey")
            _ = try require("engineId")
        case .volcengine, .custom:
            // The frozen table also requires an endpoint for these kinds;
            // the configuration half is validated by the list parser.
            guard configuration.endpoint != nil else {
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "websearchCredentialEndpointRequired")
            }
            _ = try require("apiKey")
        case .searxng:
            // requiresCredential == false: a Set can never target it.
            throw ConfigDomainError(code: .invalidEnvelope,
                                    reason: "websearchCredentialNotRequired")
        }
        return credential
    }
}

// MARK: - Durable cleanup journal (floe.webSearch.secretCleanup.v1)

/// One bounded durable web-search intent. Secret-free by construction:
/// configuration UUID + deterministic account string + intent class. The
/// provider ledger remains a SEPARATE key with its own format — the two
/// never mix (independence of unrelated account clears).
public struct WebSearchSecretCleanupEntry: Sendable, Equatable, Codable {
    public enum Intent: String, Sendable, Equatable, Codable {
        /// A Set's secret write may still need to (re-)commit/converge.
        case secretWrite
        /// A Clear's delete may still need to run.
        case secretClear
    }

    public let configurationID: UUID
    public let account: String
    public let intent: Intent

    public init(configurationID: UUID, account: String, intent: Intent) {
        self.configurationID = configurationID
        self.account = account
        self.intent = intent
    }

    /// The account is owned by exactly one configuration at a time; the
    /// (configurationID, intent) pair is the durable identity (a newer
    /// intent REPLACES the older one for the same configuration).
    var dictionaryKey: String { configurationID.uuidString }
}

public struct WebSearchSecretCleanupDrainResult: Sendable, Equatable {
    public enum EntryOutcome: Sendable, Equatable {
        /// The bounded delete committed; the entry was finalized
        /// (compare-and-delete on the exact intent).
        case secretRemoved
        /// A live configuration still references the account (write
        /// converged / clear superseded / delete aborted): nothing was
        /// deleted; the entry was discarded after compare-and-delete.
        case intentResolvedWithoutDelete(reason: String)
        /// C1 or unobserved ambiguous outcome: entry KEPT, and (MC-R4/MC-
        /// CAPACITY-1) the cleanup owner (ticket + retained registry lease +
        /// receipt) is PARKED until the individual physical truth settles.
        case outcomeUnknownPendingOwnerKept(reason: String)
        /// MC-R3: an effect-absent disposition proves THIS attempt mutated
        /// nothing; kept as an honest retry — never reported as removed.
        case effectRejectedKeptForRetry(reason: String)
        /// An active save/delete holds the configuration: kept untouched
        /// (CV-R1 both-direction gate).
        case activeOperationSkippedKept
        /// A durable pending owner holds the configuration: one bounded
        /// reconciliation was attempted first; still pending.
        case pendingOwnerSkippedKept(reason: String)
        /// The runtime owned-work registry refused attach: kept, no effect.
        case ownedWorkAttachKept(reason: String)
        /// The gateway is not registered: kept, no effect.
        case gatewayUnregisteredKept
        /// Transient row/query failure: kept for retry.
        case outcomeUnknownKeptForRetry(reason: String)
    }

    public var outcomes: [UUID: EntryOutcome]
    public var entriesRemaining: Int
}

/// Strict bounded durable ledger for web-search secret effects, mirroring
/// the provider cleanup ledger's MC-R2 codec semantics on its OWN fixed
/// key. All writes mirror the ORIGINAL SettingsStore upsert statement for
/// the ONE app_settings table (no second business DB, no schema change).
public actor WebSearchSecretCleanup {
    static let key = ConfigSettingsKeys.webSearchSecretCleanup

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    /// Safety bound; saturation fails CLOSED before effects (never a
    /// silent drop). Same derivation as the provider ledger.
    static let maximumEntries = 256

    // MARK: Ledger access (STRICT bounded codec; absent ≠ corrupt)

    public func entries() async throws -> [WebSearchSecretCleanupEntry] {
        let raw: String?? = try await database.reader { db in
            try Self.readRaw(db, key: Self.key)
        }
        switch Self.decode(raw) {
        case .absent:
            return []
        case .valid(let list):
            return list
        case .corrupt(let reason):
            // MC-R2: corrupt bytes preserved; typed failure; NEVER mapped
            // to empty, never rewritten.
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "webSearchCleanupCorrupt.\(reason)")
        }
    }

    /// Enqueue BEFORE the first native effect (Set) or on an unsettled
    /// Clear, so an unrecorded intent could never be lost. Idempotent per
    /// (configurationID, intent); a newer intent REPLACES the older for the
    /// same configuration (identity advance, never a duplicate).
    public func enqueue(_ entry: WebSearchSecretCleanupEntry) async throws {
        let maximum = Self.maximumEntries
        try await database.writer { db in
            let raw = try Self.readRaw(db, key: Self.key)
            switch Self.decode(raw) {
            case .corrupt(let reason):
                throw ConfigDomainError(code: .persistenceUnavailable,
                                        reason: "webSearchCleanupCorrupt.\(reason)")
            case .absent:
                try Self.write(db, key: Self.key, entries: [entry])
            case .valid(var list):
                if list.contains(where: {
                    $0.dictionaryKey == entry.dictionaryKey && $0.intent == entry.intent
                }) {
                    return
                }
                list.removeAll { $0.dictionaryKey == entry.dictionaryKey }
                guard list.count < maximum else {
                    throw ConfigDomainError(code: .persistenceUnavailable,
                                            reason: "webSearchCleanupSaturated")
                }
                list.append(entry)
                try Self.write(db, key: Self.key, entries: list)
            }
        }
    }

    /// COMPARE-AND-DELETE finalization: an entry is removed only while it
    /// still carries the EXACT attempted intent, after a STRICT read. A
    /// stale completion can never erase a newer intent.
    @discardableResult
    func dequeueMatching(configurationID: UUID,
                         intent: WebSearchSecretCleanupEntry.Intent) async throws -> Bool {
        try await database.writer { db in
            let raw = try Self.readRaw(db, key: Self.key)
            switch Self.decode(raw) {
            case .corrupt(let reason):
                throw ConfigDomainError(code: .persistenceUnavailable,
                                        reason: "webSearchCleanupCorrupt.\(reason)")
            case .absent:
                return false
            case .valid(let list):
                guard list.contains(where: {
                    $0.configurationID == configurationID && $0.intent == intent
                }) else {
                    return false
                }
                var remaining = list
                remaining.removeAll {
                    $0.configurationID == configurationID && $0.intent == intent
                }
                try Self.write(db, key: Self.key, entries: remaining)
                return true
            }
        }
    }

    // MARK: Drain (bootstrap replay after restart; bounded + coordinated)

    /// Replays pending web-search intents under the SAME shared coordinator
    /// the save path uses: while one entry's awaited delete runs, no
    /// save/clear can interleave on that configuration (CV-R1). A durable
    /// pending owner gets ONE bounded reconciliation attempt first.
    func drain(gateway: any SecretGatewayServicing,
               ownership: any ProviderOperationOwning,
               ownedWork: ConfigOwnedWorkLifecycle,
               reconciler: (any WebSearchPendingReconciling)?) async throws
        -> WebSearchSecretCleanupDrainResult
    {
        var result = WebSearchSecretCleanupDrainResult(outcomes: [:], entriesRemaining: 0)
        let current: [WebSearchSecretCleanupEntry]
        do {
            current = try await entries()
        } catch let error as ConfigDomainError
        where error.reason.hasPrefix("webSearchCleanupCorrupt") {
            // Corrupt bytes preserved; NO entry attempted; the typed failure
            // propagates to the bootstrap caller.
            throw error
        }
        let live = (try? await Self.loadConfigurations(database: database)) ?? []
        for entry in current {
            if await ownership.pendingRecord(providerID: entry.configurationID) != nil {
                guard let reconciler else {
                    result.outcomes[entry.configurationID] =
                        .pendingOwnerSkippedKept(reason: "noReconcilerBound")
                    continue
                }
                switch await reconciler.reconcileWebSearchRecovery(
                    configurationID: entry.configurationID) {
                case .nothingPending:
                    break
                case .settledNow:
                    break
                case .stillPending(let reason):
                    result.outcomes[entry.configurationID] =
                        .pendingOwnerSkippedKept(reason: reason)
                    continue
                case .notAdmitted(let reason):
                    result.outcomes[entry.configurationID] =
                        .pendingOwnerSkippedKept(reason: "notAdmitted.\(reason)")
                    continue
                }
            }
            let ticket: ProviderOperationTicket
            switch await ownership.beginOperation(providerID: entry.configurationID,
                                                  kind: .cleanup) {
            case .conflict:
                result.outcomes[entry.configurationID] = .activeOperationSkippedKept
                continue
            case .pendingReconciliation:
                result.outcomes[entry.configurationID] =
                    .pendingOwnerSkippedKept(reason: "pendingAppeared")
                continue
            case .capacityUnavailable:
                // MC-CAPACITY-1: refused BEFORE any effect; entry untouched.
                result.outcomes[entry.configurationID] =
                    .pendingOwnerSkippedKept(reason: "operationCapacityUnavailable")
                continue
            case .attached(let attachedTicket):
                ticket = attachedTicket
            }
            let lease: ConfigOwnedWorkLease
            switch ownedWork.begin(kind: .vaultMaintenance,
                                   ownerID: entry.configurationID.uuidString) {
            case .failure(let rejection):
                result.outcomes[entry.configurationID] = ownedWorkAttachKeptOutcome(rejection)
                await ownership.endOperation(ticket)
                continue
            case .success(let attachedLease):
                lease = attachedLease
            }
            result.outcomes[entry.configurationID] = await attempt(
                entry, live: live, gateway: gateway, ticket: ticket, lease: lease,
                ownership: ownership, ownedWork: ownedWork)
        }
        result.entriesRemaining = (try? await entries().count) ?? current.count
        return result
    }

    private func ownedWorkAttachKeptOutcome(
        _ rejection: ConfigOwnedWorkLifecycle.BeginRejection)
        -> WebSearchSecretCleanupDrainResult.EntryOutcome
    {
        switch rejection {
        case .noAdmittedEpoch:
            return .ownedWorkAttachKept(reason: "noAdmittedRuntimeEpoch")
        case .invalidOwnerIdentity:
            return .ownedWorkAttachKept(reason: "ownedWorkInvalidOwner")
        case .rejected(let code):
            return .ownedWorkAttachKept(reason: "ownedWorkRejected.\(code)")
        }
    }

    /// One guarded entry attempt: compare the LIVE configuration list, then
    /// the bounded observed delete, then compare-and-delete finalization —
    /// the MC-R3/MC-R4 rules (pre-ticket refusals never finalize; only the
    /// delete's OWN committed completion finalizes; an unsettled lifetime
    /// PARKS the owner instead of releasing it).
    private func attempt(_ entry: WebSearchSecretCleanupEntry,
                         live: [WebSearchProviderConfiguration],
                         gateway: any SecretGatewayServicing,
                         ticket: ProviderOperationTicket,
                         lease: ConfigOwnedWorkLease,
                         ownership: any ProviderOperationOwning,
                         ownedWork: ConfigOwnedWorkLifecycle) async
        -> WebSearchSecretCleanupDrainResult.EntryOutcome
    {
        enum Decision {
            case discardWithoutDelete(reason: String)
            case backendDelete
        }
        let decision: Decision
        if let row = live.first(where: { $0.id == entry.configurationID }) {
            if row.credentialAccount == entry.account {
                // The live configuration still owns the account: a write
                // converged or the delete aborted before the metadata
                // commit. Never delete a live referenced secret.
                decision = .discardWithoutDelete(reason: "liveRowOwnsAccount")
            } else {
                // The row moved to a different account: the deterministic
                // reference for the OLD account may hold an orphan.
                decision = .backendDelete
            }
        } else {
            // No live row: settle the reference the intent recorded.
            decision = .backendDelete
        }
        if case .discardWithoutDelete(let reason) = decision {
            let finalized: Bool
            do {
                finalized = try await dequeueMatching(
                    configurationID: entry.configurationID, intent: entry.intent)
            } catch {
                ownedWork.settle(lease)
                await ownership.endOperation(ticket)
                return .outcomeUnknownKeptForRetry(reason: "entryIntentAdvanced")
            }
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return finalized
                ? .intentResolvedWithoutDelete(reason: reason)
                : .outcomeUnknownKeptForRetry(reason: "entryIntentAdvanced")
        }
        guard gateway.isRegistered else {
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return .gatewayUnregisteredKept
        }
        let reference = ConfigSecretIdentity.webSearchOpaqueReference(
            credentialAccount: entry.account)
        let observed = PhysicalObservationResolver.observer(for: gateway)
        let capture = ReceiptCapture()
        let assessment: SecretEffectAssessment
        do {
            if let observed {
                try await observed.deleteObserved(reference: reference) { receipt in
                    capture.set(receipt)
                }
                var settlement: PhysicalSettlement = .executionSettled(status: 4)
                if let receipt = capture.receipt {
                    let snapshot = observed.physicalSnapshot(claim: receipt.claim)
                    if case .settled(let status) = snapshot {
                        settlement = .executionSettled(status: status)
                    }
                    _ = observed.resolvePhysical(claim: receipt.claim)
                } else {
                    settlement = .unobserved
                }
                assessment = SecretEffectAssessment(disposition: .committed,
                                                    settlement: settlement,
                                                    receipt: capture.receipt)
            } else {
                try await gateway.delete(reference: reference)
                assessment = SecretEffectAssessment(
                    disposition: .committed,
                    settlement: .executionSettled(status: 4),
                    receipt: nil)
            }
        } catch {
            let snapshot: PhysicalOperationSnapshot
            if let observed, let receipt = capture.receipt {
                snapshot = observed.physicalSnapshot(claim: receipt.claim)
            } else {
                snapshot = .notRecorded
            }
            assessment = SecretPhysicalAssessor.assess(error: error,
                                                       receipt: capture.receipt,
                                                       snapshot: snapshot,
                                                       supportsObservation: observed != nil)
        }
        switch assessment.disposition {
        case .committed:
            let finalized = (try? await dequeueMatching(
                configurationID: entry.configurationID, intent: entry.intent)) ?? false
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return finalized
                ? .secretRemoved
                : .outcomeUnknownKeptForRetry(reason: "entryIntentAdvanced")
        case .effectAbsent(let reason):
            // MC-R3: no-effect from THIS attempt never proves the
            // pre-existing secret absent; kept for honest retry.
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return .effectRejectedKeptForRetry(reason: reason)
        case .outcomeUnknown(let reason):
            if assessment.requiresOwnerRetention {
                // PARK the cleanup owner (MC-CAPACITY-1: always succeeds for
                // this exact running ticket).
                let parked = await ownership.parkPending(
                    ticket,
                    intent: entry.intent == .secretClear ? .secretClear : .secretWrite,
                    receipt: assessment.receipt,
                    lease: lease,
                    witness: observed)
                return parked
                    ? .outcomeUnknownPendingOwnerKept(reason: reason)
                    : .outcomeUnknownKeptForRetry(reason: "\(reason).parkRefused")
            }
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return .outcomeUnknownKeptForRetry(reason: reason)
        }
    }

    // MARK: Codec (STRICT, bounded, all-or-fail; mirrors MC-R2)

    enum LedgerDecode: Equatable {
        case absent
        case valid([WebSearchSecretCleanupEntry])
        case corrupt(reason: String)
    }

    /// Per-entry maximum ≈ 144 B (same derivation as the provider ledger:
    /// account ≤ 128, intent ≤ 12, UUID 36, closed 3-field object).
    static let maximumLedgerJSONBytes = maximumEntries * 144 + 64

    private static func readRaw(_ db: Database, key: String) throws -> String?? {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT value_json FROM app_settings WHERE key = ?",
            arguments: [key]
        ) else {
            return nil
        }
        let text: String? = row["value_json"]
        return .some(text)
    }

    static func decode(_ raw: String??) -> LedgerDecode {
        guard case .some(let text) = raw else { return .absent }
        guard let text else { return .corrupt(reason: "nullValueJSON") }
        guard text.utf8.count <= maximumLedgerJSONBytes else {
            return .corrupt(reason: "rawBytesExceedBound")
        }
        guard let data = text.data(using: .utf8) else {
            return .corrupt(reason: "notUTF8")
        }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            return .corrupt(reason: "malformedJSON")
        }
        guard let array = parsed as? [Any] else {
            return .corrupt(reason: "notArray")
        }
        guard array.count <= maximumEntries else {
            return .corrupt(reason: "entryCountExceedsBound")
        }
        var entries: [WebSearchSecretCleanupEntry] = []
        var seenConfigurations = Set<UUID>()
        var seenIdentities = Set<String>()
        for element in array {
            guard let object = element as? [String: Any], object.count == 3 else {
                return .corrupt(reason: "entryNotClosedObject")
            }
            guard let idString = object["configurationID"] as? String,
                  let configurationID = UUID(uuidString: idString),
                  let account = object["account"] as? String,
                  !account.isEmpty,
                  account.utf8.count <= 128,
                  let intentRaw = object["intent"] as? String,
                  let intent = WebSearchSecretCleanupEntry.Intent(rawValue: intentRaw)
            else {
                return .corrupt(reason: "entryInvalidField")
            }
            let identity = "\(configurationID.uuidString)|\(intent.rawValue)"
            guard seenIdentities.insert(identity).inserted else {
                return .corrupt(reason: "duplicateEntry")
            }
            guard seenConfigurations.insert(configurationID).inserted else {
                return .corrupt(reason: "duplicateConfigurationID")
            }
            entries.append(WebSearchSecretCleanupEntry(configurationID: configurationID,
                                                       account: account,
                                                       intent: intent))
        }
        return .valid(entries)
    }

    private static func write(_ db: Database, key: String,
                              entries: [WebSearchSecretCleanupEntry]) throws {
        var array: [[String: Any]] = []
        array.reserveCapacity(entries.count)
        for entry in entries {
            array.append([
                "configurationID": entry.configurationID.uuidString,
                "account": entry.account,
                "intent": entry.intent.rawValue,
            ])
        }
        let data = try JSONSerialization.data(withJSONObject: array, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
        guard array.count <= maximumEntries, json.utf8.count <= maximumLedgerJSONBytes else {
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "webSearchCleanupSaturated")
        }
        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
            arguments: [key, json, Self.timestamp(Date())]
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Narrow provenance mirror of the facade's configurations read (the
    /// ORIGINAL SQLiteSettingsStore SELECT for the ONE fixed key). Used by
    /// the drain to compare the live list; decode failures yield [] (the
    /// drain then keeps entries honestly instead of deleting against an
    /// unreadable list).
    static func loadConfigurations(database: DatabaseManager) async throws
        -> [WebSearchProviderConfiguration]
    {
        let raw: String? = try await database.reader { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [ConfigSettingsKeys.webSearchConfigurations]
            )
            return row?["value_json"]
        }
        guard let raw else { return [] }
        guard raw.utf8.count <= ConfigWebSearchLimits.maximumConfigurationJSONBytes else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "websearchCorrupt")
        }
        guard let decoded = try? JSONDecoder().decode([WebSearchProviderConfiguration].self,
                                                      from: Data(raw.utf8)) else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "websearchCorrupt")
        }
        return decoded
    }
}

/// The drain asks this typed seam for ONE bounded reconciliation of a
/// web-search pending owner (MC-R4 individual physical truth only).
public protocol WebSearchPendingReconciling: Sendable {
    func reconcileWebSearchRecovery(configurationID: UUID) async -> ProviderRecoveryOutcome
}

// MARK: - Secure save engine

/// Typed result of one credential edit so the facade can compose the reply
/// and decide whether the metadata CAS may proceed.
enum WebSearchCredentialEditResult: Sendable {
    /// Keep / absent credential: zero secret effects (legacy semantics).
    case noEffect
    /// The secret write committed at the backend (status 3).
    case written
    /// The secret delete committed at the backend (status 4).
    case removed
    /// The attempt had an unsettled physical lifetime: the owner
    /// (ticket + registry lease + receipt) is PARKED, the durable journal
    /// entry is KEPT, and the metadata CAS must NOT proceed.
    case retainedPending(reason: String)
    /// The attempt failed with a provable pre-effect / effect-absent
    /// disposition: nothing was written/deleted; the durable intent (when
    /// recorded) stays for honest retry; the metadata CAS must NOT proceed.
    case failed(ConfigDomainError)
}

/// Owns the web-search Set/Clear authority chain. Mirrors the provider
/// save executor's MC-R4 structure for the web-search namespace: shared
/// coordinator reservation by exact configurationID, ACTUAL RB1 registry
/// lease, individual mailbox physical receipt, durable journal intent
/// recorded BEFORE the first native effect, and reconcile-by-individual-
/// truth only.
actor WebSearchSecretSaveEngine: WebSearchPendingReconciling {
    private let database: DatabaseManager
    private let gateway: any SecretGatewayServicing
    private let ownership: any ProviderOperationOwning
    private let ownedWork: ConfigOwnedWorkLifecycle
    let cleanup: WebSearchSecretCleanup

    init(database: DatabaseManager,
         gateway: any SecretGatewayServicing,
         ownership: any ProviderOperationOwning,
         ownedWork: ConfigOwnedWorkLifecycle) {
        self.database = database
        self.gateway = gateway
        self.ownership = ownership
        self.ownedWork = ownedWork
        self.cleanup = WebSearchSecretCleanup(database: database)
    }

    // MARK: Set

    /// Chain authority for one Set: validate → reserve → lease → durable
    /// intent → observed write → metadata CAS (`commit`) → finalize. The
    /// durable `.secretWrite` intent is finalized ONLY when the CAS list
    /// commits; on a stale CAS the intent survives and the drain converges
    /// it with the live list (MC-R4 provider-create rule mirrored: a stored
    /// row owning the account discards it; an unreferenced orphan is
    /// settled on a later drain).
    func set(configuration: WebSearchProviderConfiguration,
             normalizedList: String,
             lease: SaveIntentLease,
             commit: @Sendable (String) async throws -> Void) async
        -> WebSearchCredentialEditResult
    {
        // 1) Lease candidate MUST be the exact targeted configuration
        //    (canonical JSON equality — the vault already bound id==subject
        //    id at submit; this re-checks the full body against the CAS
        //    list entry the handler validated).
        guard lease.subject == .webSearchSave else {
            // A providerSave/mcpSave lease can never drive this path; the
            // vault consume would already have refused — defensive truth.
            _ = lease.close()
            return .failed(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "websearchSubjectMismatch"))
        }
        let leaseConfig: WebSearchProviderConfiguration
        do {
            leaseConfig = try JSONDecoder().decode(WebSearchProviderConfiguration.self,
                                                   from: lease.candidateJSON)
        } catch {
            _ = lease.close()
            return .failed(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "websearchCandidateSchema"))
        }
        guard Self.canonicalJSON(leaseConfig) == Self.canonicalJSON(configuration) else {
            // The frozen candidate is not the EXACT CAS-list target
            // (canonical JSON equality: identity/account/kind/endpoint/
            // options all bound, per the Main decision's candidate rule).
            _ = lease.close()
            return .failed(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "websearchCandidateMismatch"))
        }
        // 2) Validate the ORIGINAL credential shape + per-kind fields
        //    BEFORE any effect (the lease bytes are the ONLY value source).
        guard let secretBytes = lease.secret else {
            _ = lease.close()
            return .failed(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "websearchCredentialMissing"))
        }
        do {
            _ = try WebSearchCredentialValidator.validate(bytes: secretBytes,
                                                          for: configuration)
        } catch let error as ConfigDomainError {
            _ = lease.close()
            return .failed(error)
        } catch {
            _ = lease.close()
            return .failed(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "websearchCredentialUnreadable"))
        }
        // 3) Reserve the operation BEFORE any effect (MC-CAPACITY-1).
        let ticket: ProviderOperationTicket
        switch await ownership.beginOperation(providerID: configuration.id, kind: .save) {
        case .attached(let attached):
            ticket = attached
        case .conflict:
            _ = lease.close()
            return .failed(ConfigDomainError(code: .duplicateInFlight,
                                             reason: "websearchOperationActive"))
        case .capacityUnavailable:
            _ = lease.close()
            return .failed(ConfigDomainError(code: .mailboxSaturated,
                                             reason: "websearchOperationCapacityUnavailable"))
        case .pendingReconciliation:
            _ = await reconcileWebSearchRecovery(configurationID: configuration.id)
            if case .attached(let attached) = await ownership.beginOperation(
                providerID: configuration.id, kind: .save) {
                ticket = attached
            } else {
                _ = lease.close()
                return .failed(ConfigDomainError(code: .duplicateInFlight,
                                                 reason: "websearchPendingReconciliation"))
            }
        }
        // 4) ACTUAL runtime owned-work lease BEFORE the first native write.
        let ownedLease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .vaultMaintenance,
                               ownerID: configuration.id.uuidString) {
        case .success(let attached):
            ownedLease = attached
        case .failure(let rejection):
            await ownership.endOperation(ticket)
            _ = lease.close()
            return .failed(ProviderSaveExecutor.ownedWorkAttachError(rejection))
        }
        // 5) Durable intent BEFORE the first native write (MC-R4 create rule).
        do {
            try await cleanup.enqueue(.init(configurationID: configuration.id,
                                            account: configuration.credentialAccount,
                                            intent: .secretWrite))
        } catch {
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ticket)
            _ = lease.close()
            return .failed((error as? ConfigDomainError) ?? ConfigDomainError(
                code: .persistenceUnavailable, reason: "websearchCleanupEnqueue"))
        }
        // 6) The observed physical write at the EXACT derived reference.
        let reference = ConfigSecretIdentity.webSearchOpaqueReference(
            credentialAccount: configuration.credentialAccount)
        let (assessment, witness) = await performObservedWrite(reference: reference,
                                                               bytes: secretBytes)
        switch assessment.disposition {
        case .committed:
            // Effect truth from the individual signal (status 3 = write).
            // The metadata CAS must now commit BEFORE the durable intent is
            // finalized (a stale CAS keeps the intent for drain convergence).
            do {
                try await commit(normalizedList)
            } catch {
                ownedWork.settle(ownedLease)
                await ownership.endOperation(ticket)
                _ = lease.close()
                return .failed((error as? ConfigDomainError) ?? ConfigDomainError(
                    code: .persistenceUnavailable, reason: "websearchCommit"))
            }
            _ = try? await cleanup.dequeueMatching(configurationID: configuration.id,
                                              intent: .secretWrite)
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ticket)
            _ = lease.close()
            return .written
        case .effectAbsent(let reason):
            // MC-R3: no effect from THIS attempt; the durable intent stays
            // for honest retry. Owner + lease release (neverExecuted only).
            if case .neverExecuted = assessment.settlement {
                ownedWork.settle(ownedLease)
                await ownership.endOperation(ticket)
            } else {
                // Authoritative non-commit with a live row pending: keep the
                // intent and release the owner honestly (retry re-enqueues).
                ownedWork.settle(ownedLease)
                await ownership.endOperation(ticket)
            }
            _ = lease.close()
            return .failed(ConfigDomainError(code: .runtimeUnavailable,
                                             reason: "websearchSecretAbsent.\(reason)"))
        case .outcomeUnknown(let reason):
            _ = lease.close()
            if assessment.requiresOwnerRetention {
                // PARK ticket + lease + receipt; the journal entry stays.
                let parked = await ownership.parkPending(
                    ticket, intent: .secretWrite,
                    receipt: assessment.receipt, lease: ownedLease,
                    witness: witness)
                return parked
                    ? .retainedPending(reason: reason)
                    : .failed(ConfigDomainError(code: .runtimeUnavailable,
                                                reason: "websearchParkRefused.\(reason)"))
            }
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ticket)
            return .failed(ConfigDomainError(code: .runtimeUnavailable,
                                             reason: "websearchSecretUnknown.\(reason)"))
        }
    }

    // MARK: Clear

    /// Deletes the secret at the CURRENT stored/validated account for the
    /// target configuration. `current` is the persisted list read by the
    /// facade; `incoming` is the validated CAS list. The metadata CAS
    /// (`commit`) runs only on a committed delete and finalizes the durable
    /// `.secretClear` intent only on CAS success.
    func clear(configurationID: UUID,
               incoming: [WebSearchProviderConfiguration],
               current: [WebSearchProviderConfiguration],
               normalizedList: String,
               commit: @Sendable (String) async throws -> Void) async
        -> WebSearchCredentialEditResult
    {
        // 1) Resolve the CURRENT stored account for the exact id (clear
        //    targets what is stored NOW, never a caller-supplied account).
        guard let stored = current.first(where: { $0.id == configurationID }) else {
            return .failed(ConfigDomainError(code: .notFound,
                                             reason: "websearchConfigurationMissing"))
        }
        let account = stored.credentialAccount
        guard !account.isEmpty, account.utf8.count <= 128 else {
            return .failed(ConfigDomainError(code: .persistenceUnavailable,
                                             reason: "websearchAccountOwnership"))
        }
        // 2) Never delete a newer/live referenced secret: no OTHER
        //    configuration (current or incoming list) may reference the
        //    account. (Uniqueness within each list is already enforced by
        //    the list parser; this is the cross-list guard.)
        let othersCurrent = current.contains {
            $0.id != configurationID && $0.credentialAccount == account
        }
        let othersIncoming = incoming.contains {
            $0.id != configurationID && $0.credentialAccount == account
        }
        guard !othersCurrent, !othersIncoming else {
            return .failed(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "websearchAccountLiveReferenced"))
        }
        guard stored.kind.requiresCredential else {
            // searxng-style kinds never own a secret; clear is a typed
            // no-target refusal (never a fake delete).
            return .failed(ConfigDomainError(code: .invalidEnvelope,
                                             reason: "websearchCredentialNotRequired"))
        }
        // 3) Reserve BEFORE any effect (MC-CAPACITY-1).
        let ticket: ProviderOperationTicket
        switch await ownership.beginOperation(providerID: configurationID, kind: .delete) {
        case .attached(let attached):
            ticket = attached
        case .conflict:
            return .failed(ConfigDomainError(code: .duplicateInFlight,
                                             reason: "websearchOperationActive"))
        case .capacityUnavailable:
            return .failed(ConfigDomainError(code: .mailboxSaturated,
                                             reason: "websearchOperationCapacityUnavailable"))
        case .pendingReconciliation:
            _ = await reconcileWebSearchRecovery(configurationID: configurationID)
            if case .attached(let attached) = await ownership.beginOperation(
                providerID: configurationID, kind: .delete) {
                ticket = attached
            } else {
                return .failed(ConfigDomainError(code: .duplicateInFlight,
                                                 reason: "websearchPendingReconciliation"))
            }
        }
        let ownedLease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .vaultMaintenance,
                               ownerID: configurationID.uuidString) {
        case .success(let attached):
            ownedLease = attached
        case .failure(let rejection):
            await ownership.endOperation(ticket)
            return .failed(ProviderSaveExecutor.ownedWorkAttachError(rejection))
        }
        // 4) Durable intent BEFORE the destructive effect.
        do {
            try await cleanup.enqueue(.init(configurationID: configurationID,
                                            account: account,
                                            intent: .secretClear))
        } catch {
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ticket)
            return .failed((error as? ConfigDomainError) ?? ConfigDomainError(
                code: .persistenceUnavailable, reason: "websearchCleanupEnqueue"))
        }
        // 5) The observed physical delete at the EXACT derived reference.
        let reference = ConfigSecretIdentity.webSearchOpaqueReference(
            credentialAccount: account)
        let (assessment, witness) = await performObservedDelete(reference: reference)
        switch assessment.disposition {
        case .committed:
            do {
                try await commit(normalizedList)
            } catch {
                ownedWork.settle(ownedLease)
                await ownership.endOperation(ticket)
                return .failed((error as? ConfigDomainError) ?? ConfigDomainError(
                    code: .persistenceUnavailable, reason: "websearchCommit"))
            }
            _ = try? await cleanup.dequeueMatching(configurationID: configurationID,
                                              intent: .secretClear)
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ticket)
            return .removed
        case .effectAbsent(let reason):
            // MC-R3: a pre-ticket/authoritative-non-commit absence proof is
            // never "already absent" for the durable intent; keep it for
            // honest retry and refuse the metadata CAS.
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ticket)
            return .failed(ConfigDomainError(code: .runtimeUnavailable,
                                             reason: "websearchClearAbsent.\(reason)"))
        case .outcomeUnknown(let reason):
            if assessment.requiresOwnerRetention {
                let parked = await ownership.parkPending(
                    ticket, intent: .secretClear,
                    receipt: assessment.receipt, lease: ownedLease,
                    witness: witness)
                return parked
                    ? .retainedPending(reason: reason)
                    : .failed(ConfigDomainError(code: .runtimeUnavailable,
                                                reason: "websearchParkRefused.\(reason)"))
            }
            ownedWork.settle(ownedLease)
            await ownership.endOperation(ticket)
            return .failed(ConfigDomainError(code: .runtimeUnavailable,
                                             reason: "websearchClearUnknown.\(reason)"))
        }
    }

    /// Canonical sorted-keys JSON of one configuration — the single exact
    /// comparison form for the frozen candidate vs the CAS-list target.
    private static func canonicalJSON(_ configuration: WebSearchProviderConfiguration) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(configuration)
    }

    // MARK: MC-R4 reconciliation (individual physical truth only)

    /// One bounded reconciliation pass for a configuration's durable
    /// pending owner. Reads ONLY the individual mailbox physical signal for
    /// the stored receipt — never statsJSON, counters, a re-read, a timeout
    /// or the durable entry itself.
    func reconcileWebSearchRecovery(configurationID: UUID) async -> ProviderRecoveryOutcome {
        guard let pending = await ownership.pendingRecord(providerID: configurationID) else {
            return .nothingPending
        }
        guard let recovery = await ownership.tryAcquireRecoveryLease(
            providerID: configurationID) else {
            return .stillPending(reason: "recoveryAlreadyRunning")
        }
        // The OLD pending operation is settled/acknowledged through the
        // witness captured at its attempt — independent of the CURRENT
        // registry state (removed or re-pointed to a non-observing gateway).
        let snapshot = physicalSnapshot(of: pending.receipt, witness: pending.witness)
        var settledReason: String?
        switch snapshot {
        case .neverDispatched(let reason):
            settledReason = "neverDispatched.\(reason.rawValue)"
        case .settled(let status):
            settledReason = "executionSettled.\(status)"
        case .queued, .claimedOutstanding, .notRecorded:
            settledReason = nil
        }
        if let reason = settledReason {
            _ = resolvePhysical(pending.receipt, witness: pending.witness)
            let detached = pending.lease.map { ownedWork.settle($0) } ?? true
            let settled = await ownership.settlePending(providerID: configurationID,
                                                        ticket: pending.ticket)
            await ownership.releaseRecovery(recovery)
            return settled
                ? .settledNow(reason: "\(reason).leaseDetached=\(detached)")
                : .stillPending(reason: "pendingIdentityAdvanced")
        }
        await ownership.releaseRecovery(recovery)
        return .stillPending(reason: pending.receipt == nil
            ? "noIndividualReceipt"
            : "physicalOutstanding")
    }

    // MARK: Observed physical attempts (per-attempt, metadata-only)

    /// PER-ATTEMPT observed write (MC-CAPACITY-2 registry-replacement rule):
    /// the observing seam is resolved for THIS attempt only; success IS the
    /// terminal completion channel (caller continuation resumes only from
    /// mailbox complete() with a GWS-7-valid positive status).
    private func performObservedWrite(reference: String,
                                      bytes: Data) async
        -> (SecretEffectAssessment, (any PhysicalObservingSecretGateway)?)
    {
        var owned = bytes
        defer {
            if owned.count > 0 { owned.resetBytes(in: 0..<owned.count) }
        }
        let capture = ReceiptCapture()
        let observed = PhysicalObservationResolver.observer(for: gateway)
        do {
            if let observed {
                try await observed.writeObserved(reference: reference, value: owned) { receipt in
                    capture.set(receipt)
                }
                var settlement: PhysicalSettlement = .executionSettled(status: 3)
                if let receipt = capture.receipt {
                    let snapshot = observed.physicalSnapshot(claim: receipt.claim)
                    if case .settled(let status) = snapshot {
                        settlement = .executionSettled(status: status)
                    }
                    _ = observed.resolvePhysical(claim: receipt.claim)
                } else {
                    settlement = .unobserved
                }
                return (SecretEffectAssessment(disposition: .committed,
                                               settlement: settlement,
                                               receipt: capture.receipt),
                        observed)
            }
            try await gateway.write(reference: reference, value: owned)
            return (SecretEffectAssessment(
                disposition: .committed,
                settlement: .executionSettled(status: 3),
                receipt: nil),
                    nil)
        } catch {
            let snapshot: PhysicalOperationSnapshot
            if let observed, let receipt = capture.receipt {
                snapshot = observed.physicalSnapshot(claim: receipt.claim)
            } else {
                snapshot = .notRecorded
            }
            return (SecretPhysicalAssessor.assess(error: error,
                                                  receipt: capture.receipt,
                                                  snapshot: snapshot,
                                                  supportsObservation: observed != nil),
                    observed)
        }
    }

    private func performObservedDelete(reference: String) async
        -> (SecretEffectAssessment, (any PhysicalObservingSecretGateway)?)
    {
        let capture = ReceiptCapture()
        let observed = PhysicalObservationResolver.observer(for: gateway)
        do {
            if let observed {
                try await observed.deleteObserved(reference: reference) { receipt in
                    capture.set(receipt)
                }
                var settlement: PhysicalSettlement = .executionSettled(status: 4)
                if let receipt = capture.receipt {
                    let snapshot = observed.physicalSnapshot(claim: receipt.claim)
                    if case .settled(let status) = snapshot {
                        settlement = .executionSettled(status: status)
                    }
                    _ = observed.resolvePhysical(claim: receipt.claim)
                } else {
                    settlement = .unobserved
                }
                return (SecretEffectAssessment(disposition: .committed,
                                               settlement: settlement,
                                               receipt: capture.receipt),
                        observed)
            }
            try await gateway.delete(reference: reference)
            return (SecretEffectAssessment(
                disposition: .committed,
                settlement: .executionSettled(status: 4),
                receipt: nil),
                    nil)
        } catch {
            let snapshot: PhysicalOperationSnapshot
            if let observed, let receipt = capture.receipt {
                snapshot = observed.physicalSnapshot(claim: receipt.claim)
            } else {
                snapshot = .notRecorded
            }
            return (SecretPhysicalAssessor.assess(error: error,
                                                  receipt: capture.receipt,
                                                  snapshot: snapshot,
                                                  supportsObservation: observed != nil),
                    observed)
        }
    }

    /// MC-OBSERVER-PENDING-OWNER: pending-record truth is read ONLY through
    /// the witness captured at attempt time. A missing witness is honest
    /// `.notRecorded`; it must never inspect the CURRENT registry, where a
    /// replacement gateway could answer for a colliding claim token. Fresh
    /// attempts query their locally captured observer directly.
    private func physicalSnapshot(of receipt: PhysicalOperationReceipt?,
                                  witness: (any PhysicalObservingSecretGateway)?)
        -> PhysicalOperationSnapshot
    {
        guard let receipt, let observed = witness else { return .notRecorded }
        return observed.physicalSnapshot(claim: receipt.claim)
    }

    @discardableResult
    private func resolvePhysical(_ receipt: PhysicalOperationReceipt?,
                                 witness: (any PhysicalObservingSecretGateway)?) -> Bool {
        guard let receipt else { return true }
        guard let observed = witness else { return false }
        return observed.resolvePhysical(claim: receipt.claim)
    }
}

// MARK: - Privacy participation (adapter delta for the later privacy qualifier)

/// Metadata-only inventory of web-search state for the privacy clear
/// summary. No secret bytes, no account strings beyond counts, no values.
public struct WebSearchPrivacyInventory: Sendable, Equatable {
    /// Whether the configurations row exists and how many providers it holds.
    public let configurationsPresent: Bool
    public let configurationCount: Int
    /// Whether the durable cleanup journal row exists and its entry count.
    public let cleanupJournalPresent: Bool
    public let cleanupJournalEntries: Int
    /// How many configurations declare a credential account (secret-bearing
    /// candidates). Count only.
    public let credentialBearingCount: Int
}

/// Scope-consistent adapter delta the privacy qualifier consumes: the
/// privacy clear-all MUST route web-search secret removal through these
/// durable, coordinated intents (bounded + recoverable + owner-gated)
/// rather than touching the gateway directly. This is the ONLY additional
/// surface; the privacy implementation itself stays with its owner lane.
public protocol WebSearchPrivacyRetentionParticipating: Sendable {
    /// Metadata-only inventory for the privacy summary.
    func webSearchPrivacyInventory() async -> WebSearchPrivacyInventory
    /// Records durable clear intents for every credential-bearing configured
    /// account so the privacy clear participates in the SAME recovery
    /// discipline as ordinary clears (never a broad unaccountable wipe, and
    /// never touching unrelated provider/MCP namespaces).
    func enqueueWebSearchRetentionClears() async throws -> Int
}
