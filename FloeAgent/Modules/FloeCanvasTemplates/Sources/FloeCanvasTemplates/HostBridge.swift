import Foundation
import FloeCanvasCore
import FloeCanvasIntegration

/// Resolve from the current file/project registry, including completed moves.
/// Snapshot metadata is a portable hint, never authority over the host registry.
public protocol TemplateOwnershipResolving: Sendable {
    func ownership(for projectID: UUID) async throws -> TemplateOwnership
}

public enum TemplateReturnDestination: Hashable, Sendable {
    case canvas(UUID)
    case directory(UUID)

    public init(currentOwnership: TemplateOwnership) {
        if currentOwnership.kind == .canvas { self = .canvas(currentOwnership.ownerID) }
        else { self = .directory(currentOwnership.directoryID) }
    }
}

/// Bind these closures to the App's existing file registry and native editors.
/// There is no fallback editor, generated result, file copy or new job service.
public struct TemplateEditorHostBridge: TemplateEditorCreating, CanvasEditorGateway,
                                        CanvasEditorForkGateway, TemplateOwnershipResolving {
    public var resolve: @Sendable (UUID) async throws -> TemplateOwnership
    public var create: @Sendable (TemplateEditorCreateRequest) async throws -> CanvasEditorReference
    public var open: @Sendable (CanvasEditorReference, CanvasRuntimeContext) async throws -> Void
    public var apply: @Sendable (CanvasEditorReference, CanvasRuntimeContext) async throws -> CanvasEditorReference
    public var fork: @Sendable (CanvasEditorForkRequest) async throws -> CanvasEditorForkResult

    public init(resolve: @escaping @Sendable (UUID) async throws -> TemplateOwnership,
                create: @escaping @Sendable (TemplateEditorCreateRequest) async throws -> CanvasEditorReference,
                open: @escaping @Sendable (CanvasEditorReference, CanvasRuntimeContext) async throws -> Void,
                apply: @escaping @Sendable (CanvasEditorReference, CanvasRuntimeContext) async throws -> CanvasEditorReference,
                fork: @escaping @Sendable (CanvasEditorForkRequest) async throws -> CanvasEditorForkResult) {
        self.resolve = resolve; self.create = create; self.open = open; self.apply = apply; self.fork = fork
    }
    public func ownership(for projectID: UUID) async throws -> TemplateOwnership { try await resolve(projectID) }
    public func createEditor(_ request: TemplateEditorCreateRequest) async throws -> CanvasEditorReference {
        try await create(request)
    }
    public func openEditor(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) async throws {
        try await open(reference, context)
    }
    public func applyEditorResult(_ reference: CanvasEditorReference, context: CanvasRuntimeContext) async throws -> CanvasEditorReference {
        try await apply(reference, context)
    }
    public func forkEditor(_ request: CanvasEditorForkRequest) async throws -> CanvasEditorForkResult { try await fork(request) }
}

public enum TemplateWorkingPosition: Codable, Hashable, Sendable {
    case canvas(pageID: UUID)
    case editor(pageID: UUID, nodeID: UUID)

    public var pageID: UUID {
        switch self { case .canvas(let pageID), .editor(let pageID, _): return pageID }
    }
    public func validated(in snapshot: CanvasSnapshot) -> Self {
        guard let page = snapshot.pages.first(where: { $0.id == pageID }) else {
            return .canvas(pageID: snapshot.selectedPageID)
        }
        if case .editor(_, let nodeID) = self {
            guard let node = page.nodes.first(where: { $0.id == nodeID }),
                  case .editor = node.content else { return .canvas(pageID: page.id) }
        }
        return self
    }
}

/// View state only: moving/opening an editor does not add a document undo unit.
/// A host may use its existing scene persistence instead of this file adapter.
public actor TemplateNavigationStore {
    private let root: URL
    public init(root: URL) throws {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }
    public func save(_ position: TemplateWorkingPosition, canvasID: UUID) throws {
        try JSONEncoder().encode(position).write(to: url(canvasID), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
    public func load(canvasID: UUID) throws -> TemplateWorkingPosition? {
        let path = url(canvasID)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try Data(contentsOf: path)
        guard data.count < 4096 else { throw TemplateError.invalid("invalid working position") }
        return try JSONDecoder().decode(TemplateWorkingPosition.self, from: data)
    }
    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
}
