// SPDX-License-Identifier: MPL-2.0
//
// Configured MCP connector for the Floe Mac workbench.
//
// Bounded to ONE explicitly configured Streamable-HTTP MCP connection:
// the user types an endpoint, enables it deliberately, sees an honest
// status, can test discovery, and can disable or revoke it at any time.
// Actual tool calls never originate here — discovered tools are published
// through the EXISTING `MCPRemoteToolSource` (FloeTools), which classifies
// every generic remote tool conservatively (network access + mutating,
// side-effecting) and runs it through the runtime's ordinary approval
// chain. This center adds no model-facing invocation path, starts no
// local process, reads no credential store, and exposes nothing on the
// network: the only outbound traffic is the user's configured endpoint,
// reached only while the connector is enabled and only for discovery or
// runtime-approved tool calls. Credential schemes are refused on this
// surface (authentication == .none only); a server that demands a
// credential fails honestly at discovery time.

import Combine
import Foundation
import FloeCore
import FloeTools

// MARK: - Configuration

/// The single configured connector. `server` is the existing
/// `MCPServerConfiguration` (FloeTools); the workbench constrains it to
/// explicit user authority (enabled flag, no credential schemes).
public struct MacWorkbenchConnectorConfiguration: Codable, Sendable, Equatable {
    public var server: MCPServerConfiguration
    public var addedAt: Date

    public init(server: MCPServerConfiguration, addedAt: Date = Date()) {
        self.server = server
        self.addedAt = addedAt
    }
}

// MARK: - Status

/// Display state for the one configured connector. Values are honest:
/// a failed discovery is a failure, never "ready with zero tools".
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
    case credentialSchemesUnsupported
    case invalidConfiguration(String)
    case noConnection

    public var errorDescription: String? {
        switch self {
        case .credentialSchemesUnsupported:
            "Credential-based connectors are not available on this surface. Use a server that needs no credential, on a network you trust."
        case .invalidConfiguration(let reason):
            reason
        case .noConnection:
            "No MCP connector is configured. Add one above."
        }
    }
}

// MARK: - Persistence facade

/// The coordinator satisfies this with its settings persistence; the
/// default file store below is a non-conflicting JSON file owned by this
/// workbench (it touches no existing database or Keychain item).
public protocol MacWorkbenchConnectorStore: Sendable {
    func load() async throws -> MacWorkbenchConnectorConfiguration?
    func save(_ configuration: MacWorkbenchConnectorConfiguration?) async throws
}

/// Atomic JSON persistence in Application Support. The write is staged and
/// moved so a crash mid-write cannot truncate the previous value.
public struct MacWorkbenchFileConnectorStore: MacWorkbenchConnectorStore {
    private let url: URL
    public init(url: URL) { self.url = url }

    public static func `default`() -> MacWorkbenchFileConnectorStore {
        MacWorkbenchFileConnectorStore(url: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeMacWorkbench", isDirectory: true)
            .appendingPathComponent("mcp-connector.json"))
    }

