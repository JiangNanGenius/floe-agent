// SPDX-License-Identifier: MPL-2.0
//
// Multi-server persistence and credential storage for the Floe Mac
// workbench MCP connectors, mirroring the iPad `MCPSettingsCenter` storage
// design (`MCPServerConfiguration` + Keychain-bound credentials).
//
// - Snapshot store: a versioned JSON document holding every configured
//   server. The previous single-server document decodes as the legacy
//   format and migrates in memory on first load; the file is only replaced
//   after a new snapshot is written atomically, so a failed save cannot
//   destroy the previous configuration (coherent rollback). A decode error,
//   a newer-than-supported document version, a permission failure or
//   cancellation is NEVER reported as an empty document: loading throws and
//   the saved connectors stay on disk untouched.
// - Credential store: secrets live in the macOS Keychain, never in the JSON
//   document and never in logs. Items are device-only and non-synchronizable
//   (MCP tokens stay on this Mac unless the user separately opts in) and
//   each credential is bound to the stable server identity, its network
//   origin (scheme/host/port) AND its authentication method/header
//   identity, so editing an endpoint or switching the auth scheme never
//   silently reuses an old secret for a new destination. Read and removal
//   failures propagate except a confirmed itemNotFound.

import Foundation
import FloeCore
import FloeSecurity
import FloeTools

// MARK: - Snapshot

/// Versioned on-disk document for the configured connectors. `version` lets
/// future schema changes migrate deterministically.
public struct MacWorkbenchConnectorSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var servers: [MacWorkbenchConnectorConfiguration]

    public init(version: Int = Self.currentVersion,
                servers: [MacWorkbenchConnectorConfiguration]) {
        self.version = version
        self.servers = servers
    }
}

// MARK: - Store seam

/// The coordinator satisfies this with its settings persistence; the default
/// file store below is a non-conflicting JSON file owned by this workbench
/// (it touches no existing database or Keychain item beyond the connector
/// credential service below).
public protocol MacWorkbenchConnectorStore: Sendable {
    func load() async throws -> MacWorkbenchConnectorSnapshot
    func save(_ snapshot: MacWorkbenchConnectorSnapshot) async throws
}

public enum MacWorkbenchConnectorStoreError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(found: Int, supported: Int)
    case decodeFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let found, let supported):
            "These connector settings were written by a newer version (v\(found), supported v\(supported)). Update Floe Agent to keep using them."
        case .decodeFailed:
            "The saved connector settings could not be read and were left unchanged."
        }
    }
}

/// Atomic JSON persistence in Application Support. The write is staged and
/// moved so a crash mid-write cannot truncate the previous value. Loading
/// understands both the current snapshot document and the historical
/// single-server document, so an existing configuration migrates without
/// loss on first launch.
public struct MacWorkbenchFileConnectorStore: MacWorkbenchConnectorStore {
    private let url: URL

    public init(url: URL) { self.url = url }

    public static func `default`() -> MacWorkbenchFileConnectorStore {
        MacWorkbenchFileConnectorStore(url: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FloeMacWorkbench", isDirectory: true)
            .appendingPathComponent("mcp-connector.json"))
    }

    public func load() async throws -> MacWorkbenchConnectorSnapshot {
        try Task.checkCancellation()
        // A missing file means "never configured". Permission and other I/O
        // failures propagate so a later save cannot silently replace a
        // document we failed to read.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return MacWorkbenchConnectorSnapshot(servers: [])
        }
        let decoder = JSONDecoder()
        if let snapshot = try? decoder.decode(MacWorkbenchConnectorSnapshot.self, from: data) {
            guard snapshot.version <= MacWorkbenchConnectorSnapshot.currentVersion else {
                throw MacWorkbenchConnectorStoreError.unsupportedVersion(
                    found: snapshot.version,
                    supported: MacWorkbenchConnectorSnapshot.currentVersion)
            }
            try Task.checkCancellation()
            return snapshot.normalized()
        }
        // Legacy single-server document: migrate without dropping data. The
        // file itself is left untouched until the first successful save.
        if let legacy = try? decoder.decode(MacWorkbenchConnectorConfiguration.self, from: data) {
            try Task.checkCancellation()
            return MacWorkbenchConnectorSnapshot(servers: [legacy])
        }
        // Neither format decoded: report the failure instead of pretending
        // the document is empty — an empty snapshot would overwrite the
        // user's saved connectors on the next save.
        throw MacWorkbenchConnectorStoreError.decodeFailed
    }

    public func save(_ snapshot: MacWorkbenchConnectorSnapshot) async throws {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot.normalized())
        try data.write(to: url, options: .atomic)
    }
}

extension MacWorkbenchConnectorSnapshot {
    /// Deduplicate by server id (the stored order is authoritative, first
    /// occurrence kept) and pin the current version so later readers see a
    /// stable document.
    fileprivate func normalized() -> MacWorkbenchConnectorSnapshot {
        var seen = Set<UUID>()
        let unique = servers.filter { seen.insert($0.server.id).inserted }
        return MacWorkbenchConnectorSnapshot(version: Self.currentVersion, servers: unique)
    }
}

