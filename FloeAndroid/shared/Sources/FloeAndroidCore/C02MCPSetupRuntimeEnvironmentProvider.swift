// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeEnvironments

/// Metadata stays in the runtime process's original registry. Project roots
/// come from C01, and every lookup re-reads the authenticated runtime catalog.
public struct C02MCPSetupRuntimeEnvironmentProvider: C02MCPSetupEnvironmentListing,
    C02MCPSetupEnvironmentProviding {
    private let epoch: UInt64
    public init(epoch: UInt64) { self.epoch = epoch }

    // The runtime uses hashed runtime-workspace owners. A context-free lookup
    // cannot prove the corresponding Core project; do not guess or cache it.
    public func environment(id: String) async -> C02MCPSetupEnvironmentFacts? { nil }
    public func environments(ownerID: String) async -> [C02MCPSetupEnvironmentFacts] { [] }

    public func environment(id: String, project: C02MCPSetupProject) async -> C02MCPSetupEnvironmentFacts? {
        await environments(project: project).first { $0.id == id }
    }

    public func environments(project: C02MCPSetupProject) async -> [C02MCPSetupEnvironmentFacts] {
        guard G02NativeRootEpoch.readback() == epoch,
              C01ProjectRootLayout.inspectProjectDirectory(
                  rootPath: project.rootURL.path, projectID: project.id) == .available,
              let rows = try? await C02RuntimeEnvironmentCatalog.read(
                  workspaceRoot: project.rootURL, epoch: epoch) else { return [] }
        let owner = C02MCPSetupWorkspaceStager.projectRootIdentity(project.rootURL)
        return rows.compactMap { row in
            guard row.kind == "project", row.state == "active", !row.requiresRebuild,
                  let backend = row.executionBackend,
                  backend == EnvironmentExecutionBackend.linuxPRoot.rawValue,
                  let format = row.layerFormat,
                  format == ContainerRecord.currentLayerFormat ||
                    format == ContainerRecord.currentLayerFormat - 1 else { return nil }
            return C02MCPSetupEnvironmentFacts(id: row.id, label: row.name ?? row.id,
                kind: row.kind, ownerID: owner, state: row.state,
                requiresRebuild: row.requiresRebuild, backend: backend,
                containerID: row.id, baseRevision: row.baseRevision, layerFormat: format)
        }
    }
}
