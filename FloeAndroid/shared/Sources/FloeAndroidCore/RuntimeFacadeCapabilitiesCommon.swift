// SPDX-License-Identifier: MPL-2.0
//
// RB-6 capabilities/skills/MCP — closed shared vocabulary for the three
// domain packages (private source candidate; NOT compiled, NOT executed,
// NOT registered by this package).
//
// Wire authority (frozen, verbatim):
// * The 7 configuration commands and their closed scopes/create flags come
//   ONLY from BridgeEnvelopeV3.commandRules (:133-148). This file adds no
//   command, no label, no scope and no create flag; payload operations below
//   are the closed RB6 vocabulary INSIDE those existing rules.
// * Revision shapes follow contract.json commandVocabulary:
//   skills   → "skill.<id>/version"   (validator stores PersistedSkill
//              rewritten_digest as the durable CAS authority; the wire
//              version string is that digest — SkillStore.swift:114-129)
//   mcp      → "mcp.<serverID>/config-hash" (canonical sorted-key JSON
//              SHA-256 of the persisted MCPServerConfiguration)
//   receipts → queue receipt only pre-commit (RB1); REAL ids only after the
//              original atomic commit (contract receiptModel).
// * Error codes reuse the frozen accepted ConfigWireCode vocabulary (RB2
//   RuntimeFacadeConfigModels.swift:41-56 — same accepted family the effect
//   wire already projects; contract.json errorCodeVocabulary). RB6 invents no
//   new wire codes. capabilityNotUsable is projected as
//   .credentialUnavailable/.needsConfiguration/.runtimeUnavailable typed
//   sub-reasons exactly where contract maps them; "capabilityNotUsable"
//   remains the run-admission code owned by RB4/RB5, never minted here.
// * Root/epoch/generation ownership: every durable/staged object binds the
//   CURRENT accepted epoch (AndroidRuntimeBootstrap generation) and the
//   trusted root fingerprint; an old-generation token is a typed refusal,
//   never a silent success (RB1 admission; coordinator guidance).
import Foundation
import Crypto
import FloeTools

// MARK: - RB6 closed limits (documented bases)

public enum SkillsMcpLimits {
    /// One command payload inside the frozen 64 KiB envelope (RB2 precedent:
    /// ConfigPageBudget.maximumCommandPayloadBytes = 61_440). Shared.
    public static var maximumPayloadBytes: Int { ConfigPageBudget.maximumCommandPayloadBytes }
    /// Oversize domain content (skill markdown detail, tool schema views) is
    /// served in 32 KiB owned windows — SettingsDomainV1.maximumChunkBytes —
    /// never truncated inside a page item (RB1 typed carrier decision: no
    /// new tiny caps, no silent truncation).
    public static var maximumWindowBytes: Int { 32_768 }
    /// Staged install/upgrade review lifetime. Bounded like the frozen
    /// save-intent LIVE slot (SecretSaveIntentVault liveSlotTTLMillis = 120 s)
    /// is NOT appropriate for a review a human reads; the native review has
    /// no TTL at all (SkillsCenter pendingInstallation lives until the
    /// sheet closes). RB6 binds reviews to the CURRENT runtime generation
    /// and caps live reviews to 8 (saturation is a typed refusal). Expiry is
    /// generation-scoped retirement, never a wall-clock lie.
    public static let maximumLiveReviews = 8
    /// Staged folder-import receipts (host-issued) expire at their own
    /// announced TTL bounded to this ceiling (30 min). Bytes never enter
    /// JSON; only the opaque handle does (attachment staging precedent,
    /// BRIDGE_V3_MAIN_DECISIONS.attachmentPreRunClarification).
    public static let maximumStagingReceiptTTLSec: Int = 1_800
    /// MCP refresh generations and per-server tool inventory bounds come
    /// from the ORIGINAL client constants (MCPRemoteClient:
    /// hard discovery cap 512 tools, 768 KiB discovery metadata). RB6 adds
    /// no wider set; per-server retained projections ≤512.
    public static let maximumMcpToolsPerServer: Int = 512
    /// Canonical identity lengths for opaque tokens minted by RB6 domains.
    public static let tokenHexLength = 32
    /// Detail dictionaries inside terminal RuntimeCommandResult stay
    /// identifier-only (RB1 frozen carrier: detail [String:String]).
    public static let maximumDetailPairs = 12
}

// MARK: - Opaque RB6 identity (host-session bound, never model-mintable)