    public func load() async throws -> MacWorkbenchConnectorConfiguration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try JSONDecoder().decode(MacWorkbenchConnectorConfiguration.self, from: data)
    }

    public func save(_ configuration: MacWorkbenchConnectorConfiguration?) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let configuration {
            try JSONEncoder().encode(configuration).write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

// MARK: - Center

/// Owns the one configured MCP connector: configuration, explicit
/// enablement, honest status, test discovery, and teardown. Discovered
/// remote tools are published into the service's OWN injected registry —
/// never the process-shared registry — and exposed as an explicit
/// `[AnyAgentTool]` slice (`publishedTools`) so the native owner can inject
/// scoped copies into a task through the current TaskPolicy path. This
/// center adds no model-facing invocation path, starts no local process,
/// reads no credential store, and exposes nothing on the network: the only
/// outbound traffic is the user's configured endpoint, reached only while
/// the connector is enabled and only for discovery or runtime-approved tool
/// calls. Credential schemes are refused on this surface
/// (authentication == .none only); a server that demands a credential fails
/// honestly at discovery time.
@MainActor
public final class MacWorkbenchConnectorsService: ObservableObject {
    @Published public private(set) var configuration: MacWorkbenchConnectorConfiguration?
    @Published public private(set) var status: MacWorkbenchConnectorStatus = .unconfigured
    @Published public private(set) var discoveredTools: [MCPDiscoveredTool] = []
    /// The executable remote tools currently published for this connector,
    /// scoped to the service's own injected registry — never the
    /// process-shared registry. The native owner injects this slice into a
    /// task explicitly through the current TaskPolicy path; the service
    /// performs no shared registration itself.
    @Published public private(set) var publishedTools: [AnyAgentTool] = []

    private let store: any MacWorkbenchConnectorStore
    private let registry: ToolRunnerRegistry
    private var client: MCPRemoteClient?
    /// The configuration the live client was built from (authoritative for
    /// the unregister namespace on teardown).
    private var activeConfiguration: MCPServerConfiguration?
    /// Bumped on every configuration change; a stale discovery result must
    /// not overwrite a newer status or publish tools under a newer config.
    private var generation = 0
    private var savingConfiguration = false

    public init(store: any MacWorkbenchConnectorStore = MacWorkbenchFileConnectorStore.default(),
                registry: ToolRunnerRegistry = ToolRunnerRegistry()) {
        self.store = store
        self.registry = registry
    }

    /// Restore the persisted connector on launch. Never touches the network.
    /// Idempotent: a later call (e.g. the settings view reappearing) must
    /// not reset a live Ready state back to untested.
    public func restore() async {
        guard configuration == nil, status == .unconfigured, !savingConfiguration else { return }
        let previousGeneration = generation
        guard let loaded = try? await store.load(), generation == previousGeneration else { return }
        guard (try? Self.validate(loaded.server)) != nil else { return }
        configuration = loaded
        applyIdleStatus()
    }

    // MARK: Configure / enable / disable / revoke

    /// Validate and persist a new connector, replacing any previous one.
    /// The previous connector's tools are revoked before the new
    /// configuration is stored. Only credential-free servers are accepted
    /// on this surface.
    public func configure(server: MCPServerConfiguration) async throws {
        try Self.validate(server)
        try await saveConfiguration(MacWorkbenchConnectorConfiguration(server: server))
    }

    private static func validate(_ server: MCPServerConfiguration) throws {
        guard server.authentication == .none else {
            throw MacWorkbenchConnectorError.credentialSchemesUnsupported
        }
        // Credential-free, file-backed settings must not smuggle credential-
        // like or routing data in the endpoint URL: the MCP transport sends
        // the configured origin only; query/fragment carrying endpoints are
        // rejected before validation.
        guard server.endpoint.query == nil, server.endpoint.fragment == nil else {
            throw MacWorkbenchConnectorError.invalidConfiguration(
                "The MCP endpoint must not carry query parameters or a fragment.")
        }
        try server.validate()
    }

    public func setEnabled(_ enabled: Bool) async throws {
        guard var config = configuration else { throw MacWorkbenchConnectorError.noConnection }
        config.server.enabled = enabled
        try await saveConfiguration(config)
    }

    /// Remove the connector entirely: revoke its tools, disconnect, and
    /// delete the persisted configuration.
    public func revoke() async throws {
        try await saveConfiguration(nil)
    }

    private func saveConfiguration(_ next: MacWorkbenchConnectorConfiguration?) async throws {
        guard !savingConfiguration else {
            throw MacWorkbenchConnectorError.invalidConfiguration("The connector is being saved.")
        }
        savingConfiguration = true
        defer { savingConfiguration = false }
        generation += 1
        await teardownClient()
        applyIdleStatus()
        try await store.save(next)
        configuration = next
        applyIdleStatus()
    }

    // MARK: Discovery (explicit user test)

    /// Explicit discovery against the user's configured endpoint. Clear
    /// the old snapshot first so a failed refresh cannot leave stale tools.
    @discardableResult
    public func testDiscovery() async -> [MCPDiscoveredTool] {
        guard let config = configuration, config.server.enabled, !savingConfiguration else { return [] }
        let generation = self.generation + 1
        self.generation = generation
        status = .discovering
        await teardownClient()
        guard generation == self.generation else { return [] }
        do {
            let client = try MCPRemoteClient(configuration: config.server, credential: nil)
            self.client = client
            self.activeConfiguration = config.server
            let tools = try await client.discoverTools()
            try Task.checkCancellation()
            guard generation == self.generation else { return [] }
            discoveredTools = tools
            MCPRemoteToolSource.register(configuration: config.server, client: client,
                                         tools: tools, registry: registry)
            publishedTools = registry.allDescriptors.compactMap { registry.runner(named: $0.name) }
            status = .ready(toolCount: tools.count)
            return tools
        } catch {
            guard generation == self.generation else { return [] }
            await teardownClient()
            guard generation == self.generation else { return [] }
            if error is CancellationError { applyIdleStatus() }
            else { status = .failed(message: Self.boundedFailureMessage(error)) }
            return []
        }
    }

    /// Disconnect the live client and revoke the published tools while
    /// KEEPING the persisted configuration and enabled state. This is the
    /// Agent-deactivation hook: the runtime drops the task-scoped tools and
    /// tears the connection down, and the user-visible switch stays as
    /// configured for the next activation.
    public func disconnect() async {
        generation += 1
        let retiringGeneration = generation
        await teardownClient()
        if retiringGeneration == generation { applyIdleStatus() }
    }

    /// Disconnect and unregister the connector's remote tools from the
    /// service's own registry, and clear the published slice. Idempotent.
    private func teardownClient() async {
        let retiringClient = client
        client = nil
        if let config = activeConfiguration {
            MCPRemoteToolSource.unregister(configuration: config, registry: registry)
        }
        activeConfiguration = nil
        discoveredTools = []
        publishedTools = []
        await retiringClient?.disconnect()
    }

    private func applyIdleStatus() {
        guard let configuration else { status = .unconfigured; return }
        status = configuration.server.enabled ? .enabledUntested : .disabled
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
