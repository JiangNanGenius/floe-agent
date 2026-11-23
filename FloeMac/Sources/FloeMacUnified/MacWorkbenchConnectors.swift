// SPDX-License-Identifier: MPL-2.0
//
// Configured MCP connectors for the Floe Mac workbench.
//
// Mirrors the iPad `MCPSettingsCenter` model: the user can configure MULTIPLE
// explicitly configured Streamable-HTTP MCP servers, each with its own
// stable identity (`MCPServerConfiguration.id`), independent namespaced tool
// namespace, and lifecycle. Authentication schemes follow the shared
// `MCPServerConfiguration` contract (none / Bearer token / custom request
// header); credentials live in the injected macOS Keychain store, never in
// the JSON settings document and never in logs. Actual tool calls never
// originate here — discovered tools are published through the EXISTING
// `MCPRemoteToolSource` (FloeTools), which classifies every generic remote
// tool conservatively (network access + mutating, side-effecting) and runs
// it through the runtime's ordinary approval chain.
//
// The activated/advertised set injected into a task is BOUNDED across all
// enabled servers (see `advertisedToolLimit`): the production runtime
// freezes a capability ceiling of at most 64 named tools per run, so an
// unbounded connector set must never break normal agent admission. The
// selection is deterministic (servers by added-then-id, tools by discovery
// order, per-server disabled tools skipped), and every advertised tool
// carries a `MacWorkbenchConnectorToolOrigin` so the approval card can show
// the exact server it targets. Tools beyond the budget stay discovered and
// individually manageable in settings without entering the run scope.

import Combine
import Foundation
import FloeCore
import FloeTools

// MARK: - Configuration

/// One configured connector record: the shared `MCPServerConfiguration`
/// (FloeTools) plus the local bookkeeping date. The server `id` is stable
/// across edits, keychain bindings, and persistence migrations.
public struct MacWorkbenchConnectorConfiguration: Codable, Sendable, Equatable {
    public var server: MCPServerConfiguration
    public var addedAt: Date

    public init(server: MCPServerConfiguration, addedAt: Date = Date()) {
        self.server = server
        self.addedAt = addedAt
    }
}

// MARK: - Status

