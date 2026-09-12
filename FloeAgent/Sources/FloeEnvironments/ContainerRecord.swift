import Foundation

/// Container kinds. Sessions are ephemeral forks, projects persist with a
/// workspace, templates are committed layer sets, shared is the cross-project
/// permanent layer.
public enum ContainerKind: String, Codable, Sendable, CaseIterable {
    case session
    case project
    case template
    case shared

    public var isWritableLayer: Bool { self == .session || self == .project }
    public var survivesOwnerDeletion: Bool { self == .template || self == .shared }
}

public enum ContainerState: String, Codable, Sendable {
    case active
    case stopped
    case deleting
}

public enum LayerKind: String, Codable, Sendable, CaseIterable {
    case base
    case shared
    case project
    case session
}

/// One container record. `ownerID` is the conversation (session) or workspace
/// (project) UUID string; templates and the shared layer have no owner.
public struct ContainerRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var kind: ContainerKind
    public var ownerID: String?
    public var name: String?
    public var baseRevision: String
    public var layerFormat: Int
    public var state: ContainerState
    public var createdAt: Date
    public var lastUsedAt: Date
    public var bytes: Int64
    public var packageCount: Int
    public var parentID: String?
    public var templateID: String?
    public var requiresRebuild: Bool
    public var rebuildReason: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: ContainerKind,
        ownerID: String? = nil,
        name: String? = nil,
        baseRevision: String,
        layerFormat: Int = ContainerRecord.currentLayerFormat,
        state: ContainerState = .active,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date(),
        bytes: Int64 = 0,
        packageCount: Int = 0,
        parentID: String? = nil,
        templateID: String? = nil,
        requiresRebuild: Bool = false,
        rebuildReason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.ownerID = ownerID
        self.name = name
        self.baseRevision = baseRevision
        self.layerFormat = layerFormat
        self.state = state
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.bytes = bytes
        self.packageCount = packageCount
        self.parentID = parentID
        self.templateID = templateID
        self.requiresRebuild = requiresRebuild
        self.rebuildReason = rebuildReason
    }

    public static let currentLayerFormat = 1

    public func isCompatible(withLayerFormat format: Int) -> Bool {
        format == Self.currentLayerFormat || format == Self.currentLayerFormat - 1
    }
}

/// One installed package inside a container layer. Written into the layer's
/// dpkg shard; promoted entries are copied to the target layer.
public struct InstalledPackage: Codable, Sendable, Hashable {
    public var name: String
    public var version: String
    public var architecture: String
    public var layer: LayerKind
    public var installState: String
    public var summary: String?
    public var license: String?
    public var source: String?
    public var requiresBase: String?
    public var depends: String?
    public var preDepends: String?
    public var files: [String]

    public init(
        name: String,
        version: String,
        architecture: String = "all",
        layer: LayerKind,
        installState: String = "installed",
        summary: String? = nil,
        license: String? = nil,
        source: String? = nil,
        requiresBase: String? = nil,
        files: [String] = [],
        depends: String? = nil,
        preDepends: String? = nil
    ) {
        self.name = name
        self.version = version
        self.architecture = architecture
        self.layer = layer
        self.installState = installState
        self.summary = summary
        self.license = license
        self.source = source
        self.requiresBase = requiresBase
        self.depends = depends
        self.preDepends = preDepends
        self.files = files
    }
}

public struct EnvironmentQuota: Codable, Sendable {
    public var sessionBytes: Int64
    public var sharedBytes: Int64
    public var totalBytes: Int64

    public init(sessionBytes: Int64 = 2 * 1024 * 1024 * 1024,
                sharedBytes: Int64 = 5 * 1024 * 1024 * 1024,
                totalBytes: Int64 = 10 * 1024 * 1024 * 1024) {
        self.sessionBytes = sessionBytes
        self.sharedBytes = sharedBytes
        self.totalBytes = totalBytes
    }

    public static let `default` = EnvironmentQuota()
}
