// SPDX-License-Identifier: MPL-2.0
//
// RB2 model-configuration domain — shared wire models, typed codes, canonical
// identities, page budgeting, and the MC-R1..R4 repair additions
// (provider revision rules + physical-lifetime assessment).
// REPAIR SUCCESSOR of job-d02beb16bd1840a9 (private source candidate;
// NOT compiled, NOT executed; see REPORT.md "source-only limitations").
//
// Repair delta over the parent (per MAIN_SOURCE_REVIEW_20261019.json):
// * MC-R1: ConfigProviderRevisionRules centralizes Main's 2026-10-19
//   settlement rule — every provider edit MUST advance the persisted,
//   supported revision; overflow is a typed refusal; stale requests are
//   rejected (the durable gate itself is the same-writer CAS in the store
//   mirror).
// * MC-R3: read-side availability no longer reports `.secretMissing` from a
//   pre-ticket invalidReference (proves nothing about a pre-existing
//   secret — VAULT_GATEWAY_FAILURE_SEMANTICS_MAIN / Main review).
// * MC-R4 (Main physical-lifetime API 2026-10-19): SecretPhysicalAssessor
//   separates CALLER OUTCOME from TRUE PHYSICAL SETTLEMENT using the
//   individual per-operation signal (PhysicalObservingSecretGateway).
//   No timeout, no re-read, no global counters, no durable intent is used
//   as settlement evidence.
//
// Authority chain (all paths relative to the repository root):
// * Local/Private/android-g02-20261018/RB2_MODEL_CONFIGURATION_SOURCE_ADMISSION_20261019.json
// * MAIN_SOURCE_REVIEW_20261019.json (MC-R1..R4 findings + settlement rules)
// * MAIN_GATEWAY_PHYSICAL_LIFETIME_API_GAP_20261019.json (physical API scope)
// * runtime-facade-contract/contract.json: commandVocabulary families config.*,
//   errorCodeVocabulary, receiptModel, credentialContract, asyncJniDesign,
//   eventPump.frameBudget, secretHygiene; BRIDGE_V3_MAIN_DECISIONS.json:
//   asynchronous, localSync, anonymousAuth, credentialGatewayDownstreamIngress,
//   credentialGatewayIdentityClarification.
// * The ACTUAL frozen 57-entry v3 matrix in FloeAndroid/shared/Sources/
//   FloeAndroidCore/BridgeEnvelopeV3.swift:104-222. RB2 binds EXACTLY the
//   eleven config.* command names quoted there (and nothing else); no new
//   command names, labels or IDs are invented here. The final P0 settings
//   rules ADD rules; they never restore an old matrix and never remove a
//   config.* command; nothing here re-binds them.
// * MAIN_GATEWAY_EFFECT_DISPOSITION_CLARIFICATION_20261019.json (C0/C1 effect
//   honesty) consumed together with the ACTUAL mailbox classification in
//   SecretGatewayMailbox.swift recordEffectLocked.

import Foundation
import Crypto
import FloeCore
import FloePersistence
import FloeProviders
import FloeAndroidWebTools

// MARK: - Frozen wire error codes (closed subset of the accepted vocabulary)

/// Closed subset of contract.json errorCodeVocabulary that the config domain
/// can itself produce. The strings are the ACCEPTED wire codes; nothing here
/// widens the vocabulary.
public enum ConfigWireCode: String, Sendable, Equatable {
    case invalidEnvelope
    case invalidJSON
    case payloadTooLarge
    case notFound
    case staleRevision
    case persistenceUnavailable
    case transportUnavailable
    case needsConfiguration
    case credentialUnavailable
    case unsupportedSyncRequest
    case duplicateInFlight
    case mailboxSaturated
    case runtimeUnavailable
    case unsupportedOperation
}

/// Typed credential-availability reasons. Names match contract.json
/// credentialResolution + errorCodeVocabulary
/// `credentialUnavailable{gatewayUnregistered|secretMissing|secretLocked|
/// secretInvalidated}`.
public enum ConfigCredentialAvailability: String, Sendable, Equatable {
    case gatewayUnregistered
    case secretMissing
    case secretLocked
    case secretInvalidated
}

/// Typed outcome of resolving a provider's credentials BEFORE any network
/// dispatch. `.anonymousAuthorized` is reachable ONLY for an explicitly
/// configured/supported no-auth style: authStyle "none" from the original
/// ProviderConnectionIdentity.authStyle(for:) (FloeCore
/// ProviderConfigurationValidation.swift:258-264, `.local` only) or the
/// ProviderPreset AuthStyle.none the factory carries for the same kind
/// (FloeProviders ProviderAdapterFactory.swift:175). A missing secretRef or a
/// LAN/self-hosted endpoint NEVER produces anonymous authority
/// (BRIDGE_V3_MAIN_DECISIONS.json anonymousAuth).
public enum ProviderCredentialResolution: Sendable, Equatable {
    case apiKey(String)
    case anonymousAuthorized
    case unavailable(ConfigCredentialAvailability)
}

// MARK: - Secret effect dispositions (C0 absence vs C1 real write/unknown)
//
// Source authority: SecretGatewayMailbox.swift recordEffectLocked plus the
// Main clarification "A claimed request without an authoritative store
// completion is effectUnknown; only authoritative -13 skip acknowledgement,
// queue-never-claimed removal, or explicit valid pre-dispatch statuses
// establish known no effect. Treat -14 abandoned as unknown... Never infer
// no effect from a missing submitted flag." AND
// VAULT_GATEWAY_FAILURE_SEMANTICS_MAIN_20261019.json (CV-R4): the ambiguous
// enum values (dispatcherUnresponsive/dispatcherReplaced/gatewayCancelled)
// are emitted on BOTH pre-queue refusals and CLAIMED-ticket settlements, so
// the value alone NEVER proves C0. MC-R4 adds the INDIVIDUAL physical signal
// (below): where a physical receipt exists, the conservative value-based
// rule is superseded by the per-operation truth — never the other way
// around. Deterministic negative statuses (-3..-10) are authoritative only
// because the ACTUAL frozen chain completes strictly AFTER the awaited real
// store effect (AndroidKeystoreCredentialStore freezes bytes then dispatchIo
// before suspension; SecretGatewayDispatcher.runChild awaits the actual store
// effect before `complete`; native isLive is validated before the UNDISPATCHED
// store launch) — compensation ordering is therefore not assumed and
// late-write reordering is not relied upon.
//
// The caller-side errors are produced by errorForStatus; this classifier
// maps each typed caller error onto the SAME disposition the mailbox itself
// records, and is deliberately conservative where two statuses share one
// Swift case (-11/-13 → dispatcherCancelled: the caller cannot prove which,
// so RB2 reports outcomeUnknown, the honest over-approximation).

