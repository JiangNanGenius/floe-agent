// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeAndroidShellTools

/// Read-only metadata from the authenticated runtime peer. No cached schedule
/// snapshot, synthetic environment or cross-project fallback is used here.
public enum C02RuntimeEnvironmentCatalog {
    public struct Row: Decodable, Sendable {
        public let id: String
        public let kind: String
        public let ownerID: String?
        public let name: String?
        public let state: String
        public let baseRevision: String
        public let requiresRebuild: Bool
        public let executionBackend: String?
        public let parentID: String?
        public let layerFormat: Int?

        public func targetFacts(projectOwner: String) -> C02LocalEnvironmentFacts {
            C02LocalEnvironmentFacts(id: id, name: name, kind: kind, state: state,
                requiresRebuild: requiresRebuild, executionBackend: executionBackend,
                ownerID: kind == "project" ? projectOwner : ownerID)
        }
    }
    private struct Reply: Decodable {
        let phase: String
        let projectID: UUID
        let workspaceOwnerID: String
        let environments: [Row]
    }

    public static func read(ownership: C02TargetOwnership) async throws -> [Row] {
        guard ownership.rootEpoch > 0,
              G02NativeRootEpoch.readback() == ownership.rootEpoch else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        let projectID = LinuxShellProjectMapping.projectID(
            forCanonicalCoreWorkspaceRoot: ownership.workspaceRoot)
        let payload = try JSONSerialization.data(withJSONObject: [
            "action": "catalog", "epoch": ownership.rootEpoch,
            "projectID": projectID.uuidString
        ], options: [.sortedKeys])
        let bytes = try await LinuxShellMailbox.shared.submit(
            operation: C01LinuxEnvironmentMailboxHost.operation,
            payload: payload, timeoutMillis: 15_000)
        guard bytes.count <= 65_536,
              G02NativeRootEpoch.readback() == ownership.rootEpoch else {
            throw C02ExecutionTargetError.rootEpochUnavailable
        }
        return try decode(bytes, projectID: projectID)
    }

    static func decode(_ bytes: Data, projectID: UUID) throws -> [Row] {
        guard bytes.count <= 65_536 else {
            throw C02ExecutionTargetError.environmentUnavailable("catalog")
        }
        let reply = try JSONDecoder().decode(Reply.self, from: bytes)
        guard reply.phase == "ready", reply.projectID == projectID,
              reply.workspaceOwnerID.count == 64,
              reply.workspaceOwnerID.allSatisfy({ $0.isHexDigit }),
              reply.environments.count <= 2048 else {
            throw C02ExecutionTargetError.environmentUnavailable("catalog")
        }
        let projects = reply.environments.filter { $0.kind == "project" }
        let ids = Set(reply.environments.map(\.id))
        guard projects.count <= 1, ids.count == reply.environments.count,
              projects.allSatisfy({ $0.ownerID == reply.workspaceOwnerID }),
              reply.environments.allSatisfy({ row in
                  !row.id.isEmpty && row.id.utf8.count <= 128 &&
                  (row.kind == "project" || (row.kind == "session" &&
                   row.parentID == projects.first?.id && !projects.isEmpty))
              }) else {
            throw C02ExecutionTargetError.environmentUnavailable("catalog")
        }
        return reply.environments
    }
}