/// Display state for one configured connector. Values are honest: a failed
/// discovery is a failure, never "ready with zero tools".
public enum MacWorkbenchConnectorStatus: Sendable, Equatable {
    case unconfigured
    case disabled
    case enabledUntested
    case discovering
    case ready(toolCount: Int)
    case failed(message: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

// MARK: - Errors

public enum MacWorkbenchConnectorError: Error, Equatable, Sendable, LocalizedError {
    /// Legacy spelling kept for source compatibility; credential schemes are
    /// now supported through the injected credential store.
    case credentialSchemesUnsupported
    case invalidConfiguration(String)
    case noConnection
    case unknownServer(UUID)

    public var errorDescription: String? {
        switch self {
        case .credentialSchemesUnsupported:
            "Credential-based connectors are stored in the macOS Keychain."
        case .invalidConfiguration(let reason):
            reason
        case .noConnection:
            "No MCP connector is configured. Add one above."
        case .unknownServer(let id):
            "No MCP connector exists for \(id.uuidString)."
        }
    }
}

// MARK: - Tool origin metadata

/// Where one advertised connector tool came from. The approval surface uses
/// this to label the card with the exact server and host a tool targets; no
/// credential material is ever part of this value.
public struct MacWorkbenchConnectorToolOrigin: Sendable, Equatable {
    public let serverID: UUID
    public let serverName: String
    public let host: String?
    public let remoteName: String
    /// "none" / "bearer" / "header:<name>" — display classification only.
    public let authentication: String

    public init(serverID: UUID, serverName: String, host: String?, remoteName: String,
                authentication: String) {
        self.serverID = serverID
        self.serverName = serverName
        self.host = host
        self.remoteName = remoteName
        self.authentication = authentication
    }
}

// MARK: - Tool binding

/// The exact binding material a scoped tool grant locks to one connector
/// tool: the descriptor authorization identity, the normalized endpoint
/// digest, the configured authentication digest, and the SHA-256 of the
/// exact approved call arguments. Raw arguments and credential values never
/// enter the grant store — only their digests.
public struct MacWorkbenchConnectorToolBinding: Sendable, Equatable {
    public let serverID: UUID
    public let toolName: String
    public let descriptorIdentity: String
    public let endpointDigest: String
    public let authenticationDigest: String
    let connectionGeneration: UInt64
    public let host: String?
    public let remoteName: String

    public init(serverID: UUID, toolName: String, descriptorIdentity: String,
                endpointDigest: String, authenticationDigest: String,
                host: String?, remoteName: String, connectionGeneration: UInt64 = 0) {
        self.serverID = serverID
        self.toolName = toolName
        self.descriptorIdentity = descriptorIdentity
        self.endpointDigest = endpointDigest
        self.authenticationDigest = authenticationDigest
        self.connectionGeneration = connectionGeneration
        self.host = host
        self.remoteName = remoteName
    }

    /// Digest of one exact call's argument bytes, bound by scoped grants so a
    /// remembered approval can never authorize a different remote operation.
    public static func argumentsDigest(_ argumentsJSON: Data) -> String {
        FloeDigest.sha256Hex(argumentsJSON)
    }
}

// MARK: - Center

/// Owns every configured MCP connector: configuration, explicit enablement,
/// honest per-server status, test discovery, and teardown. Discovered remote
/// tools are published into the service's OWN injected registry — never the
/// process-shared registry — and exposed as an explicit `[AnyAgentTool]`
/// slice (`publishedTools`) so the native owner can inject scoped copies into
/// a task through the current TaskPolicy path. This center adds no
/// model-facing invocation path, starts no local process, and exposes nothing
/// on the network: the only outbound traffic is the user's configured
/// endpoints, reached only while the connector is enabled and only for
/// discovery or runtime-approved tool calls.
@MainActor
public final class MacWorkbenchConnectorsService: ObservableObject {
    // MARK: Published state

    /// All configured servers in a stable order (added date, then id).
    @Published public private(set) var servers: [MCPServerConfiguration] = []
    @Published public private(set) var statusByID: [UUID: MacWorkbenchConnectorStatus] = [:]
    @Published public private(set) var discoveredToolsByID: [UUID: [MCPDiscoveredTool]] = [:]
    /// The executable remote tools currently advertised for task injection.
    /// This is the BOUNDED selection across enabled servers (see the type
    /// comment); the service performs no shared registration itself.
    @Published public private(set) var publishedTools: [AnyAgentTool] = []
    /// The server metadata for every advertised tool, keyed by local tool
    /// name, so the approval card targets the correct server.
    @Published public private(set) var toolOrigins: [String: MacWorkbenchConnectorToolOrigin] = [:]

    // MARK: Single-server compatibility views
    //
    // Un-migrated call sites keep compiling: with one configured server these
    // behave exactly like the former single-server surface. Multi-server call
    // sites should use `servers` / `statusByID` / `discoveredToolsByID`.

    /// The first configured server record, if any.
    public var configuration: MacWorkbenchConnectorConfiguration? {
        guard let server = servers.first else { return nil }
        return MacWorkbenchConnectorConfiguration(server: server, addedAt: addedAtByID[server.id] ?? Date())
    }

    /// The status of the first configured server.
    public var status: MacWorkbenchConnectorStatus {
        guard let server = servers.first else { return .unconfigured }
        return statusByID[server.id] ?? .unconfigured
    }

    /// The discovered tools of the first ready server.
    public var discoveredTools: [MCPDiscoveredTool] {
        guard let server = servers.first else { return [] }
        return discoveredToolsByID[server.id] ?? []
    }

    // MARK: Limits

    /// Total connector tools advertised into a task across all enabled
    /// servers. The production runtime freezes at most 64 named tools per
    /// run; first-party tools already occupy most of that budget, so the
    /// connector slice must stay bounded to avoid breaking normal admission.
    public let advertisedToolLimit: Int
    /// Per-server share of the advertised budget. A server can never crowd
    /// out every other server.
    public let perServerAdvertisedToolLimit: Int

    // MARK: Private state

    private let store: any MacWorkbenchConnectorStore
    private let credentials: any MacWorkbenchConnectorCredentialStore
    private let registry: ToolRunnerRegistry
    /// Test seam: return a custom URLSession for a server configuration (for
    /// example a `URLProtocol`-stubbed session). `nil` uses the transport's
    /// own ephemeral session.
    private let sessionProvider: @Sendable (MCPServerConfiguration) -> URLSession?
    private var clients: [UUID: MCPRemoteClient] = [:]
    /// The configuration each live client was built from (authoritative for
    /// the unregister namespace on teardown).
    private var activeConfigurationByID: [UUID: MCPServerConfiguration] = [:]
    private var addedAtByID: [UUID: Date] = [:]
    /// Per-server generation: a stale discovery result must not overwrite a
    /// newer status or publish tools under a newer config.
    private var generationByID: [UUID: UInt64] = [:]
    private var changingServers: Set<UUID> = []
    private var savingConfiguration = false

    public init(store: any MacWorkbenchConnectorStore = MacWorkbenchFileConnectorStore.default(),
                registry: ToolRunnerRegistry = ToolRunnerRegistry(),
                credentials: any MacWorkbenchConnectorCredentialStore = MacWorkbenchKeychainCredentialStore(),
                advertisedToolLimit: Int = 16,
                perServerAdvertisedToolLimit: Int = 8,
                sessionProvider: (@Sendable (MCPServerConfiguration) -> URLSession)? = nil) {
        self.store = store
        self.registry = registry
        self.credentials = credentials
        self.advertisedToolLimit = min(max(advertisedToolLimit, 1), 32)
        self.perServerAdvertisedToolLimit = min(max(perServerAdvertisedToolLimit, 1), 16)
        self.sessionProvider = sessionProvider ?? { _ in nil }
    }

    // MARK: Restore

    /// Honest surface for a failed settings read: the saved connectors stay
    /// on disk untouched and the user sees why the list is empty.
    @Published public private(set) var restoreError: String?

    /// Restore the persisted connectors on launch. Never touches the
    /// network. Idempotent: a later call (e.g. the settings view reappearing)
    /// must not reset a live Ready state back to untested. A load failure is
    /// surfaced through `restoreError` and NEVER treated as "no connectors":
    /// the persisted document is left untouched for the next launch.
    public func restore() async {
        guard servers.isEmpty, !savingConfiguration else { return }
        let snapshot: MacWorkbenchConnectorSnapshot
        do {
            snapshot = try await store.load()
        } catch {
            restoreError = Self.boundedFailureMessage(error)
            return
        }
        restoreError = nil
        var addedAtByID: [UUID: Date] = [:]
        var servers: [MCPServerConfiguration] = []
        for record in snapshot.servers {
            guard (try? Self.validate(record.server)) != nil else { continue }
            addedAtByID[record.server.id] = record.addedAt
            servers.append(record.server)
        }
        self.addedAtByID = addedAtByID
        self.servers = Self.stablySorted(servers, addedAtByID: addedAtByID)
        for server in self.servers {
            statusByID[server.id] = server.enabled ? .enabledUntested : .disabled
        }
    }

    // MARK: Configure / enable / remove

    /// Validate and persist a server, replacing any previous record with the
    /// same id. The previous registration is revoked only after the new
    /// snapshot was stored, so a failed save leaves the live connector
    /// untouched (coherent rollback). Credential handling:
    /// - non-empty `credential` → stored in the Keychain, bound to the
    ///   server id and endpoint origin;
    /// - authentication required and no stored/new credential → throws
    ///   `MCPClientError.authenticationRequired`;
    /// - authentication `.none` → any stored credential is deleted;
    /// - endpoint origin changed → the credential bound to the previous
    ///   origin is deleted (never reused for a new destination).
    public func configure(server: MCPServerConfiguration, credential: String? = nil) async throws {
        try Self.validate(server)
        try beginChange(server.id)
        defer { endChange(server.id) }
        let previous = servers.first(where: { $0.id == server.id })
        let previousAccount = previous.map { MacWorkbenchKeychainCredentialStore.account(for: $0) }
        let newAccount = MacWorkbenchKeychainCredentialStore.account(for: server)
        let replacementKey = credential.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if previous != nil, previous != server || replacementKey != nil {
            try await revokeScopedGrants(for: server)
        }
        let previousKey = replacementKey != nil && previousAccount == newAccount
            ? try await credentials.credential(for: server) : nil
        if let credential = replacementKey {
            try await credentials.store(credential: credential, for: server)
        } else if server.authentication != .none,
                  try await credentials.credential(for: server) == nil {
            throw MCPClientError.authenticationRequired
        }
        if server.authentication == .none {
            try await credentials.delete(for: server)
        }
        var record = MacWorkbenchConnectorConfiguration(server: server)
        record.addedAt = previous.flatMap { addedAtByID[$0.id] } ?? Date()
        do {
            try await persistReplacing([record], changedServerIDs: [server.id])
        } catch {
            // Roll back a freshly stored credential so a failed save cannot
            // leave an orphaned secret (the live connector is untouched).
            if replacementKey != nil {
                if let previousKey { try? await credentials.store(credential: previousKey, for: server) }
                else { try? await credentials.delete(for: server) }
            }
            throw error
        }
        // The snapshot is stored; swapping runtime state cannot fail closed
        // anymore. Drop the previous registration under this server id (the
        // namespace prefix is id-derived, so stale runner closures from an
        // older endpoint must not survive) and rediscover when enabled.
        await teardownServer(serverID: server.id)
        if let previous, previousAccount != newAccount {
            try await credentials.delete(for: previous)
        }
        if server.enabled {
            await refresh(serverID: server.id)
        } else {
            applyIdleStatus(serverID: server.id)
        }
    }

    public func setEnabled(_ enabled: Bool, serverID: UUID) async throws {
        guard let record = configurationRecord(serverID: serverID) else {
            throw MacWorkbenchConnectorError.unknownServer(serverID)
        }
        guard record.server.enabled != enabled else { return }
        try beginChange(serverID)
        defer { endChange(serverID) }
        var server = record.server
        server.enabled = enabled
        if enabled { try await revokeScopedGrants(for: server) }
        var updated = record
        updated.server = server
        try await persistReplacing([updated], changedServerIDs: [serverID])
        if enabled {
            await refresh(serverID: serverID)
        } else {
            await teardownServer(serverID: serverID)
            applyIdleStatus(serverID: serverID)
            // A disabled server must not keep authorizing remembered calls.
            try await revokeScopedGrants(for: server)
        }
    }

    /// Remove the connector entirely: revoke its tools, disconnect, delete
    /// the persisted record and erase its stored credential (including a
    /// credential for a server that was never connected).
    public func remove(serverID: UUID) async throws {
        guard let record = configurationRecord(serverID: serverID) else {
            throw MacWorkbenchConnectorError.unknownServer(serverID)
        }
        try beginChange(serverID)
        defer { endChange(serverID) }
        // Capture the persisted configuration BEFORE teardown: teardown
        // clears the live registration map, and the credential binding is
        // derived from the persisted spec (not from a connected client).
        let persisted = record.server
        try await revokeScopedGrants(for: persisted)
        try await persistRemoving(serverID: serverID)
        try await credentials.delete(for: persisted)
    }

    /// Legacy single-server spelling of `remove(serverID:)`.
    public func revoke() async throws {
        guard let server = servers.first else { throw MacWorkbenchConnectorError.noConnection }
        try await remove(serverID: server.id)
    }

    /// Legacy single-server spelling of `configure(server:credential:)`.
    public func configure(server: MCPServerConfiguration) async throws {
        try await configure(server: server, credential: nil)
    }

    private func configurationRecord(serverID: UUID) -> MacWorkbenchConnectorConfiguration? {
        guard let server = servers.first(where: { $0.id == serverID }) else { return nil }
        return MacWorkbenchConnectorConfiguration(server: server, addedAt: addedAtByID[serverID] ?? Date())
    }

    /// Persist the replacement record, then swap runtime state. Ordered so a
    /// store failure leaves the previous runtime untouched. Only the changed
    /// servers have their discovery generation bumped: an untouched server's
    /// in-flight discovery stays valid.
    private func persistReplacing(_ records: [MacWorkbenchConnectorConfiguration],
                                  changedServerIDs: Set<UUID>) async throws {
        guard !savingConfiguration else {
            throw MacWorkbenchConnectorError.invalidConfiguration("A connector change is already being saved.")
        }
        savingConfiguration = true
        defer { savingConfiguration = false }
        var snapshot = MacWorkbenchConnectorSnapshot(servers: records)
        snapshot.servers += servers
            .filter { existing in !records.contains(where: { $0.server.id == existing.id }) }
            .map { MacWorkbenchConnectorConfiguration(server: $0, addedAt: addedAtByID[$0.id] ?? Date()) }
        snapshot.servers = Self.stablySortedRecords(snapshot.servers)
        try await store.save(snapshot)
        applySnapshot(snapshot, changedServerIDs: changedServerIDs)
    }

    private func persistRemoving(serverID: UUID) async throws {
        guard !savingConfiguration else {
            throw MacWorkbenchConnectorError.invalidConfiguration("A connector change is already being saved.")
        }
        savingConfiguration = true
        defer { savingConfiguration = false }
        let remaining = servers
            .filter { $0.id != serverID }
            .map { MacWorkbenchConnectorConfiguration(server: $0, addedAt: addedAtByID[$0.id] ?? Date()) }
        let snapshot = MacWorkbenchConnectorSnapshot(servers: Self.stablySortedRecords(remaining))
        try await store.save(snapshot)
        applySnapshot(snapshot, changedServerIDs: [serverID])
        await teardownServer(serverID: serverID)
    }

    private func applySnapshot(_ snapshot: MacWorkbenchConnectorSnapshot,
                               changedServerIDs: Set<UUID>) {
        for id in changedServerIDs {
            generationByID[id] = (generationByID[id] ?? 0) &+ 1
        }
        var addedAtByID: [UUID: Date] = [:]
        var servers: [MCPServerConfiguration] = []
        for record in snapshot.servers {
            addedAtByID[record.server.id] = record.addedAt
            servers.append(record.server)
        }
        self.addedAtByID = addedAtByID
        self.servers = Self.stablySorted(servers, addedAtByID: addedAtByID)
        var statusByID = statusByID
        for id in statusByID.keys where addedAtByID[id] == nil {
            statusByID.removeValue(forKey: id)
        }
        for server in self.servers where statusByID[server.id] == nil {
            statusByID[server.id] = server.enabled ? .enabledUntested : .disabled
        }
        self.statusByID = statusByID
        republish()
    }

    private static func validate(_ server: MCPServerConfiguration) throws {
        // Settings must not smuggle credential-like or routing data in the
        // endpoint URL: the MCP transport sends the configured origin only;
        // query/fragment carrying endpoints are rejected before validation.
        guard server.endpoint.query == nil, server.endpoint.fragment == nil else {
            throw MacWorkbenchConnectorError.invalidConfiguration(
                "The MCP endpoint must not carry query parameters or a fragment.")
        }
        try server.validate()
    }

    // MARK: Discovery (explicit user test)

    /// Explicit discovery against one configured endpoint. Clears the old
    /// snapshot first so a failed refresh cannot leave stale tools.
    @discardableResult
    public func testDiscovery(serverID: UUID) async -> [MCPDiscoveredTool] {
        guard let server = servers.first(where: { $0.id == serverID }),
              server.enabled, !savingConfiguration else { return [] }
        let generation = (generationByID[serverID] ?? 0) &+ 1
        generationByID[serverID] = generation
        statusByID[serverID] = .discovering
        await teardownServer(serverID: serverID)
        guard generation == generationByID[serverID] else { return [] }
        do {
            let credential = try await credentials.credential(for: server)
            let client = try MCPRemoteClient(
                configuration: server,
                credential: credential,
                session: sessionProvider(server)
            )
            let tools = try await client.discoverTools()
            try Task.checkCancellation()
            guard generation == generationByID[serverID],
                  servers.first(where: { $0.id == serverID }) == server else {
                await client.disconnect()
                return []
            }
            clients[serverID] = client
            activeConfigurationByID[serverID] = server
            discoveredToolsByID[serverID] = tools
            MCPRemoteToolSource.register(configuration: server, client: client,
                                         tools: tools, registry: registry)
            statusByID[serverID] = .ready(toolCount: tools.count)
            republish()
            return tools
        } catch {
            guard generation == generationByID[serverID] else { return [] }
            await teardownServer(serverID: serverID)
            guard generation == generationByID[serverID] else { return [] }
            if error is CancellationError {
                applyIdleStatus(serverID: serverID)
            } else {
                statusByID[serverID] = .failed(message: Self.boundedFailureMessage(error))
            }
            return []
        }
    }

    /// Legacy single-server spelling of `testDiscovery(serverID:)`.
    @discardableResult
    public func testDiscovery() async -> [MCPDiscoveredTool] {
        guard let server = servers.first else { return [] }
        return await testDiscovery(serverID: server.id)
    }

    /// Enable-and-discover convenience for one server (used by the editor's
    /// "Save & Connect" and by the settings toggle).
    @discardableResult
    public func refresh(serverID: UUID) async -> [MCPDiscoveredTool] {
        await testDiscovery(serverID: serverID)
    }

    /// Disconnect every live client and revoke the published tools while
    /// KEEPING the persisted configuration and enabled state. This is the
    /// Agent-deactivation hook.
    public func disconnect() async {
        generationByID = generationByID.mapValues { $0 &+ 1 }
        let ids = Array(activeConfigurationByID.keys)
        for id in ids { await teardownServer(serverID: id) }
        for server in servers { applyIdleStatus(serverID: server.id) }
    }

    /// Disconnect and unregister one server's remote tools from the
    /// service's own registry, and clear its published slice. Idempotent.
    private func teardownServer(serverID: UUID) async {
        let retiringClient = clients.removeValue(forKey: serverID)
        if let config = activeConfigurationByID.removeValue(forKey: serverID) {
            MCPRemoteToolSource.unregister(configuration: config, registry: registry)
        }
        discoveredToolsByID[serverID] = []
        await retiringClient?.disconnect()
        republish()
    }

    private func applyIdleStatus(serverID: UUID) {
        guard let server = servers.first(where: { $0.id == serverID }) else {
            statusByID[serverID] = .unconfigured
            return
        }
        statusByID[serverID] = server.enabled ? .enabledUntested : .disabled
    }

    /// Revoke persisted and session tool grants in one server's exact
    /// id-derived namespace. Covers grants written before this launch ever
    /// discovered the server; matching stays fail-closed regardless.
    private func revokeScopedGrants(for server: MCPServerConfiguration) async throws {
        let prefix = server.namespacePrefix + "_"
        await MacSessionApprovalGrants.shared.revokeAll(toolNamePrefix: prefix)
        try await MacScopedToolGrants.shared.revokeAll(toolNamePrefix: prefix)
    }

    private func beginChange(_ id: UUID) throws {
        guard changingServers.insert(id).inserted else {
            throw MacWorkbenchConnectorError.invalidConfiguration("A connector change is already being saved.")
        }
        republish()
    }

    private func endChange(_ id: UUID) {
        changingServers.remove(id)
        republish()
    }

    // MARK: Advertised selection

    /// Recompute the bounded advertised slice and its metadata map from the
    /// live registrations. Deterministic: servers by (addedAt, id), tools by
    /// discovery order, per-server and total budgets enforced.
    private func republish() {
        var published: [AnyAgentTool] = []
        var origins: [String: MacWorkbenchConnectorToolOrigin] = [:]
        var budget = advertisedToolLimit
        for server in servers {
            guard budget > 0, server.enabled,
                  !changingServers.contains(server.id), activeConfigurationByID[server.id] == server,
                  let tools = discoveredToolsByID[server.id], !tools.isEmpty else { continue }
            let prefix = server.namespacePrefix + "_"
            var perServer = 0
            for tool in tools {
                guard budget > 0, perServer < perServerAdvertisedToolLimit else { break }
                guard !server.disabledRemoteToolNames.contains(tool.remoteName) else { continue }
                let localName = MCPRemoteToolSource.namespacedName(prefix: prefix, remoteName: tool.remoteName)
                guard let runner = registry.runner(named: localName) else { continue }
                published.append(runner)
                origins[localName] = MacWorkbenchConnectorToolOrigin(
                    serverID: server.id,
                    serverName: server.displayName,
                    host: server.endpoint.host(),
                    remoteName: tool.remoteName,
                    authentication: Self.authenticationLabel(server.authentication)
                )
                budget -= 1
                perServer += 1
            }
        }
        publishedTools = published
        toolOrigins = origins
    }

    private static func authenticationLabel(_ authentication: MCPServerConfiguration.Authentication) -> String {
        switch authentication {
        case .none: "none"
        case .bearerToken: "bearer"
        case .customHeader: "customHeader"
        }
    }

    private static func stablySorted(_ servers: [MCPServerConfiguration],
                                     addedAtByID: [UUID: Date]) -> [MCPServerConfiguration] {
        servers.sorted {
            let lhs = addedAtByID[$0.id] ?? .distantPast
            let rhs = addedAtByID[$1.id] ?? .distantPast
            if lhs != rhs { return lhs < rhs }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func stablySortedRecords(_ records: [MacWorkbenchConnectorConfiguration]) -> [MacWorkbenchConnectorConfiguration] {
        records.sorted {
            if $0.addedAt != $1.addedAt { return $0.addedAt < $1.addedAt }
            return $0.server.id.uuidString < $1.server.id.uuidString
        }
    }

    /// The exact binding material for one advertised tool, or nil when the
    /// tool is not currently published by this service. Scoped tool grants
    /// consume this so a remembered approval is locked to the descriptor
    /// identity, endpoint, authentication scheme and call arguments.
    public func binding(for toolName: String) -> MacWorkbenchConnectorToolBinding? {
        guard let origin = toolOrigins[toolName],
              let generation = generationByID[origin.serverID],
              let server = servers.first(where: { $0.id == origin.serverID }),
              let descriptor = registry.descriptor(named: toolName) else { return nil }
        return MacWorkbenchConnectorToolBinding(
            serverID: origin.serverID,
            toolName: toolName,
            descriptorIdentity: descriptor.authorizationIdentity,
            endpointDigest: Self.endpointDigest(server.endpoint),
            authenticationDigest: Self.authenticationDigest(server),
            host: origin.host,
            remoteName: origin.remoteName,
            connectionGeneration: generation
        )
    }

    /// Normalized endpoint material for binding: scheme, host, port and the
    /// percent-encoded path in canonical form. Query and fragment are
    /// rejected at validation time; the encoded path keeps distinct routes
    /// distinct (never filesystem-path normalization).
    public static func endpointDigest(_ endpoint: URL) -> String {
        let scheme = endpoint.scheme?.lowercased() ?? ""
        let host = endpoint.host?.lowercased() ?? ""
        let port = endpoint.port.map(String.init) ?? ""
        let path = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?
            .percentEncodedPath ?? endpoint.path
        return FloeDigest.sha256Hex(Data("\(scheme)\u{1f}\(host)\u{1f}\(port)\u{1f}\(path)".utf8))
    }

    /// Authentication binding: the scheme and, for custom headers, the
    /// configured header name. Credential VALUES never enter the digest.
    public static func authenticationDigest(_ server: MCPServerConfiguration) -> String {
        switch server.authentication {
        case .none:
            return FloeDigest.sha256Hex(Data("none".utf8))
        case .bearerToken:
            return FloeDigest.sha256Hex(Data("bearer".utf8))
        case .customHeader:
            let name = server.credentialHeaderName.trimmingCharacters(in: .whitespaces).lowercased()
            return FloeDigest.sha256Hex(Data("header\u{1f}\(name)".utf8))
        }
    }

    /// Remote failures are untrusted text: redact anything the shared
    /// redactor knows about and bound the result for display.
    static func boundedFailureMessage(_ error: Error) -> String {
        let redacted = SecretRedactor.redact(error.localizedDescription)
        let collapsed = redacted
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(collapsed.prefix(240))
    }
}