public enum SecretEffectDisposition: Sendable, Equatable {
    /// The operation committed at the backend (authoritative statuses 1/3/4).
    case committed
    /// C0: provably no effect FOR THIS OPERATION. MC-R3: never a claim that
    /// a PRE-EXISTING secret is absent — only the actual success or an
    /// authoritative reference-absent completion finalizes a deletion intent.
    case effectAbsent(reason: String)
    /// C1: the request may have executed; no authoritative completion exists.
    /// Retry against the SAME deterministic reference converges (the original
    /// write is idempotent under the deterministic account→reference rule);
    /// the caller must claim neither success nor deletion.
    case outcomeUnknown(reason: String)
}

public enum SecretDispositionClassifier {
    /// `published` may be true only when the caller KNOWS the ticket passed
    /// the publish gate (queued/claimed). Callers that cannot prove either way
    /// pass true conservatively — never a false C0.
    public static func classify(error: Error, published: Bool) -> SecretEffectDisposition {
        if let backend = error as? SecretBackendError {
            switch backend {
            case .invalidReference, .invalidValue:
                // Pre-ticket validation in MailboxSecretGateway.perform — the
                // ticket was never created. Effect truth FOR THIS OPERATION:
                // none. MC-R3: this is NOT proof about any pre-existing
                // record; deletion intents are never finalized from here.
                return .effectAbsent(reason: backend == .invalidReference ? "invalidReference" : "invalidValue")
            case .gatewayClosed:
                return published
                    ? .outcomeUnknown(reason: "gatewayClosedAfterClaim")
                    : .effectAbsent(reason: "gatewayClosed")
            case .mailboxSaturated, .backendBusy:
                // Refused at publish: never queued, never claimed.
                return .effectAbsent(reason: backend == .mailboxSaturated ? "mailboxSaturated" : "backendBusy")
            case .dispatcherUnresponsive:
                // Pre-publish stale-heartbeat refusal AND the
                // watchdog-settled CLAIMED ticket (state becomes
                // callerSettledExecutionOutstanding while permit/effect-
                // unknown bookkeeping remains) emit the SAME enum value.
                // VAULT_GATEWAY_FAILURE_SEMANTICS_MAIN_20261019.json (CV-R4)
                // makes this normative: the error alone is NOT proof of no
                // effect. Only a proven pre-publish flag (`published:
                // false`) establishes C0; every post-publish caller in
                // this package passes published: true. Where the physical
                // signal (SecretPhysicalAssessor below) is available, the
                // individual truth supersedes this conservative default.
                return published
                    ? .outcomeUnknown(reason: "dispatcherUnresponsiveClaimed")
                    : .effectAbsent(reason: "dispatcherUnresponsivePreDispatch")
            case .dispatcherReplaced:
                // bind() settles never-claimed QUEUED tickets (C0)
                // and converts CLAIMED tickets to execution-outstanding
                // unknown (C1).
                return published
                    ? .outcomeUnknown(reason: "dispatcherReplacedClaimed")
                    : .effectAbsent(reason: "dispatcherReplacedQueued")
            case .corruptRecord, .authenticationFailed, .keyUnavailable,
                 .keyStoreFailure, .storageFailure, .deleteFailed,
                 .deviceLocked, .authRequired, .generationFailure:
                // Authoritative negative store completions (-3..-10): the
                // backend reported a definite non-committed result.
                return .effectAbsent(reason: "backendRejected")
            case .quarantined:
                // -15: the mailbox itself records skippedNoEffect.
                return .effectAbsent(reason: "backendQuarantined")
            case .dispatcherCancelled:
                // Shared caller mapping for -11 (mailbox: effectUnknown) and
                // -13 (mailbox: authoritative skip). The Swift error alone
                // cannot distinguish them; conservative unknown. (Bounded
                // reconciliation note for Main: exposing the completion status
                // to callers would allow -13 to map to C0 without any ABI
                // change; RB2 does NOT edit the frozen mailbox beyond the
                // Main-authorized additive physical API.)
                return .outcomeUnknown(reason: "dispatcherCancelledStatusAmbiguous")
            case .abandoned:
                // -14: "the status alone cannot establish where abandonment
                // occurred" → unknown for effect accounting.
                return .outcomeUnknown(reason: "abandoned")
            case .intentRejected(let rejection):
                return .effectAbsent(reason: "intentRejected.\(rejection.rawValue)")
            case .internal:
                // Internal mailbox failure has no authoritative completion
                // semantics of its own; only the publish flag can prove C0.
                return published
                    ? .outcomeUnknown(reason: "internalAfterPublish")
                    : .effectAbsent(reason: "internalPreDispatch")
            }
        }
        if error is CancellationError {
            // Queued-cancel is provably no-effect; claimed-cancel marks the
            // execution unknown (physical signal below refines both when
            // individually tracked).
            return published
                ? .outcomeUnknown(reason: "cancelledAfterClaim")
                : .effectAbsent(reason: "cancelledBeforePublish")
        }
        if let registryError = error as? SecretGatewayError {
            switch registryError {
            case .needsConfiguration:
                return .effectAbsent(reason: "gatewayUnregistered")
            }
        }
        return published
            ? .outcomeUnknown(reason: "unclassifiedAfterPublish")
            : .effectAbsent(reason: "unclassifiedPreDispatch")
    }
}

// MARK: - MC-R4: caller outcome vs TRUE physical settlement
//
// Main-authorized 2026-10-19 (MAIN_GATEWAY_PHYSICAL_LIFETIME_API_GAP_
// 20261019.json): the existing AndroidSecretGateway CRUD alone cannot prove
// physical settlement, so the mailbox now exposes an INDIVIDUAL per-operation
// physical record (PhysicalObservingSecretGateway on the candidate mirror).
// Rules enforced here (requiredSemantics verbatim):
// * Separate caller outcome from true physical settlement; NO timeout, fake
//   ledger, re-read, or global counts as settlement.
// * Cancellation BEFORE claim settles safely as no effect; AFTER claim the
//   lease/token is retained until the actual trusted host completion.
//   close/rebind/abandoned do not manufacture physical absence. If the
//   physical state is unprovable, the honest result is retained pending /
//   quarantine — never a released newer operation.
// * Never infer from statsJSON/global counts/account lookup/durable intent.
//   `.notRecorded` (no individual record) is honest NON-EVIDENCE, not
//   settlement.