/// `rev:v1:` + 32 lowercase hex — one staged install/upgrade review token
/// minted ONLY by the SkillsDomain actor after a real staging commit exists.
/// `cxl:v1:`/`stage:v1:` variants for cancels/receipts reuse the same shape
/// rule via explicit namespace prefixes; a model envelope can never address
/// a review without the domain having minted it in the CURRENT generation.
public enum FacadeCapabilityToken {
    public static func isValid(_ value: String, prefix: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == prefix.utf8.count + SkillsMcpLimits.tokenHexLength,
              value.hasPrefix(prefix) else { return false }
        let hex = String(value.dropFirst(prefix.count))
        guard hex.count == SkillsMcpLimits.tokenHexLength else { return false }
        return hex.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
    public static func make(namespace: String) -> String {
        var random = Data(count: 16)
        for index in random.indices { random[index] = UInt8.random(in: 0...255) }
        return namespace + random.map { String(format: "%02x", $0) }.joined()
    }
    public static let reviewPrefix = "rev:v1:"
    public static let stagingPrefix = "stg:v1:"
    public static let effectPrefix = "eff:v1:"
}

// MARK: - Root/generation binding

/// The CURRENT trusted runtime binding every RB6 durable/staged object
/// records: the accepted generation epoch (RB1 `currentPumps().epoch`, and
/// only while `storeReady`) plus the root fingerprint supplied by the
/// trusted host binding — the approved RB1 source exposes NO public root
/// accessor from outside its lifecycle lock (the fingerprint appears only
/// inside `statusSnapshotJSON`), so this package deliberately takes it from
/// the host that CALLED `start(rootPath:ownerToken:epoch:)` instead of
/// inventing an RB1 API. Never read from an envelope. An object minted under
/// one root generation can never be mutated or read back as success under a
/// different generation: the domain answers a typed staleGeneration refusal.
public struct FacadeRootGeneration: Sendable, Equatable {
    public let epoch: UInt64
    public let rootFingerprint: String

    public init?(epoch: UInt64, rootFingerprint: String) {
        guard epoch > 0,
              rootFingerprint.utf8.count == 8,
              rootFingerprint.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              }) else { return nil }
        self.epoch = epoch
        self.rootFingerprint = rootFingerprint
    }
}

/// Trusted host seam (Main binds; NOT model-visible): the CURRENT accepted
/// epoch's root fingerprint. Combined with the REAL
/// `AndroidRuntimeBootstrap.currentPumps()` fence by `currentRootBinding()`.
public protocol SkillsMcpRootBindingProviding: Sendable {
    func rootFingerprint(epoch: UInt64) -> String?
}

/// Honest "no host binding yet": every generation check fails closed. NOT a
/// fabricated fingerprint (the trusted root never comes from this package).
public struct SkillsMcpRootBindingUnavailable: SkillsMcpRootBindingProviding {
    public init() {}
    public func rootFingerprint(epoch: UInt64) -> String? { nil }
}

/// nil when no accepted generation currently owns the store. Callers MUST
/// fail closed (typed runtimeUnavailable) — no default zero (coordinator RB1
/// owned-work guidance 2026-10-19; RB1 stores admission).
public func currentRootBinding(from provider: any SkillsMcpRootBindingProviding)
    -> FacadeRootGeneration? {
    guard let pumps = AndroidRuntimeBootstrap.currentPumps(), pumps.storeReady,
          let fingerprint = provider.rootFingerprint(epoch: pumps.epoch),
          let binding = FacadeRootGeneration(epoch: pumps.epoch,
                                             rootFingerprint: fingerprint) else {
        return nil
    }
    return binding
}

// MARK: - Canonical config hash (MCP revision)

/// Deterministic revision token for one persisted MCPServerConfiguration:
/// SHA-256 over the ORIGINAL Codable sorted-key bytes (MCPRemoteToolSource
//  .swift:16-47 — the config already has a stable synthesized Codable shape;
//  credentials never live inside it, only the credential HEADER NAME and the
//  account-deriving endpoint). This is "mcp.<serverID>/config-hash" from
//  contract.json commandVocabulary — the hash is opaque revision material,
//  never a secret (endpoint/scheme/port/name are non-secret config).
public enum MCPServerConfigHash {
    public static func digest(of configuration: MCPServerConfiguration) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let bytes = try? encoder.encode(configuration) else {
            return "invalid"
        }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public static func resourceID(serverID: UUID) -> String {
        "mcp.\(serverID.uuidString)"
    }
}

// MARK: - Canonical MCP credential identity (original account rule)

/// The ORIGINAL credential account rule from MCPSettingsCenter.credentialAccount
/// (FloeApp SkillsView.swift:594-607):
/// `mcp.<uuid>.<urlScheme>.<host>.<port>` — the URL SCHEME
/// (endpoint.scheme ?? "https"), the lowercased host and the port defaulted
/// (443 https / 80 http). An endpoint edit therefore derives a NEW account
/// (a saved key never silently follows the URL to another origin). The
/// legacy bare `mcp.<uuid>` account (legacyCredentialAccount :608-610) is a
/// deletion target only. Service domain: the ORIGINAL Keychain service
/// `org.floeagent.ios.mcp` (SkillsView.swift:372) — kept as the gateway
/// NAMESPACE (BRIDGE_V3 credentialGatewayIdentityClarification.existing
/// Reference: "MCP original service domain org.floeagent.ios.mcp plus
/// original credentialAccount"; the published gateway SecretSaveIntentVault
/// Tests pin the same namespace + "mcp.<uuid>.https.example.invalid.443"
/// account). NOT the provider "keychainAccount" namespace and never int:v1
/// as a stored reference.
public enum MCPCredentialIdentity {
    public static let serviceNamespace = "org.floeagent.ios.mcp"

