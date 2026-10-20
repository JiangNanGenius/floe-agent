// SPDX-License-Identifier: MPL-2.0
//
// RB-6 MCP domain — the REAL MCP server administration + connection
// lifecycle behind the frozen `mcp.servers.list` / `mcp.connect` /
// `mcp.disconnect` command rules (private source candidate; NOT compiled,
// NOT executed, NOT registered by this package).
//
// Reuse (exact reviewed originals; the shared overlay MCPRemoteToolSource
// differs from the iOS file ONLY in the pinned transport deltas — see
// provenance/PINS.json):
// * MCPServerConfiguration (+Authentication +validate()) — the ORIGINAL
//   Codable config shape and rules (scheme/host, no URL-embedded
//   credentials, allowInsecureHTTP gate, RFC-token custom header names vs
//   the MCP reserved set, timeoutSeconds clamp 5...120). NO transport or
//   auth kind is invented; stdio/SSH/Linux subprocess transports were never
//   part of this client (Streamable HTTP POST + bounded SSE response
//   parsing only) and remain declared G03 dependencies with honest
//   NOT_IMPLEMENTED projections — never silently-dropped native
//   functionality, never an Android host subprocess fallback.
// * MCPRemoteClient — the actor itself: era negotiation
//   (2026-07-28 stateless-preferred → legacy 2025-11-25 initialize +
//   Mcp-Session-Id), Accept/MCP-Protocol-Version/Mcp-Method/Mcp-Name/
//   Mcp-Param-* header machinery, bounded pagination (32 pages/512 tools/
//   32 KiB schema/768 KiB metadata), 2 MiB response cap, the
//   MCPNoRedirectSessionDelegate fail-closed redirect policy preserved via
//   the QUALIFIED StreamingTransport.makeSession seam on Android/Linux
//   (shared file :310-322 — no metadata/XML assumptions imported), and the
//   disconnect-generation checks that make a late listTools/call result
//   unable to restore a closed connection (:554-556, :639-644).
// * MCPRemoteToolSource.register/unregister/namespacedName — atomic
//   replace-by-prefix registration into ToolRunnerRegistry.shared with the
//   ORIGINAL untrusted-data descriptor and the original JSON-Schema subset
//   validation before crossing the remote trust boundary. MCP schema/tool
//   output NEVER grants permission.
// * SecretSaveIntentVault (CURRENT qualified body sha 64eac84b… per Main's
//   gateway-qualifier re-pin — the older frozen bodies are NOT restored) +
//   SubjectKind.mcpSave + RouteBinding exact matching + SaveIntentLease
//   (non-Sendable, one scope, close() zeroizes; failed close keeps the
//   admission fail-closed).
// * SecretGatewayRegistry/SecretGatewayNaming.opaqueReference — canonical
//   MCP identity: namespace "org.floeagent.ios.mcp" (the ORIGINAL Keychain
//   service, SkillsView.swift:372, pinned by the published gateway tests) +
//   account mcp.<uuid>.<scheme>.<host>.<port> (original credentialAccount
//   rule :594-607) → the existing ref:v1:+SHA-256 reference. NOT the
//   provider "keychainAccount" namespace; NEVER int:v1 as a stored
//   reference; the legacy bare mcp.<uuid> account is delete-only.
// * SecretDispositionClassifier + CV-R4 (VAULT_GATEWAY_FAILURE_SEMANTICS):
//   ambiguous post-claim gateway errors are outcomeUnknown with the durable
//   intent kept — never "no effect", never a fake compensation success.
//   The current vault-07 source owns the credential_records queue/context;
//   this MCP ledger is the RB2 providerSecretCleanup ANALOG in the canonical
//   app_settings table with provably disjoint account prefixes (mcp.* vs
//   provider.*/credential.*/host.*/approval-model) — no duplicate cleanup
//   journal against the vault tables, no new secret file.
//
// ios-reference extraction (behavior mirrored from MCPSettingsCenter,
// SkillsView.swift:362-608 — App UI-owner code, never imported):
// ConnectionState vocabulary; refreshGenerationByServerID monotonic fencing
// (a newer generation supersedes stale results; a superseded client is
// disconnected and never registers); setEnabled(false) = invalidate +
// unregister + disconnect + inactive + empty tools; remove = same + bound
// account delete (legacy too); Set/Keep/Clear auth rules (explicit .none
// deletes; empty credential + existing = KEEP; auth-scheme/endpoint change
// re-binds a NEW account and queues the old for cleanup); activate once for
// enabled servers at bind; per-tool toggle re-registers with the EXISTING
// client (no reconnect); per-server error retained until the next
// successful refresh clears it.
//
// Honesty rules honored throughout: discovery counts only from a VALID
// server response; queue acceptance is never "connected"; connect refuses
// typed BEFORE network when the admission gate is closed, the gateway is
// unregistered, or a required secret is missing/locked/unreadable (no LAN
// anonymous fallback; explicit .none auth only); disconnect cancels only
// the matching server/root-generation owned workers; retry keeps the actual
// saved config/draft; tool results cross only the original bounded paths.
import Foundation
import Crypto
import FloeCore
import FloeTools
import FloePersistence

// MARK: - Trusted host seams

/// Host route registry binding for save-intent consumption (RB2
/// ConfigRouteContextProviding analog; NEVER wire-fed).
public protocol SkillsMcpRouteContextProviding: Sendable {
    func currentRoute() -> RouteBinding?
}

public struct SkillsMcpRouteUnavailable: SkillsMcpRouteContextProviding {
    public init() {}
    public func currentRoute() -> RouteBinding? { nil }
}

/// Transport admission for live MCP network dispatch. DEFAULT CLOSED:
/// connect/refresh refuses typed transportUnavailable BEFORE creating any
/// client until Main's qualified gateway/transport/TLS/product-UID gates
/// admit. Nothing in this package exercises network or keys.
public protocol MCPTransportAdmitting: Sendable {
    var admitsMCPNetwork: Bool { get }
}

public struct MCPTransportAdmissionClosed: MCPTransportAdmitting {
    public init() {}
    public var admitsMCPNetwork: Bool { false }
}

/// The ORIGINAL client construction seam. Production binds
/// OriginalMCPClientFactory (the real actor with its own qualified
/// ephemeral session — StreamingTransport.makeSession +
/// MCPNoRedirectSessionDelegate on Android/Linux, shared file :310-322).
/// Coordinator lifecycle tests bind a scripted maker so fencing/CAS/
/// registration ordering get real coverage WITHOUT network; the concrete
/// client's protocol behavior stays covered by the original FloeAgent
/// suites + the pinned transport-lane proof (provenance/EQUIVALENT_TESTS.md
/// records the split — no scripted fake is ever presented as the real
/// transport path).
public protocol MCPClientMaking: Sendable {
    func make(configuration: MCPServerConfiguration,
              credential: String?) throws -> MCPRemoteClient
}

public struct OriginalMCPClientFactory: MCPClientMaking {
    public init() {}
    public func make(configuration: MCPServerConfiguration,
                     credential: String?) throws -> MCPRemoteClient {
        // The ORIGINAL init already runs configuration.validate() FIRST
        // (MCPRemoteToolSource.swift:230-246); re-asserting here keeps the
        // typed wire mapping honest before the actor hop (defense in depth).
        try configuration.validate()
        return try MCPRemoteClient(configuration: configuration, credential: credential)
    }
}

// MARK: - Typed refusals

enum MCPDomainRefusal: Error, Sendable, Equatable {
    case runtimeNotReady
    case transportClosed
    case gatewayUnregistered
    case needsRouteContext
}

// MARK: - Per-server live state

public enum MCPServerStateProjection: Sendable, Equatable {
    case inactive
    case connecting(generation: UInt64)
    case ready(toolCount: Int, revision: String)
    case failed(reason: String, revision: String)

    var wireObject: [String: Any] {
        switch self {
        case .inactive: return ["state": "inactive"]
        case .connecting(let g): return ["state": "connecting", "generation": String(g)]
        case .ready(let count, let rev):
            return ["state": "ready", "toolCount": count, "revision": rev]
        case .failed(let reason, let rev):
            return ["state": "failed", "reason": reason, "revision": rev]
        }
    }
}

struct MCPServerConnection {
    var generation: UInt64 = 0
    var client: MCPRemoteClient?
    var tools: [MCPDiscoveredTool] = []
    var state: MCPServerStateProjection = .inactive
    /// The config-hash this connection was established at; a config change
    /// invalidates, and completion re-checks equality (original
    /// SkillsView:514-520).
    var boundConfigHash: String?
}

/// Mirrors RB2's ProviderSecretCleanup intent shape for the MCP namespace.
struct MCPSecretCleanupIntent: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable { case accountReplace, serverRemove }
    let serverID: UUID
    let account: String
    let kind: Kind
}

// MARK: - MCPDomain