public enum PhysicalSettlement: Sendable, Equatable {
    /// The individual operation provably NEVER reached a poller/store
    /// (mailbox record: neverDispatched). Safe to release the owner gate for
    /// THIS attempt; says NOTHING about any pre-existing secret (MC-R3).
    case neverExecuted(reason: String)
    /// The real host completion arrived for THIS claim (status included).
    /// Physical execution is finished; the EFFECT truth is still classified
    /// from the same authoritative status table as the mailbox itself.
    case executionSettled(status: Int32)
    /// Claimed and the host completion has NOT arrived (mailbox record
    /// claimedOutstanding/queued). The owner gate + runtime lease MUST be
    /// retained; durable intent stays recorded. No timer, no caller-cancel,
    /// no pretend settled.
    case executionOutstanding
    /// No individual physical signal is available (unobserving gateway,
    /// untracked capacity, or pre-ticket refusal). Conservative: retain
    /// pending for ambiguous outcomes; the pre-queue refusal set keeps the
    /// existing provable-C0 classification.
    case unobserved
}

public struct SecretEffectAssessment: Sendable, Equatable {
    public let disposition: SecretEffectDisposition
    public let settlement: PhysicalSettlement
    public let receipt: PhysicalOperationReceipt?

    public init(disposition: SecretEffectDisposition,
                settlement: PhysicalSettlement,
                receipt: PhysicalOperationReceipt?) {
        self.disposition = disposition
        self.settlement = settlement
        self.receipt = receipt
    }

    /// MC-R4 retention rule: the owner gate/registry lease may be released
    /// ONLY when the physical truth is neverExecuted or executionSettled.
    public var requiresOwnerRetention: Bool {
        switch settlement {
        case .neverExecuted, .executionSettled:
            return false
        case .executionOutstanding, .unobserved:
            // unobserved retains ONLY for unknown dispositions (pre-queue
            // C0 refusals were provably never claimed → never queued → no
            // dispatch possible; those release normally).
            switch disposition {
            case .outcomeUnknown:
                return true
            case .committed, .effectAbsent:
                if case .executionOutstanding = settlement { return true }
                return false
            }
        }
    }
}

public enum SecretPhysicalAssessor {
    /// The frozen mailbox status→caller-error table (errorForStatus,
    /// SecretGatewayMailbox.swift) reproduced CLOSED for the settled-status
    /// classification ONLY, with provenance. RB2 does not call the private
    /// mailbox function; the additive physical API exposes the status value
    /// itself, which is authoritative (the same value recordEffectLocked
    /// consumes: 1/3/4 committed; 2 read-miss; -1..-16 per the mailbox's own
    /// terminal protocol; positive-status pairing is enforced by GWS-7 in
    /// the mailbox before the record settles).
    static func disposition(forSettledStatus status: Int32) -> SecretEffectDisposition {
        switch status {
        case 1, 3, 4:
            return .committed
        case 2:
            // Read miss: the store authoritatively answered "no record" for
            // the exact reference — the ONE authoritative reference-absence
            // evidence in this domain (MC-R3).
            return .effectAbsent(reason: "authoritativeReadMiss")
        case -1:
            return .effectAbsent(reason: "invalidReference")
        case -2:
            return .effectAbsent(reason: "invalidValue")
        case -3, -4, -5, -6, -7, -8, -9, -10:
            return .effectAbsent(reason: "backendRejected")
        case -11:
            return .outcomeUnknown(reason: "dispatcherCancelledMidExecution")
        case -12:
            return .outcomeUnknown(reason: "internalSettled")
        case -13:
            // Explicit skipped-before-submit acknowledgement (rev4 rule).
            return .effectAbsent(reason: "backendSkippedNoEffect")
        case -14:
            return .outcomeUnknown(reason: "abandonedSettled")
        case -15:
            return .effectAbsent(reason: "backendQuarantined")
        case -16:
            return .effectAbsent(reason: "backendBusy")
        default:
            return .outcomeUnknown(reason: "unclassifiedSettledStatus")
        }
    }

    /// Combine the caller's typed error with the INDIVIDUAL physical truth.
    /// `snapshot` must come from `physicalSnapshot(claim:)` — never from a
    /// re-read, a counter, or durable intent.
    public static func assess(error: Error,
                              receipt: PhysicalOperationReceipt?,
                              snapshot: PhysicalOperationSnapshot,
                              supportsObservation: Bool = false) -> SecretEffectAssessment {
        // The conservative (unobserved) baseline first.
        let baseline = SecretDispositionClassifier.classify(error: error, published: true)
        guard let receipt else {
            if supportsObservation {
                // An OBSERVING gateway that never delivered a receipt proves
                // the ticket was NEVER queue-accepted: the sink fires exactly
                // at queue-accept (including the capacity-untracked case).
                // A never-queued ticket can never be claimed and can never
                // dispatch ⇒ provable C0 for THIS attempt, structurally (the
                // mailbox watchdog only ever settles queued/claimed tickets).
                // MC-R3: this still says NOTHING about any pre-existing
                // record — deletion intents stay preserved for retry.
                return SecretEffectAssessment(
                    disposition: .effectAbsent(reason: "physicalNeverQueued"),
                    settlement: .neverExecuted(reason: "neverQueued"),
                    receipt: nil)
            }
            // No receipt ⇒ the ticket was never queued-accepted with
            // observation, OR the error was a pre-ticket refusal. The
            // baseline rules already classify the deterministic pre-publish
            // refusal set as C0; ambiguous values stay unknown.
            switch baseline {
            case .outcomeUnknown:
                return SecretEffectAssessment(disposition: baseline,
                                              settlement: .unobserved,
                                              receipt: nil)
            case .committed, .effectAbsent:
                // Pre-effect refusal (unregistered gateway, invalid
                // reference/value shape, saturation at publish, backendBusy
                // at publish): the ticket never reached a poller ⇒ provable
                // no dispatch for THIS operation.
                return SecretEffectAssessment(disposition: baseline,
                                              settlement: .neverExecuted(reason: "preTicketOrPublishRefusal"),
                                              receipt: nil)
            }
        }
        guard receipt.tracked else {
            // Queued but the bounded physical ledger could not retain the
            // record: honest untracked — never fake settlement.
            return SecretEffectAssessment(disposition: baseline,
                                          settlement: .unobserved,
                                          receipt: receipt)
        }
        switch snapshot {
        case .neverDispatched(let reason):
            // Structural proof: the ticket left the mailbox before any
            // poller could claim it (watchdog drained the QUEUE, cancel
            // removed a QUEUED ticket, bind/remove settled never-claimed).
            // This supersedes the conservative unknown for
            // dispatcherUnresponsive — without ever claiming anything about
            // a pre-existing secret (MC-R3).
            return SecretEffectAssessment(
                disposition: .effectAbsent(reason: "physicalNeverDispatched.\(reason.rawValue)"),
                settlement: .neverExecuted(reason: reason.rawValue),
                receipt: receipt)
        case .settled(let status):
            return SecretEffectAssessment(disposition: disposition(forSettledStatus: status),
                                          settlement: .executionSettled(status: status),
                                          receipt: receipt)
        case .queued, .claimedOutstanding:
            // The caller may already be resumed (watchdog/bind/close/cancel
            // settled it) while the physical execution is STILL outstanding.
            // This is the MC-R4 defect the parent got wrong: retention is
            // keyed on THIS signal, never on the returned error alone.
            return SecretEffectAssessment(disposition: .outcomeUnknown(
                reason: snapshot == .queued ? "physicalQueuedUnconsumed"
                                            : "physicalClaimedOutstanding"),
                                          settlement: .executionOutstanding,
                                          receipt: receipt)
        case .notRecorded:
            // Record already resolved (consumed) or mailbox reset: honest
            // non-evidence. A caller only reaches here after consuming, or
            // after an external reset (process restart path — the durable
            // ledger + drain handle reconciliation there).
            return SecretEffectAssessment(disposition: baseline,
                                          settlement: .unobserved,
                                          receipt: receipt)
        }
    }
}

