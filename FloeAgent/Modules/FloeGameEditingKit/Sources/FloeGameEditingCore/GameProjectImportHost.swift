// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Host hook for importing external project/game files (including archives)
/// into an EXISTING project. The editing component never unpacks archives
/// itself and never turns a ZIP into a raw asset: the host (BuildKit pipeline
/// or App adapter) owns unpacking, bounded IO off the MainActor, cancellation
/// and ownership checks against the existing project ID/revision.
public struct GameProjectImportRequest: Sendable {
    public var projectID: UUID
    public var owner: GameProjectOwner
    /// Revision the import starts from; hosts must keep the repository's
    /// expected-revision conflict semantics.
    public var baseRevision: String
    public var sources: [URL]

    public init(projectID: UUID, owner: GameProjectOwner, baseRevision: String, sources: [URL]) {
        self.projectID = projectID; self.owner = owner
        self.baseRevision = baseRevision; self.sources = sources
    }
}

public protocol GameProjectImportHost: Sendable {
    /// Imports the given files/archives into the project, returning
    /// diagnostics for anything skipped or degraded. Throwing leaves the
    /// project untouched.
    func importProjectContents(_ request: GameProjectImportRequest) async throws -> [GameEditDiagnostic]
}

/// Bounded, non-MainActor byte loading for the "Add Asset" flow. Unreadable
/// or oversized selections throw; callers must surface the error instead of
/// silently skipping the selection.
public enum GameAssetByteLoader {
    public static let defaultLimit = 64 * 1_024 * 1_024

    public static func load(_ url: URL, limit: Int = defaultLimit) async throws -> Data {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= limit else {
            throw GameProjectError.limitExceeded(url.lastPathComponent)
        }
        return data
    }
}
