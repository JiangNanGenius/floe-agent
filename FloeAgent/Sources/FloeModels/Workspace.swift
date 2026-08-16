// FloeModels — Workspace (project) domain types.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3/§5.1: a workspace binds a
// security-scoped root bookmark, an execution target and inspector state.
// Only metadata lives here — file contents and secrets never enter the
// model layer or the database.

import Foundation

public enum WorkspaceKind: String, Sendable, Codable, CaseIterable, Hashable {
    case project
    case privateTask
}

/// Where a workspace executes: locally on-device or on a paired host.
public enum WorkspaceTarget: Sendable, Codable, Hashable {
    case local
    case host(UUID)

    /// Persisted discriminator used by `workspaces.active_target_kind`.
    public var kindName: String {
        switch self {
        case .local: return "local"
        case .host: return "host"
        }
    }

    /// Persisted host identifier, `nil` for `.local`.
    public var hostID: UUID? {
        switch self {
        case .local: return nil
        case .host(let id): return id
        }
    }

    /// Rebuilds a target from its persisted columns.
    public init(kindName: String, hostID: UUID?) {
        switch (kindName, hostID) {
        case ("host", let id?):
            self = .host(id)
        default:
            self = .local
        }
    }
}

/// Collapsible file-inspector state for a workspace. `selectedRelativePath`
/// is always relative to the workspace root; never an absolute path.
public struct InspectorState: Sendable, Codable, Hashable {
    public var isExpanded: Bool
    public var selectedRelativePath: String?

    public init(isExpanded: Bool = false, selectedRelativePath: String? = nil) {
        self.isExpanded = isExpanded
        self.selectedRelativePath = selectedRelativePath
    }

    /// Lenient decoding: the v5 schema default is `'{}'`, and synthesized
    /// Codable ignores property defaults, so missing keys must fall back
    /// explicitly rather than failing the whole workspace row.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? false
        self.selectedRelativePath = try container.decodeIfPresent(String.self, forKey: .selectedRelativePath)
    }
}

/// A persisted workspace (project). `rootBookmark` is a security-scoped
/// bookmark (BLOB at rest); `instructionsRelativePath` only stores the
/// relative path of an optional agent instruction file (e.g. `FLOE.md`) —
/// its body is read through the path guard and never persisted.
public struct WorkspaceRecord: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var rootBookmark: Data
    public var lastOpenedAt: Date?
    public var activeTarget: WorkspaceTarget
    public var inspectorState: InspectorState
    public var instructionsRelativePath: String?
    public var kind: WorkspaceKind
    public var internalRelativePath: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        rootBookmark: Data,
        lastOpenedAt: Date? = nil,
        activeTarget: WorkspaceTarget = .local,
        inspectorState: InspectorState = InspectorState(),
        instructionsRelativePath: String? = nil,
        kind: WorkspaceKind = .project,
        internalRelativePath: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rootBookmark = rootBookmark
        self.lastOpenedAt = lastOpenedAt
        self.activeTarget = activeTarget
        self.inspectorState = inspectorState
        self.instructionsRelativePath = instructionsRelativePath
        self.kind = kind
        self.internalRelativePath = internalRelativePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