// MARK: - Revisions

/// MC-R1 settlement rule (Main, 2026-10-19): provider edits MUST advance a
/// persisted supported revision; an unchanged revision is stale and MUST be
/// rejected; overflow is typed refusal, never wraparound. The durable
/// enforcement is the same-writer CAS in the store mirror
/// (`expectedSyncRevision`); this rule centralizes the pre-effect guard and
/// the reply token so the whole domain shares ONE policy. Provenance:
/// original increment-only rule for preferences (ConversationCenter.swift
/// :7176-7177; LocalModelsSettingsView.swift :106,:140) generalized to the
/// provider row per the Main finding; the original draft/runner continue to
/// carry the OBSERVED base revision unchanged.
enum ConfigProviderRevisionRules {
    /// The revision a gated bundle write will persist, or nil when the
    /// revision space is exhausted (Int64.max cannot advance; typed refusal
    /// BEFORE any secret or DB effect).
    static func advanced(fromBase base: Int64) -> Int64? {
        guard base < Int64.max, base >= 0 else { return nil }
        return base + 1
    }

    /// Readback rule: the persisted row must carry EXACTLY the advanced
    /// value (never the frozen base, never a larger jump).
    static func readbackMatches(base: Int64, persisted: Int64) -> Bool {
        persisted == base + 1
    }
}

/// The envelope revision pair for one config resource (BridgeEnvelopeV3
/// revision object requires resourceID + version strings, :684-702).
public struct ConfigRevision: Sendable, Equatable {
    public let resourceID: String
    public let version: String
    public init(resourceID: String, version: String) {
        self.resourceID = resourceID
        self.version = version
    }

    public static func provider(id: UUID, syncRevision: Int64) -> ConfigRevision {
        ConfigRevision(resourceID: "provider.\(id.uuidString)", version: String(syncRevision))
    }
    public static func model(id: UUID, snapshotDigest: String) -> ConfigRevision {
        ConfigRevision(resourceID: "model.\(id.uuidString)", version: snapshotDigest)
    }
    public static func preferences(syncRevision: Int64) -> ConfigRevision {
        ConfigRevision(resourceID: "preferences", version: String(syncRevision))
    }
    public static func webSearch(digest: String) -> ConfigRevision {
        ConfigRevision(resourceID: "settings.websearch", version: digest)
    }
}

// MARK: - Typed domain error

/// One typed domain failure. `code` is a frozen wire code; `reason` is a
/// closed machine identifier (never user text, never secret-bearing). The
/// normal UI keeps internal strings out of view surfaces (AGENTS.md product
/// copy; contract secretHygiene).
public struct ConfigDomainError: Error, Sendable, Equatable {
    public let code: ConfigWireCode
    public let reason: String
    public init(code: ConfigWireCode, reason: String) {
        self.code = code
        self.reason = reason
    }

    public static var rawCredentialInputRejected: ConfigDomainError {
        // The frozen vocabulary has no dedicated "raw credential in JSON"
        // code; invalidEnvelope is the accepted refusal class for a body the
        // closed wire grammar cannot carry.
        ConfigDomainError(code: .invalidEnvelope, reason: "rawCredentialInputRejected")
    }

    public func jsonBody() -> [String: Any] {
        ["errorCode": code.rawValue, "reason": reason]
    }
}

// MARK: - Secret-free provider projection

/// The persisted secret reference projected to the agreed opaque form: the
/// deterministic gateway reference (SecretGatewayNaming.opaqueReference(for:)
/// — CredentialBackend.swift:88-90, ref:v1:+SHA-256; logical 71 bytes /
/// capacity 72 per SecretGatewayLimits :107-108) plus presence/sync STATUS
/// ONLY. The raw `keychainAccount` string does not leave the Swift domain:
/// the provider account is fully derivable from the provider id by the
/// ORIGINAL rule (KeychainSecretStore.swift:230-239 `provider.<uuid>`; the
/// save-side mint ProviderSaveRunner.swift:182-186), and the reference is
/// already the canonical non-secret wire form (BRIDGE_V3_MAIN_DECISIONS
/// credentialGatewayIdentityClarification.existingReference).
public struct ConfigProviderSecretStatus: Sendable, Equatable {
    public let configured: Bool
    public let opaqueReference: String?
    /// Persisted Keychain-sync preference only. NEVER interpreted as a second
    /// reference or as a device-sync capability (RB2 admission invariants).
    public let synchronizable: Bool

    public init(configured: Bool, opaqueReference: String?, synchronizable: Bool) {
        self.configured = configured
        self.opaqueReference = opaqueReference
        self.synchronizable = synchronizable
    }

    init?(reference: SecretReference?) {
        guard let reference else { return nil }
        self.configured = true
        self.opaqueReference = SecretGatewayNaming.opaqueReference(for: reference)
        self.synchronizable = reference.synchronizable
    }

    public static var none: ConfigProviderSecretStatus {
        ConfigProviderSecretStatus(configured: false, opaqueReference: nil, synchronizable: false)
    }
}

