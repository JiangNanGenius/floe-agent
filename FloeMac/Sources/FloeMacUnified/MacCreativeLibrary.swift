// SPDX-License-Identifier: MPL-2.0
import Combine
import FloeCanvasTemplates
import FloeCore
import Foundation
import UniformTypeIdentifiers

/// Native window state is local. Canvas files use the same codec and ISO dates as the iPad library.
@MainActor
final class MacCreativeLibrary: ObservableObject {
    #if FLOE_MAC_HOST_SMOKE
    var smokeTabFrame: CGRect?
    var smokeTab = ""
    var smokeCanvasFrames: [UUID: CGRect] = [:]
    var smokeCanvasCreateFrame: CGRect?
    var smokeCanvasTemplateCloseFrame: CGRect?
    var smokeCanvasEditorOpen = false
    var smokeCanvasLibraryBackFrame: CGRect?
    #endif
    let directory: URL
    @Published private(set) var projects: [CanvasProject] = []
    @Published var selectedID: UUID? {
        didSet {
            preferences.set(selectedID?.uuidString, forKey: selectionKey)
            // Undo entries belong to one editing session on one canvas.
            undoStack.removeAll()
        }
    }
    @Published var error: String?
    @Published private(set) var isTransferring = false
    private let admitWork: HostAgentWorkspace.AdmitWork
    private var libraryReadFailed = false
    private var undoStack = MacCanvasUndoStack()
    private let preferences: UserDefaults
    private let selectionKey = "mac.creative.selectedCanvas"