// MARK: - Credential store

/// Secret storage seam for connector credentials. Values are raw credential
/// strings (bearer tokens or custom-header values); implementations must
/// never log or copy them into persistent documents. Read/removal failures
/// propagate except a confirmed itemNotFound.
public protocol MacWorkbenchConnectorCredentialStore: Sendable {
    func store(credential: String, for server: MCPServerConfiguration) async throws
    func credential(for server: MCPServerConfiguration) async throws -> String?
    func hasCredential(for server: MCPServerConfiguration) async throws -> Bool
    func delete(for server: MCPServerConfiguration) async throws
}

/// Production credential store backed by the macOS Keychain. Items are
/// device-only and non-synchronizable: MCP tokens remain on this Mac. The
/// account is bound to the server id, the endpoint origin, and the
/// authentication method/header identity, mirroring and extending the iPad
/// `MCPSettingsCenter.credentialAccount` design: editing an endpoint or
/// changing the auth scheme requires a credential stored for the new binding
/// instead of silently reusing the old secret. Secrets never appear in logs.
public struct MacWorkbenchKeychainCredentialStore: MacWorkbenchConnectorCredentialStore {
    public static let service = "org.floeagent.mac.mcp"

    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore(
        service: Self.service,
        synchronizable: false,
        accessibility: .whenUnlockedThisDeviceOnly
    )) {
        self.keychain = keychain
    }

    public func store(credential: String, for server: MCPServerConfiguration) async throws {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacWorkbenchConnectorError.invalidConfiguration("The credential is empty.")
        }
        guard trimmed.utf8.count <= MCPRemoteClient.maximumCredentialBytes,
              !trimmed.contains("\r"), !trimmed.contains("\n") else {
            throw MacWorkbenchConnectorError.invalidConfiguration("The credential value is invalid.")
        }
        try keychain.store(account: Self.account(for: server), secret: Data(trimmed.utf8))
    }

    public func credential(for server: MCPServerConfiguration) async throws -> String? {
        do {
            let data = try keychain.read(account: Self.account(for: server))
            return String(decoding: data, as: UTF8.self)
        } catch KeychainStoreError.itemNotFound {
            return nil
        }
    }

    public func hasCredential(for server: MCPServerConfiguration) async throws -> Bool {
        try await credential(for: server) != nil
    }

    public func delete(for server: MCPServerConfiguration) async throws {
        do {
            try keychain.delete(account: Self.account(for: server))
        } catch KeychainStoreError.itemNotFound {
            return
        }
        // Best-effort legacy cleanup; a missing legacy item is not an error.
        try? keychain.delete(account: Self.legacyAccount(for: server.id))
    }

    /// Bind secret lookup to the stable server identity, its network origin,
    /// and its authentication method/header identity. Editing or replacing
    /// any of them therefore requires a credential stored for the new
    /// binding instead of silently sending the old secret along.
    public static func account(for server: MCPServerConfiguration) -> String {
        let scheme = server.endpoint.scheme?.lowercased() ?? "https"
        let host = server.endpoint.host?.lowercased() ?? "invalid"
        let port = server.endpoint.port ?? (scheme == "https" ? 443 : 80)
        let auth = server.authentication.rawValue
        let header: String
        switch server.authentication {
        case .customHeader:
            let name = server.credentialHeaderName.trimmingCharacters(in: .whitespaces).lowercased()
            header = "." + String(FloeDigest.sha256Hex(Data(name.utf8)).prefix(16))
        case .none, .bearerToken:
            header = ""
        }
        return "mcp.\(server.id.uuidString).\(scheme).\(host).\(port).\(auth)\(header)"
    }

    /// Historical spelling used ONLY to remove stale items from older builds.
    public static func legacyAccount(for serverID: UUID) -> String {
        "mcp.\(serverID.uuidString)"
    }
}

// MARK: - In-memory fixture store (focused tests / synthetic smoke)

/// Deterministic in-memory credential store for focused tests and the
/// built-in synthetic smoke. No Keychain access, no persistence; credentials
/// live for the store instance lifetime and are never shared.
public actor MacWorkbenchMemoryCredentialStore: MacWorkbenchConnectorCredentialStore {
    private var credentials: [String: String] = [:]

    public init() {}

    public func store(credential: String, for server: MCPServerConfiguration) async throws {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MacWorkbenchConnectorError.invalidConfiguration("The credential is empty.")
        }
        credentials[Self.key(for: server)] = trimmed
    }

    public func credential(for server: MCPServerConfiguration) async throws -> String? {
        credentials[Self.key(for: server)]
    }

    public func hasCredential(for server: MCPServerConfiguration) async throws -> Bool {
        credentials[Self.key(for: server)] != nil
    }

    public func delete(for server: MCPServerConfiguration) async throws {
        credentials.removeValue(forKey: Self.key(for: server))
    }

    private static func key(for server: MCPServerConfiguration) -> String {
        MacWorkbenchKeychainCredentialStore.account(for: server)
    }
}