public struct ConfigProviderSummary: Sendable {
    public let id: UUID
    public let kind: ProviderKind
    public let wireProtocol: ModelProtocol
    public let baseURL: String
    public let displayName: String?
    public let region: String?
    public let isEnabled: Bool
    public let allowsPlainHTTP: Bool
    public let toolNameCompatibility: Bool
    public let createdAt: String
    public let updatedAt: String
    public let syncRevision: Int64
    public let secret: ConfigProviderSecretStatus

    public func jsonObject() -> [String: Any] {
        [
            "id": id.uuidString,
            "kind": kind.rawValue,
            "wireProtocol": wireProtocol.rawValue,
            "baseURL": baseURL,
            "displayName": displayName as Any,
            "region": region as Any,
            "isEnabled": isEnabled,
            "allowsPlainHTTP": allowsPlainHTTP,
            "toolNameCompatibility": toolNameCompatibility,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "syncRevision": syncRevision,
            "secret": [
                "configured": secret.configured,
                "opaqueReference": secret.opaqueReference as Any,
                "synchronizable": secret.synchronizable,
            ] as [String: Any],
        ]
    }
}

extension ProviderProfile {
    /// Secret-free projection for the wire. Dates use the ORIGINAL codec
    /// format (ConfigurationCodec.encode(Date) — ModelConfigurationStore.
    /// swift:403-407, ISO-8601 with fractional seconds), reproduced narrowly
    /// because the codec is internal to FloePersistence; the value is
    /// display-only and never a CAS token. `syncRevision` is the ACTUAL
    /// persisted value (after MC-R1 it advances on every gated edit, so a
    /// stale editor's token is durably detectable).
    public func configSummary() -> ConfigProviderSummary {
        ConfigProviderSummary(
            id: id,
            kind: kind,
            wireProtocol: wireProtocol,
            baseURL: baseURL.absoluteString,
            displayName: displayName,
            region: region,
            isEnabled: isEnabled,
            allowsPlainHTTP: allowsPlainHTTP,
            toolNameCompatibility: toolNameCompatibility,
            createdAt: ConfigTimestampCodec.encode(createdAt),
            updatedAt: ConfigTimestampCodec.encode(updatedAt),
            syncRevision: syncRevision,
            secret: ConfigProviderSecretStatus(reference: secretRef) ?? .none
        )
    }
}

enum ConfigTimestampCodec {
    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

// MARK: - Account / reference rules (ONE canonical mapping, both directions)

/// Deterministic provider secret identity. Provenance:
/// * account vocabulary: KeychainSecretStore.swift:230-239 (`provider.<uuid>`)
///   and the save-side mint rule ProviderSaveRunner.swift:182-186.
/// * reference: SecretGatewayNaming.opaqueReference (frozen, namespace
///   "keychainAccount" = original service org.floeagent.ios.secrets,
///   ref:v1:+SHA-256; logical 71 / capacity 72 per SecretGatewayLimits).
/// The MCP namespace (original service org.floeagent.ios.mcp) is a DISTINCT
/// namespace and is never merged here (MCP/Skills belong to RB6, not RB2).
public enum ConfigSecretIdentity {
    public static func providerAccount(providerID: UUID) -> String {
        "provider.\(providerID.uuidString)"
    }

    public static func providerSecretReference(account: String, synchronizable: Bool) -> SecretReference {
        SecretReference(keychainAccount: account, synchronizable: synchronizable)
    }

    public static func providerOpaqueReference(for reference: SecretReference) -> String {
        SecretGatewayNaming.opaqueReference(for: reference)
    }

    /// Web-search credentials keep their ORIGINAL service domain as the
    /// gateway namespace and their ORIGINAL credentialAccount as the account
    /// (WebSearchSettingsCenter.swift:11 keychainService =
    /// "org.floeagent.ios.web-search"; WebRetrievalModels.swift
    /// WebSearchProviderConfiguration.credentialAccount). Different namespace ⇒
    /// different reference for an identical account string (contract
    /// canonicalReferenceMapping.isolation); never merged with the provider
    /// "keychainAccount" namespace.
    public static func webSearchOpaqueReference(credentialAccount: String) -> String {
        SecretGatewayNaming.opaqueReference(namespace: "org.floeagent.ios.web-search",
                                            account: credentialAccount)
    }
}

// MARK: - Fixed, whitelisted app_settings keys owned by this domain
//
// Explicit trusted-settings whitelist: these FOUR constants are the ONLY
// app_settings keys the config domain may write (single existing table, no
// schema change — the same narrow-SQL justification pattern recorded in the
// Main-accepted sibling adapter settings-defaults-usage-source
// RuntimeFacadeSettingsDefaults.swift:18-24). There is NO arbitrary-key write
// API anywhere in RB2. MC-R4 note: the provider cleanup ledger may be
// EXTENDED within this same whitelisted key (new intent vocabulary only);
// the tool-vault credential_records / V11 deletion queue are never touched.
// MC-WEBSEARCH-3: the fourth key (webSearchSecretCleanup) is the single
// Main-authorized new fixed internal key
// (MAIN_WEB_SEARCH_SECURE_INGRESS_DECISION_20261019.json durable cleanup);
// it is a closed native-only journal — no public arbitrary settings writer,
// no new permission, no new store — and is independent of the provider
// cleanup key (unrelated account clears never mix).
public enum ConfigSettingsKeys {
    /// Web-search provider CONFIGURATIONS (secret-free: the original
    /// WebSearchProviderConfiguration carries credentialAccount — an account
    /// identifier — never a secret value). Key mirrors the original iOS
    /// persistence name (WebSearchSettingsCenter.swift:10 defaultsKey) for
    /// cross-feature identity, stored in app_settings on Android because
    /// UserDefaults/CloudKit persistence is not available and the original
    /// center class is App-target code excluded from the overlay.
    public static let webSearchConfigurations = "floe.webSearch.providers.v1"
    /// Preset identity sidecar: provider UUID → catalog presetID. Provenance
    /// equivalence: the ORIGINAL SQLite codec never persisted presetID
    /// (ModelConfigurationStore.swift:458-496 writes no preset column and
    /// :422-456 always decodes presetID == nil), while the iOS editor computed
    /// configuredPresetIDs from in-memory profiles
    /// (ProviderEditorView.swift:237-239 compactMap(\.presetID)). A durable
    /// real-store source is required for config.catalog.search(filter
    /// "configured") on a backend with no long-lived editor object, and this
    /// sidecar inside the SAME schema-46 app_settings table is the narrowest
    /// equivalent. Delete/cleanup removes entries; no data is dropped.
    public static let providerPresetIDs = "floe.provider.presetIDs.v1"
    /// Provider secret cleanup queue (file 4). Durable recovery ledger for
    /// cross-Keystore/SQLite deletion AND (MC-R4) for the new-resource write
    /// intent recorded BEFORE the first native effect. The credential_records
    /// tool vault and its trigger-fed credential_deletion_queue
    /// (V11ArchiveCredentials.swift :48-61; CredentialStore.swift:176-193)
    /// are OWNED by the separate vault recovery lane: RB2 never writes or
    /// reads those tables or that code. Account prefixes are provably
    /// disjoint (provider.* vs credential.*|host.ssh.*|host.vnc.*|
    /// approval-model per KeychainSecretStore.swift:230-239 and
    /// CredentialStore.swift:55). The ledger NEVER stores secret/plaintext
    /// bytes: only provider UUID + deterministic account string + intent.
    public static let providerSecretCleanup = "floe.provider.secretCleanup.v1"
    /// MC-WEBSEARCH-3 durable web-search secret cleanup journal (ONE fixed
    /// key, Main-authorized). Strict bounded all-or-fail codec mirroring the
    /// provider ledger's MC-R2 semantics on an INDEPENDENT key: web-search
    /// intents never enter the provider ledger and provider cleanup never
    /// touches this row (unrelated account clears stay isolated). Contents:
    /// configuration UUID + credentialAccount string + intent only — never
    /// secret bytes.
    public static let webSearchSecretCleanup = "floe.webSearch.secretCleanup.v1"
}

// MARK: - Closed-shape JSON parsing helpers

/// Strict object parsing with a closed key whitelist. Unknown keys are
/// REJECTED — the wire cannot smuggle extra fields; model-authored JSON never
/// gains authority by minting id/intent/route fields, and raw credential
/// field NAMES are refused before anything else is examined (RB2 admission:
/// "Rawcandidate/secretbytes neverenter command/eventJSON").
enum ConfigJSON {
    /// Field names that may never appear on the config wire (after case
    /// folding and "-"→"_" normalization). Detection is name-based and
    /// deliberately paranoid: legitimate closed payloads never use them, and
    /// the real secret path is the binary lease, not JSON.
    static let rawCredentialFieldNames: Set<String> = [
        "api_key", "apikey", "entered_api_key", "secret", "secret_value",
        "token", "credential_value", "x_api_key", "authorization",
        "cookie", "value_json",
    ]