public actor MCPDomain {

    /// The ORIGINAL persistence key (SkillsView.swift:371). Android is
    /// local-only (no cloud KV; BRIDGE_V3 localSync) and the canonical
    /// SINGLE app_settings table replaces UserDefaults — the documented RB2
    /// defaultsKey pattern. The stored JSON is the ORIGINAL
    /// [MCPServerConfiguration] Codable shape (secret-free by construction:
    /// credentials live ONLY in the gateway under the canonical reference).
    static let serversSettingsKey = "floe.mcp.remoteServers.v1"
    static let cleanupSettingsKey = "floe.mcp.secretCleanup.v1"

    private let database: DatabaseManager
    private let settingsStore: SQLiteSettingsStore
    // internal (not private): the test target verifies the canonical
    // reference/bytes through @testable; production behavior is unchanged.
    let gateway: any SecretGatewayServicing
    private let routeContext: any SkillsMcpRouteContextProviding
    private let transportAdmission: any MCPTransportAdmitting
    private let clientFactory: any MCPClientMaking
    private let ownedWork: ConfigOwnedWorkLifecycle
    private let toolWork: FacadeToolWorkCoordinator
    private let registry: ToolRunnerRegistry
    private let hostContext: any SkillsHostContextProviding
    /// CAP-SECRET-2: the SAME accepted per-server operation ownership the
    /// model domain uses (one coordinator per live DatabaseManager instance,
    /// exact-ticket release, durable pending owner with retained root lease).
    /// Save/replace/remove/recover share it, so a cleanup drain can never
    /// delete a reference a live save owns.
    private let ownership: any ProviderOperationOwning

    // internal (not private): the CapabilitiesMCPObserving conformance and
    // the router bindings read these through actor-isolated async methods.
    var servers: [MCPServerConfiguration] = []
    var connections: [UUID: MCPServerConnection] = [:]
    var loaded = false

    public struct Services: Sendable {
        public let database: DatabaseManager
        public let gateway: any SecretGatewayServicing
        public let routeContext: any SkillsMcpRouteContextProviding
        public let transportAdmission: any MCPTransportAdmitting
        public let clientFactory: any MCPClientMaking
        public let ownedWork: ConfigOwnedWorkLifecycle
        public let toolWork: FacadeToolWorkCoordinator
        public let registry: ToolRunnerRegistry
        public let hostContext: any SkillsHostContextProviding
        /// Optional explicit owner (qualification tests / Main composition).
        /// Production default: the shared context coordinator resolved from
        /// the ACTUAL DatabaseManager instance.
        public let ownership: (any ProviderOperationOwning)?
        public init(database: DatabaseManager, gateway: any SecretGatewayServicing,
                    routeContext: any SkillsMcpRouteContextProviding,
                    transportAdmission: any MCPTransportAdmitting,
                    clientFactory: any MCPClientMaking,
                    ownedWork: ConfigOwnedWorkLifecycle,
                    toolWork: FacadeToolWorkCoordinator,
                    registry: ToolRunnerRegistry = .shared,
                    hostContext: any SkillsHostContextProviding,
                    ownership: (any ProviderOperationOwning)? = nil) {
            self.database = database
            self.gateway = gateway
            self.routeContext = routeContext
            self.transportAdmission = transportAdmission
            self.clientFactory = clientFactory
            self.ownedWork = ownedWork
            self.toolWork = toolWork
            self.registry = registry
            self.hostContext = hostContext
            self.ownership = ownership
        }
    }

    public init(services: Services) {
        self.database = services.database
        self.settingsStore = SQLiteSettingsStore(database: services.database)
        self.gateway = services.gateway
        // MCP-scoped owner pool: the accepted coordinator TYPE, but a
        // SEPARATE namespace from the model provider pool (independent
        // resource IDs may be equal). All MCP facades over this database
        // share the MCP coordinator.
        self.ownership = services.ownership
            ?? MCPOperationCoordinatorRegistry.shared.coordinator(
                for: services.database)
        self.routeContext = services.routeContext
        self.transportAdmission = services.transportAdmission
        self.clientFactory = services.clientFactory
        self.ownedWork = services.ownedWork
        self.toolWork = services.toolWork
        self.registry = services.registry
        self.hostContext = services.hostContext
    }

    // MARK: Admission + loading

    private func requireBinding() throws -> FacadeRootGeneration {
        guard let pumps = AndroidRuntimeBootstrap.currentPumps(), pumps.storeReady,
              let fingerprint = hostContext.rootFingerprint(epoch: pumps.epoch),
              let binding = FacadeRootGeneration(epoch: pumps.epoch,
                                                 rootFingerprint: fingerprint) else {
            throw MCPDomainRefusal.runtimeNotReady
        }
        return binding
    }

    /// Fresh persisted read on EVERY command: two facades over one database
    /// must not act on a stale cache (the shared key holds every server row).
    private func loadServers() async throws {
        let raw = try await settingsStore.value(forKey: Self.serversSettingsKey)
        servers = try Self.decodeServerArray(raw)
        loaded = true
    }

    private static func decodeServerArray(_ raw: String?) throws
        -> [MCPServerConfiguration]
    {
        guard let raw else { return [] }
        guard let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([MCPServerConfiguration].self,
                                                      from: data) else {
            // Corrupt stored JSON must NOT wipe live configs silently:
            // fail closed typed (delta D-MCP2 in provenance).
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "mcpServersCorrupt")
        }
        return decoded
    }

    /// One targeted mutation of the SHARED server array, executed as ONE
    /// real writer transaction: read the NEWEST persisted array, verify the
    /// TARGET row's revision, change ONLY that row, write, and return the
    /// committed array for the cache refresh. Sibling records written by
    /// another facade are always preserved; a stale target CAS refuses with
    /// NO effect.
    private enum ServerMutation {
        case upsert(MCPServerConfiguration, expectedHash: String?)
        case remove(serverID: UUID, expectedHash: String)
        case setEnabled(serverID: UUID, expectedHash: String, enabled: Bool)
        case setTool(serverID: UUID, expectedHash: String,
                     remoteName: String, enabled: Bool)
    }

    private func mutateServers(_ mutation: ServerMutation) async throws
        -> [MCPServerConfiguration]
    {
        let key = Self.serversSettingsKey
        return try await database.writer { db in
            let raw = try String.fetchOne(
                db,
                sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [key])
            var current = try Self.decodeServerArray(raw)
            switch mutation {
            case .upsert(let configuration, let expectedHash):
                if let index = current.firstIndex(where: { $0.id == configuration.id }) {
                    guard let expectedHash,
                          MCPServerConfigHash.digest(of: current[index]) == expectedHash else {
                        throw ConfigDomainError(code: .staleRevision,
                                                reason: "mcpServerCAS")
                    }
                    current[index] = configuration
                } else {
                    guard expectedHash == nil else {
                        throw ConfigDomainError(code: .staleRevision,
                                                reason: "mcpServerDisappeared")
                    }
                    current.append(configuration)
                }
            case .remove(let serverID, let expectedHash):
                guard let index = current.firstIndex(where: { $0.id == serverID }),
                      MCPServerConfigHash.digest(of: current[index]) == expectedHash else {
                    throw ConfigDomainError(code: .staleRevision,
                                            reason: "mcpServerCAS")
                }
                current.remove(at: index)
            case .setEnabled(let serverID, let expectedHash, let enabled):
                guard let index = current.firstIndex(where: { $0.id == serverID }),
                      MCPServerConfigHash.digest(of: current[index]) == expectedHash else {
                    throw ConfigDomainError(code: .staleRevision,
                                            reason: "mcpServerCAS")
                }
                current[index].enabled = enabled
            case .setTool(let serverID, let expectedHash, let remoteName, let enabled):
                guard let index = current.firstIndex(where: { $0.id == serverID }),
                      MCPServerConfigHash.digest(of: current[index]) == expectedHash else {
                    throw ConfigDomainError(code: .staleRevision,
                                            reason: "mcpServerCAS")
                }
                if enabled {
                    current[index].disabledRemoteToolNames.remove(remoteName)
                } else {
                    current[index].disabledRemoteToolNames.insert(remoteName)
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(current)
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value_json, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET
                        value_json = excluded.value_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [key, String(decoding: data, as: UTF8.self),
                            MCPSecretCleanupLedger.timestamp(Date())])
            return current
        }
    }

    /// The NEWEST persisted row for one server id, read from the one owned
    /// store. Used ONLY under a held operation owner (CAP-SECRET-2): the
    /// destructive decision must be made against the current row, never
    /// against a previously cached array. Corrupt stored JSON is a typed
    /// refusal (never "no row", which would authorize a delete).
    private func storedServer(id: UUID) async throws -> MCPServerConfiguration? {
        guard let raw = try await settingsStore.value(forKey: Self.serversSettingsKey) else {
            return nil
        }
        return try Self.decodeServerArray(raw).first { $0.id == id }
    }

    // MARK: Shared per-server secret ownership (accepted model physical API)

    /// Typed failure carrier for the ownership helpers: `Result` requires an
    /// Error failure, while the reply itself is the actor-owned JSON body.
    private struct MCPReplyFailure: Error {
        let reply: [String: Any]
    }

    /// Atomic reservation BEFORE any secret/row effect. `.pendingReconciliation`
    /// gets exactly ONE bounded reconciliation attempt through the pending
    /// record's own witness; if the old physical lifetime is still genuinely
    /// outstanding the caller is refused typed and nothing is touched.
    private func beginServerSecretOperation(
        _ kind: ProviderOperationKind, serverID: UUID
    ) async -> Result<ProviderOperationTicket, MCPReplyFailure> {
        switch await ownership.beginOperation(providerID: serverID, kind: kind) {
        case .attached(let ticket):
            return .success(ticket)
        case .conflict:
            return .failure(MCPReplyFailure(reply: Self.rejection(ConfigDomainError(
                code: .duplicateInFlight, reason: "mcpOperationActive"))))
        case .capacityUnavailable:
            return .failure(MCPReplyFailure(reply: Self.rejection(ConfigDomainError(
                code: .mailboxSaturated, reason: "mcpOperationCapacityUnavailable"))))
        case .pendingReconciliation:
            _ = await reconcilePendingSecretOwner(serverID: serverID)
            if case .attached(let ticket) = await ownership.beginOperation(
                providerID: serverID, kind: kind) {
                return .success(ticket)
            }
            return .failure(MCPReplyFailure(reply: Self.rejection(ConfigDomainError(
                code: .duplicateInFlight, reason: "mcpPhysicalOwnerPending"))))
        }
    }

    /// ACTUAL runtime owned-work lease (RB1 registry, kind
    /// `.vaultMaintenance`) held across the awaited row/secret/cleanup chain.
    /// Attach failure fails closed BEFORE any effect.
    private func attachSecretOwnership(serverID: UUID)
        -> Result<ConfigOwnedWorkLease, MCPReplyFailure> {
        switch ownedWork.begin(kind: .vaultMaintenance,
                               ownerID: serverID.uuidString) {
        case .success(let lease):
            return .success(lease)
        case .failure(let rejection):
            return .failure(MCPReplyFailure(
                reply: Self.rejection(SkillsDomain.ownedWorkAttachError(rejection))))
        }
    }

    /// ONE bounded reconciliation attempt for a pending physical owner.
    /// The OLD operation's truth is read ONLY through the witness captured at
    /// its attempt time (never the current registry, which may be removed or
    /// re-pointed). A missing witness/receipt is honest unknown.
    public func reconcilePendingSecretOwner(serverID: UUID) async
        -> MCPPendingReconciliationOutcome
    {
        guard let pending = await ownership.pendingRecord(providerID: serverID) else {
            return .nothingPending
        }
        guard let recovery = await ownership.tryAcquireRecoveryLease(
            providerID: serverID) else {
            return .stillPending(reason: "recoveryAlreadyRunning")
        }
        let snapshot: PhysicalOperationSnapshot
        if let receipt = pending.receipt, let witness = pending.witness {
            snapshot = witness.physicalSnapshot(claim: receipt.claim)
        } else {
            snapshot = .notRecorded
        }
        var settledReason: String?
        switch snapshot {
        case .neverDispatched(let reason):
            settledReason = "neverDispatched.\(reason.rawValue)"
        case .settled(let status):
            // Physical execution finished; caller outcome and physical
            // settlement stay separate axes (the durable intent is finalized
            // by its OWN committed delete, not by this release).
            settledReason = "executionSettled.\(status)"
        case .queued, .claimedOutstanding, .notRecorded:
            settledReason = nil
        }
        guard let settledReason else {
            await ownership.releaseRecovery(recovery)
            return .stillPending(reason: pending.receipt == nil
                ? "noIndividualReceipt" : "physicalOutstanding")
        }
        if let receipt = pending.receipt, let witness = pending.witness {
            _ = witness.resolvePhysical(claim: receipt.claim)
        }
        let detached = pending.lease.map { ownedWork.settle($0) } ?? true
        let settled = await ownership.settlePending(providerID: serverID,
                                                    ticket: pending.ticket)
        await ownership.releaseRecovery(recovery)
        return settled
            ? .settledNow(reason: "\(settledReason).leaseDetached=\(detached)")
            : .stillPending(reason: "pendingIdentityAdvanced")
    }

    // MARK: mcp.servers.list

    public func list(cursor: String?) async throws -> sending [String: Any] {
        _ = try requireBinding()
        try await loadServers()
        var rows: [[String: Any]] = []
        for server in servers {
            let hash = MCPServerConfigHash.digest(of: server)
            let connection = connections[server.id] ?? MCPServerConnection()
            var row: [String: Any] = [
                "id": server.id.uuidString,
                "displayName": server.displayName,
                "endpoint": server.endpoint.absoluteString,
                "enabled": server.enabled,
                "allowInCanvas": server.allowInCanvas,
                "allowInsecureHTTP": server.allowInsecureHTTP,
                "authentication": server.authentication.rawValue,
                "credentialHeaderName": server.authentication == .customHeader
                    ? server.credentialHeaderName : NSNull(),
                "timeoutSeconds": server.timeoutSeconds,
                "disabledRemoteToolNames": server.disabledRemoteToolNames.sorted(),
                "revision": ["resourceID": MCPServerConfigHash.resourceID(serverID: server.id),
                             "version": hash],
                "connection": connection.state.wireObject,
                "toolCount": connection.tools.count,
                "tools": connection.tools
                    .prefix(SkillsMcpLimits.maximumMcpToolsPerServer)
                    .map { tool in
                        [
                            "remoteName": tool.remoteName,
                            "localName": MCPRemoteToolSource.namespacedName(
                                prefix: server.namespacePrefix + "_",
                                remoteName: tool.remoteName),
                            "displayName": tool.displayName ?? NSNull(),
                            "description": String(tool.toolDescription.prefix(512)),
                            "schemaBytes": tool.inputSchemaJSON.utf8.count,
                            "readOnlyHint": tool.readOnlyHint,
                            "destructiveHint": tool.destructiveHint,
                            "enabled": !server.disabledRemoteToolNames.contains(tool.remoteName),
                        ] as [String: Any]
                    },
                "credential": await credentialStatus(for: server),
                "secretCleanupPending": await cleanupIntentExists(serverID: server.id),
            ]
            rows.append(row)
        }
        let start = max(0, Int(cursor ?? "0") ?? 0)
        let slice = Array(rows.dropFirst(min(start, rows.count))
            .prefix(ConfigPageBudget.maximumItemsPerPage))
        let nextIndex = min(start, rows.count) + slice.count
        return [
            "servers": slice,
            "hasMore": nextIndex < rows.count,
            "nextCursor": nextIndex < rows.count ? String(nextIndex) : NSNull(),
            "transports": Self.transportsInventory(admitsNetwork: transportAdmission.admitsMCPNetwork),
            "gatewayRegistered": gateway.isRegistered,
        ]
    }

    static func transportsInventory(admitsNetwork: Bool) -> sending [[String: Any]] {
        [
            ["transport": "streamableHTTP2026-07-28",
             "availability": admitsNetwork ? "AVAILABLE" : "NEEDS_CONFIGURATION",
             "note": admitsNetwork ? "stateless-preferred era" : "transport admission gate closed"],
            ["transport": "streamableHTTPLegacySession2025-11-25",
             "availability": admitsNetwork ? "AVAILABLE" : "NEEDS_CONFIGURATION",
             "note": "initialize + Mcp-Session-Id era fallback"],
            ["transport": "sseResponseParsing",
             "availability": admitsNetwork ? "AVAILABLE" : "NEEDS_CONFIGURATION",
             "note": "text/event-stream response bodies (bounded)"],
            ["transport": "stdioHostSubprocess",
             "availability": "NOT_IMPLEMENTED",
             "note": "G03 resolved environment/jobs owned; never an Android host subprocess"],
            ["transport": "sshRemote",
             "availability": "NOT_IMPLEMENTED",
             "note": "G03 remote-host environment owned"],
            ["transport": "linuxGuest",
             "availability": "NOT_IMPLEMENTED",
             "note": "G03 Linux closure owned"],
        ]
    }

    // MARK: Credential reads (status never bytes; typed pre-dispatch)

    private func credentialStatus(for server: MCPServerConfiguration) async -> sending [String: Any] {
        guard server.authentication != .none else {
            return ["required": false, "state": "noneConfigured"]
        }
        guard gateway.isRegistered else {
            return ["required": true, "state": "gatewayUnregistered"]
        }
        guard let account = MCPCredentialIdentity.account(for: server) else {
            return ["required": true, "state": "secretMissing"]
        }
        let reference = MCPCredentialIdentity.opaqueReference(account: account)
        do {
            guard let bytes = try await gateway.read(reference: reference),
                  let text = String(data: bytes, encoding: .utf8), !text.isEmpty else {
                return ["required": true, "state": "secretMissing"]
            }
            return ["required": true, "state": "configured", "opaqueReference": reference]
        } catch {
            if let availability = ConfigCredentialAvailability.from(gatewayError: error) {
                return ["required": true, "state": availability.rawValue]
            }
            return ["required": true, "state": "secretLocked"]
        }
    }

    private enum MCPCredentialResolution {
        case resolved(String?)
        case unavailable(ConfigCredentialAvailability)
    }

    private func resolveCredential(for server: MCPServerConfiguration) async
        -> MCPCredentialResolution {
        switch server.authentication {
        case .none:
            // EXPLICIT native no-auth only; a missing ref or LAN endpoint
            // alone NEVER authorizes anonymous fallback (BRIDGE_V3
            // anonymousAuth).
            return .resolved(nil)
        case .bearerToken, .customHeader:
            guard gateway.isRegistered else { return .unavailable(.gatewayUnregistered) }
            guard let account = MCPCredentialIdentity.account(for: server) else {
                return .unavailable(.secretMissing)
            }
            let reference = MCPCredentialIdentity.opaqueReference(account: account)
            do {
                guard let bytes = try await gateway.read(reference: reference) else {
                    return .unavailable(.secretMissing)
                }
                guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty,
                      value.utf8.count <= MCPRemoteClient.maximumCredentialBytes,
                      !value.contains(where: { $0 == "\r" || $0 == "\n" }) else {
                    return .unavailable(.secretInvalidated)
                }
                return .resolved(value)
            } catch {
                if let availability = ConfigCredentialAvailability.from(gatewayError: error) {
                    return .unavailable(availability)
                }
                return .unavailable(.secretLocked)
            }
        }
    }

    // MARK: mcp.connect — save candidate schema (closed, secret-free)

    struct MCPSaveCandidate {
        let id: UUID
        let displayName: String
        let endpoint: URL
        let enabled: Bool
        let allowInCanvas: Bool
        let allowInsecureHTTP: Bool
        let authentication: MCPServerConfiguration.Authentication
        let credentialHeaderName: String
        let timeoutSeconds: Double
        let disabledRemoteToolNames: Set<String>
        let createIntent: Bool

        static let allowedKeys: Set<String> = [
            "id", "displayName", "endpoint", "enabled", "allowInCanvas",
            "allowInsecureHTTP", "authentication", "credentialHeaderName",
            "timeoutSeconds", "disabledRemoteToolNames", "createIntent",
        ]

        static func parse(_ dictionary: [String: Any]) throws -> MCPSaveCandidate {
            try ConfigJSON.closed(dictionary,
                                  allowed: allowedKeys,
                                  required: ["id", "displayName", "endpoint",
                                             "authentication"],
                                  context: "mcpCandidate")
            guard let idString = dictionary["id"] as? String,
                  let id = UUID(uuidString: idString) else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpCandidate.id")
            }
            guard let displayName = dictionary["displayName"] as? String,
                  !displayName.isEmpty, displayName.utf8.count <= 256 else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpCandidate.displayName")
            }
            guard let endpointString = dictionary["endpoint"] as? String,
                  endpointString.utf8.count <= 2_048,
                  let endpoint = URL(string: endpointString) else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpCandidate.endpoint")
            }
            guard let authRaw = dictionary["authentication"] as? String,
                  let authentication = MCPServerConfiguration.Authentication(rawValue: authRaw)
            else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "mcpCandidate.authentication")
            }
            let enabled = (dictionary["enabled"] as? Bool) ?? true
            let allowInCanvas = (dictionary["allowInCanvas"] as? Bool) ?? false
            let allowInsecureHTTP = (dictionary["allowInsecureHTTP"] as? Bool) ?? false
            let headerName = (dictionary["credentialHeaderName"] as? String) ?? "Authorization"
            let timeout = (dictionary["timeoutSeconds"] as? Double) ?? 30
            var disabled: Set<String> = []
            if let list = dictionary["disabledRemoteToolNames"] as? [String] {
                guard list.count <= 512 else {
                    throw ConfigDomainError(code: .payloadTooLarge, reason: "mcpDisabledToolNames")
                }
                disabled = Set(list.map { String($0.prefix(128)) })
            }
            let createIntent = (dictionary["createIntent"] as? Bool) ?? false
            return MCPSaveCandidate(id: id, displayName: displayName, endpoint: endpoint,
                                    enabled: enabled, allowInCanvas: allowInCanvas,
                                    allowInsecureHTTP: allowInsecureHTTP,
                                    authentication: authentication,
                                    credentialHeaderName: headerName,
                                    timeoutSeconds: timeout,
                                    disabledRemoteToolNames: disabled,
                                    createIntent: createIntent)
        }

        func makeConfiguration() -> MCPServerConfiguration {
            MCPServerConfiguration(id: id, displayName: displayName, endpoint: endpoint,
                                   enabled: enabled, allowInCanvas: allowInCanvas,
                                   allowInsecureHTTP: allowInsecureHTTP,
                                   authentication: authentication,
                                   credentialHeaderName: credentialHeaderName,
                                   timeoutSeconds: timeoutSeconds,
                                   disabledRemoteToolNames: disabledRemoteToolNames)
        }
    }

    // MARK: Set (lease-bound single hop)

    /// ⇄ saveMcpServer Set. The lease is NON-Sendable: consume→use→close
    /// all happen inside this actor-isolated hop (RB2 saveProviderSet
    /// chain, adapted to SubjectKind.mcpSave). One-shot: a spent/expired/
    /// route-mismatch token is typed and NEVER replayed; lease bytes are
    /// never copied outside the save effect (zeroized in performSave).
    public func saveSet(ingressToken: String, envelopeRevision: ConfigRevision?) async
        -> sending [String: Any] {
        let binding: FacadeRootGeneration
        do { binding = try requireBinding() } catch { return Self.rejection(error) }
        try? await loadServers()
        guard let route = routeContext.currentRoute() else {
            return Self.rejection(MCPDomainRefusal.needsRouteContext)
        }
        let lease: SaveIntentLease
        do {
            lease = try SecretSaveIntentVault.shared.consume(token: ingressToken,
                                                             route: route,
                                                             expectedSubject: .mcpSave)
        } catch {
            return Self.rejection(SaveIntentConsumption.mapRejection(error))
        }
        let outcome = await performSave(candidateData: lease.candidateJSON,
                                        secretIntent: "set",
                                        leaseSecret: lease.secret,
                                        leaseBaseRevision: lease.baseRevision,
                                        envelopeRevision: envelopeRevision,
                                        binding: binding)
        var reply = outcome
        if !lease.close() {
            // Vault fail-closed: the admission stays recorded against the
            // cap. Diagnostic flag only — never a secret, never retried by
            // this package (RB2 parity).
            reply["leaseAdmissionCloseFailed"] = true
        }
        return reply
    }

    // MARK: Keep / Clear (envelope-bound; no secret bytes)

    /// Keep: same draft, existing account preserved (the ORIGINAL account
    /// rule re-derives from the endpoint; an endpoint edit under Keep would
    /// bind a NEW account with NO secret — refused typed, because the
    /// original "enter new credentials to replace…" gate means Keep is
    /// only valid while the connection identity is unchanged).
    /// Clear: the honest auth-mode change to `.none` (original: .none
    /// deletes the account); an auth-required candidate may not clear into
    /// a secret-less server (that would fabricate anonymous authority).
    public func save(candidateJSON: Data?, secretIntent: String,
                     envelopeRevision: ConfigRevision?) async -> sending [String: Any] {
        let binding: FacadeRootGeneration
        do { binding = try requireBinding() } catch { return Self.rejection(error) }
        try? await loadServers()
        guard secretIntent == "keep" || secretIntent == "clear" else {
            return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                    reason: "mcpIntentRouting"))
        }
        guard let candidateJSON, !candidateJSON.isEmpty else {
            return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                    reason: "mcpCandidateMissing"))
        }
        return await performSave(candidateData: candidateJSON,
                                 secretIntent: secretIntent,
                                 leaseSecret: nil,
                                 leaseBaseRevision: nil,
                                 envelopeRevision: envelopeRevision,
                                 binding: binding)
    }

    private func performSave(candidateData: Data,
                             secretIntent: String,
                             leaseSecret: Data?,
                             leaseBaseRevision: SaveIntentBaseRevision?,
                             envelopeRevision: ConfigRevision?,
                             binding: FacadeRootGeneration) async -> sending [String: Any] {
        do {
            guard candidateData.count <= 16_384 else {
                return Self.rejection(ConfigDomainError(code: .payloadTooLarge,
                                                        reason: "mcpCandidateSize"))
            }
            let dictionary = try ConfigJSON.object(from: candidateData)
            let candidate = try MCPSaveCandidate.parse(dictionary)
            return await performValidatedSave(candidate: candidate,
                                              secretIntent: secretIntent,
                                              leaseSecret: leaseSecret,
                                              leaseBaseRevision: leaseBaseRevision,
                                              envelopeRevision: envelopeRevision,
                                              binding: binding)
        } catch let error as ConfigDomainError {
            return Self.rejection(error)
        } catch {
            return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                    reason: "mcpCandidateParse"))
        }
    }

    private func performValidatedSave(candidate: MCPSaveCandidate,
                                      secretIntent: String,
                                      leaseSecret: Data?,
                                      leaseBaseRevision: SaveIntentBaseRevision?,
                                      envelopeRevision: ConfigRevision?,
                                      binding: FacadeRootGeneration) async -> sending [String: Any] {
        let configuration = candidate.makeConfiguration()
        // ORIGINAL validate() BEFORE any durable/secret effect.
        do { try configuration.validate() } catch {
            return Self.rejection(Self.mapConfigurationValidation(error))
        }
        let existingIndex = servers.firstIndex { $0.id == candidate.id }
        let existing = existingIndex.map { servers[$0] }
        let currentHash = existing.map { MCPServerConfigHash.digest(of: $0) }
        // Identity/creation gates (frozen matrix semantics).
        switch (existing != nil, candidate.createIntent) {
        case (true, true):
            return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                    reason: "mcpCreateConflict"))
        case (false, false):
            return Self.rejection(ConfigDomainError(code: .notFound,
                                                    reason: "mcpServerMissing"))
        case (false, true):
            guard secretIntent == "set" else {
                // New identity creation is legitimate ONLY as the Set lease
                // (candidate + secret frozen together at the save tap).
                return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                        reason: "mcpCreateNeedsSet"))
            }
        case (true, false):
            break
        }
        // Lease base revision (RB2 providerLeaseBaseRevision parity): the
        // frozen save-tap binding must match the CURRENT row; "0" is the
        // expected-absent marker for create.
        if let leaseBaseRevision {
            let expectedResource = MCPServerConfigHash.resourceID(serverID: candidate.id)
            guard leaseBaseRevision.resourceID == expectedResource else {
                return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                        reason: "mcpLeaseBaseResource"))
            }
            if let currentHash {
                guard leaseBaseRevision.version == currentHash else {
                    return Self.rejection(ConfigDomainError(code: .staleRevision,
                                                            reason: "mcpLeaseBaseRevision"))
                }
            } else if leaseBaseRevision.version != "0" {
                return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                        reason: "mcpCreateBaseRevisionDivergence"))
            }
        }
        // Envelope revision CAS for existing rows.
        if let existing, let envelopeRevision {
            guard envelopeRevision.resourceID == MCPServerConfigHash.resourceID(serverID: existing.id),
                  envelopeRevision.version == currentHash else {
                return Self.rejection(ConfigDomainError(code: .staleRevision,
                                                        reason: "mcpEnvelopeRevision"))
            }
        } else if existing != nil, envelopeRevision == nil {
            return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                    reason: "mcpRevisionMissing"))
        }
        // Keep may not silently re-bind a NEW account: an endpoint/auth
        // change under Keep would point at an account with no secret (the
        // original UI requires new credentials in that case).
        if secretIntent == "keep", let existing {
            let oldAccount = MCPCredentialIdentity.account(for: existing)
            let newAccount = MCPCredentialIdentity.account(for: configuration)
            // Keep preserves the EXISTING credential: the full connection
            // identity must be unchanged (endpoint, auth mode and header
            // name). A rename-only edit is fine; any connection edit binds
            // new authority and must come as Set (or Clear→Set), because a
            // Keep would otherwise point the row at a different endpoint
            // while silently retaining the old secret.
            let sameConnection = existing.endpoint == configuration.endpoint
                && existing.authentication == configuration.authentication
                && existing.credentialHeaderName == configuration.credentialHeaderName
                && existing.allowInsecureHTTP == configuration.allowInsecureHTTP
            if oldAccount != newAccount || !sameConnection {
                return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                        reason: "mcpKeepConnectionChangedNeedsSet"))
            }
        }

        let oldAccount = existing.flatMap(MCPCredentialIdentity.account(for:))
        var newAccount: String?
        if secretIntent == "set" {
            guard gateway.isRegistered else {
                return Self.rejection(MCPDomainRefusal.gatewayUnregistered)
            }
            guard configuration.authentication != .none else {
                return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                        reason: "mcpSecretForNoAuthMode"))
            }
            guard let leaseSecret, !leaseSecret.isEmpty,
                  let text = String(data: leaseSecret, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= MCPRemoteClient.maximumCredentialBytes,
                  !text.contains(where: { $0 == "\r" || $0 == "\n" }),
                  let account = MCPCredentialIdentity.account(for: configuration) else {
                return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                        reason: "mcpSecretBounds"))
            }
            newAccount = account
        }
        if secretIntent == "clear" {
            guard configuration.authentication == .none else {
                return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                        reason: "mcpClearRequiresNoneAuth"))
            }
        }

        // CAP-COMPILE-1: real scoped awaited ownership. The bounded
        // tool-work worker is registered BEFORE the first effect and retired
        // only AFTER the awaited save effects have settled; the awaited
        // `end` replaces the parent's illegal synchronous `defer`.
        let worker: FacadeOwnedWorker
        switch await toolWork.begin(ownerID: "mcp-save:\(candidate.id.uuidString)",
                                    runID: nil, callID: nil, epoch: binding.epoch) {
        case .failure(.noAdmittedEpoch):
            return Self.rejection(MCPDomainRefusal.runtimeNotReady)
        case .failure(.ownerAlreadyActive):
            return Self.rejection(ConfigDomainError(code: .duplicateInFlight,
                                                    reason: "mcpOperationActive"))
        case .failure(.saturated):
            return Self.rejection(ConfigDomainError(code: .mailboxSaturated,
                                                    reason: "mcpLedgerSaturated"))
        case .success(let started):
            worker = started
        }
        // CAP-SECRET-2: the SAME per-server owner the cleanup drain/remove
        // use. Taken BEFORE the durable intent and any secret/row effect.
        let ticket: ProviderOperationTicket
        switch await beginServerSecretOperation(.save, serverID: candidate.id) {
        case .success(let attached):
            ticket = attached
        case .failure(let failure):
            await toolWork.end(worker.id)
            return failure.reply
        }
        let lease: ConfigOwnedWorkLease
        switch attachSecretOwnership(serverID: candidate.id) {
        case .success(let attached):
            lease = attached
        case .failure(let failure):
            await ownership.endOperation(ticket)
            await toolWork.end(worker.id)
            return failure.reply
        }
        let effect = await runSaveEffects(
            candidate: candidate, configuration: configuration,
            existing: existing, currentHash: currentHash,
            secretIntent: secretIntent, leaseSecret: leaseSecret,
            oldAccount: oldAccount, newAccount: newAccount,
            binding: binding)
        await toolWork.end(worker.id)
        if effect.requiresRetention {
            // MC-R4/CAP-SECRET-2: an unsettled individual physical lifetime
            // parks the EXACT ticket + retained RB1 lease + receipt + the
            // exact attempt witness. Nothing is detached or claimed; the
            // reconciler settles only on real physical truth.
            let parked = await ownership.parkPending(
                ticket,
                intent: secretIntent == "set" ? .secretWrite : .secretClear,
                receipt: effect.receipt,
                lease: lease,
                witness: effect.witness)
            var reply = effect.reply
            reply["pendingPhysicalSettlement"] = true
            reply["physicalOwnerParked"] = parked
            return reply
        }
        ownedWork.settle(lease)
        await ownership.endOperation(ticket)
        guard effect.rowCommitted else { return effect.reply }

        // ── Connection effect (upsert→refresh when enabled; original
        // :445-454). A save NEVER claims a connected state: connect runs
        // through its own fenced worker with an honest terminal.
        var connectResult: [String: Any]
        if configuration.enabled {
            connectResult = await connectInternal(serverID: candidate.id,
                                                  binding: binding, force: true)
        } else {
            await disconnectInternal(serverID: candidate.id, binding: binding)
            connectResult = ["connection": MCPServerStateProjection.inactive.wireObject]
        }
        var reply = effect.reply
        reply["revision"] = ["resourceID": MCPServerConfigHash.resourceID(serverID: candidate.id),
                             "version": MCPServerConfigHash.digest(of: configuration)]
        reply["connect"] = connectResult
        if let disposition = effect.disposition {
            reply["secretDisposition"] = Self.dispositionString(disposition)
        }
        return reply
    }

    /// Result of the awaited save effects. `requiresRetention` is true only
    /// when the INDIVIDUAL physical truth for THIS attempt is not terminal
    /// (claimed/queued receipt, or an unobservable ambiguous effect); the
    /// caller then parks the exact ticket/lease/receipt/witness instead of
    /// detaching.
    private struct SaveEffectOutcome {
        let reply: [String: Any]
        let rowCommitted: Bool
        let requiresRetention: Bool
        let receipt: PhysicalOperationReceipt?
        let witness: (any PhysicalObservingSecretGateway)?
        let disposition: SecretEffectDisposition?
        let cleanup: String?
    }

    /// All secret/row effects of ONE validated save. Runs ONLY while the
    /// caller holds the server's operation reservation + RB1 lease
    /// (CAP-SECRET-2). Every early exit returns an honest typed reply; the
    /// worker/lease/ticket lifecycle is owned by `performValidatedSave`.
    private func runSaveEffects(candidate: MCPSaveCandidate,
                                configuration: MCPServerConfiguration,
                                existing: MCPServerConfiguration?,
                                currentHash: String?,
                                secretIntent: String,
                                leaseSecret: Data?,
                                oldAccount: String?,
                                newAccount: String?,
                                binding: FacadeRootGeneration) async -> sending SaveEffectOutcome {
        // Enqueue durable cleanup intents BEFORE the first destructive
        // effect (original ordering; unknown outcomes KEEP them). A corrupt
        // ledger refuses the save instead of being overwritten.
        if secretIntent == "set", let oldAccount, oldAccount != newAccount {
            do {
                try await MCPSecretCleanupLedger.enqueue(
                    .init(serverID: candidate.id, account: oldAccount,
                          kind: .accountReplace),
                    in: database)
            } catch {
                if let domain = error as? ConfigDomainError {
                    return Self.saveEffectFailure(domain)
                }
                return Self.saveEffectFailure(
                    ConfigDomainError(code: .persistenceUnavailable,
                                      reason: "cleanupLedgerWrite"))
            }
        }
        if secretIntent == "clear", let oldAccount {
            do {
                try await MCPSecretCleanupLedger.enqueue(
                    .init(serverID: candidate.id, account: oldAccount,
                          kind: .accountReplace),
                    in: database)
            } catch {
                if let domain = error as? ConfigDomainError {
                    return Self.saveEffectFailure(domain)
                }
                return Self.saveEffectFailure(
                    ConfigDomainError(code: .persistenceUnavailable,
                                      reason: "cleanupLedgerWrite"))
            }
        }
        var secretDisposition: SecretEffectDisposition?
        var retentionReceipt: PhysicalOperationReceipt?
        var retentionWitness: (any PhysicalObservingSecretGateway)?
        // Secret write under the canonical reference (bytes are owned here
        // only; zeroized before returning).
        if secretIntent == "set", let leaseSecret, let newAccount {
            let reference = MCPCredentialIdentity.opaqueReference(account: newAccount)
            var owned = leaseSecret
            defer {
                if !owned.isEmpty { owned.resetBytes(in: 0..<owned.count) }
            }
            let attempt = await MCPPhysicalSecretAttempt.perform(
                kind: .write, reference: reference, value: owned, gateway: gateway)
            switch attempt.assessment.disposition {
            case .committed:
                break
            case .effectAbsent, .outcomeUnknown:
                return SaveEffectOutcome(
                    reply: Self.saveFailed(attempt.assessment.disposition,
                                           databaseRowWritten: false),
                    rowCommitted: false,
                    requiresRetention: attempt.requiresOwnerRetention,
                    receipt: attempt.receipt,
                    witness: attempt.witness,
                    disposition: attempt.assessment.disposition,
                    cleanup: nil)
            }
            do {
                guard let readBack = try await gateway.read(reference: reference) else {
                    return Self.saveEffectFailure(.outcomeUnknown(reason: "readbackMissing"))
                }
                guard readBack == owned else {
                    // Row+secret partial state stays honest: the mismatch is
                    // NEVER converted into a no-effect claim.
                    return Self.saveEffectFailure(.outcomeUnknown(reason: "readbackMismatch"))
                }
            } catch {
                return Self.saveEffectFailure(
                    SecretDispositionClassifier.classify(error: error, published: true))
            }
            secretDisposition = .committed
        }
        // ── Config row commit: ONE atomic targeted mutation ─────────────
        // Fresh persisted array + target revision CAS inside one writer
        // transaction; sibling rows from another facade are preserved.
        do {
            let committed = try await mutateServers(
                .upsert(configuration,
                        expectedHash: existing == nil ? nil : currentHash))
            servers = committed
            loaded = true
        } catch let error as ConfigDomainError {
            if secretDisposition == .committed {
                // The secret is really committed but the row is not: the
                // caller must see that partial state, not a plain refusal.
                return Self.saveEffectFailure(.committed)
            }
            return Self.saveEffectFailure(error)
        } catch {
            if secretDisposition == .committed {
                return Self.saveEffectFailure(.committed)
            }
            return Self.saveEffectFailure(
                ConfigDomainError(code: .persistenceUnavailable, reason: "mcpRowWrite"))
        }
        // Post-commit bounded old-account cleanup under the SAME held owner.
        // Unknown KEEPS the durable intent; only a committed delete settles.
        var cleanup = "none"
        if secretIntent == "set", let oldAccount, oldAccount != newAccount {
            let outcome = await finalizeCleanup(serverID: candidate.id, account: oldAccount)
            cleanup = outcome.report
            if outcome.kind == .pending {
                retentionReceipt = outcome.receipt
                retentionWitness = outcome.witness
            }
        }
        if secretIntent == "clear", let oldAccount {
            let outcome = await finalizeCleanup(serverID: candidate.id, account: oldAccount)
            cleanup = outcome.report
            if outcome.kind == .pending {
                retentionReceipt = outcome.receipt
                retentionWitness = outcome.witness
            }
        }
        var reply: [String: Any] = [
            "state": "committed",
            "serverID": candidate.id.uuidString,
            "secretIntent": secretIntent,
        ]
        if cleanup != "none" { reply["credentialCleanup"] = cleanup }
        return SaveEffectOutcome(
            reply: reply,
            rowCommitted: true,
            requiresRetention: retentionReceipt != nil || retentionWitness != nil,
            receipt: retentionReceipt,
            witness: retentionWitness,
            disposition: secretDisposition,
            cleanup: cleanup)
    }

    /// Honest failure reply with no retention (or with a rethrown typed
    /// error when the failure happened before any secret effect).
    private static func saveEffectFailure(_ error: ConfigDomainError,
                                          disposition: SecretEffectDisposition? = nil)
        -> sending SaveEffectOutcome
    {
        SaveEffectOutcome(reply: rejection(error), rowCommitted: false,
                          requiresRetention: false, receipt: nil, witness: nil,
                          disposition: disposition, cleanup: nil)
    }

    private static func saveEffectFailure(_ disposition: SecretEffectDisposition,
                                          databaseRowWritten: Bool = false)
        -> sending SaveEffectOutcome
    {
        SaveEffectOutcome(reply: saveFailed(disposition,
                                            databaseRowWritten: databaseRowWritten),
                          rowCommitted: false, requiresRetention: false,
                          receipt: nil, witness: nil,
                          disposition: disposition, cleanup: nil)
    }


    // MARK: mcp.connect — connect/refresh/setEnabled/setToolEnabled

    public func connect(serverID: UUID) async -> sending [String: Any] {
        let binding: FacadeRootGeneration
        do { binding = try requireBinding() } catch { return Self.rejection(error) }
        do { try await loadServers() } catch { return Self.rejection(error) }
        return await connectInternal(serverID: serverID, binding: binding, force: false)
    }

    /// ⇄ MCPSettingsCenter.refresh(serverID:) (:503-540): NEW client per
    /// attempt, monotonic generation fence, credential BEFORE dispatch,
    /// config-equality + generation re-check at completion, ORIGINAL
    /// replace-by-prefix registration, previous client disconnected, error
    /// retained honestly (config/draft untouched).
    private func connectInternal(serverID: UUID, binding: FacadeRootGeneration,
                                 force: Bool) async -> sending [String: Any] {
        guard transportAdmission.admitsMCPNetwork else {
            return Self.rejection(MCPDomainRefusal.transportClosed)
        }
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return Self.rejection(ConfigDomainError(code: .notFound, reason: "mcpServerMissing"))
        }
        if !server.enabled && !force {
            return Self.rejection(ConfigDomainError(code: .needsConfiguration,
                                                    reason: "mcpServerDisabled"))
        }
        // Typed credential resolution BEFORE any client/network effect.
        let credential: String?
        switch await resolveCredential(for: server) {
        case .resolved(let value):
            credential = value
        case .unavailable(let availability):
            let hash = MCPServerConfigHash.digest(of: server)
            var connection = connections[serverID] ?? MCPServerConnection()
            connection.state = .failed(reason: availability.rawValue, revision: hash)
            connections[serverID] = connection
            return Self.rejection(ConfigDomainError(code: .credentialUnavailable,
                                                    reason: availability.rawValue))
        }
        let hash = MCPServerConfigHash.digest(of: server)
        // beginRefresh parity (SkillsView:584-588): monotonic `&+ 1`, never
        // reset, never decremented (a failed registration must not rewind).
        var connection = connections[serverID] ?? MCPServerConnection()
        connection.generation &+= 1
        let generation = connection.generation
        connection.state = .connecting(generation: generation)
        connection.boundConfigHash = hash
        connections[serverID] = connection
        let previousClient = connection.client
        let remote: MCPRemoteClient
        do {
            remote = try clientFactory.make(configuration: server, credential: credential)
        } catch {
            var failed = connections[serverID] ?? connection
            failed.state = .failed(reason: Self.safeReason(error), revision: hash)
            connections[serverID] = failed
            await previousClient?.disconnect()
            return Self.rejection(Self.mapConfigurationValidation(error))
        }
        let ownerID = FacadeToolWorkCoordinator.mcpRefreshOwnerID(serverID,
                                                                  generation: generation)
        let worker: FacadeOwnedWorker
        switch await toolWork.begin(ownerID: ownerID, runID: nil, callID: nil,
                                    epoch: binding.epoch) {
        case .success(let started):
            worker = started
        case .failure:
            await remote.disconnect()
            var failed = connections[serverID] ?? connection
            failed.state = .failed(reason: "refreshAlreadyActive", revision: hash)
            connections[serverID] = failed
            return Self.rejection(ConfigDomainError(code: .duplicateInFlight,
                                                    reason: "mcpRefreshAlreadyActive"))
        }
        // CAP-COMPILE-1: the worker ends only after the awaited discovery
        // + registration/failure settlement (no synchronous actor defer).
        let reply = await runRefresh(serverID: serverID, server: server,
                                     remote: remote, previousClient: previousClient,
                                     connection: connection, generation: generation,
                                     hash: hash)
        await toolWork.end(worker.id)
        return reply
    }

    /// The awaited refresh body, called only while the refresh worker is
    /// registered. Every early exit has already settled the client state.
    private func runRefresh(serverID: UUID, server: MCPServerConfiguration,
                            remote: MCPRemoteClient,
                            previousClient: MCPRemoteClient?,
                            connection: MCPServerConnection,
                            generation: UInt64, hash: String) async -> sending [String: Any] {
        let discovered: [MCPDiscoveredTool]
        do {
            discovered = try await remote.discoverTools()
        } catch {
            // Failure path mirrors the original :528-536: unregister tools,
            // drop the client entry, disconnect BOTH the new and previous
            // client (no half-open session survives), retain the typed
            // error; the saved config/draft is untouched (retry keeps it).
            MCPRemoteToolSource.unregister(configuration: server, registry: registry)
            await remote.disconnect()
            await previousClient?.disconnect()
            let reason = Self.safeReason(error)
            var failed = connections[serverID] ?? connection
            failed.state = .failed(reason: reason, revision: hash)
            failed.client = nil
            failed.tools = []
            connections[serverID] = failed
            return Self.rejection(ConfigDomainError(code: Self.wireCode(forMCP: error),
                                                    reason: reason))
        }
        // Staleness re-check exactly like the original :514-520: generation
        // AND config equality at completion. A late result from a closed or
        // superseded connection can NEVER restore/registrate.
        guard let current = connections[serverID], current.generation == generation,
              let live = servers.first(where: { $0.id == serverID }),
              MCPServerConfigHash.digest(of: live) == hash else {
            await remote.disconnect()
            return Self.rejection(ConfigDomainError(code: .runtimeUnavailable,
                                                    reason: "mcpRefreshSuperseded"))
        }
        let tools = Array(discovered.prefix(SkillsMcpLimits.maximumMcpToolsPerServer))
        MCPRemoteToolSource.register(configuration: live, client: remote,
                                     tools: tools, registry: registry)
        if let previousClient, !(previousClient === remote) {
            await previousClient.disconnect()
        }
        var ready = connections[serverID] ?? connection
        ready.client = remote
        ready.tools = tools
        ready.state = .ready(toolCount: tools.count, revision: hash)
        connections[serverID] = ready
        let enabledNames = tools
            .filter { !live.disabledRemoteToolNames.contains($0.remoteName) }
            .map { MCPRemoteToolSource.namespacedName(prefix: live.namespacePrefix + "_",
                                                      remoteName: $0.remoteName) }
        return ["state": "connected", "serverID": serverID.uuidString,
                "generation": String(generation),
                "toolCount": tools.count,
                "enabledToolCount": enabledNames.count,
                "revision": ["resourceID": MCPServerConfigHash.resourceID(serverID: serverID),
                             "version": hash]]
    }

    /// enabled.set ⇄ setEnabled (:457-472): disable = invalidateRefresh +
    /// unregister + disconnect + inactive + empty tools; enable triggers a
    /// real refresh (typed when the admission gate is closed).
    public func setEnabled(serverID: UUID, enabled: Bool, revision: ConfigRevision) async
        -> sending [String: Any] {
        let binding: FacadeRootGeneration
        do { binding = try requireBinding() } catch { return Self.rejection(error) }
        do { try await loadServers() } catch { return Self.rejection(error) }
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            return Self.rejection(ConfigDomainError(code: .notFound, reason: "mcpServerMissing"))
        }
        guard revision.resourceID == MCPServerConfigHash.resourceID(serverID: serverID),
              revision.version == MCPServerConfigHash.digest(of: servers[index]) else {
            return Self.rejection(ConfigDomainError(code: .staleRevision, reason: "mcpCAS"))
        }
        let currentDigest = MCPServerConfigHash.digest(of: servers[index])
        do {
            let committed = try await mutateServers(
                .setEnabled(serverID: serverID, expectedHash: currentDigest,
                            enabled: enabled))
            servers = committed
            loaded = true
        } catch let error as ConfigDomainError {
            return Self.rejection(error)
        } catch {
            return Self.rejection(ConfigDomainError(code: .persistenceUnavailable,
                                                    reason: "mcpRowWrite"))
        }
        if !enabled {
            await disconnectInternal(serverID: serverID, binding: binding)
            return ["state": "disabled", "serverID": serverID.uuidString,
                    "connection": MCPServerStateProjection.inactive.wireObject]
        }
        let connect = await connectInternal(serverID: serverID, binding: binding, force: true)
        return ["state": "enabled", "serverID": serverID.uuidString, "connect": connect]
    }

    /// tool.enabled.set ⇄ setToolEnabled (:474-486): persist the toggle and
    /// RE-REGISTER with the existing client — no reconnect, no discovery
    /// claim, no secret effect.
    public func setToolEnabled(serverID: UUID, remoteName: String, enabled: Bool,
                               revision: ConfigRevision) async -> sending [String: Any] {
        _ = try? requireBinding()
        do { try await loadServers() } catch { return Self.rejection(error) }
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            return Self.rejection(ConfigDomainError(code: .notFound, reason: "mcpServerMissing"))
        }
        guard revision.resourceID == MCPServerConfigHash.resourceID(serverID: serverID),
              revision.version == MCPServerConfigHash.digest(of: servers[index]) else {
            return Self.rejection(ConfigDomainError(code: .staleRevision, reason: "mcpCAS"))
        }
        guard !remoteName.isEmpty, remoteName.utf8.count <= 128 else {
            return Self.rejection(ConfigDomainError(code: .invalidEnvelope,
                                                    reason: "mcpToolNameShape"))
        }
        let currentDigest = MCPServerConfigHash.digest(of: servers[index])
        let committedServer: MCPServerConfiguration
        do {
            let committed = try await mutateServers(
                .setTool(serverID: serverID, expectedHash: currentDigest,
                         remoteName: remoteName, enabled: enabled))
            servers = committed
            loaded = true
            committedServer = committed[index]
        } catch let error as ConfigDomainError {
            return Self.rejection(error)
        } catch {
            return Self.rejection(ConfigDomainError(code: .persistenceUnavailable,
                                                    reason: "mcpRowWrite"))
        }
        if let connection = connections[serverID], let client = connection.client {
            MCPRemoteToolSource.register(configuration: committedServer, client: client,
                                         tools: connection.tools, registry: registry)
        }
        return ["state": "applied", "serverID": serverID.uuidString,
                "remoteName": remoteName, "enabled": enabled]
    }

    // MARK: mcp.disconnect — disconnect / cancelRefresh / remove

    public func disconnect(serverID: UUID, revision: ConfigRevision) async -> sending [String: Any] {
        let binding: FacadeRootGeneration
        do { binding = try requireBinding() } catch { return Self.rejection(error) }
        do { try await loadServers() } catch { return Self.rejection(error) }
        guard let server = servers.first(where: { $0.id == serverID }) else {
            return Self.rejection(ConfigDomainError(code: .notFound, reason: "mcpServerMissing"))
        }
        guard revision.resourceID == MCPServerConfigHash.resourceID(serverID: serverID),
              revision.version == MCPServerConfigHash.digest(of: server) else {
            return Self.rejection(ConfigDomainError(code: .staleRevision, reason: "mcpCAS"))
        }
        await disconnectInternal(serverID: serverID, binding: binding)
        return ["state": "disconnected", "serverID": serverID.uuidString,
                "connection": MCPServerStateProjection.inactive.wireObject]
    }

    private func disconnectInternal(serverID: UUID, binding: FacadeRootGeneration,
                                    configuration: MCPServerConfiguration? = nil) async {
        guard var connection = connections[serverID] else { return }
        connection.generation &+= 1                       // invalidateRefresh
        let previous = connection.client
        connection.client = nil
        connection.tools = []
        connection.state = .inactive
        connections[serverID] = connection
        // A remove passes the already-deleted row so its registered tools
        // are still unregistered (the live array no longer contains it).
        if let server = configuration ?? servers.first(where: { $0.id == serverID }) {
            MCPRemoteToolSource.unregister(configuration: server, registry: registry)
        }
        // Cancel ONLY this server's refresh workers under the CURRENT epoch
        // (scoped; other servers' connections are untouched).
        _ = await toolWork.cancelWorkers(ownerPrefix: "mcp-refresh:\(serverID.uuidString):",
                                         epoch: binding.epoch)
        await previous?.disconnect()
    }

    /// cancelRefresh ⇄ the binding-map mcpRefresh fence: generation EXACTLY
    /// as projected; superseded generations answer honest "noop" (the UI
    /// latch clears on the newer terminal). The worker's completion re-check
    /// makes any late discovery unregistrable (generation + client
    /// disconnect inside the ORIGINAL actor).
    public func cancelRefresh(serverID: UUID, generation: String) async -> sending [String: Any] {
        let binding: FacadeRootGeneration
        do { binding = try requireBinding() } catch { return Self.rejection(error) }
        guard let parsed = UInt64(generation),
              let connection = connections[serverID],
              connection.generation == parsed,
              case .connecting = connection.state else {
            return ["state": "noop", "serverID": serverID.uuidString,
                    "reason": "generationNotLive"]
        }
        let ownerID = FacadeToolWorkCoordinator.mcpRefreshOwnerID(serverID,
                                                                  generation: parsed)
        let cancelled = await toolWork.cancelWorkers(ownerPrefix: ownerID, epoch: binding.epoch)
        // The refresh worker cooperatively ends; then tear the connection
        // track down through the same real path as disconnectInternal for
        // THIS generation only (a newer generation is untouched).
        if cancelled.isEmpty {
            return ["state": "noop", "serverID": serverID.uuidString,
                    "reason": "workerAlreadySettling"]
        }
        await disconnectInternal(serverID: serverID, binding: binding)
        return ["state": "cancelling", "serverID": serverID.uuidString,
                "generation": generation]
    }

    /// remove ⇄ MCPSettingsCenter.remove (:488-501): invalidate + unregister
    /// + disconnect + config row delete + bound credential delete (and the
    /// legacy bare account) through the durable cleanup ordering. A failed
    /// row delete keeps the server saved (never half-removed); the secret
    /// cleanup intent stays durable until settlement truth.
    public func remove(serverID: UUID, revision: ConfigRevision) async -> sending [String: Any] {
        let binding: FacadeRootGeneration
        do { binding = try requireBinding() } catch { return Self.rejection(error) }
        do { try await loadServers() } catch { return Self.rejection(error) }
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else {
            return Self.rejection(ConfigDomainError(code: .notFound, reason: "mcpServerMissing"))
        }
        let server = servers[index]
        guard revision.resourceID == MCPServerConfigHash.resourceID(serverID: serverID),
              revision.version == MCPServerConfigHash.digest(of: server) else {
            return Self.rejection(ConfigDomainError(code: .staleRevision, reason: "mcpCAS"))
        }
        let account = MCPCredentialIdentity.account(for: server)
        let legacy = MCPCredentialIdentity.legacyAccount(serverID: serverID)
        // CAP-SECRET-2: the remove chain (enqueue -> row delete -> secret
        // delete) runs under the SAME per-server owner + RB1 lease a save
        // would need, so a concurrent Set cannot interleave after the
        // newest-row check.
        let ticket: ProviderOperationTicket
        switch await beginServerSecretOperation(.delete, serverID: serverID) {
        case .success(let attached):
            ticket = attached
        case .failure(let failure):
            return failure.reply
        }
        let lease: ConfigOwnedWorkLease
        switch attachSecretOwnership(serverID: serverID) {
        case .success(let attached):
            lease = attached
        case .failure(let failure):
            await ownership.endOperation(ticket)
            return failure.reply
        }
        // Enqueue BEFORE any destructive effect (original ordering; CV-R2
        // compare-and-delete finalization). A corrupt ledger refuses.
        do {
            if let account {
                try await enqueueCleanup(.init(serverID: serverID, account: account,
                                               kind: .serverRemove))
            }
            try await enqueueCleanup(.init(serverID: serverID, account: legacy,
                                           kind: .serverRemove))
        } catch {
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            if let domain = error as? ConfigDomainError {
                return Self.rejection(domain)
            }
            return Self.rejection(ConfigDomainError(code: .persistenceUnavailable,
                                                    reason: "cleanupLedgerWrite"))
        }
        // ONE atomic targeted removal of the CURRENT row (target revision
        // CAS, siblings preserved); the connection is torn down only after
        // the committed row delete.
        do {
            let committed = try await mutateServers(
                .remove(serverID: serverID,
                        expectedHash: MCPServerConfigHash.digest(of: server)))
            servers = committed
            loaded = true
        } catch let error as ConfigDomainError {
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return Self.rejection(error)
        } catch {
            ownedWork.settle(lease)
            await ownership.endOperation(ticket)
            return Self.rejection(ConfigDomainError(code: .persistenceUnavailable,
                                                    reason: "mcpRowDelete"))
        }
        // Tear the live connection down WITH the removed configuration so
        // its namespaced tools are unregistered (the live array no longer
        // holds it), then drop the connection entry.
        await disconnectInternal(serverID: serverID, binding: binding,
                                 configuration: server)
        connections[serverID] = nil
        // Compare-and-delete under the HELD owner: the live-row check now
        // sees the removed row (absent), and no newer Set can interleave.
        var pendingReceipt: PhysicalOperationReceipt?
        var pendingWitness: (any PhysicalObservingSecretGateway)?
        if let account {
            let outcome = await finalizeCleanup(serverID: serverID, account: account)
            if outcome.kind == .pending {
                pendingReceipt = outcome.receipt
                pendingWitness = outcome.witness
            }
        }
        // Exactly ONE outstanding physical lifetime per server may be parked.
        // If the first delete is still outstanding, the legacy intent is left
        // for the bounded drain (which also reconciles this owner first).
        if pendingReceipt == nil && pendingWitness == nil {
            let legacyOutcome = await finalizeCleanup(serverID: serverID, account: legacy)
            if legacyOutcome.kind == .pending {
                pendingReceipt = legacyOutcome.receipt
                pendingWitness = legacyOutcome.witness
            }
        }
        if pendingReceipt != nil || pendingWitness != nil {
            let parked = await ownership.parkPending(
                ticket, intent: .providerDelete,
                receipt: pendingReceipt, lease: lease, witness: pendingWitness)
            let stillPending = await cleanupIntentExists(serverID: serverID)
            return ["state": "removed", "serverID": serverID.uuidString,
                    "credentialCleanup": stillPending ? "queuedForRetry" : "settled",
                    "pendingPhysicalSettlement": true,
                    "physicalOwnerParked": parked]
        }
        ownedWork.settle(lease)
        await ownership.endOperation(ticket)
        let stillPending = await cleanupIntentExists(serverID: serverID)
        return ["state": "removed", "serverID": serverID.uuidString,
                "credentialCleanup": stillPending ? "queuedForRetry" : "settled"]
    }

    // MARK: activate (bootstrap one-shot; host-gated placement)

    /// ⇄ activate(force:) (:410-419). Main wires the CALL site into the RB1
    /// bootstrap order (after the owned store is ready and the credential
    /// deletion drains); this method performs ONE refresh pass per enabled
    /// server and returns typed per-server outcomes (no partial-success
    /// claim, no network here unless the admission gate is open).
    public func activateEnabledServers() async -> sending [[String: Any]] {
        var outcomes: [[String: Any]] = []
        do { try await loadServers() } catch {
            return [["state": "refused", "reason": Self.safeReason(error)]]
        }
        for server in servers where server.enabled {
            guard let binding = try? requireBinding() else {
                outcomes.append(["serverID": server.id.uuidString,
                                 "state": "refused.runtimeNotReady"])
                continue
            }
            var outcome = await connectInternal(serverID: server.id, binding: binding,
                                                force: true)
            outcome["serverID"] = server.id.uuidString
            outcomes.append(outcome)
        }
        return outcomes
    }

    /// The CURRENT durable revision pair for one server id (test/later
    /// domain use; reads the actual row through the actor's own state).
    func currentRevision(serverID: UUID) -> ConfigRevision? {
        guard let server = servers.first(where: { $0.id == serverID }) else { return nil }
        return ConfigRevision(
            resourceID: MCPServerConfigHash.resourceID(serverID: serverID),
            version: MCPServerConfigHash.digest(of: server))
    }

    // MARK: Cleanup ledger (strict, shared with the physical lifetime)

    private func enqueueCleanup(_ intent: MCPSecretCleanupIntent) async throws {
        try await MCPSecretCleanupLedger.enqueue(intent, in: database)
    }

    /// Corrupt bytes are UNKNOWN, not empty (CAP-SECRET-2): the list surface
    /// reports the pending state instead of silently dropping intents.
    private func cleanupIntentExists(serverID: UUID) async -> Bool {
        do {
            return try await MCPSecretCleanupLedger.readStrict(database)
                .contains { $0.serverID == serverID }
        } catch {
            return true
        }
    }

    /// Outcome of ONE compare-and-delete finalization under a held owner.
    private struct CleanupFinalizeOutcome {
        enum Kind: Sendable, Equatable {
            case settled        // committed delete, intent removed
            case superseded     // newest row owns the reference, no delete
            case kept           // unknown/no-effect/corrupt: intent retained
            case pending        // outstanding physical lifetime: park owner
        }
        let kind: Kind
        let reason: String
        let receipt: PhysicalOperationReceipt?
        let witness: (any PhysicalObservingSecretGateway)?
        var report: String {
            switch kind {
            case .settled, .superseded: return "settled"
            case .kept, .pending: return "queuedForRetry"
            }
        }
    }

    /// Compare-and-delete finalization (CAP-SECRET-2 + CV-R2), called ONLY
    /// while the caller holds the server's operation ticket + RB1 lease:
    /// 1. read the STRICT durable intent (corrupt => keep, no effect);
    /// 2. re-read the NEWEST persisted row through the held owner — a live
    ///    row that still references this exact account resolves the intent
    ///    WITHOUT any delete (a newer same-account Set is never destroyed);
    /// 3. delete through the per-attempt physical observer and classify from
    ///    the INDIVIDUAL truth;
    /// 4. remove the intent ONLY on a real committed delete. A pre-ticket
    ///    invalidValue/invalidReference (or never-queued) is NOT authority
    ///    that the old secret is absent.
    private func finalizeCleanup(serverID: UUID, account: String) async
        -> CleanupFinalizeOutcome
    {
        let intents: [MCPSecretCleanupIntent]
        do {
            intents = try await MCPSecretCleanupLedger.readStrict(database)
        } catch {
            return CleanupFinalizeOutcome(kind: .kept, reason: "cleanupLedgerCorrupt",
                                          receipt: nil, witness: nil)
        }
        guard intents.contains(where: { $0.serverID == serverID && $0.account == account }) else {
            return CleanupFinalizeOutcome(kind: .settled, reason: "intentAbsent",
                                          receipt: nil, witness: nil)
        }
        let live: MCPServerConfiguration?
        do {
            live = try await storedServer(id: serverID)
        } catch {
            return CleanupFinalizeOutcome(kind: .kept, reason: "liveRowUnreadable",
                                          receipt: nil, witness: nil)
        }
        if let live, MCPCredentialIdentity.account(for: live) == account {
            // Newest row (version/account) owns this exact reference. Resolve
            // the now-obsolete intent WITHOUT the destructive effect.
            do {
                try await MCPSecretCleanupLedger.remove(serverID: serverID,
                                                        account: account,
                                                        in: database)
                return CleanupFinalizeOutcome(kind: .superseded,
                                              reason: "newerRecordOwnsReference",
                                              receipt: nil, witness: nil)
            } catch {
                return CleanupFinalizeOutcome(kind: .kept,
                                              reason: "cleanupLedgerCorrupt",
                                              receipt: nil, witness: nil)
            }
        }
        guard gateway.isRegistered else {
            return CleanupFinalizeOutcome(kind: .kept, reason: "gatewayUnregistered",
                                          receipt: nil, witness: nil)
        }
        let reference = MCPCredentialIdentity.opaqueReference(account: account)
        let attempt = await MCPPhysicalSecretAttempt.perform(
            kind: .delete, reference: reference, value: nil, gateway: gateway)
        switch attempt.assessment.disposition {
        case .committed:
            do {
                try await MCPSecretCleanupLedger.remove(serverID: serverID,
                                                        account: account,
                                                        in: database)
                return CleanupFinalizeOutcome(kind: .settled, reason: "deleted",
                                              receipt: attempt.receipt,
                                              witness: attempt.witness)
            } catch {
                return CleanupFinalizeOutcome(kind: .kept,
                                              reason: "cleanupLedgerCorrupt",
                                              receipt: attempt.receipt,
                                              witness: attempt.witness)
            }
        case .effectAbsent(let reason):
            // MC-R3 parity: "no effect for THIS attempt" never proves the
            // PRE-EXISTING record absent. Keep + report the intent.
            return CleanupFinalizeOutcome(kind: .kept,
                                          reason: "effectAbsent.\(reason)",
                                          receipt: attempt.receipt,
                                          witness: attempt.witness)
        case .outcomeUnknown(let reason):
            if attempt.requiresOwnerRetention {
                return CleanupFinalizeOutcome(kind: .pending, reason: reason,
                                              receipt: attempt.receipt,
                                              witness: attempt.witness)
            }
            return CleanupFinalizeOutcome(kind: .kept,
                                          reason: "outcomeUnknown.\(reason)",
                                          receipt: attempt.receipt,
                                          witness: attempt.witness)
        }
    }

    /// Bootstrap drain (Main wires placement AFTER the owned store is ready
    /// and BEFORE ordinary admission): re-verify each durable intent against
    /// the NEWEST row under a real owner, delete-or-keep honestly, and park
    /// outstanding physical lifetimes with their exact witness. Disjoint from
    /// the vault credential_records drain (different namespace + table).
    public func drainCleanupQueue() async -> [String: Int] {
        var drained = 0, deferred = 0, superseded = 0
        let intents: [MCPSecretCleanupIntent]
        do {
            intents = try await MCPSecretCleanupLedger.readStrict(database)
        } catch {
            // Strict corrupt state: the queue is NOT empty/unknown-empty.
            return ["drained": 0, "deferred": 0, "superseded": 0, "corrupt": 1]
        }
        do { try await loadServers() } catch {
            return ["drained": 0, "deferred": intents.count,
                    "superseded": 0, "corrupt": 0]
        }
        for intent in intents {
            // A pending owner holds this server: reconcile through ITS
            // witness or keep the entry honestly.
            if await ownership.pendingRecord(providerID: intent.serverID) != nil {
                switch await reconcilePendingSecretOwner(serverID: intent.serverID) {
                case .settledNow, .nothingPending:
                    break
                case .stillPending:
                    deferred += 1
                    continue
                }
            }
            let ticket: ProviderOperationTicket
            switch await ownership.beginOperation(providerID: intent.serverID,
                                                  kind: .cleanup) {
            case .attached(let attached):
                ticket = attached
            case .conflict, .pendingReconciliation, .capacityUnavailable:
                deferred += 1
                continue
            }
            let lease: ConfigOwnedWorkLease
            switch ownedWork.begin(kind: .vaultMaintenance,
                                   ownerID: intent.serverID.uuidString) {
            case .success(let attached):
                lease = attached
            case .failure:
                await ownership.endOperation(ticket)
                deferred += 1
                continue
            }
            let outcome = await finalizeCleanup(serverID: intent.serverID,
                                                account: intent.account)
            switch outcome.kind {
            case .settled:
                drained += 1
                ownedWork.settle(lease)
                await ownership.endOperation(ticket)
            case .superseded:
                superseded += 1
                ownedWork.settle(lease)
                await ownership.endOperation(ticket)
            case .kept:
                deferred += 1
                ownedWork.settle(lease)
                await ownership.endOperation(ticket)
            case .pending:
                // Exact ticket + retained lease + receipt + original witness.
                _ = await ownership.parkPending(
                    ticket, intent: .secretClear,
                    receipt: outcome.receipt, lease: lease,
                    witness: outcome.witness)
                deferred += 1
            }
        }
        return ["drained": drained, "deferred": deferred,
                "superseded": superseded, "corrupt": 0]
    }

    // MARK: - Reply helpers

    private static func rejection(_ error: Error) -> sending [String: Any] {
        if let domain = error as? ConfigDomainError { return domain.jsonBody() }
        if let refusal = error as? MCPDomainRefusal {
            return ConfigDomainError(refusal).jsonBody()
        }
        if error is CancellationError {
            return ConfigDomainError(code: .runtimeUnavailable, reason: "cancelled").jsonBody()
        }
        return ConfigDomainError(code: .runtimeUnavailable,
                                 reason: safeReason(error)).jsonBody()
    }

    static func saveFailed(_ disposition: SecretEffectDisposition,
                           databaseRowWritten: Bool) -> sending [String: Any] {
        var body: [String: Any]
        switch disposition {
        case .committed:
            body = ["errorCode": ConfigWireCode.runtimeUnavailable.rawValue,
                    "reason": "secretCommittedThenFailed",
                    "secretDisposition": "committed"]
        case .outcomeUnknown(let reason):
            body = ["errorCode": ConfigWireCode.runtimeUnavailable.rawValue,
                    "reason": "secretOutcomeUnknown.\(reason)",
                    "secretDisposition": "outcomeUnknown",
                    "secretDispositionReason": reason]
        case .effectAbsent(let reason):
            if reason == "gatewayUnregistered" {
                body = ["errorCode": ConfigWireCode.needsConfiguration.rawValue,
                        "reason": "secretGatewayUnregistered",
                        "secretDisposition": "effectAbsent"]
            } else {
                body = ["errorCode": ConfigWireCode.runtimeUnavailable.rawValue,
                        "reason": "credentialPhaseAbsent.\(reason)",
                        "secretDisposition": "effectAbsent"]
            }
        }
        body["databaseRowWritten"] = databaseRowWritten
        return body
    }

    static func dispositionString(_ disposition: SecretEffectDisposition) -> String {
        switch disposition {
        case .committed: return "committed"
        case .effectAbsent(let reason): return "effectAbsent.\(reason)"
        case .outcomeUnknown(let reason): return "outcomeUnknown.\(reason)"
        }
    }

    static func wireCode(forMCP error: Error) -> ConfigWireCode {
        if let mcp = error as? MCPClientError {
            switch mcp {
            case .authenticationRequired: return .credentialUnavailable
            case .httpError, .remoteError, .invalidResponse: return .transportUnavailable
            case .responseTooLarge: return .payloadTooLarge
            case .disconnected, .cancelled, .timedOut: return .runtimeUnavailable
            }
        }
        if error is CancellationError { return .runtimeUnavailable }
        return .transportUnavailable
    }

    /// Closed machine-reason projection for typed MCP/config errors. Never
    /// remote message bodies, never endpoint userinfo, never secret text.
    static func safeReason(_ error: Error) -> String {
        if let mcp = error as? MCPClientError {
            switch mcp {
            case .authenticationRequired: return "authenticationRequired"
            case .httpError(let status, _): return "http.\(status)"
            case .remoteError(let code, _): return "remote.\(abs(code))"
            case .responseTooLarge: return "responseTooLarge"
            case .disconnected: return "disconnected"
            case .cancelled: return "cancelled"
            case .timedOut(let phase):
                let filtered = phase.unicodeScalars.prefix(24).map { scalar -> String in
                    let v = scalar.value
                    return (v >= 97 && v <= 122) ? String(scalar) : ""
                }
                let text = filtered.joined()
                return text.isEmpty ? "timedOut" : "timedOut.\(text)"
            case .invalidResponse:
                return "invalidResponse"
            }
        }
        if let floe = error as? FloeError, case .invalidConfiguration = floe {
            return "invalidConfiguration"
        }
        if error is CancellationError { return "cancelled" }
        if let domain = error as? ConfigDomainError { return domain.reason }
        return "failed"
    }

    static func mapConfigurationValidation(_ error: Error) -> ConfigDomainError {
        if let floe = error as? FloeError, case .invalidConfiguration = floe {
            return ConfigDomainError(code: .invalidEnvelope,
                                     reason: "mcpConfig.\(safeReason(error))")
        }
        if let domain = error as? ConfigDomainError { return domain }
        return ConfigDomainError(code: .invalidEnvelope, reason: "mcpConfigValidation")
    }
}

extension ConfigDomainError {
    init(_ refusal: MCPDomainRefusal) {
        switch refusal {
        case .runtimeNotReady:
            self.init(code: .runtimeUnavailable, reason: "storeNotReady")
        case .transportClosed:
            self.init(code: .transportUnavailable, reason: "mcpAdmissionGateClosed")
        case .gatewayUnregistered:
            self.init(code: .needsConfiguration, reason: "secretGatewayUnregistered")
        case .needsRouteContext:
            self.init(code: .runtimeUnavailable, reason: "routeContextUnavailable")
        }
    }
}