    init(directory: URL, preferences: UserDefaults, admitWork: @escaping HostAgentWorkspace.AdmitWork) {
        self.admitWork = admitWork
        self.directory = directory
        self.preferences = preferences
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                where url.pathExtension == "json" {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
                do {
                    let project = try CanvasProjectCodec.decode(Data(contentsOf: url), fallbackID: id, decoder: decoder)
                    guard project.id == id else { throw CocoaError(.fileReadCorruptFile) }
                    projects.append(project)
                } catch { libraryReadFailed = true; self.error = error.localizedDescription }
            }
            projects.sort { $0.updatedAt > $1.updatedAt }
            let last = preferences.string(forKey: selectionKey).flatMap(UUID.init(uuidString:))
            selectedID = projects.first(where: { $0.id == last })?.id ?? projects.first?.id
        } catch { libraryReadFailed = true; self.error = error.localizedDescription }
    }

    var selected: CanvasProject? { projects.first { $0.id == selectedID } }
    var page: CanvasDocument? { selected.flatMap { project in project.documents.first { $0.id == project.selectedDocumentID } } }

    // MARK: Timeline drafts

    /// Draft store for the multi-track timeline editor. Lives inside the
    /// creative library directory so backups, exports and trash flows keep
    /// owning the whole creative workspace.
    private(set) lazy var timelineDraftStore: MacTimelineDraftStore? = try? MacTimelineDraftStore(
        directory: directory.appendingPathComponent("TimelineDrafts", isDirectory: true))

    /// Every readable timeline draft, newest first.
    func timelineDrafts() -> [MacTimelineDraft] {
        (try? timelineDraftStore?.loadAll()) ?? []
    }

    /// Persists (or removes) a timeline draft, then lets the presenter
    /// refresh its draft list.
    func saveTimelineDraft(_ draft: MacTimelineDraft) throws {
        guard let store = timelineDraftStore else { throw CocoaError(.fileWriteUnknown) }
        try store.save(draft)
    }

    /// True when the selected canvas contains read-only nodes or ink.
    var hasPreservedContent: Bool {
        selected.map(MacCanvasBackupProjection.hasOpaqueContent) ?? false
    }

    /// Session-local undo for the supported board edits on the selected
    /// canvas: text, media, move, remove and connectors.
    var canUndo: Bool {
        guard let id = selectedID else { return false }
        return undoStack.entries.last?.projectID == id
    }

    func undo() throws {
        guard canUndo, let entry = undoStack.pop() else { return }
        do {
            try entry.inverse(self)
        } catch {
            undoStack.push(entry)
            throw error
        }
    }

    func create(name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FloeError.validationFailed(String(localized: "mac.creative.nameRequired")) }
        let document = CanvasDocument(name: title)
        // New boards start as first-class kit canvases, same as iPad: the
        // native engine is the editing authority from the first revision.
        let project = try CanvasFrameworkBackupState.seedFrameworkState(
            CanvasProject(id: UUID(), name: title, documents: [document], selectedDocumentID: document.id))
        try save(project)
        selectedID = project.id
    }

    func create(template: CanvasTemplate?, goal: String?, chinese: Bool) throws {
        let snapshot = try CanvasTemplateEngine.startingSnapshot(template: template, chinese: chinese, goal: goal)
        let project = try CanvasFrameworkBackupState.project(from: snapshot)
        try save(project)
        selectedID = project.id
    }

    func rename(_ name: String) throws {
        guard var project = selected else { throw CocoaError(.fileNoSuchFile) }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FloeError.validationFailed(String(localized: "mac.creative.nameRequired")) }
        project.name = title
        try save(project)
    }

    func trashSelected() async throws {
        guard let project = selected else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        let staging = directory.appendingPathComponent(".trash-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        let name = String(project.name.prefix(64)).components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
        let backup = staging.appendingPathComponent((name.isEmpty || name.hasPrefix(".") ? "Canvas" : name) + ".floeCanvas")
        try await exportSelected(to: backup)
        guard selected?.id == project.id, selected?.revision == project.revision else { throw CocoaError(.userCancelled) }
        // Trash the portable copy first. A failure removing the original is recoverable.
        try manager.trashItem(at: backup, resultingItemURL: nil)
        try manager.removeItem(at: directory.appendingPathComponent(project.id.uuidString + ".json"))
        projects.removeAll { $0.id == project.id }
        selectedID = projects.first?.id
        for file in project.documents.flatMap(\.nodes).compactMap(assetURL) { prune(file) }
    }

    func selectDocument(_ id: UUID) throws {
        guard var project = selected, project.documents.contains(where: { $0.id == id }) else { return }
        project.selectedDocumentID = id
        try save(project)
    }

    func addText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let node = node(.text, text: text, index: page?.nodes.count ?? 0)
        try updatePage { $0.nodes.append(node) }
        pushUndo(projectID: selected?.id, documentID: selected?.selectedDocumentID) { library in
            try library.removeNode(node.id, recordUndo: false)
        }
    }

    func setText(_ text: String, id: UUID) throws {
        guard let node = page?.nodes.first(where: { $0.id == id }) else { return }
        try requireEditable(node)
        let old = node.text
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id && Self.textEditableKinds.contains($0.kind) }) else { return }
            page.nodes[i].text = text
        }
        pushUndo(projectID: selected?.id, documentID: selected?.selectedDocumentID) { library in
            try library.setTextSilently(old, id: id)
        }
    }

    /// Renames a node's display title without touching its payload
    /// (asset bytes, metadata, Pencil fields, generation state).
    func setTitle(_ title: String?, id: UUID) throws {
        guard let node = page?.nodes.first(where: { $0.id == id }) else { return }
        try requireEditable(node)
        let old = node.title
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id }) else { return }
            page.nodes[i].title = trimmed?.isEmpty == true ? nil : trimmed
        }
        pushUndo(projectID: selected?.id, documentID: selected?.selectedDocumentID) { library in
            try library.setTitleSilently(old, id: id)
        }
    }

    private func setTitleSilently(_ title: String?, id: UUID) throws {
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id }) else { return }
            page.nodes[i].title = title
        }
    }

    /// Changes a shape node's geometry kind. The node's text, metadata and
    /// asset payload stay untouched, so iPad backup fields survive.
    func setShape(_ shape: CanvasShapeKind, id: UUID) throws {
        guard let node = page?.nodes.first(where: { $0.id == id }) else { return }
        try requireEditable(node)
        let old = node.shape
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id && $0.kind == .shape }) else { return }
            page.nodes[i].shape = shape
        }
        pushUndo(projectID: selected?.id, documentID: selected?.selectedDocumentID) { library in
            try library.setShapeSilently(old, id: id)
        }
    }

    private func setShapeSilently(_ shape: CanvasShapeKind?, id: UUID) throws {
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id }) else { return }
            page.nodes[i].shape = shape
        }
    }

    /// Read-only nodes are owned by the iPad editor; the board never mutates
    /// their content, geometry or membership.
    private func requireEditable(_ node: CanvasNode) throws {
        guard MacCanvasBackupProjection.isEditable(node) else {
            throw FloeError.validationFailed(MacCanvasText.readonlyEditDenied)
        }
    }

    private func setTextSilently(_ text: String, id: UUID) throws {
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id }) else { return }
            page.nodes[i].text = text
        }
    }

    /// Node kinds whose `text` field the simple board may edit: plain text
    /// plus the iPad content nodes that carry user-authored copy.
    static let textEditableKinds: Set<CanvasNodeKind> = [.text, .stickyNote, .card]

    func addMedia(_ source: URL, kind: CanvasNodeKind, title: String) throws {
        guard MacCanvasBackupProjection.editableKinds.contains(kind),
              let type = UTType(filenameExtension: source.pathExtension),
              type.conforms(to: kind == .image ? .image : kind == .video ? .movie : kind == .audio ? .audio : .data),
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        let id = UUID()
        let relative = "Materials/\(id.uuidString).\(source.pathExtension.lowercased())"
        let target = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: target)
        do {
            let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
            // Build the node outside the mutation so the undo entry captures
            // the NODE id (the asset id is a different UUID).
            var item = node(kind, text: "", index: page?.nodes.count ?? 0)
            item.title = title
            item.asset = CanvasAssetReference(id: id, localRelativePath: relative, mimeType: type.preferredMIMEType,
                                              byteCount: size.map(Int64.init))
            let nodeID = item.id
            try updatePage { page in
                page.nodes.append(item)
            }
            pushUndo(projectID: selected?.id, documentID: selected?.selectedDocumentID) { library in
                try library.removeNode(nodeID, recordUndo: false)
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func assetURL(_ item: CanvasNode) -> URL? {
        guard let url = assetDestination(item) else { return nil }
        guard let type = UTType(filenameExtension: url.pathExtension) else { return nil }
        let conforms: Bool = switch item.kind {
        case .image: type.conforms(to: .image)
        case .video: type.conforms(to: .movie)
        case .audio: type.conforms(to: .audio)
        case .file: true // any regular file a file node references
        default: false
        }
        guard conforms, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    func move(_ id: UUID, x: Double, y: Double) throws {
        guard let node = page?.nodes.first(where: { $0.id == id }) else { return }
        try requireEditable(node)
        let old = node.position
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id }) else { return }
            page.nodes[i].position = CanvasPoint(x: max(0, x), y: max(0, y))
        }
        pushUndo(projectID: selected?.id, documentID: selected?.selectedDocumentID) { library in
            try library.moveSilently(id, x: old.x, y: old.y)
        }
    }

    private func moveSilently(_ id: UUID, x: Double, y: Double) throws {
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id }) else { return }
            page.nodes[i].position = CanvasPoint(x: x, y: y)
        }
    }

    func remove(_ id: UUID) throws {
        try removeNode(id, recordUndo: true)
    }

    private func removeNode(_ id: UUID, recordUndo: Bool) throws {
        guard let project = selected else { return }
        let documentID = project.selectedDocumentID
        guard let page = project.documents.first(where: { $0.id == documentID }),
              let node = page.nodes.first(where: { $0.id == id }) else { return }
        try requireEditable(node)
        let index = page.nodes.firstIndex(where: { $0.id == id }) ?? page.nodes.count
        let connections = page.connections.filter { $0.sourceNodeID == id || $0.destinationNodeID == id }
        let file = assetURL(node)
        try updatePage { page in
            page.nodes.removeAll { $0.id == id }
            page.connections.removeAll { $0.sourceNodeID == id || $0.destinationNodeID == id }
        }
        if recordUndo {
            // Keep the asset bytes until the matching undo runs; a file that
            // other nodes still reference stays in place.
            let staged = file.flatMap { stageForUndoIfUnreferenced($0) }
            pushUndo(projectID: project.id, documentID: documentID) { library in
                try library.restore(node: node, at: index, connections: connections, stagedAsset: staged)
            }
        } else if let file {
            prune(file)
        }
    }

    /// Moves an unreferenced asset into the session undo trash so a later
    /// undo can restore the exact bytes. Returns nil when the bytes stayed
    /// in place (still referenced) or could not be staged.
    private func stageForUndoIfUnreferenced(_ file: URL) -> URL? {
        guard !libraryReadFailed, !isReferencedAsset(file) else { return nil }
        do {
            try FileManager.default.createDirectory(at: undoTrashDirectory, withIntermediateDirectories: true)
            let staged = undoTrashDirectory.appendingPathComponent("\(UUID().uuidString)-\(file.lastPathComponent)")
            try FileManager.default.moveItem(at: file, to: staged)
            return staged
        } catch {
            return nil
        }
    }

    private var undoTrashDirectory: URL {
        directory.appendingPathComponent(".undo-trash", isDirectory: true)
    }

    /// Re-inserts a removed node at its old z-position, restores the
    /// connections that referenced it and moves staged asset bytes back when
    /// the original file is gone. Used by undo; never records undo.
    private func restore(node: CanvasNode, at index: Int, connections: [CanvasConnection], stagedAsset: URL? = nil) throws {
        if let stagedAsset, let target = assetDestination(node),
           !FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: stagedAsset, to: target)
        }
        try updatePage { page in
            if !page.nodes.contains(where: { $0.id == node.id }) {
                page.nodes.insert(node, at: min(max(index, 0), page.nodes.count))
            }
            for connection in connections
            where !page.connections.contains(where: { $0.id == connection.id })
                && page.nodes.contains(where: { $0.id == connection.sourceNodeID })
                && page.nodes.contains(where: { $0.id == connection.destinationNodeID }) {
                page.connections.append(connection)
            }
        }
    }

    /// Where the node's asset lives inside the library, WITHOUT requiring
    /// the bytes to exist yet (undo staging moves them back afterwards).
    private func assetDestination(_ item: CanvasNode) -> URL? {
        guard let relative = item.asset?.localRelativePath else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Materials", !parts[1].hasPrefix(".") else { return nil }
        let url = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().standardizedFileURL.path ==
                directory.resolvingSymlinksInPath().appendingPathComponent("Materials").standardizedFileURL.path else { return nil }
        return url
    }

    // MARK: Connectors

    /// Adds an ordinary arrow connector between two nodes on the selected
    /// page. Any node may be an endpoint; connectors never mutate node
    /// content. Refuses duplicate endpoint pairs instead of stacking them.
    @discardableResult
    func addConnection(from source: UUID, to destination: UUID) throws -> UUID {
        guard source != destination else {
            throw FloeError.validationFailed(MacCanvasText.connectBanner)
        }
        let connectionID = UUID()
        try updatePage { page in
            guard page.nodes.contains(where: { $0.id == source }),
                  page.nodes.contains(where: { $0.id == destination }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            guard !page.connections.contains(where: {
                $0.sourceNodeID == source && $0.destinationNodeID == destination && $0.kind == .arrow
            }) else { return }
            page.connections.append(CanvasConnection(id: connectionID, sourceNodeID: source,
                                                     destinationNodeID: destination, kind: .arrow))
        }
        // The undo applies only when the connection was actually added; when
        // the pair already existed the mutation was a no-op and removing the
        // existing connection would be wrong.
        if page?.connections.contains(where: { $0.id == connectionID }) == true {
            pushUndo(projectID: selected?.id, documentID: selected?.selectedDocumentID) { library in
                try library.removeConnection(connectionID, recordUndo: false)
            }
        }
        return connectionID
    }

    func removeConnection(_ id: UUID) throws {
        try removeConnection(id, recordUndo: true)
    }

    private func removeConnection(_ id: UUID, recordUndo: Bool) throws {
        guard let project = selected else { return }
        let documentID = project.selectedDocumentID
        guard let page = project.documents.first(where: { $0.id == documentID }),
              let connection = page.connections.first(where: { $0.id == id }) else { return }
        try updatePage { page in
            page.connections.removeAll { $0.id == id }
        }
        if recordUndo {
            pushUndo(projectID: project.id, documentID: documentID) { library in
                try library.restore(connection: connection)
            }
        }
    }

    private func restore(connection: CanvasConnection) throws {
        try updatePage { page in
            guard !page.connections.contains(where: { $0.id == connection.id }),
                  page.nodes.contains(where: { $0.id == connection.sourceNodeID }),
                  page.nodes.contains(where: { $0.id == connection.destinationNodeID }) else { return }
            page.connections.append(connection)
        }
    }

    private func pushUndo(projectID: UUID?, documentID: UUID?, inverse: @escaping @MainActor (MacCreativeLibrary) throws -> Void) {
        guard let projectID, let documentID else { return }
        undoStack.push(.init(projectID: projectID, documentID: documentID, inverse: inverse))
    }

    private func prune(_ file: URL) {
        guard !libraryReadFailed, !isReferencedAsset(file) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    private func isReferencedAsset(_ file: URL) -> Bool {
        projects.contains { project in
            project.documents.contains { $0.nodes.contains { assetDestination($0) == file } }
        }
    }

    func exportSelected(to destination: URL) async throws {
        guard !isTransferring, let project = selected else { throw CocoaError(.fileNoSuchFile) }
        let release = try admitWork()
        isTransferring = true
        defer { isTransferring = false; release() }
        let root = directory
        try await Task.detached(priority: .userInitiated) {
            let layout = CanvasBackupPackage.ExportLayout(projectsRoot: root.appendingPathComponent("MediaProjects"),
                materialsRoot: root.appendingPathComponent("Materials"),
                fallbackMediaRoot: root.appendingPathComponent("WorkbenchRoot"),
                cadDraftsRoot: root.appendingPathComponent(CanvasDrawingNodePlanner.draftRootDirectoryName),
                nativeCADRoot: root.appendingPathComponent("CanvasCAD"))
            let manager = FileManager.default
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).floeCanvas")
            defer { try? manager.removeItem(at: temporary) }
            try CanvasBackupPackage.exportToURL(project: project, destination: temporary, layout: layout)
            if manager.fileExists(atPath: destination.path) { _ = try manager.replaceItemAt(destination, withItemAt: temporary) }
            else { try manager.moveItem(at: temporary, to: destination) }
        }.value
    }

    func importCanvas(from source: URL) async throws {
        guard !isTransferring else { throw CocoaError(.userCancelled) }
        let release = try admitWork()
        isTransferring = true
        defer { isTransferring = false; release() }
        let root = directory
        var identity = UUID()
        while projects.contains(where: { $0.id == identity }) { identity = UUID() }
        let project = try await Task.detached(priority: .userInitiated) {
            var finalized: CanvasProject?
            let restored = try CanvasBackupPackage.restore(fileURL: source, floeRoot: root, canvasID: identity) { restoredProject in
                // Reconcile the restored identity and media rebases through
                // the shared native engine (no node-id fork), then publish the
                // FINALIZED project; corrupt kit state refuses the import.
                let project = try CanvasFrameworkBackupState.reconcileRestoredProject(restoredProject)
                try Self.write(project, directory: root)
                finalized = project
            }
            // The reconciled project is the library's copy; restored.project
            // only carries the raw outer state.
            guard let project = finalized else { throw CocoaError(.fileReadCorruptFile) }
            return project
        }.value
        undoStack.removeAll()
        projects.insert(project, at: 0)
        selectedID = project.id
    }

    private func node(_ kind: CanvasNodeKind, text: String, index: Int) -> CanvasNode {
        CanvasNode(kind: kind, text: text, position: .init(x: 24 + Double(index % 3) * 222, y: 24 + Double(index / 3) * 165),
                   size: .init(width: 204, height: 146), zIndex: index)
    }

    private func updatePage(_ change: (inout CanvasDocument) throws -> Void) throws {
        guard var project = selected, let i = project.documents.firstIndex(where: { $0.id == project.selectedDocumentID })
        else { throw CocoaError(.fileNoSuchFile) }
        try change(&project.documents[i])
        project.documents[i].updatedAt = Date()
        try save(project)
    }

    private func save(_ value: CanvasProject) throws {
        var proposed = value
        proposed.updatedAt = Date()
        proposed.revision += 1
        var published = proposed
        if let previous = projects.first(where: { $0.id == proposed.id }) {
            // Publish the local edit through the same native transaction
            // engine as the iPad editor, so retained kit state, strokes and
            // receipts stay the overlay authority instead of going stale.
            published = try CanvasFrameworkBackupState.commitEdit(from: previous, to: proposed)
        }
        try Self.write(published, directory: directory)
        projects.removeAll { $0.id == published.id }
        projects.insert(published, at: 0)
    }

    nonisolated private static func write(_ project: CanvasProject, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try CanvasProjectCodec.encode(project, encoder: encoder)
        try bytes.write(to: directory.appendingPathComponent(project.id.uuidString + ".json"), options: .atomic)
    }
}