    /// Name folding for the raw-credential detection boundary ONLY.
    /// Hyphens fold to underscores AND camelCase boundaries are split
    /// (`apiKey` → `api_key`), so the closed credential-name vocabulary
    /// cannot be bypassed by spelling alone. All-caps runs are preserved
    /// (`API_KEY` → `api_key`); the collapsed `apikey` alias is also listed
    /// in the vocabulary for mixed-case spellings that do not split.
    static func normalizeFieldName(_ key: String) -> String {
        let folded = key.replacingOccurrences(of: "-", with: "_")
        let characters = Array(folded)
        var normalized = ""
        for (index, character) in characters.enumerated() {
            if character.isUppercase,
               index > 0,
               characters[index - 1].isLowercase || characters[index - 1].isNumber,
               index + 1 < characters.count,
               characters[index + 1].isLowercase {
                normalized.append("_")
            }
            normalized.append(contentsOf: character.lowercased())
        }
        return normalized.lowercased()
    }

    static func object(from data: Data) throws -> [String: Any] {
        guard !data.isEmpty else {
            throw ConfigDomainError(code: .invalidJSON, reason: "emptyPayload")
        }
        guard data.count <= ConfigPageBudget.maximumCommandPayloadBytes else {
            throw ConfigDomainError(code: .payloadTooLarge,
                                    reason: "payloadBytes\(data.count)")
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let dictionary = parsed as? [String: Any] else {
            throw ConfigDomainError(code: .invalidJSON, reason: "malformedObject")
        }
        try assertNoCredentialNames(dictionary)
        return dictionary
    }

    static func assertNoCredentialNames(_ dictionary: [String: Any]) throws {
        // Top-level command envelope scan only. Free-form nested maps
        // (nonSecretHeaders, options) are scanned explicitly by the executor
        // that KNOWS their structure, so a legitimate provider option key is
        // never falsely rejected while a smuggled raw-credential field on the
        // command body is refused here.
        for key in dictionary.keys {
            if rawCredentialFieldNames.contains(normalizeFieldName(key)) {
                throw ConfigDomainError.rawCredentialInputRejected
            }
        }
    }

    /// Reusable check for the known credential-bearing free-form maps
    /// (`nonSecretHeaders`, web-search `options`). Header/option NAMES must
    /// not be raw credential material. This complements (does not replace)
    /// the original ProviderConfigurationValidation forbidden-header rule.
    static func assertNoCredentialMapKeys(_ map: [String: String],
                                          context: String) throws {
        for key in map.keys {
            if rawCredentialFieldNames.contains(normalizeFieldName(key)) {
                throw ConfigDomainError(
                    code: .invalidEnvelope,
                    reason: "rawCredentialMapKey.\(context).\(normalizeFieldName(key))"
                )
            }
        }
    }

    /// Closed whitelist check for one object level (callers pass already
    /// credential-name-checked subtrees; nested containers re-enter here).
    static func closed(_ dictionary: [String: Any],
                       allowed: Set<String>,
                       required: Set<String> = [],
                       context: String) throws {
        let keys = Set(dictionary.keys)
        guard keys.isSubset(of: allowed) else {
            let extras = keys.subtracting(allowed).sorted()
            throw ConfigDomainError(code: .invalidEnvelope,
                                    reason: "unknownField.\(context).\(extras.joined(separator: ","))")
        }
        guard required.isSubset(of: keys) else {
            let missing = required.subtracting(keys).sorted()
            throw ConfigDomainError(code: .invalidEnvelope,
                                    reason: "missingField.\(context).\(missing.joined(separator: ","))")
        }
    }

    /// Decodes a subtree with the ORIGINAL type's Codable shape (so the
    /// capabilities/use-surfaces JSON shape is the original one, not an RB2
    /// invention). `ModelCapabilities` is an `OptionSet` whose ORIGINAL
    /// synthesized Codable shape is a single scalar value (`1`), so scalar
    /// fragments are legitimate here; containers keep working unchanged.
    static func decodeCanonical<T: Decodable>(_ type: T.Type, from value: Any,
                                              context: String) throws -> T {
        let data: Data
        if let serialized = try? JSONSerialization.data(withJSONObject: value,
                                                        options: [.fragmentsAllowed,
                                                                  .sortedKeys]) {
            data = serialized
        } else {
            throw ConfigDomainError(code: .invalidJSON, reason: "notSerializable.\(context)")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ConfigDomainError(code: .invalidJSON, reason: "decode.\(context)")
        }
    }

    /// Canonical, deterministic JSON bytes for digests: sorted-key
    /// re-serialization so key order never perturbs a revision token.
    static func canonicalData(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Frame/page budget (contract eventPump.frameBudget)

public enum ConfigPageBudget {
    /// 48 KiB of ACTUAL serialized UTF-8 per page, leaving >=16 KiB headroom
    /// inside the frozen 65_536-byte frame (BridgeV3.maximumBytes;
    /// Bridge.swift:7; floe_jni.cpp:17-19,28-30; Kotlin
    /// BridgeProtocol.MAX_REQUEST_BYTES). Budget is measured on serialized
    /// bytes, NEVER `.count`.
    public static let maximumPageItemsBytes = 49_152
    /// Command payload bound: strictly below the frame bound (the envelope
    /// itself, the receipt and the effect wrapper must also fit).
    public static let maximumCommandPayloadBytes = 61_440
    /// Hard ceiling for items in one page even if more would fit the byte
    /// budget — bounded buffers rule (AGENTS.md invariants).
    public static let maximumItemsPerPage = 200
    /// Catalog search bound (a static ≤2 MiB document; ProviderCatalog.
    /// swift:242 maximumDocumentBytes = 2 * 1_024 * 1_024).
    public static let maximumCatalogResultsPerPage = 50
}

/// Stop-at-budget page composition with an opaque index cursor
/// (messagePage/event-poll pattern: nextCursor/hasMore, never truncation of
/// an individual item). If a SINGLE item cannot fit inside the remaining
/// budget the page simply stops (more=true); if the FIRST item of a fresh
/// page alone exceeds the budget the caller receives
/// `itemDoesNotFitPage` — a typed failure, never a silently truncated lie.
enum ConfigPageComposer {
    struct Composed {
        let data: Data
        let nextCursor: String?
        let hasMore: Bool
    }

    static func compose(_ objects: [[String: Any]],
                        cursor: Int?,
                        itemBudget: Int) throws -> Composed {
        let start = cursor ?? 0
        guard start >= 0, start <= objects.count else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "cursorOutOfRange")
        }
        var itemBytes: [Data] = []
        var bytes = 0
        var index = start
        while index < objects.count, itemBytes.count < ConfigPageBudget.maximumItemsPerPage {
            guard let candidate = ConfigJSON.canonicalData(objects[index]) else {
                throw ConfigDomainError(code: .persistenceUnavailable, reason: "pageEncode")
            }
            // enclosing "[...]" costs 2 bytes for the first item, 1 more comma
            // for each additional item; the final assembled `body.count` below
            // is the authoritative actual-serialized-UTF-8 measurement.
            let overhead = itemBytes.isEmpty ? 2 : 1
            if bytes + candidate.count + overhead > itemBudget {
                if itemBytes.isEmpty {
                    throw ConfigDomainError(code: .payloadTooLarge,
                                            reason: "itemDoesNotFitPage")
                }
                break
            }
            itemBytes.append(candidate)
            bytes += candidate.count + overhead
            index += 1
        }
        var body = Data()
        body.reserveCapacity(bytes)
        body.append(0x5B) // "["
        for (offset, chunk) in itemBytes.enumerated() {
            if offset > 0 { body.append(0x2C) } // ","
            body.append(chunk)
        }
        body.append(0x5D) // "]"
        precondition(body.count <= itemBudget, "composed page exceeded its budget")
        let nextCursor = index < objects.count ? String(index) : nil
        return Composed(data: body, nextCursor: nextCursor, hasMore: index < objects.count)
    }
}

// MARK: - Model wire DTOs (reuse of the ORIGINAL Codable shapes)

/// Canonical digest of a model snapshot exactly as the original types encode
/// it (ModelProfile is the original Codable value type; FloeCore
/// ModelProfile.swift:105-273). config.model.save's CAS revision (contract:
/// `model.<uuid>/sha256(expected snapshot)`) is computed over these bytes;
/// the store's own `saveModel(_:expected:)` full-snapshot compare-and-swap
/// remains the durable authority (ModelConfigurationStore.swift:53-65 —
/// MC-R1: UNCHANGED, the existing models CAS stays exactly as-is).
enum ConfigModelSnapshot {
    static func data(_ model: ModelProfile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(model)
    }

