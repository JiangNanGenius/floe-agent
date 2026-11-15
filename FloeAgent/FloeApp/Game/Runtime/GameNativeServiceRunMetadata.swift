// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

/// Non-Codable execution identity for a host-only archive import. It is built
/// only from a real saved `RunRecord` (never a random UUID) and carries the
/// exact conversation/binding generation when the game has an environment.
struct GameArchiveRunAuthority: Sendable, Equatable {
    let runID: UUID
    let conversationID: UUID
    let environmentID: String?
    let executionBindingGeneration: Int64?
}

/// Durable provenance attached to a native game-service run. It is a status
/// event payload, not a tool grant and not model output. It deliberately uses
/// a different target tool from `NativeServiceRunMetadata` (`exec.localService`)
/// so the existing standalone-service matcher never mistakes a game build or
/// import for an exec.localService shell job.
struct GameNativeServiceRunMetadata: Codable, Sendable, Equatable {
    let activity: String
    let version: Int
    let source: String
    let runID: UUID
    let conversationID: UUID
    let targetTool: String
    /// Exact project/workspace identity captured by the trusted host. A marker
    /// with nil or mismatched identity never classifies a run as native.
    let projectID: UUID?
    let workspaceRootPath: String?

    init(runID: UUID, conversationID: UUID, targetTool: String,
         projectID: UUID? = nil, workspaceRootPath: String? = nil) {
        self.activity = "gameProjectService"
        self.version = 1
        self.source = "nativeService"
        self.runID = runID
        self.conversationID = conversationID
        self.targetTool = targetTool
        self.projectID = projectID
        self.workspaceRootPath = workspaceRootPath
    }

    func payloadJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
#endif
