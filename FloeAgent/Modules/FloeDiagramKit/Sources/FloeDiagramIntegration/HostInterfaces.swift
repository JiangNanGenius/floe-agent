// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeDiagramCore

public protocol DiagramAssetResolver: Sendable {
    func data(for asset: DiagramAsset) async throws -> Data
}
public protocol DiagramAssetStore: DiagramAssetResolver {
    func store(_ data: Data, fileName: String, mediaType: String) async throws -> DiagramAsset
}
public actor FileDiagramAssets: DiagramAssetStore {
    public let directory: URL
    public init(directory: URL) throws {
        guard directory.isFileURL, directory.path.hasPrefix("/") else { throw DiagramError.invalid("explicit asset directory required") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let values = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard values[.type] as? FileAttributeType == .typeDirectory else { throw DiagramError.invalid("asset directory") }
        self.directory = directory
    }
    public func store(_ data: Data, fileName: String, mediaType: String) throws -> DiagramAsset {
        guard data.count <= 64*1_024*1_024 else { throw DiagramError.invalid("asset size") }
        let asset = DiagramAsset(fileName: fileName, mediaType: mediaType, byteCount: data.count, sha256: DiagramCodec.digest(data))
        let test = DiagramDocument(assets: [asset]); try test.validate()
        try DiagramAtomicFile.write(data, to: directory.appendingPathComponent(asset.id.uuidString)); return asset
    }
    public func data(for asset: DiagramAsset) throws -> Data {
        let url = directory.appendingPathComponent(asset.id.uuidString)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue == asset.byteCount, asset.byteCount <= 64*1_024*1_024 else { throw DiagramError.invalid("asset file") }
        let bytes = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard asset.sha256.map({ DiagramCodec.digest(bytes) == $0 }) ?? true else { throw DiagramError.invalid("asset digest") }
        return bytes
    }
    /// Imports preserve stable resource identities. Bytes are verified before publication into the store.
    public func importAsset(_ asset: DiagramAsset, data: Data) throws {
        guard data.count == asset.byteCount, asset.sha256.map({ DiagramCodec.digest(data) == $0 }) ?? true else { throw DiagramError.invalid("asset import integrity") }
        let url = directory.appendingPathComponent(asset.id.uuidString)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try self.data(for: asset) == data else { throw DiagramError.invalid("resource identity collision") }; return
        }
        try DiagramAtomicFile.write(data, to: url)
    }
}
public struct DiagramExecutionRequest: Codable, Hashable, Sendable {
    public enum Intent: String, Codable, Sendable { case start, stop }
    public var documentID: UUID
    public var revision: Int
    public var pageID: UUID?
    public var elementIDs: Set<UUID>
    public var taskIDs: Set<UUID>
    public var userInstruction: String
    public var intent: Intent
    public init(document: DiagramDocument, pageID: UUID? = nil, elementIDs: Set<UUID> = [],
                taskIDs: Set<UUID> = [], userInstruction: String, intent: Intent = .start) throws {
        guard !userInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DiagramError.invalid("explicit user instruction required") }
        guard elementIDs.isSubset(of: Set(document.pages.flatMap(\.elements).map(\.id))), taskIDs.isSubset(of: Set(document.tasks.map(\.id))) else { throw DiagramError.invalid("execution selection") }
        self.documentID = document.id; revision = document.revision; self.pageID = pageID
        self.elementIDs = elementIDs; self.taskIDs = taskIDs; self.userInstruction = userInstruction; self.intent = intent
    }
}
/// The host supplies existing Floe services. Documents and model output cannot construct new authority.
public struct DiagramHostCallbacks: Sendable {
    public var openSource: (@Sendable (DiagramSourceReference) async throws -> Void)?
    public var execute: (@Sendable (DiagramExecutionRequest) async throws -> Void)?
    public var askAssistant: (@Sendable (DiagramAssistantRequest) async throws -> DiagramEditBatch)?
    public var refreshSources: (@Sendable (DiagramDocument, Set<UUID>) async throws -> DiagramSourceRefreshInput)?
    public init(openSource: (@Sendable (DiagramSourceReference) async throws -> Void)? = nil,
                execute: (@Sendable (DiagramExecutionRequest) async throws -> Void)? = nil,
                askAssistant: (@Sendable (DiagramAssistantRequest) async throws -> DiagramEditBatch)? = nil,
                refreshSources: (@Sendable (DiagramDocument, Set<UUID>) async throws -> DiagramSourceRefreshInput)? = nil) {
        self.openSource = openSource; self.execute = execute; self.askAssistant = askAssistant; self.refreshSources = refreshSources
    }
}
public struct DiagramSourceRefreshInput: Sendable {
    public var base: DiagramDocument
    public var incoming: DiagramDocument
    public init(base: DiagramDocument, incoming: DiagramDocument) { self.base = base; self.incoming = incoming }
}
public struct DiagramAssistantRequest: Codable, Hashable, Sendable {
    public var documentID: UUID
    public var revision: Int
    public var instruction: String
    public var selectedElements: [DiagramElement]
    public var selectedConnections: [DiagramConnection]
    public var selectedTasks: [DiagramTask]
    public var selectedDependencies: [DiagramTaskDependency]
    public var allowsNewTasks: Bool
    public var lockedElementIDs: Set<UUID>
    public var lockedConnectionIDs: Set<UUID>
    public var lockedTaskIDs: Set<UUID>
    public var pageID: UUID
    public init(document: DiagramDocument, pageID: UUID, scope: DiagramEditScope, instruction: String) throws {
        guard let page = document.page(pageID), !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DiagramError.invalid("assistant context") }
        let index = DiagramPageIndex(page)
        let ids = scope.elementIDs.map { scope.includeDescendants ? index.descendants(of: $0) : $0 } ?? Set(index.elements.keys)
        guard ids.count <= 2_000 else { throw DiagramError.invalid("choose a smaller assistant selection") }
        self.documentID = document.id; revision = document.revision; self.instruction = instruction; self.pageID = pageID
        selectedElements = page.elements.filter { ids.contains($0.id) }
        selectedConnections = page.connections.filter { ids.contains($0.from) && ids.contains($0.to) || scope.connectionIDs.contains($0.id) }
        let tasks = scope.taskIDs.isEmpty ? Set(selectedElements.compactMap(\.taskID)) : scope.taskIDs
        selectedTasks = document.tasks.filter { tasks.contains($0.id) }
        selectedDependencies = document.dependencies.filter { tasks.contains($0.predecessorID) && tasks.contains($0.successorID) }
        allowsNewTasks = scope.allowsNewTasks
        lockedElementIDs = index.effectivelyLockedIDs.intersection(ids)
        lockedConnectionIDs = Set(selectedConnections.filter { $0.isLocked || index.isEffectivelyLocked($0.from) || index.isEffectivelyLocked($0.to) }.map(\.id))
        var lockedTasks: Set<UUID> = []
        for p in document.pages { let i = DiagramPageIndex(p); lockedTasks.formUnion(p.elements.filter { i.isEffectivelyLocked($0.id) }.compactMap(\.taskID)) }
        lockedTaskIDs = lockedTasks.intersection(tasks)
    }
}
public enum DiagramAssistantBridge {
    public static func apply(_ batch: DiagramEditBatch, to session: DiagramSession,
                             trustedScope: DiagramEditScope) async throws -> DiagramDocument {
        try await session.commit(batch, context: .init(scope: trustedScope, permitsUnlock: false))
    }
}
public struct InMemoryDiagramAssets: DiagramAssetResolver {
    public var values: [UUID: Data]
    public init(_ values: [UUID: Data]) { self.values = values }
    public func data(for asset: DiagramAsset) throws -> Data {
        guard let data = values[asset.id], data.count == asset.byteCount,
              asset.sha256.map({ DiagramCodec.digest(data) == $0 }) ?? true else { throw DiagramError.invalid("asset bytes do not match descriptor") }
        return data
    }
}