    static func digest(_ model: ModelProfile) throws -> String {
        let encoded = try data(model)
        guard let object = try? JSONSerialization.jsonObject(with: encoded),
              let canonical = ConfigJSON.canonicalData(object) else {
            return ConfigJSON.sha256Hex(encoded)
        }
        return ConfigJSON.sha256Hex(canonical)
    }

    static func decode(_ value: Any, context: String) throws -> ModelProfile {
        try ConfigJSON.decodeCanonical(ModelProfile.self, from: value, context: context)
    }

    static func jsonObject(_ model: ModelProfile) throws -> [String: Any] {
        let encoded = try data(model)
        guard let object = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "modelEncode")
        }
        return object
    }
}

// MARK: - Preferences wire rules

/// Preferences keep the ORIGINAL Codable shape (FloeCore
/// ModelSelectionPreferences.swift:18-137). The two server-owned fields are
/// NOT client authority:
/// * `syncRevision` in the payload must equal the CAS revision the client
///   read (re-sent via the envelope revision);
/// * the stored value is recomputed with the ORIGINAL increment-only rule
///   (ConversationCenter.swift:7176-7177 `updatedAt = Date(); syncRevision
///   += 1`; mirrored caller-side increments at LocalModelsSettingsView.swift
///   :106,:140). No timestamp-only revision, no dummy 0, no first-model or
///   fake IDs. MC-R1: the preferences CAS chain is UNCHANGED by this repair
///   (it already advanced + rejected stale inside the writer transaction).
enum ConfigPreferencesRules {
    static func applyServerOwnership(_ decoded: ModelSelectionPreferences,
                                     expectedRevision: Int64) throws -> ModelSelectionPreferences {
        guard decoded.syncRevision == expectedRevision else {
            throw ConfigDomainError(code: .staleRevision,
                                    reason: "preferencesPayloadRevision")
        }
        guard expectedRevision < Int64.max else {
            throw ConfigDomainError(code: .staleRevision, reason: "preferencesRevisionExhausted")
        }
        var updated = decoded
        updated.updatedAt = Date()
        updated.syncRevision = expectedRevision + 1
        return updated
    }
}

// MARK: - Catalog state

