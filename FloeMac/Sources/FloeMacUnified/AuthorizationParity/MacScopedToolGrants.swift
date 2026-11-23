// SPDX-License-Identifier: MPL-2.0
//
// Persisted, narrowly scoped tool grants for the Floe Mac workbench — the
// tool counterpart of the existing per-file approval grants
// (`FloeMacSelfApprovalGrants`). A tool grant binds ALL of the following,
// so a remembered approval can never authorize a different remote operation:
//
// - the EXACT tool name (no path material — tools, not files),
// - the descriptor authorization identity, so replacing a dynamic runner
//   under the same name cannot inherit old authority,
// - the normalized endpoint digest + configured authentication digest of
//   the server the tool belongs to (from
//   `MacWorkbenchConnectorToolBinding`),
// - the SHA-256 digest of the exact approved `ToolCall.argumentsJSON`
//   (raw arguments NEVER enter the grant store),
// - ONE task (conversation id) or ONE project workspace (nil conversation).
//
// Grants are rows in the SAME runtime-owned `approval_grants` table behind
// the existing workspace store, tagged with their own policy namespace, so
// revocation, listing and the durability guarantees reuse the shared store
// instead of a parallel authority system. Only the human-approval path can
// consume them (see `MacScopedToolGrantPolicy`): automatic/full-access
// policies stay fully authoritative, the catastrophic gate still runs
// first, and a child subagent inherits the run policy like every other
// approval decision.

import Foundation
import FloeAgentRuntime
import FloeCore
import FloeMacSelfCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools

// MARK: - Scope

/// Persisted tool-grant scope. `.task` binds one conversation; `.project`
/// binds the whole project workspace (any of its tasks).
public enum MacScopedToolGrantScope: Sendable, Hashable {
    case task
    case project
}

// MARK: - Display model

public struct MacScopedToolGrant: Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    /// nil means the whole project workspace.
    public let conversationID: UUID?
    public let toolName: String
    /// The full opaque binding composite (descriptor + endpoint + auth +
    /// arguments digests). Never carries raw arguments or secrets.
    public let bindingIdentity: String
    public let argumentsDigest: String
    public let decidedAt: Date

    public init(id: UUID, workspaceID: UUID, conversationID: UUID?, toolName: String,
                bindingIdentity: String, argumentsDigest: String, decidedAt: Date) {
        self.id = id
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.toolName = toolName
        self.bindingIdentity = bindingIdentity
        self.argumentsDigest = argumentsDigest
        self.decidedAt = decidedAt
    }
}

// MARK: - Persistence seam

/// The narrow store seam the grants manager needs. The coordinator adapts
/// the EXISTING runtime-owned `SQLiteWorkspaceStore` (the same instance
/// `FloeMacSelfApprovalGrants` composes) — no second database or schema.
public protocol MacScopedToolGrantPersistence: Sendable {
    func allGrants() async throws -> [StoredGrant]
    func saveGrant(_ grant: StoredGrant) async throws
    func deleteGrant(id: UUID) async throws
}

/// Adapter over the shared `SQLiteWorkspaceStore`.
public struct MacSQLiteScopedToolGrantPersistence: MacScopedToolGrantPersistence {
    private let store: SQLiteWorkspaceStore

    public init(_ store: SQLiteWorkspaceStore) { self.store = store }

    public func allGrants() async throws -> [StoredGrant] { try await store.allGrants() }
    public func saveGrant(_ grant: StoredGrant) async throws { try await store.saveGrant(grant) }
    public func deleteGrant(id: UUID) async throws { try await store.deleteGrant(id: id) }
}

// MARK: - Manager

