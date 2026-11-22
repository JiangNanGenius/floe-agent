// SPDX-License-Identifier: MPL-2.0

import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity

public enum FloeMacFileGrantScope: Hashable, Sendable { case task, workspace }

public struct FloeMacFileGrant: Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let conversationID: UUID?
    public let toolName: String
    public let path: String
    public let decidedAt: Date
}

public actor FloeMacSelfApprovalGrants {
    private let store: SQLiteWorkspaceStore
    private static let namespace = "floe.mac.file-grant.v1."
    private static let tools: Set<String> = [
        "workspace.createFile", "workspace.replaceText", "workspace.writeFile",
        "workspace.appendFile", "workspace.applyPatch", "workspace.createDirectory",
    ]

    public nonisolated static func canRemember(toolName: String) -> Bool {
        tools.contains(toolName)
    }

    public init(store: SQLiteWorkspaceStore) { self.store = store }

    public func list(workspaceID: UUID? = nil) async throws -> [FloeMacFileGrant] {
        try await store.allGrants().compactMap { row in
            guard row.policyName.hasPrefix(Self.namespace), row.authorizationIdentity != nil,
                  let owner = row.workspaceID, workspaceID == nil || workspaceID == owner,
                  row.hostID == nil, row.paths.count == 1, let path = row.paths.first,
                  Self.tools.contains(row.toolName), !row.singleUse else { return nil }
            return FloeMacFileGrant(id: row.id, workspaceID: owner, conversationID: row.conversationID,
                                    toolName: row.toolName, path: path, decidedAt: row.decidedAt)
        }
    }

    public func revoke(id: UUID) async throws {
        guard try await list().contains(where: { $0.id == id }) else { return }
        try await store.deleteGrant(id: id)
    }

    public func remember(scope: FloeMacFileGrantScope, workspaceID: UUID, conversationID: UUID,
                         toolName: String, path: String, authorizationIdentity: String, workspaceRoot: URL) async throws {
        guard Self.tools.contains(toolName), !authorizationIdentity.isEmpty, Self.validPath(path),
              try await store.workspaceID(conversationID: conversationID) == workspaceID,
              let workspace = try await store.workspace(id: workspaceID),
              scope == .task || workspace.kind == .project,
              let binding = try workspaceBinding(workspace, root: workspaceRoot) else { throw CocoaError(.fileWriteNoPermission) }
        let owner = scope == .task ? conversationID : nil
        // A repeated approval or a concurrent click is one row for the same operation.
        let key = [binding, workspaceID.uuidString, owner?.uuidString ?? "", toolName, path, authorizationIdentity]
        let hash = FloeDigest.sha256Hex(try JSONEncoder().encode(key))
        let rawID = String(hash.prefix(32))
        let identifier = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(rawID.dropFirst(range.lowerBound).prefix(range.count))
        }.joined(separator: "-")
        guard let id = UUID(uuidString: identifier) else { throw CocoaError(.fileWriteUnknown) }
        try await store.saveGrant(.init(id: id, workspaceID: workspaceID, toolName: toolName, paths: [path],
            singleUse: false, policyName: binding, conversationID: owner, authorizationIdentity: authorizationIdentity))
    }

    private func workspaceBinding(_ workspace: WorkspaceRecord, root: URL) throws -> String? {
        if workspace.kind == .privateTask {
            let folder = root.deletingLastPathComponent().lastPathComponent + "/" + root.lastPathComponent
            guard let internalPath = workspace.internalRelativePath, internalPath == folder, folder.hasPrefix("PrivateTasks/") else {
                return nil
            }
            return Self.namespace + FloeDigest.sha256Hex(Data((workspace.id.uuidString + "\n" + root.standardizedFileURL.path).utf8))
        }
        guard workspace.kind == .project else { return nil }
        var stale = false
        let resolved = try URL(resolvingBookmarkData: workspace.rootBookmark, options: [.withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale, resolved.resolvingSymlinksInPath().standardizedFileURL.path == root.standardizedFileURL.path else { return nil }
        return Self.namespace + FloeDigest.sha256Hex(workspace.rootBookmark)
    }

    private static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("~") && !path.contains("\\")
            && !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            && !path.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) })
    }

    fileprivate func matches(_ action: ProposedAction, workspaceID: UUID, conversationID: UUID,
                             root: URL, identities: [String: String]) async throws -> Bool {
        let call = action.toolCall
        guard Self.tools.contains(call.toolName), action.riskLabels.contains("writesFiles"),
              action.riskLabels.isSubset(of: ["readsFiles", "writesFiles"]),
              case .local = call.scope, case .local = action.hostAndPathScope,
              let context = action.trustedContext, context.environmentClass == .localNative,
              context.workspaceRootPath == root.standardizedFileURL.path,
              let identity = identities[call.toolName], !identity.isEmpty,
              let args = try JSONSerialization.jsonObject(with: call.argumentsJSON) as? [String: Any],
              let path = args["path"] as? String, Self.validPath(path),
              try await store.workspaceID(conversationID: conversationID) == workspaceID,
              let workspace = try await store.workspace(id: workspaceID),
              let binding = try workspaceBinding(workspace, root: root) else { return false }
        return try await store.fileApprovalGrants(workspaceID: workspaceID, toolName: call.toolName).contains {
            $0.policyName == binding && !$0.singleUse && $0.authorizationIdentity == identity &&
                ($0.conversationID == conversationID || (workspace.kind == .project && $0.conversationID == nil)) &&
                $0.paths.count == 1 && $0.paths.first?.utf8.elementsEqual(path.utf8) == true
        }
    }

    public nonisolated func wrapping(_ base: any ApprovalPolicy, workspaceID: UUID, conversationID: UUID,
                                     workspaceRoot: URL, authorizationIdentities: [String: String]) -> any ApprovalPolicy {
        FileGrantPolicy(base: base, grants: self, workspaceID: workspaceID, conversationID: conversationID,
                        root: workspaceRoot, identities: authorizationIdentities)
    }
}

private struct FileGrantPolicy: ApprovalPolicy, ApprovalReviewRouting {
    let base: any ApprovalPolicy
    let grants: FloeMacSelfApprovalGrants
    let workspaceID: UUID
    let conversationID: UUID
    let root: URL
    let identities: [String: String]
    var policyName: String { base.policyName }

    func requiresModelReview(_ action: ProposedAction) -> Bool {
        (base as? any ApprovalReviewRouting)?.requiresModelReview(action) ?? false
    }

    func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        let decision = try await base.decide(action)
        guard base is HumanApprovalPolicy, case .escalateToHuman = decision,
              (try? await grants.matches(action, workspaceID: workspaceID, conversationID: conversationID,
                                         root: root, identities: identities)) == true else { return decision }
        return .allow(scope: ApprovalScope(toolName: action.toolCall.toolName, singleUse: true), expiresAt: nil)
    }
}
