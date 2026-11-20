// SPDX-License-Identifier: MPL-2.0
import Combine
import FloeCore
import Foundation
import UniformTypeIdentifiers

/// Native window state is local. Canvas files use the same codec and ISO dates as the iPad library.
@MainActor
final class MacCreativeLibrary: ObservableObject {
    #if FLOE_MAC_HOST_SMOKE
    var smokeTabFrame: CGRect?
    var smokeTab = ""
    #endif
    let directory: URL
    @Published private(set) var projects: [CanvasProject] = []
    @Published var selectedID: UUID? {
        didSet { preferences.set(selectedID?.uuidString, forKey: selectionKey) }
    }
    @Published var error: String?
    @Published private(set) var isTransferring = false
    private let admitWork: HostAgentWorkspace.AdmitWork
    private var libraryReadFailed = false
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

    func create(name: String) throws {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw FloeError.validationFailed(String(localized: "mac.creative.nameRequired")) }
        let document = CanvasDocument(name: title)
        let project = CanvasProject(id: UUID(), name: title, documents: [document], selectedDocumentID: document.id)
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
        try updatePage { $0.nodes.append(node(.text, text: text, index: $0.nodes.count)) }
    }

    func setText(_ text: String, id: UUID) throws {
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id && $0.kind == .text }) else { return }
            page.nodes[i].text = text
        }
    }

    func addMedia(_ source: URL, kind: CanvasNodeKind, title: String) throws {
        guard kind == .image || kind == .video, let type = UTType(filenameExtension: source.pathExtension),
              type.conforms(to: kind == .image ? .image : .movie),
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else { throw CocoaError(.fileReadUnsupportedScheme) }
        let id = UUID()
        let relative = "Materials/\(id.uuidString).\(source.pathExtension.lowercased())"
        let target = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: target)
        do {
            let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
            try updatePage { page in
                var item = node(kind, text: "", index: page.nodes.count)
                item.title = title
                item.asset = CanvasAssetReference(id: id, localRelativePath: relative, mimeType: type.preferredMIMEType,
                                                  byteCount: size.map(Int64.init))
                page.nodes.append(item)
            }
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
    }

    func assetURL(_ item: CanvasNode) -> URL? {
        guard let relative = item.asset?.localRelativePath else { return nil }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Materials", !parts[1].hasPrefix(".") else { return nil }
        let url = directory.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().standardizedFileURL.path ==
                directory.resolvingSymlinksInPath().appendingPathComponent("Materials").standardizedFileURL.path else { return nil }
        guard let type = UTType(filenameExtension: url.pathExtension),
              (item.kind == .image && type.conforms(to: .image)) || (item.kind == .video && type.conforms(to: .movie)),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return url
    }

    func move(_ id: UUID, x: Double, y: Double) throws {
        try updatePage { page in
            guard let i = page.nodes.firstIndex(where: { $0.id == id }) else { return }
            page.nodes[i].position = CanvasPoint(x: max(0, x), y: max(0, y))
        }
    }

    func remove(_ id: UUID) throws {
        let file = page?.nodes.first(where: { $0.id == id }).flatMap(assetURL)
        try updatePage { page in
            page.nodes.removeAll { $0.id == id }
            page.connections.removeAll { $0.sourceNodeID == id || $0.destinationNodeID == id }
        }
        if let file { prune(file) }
    }

    private func prune(_ file: URL) {
        guard !libraryReadFailed, !projects.contains(where: { project in
            project.documents.contains { $0.nodes.contains { assetURL($0) == file } }
        }) else { return }
        try? FileManager.default.removeItem(at: file)
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
        let project = try await Task.detached(priority: .userInitiated) {
            try CanvasBackupPackage.restore(fileURL: source, floeRoot: root) { project in
                // A rich iPad editor snapshot carries its own identity and undo state.
                // The simple board cannot rebind those records during import.
                guard project.canvasKitState == nil, project.documents.allSatisfy({ page in
                    page.strokes.isEmpty && page.pencilDrawingData == nil && page.connections.isEmpty &&
                    page.nodes.allSatisfy { node in
                        [.text, .image, .video].contains(node.kind) && !node.isLocked && node.groupID == nil &&
                        node.position.x.isFinite && node.position.y.isFinite &&
                        node.size.width > 0 && node.size.height > 0 && node.size.width <= 32768 && node.size.height <= 32768
                    }
                }) else { throw FloeError.validationFailed(String(localized: "mac.creative.unsupported")) }
                try Self.write(project, directory: root)
            }.project
        }.value
        projects.insert(project, at: 0)
        selectedID = project.id
    }

    private func node(_ kind: CanvasNodeKind, text: String, index: Int) -> CanvasNode {
        CanvasNode(kind: kind, text: text, position: .init(x: 24 + Double(index % 3) * 222, y: 24 + Double(index / 3) * 165),
                   size: .init(width: 204, height: 146), zIndex: index)
    }

    private func updatePage(_ change: (inout CanvasDocument) -> Void) throws {
        guard var project = selected, let i = project.documents.firstIndex(where: { $0.id == project.selectedDocumentID })
        else { throw CocoaError(.fileNoSuchFile) }
        change(&project.documents[i])
        project.documents[i].updatedAt = Date()
        try save(project)
    }

    private func save(_ value: CanvasProject) throws {
        var project = value
        project.updatedAt = Date()
        project.revision += 1
        try Self.write(project, directory: directory)
        projects.removeAll { $0.id == project.id }
        projects.insert(project, at: 0)
    }

    nonisolated private static func write(_ project: CanvasProject, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bytes = try CanvasProjectCodec.encode(project, encoder: encoder)
        try bytes.write(to: directory.appendingPathComponent(project.id.uuidString + ".json"), options: .atomic)
    }
}