    public static func account(for configuration: MCPServerConfiguration) -> String? {
        guard configuration.authentication != .none,
              let host = configuration.endpoint.host?.lowercased(), !host.isEmpty
        else { return nil }
        let scheme = configuration.endpoint.scheme?.lowercased() ?? "https"
        let port = configuration.endpoint.port ?? (scheme == "https" ? 443 : 80)
        return "mcp.\(configuration.id.uuidString).\(scheme).\(host).\(port)"
    }

    public static func legacyAccount(serverID: UUID) -> String {
        "mcp.\(serverID.uuidString)"
    }

    public static func opaqueReference(account: String) -> String {
        SecretGatewayNaming.opaqueReference(namespace: serviceNamespace, account: account)
    }
}

// MARK: - Typed availability projection (Kotlin-contract vocabulary mirror)

/// The ACCEPTED discovery availability vocabulary — mirrors
/// core/contracts RuntimeContracts.kt:13 `Availability { AVAILABLE,
/// NEEDS_CONFIGURATION, NEEDS_PERMISSION, NOT_IMPLEMENTED, UNSUPPORTED }`
/// (service-map "kotlin-contracts"). Swift-side source of truth; the Kotlin
/// projection binds these strings without inventing new states. An item is
/// AVAILABLE only when the ACTUAL current runtime can execute it right now:
/// never descriptor-only advertising, never a future Linux/root/phone/
/// Play-absent capability.
public enum FacadeCapabilityAvailability: String, Sendable, Codable, CaseIterable {
    case available = "AVAILABLE"
    case needsConfiguration = "NEEDS_CONFIGURATION"
    case needsPermission = "NEEDS_PERMISSION"
    case notImplemented = "NOT_IMPLEMENTED"
    case unsupported = "UNSUPPORTED"
}

/// Honest typed domain failure. Same closed codes as RB2 (frozen wire);
//  RB6 never adds a code.
public typealias CapabilitiesDomainError = ConfigDomainError

// MARK: - Closed envelope view (RB6 re-parse; validation stays structural)

/// Re-reads ONLY the closed fields the RB6 domains consume (RB2
/// ModelConfigurationCommandRouter.EnvelopeView pattern, same module):
/// payload (credential-name-scanned by ConfigJSON), revision pair, create
/// intent echo check and the opaque cursor. Shape never grants authority;
/// every domain decision re-checks the actual stores.
/// RB6 reads the envelope cursor from the PAYLOAD only: the frozen wire
/// validator REJECTS a top-level `cursor` on command.submit
/// (BridgeEnvelopeV3.swift:704-729 — cursor is the run-event role), so a
/// list/page cursor must be a closed payload field. This view therefore does
/// NOT read envelope["cursor"]; routers take `payload["cursor"]`.
struct CapabilitiesEnvelopeView {
    let payload: [String: Any]?
    let payloadRaw: Data?
    let revision: ConfigRevision?
    let createIntent: Bool

    init(envelope: [String: Any]) throws {
        var payload: [String: Any]?
        var payloadRaw: Data?
        if let payloadObject = envelope["payload"] as? [String: Any] {
            payload = payloadObject
            if JSONSerialization.isValidJSONObject(payloadObject),
               let data = try? JSONSerialization.data(withJSONObject: payloadObject,
                                                      options: [.sortedKeys]) {
                payloadRaw = data
            }
        }
        var revision: ConfigRevision?
        if let revisionObject = envelope["revision"] as? [String: Any] {
            guard let resourceID = revisionObject["resourceID"] as? String,
                  let version = revisionObject["version"] as? String,
                  !resourceID.isEmpty, !version.isEmpty,
                  resourceID.utf8.count <= 256, version.utf8.count <= 256 else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "revisionShape")
            }
            revision = ConfigRevision(resourceID: resourceID, version: version)
        } else if envelope["revision"] != nil {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "revisionPresentUnreadable")
        }
        var createIntent = false
        if let createValue = envelope["createIntent"] {
            guard let typed = createValue as? Bool else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "createIntentShape")
            }
            createIntent = typed
        }
        self.payload = payload
        self.payloadRaw = payloadRaw
        self.revision = revision
        self.createIntent = createIntent
    }

    /// Typed page cursor helper (payload string; ≤24 chars, decimal index
    /// only — the ConfigPageComposer index shape).
    func payloadCursor() throws -> String? {
        guard let payload else { return nil }
        switch payload["cursor"] {
        case .none:
            return nil
        case let value as String:
            guard value.utf8.count <= 24, value.allSatisfy(\.isNumber), !value.isEmpty else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "payloadCursorShape")
            }
            return value
        default:
            throw ConfigDomainError(code: .invalidEnvelope, reason: "payloadCursorShape")
        }
    }
}