/// Provider catalog state after the ONE original decoder. The bundled asset
/// is injected as bounded bytes (≤ ProviderCatalogIndex.maximumDocumentBytes
/// = 2 MiB, ProviderCatalog.swift:242) by the trusted host resource
/// handoff; a bare .so `Bundle.module` load is unusable (service-map
/// "gate"/"probecatalog" Bundle.module caveats), so there is NO bundle
/// fallback and NO fabricated catalog: absent bytes ⇒ typed
/// needsConfiguration, invalid bytes ⇒ typed gate-style fail-closed refusal
/// (ProviderCatalogValidationError). The source-pinned asset keeps its
/// license/project provenance (document.source.license/project,
/// ProviderCatalog.swift:135-155).
public struct ConfigCatalogSnapshot: Sendable {
    public let entryCount: Int
    public let documentDigest: String
    public let sourceLicense: String
    public let sourceProject: String
    public let sourceURL: String
    public let fetchedAt: String
}

enum ConfigCatalogValidator {
    /// Returns either the validated index or the typed refusal. NEVER falls
    /// back to an empty/implicit catalog.
    static func validate(_ data: Data) -> Result<ProviderCatalogIndex, ConfigDomainError> {
        guard data.count <= ProviderCatalogIndex.maximumDocumentBytes else {
            return .failure(ConfigDomainError(code: .payloadTooLarge,
                                              reason: "catalogBytes\(data.count)"))
        }
        do {
            return .success(try ProviderCatalogIndex.validated(from: data))
        } catch {
            return .failure(ConfigDomainError(code: .persistenceUnavailable,
                                              reason: "catalogFailClosed"))
        }
    }

    static func snapshot(_ index: ProviderCatalogIndex, data: Data) -> ConfigCatalogSnapshot {
        ConfigCatalogSnapshot(
            entryCount: index.all.count,
            documentDigest: ConfigJSON.sha256Hex(data),
            sourceLicense: index.document.source.license,
            sourceProject: index.document.source.project,
            sourceURL: index.document.source.url,
            fetchedAt: index.document.source.fetchedAt
        )
    }
}

// MARK: - Web-search wire DTOs (original Codable shapes; secrets NEVER here)

/// Persisted web-search configuration list. WebSearchProviderConfiguration
/// (overlay FloeAndroidWebTools WebRetrievalModels.swift:34-66) is secret
/// free: `credentialAccount` is an account identifier, not a value. The
/// corresponding WebSearchCredential VALUE map ([String:String]) is fetched
/// from the gateway by that account at resolution time only, and is never
/// serialized into persisted JSON, command frames, event frames, logs or
/// prompts.
public enum ConfigWebSearchLimits {
    public static let maximumProviders = 32
    /// Same bound the gateway itself enforces for one secret
    /// (SecretGatewayLimits.maximumSecretBytes).
    public static let maximumCredentialBytes = 65_536
    /// Bounded persisted configuration list (16 KiB is the intent-JSON class
    /// bound; provider lists stay far below, cap keeps the frame promise).
    public static let maximumConfigurationJSONBytes = 32_768
}

public struct WebSearchProviderState: Sendable {
    public enum CredentialState: String, Sendable, Equatable {
        case available
        /// Original rule: only searxng is credential-free
        /// (WebSearchProviderKind.requiresCredential, WebRetrievalModels.
        /// swift:23 `self != .searxng`).
        case noCredentialRequired
        case gatewayUnregistered
        case secretMissing
        case secretLocked
        case secretInvalidated
        case outcomeUnknown
    }
    public let configuration: WebSearchProviderConfiguration
    /// Typed availability of the credential behind the gateway. `available`
    /// is proven only by a successful bounded decode of the credential JSON;
    /// the decoded values are never copied into this state.
    public let credentialState: CredentialState

    public func jsonObject() -> [String: Any] {
        [
            "id": configuration.id.uuidString,
            "kind": configuration.kind.rawValue,
            "displayName": configuration.displayName,
            "endpoint": configuration.endpoint?.absoluteString as Any,
            "credentialAccount": configuration.credentialAccount,
            "credential": credentialState.rawValue,
            "enabled": configuration.enabled,
            "priority": configuration.priority,
            "region": configuration.region as Any,
            "options": configuration.options,
        ]
    }
}

extension ConfigCredentialAvailability {
    /// Shared projection for gateway reads (no new vocabulary: the mailbox
    /// backend errors map onto the SAME four accepted availability cases;
    /// transient backend-class errors are NOT availability and return nil so
    /// callers can report their own disposition).
    ///
    /// MC-R3 correction: `.invalidReference` is a PRE-TICKET format refusal
    /// and does NOT prove the pre-existing secret is absent. Returning nil
    /// keeps the honest fail-closed paths (resolve ⇒ secretLocked,
    /// secretStatus ⇒ outcomeUnknown), never a `.secretMissing` claim that
    /// invites an overwrite or masks a real record. `secretMissing` stays
    /// reachable ONLY through an actual authoritative read miss (the gateway
    /// returned nil, or the settled status 2 / backendSkippedNoEffect path).
    static func from(gatewayError error: Error) -> ConfigCredentialAvailability? {
        if let secretError = error as? SecretGatewayError {
            switch secretError {
            case .needsConfiguration:
                return .gatewayUnregistered
            }
        }
        if let backend = error as? SecretBackendError {
            switch backend {
            case .deviceLocked:
                return .secretLocked
            case .authenticationFailed, .keyUnavailable, .corruptRecord:
                return .secretInvalidated
            default:
                return nil
            }
        }
        return nil
    }
}

// MARK: - Probe wire outcome

/// Typed probe result. `discoveredModels` carries the ORIGINAL ModelProfile
/// JSON the adapter returned; NOTHING is auto-installed into the store
/// (no preset/model auto-install; the editor owns selection).
public struct ConfigProbeOutcome: Sendable {
    public enum Status: String, Sendable, Equatable {
        case connected
        case failed
        case cancelled
        case outcomeUnknown
    }
    public let providerID: UUID
    public let status: Status
    public let modelCount: Int
    public let discoveredModels: [ModelProfile]
    /// Closed, redacted failure identifier — never raw provider bodies
    /// (SecretRedactor.redact applied at the boundary; contract secretHygiene).
    public let failureReason: String?

    func jsonObject() throws -> [String: Any] {
        var models: [[String: Any]] = []
        models.reserveCapacity(discoveredModels.count)
        for model in discoveredModels {
            models.append(try ConfigModelSnapshot.jsonObject(model))
        }
        return [
            "providerID": providerID.uuidString,
            "status": status.rawValue,
            "modelCount": modelCount,
            "discoveredModels": models,
            "failureReason": failureReason as Any,
        ]
    }
}