/// Persisted tool-grant manager. Rows are tagged with the
/// `floe.mac.tool-grant.v1.` policy namespace and never collide with the
/// file-grant namespace in the same table. The binding digest is carried in
/// the shared `authorizationIdentity` column as a composite of the
/// descriptor identity, endpoint digest, authentication digest and arguments
/// digest, so every binding component participates in both matching and the
/// deterministic row id.
public actor MacScopedToolGrants {
    public static let namespace = "floe.mac.tool-grant.v1."

    /// Shared instance for the app composition root. The coordinator sets
    /// `persistence` once at launch with the runtime-owned store adapter;
    /// focused tests inject their own in-memory store per instance.
    public static let shared = MacScopedToolGrants()

    public var persistence: (any MacScopedToolGrantPersistence)?

    public init(persistence: (any MacScopedToolGrantPersistence)? = nil) {
        self.persistence = persistence
    }

    /// Test-only seam replacing the shared instance's persistence; the app
    /// sets `persistence` once at launch and never swaps it.
    public func setPersistenceForParityTests(_ persistence: (any MacScopedToolGrantPersistence)?) {
        self.persistence = persistence
    }

    /// Which tools may be remembered at all: file-write tools keep their
    /// dedicated file-grant path (with path scoping); delegation and output
    /// publication are per-decision authorities and are never remembered.
    public nonisolated static func canRemember(toolName: String) -> Bool {
        !FloeMacSelfApprovalGrants.canRemember(toolName: toolName)
            && toolName != DelegateTool.name
            && toolName != WorkspaceOutputPublication.name
            && !toolName.isEmpty
            && toolName.utf8.count <= 128
    }

    /// Builds the composite binding stored in `authorizationIdentity`.
    public nonisolated static func compositeIdentity(descriptorIdentity: String,
                                                       endpointDigest: String,
                                                       authenticationDigest: String,
                                                       argumentsDigest: String) -> String {
        "descriptor=\(descriptorIdentity);endpoint=\(endpointDigest);auth=\(authenticationDigest);args=\(argumentsDigest)"
    }

    public func list(workspaceID: UUID? = nil) async throws -> [MacScopedToolGrant] {
        guard let persistence else { return [] }
        let rows = try await persistence.allGrants()
        return rows.compactMap { row in
            guard row.policyName.hasPrefix(Self.namespace),
                  row.authorizationIdentity != nil,
                  let owner = row.workspaceID,
                  workspaceID == nil || workspaceID == owner,
                  row.hostID == nil,
                  row.paths.isEmpty,
                  !row.singleUse else { return nil }
            return MacScopedToolGrant(
                id: row.id, workspaceID: owner,
                conversationID: row.conversationID,
                toolName: row.toolName,
                bindingIdentity: row.authorizationIdentity ?? "",
                argumentsDigest: Self.argumentsDigest(fromComposite: row.authorizationIdentity) ?? "",
                decidedAt: row.decidedAt)
        }
        .sorted { $0.decidedAt > $1.decidedAt }
    }

    public func revoke(id: UUID) async throws {
        guard let persistence else { return }
        let known = try await list().contains { $0.id == id }
        guard known else { return }
        try await persistence.deleteGrant(id: id)
    }

    /// Revoke every persisted grant for one tool name (used when the tool's
    /// server is disabled/removed so stale authority cannot survive).
    public func revokeAll(toolName: String) async throws {
        guard let persistence else { return }
        let ids = try await list().filter { $0.toolName == toolName }.map(\.id)
        for id in ids {
            try await persistence.deleteGrant(id: id)
        }
    }

    /// Revoke every persisted grant whose tool name lives in one server's
    /// exact id-derived namespace — including grants written before the
    /// current launch ever discovered the server.
    public func revokeAll(toolNamePrefix: String) async throws {
        guard let persistence else { return }
        let ids = try await list().filter { $0.toolName.hasPrefix(toolNamePrefix) }.map(\.id)
        for id in ids {
            try await persistence.deleteGrant(id: id)
        }
    }

    public func remember(scope: MacScopedToolGrantScope, workspaceID: UUID, conversationID: UUID,
                         toolName: String, descriptorIdentity: String,
                         endpointDigest: String, authenticationDigest: String,
                         argumentsDigest: String) async throws {
        guard Self.canRemember(toolName: toolName), !descriptorIdentity.isEmpty else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard let persistence else { throw CocoaError(.fileWriteNoPermission) }
        let owner = scope == .task ? conversationID : nil
        let composite = Self.compositeIdentity(descriptorIdentity: descriptorIdentity,
                                               endpointDigest: endpointDigest,
                                               authenticationDigest: authenticationDigest,
                                               argumentsDigest: argumentsDigest)
        // A repeated approval or a concurrent click is one row for the same
        // operation: derive a deterministic id from the binding material.
        let key = [Self.namespace, workspaceID.uuidString, owner?.uuidString ?? "", toolName, composite]
        let hash = FloeDigest.sha256Hex(try JSONEncoder().encode(key))
        let rawID = String(hash.prefix(32))
        let identifier = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(rawID.dropFirst(range.lowerBound).prefix(range.count))
        }.joined(separator: "-")
        guard let id = UUID(uuidString: identifier) else { throw CocoaError(.fileWriteUnknown) }
        try await persistence.saveGrant(.init(
            id: id, workspaceID: workspaceID, toolName: toolName, paths: [],
            singleUse: false, policyName: Self.namespace + "binding",
            conversationID: owner, authorizationIdentity: composite))
    }

    /// True when a persisted grant exactly covers this local-native action:
    /// same tool, same full binding composite, same workspace, and either the
    /// same task or a project-wide grant.
    public func matches(toolName: String, workspaceID: UUID, conversationID: UUID,
                        descriptorIdentity: String, endpointDigest: String,
                        authenticationDigest: String, argumentsDigest: String) async throws -> Bool {
        guard !descriptorIdentity.isEmpty else { return false }
        let composite = Self.compositeIdentity(descriptorIdentity: descriptorIdentity,
                                               endpointDigest: endpointDigest,
                                               authenticationDigest: authenticationDigest,
                                               argumentsDigest: argumentsDigest)
        let rows = try await list(workspaceID: workspaceID)
        return rows.contains {
            $0.toolName == toolName && $0.bindingIdentity == composite
                && ($0.conversationID == conversationID || $0.conversationID == nil)
        }
    }

    static func argumentsDigest(fromComposite composite: String?) -> String? {
        composite?.split(separator: ";").first { $0.hasPrefix("args=") }
            .map { String($0.dropFirst("args=".count)) }
    }
}
