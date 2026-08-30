// FloeApp — Native workspace canvas.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import UIKit
import AVKit
import PencilKit
import UniformTypeIdentifiers
import CryptoKit
import FloeCore
import FloeLocalModels
import FloeModels
import FloePersistence
import FloeProviders
import FloeSync
import FloeTools

private extension UTType {
    static let floeCanvasPackage = UTType(exportedAs: "org.floeagent.canvas")
}

private struct CanvasBinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.floeCanvasPackage, .json, .png, .pdf] }
    var data: Data

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Stable sidebar entry for creative work. A private canvas works without a
/// Workspace; optional Workspace canvases remain available for project-owned
/// material and explicit file export.
struct CreativeModeHubView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @State private var presentation: CanvasPresentation?
    @State private var showsWorkspacePicker = false
    @State private var showsMaterialLibrary = false
    @State private var imageGenerationReady = false
    @State private var hasImageGenerationModel = false
    @State private var listRevision = 0
    @State private var renamingCanvas: WorkspaceCanvasRegistry.CanvasSummary?
    @State private var renameValue = ""
    @State private var importsCanvasPackage = false
    @State private var exportedCanvas: CanvasBinaryDocument?
    @State private var exportedCanvasFilename = "Floe 画布"

    private struct CanvasPresentation: Identifiable {
        let id: UUID
        let name: String
        let workspace: WorkspaceRecord?
    }

    var body: some View {
        Group {
            if imageGenerationReady {
                canvasList
            } else {
                ContentUnavailableView {
                    Label("需要生图模型", systemImage: "photo.badge.plus")
                } description: {
                    Text(hasImageGenerationModel
                         ? "请选择创意模式默认使用的生图模型。视频模型是可选的 Extra，工作区也可以稍后再添加。"
                         : "创意模式至少需要一个已启用的图片生成模型。视频模型是可选的 Extra，工作区也可以稍后再添加。")
                } actions: {
                    if hasImageGenerationModel {
                        NavigationLink {
                            AuxiliaryModelsView(center: environment.conversationCenter)
                        } label: {
                            Text("选择生图模型")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        NavigationLink {
                            ProviderListView(center: environment.conversationCenter)
                        } label: {
                            Text("添加生图服务商")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle("创意模式")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("导入画布", systemImage: "square.and.arrow.down") {
                    importsCanvasPackage = true
                }
                Button("添加工作区", systemImage: "folder.badge.plus") {
                    showsWorkspacePicker = true
                }
            }
        }
        .task { await refreshPrerequisites() }
        .onAppear { Task { await refreshPrerequisites() } }
        .sheet(isPresented: $showsWorkspacePicker) {
            NavigationStack {
                WorkspacePickerView(center: environment.workspaceCenter) {
                    showsWorkspacePicker = false
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { showsWorkspacePicker = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showsMaterialLibrary) {
            NavigationStack { CanvasMaterialLibraryView() }
        }
        .fileImporter(
            isPresented: $importsCanvasPackage,
            allowedContentTypes: [.floeCanvasPackage, .json],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let source = try result.get().first else { return }
                let accessed = source.startAccessingSecurityScopedResource()
                defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                let id = try WorkspaceCanvasRegistry.importPackage(from: source)
                let summary = WorkspaceCanvasRegistry.summaries().first { $0.id == id }
                presentation = CanvasPresentation(
                    id: id, name: summary?.name ?? "导入画布", workspace: nil
                )
                listRevision += 1
            } catch {
                environment.workspaceCenter.actionError = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportedCanvas != nil },
                set: { if !$0 { exportedCanvas = nil } }
            ),
            document: exportedCanvas,
            contentType: .floeCanvasPackage,
            defaultFilename: exportedCanvasFilename
        ) { result in
            if case .failure(let error) = result {
                environment.workspaceCenter.actionError = error.localizedDescription
            }
            exportedCanvas = nil
        }
        .fullScreenCover(item: $presentation) { item in
            WorkspaceCanvasView(
                canvasID: item.id,
                name: item.name,
                workspace: item.workspace
            )
        }
        .alert("重命名画布", isPresented: Binding(
            get: { renamingCanvas != nil },
            set: { if !$0 { renamingCanvas = nil } }
        )) {
            TextField("画布名称", text: $renameValue)
            Button("取消", role: .cancel) { renamingCanvas = nil }
            Button("保存") {
                if let summary = renamingCanvas {
                    try? WorkspaceCanvasRegistry.rename(canvasID: summary.id, to: renameValue)
                    listRevision += 1
                }
                renamingCanvas = nil
            }
        }
    }

    private var canvasList: some View {
        List {
            Section {
                Button {
                    createPrivateCanvas()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.and.pencil.and.ellipsis")
                            .foregroundStyle(FloeTheme.primary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("新建画布")
                                .foregroundStyle(.primary)
                            Text("创建不绑定工作区的私人画布")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: FloeTheme.minimumTarget)
                Button {
                    showsMaterialLibrary = true
                } label: {
                    Label("素材库", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: FloeTheme.minimumTarget)
            } header: {
                Text("快速开始")
            } footer: {
                Text("私人画布独立保存；素材可稍后移动到工作区或导出。")
            }

            let privateCanvases = WorkspaceCanvasRegistry.summaries().filter { $0.workspaceID == nil }
            if let recent = privateCanvases.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                Section("最近使用") { canvasSummaryRow(recent) }
            }
            if !privateCanvases.isEmpty {
                Section("私人画布") {
                    ForEach(privateCanvases.sorted(by: { $0.updatedAt > $1.updatedAt })) { summary in
                        canvasSummaryRow(summary)
                    }
                }
            }

            if !environment.workspaceCenter.projectWorkspaces.isEmpty {
                Section("工作区画布") {
                    ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                    Button {
                        openCanvas(for: workspace)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: WorkspaceCanvasRegistry.exists(workspaceID: workspace.id)
                                  ? "rectangle.and.pencil.and.ellipsis" : "plus.rectangle.on.folder")
                                .foregroundStyle(FloeTheme.primary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workspace.name)
                                    .foregroundStyle(.primary)
                                Text(WorkspaceCanvasRegistry.exists(workspaceID: workspace.id)
                                     ? "继续画布" : "创建无限画布")
                                    .font(FloeTheme.Typography.metadata)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    }
                }
            }
        }
        .id(listRevision)
    }

    private func canvasSummaryRow(_ summary: WorkspaceCanvasRegistry.CanvasSummary) -> some View {
        Button {
            presentation = CanvasPresentation(id: summary.id, name: summary.name, workspace: nil)
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(FloeTheme.primary.opacity(0.12))
                    .frame(width: 52, height: 38)
                    .overlay { Image(systemName: "rectangle.and.pencil.and.ellipsis") }
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.name).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        if summary.syncEnabled { Label("同步", systemImage: "icloud") }
                        if summary.pendingMediaJobs > 0 {
                            Label("\(summary.pendingMediaJobs) 个任务", systemImage: "hourglass")
                        }
                    }
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重命名", systemImage: "pencil") {
                renamingCanvas = summary
                renameValue = summary.name
            }
            Button("复制", systemImage: "doc.on.doc") {
                _ = try? WorkspaceCanvasRegistry.duplicate(canvasID: summary.id)
                listRevision += 1
            }
            Button("导出可编辑画布包", systemImage: "square.and.arrow.up") {
                do {
                    exportedCanvas = CanvasBinaryDocument(
                        data: try WorkspaceCanvasRegistry.packageData(canvasID: summary.id)
                    )
                    exportedCanvasFilename = summary.name
                } catch {
                    environment.workspaceCenter.actionError = error.localizedDescription
                }
            }
            if !environment.workspaceCenter.projectWorkspaces.isEmpty {
                Menu("移动到工作区", systemImage: "folder") {
                    ForEach(environment.workspaceCenter.projectWorkspaces) { workspace in
                        Button(workspace.name) {
                            try? WorkspaceCanvasRegistry.move(
                                canvasID: summary.id, to: workspace
                            )
                            listRevision += 1
                        }
                    }
                }
            }
            Button("删除", systemImage: "trash", role: .destructive) {
                let operation = CanvasSyncOperation(
                    canvasID: summary.id, entityKind: .tombstone,
                    entityID: summary.id, mutation: .delete,
                    revision: Int64(Date().timeIntervalSince1970 * 1_000)
                )
                Task { try? await environment.canvasSyncOperationStore.enqueue(operation) }
                try? WorkspaceCanvasRegistry.delete(canvasID: summary.id)
                listRevision += 1
            }
        }
    }

    @MainActor
    private func refreshPrerequisites() async {
        await environment.conversationCenter.reload()
        await environment.workspaceCenter.reload()
        let center = environment.conversationCenter
        let preferences = center.modelPreferences
        hasImageGenerationModel = center.imageModels.contains {
            $0.capabilities.contains(.imageGeneration)
        }
        let configuredID = preferences.auxiliaryImageMode == .shared
            ? preferences.sharedImageModelID
            : preferences.imageGenerationModelID
        imageGenerationReady = configuredID.flatMap { id in
            center.imageModels.first(where: {
                $0.id == id && $0.capabilities.contains(.imageGeneration)
            })
        } != nil
    }

    private func createPrivateCanvas() {
        do {
            let id = UUID()
            try WorkspaceCanvasRegistry.createIfNeeded(
                canvasID: id,
                name: "未命名画布",
                workspaceID: nil
            )
            presentation = CanvasPresentation(
                id: id,
                name: "未命名画布",
                workspace: nil
            )
        } catch {
            environment.workspaceCenter.actionError = error.localizedDescription
        }
    }

    private func openCanvas(for workspace: WorkspaceRecord) {
        do {
            try WorkspaceCanvasRegistry.createIfNeeded(workspace: workspace)
            presentation = CanvasPresentation(id: workspace.id, name: workspace.name, workspace: workspace)
        } catch {
            environment.workspaceCenter.actionError = error.localizedDescription
        }
    }
}

enum CanvasAgentIdentity {
    static let conversationTitlePrefix = "Floe Canvas Agent · "

    static func isCanvasConversation(_ conversation: ConversationRecord?) -> Bool {
        conversation?.title.hasPrefix(conversationTitlePrefix) == true
    }
}

private typealias FloeCanvasPoint = CanvasPoint
private typealias FloeCanvasStroke = CanvasStroke
private typealias FloeCanvasNode = CanvasNode
private typealias FloeCanvasDocument = CanvasDocument
private typealias FloeCanvasProject = CanvasProject

private extension CanvasPoint {
    init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

private enum CanvasInkOutputPreference: String, CaseIterable, Identifiable {
    case automatic, cleanText, cards, diagram, wireframe

    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "自动判断"
        case .cleanText: "整理文字"
        case .cards: "便签卡片"
        case .diagram: "流程／思维图"
        case .wireframe: "界面草图"
        }
    }

    var instruction: String {
        switch self {
        case .automatic: "Infer the most useful structured layout from the ink."
        case .cleanText: "Convert handwriting into clean, faithfully ordered text notes."
        case .cards: "Convert the ideas into concise grouped sticky-note cards."
        case .diagram: "Convert the intent into a flowchart or mind map with explicit connections."
        case .wireframe: "Convert the sketch into a simple interface wireframe using labeled shapes."
        }
    }
}

private struct CanvasInkPlanNode: Codable, Hashable, Identifiable {
    var id: String
    var kind: String
    var text: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var shape: String?
}

private struct CanvasInkPlanConnection: Codable, Hashable {
    var from: String
    var to: String
    var label: String?
}

private struct CanvasInkInterpretation: Codable, Hashable, Identifiable {
    var id = UUID()
    var summary: String
    var layout: String
    var confidence: Double
    var nodes: [CanvasInkPlanNode]
    var connections: [CanvasInkPlanConnection]
    var sourceBounds: CGRect = .zero
    var routeDescription: String = "辅助视觉模型"

    private enum CodingKeys: String, CodingKey {
        case summary, layout, confidence, nodes, connections
    }
}

private struct CanvasInkCapture {
    let imageData: Data
    let pixelWidth: Int
    let pixelHeight: Int
    let canvasBounds: CGRect
}

private struct CanvasNodeClipboard: Codable {
    let nodes: [FloeCanvasNode]
    let connections: [CanvasConnection]
}

/// Product-level presence contract for the one optional CanvasProject owned
/// by a Workspace. Merely opening the file inspector must never manufacture a
/// canvas; creation happens only from an explicit Workspace action.
enum WorkspaceCanvasRegistry {
    static let privateCanvasID = UUID(uuidString: "4D17C2E1-AD82-4A39-97E7-F10ECA77A114")!

    struct CanvasSummary: Identifiable, Hashable {
        let id: UUID
        let name: String
        let workspaceID: UUID?
        let updatedAt: Date
        let syncEnabled: Bool
        let pendingMediaJobs: Int
    }

    static func summaries() -> [CanvasSummary] {
        guard let directory = try? projectURL(canvasID: privateCanvasID, createDirectory: false).deletingLastPathComponent(),
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls.compactMap { url in
            guard url.pathExtension == "json", let data = try? Data(contentsOf: url),
                  let fileID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let project = try? CanvasProjectCodec.decode(
                    data, fallbackID: fileID, decoder: decoder
                  ) else { return nil }
            return CanvasSummary(
                id: project.id, name: project.name,
                workspaceID: project.workspaceID, updatedAt: project.updatedAt,
                syncEnabled: project.sync.isEnabled,
                pendingMediaJobs: project.documents.flatMap(\.nodes).filter {
                    $0.kind == .generationTask && $0.generationJobID != nil
                }.count
            )
        }
    }

    static func exists(canvasID: UUID) -> Bool {
        guard let url = try? projectURL(canvasID: canvasID, createDirectory: false) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    static func exists(workspaceID: UUID) -> Bool {
        exists(canvasID: workspaceID)
    }

    static func rename(canvasID: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = try projectURL(canvasID: canvasID, createDirectory: false)
        var project = try decodeProject(at: url)
        project.name = trimmed
        project.updatedAt = Date()
        try encodeProject(project, to: url)
    }

    @discardableResult
    static func duplicate(canvasID: UUID) throws -> UUID {
        let source = try projectURL(canvasID: canvasID, createDirectory: false)
        var project = try decodeProject(at: source)
        let copyID = UUID()
        project.id = copyID
        project.workspaceID = nil
        project.name += " 副本"
        project.createdAt = Date()
        project.updatedAt = Date()
        try encodeProject(project, to: projectURL(canvasID: copyID, createDirectory: true))
        return copyID
    }

    static func move(canvasID: UUID, to workspace: WorkspaceRecord) throws {
        let source = try projectURL(canvasID: canvasID, createDirectory: false)
        let destination = try projectURL(canvasID: workspace.id, createDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FloeError.validationFailed("这个工作区已有画布。")
        }
        var project = try decodeProject(at: source)
        project.id = workspace.id
        project.workspaceID = workspace.id
        project.name = workspace.name
        project.updatedAt = Date()
        try encodeProject(project, to: destination)
        try FileManager.default.removeItem(at: source)
    }

    static func delete(canvasID: UUID) throws {
        let url = try projectURL(canvasID: canvasID, createDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func packageData(canvasID: UUID) throws -> Data {
        try Data(contentsOf: projectURL(canvasID: canvasID, createDirectory: false))
    }

    @discardableResult
    static func importPackage(from source: URL) throws -> UUID {
        var project = try decodeProject(at: source)
        guard !project.documents.isEmpty, (1...5).contains(project.schemaVersion) else {
            throw FloeError.validationFailed("这不是受支持的 Floe 画布包。")
        }
        let id = UUID()
        project.id = id
        project.workspaceID = nil
        project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.name.isEmpty { project.name = "导入画布" }
        project.updatedAt = Date()
        try encodeProject(project, to: projectURL(canvasID: id, createDirectory: true))
        return id
    }

    @MainActor
    static func createIfNeeded(workspace: WorkspaceRecord) throws {
        try createIfNeeded(canvasID: workspace.id, name: workspace.name, workspaceID: workspace.id)
    }

    @MainActor
    static func createIfNeeded(canvasID: UUID, name: String, workspaceID: UUID?) throws {
        let url = try projectURL(canvasID: canvasID, createDirectory: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let initial = FloeCanvasDocument(name: "画布 1")
        let project = FloeCanvasProject(
            id: canvasID,
            workspaceID: workspaceID,
            name: name,
            documents: [initial],
            selectedDocumentID: initial.id
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: url, options: .atomic)
    }

    static func projectURL(
        canvasID: UUID,
        createDirectory: Bool
    ) throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("Canvases", isDirectory: true)
        if createDirectory {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory.appendingPathComponent("\(canvasID.uuidString).json")
    }

    private static func decodeProject(at url: URL) throws -> FloeCanvasProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try CanvasProjectCodec.decode(
            Data(contentsOf: url),
            fallbackID: UUID(uuidString: url.deletingPathExtension().lastPathComponent),
            decoder: decoder
        )
    }

    private static func encodeProject(_ project: FloeCanvasProject, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try CanvasProjectCodec.encode(project, encoder: encoder).write(to: url, options: .atomic)
    }
}

@MainActor
private final class CanvasDocumentStore: ObservableObject {
    @Published private(set) var project: FloeCanvasProject
    @Published var saveError: String?
    @Published var wasDeletedRemotely = false

    private var fileURL: URL
    private var syncOperationStore: CanvasSyncOperationStore?
    private var creativeAssetStore: CreativeAssetStore?
    private var globalSyncEnabled = true
    private var undoStack: [FloeCanvasProject] = []
    private var redoStack: [FloeCanvasProject] = []
    private var interactiveMutationRecorded = false

    enum ExportFormat { case package, png, pdf }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    init(canvasID: UUID, workspaceID: UUID?, canvasName: String) {
        let initial = FloeCanvasDocument(name: "画布 1")
        let fallback = FloeCanvasProject(
            id: canvasID,
            workspaceID: workspaceID,
            name: canvasName,
            documents: [initial],
            selectedDocumentID: initial.id
        )
        do {
            fileURL = try WorkspaceCanvasRegistry.projectURL(
                canvasID: canvasID,
                createDirectory: true
            )
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                if let decoded = try? CanvasProjectCodec.decode(
                    data, fallbackID: canvasID, decoder: decoder
                ),
                   decoded.workspaceID == workspaceID,
                   !decoded.documents.isEmpty {
                    project = decoded
                    persist()
                } else {
                    let backup = try Self.preserveReadOnlyBackup(of: fileURL)
                    project = fallback
                    persist()
                    saveError = "原画布无法迁移，已保留只读备份：\(backup.lastPathComponent)"
                }
            } else {
                project = fallback
                persist()
            }
        } catch {
            fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-canvas-\(canvasID.uuidString).json")
            project = fallback
            saveError = error.localizedDescription
        }
    }

    private static func preserveReadOnlyBackup(of source: URL) throws -> URL {
        let directory = source.deletingLastPathComponent()
            .appendingPathComponent("ReadOnlyBackups", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = directory.appendingPathComponent(
            "\(source.deletingPathExtension().lastPathComponent)-\(stamp).json"
        )
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    var selectedDocument: FloeCanvasDocument? {
        project.documents.first { $0.id == project.selectedDocumentID }
            ?? project.documents.first
    }

    func configureSync(
        store: CanvasSyncOperationStore,
        assetStore: CreativeAssetStore? = nil,
        globalEnabled: Bool
    ) {
        syncOperationStore = store
        if let assetStore { creativeAssetStore = assetStore }
        globalSyncEnabled = globalEnabled
    }

    func synchronizeFromCloud(_ service: CanvasCloudAssetService) async {
        guard globalSyncEnabled, project.sync.isEnabled else { return }
        let canvasID = project.id
        let operations = await service.pullCanvasOperations(canvasID: canvasID)
        if let deletion = operations
            .filter({ $0.entityKind == .tombstone && $0.mutation == .delete })
            .max(by: { $0.revision < $1.revision }),
           deletion.revision >= project.sync.revision {
            wasDeletedRemotely = true
            return
        }
        guard let newest = operations
            .filter({ $0.entityKind == .project && $0.mutation == .upsert && $0.payload != nil })
            .max(by: {
                ($0.revision, $0.operationID.uuidString) < ($1.revision, $1.operationID.uuidString)
            }),
              newest.revision > project.sync.revision,
              let payload = newest.payload else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let remote = try CanvasProjectCodec.decode(
                payload, fallbackID: canvasID, decoder: decoder
            )
            guard remote.id == canvasID else { return }
            try payload.write(to: fileURL, options: .atomic)
            project = remote
            undoStack.removeAll(); redoStack.removeAll()
            for hash in newest.assetHashes {
                _ = try? await service.downloadAssetIfNeeded(contentHash: hash)
            }
            saveError = nil
        } catch {
            saveError = "同步画布失败：\(error.localizedDescription)"
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        project.updatedAt = Date()
        persist()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        project.updatedAt = Date()
        persist()
    }

    func beginInteractiveMutation() {
        guard !interactiveMutationRecorded else { return }
        recordHistory()
        interactiveMutationRecorded = true
    }

    func select(_ id: UUID) {
        guard project.documents.contains(where: { $0.id == id }) else { return }
        project.selectedDocumentID = id
        project.updatedAt = Date()
        persist()
    }

    func addDocument() {
        let document = FloeCanvasDocument(name: "画布 \(project.documents.count + 1)")
        project.documents.append(document)
        project.selectedDocumentID = document.id
        project.updatedAt = Date()
        persist()
    }

    func deleteDocument(_ id: UUID) {
        guard project.documents.count > 1 else { return }
        let assetIDs = project.documents.first(where: { $0.id == id })?.nodes.compactMap(\.asset?.id) ?? []
        project.documents.removeAll { $0.id == id }
        if project.selectedDocumentID == id {
            project.selectedDocumentID = project.documents[0].id
        }
        project.updatedAt = Date()
        persist()
        for assetID in assetIDs {
            Task { try? await creativeAssetStore?.adjustReference(assetID: assetID, by: -1) }
        }
    }

    func renameDocument(_ id: UUID, name: String) {
        mutateDocument(id) { $0.name = name }
    }

    @discardableResult
    func addNote(at point: CGPoint, text: String = "新建文本") -> UUID {
        let id = addPlaceholder(kind: .text, at: point)
        if text != "新建文本" { updateNode(id, text: text) }
        return id
    }

    /// Creates a real sticky-note node. Keeping this separate from `addNote`
    /// prevents card entry points from silently producing plain text nodes.
    @discardableResult
    func addCard(at point: CGPoint, text: String = "新建卡片") -> UUID {
        let id = addPlaceholder(kind: .stickyNote, at: point)
        if text != "新建卡片" { updateNode(id, text: text) }
        return id
    }

    @discardableResult
    func addShape(at point: CGPoint) -> UUID {
        addPlaceholder(kind: .shape, at: point)
    }

    /// Creates an empty container that can receive nodes through grouping or
    /// drag/drop.
    @discardableResult
    func addGroup(at point: CGPoint, text: String = "新建分组") -> UUID {
        let id = addPlaceholder(kind: .group, at: point)
        if text != "新建分组" { updateNode(id, text: text) }
        return id
    }

    /// Creates every native node kind without requiring an imported asset or
    /// an already-submitted provider job.
    @discardableResult
    func addPlaceholder(kind: CanvasNodeKind, at point: CGPoint) -> UUID {
        let node = FloeCanvasNode.placeholder(
            kind: kind,
            position: CanvasPoint(point),
            zIndex: selectedDocument?.nodes.count ?? 0
        )
        mutateSelectedDocument { $0.nodes.append(node) }
        return node.id
    }

    func attachAsset(
        _ asset: CanvasAssetReference,
        kind: CanvasNodeKind,
        to nodeID: UUID
    ) {
        guard [.image, .video, .audio, .file].contains(kind) else { return }
        var previousAssetID: UUID?
        mutateSelectedDocument { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            previousAssetID = document.nodes[index].asset?.id
            document.nodes[index].kind = kind
            document.nodes[index].asset = asset
            document.nodes[index].text = asset.localRelativePath?
                .split(separator: "/").last.map(String.init) ?? document.nodes[index].text
            document.nodes[index].metadata["placeholder"] = nil
        }
        if let previousAssetID, previousAssetID != asset.id {
            Task { try? await creativeAssetStore?.adjustReference(assetID: previousAssetID, by: -1) }
        }
        if previousAssetID != asset.id {
            Task { try? await creativeAssetStore?.adjustReference(assetID: asset.id, by: 1) }
        }
    }

    @discardableResult
    func addAsset(_ asset: CanvasAssetReference, kind: CanvasNodeKind, at point: CGPoint) -> UUID {
        let id = UUID()
        mutateSelectedDocument { document in
            document.nodes.append(FloeCanvasNode(
                id: id,
                text: asset.localRelativePath?.split(separator: "/").last.map(String.init) ?? "素材",
                x: point.x, y: point.y, width: 320, height: kind == .video ? 220 : 260,
                kind: kind, rotation: 0, zIndex: document.nodes.count,
                isLocked: false, asset: asset
            ))
        }
        Task { try? await creativeAssetStore?.adjustReference(assetID: asset.id, by: 1) }
        return id
    }

    @discardableResult
    func addGenerationTask(kind: MediaKind, prompt: String, at point: CGPoint) -> UUID {
        let id = UUID()
        mutateSelectedDocument { document in
            document.nodes.append(FloeCanvasNode(
                id: id,
                text: prompt,
                x: point.x, y: point.y, width: 340, height: 210,
                kind: .generationTask, rotation: 0,
                zIndex: document.nodes.count, isLocked: false
            ))
        }
        return id
    }

    @discardableResult
    func addScene3D(at point: CGPoint) -> UUID {
        addPlaceholder(kind: .scene3D, at: point)
    }

    func updateScene3D(_ scene: CanvasScene3D, for nodeID: UUID) {
        mutateSelectedDocument { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            document.nodes[index].scene3D = scene
            document.nodes[index].text = scene.name
        }
    }

    func setGenerationJob(_ jobID: UUID, for nodeID: UUID) {
        mutateSelectedDocument { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
            document.nodes[index].generationJobID = jobID
        }
    }

    func applyMediaJobs(_ jobs: [MediaGenerationJob]) {
        var changed = false
        var newlyReferencedAssets: [UUID] = []
        for documentIndex in project.documents.indices {
            for nodeIndex in project.documents[documentIndex].nodes.indices {
                guard let jobID = project.documents[documentIndex].nodes[nodeIndex].generationJobID,
                      let job = jobs.first(where: { $0.id == jobID }) else { continue }
                let oldText = project.documents[documentIndex].nodes[nodeIndex].text
                let statusText: String
                switch job.state {
                case .preparing: statusText = "正在准备生成任务"
                case .submitted: statusText = "已提交，等待供应商开始"
                case .running: statusText = "正在生成"
                case .completed: statusText = "生成完成，正在准备下载"
                case .downloading: statusText = "正在下载，完成后会自动加入素材库"
                case .ready: statusText = "已保存到素材库"
                case .failed: statusText = "生成失败：\(job.lastError ?? "未知错误")"
                case .cancelled: statusText = "任务已取消"
                case .expired: statusText = "结果可能已过期，可确认计费后重新生成"
                }
                if oldText != statusText {
                    project.documents[documentIndex].nodes[nodeIndex].text = statusText
                    changed = true
                }
                if job.state == .ready, let assetID = job.localAssetID,
                   project.documents[documentIndex].nodes[nodeIndex].asset == nil,
                   let relativePath = Self.materialRelativePath(assetID: assetID) {
                    project.documents[documentIndex].nodes[nodeIndex].kind = .video
                    project.documents[documentIndex].nodes[nodeIndex].asset = CanvasAssetReference(
                        id: assetID, localRelativePath: relativePath,
                        mimeType: "video/mp4"
                    )
                    newlyReferencedAssets.append(assetID)
                    changed = true
                }
            }
        }
        if changed {
            project.updatedAt = Date()
            persist()
        }
        for assetID in newlyReferencedAssets {
            Task { try? await creativeAssetStore?.adjustReference(assetID: assetID, by: 1) }
        }
    }

    func connect(
        _ source: UUID,
        to destination: UUID,
        kind: CanvasConnectionKind = .arrow,
        sourcePort: CanvasConnectionPort? = nil,
        destinationPort: CanvasConnectionPort? = nil
    ) {
        guard source != destination else { return }
        mutateSelectedDocument { document in
            var connections = document.connections
            let connection = CanvasConnection(
                sourceNodeID: source,
                destinationNodeID: destination,
                kind: kind,
                sourcePort: sourcePort,
                destinationPort: destinationPort
            )
            guard !connections.contains(where: {
                $0.sourceNodeID == source && $0.destinationNodeID == destination && $0.kind == kind
                    && $0.sourcePort == sourcePort && $0.destinationPort == destinationPort
            }) else { return }
            connections.append(connection)
            document.connections = connections
        }
    }

    func deleteConnection(_ id: UUID) {
        mutateSelectedDocument { document in
            document.connections.removeAll { $0.id == id }
        }
    }

    func reverseConnection(_ id: UUID) {
        mutateSelectedDocument { document in
            guard let index = document.connections.firstIndex(where: { $0.id == id }) else { return }
            let source = document.connections[index].sourceNodeID
            let destination = document.connections[index].destinationNodeID
            document.connections[index].sourceNodeID = destination
            document.connections[index].destinationNodeID = source
        }
    }

    func duplicateNodes(_ ids: Set<UUID>) -> Set<UUID> {
        var created = Set<UUID>()
        var duplicatedAssetIDs: [UUID] = []
        mutateSelectedDocument { document in
            let originals = document.nodes.filter { ids.contains($0.id) }
            for var copy in originals {
                copy.id = UUID()
                copy.x += 36; copy.y += 36
                copy.zIndex = document.nodes.count
                document.nodes.append(copy)
                created.insert(copy.id)
                if let assetID = copy.asset?.id { duplicatedAssetIDs.append(assetID) }
            }
        }
        for assetID in duplicatedAssetIDs {
            Task { try? await creativeAssetStore?.adjustReference(assetID: assetID, by: 1) }
        }
        return created
    }

    func clipboardData(for ids: Set<UUID>) throws -> Data {
        guard let document = selectedDocument else {
            throw FloeError.validationFailed("当前没有可复制的画布。")
        }
        let nodes = document.nodes.filter { ids.contains($0.id) }
        guard !nodes.isEmpty else {
            throw FloeError.validationFailed("请先选择节点。")
        }
        let connections = document.connections.filter {
            ids.contains($0.sourceNodeID) && ids.contains($0.destinationNodeID)
        }
        return try JSONEncoder().encode(CanvasNodeClipboard(
            nodes: nodes,
            connections: connections
        ))
    }

    func pasteNodes(from data: Data, offset: CGSize = CGSize(width: 44, height: 44)) throws -> Set<UUID> {
        let clipboard = try JSONDecoder().decode(CanvasNodeClipboard.self, from: data)
        guard !clipboard.nodes.isEmpty else { return [] }
        var mapping: [UUID: UUID] = [:]
        var created = Set<UUID>()
        var referencedAssets: [UUID] = []
        mutateSelectedDocument { document in
            for var node in clipboard.nodes {
                let oldID = node.id
                node.id = UUID()
                node.x += offset.width
                node.y += offset.height
                node.zIndex = (document.nodes.map(\.zIndex).max() ?? 0) + 1
                mapping[oldID] = node.id
                created.insert(node.id)
                if let assetID = node.asset?.id { referencedAssets.append(assetID) }
                document.nodes.append(node)
            }
            var connections = document.connections
            for connection in clipboard.connections {
                guard let source = mapping[connection.sourceNodeID],
                      let destination = mapping[connection.destinationNodeID] else { continue }
                connections.append(CanvasConnection(
                    sourceNodeID: source,
                    destinationNodeID: destination,
                    kind: connection.kind,
                    label: connection.label
                ))
            }
            document.connections = connections
        }
        for assetID in referencedAssets {
            Task { try? await creativeAssetStore?.adjustReference(assetID: assetID, by: 1) }
        }
        return created
    }

    func deleteNodes(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let assetIDs = selectedDocument?.nodes
            .filter { ids.contains($0.id) }
            .compactMap(\.asset?.id) ?? []
        mutateSelectedDocument { document in
            document.nodes.removeAll { ids.contains($0.id) }
            document.connections.removeAll {
                ids.contains($0.sourceNodeID) || ids.contains($0.destinationNodeID)
            }
        }
        for assetID in assetIDs {
            Task { try? await creativeAssetStore?.adjustReference(assetID: assetID, by: -1) }
        }
    }

    func nudgeNodes(_ ids: Set<UUID>, dx: Double, dy: Double) {
        guard !ids.isEmpty else { return }
        mutateSelectedDocument { document in
            for index in document.nodes.indices
            where ids.contains(document.nodes[index].id) && !document.nodes[index].isLocked {
                document.nodes[index].x += dx
                document.nodes[index].y += dy
            }
        }
    }

    func setLocked(_ ids: Set<UUID>, locked: Bool) {
        mutateSelectedDocument { document in
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                document.nodes[index].isLocked = locked
            }
        }
    }

    func group(_ ids: Set<UUID>) {
        guard ids.count > 1 else { return }
        let groupID = UUID()
        mutateSelectedDocument { document in
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                document.nodes[index].groupID = groupID
            }
        }
    }

    func setSyncEnabled(_ enabled: Bool) {
        var sync = project.sync ?? CanvasSyncSettings()
        sync.isEnabled = enabled
        sync.revision += 1
        project.sync = sync
        project.updatedAt = Date()
        persist()
    }

    func addResearchNote(
        text: String,
        sourceURLs: [String],
        runID: UUID
    ) {
        let count = selectedDocument?.nodes.count ?? 0
        mutateSelectedDocument { document in
            document.nodes.append(FloeCanvasNode(
                text: text,
                x: 320 + Double(count % 4) * 36,
                y: 250 + Double(count % 5) * 34,
                width: 340,
                height: 240,
                sourceURLs: sourceURLs,
                licenseStatus: "许可待确认",
                createdByRunID: runID
            ))
        }
    }

    func setAgentConversationID(_ id: UUID) {
        project.agentConversationID = id
        project.schemaVersion = 5
        project.updatedAt = Date()
        persist()
    }

    func updateNode(
        _ id: UUID,
        text: String? = nil,
        position: CGPoint? = nil,
        persistAfter: Bool = true
    ) {
        mutateSelectedDocument(persistAfter: persistAfter) { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
            if let text { document.nodes[index].text = text }
            if let position {
                document.nodes[index].x = position.x
                document.nodes[index].y = position.y
            }
        }
    }

    func updateNodeGeometry(
        _ id: UUID,
        width: Double? = nil,
        height: Double? = nil,
        rotation: Double? = nil,
        persistAfter: Bool = false
    ) {
        mutateSelectedDocument(persistAfter: persistAfter) { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == id }),
                  !document.nodes[index].isLocked else { return }
            if let width { document.nodes[index].width = min(2_400, max(80, width)) }
            if let height { document.nodes[index].height = min(2_400, max(60, height)) }
            if let rotation {
                document.nodes[index].rotation = rotation.truncatingRemainder(dividingBy: 360)
            }
        }
    }

    func deleteNode(_ id: UUID) {
        let assetID = selectedDocument?.nodes.first(where: { $0.id == id })?.asset?.id
        mutateSelectedDocument { $0.nodes.removeAll { $0.id == id } }
        if let assetID {
            Task { try? await creativeAssetStore?.adjustReference(assetID: assetID, by: -1) }
        }
    }

    func finishNodeMutation() {
        interactiveMutationRecorded = false
        project.updatedAt = Date()
        persist()
    }

    func beginStroke(at point: CGPoint, width: Double = 3, color: String = "primary") -> UUID {
        beginInteractiveMutation()
        let stroke = FloeCanvasStroke(points: [FloeCanvasPoint(point)], width: width, color: color)
        mutateSelectedDocument(persistAfter: false) { $0.strokes.append(stroke) }
        return stroke.id
    }

    func appendPoint(_ point: CGPoint, to strokeID: UUID) {
        mutateSelectedDocument(persistAfter: false) { document in
            guard let index = document.strokes.firstIndex(where: { $0.id == strokeID }) else { return }
            document.strokes[index].points.append(FloeCanvasPoint(point))
        }
    }

    func finishStroke() {
        interactiveMutationRecorded = false
        project.updatedAt = Date()
        persist()
    }

    func eraseStroke(near point: CGPoint, radius: Double = 24) {
        beginInteractiveMutation()
        mutateSelectedDocument(persistAfter: false) { document in
            document.strokes.removeAll { stroke in
                stroke.points.contains { sample in
                    hypot(sample.x - point.x, sample.y - point.y) <= radius
                }
            }
        }
    }

    func resizeNode(_ id: UUID, width: Double, height: Double) {
        mutateSelectedDocument { document in
            guard let index = document.nodes.firstIndex(where: { $0.id == id }),
                  !document.nodes[index].isLocked else { return }
            document.nodes[index].width = min(2_400, max(80, width))
            document.nodes[index].height = min(2_400, max(60, height))
        }
    }

    func rotateNodes(_ ids: Set<UUID>, degrees: Double) {
        mutateSelectedDocument { document in
            for index in document.nodes.indices
            where ids.contains(document.nodes[index].id) && !document.nodes[index].isLocked {
                document.nodes[index].rotation = degrees.truncatingRemainder(dividingBy: 360)
            }
        }
    }

    enum NodeAlignment { case leading, horizontalCenter, trailing, top, verticalCenter, bottom }

    func align(_ ids: Set<UUID>, to alignment: NodeAlignment) {
        guard ids.count > 1 else { return }
        mutateSelectedDocument { document in
            let selected = document.nodes.filter { ids.contains($0.id) }
            guard !selected.isEmpty else { return }
            let target: Double
            switch alignment {
            case .leading: target = selected.map { $0.x - $0.width / 2 }.min() ?? 0
            case .horizontalCenter: target = selected.map(\.x).reduce(0, +) / Double(selected.count)
            case .trailing: target = selected.map { $0.x + $0.width / 2 }.max() ?? 0
            case .top: target = selected.map { $0.y - $0.height / 2 }.min() ?? 0
            case .verticalCenter: target = selected.map(\.y).reduce(0, +) / Double(selected.count)
            case .bottom: target = selected.map { $0.y + $0.height / 2 }.max() ?? 0
            }
            for index in document.nodes.indices
            where ids.contains(document.nodes[index].id) && !document.nodes[index].isLocked {
                switch alignment {
                case .leading: document.nodes[index].x = target + document.nodes[index].width / 2
                case .horizontalCenter: document.nodes[index].x = target
                case .trailing: document.nodes[index].x = target - document.nodes[index].width / 2
                case .top: document.nodes[index].y = target + document.nodes[index].height / 2
                case .verticalCenter: document.nodes[index].y = target
                case .bottom: document.nodes[index].y = target - document.nodes[index].height / 2
                }
            }
        }
    }

    func distribute(_ ids: Set<UUID>, horizontally: Bool) {
        guard ids.count > 2 else { return }
        mutateSelectedDocument { document in
            let selected = document.nodes.filter { ids.contains($0.id) }
                .sorted { horizontally ? $0.x < $1.x : $0.y < $1.y }
            guard let first = selected.first, let last = selected.last else { return }
            let start = horizontally ? first.x : first.y
            let end = horizontally ? last.x : last.y
            let step = (end - start) / Double(selected.count - 1)
            for (offset, node) in selected.enumerated() {
                guard let index = document.nodes.firstIndex(where: { $0.id == node.id }),
                      !document.nodes[index].isLocked else { continue }
                if horizontally { document.nodes[index].x = start + Double(offset) * step }
                else { document.nodes[index].y = start + Double(offset) * step }
            }
        }
    }

    func changeLayer(_ ids: Set<UUID>, bringToFront: Bool) {
        mutateSelectedDocument { document in
            let edge = bringToFront
                ? (document.nodes.map(\.zIndex).max() ?? 0) + 1
                : (document.nodes.map(\.zIndex).min() ?? 0) - 1
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                document.nodes[index].zIndex = edge
            }
        }
    }

    func ungroup(_ ids: Set<UUID>) {
        mutateSelectedDocument { document in
            for index in document.nodes.indices where ids.contains(document.nodes[index].id) {
                document.nodes[index].groupID = nil
            }
        }
    }

    func clearDrawing() {
        mutateSelectedDocument {
            $0.strokes.removeAll()
            $0.pencilDrawingData = nil
        }
    }

    func updatePencilDrawing(_ data: Data?) {
        mutateSelectedDocument(persistAfter: false) { document in
            document.pencilDrawingData = data?.isEmpty == false ? data : nil
        }
        persist()
    }

    var hasNativeInk: Bool {
        guard let data = selectedDocument?.pencilDrawingData,
              let drawing = try? PKDrawing(data: data) else { return false }
        return !drawing.strokes.isEmpty
    }

    func removeStrokes(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        mutateSelectedDocument { document in
            document.strokes.removeAll { ids.contains($0.id) }
        }
    }

    func inkCapture(strokeIDs: Set<UUID>) throws -> CanvasInkCapture {
        guard let document = selectedDocument else {
            throw FloeError.validationFailed("当前没有画布。")
        }
        let strokes = document.strokes.filter { strokeIDs.contains($0.id) && $0.points.count > 1 }
        guard !strokes.isEmpty else {
            throw FloeError.validationFailed("请先画一些内容，或框选已有笔迹。")
        }
        let points = strokes.flatMap(\.points).map(\.cgPoint)
        let rawBounds = points.reduce(CGRect.null) {
            $0.union(CGRect(x: $1.x, y: $1.y, width: 1, height: 1))
        }
        guard !rawBounds.isNull else {
            throw FloeError.validationFailed("所选笔迹没有可识别内容。")
        }
        let canvasBounds = rawBounds.insetBy(dx: -32, dy: -32)
        let maximumDimension = 2_048.0
        let minimumScale = 1.6
        let renderScale = min(4, max(minimumScale, maximumDimension / max(canvasBounds.width, canvasBounds.height)))
        let size = CGSize(
            width: max(32, canvasBounds.width * renderScale),
            height: max(32, canvasBounds.height * renderScale)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { output in
            UIColor.white.setFill()
            output.fill(CGRect(origin: .zero, size: size))
            let context = output.cgContext
            context.saveGState()
            context.scaleBy(x: renderScale, y: renderScale)
            context.translateBy(x: -canvasBounds.minX, y: -canvasBounds.minY)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setStrokeColor(UIColor.black.cgColor)
            for stroke in strokes {
                context.setLineWidth(max(1.5, stroke.width))
                context.beginPath()
                context.move(to: stroke.points[0].cgPoint)
                for point in stroke.points.dropFirst() {
                    context.addLine(to: point.cgPoint)
                }
                context.strokePath()
            }
            context.restoreGState()
        }
        guard let data = image.pngData() else {
            throw FloeError.internalError("无法生成笔迹预览。")
        }
        return CanvasInkCapture(
            imageData: data,
            pixelWidth: Int(size.width),
            pixelHeight: Int(size.height),
            canvasBounds: canvasBounds
        )
    }

    func nativeInkCapture() throws -> CanvasInkCapture {
        guard let data = selectedDocument?.pencilDrawingData,
              let drawing = try? PKDrawing(data: data),
              !drawing.strokes.isEmpty else {
            throw FloeError.validationFailed("请先用 Apple Pencil 画一些内容。")
        }
        let bounds = drawing.bounds.insetBy(dx: -32, dy: -32)
        let scale = min(4, max(1.5, 2_048 / max(bounds.width, bounds.height)))
        let image = drawing.image(from: bounds, scale: scale)
        guard let imageData = image.pngData() else {
            throw FloeError.internalError("无法生成 PencilKit 笔迹预览。")
        }
        return CanvasInkCapture(
            imageData: imageData,
            pixelWidth: Int(max(1, bounds.width * scale)),
            pixelHeight: Int(max(1, bounds.height * scale)),
            canvasBounds: bounds
        )
    }

    func applyInkInterpretation(
        _ interpretation: CanvasInkInterpretation,
        strokeIDs: Set<UUID>,
        preserveOriginal: Bool
    ) -> Set<UUID> {
        guard !interpretation.nodes.isEmpty else { return [] }
        let source = interpretation.sourceBounds
        let targetSize = CGSize(
            width: max(480, min(1_400, source.width * 1.25)),
            height: max(320, min(1_100, source.height * 1.25))
        )
        let targetOrigin = preserveOriginal
            ? CGPoint(x: source.maxX + 72, y: source.minY)
            : source.origin
        let groupID = UUID()
        var mapping: [String: UUID] = [:]
        var created = Set<UUID>()
        mutateSelectedDocument { document in
            let firstZ = (document.nodes.map(\.zIndex).max() ?? 0) + 1
            for (offset, planned) in interpretation.nodes.prefix(40).enumerated() {
                let id = UUID()
                let kind = CanvasNodeKind(rawValue: planned.kind) ?? .stickyNote
                let shape = planned.shape.flatMap(CanvasShapeKind.init(rawValue:))
                let width = min(640, max(120, planned.width * targetSize.width))
                let height = min(520, max(70, planned.height * targetSize.height))
                let node = FloeCanvasNode(
                    id: id,
                    text: planned.text,
                    x: targetOrigin.x + min(1, max(0, planned.x)) * targetSize.width,
                    y: targetOrigin.y + min(1, max(0, planned.y)) * targetSize.height,
                    width: width,
                    height: height,
                    kind: kind,
                    rotation: 0,
                    zIndex: firstZ + offset,
                    isLocked: false,
                    groupID: groupID,
                    shape: kind == .shape ? (shape ?? .roundedRectangle) : nil,
                    metadata: [
                        "inkInterpretation": interpretation.summary,
                        "inkLayout": interpretation.layout,
                        "inkRoute": interpretation.routeDescription,
                        "convertedFromStrokeIDs": strokeIDs.map(\.uuidString).sorted().joined(separator: ",")
                    ]
                )
                document.nodes.append(node)
                mapping[planned.id] = id
                created.insert(id)
            }
            var connections = document.connections
            for planned in interpretation.connections.prefix(60) {
                guard let sourceID = mapping[planned.from], let targetID = mapping[planned.to],
                      sourceID != targetID else { continue }
                connections.append(CanvasConnection(
                    sourceNodeID: sourceID,
                    destinationNodeID: targetID,
                    kind: .arrow,
                    label: planned.label
                ))
            }
            document.connections = connections
            if !preserveOriginal {
                document.strokes.removeAll { strokeIDs.contains($0.id) }
            }
        }
        return created
    }

    func exportData(_ format: ExportFormat) throws -> Data {
        switch format {
        case .package:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try CanvasProjectCodec.encode(project, encoder: encoder)
        case .png:
            guard let image = renderCurrentDocument() else {
                throw FloeError.validationFailed("当前画布没有可导出的内容。")
            }
            guard let data = image.pngData() else {
                throw FloeError.validationFailed("无法生成 PNG。")
            }
            return data
        case .pdf:
            guard let image = renderCurrentDocument() else {
                throw FloeError.validationFailed("当前画布没有可导出的内容。")
            }
            let bounds = CGRect(origin: .zero, size: image.size)
            return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
                context.beginPage()
                image.draw(in: bounds)
            }
        }
    }

    private func renderCurrentDocument() -> UIImage? {
        guard let document = selectedDocument else { return nil }
        let nodeRects = document.nodes.map {
            CGRect(x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                   width: $0.width, height: $0.height)
        }
        let strokePoints = document.strokes.flatMap(\.points).map(\.cgPoint)
        let nativeDrawing = document.pencilDrawingData.flatMap { try? PKDrawing(data: $0) }
        let rawBounds = nodeRects.reduce(CGRect.null) { $0.union($1) }
            .union(strokePoints.reduce(CGRect.null) {
                $0.union(CGRect(x: $1.x, y: $1.y, width: 1, height: 1))
            })
            .union(nativeDrawing?.bounds ?? .null)
        guard !rawBounds.isNull else { return nil }
        let content = rawBounds.insetBy(dx: -60, dy: -60)
        let maximumDimension = 8_192.0
        let renderScale = min(1, maximumDimension / max(content.width, content.height))
        let size = CGSize(width: max(1, content.width * renderScale),
                          height: max(1, content.height * renderScale))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { output in
            UIColor.systemBackground.setFill()
            output.cgContext.fill(CGRect(origin: .zero, size: size))
            let context = output.cgContext
            context.saveGState()
            context.scaleBy(x: renderScale, y: renderScale)
            context.translateBy(x: -content.minX, y: -content.minY)

            context.setStrokeColor(UIColor.separator.cgColor)
            context.setLineWidth(2)
            let byID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
            for connection in document.connections {
                guard let source = byID[connection.sourceNodeID],
                      let target = byID[connection.destinationNodeID] else { continue }
                context.move(to: CGPoint(x: source.x, y: source.y))
                context.addLine(to: CGPoint(x: target.x, y: target.y))
                context.strokePath()
            }
            context.setStrokeColor(UIColor.label.cgColor)
            context.setLineCap(.round)
            for stroke in document.strokes where stroke.points.count > 1 {
                context.setLineWidth(stroke.width)
                context.beginPath()
                context.move(to: stroke.points[0].cgPoint)
                for point in stroke.points.dropFirst() { context.addLine(to: point.cgPoint) }
                context.strokePath()
            }
            if let nativeDrawing, !nativeDrawing.strokes.isEmpty {
                nativeDrawing.image(from: nativeDrawing.bounds, scale: 1)
                    .draw(in: nativeDrawing.bounds)
            }
            for node in document.nodes.sorted(by: { $0.zIndex < $1.zIndex }) {
                let rect = CGRect(x: node.x - node.width / 2, y: node.y - node.height / 2,
                                  width: node.width, height: node.height)
                context.saveGState()
                context.translateBy(x: node.x, y: node.y)
                context.rotate(by: CGFloat(node.rotation * .pi / 180))
                context.translateBy(x: -node.x, y: -node.y)
                UIColor.secondarySystemBackground.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 14).fill()
                UIColor.separator.setStroke()
                UIBezierPath(roundedRect: rect, cornerRadius: 14).stroke()
                let text = node.text.isEmpty ? node.kind.rawValue : node.text
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                (text as NSString).draw(
                    in: rect.insetBy(dx: 14, dy: 12),
                    withAttributes: [
                        .font: UIFont.preferredFont(forTextStyle: .body),
                        .foregroundColor: UIColor.label,
                        .paragraphStyle: paragraph
                    ]
                )
                context.restoreGState()
            }
            context.restoreGState()
        }
    }

    private func mutateSelectedDocument(
        persistAfter: Bool = true,
        _ mutation: (inout FloeCanvasDocument) -> Void
    ) {
        mutateDocument(project.selectedDocumentID, persistAfter: persistAfter, mutation)
    }

    private func mutateDocument(
        _ id: UUID,
        persistAfter: Bool = true,
        _ mutation: (inout FloeCanvasDocument) -> Void
    ) {
        guard let index = project.documents.firstIndex(where: { $0.id == id }) else { return }
        if persistAfter { recordHistory() }
        mutation(&project.documents[index])
        project.documents[index].updatedAt = Date()
        project.updatedAt = Date()
        if persistAfter { persist() }
    }

    private func recordHistory() {
        undoStack.append(project)
        if undoStack.count > 80 { undoStack.removeFirst(undoStack.count - 80) }
        redoStack.removeAll()
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            if syncOperationStore != nil, globalSyncEnabled,
               project.sync.isEnabled {
                var sync = project.sync
                sync.revision += 1
                project.sync = sync
            }
            let data = try CanvasProjectCodec.encode(project, encoder: encoder)
            try data.write(to: fileURL, options: .atomic)
            saveError = nil
            if let syncOperationStore, globalSyncEnabled,
               project.sync.isEnabled {
                let canvasID = project.id
                let operation = CanvasSyncOperation(
                    canvasID: canvasID, entityKind: .project,
                    entityID: canvasID, mutation: .upsert,
                    revision: project.sync.revision,
                    payload: data,
                    assetHashes: project.documents.flatMap(\.nodes)
                        .compactMap { $0.asset?.contentHash }
                )
                Task { try? await syncOperationStore.enqueue(operation) }
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private static func materialRelativePath(assetID: UUID) -> String? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return nil }
        let directory = support.appendingPathComponent("FloeAgent/Materials", isDirectory: true)
        let prefix = assetID.uuidString
        guard let match = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first(where: { $0.lastPathComponent.hasPrefix(prefix) }) else { return nil }
        return "Materials/\(match.lastPathComponent)"
    }
}

struct CanvasKeyboardActions {
    var canUndo = false
    var canRedo = false
    var hasNodeSelection = false
    var hasInkSelection = false
    let undo: () -> Void
    let redo: () -> Void
    let copy: () -> Void
    let paste: () -> Void
    let duplicate: () -> Void
    let delete: () -> Void
    let selectAll: () -> Void
    let group: () -> Void
    let ungroup: () -> Void
    let interpretInk: () -> Void
    let chooseTool: (Int) -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetView: () -> Void
    let nudge: (Double, Double) -> Void
}

private struct CanvasKeyboardActionsKey: FocusedValueKey {
    typealias Value = CanvasKeyboardActions
}

extension FocusedValues {
    var canvasKeyboardActions: CanvasKeyboardActions? {
        get { self[CanvasKeyboardActionsKey.self] }
        set { self[CanvasKeyboardActionsKey.self] = newValue }
    }
}

struct WorkspaceCanvasView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @AppStorage("creative.canvas.sync.enabled") private var globalCanvasSyncEnabled = true
    @StateObject private var store: CanvasDocumentStore
    private let workspace: WorkspaceRecord?
    @State private var selectedNodeIDs = Set<UUID>()
    @State private var editingNodeID: UUID?
    @State private var selectedStrokeIDs = Set<UUID>()
    @State private var mode: CanvasMode = .select
    @State private var canvasPreferences = CanvasPreferences.load()
    @State private var pencilWidth = CanvasPreferences.load().pencilWidth
    @State private var pencilColor = CanvasPreferences.load().pencilColor
    @State private var inkOutputPreference: CanvasInkOutputPreference = .automatic
    @State private var inkInterpretation: CanvasInkInterpretation?
    @State private var inkInterpretationSourceIDs = Set<UUID>()
    @State private var isInterpretingInk = false
    @State private var preservesInkAfterConversion = CanvasPreferences.load().preserveInkAfterConversion
    @State private var inkInterpretationError: String?
    @State private var scale = 1.0
    @State private var scaleStart = 1.0
    @State private var pan = CGSize.zero
    @State private var panStart = CGSize.zero
    @State private var nodeDragOrigins: [UUID: CGPoint] = [:]
    @State private var activeStrokeID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showsPencilPalette = false
    @State private var closedShapeSuggestion: CGRect?
    @State private var showsAgent = false
    @State private var isAgentCollapsed = false
    @State private var agentPanelOffset = CGSize.zero
    @State private var showsMaterials = false
    @State private var materialKindFilter: Set<CanvasNodeKind>?
    @State private var materialTargetNodeID: UUID?
    @State private var connectionStartID: UUID?
    @State private var connectionStartPort: CanvasConnectionPort?
    @State private var selectedConnectionID: UUID?
    @State private var pendingAgentRequest: CanvasAgentRequest?
    @State private var enteredGroupID: UUID?
    @State private var showsGeneration = false
    @State private var showsInspector = false
    @State private var showsMediaJobs = false
    @State private var directorPresentation: Canvas3DDirectorPresentation?
    @State private var canvasJobs: [MediaGenerationJob] = []
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var exportDocument: CanvasBinaryDocument?
    @State private var exportContentType: UTType = .floeCanvasPackage
    @State private var exportFilename = "Floe 画布"

    private static let nodePasteboardType = "org.floeagent.canvas.nodes"

    private enum CanvasMode: String, CaseIterable, Identifiable {
        case select, hand, pencil, eraser, card, text, shape, connector
        var id: String { rawValue }
        var title: String {
            switch self {
            case .select: "选择"
            case .hand: "移动画布"
            case .pencil: "画笔"
            case .eraser: "橡皮"
            case .card: "卡片"
            case .text: "文本"
            case .shape: "形状"
            case .connector: "连接线"
            }
        }
        var icon: String {
            switch self {
            case .select: "cursorarrow"
            case .hand: "hand.draw"
            case .pencil: "pencil.tip"
            case .eraser: "eraser"
            case .card: "note.text"
            case .text: "textformat"
            case .shape: "square.on.circle"
            case .connector: "point.topleft.down.to.point.bottomright.curvepath"
            }
        }
    }

    init(canvasID: UUID, name: String, workspace: WorkspaceRecord?) {
        self.workspace = workspace
        _store = StateObject(wrappedValue: CanvasDocumentStore(
            canvasID: canvasID,
            workspaceID: workspace?.id,
            canvasName: name
        ))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            documentSidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 300)
        } detail: {
            canvasDetail
        }
        .navigationSplitViewStyle(.balanced)
        // The app already owns the system sidebar toggle. Suppress the nested
        // automatic copy and expose the canvas-document list with a distinct,
        // labelled control inside the canvas toolbar.
        .toolbar(removing: .sidebarToggle)
        .alert("画布无法保存", isPresented: Binding(
            get: { store.saveError != nil },
            set: { if !$0 { store.saveError = nil } }
        )) {
            Button("完成", role: .cancel) { store.saveError = nil }
        } message: {
            Text(store.saveError ?? "")
        }
        .alert("画布已在其他设备删除", isPresented: $store.wasDeletedRemotely) {
            Button("返回创意模式") { dismiss() }
        } message: {
            Text("云端删除已经确认。当前设备不会重新上传这份旧画布。")
        }
        .sheet(isPresented: $showsMaterials) {
            NavigationStack {
                CanvasMaterialLibraryView(allowedKinds: materialKindFilter) { asset, kind in
                    if let materialTargetNodeID {
                        store.attachAsset(asset, kind: kind, to: materialTargetNodeID)
                        selectedNodeIDs = [materialTargetNodeID]
                    } else {
                        selectedNodeIDs = [store.addAsset(
                            asset, kind: kind,
                            at: canvasPoint(CGPoint(x: 520, y: 380))
                        )]
                    }
                    showsMaterials = false
                    materialKindFilter = nil
                    materialTargetNodeID = nil
                }
            }
        }
        .sheet(isPresented: $showsGeneration) {
            CanvasMediaGenerationView(store: store, sourceNodeIDs: selectedNodeIDs)
                .environmentObject(environment)
        }
        .sheet(isPresented: $showsInspector) {
            if let nodeID = selectedNodeIDs.first,
               let node = store.selectedDocument?.nodes.first(where: { $0.id == nodeID }) {
                CanvasNodeInspector(store: store, node: node, selectedIDs: selectedNodeIDs)
            }
        }
        .sheet(isPresented: $showsMediaJobs) {
            CanvasMediaJobCenter(
                jobs: canvasJobs,
                onCancel: { job in await cancel(job) },
                onRetry: { job in await retry(job) }
            )
        }
        .fullScreenCover(item: $directorPresentation) { presentation in
            if let node = store.selectedDocument?.nodes.first(where: {
                $0.id == presentation.nodeID
            }) {
                Canvas3DDirectorView(
                    initialScene: node.scene3D ?? .starter(),
                    onSave: { scene in
                        store.updateScene3D(scene, for: presentation.nodeID)
                        directorPresentation = nil
                    },
                    onCancel: { directorPresentation = nil }
                )
            }
        }
        .fileExporter(
            isPresented: Binding(
                get: { exportDocument != nil },
                set: { if !$0 { exportDocument = nil } }
            ),
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result { store.saveError = error.localizedDescription }
            exportDocument = nil
        }
        .task {
            store.configureSync(
                store: environment.canvasSyncOperationStore,
                assetStore: environment.creativeAssetStore,
                globalEnabled: globalCanvasSyncEnabled
            )
            await store.synchronizeFromCloud(environment.canvasCloudAssetService)
            while !Task.isCancelled {
                let canvasID = store.project.id
                if let jobs = try? await MediaGenerationJobStore(database: environment.database)
                    .jobs(canvasID: canvasID) {
                    canvasJobs = jobs
                    store.applyMediaJobs(jobs)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onChange(of: globalCanvasSyncEnabled) { _, enabled in
            store.configureSync(
                store: environment.canvasSyncOperationStore,
                assetStore: environment.creativeAssetStore,
                globalEnabled: enabled
            )
            if enabled {
                Task { await store.synchronizeFromCloud(environment.canvasCloudAssetService) }
            }
        }
        .onChange(of: showsMaterials) { _, presented in
            if !presented {
                materialTargetNodeID = nil
                materialKindFilter = nil
            }
        }
        .onChange(of: mode) { oldMode, newMode in
            if newMode == .pencil, oldMode != .pencil {
                selectedNodeIDs.removeAll()
                selectedStrokeIDs.removeAll()
                DispatchQueue.main.async {
                    showsPencilPalette = true
                }
            } else if newMode != .pencil {
                showsPencilPalette = false
            }
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .onChange(of: pencilWidth) { _, value in
            canvasPreferences.pencilWidth = value
            canvasPreferences.save()
        }
        .onChange(of: pencilColor) { _, value in
            canvasPreferences.pencilColor = value
            canvasPreferences.save()
        }
        .onChange(of: canvasPreferences) { _, value in value.save() }
        .focusedValue(\.canvasKeyboardActions, keyboardActions)
        .alert("无法整理笔迹", isPresented: Binding(
            get: { inkInterpretationError != nil },
            set: { if !$0 { inkInterpretationError = nil } }
        )) {
            Button("完成", role: .cancel) { inkInterpretationError = nil }
        } message: {
            Text(inkInterpretationError ?? "未知错误")
        }
    }

    private var documentSidebar: some View {
        List {
            ForEach(store.project.documents) { document in
                Button {
                    store.select(document.id)
                } label: {
                    HStack {
                        Image(systemName: document.id == store.project.selectedDocumentID
                              ? "rectangle.fill" : "rectangle")
                            .foregroundStyle(document.id == store.project.selectedDocumentID
                                             ? FloeTheme.primary : .secondary)
                        Text(document.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if document.id == store.project.selectedDocumentID {
                            Image(systemName: "checkmark")
                                .foregroundStyle(FloeTheme.primary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                    .contextMenu {
                        if store.project.documents.count > 1 {
                            Button("删除画布", role: .destructive) {
                                store.deleteDocument(document.id)
                            }
                        }
                    }
            }
        }
        .navigationTitle("画布")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { store.addDocument() } label: {
                    Label("新建画布", systemImage: "plus")
                }
            }
        }
    }

    private var canvasDetail: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
                if canvasPreferences.showGrid { grid(size: geometry.size) }
                if let document = store.selectedDocument {
                    CanvasPencilKitSurface(
                        drawingData: document.pencilDrawingData,
                        tool: mode == .eraser ? .eraser : .ink,
                        width: pencilWidth,
                        colorName: pencilColor,
                        fingerDrawingEnabled: canvasPreferences.fingerDrawingEnabled,
                        onDrawingChanged: store.updatePencilDrawing,
                        onClosedShape: { bounds in
                            withAnimation(.snappy) { closedShapeSuggestion = bounds }
                        }
                    )
                    .allowsHitTesting(mode == .pencil || mode == .eraser)
                    drawingLayer(document)
                    if mode != .pencil && mode != .eraser {
                        interactionLayer(size: geometry.size)
                    }
                    connectionLayer(document)
                        .allowsHitTesting(mode == .select)
                    nodeLayer(document)
                        .allowsHitTesting(mode == .select || mode == .connector)
                } else {
                    interactionLayer(size: geometry.size)
                }
                if let marqueeStart, let marqueeCurrent {
                    let rect = CGRect(
                        x: min(marqueeStart.x, marqueeCurrent.x),
                        y: min(marqueeStart.y, marqueeCurrent.y),
                        width: abs(marqueeCurrent.x - marqueeStart.x),
                        height: abs(marqueeCurrent.y - marqueeStart.y)
                    )
                    Rectangle()
                        .fill(FloeTheme.primary.opacity(0.10))
                        .overlay { Rectangle().stroke(FloeTheme.primary, style: StrokeStyle(dash: [5, 4])) }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                if let bounds = closedShapeSuggestion, mode == .pencil {
                    Button {
                        selectedNodeIDs = [store.addCard(
                            at: canvasPoint(CGPoint(x: bounds.midX, y: bounds.midY)),
                            text: "新建卡片"
                        )]
                        withAnimation(.snappy) { closedShapeSuggestion = nil }
                        mode = .select
                    } label: {
                        Label("转为卡片", systemImage: "note.text.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .position(
                        x: min(max(90, bounds.midX), geometry.size.width - 90),
                        y: min(max(30, bounds.maxY + 30), geometry.size.height - 30)
                    )
                    .zIndex(15)
                }
                if showsAgent {
                    CanvasAgentFloatingPanel(
                        store: store,
                        workspace: workspace,
                        contextSnapshot: canvasAgentContext,
                        pendingRequest: $pendingAgentRequest,
                        availableSize: geometry.size,
                        offset: $agentPanelOffset,
                        isCollapsed: $isAgentCollapsed,
                        onClose: {
                            withAnimation(.snappy) { showsAgent = false }
                        }
                    )
                    .environmentObject(environment)
                    .frame(
                        width: min(420, max(280, geometry.size.width - 24)),
                        height: isAgentCollapsed
                            ? 52
                            : min(680, max(300, geometry.size.height - 96))
                    )
                    .offset(agentPanelOffset)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(20)
                }
                if isInterpretingInk {
                    HStack(spacing: 10) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("正在理解笔迹").font(.headline)
                            Text("先识别内容与关系，再生成可编辑节点")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(radius: 12, y: 4)
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(30)
                } else if let inkInterpretation {
                    CanvasInkInterpretationPanel(
                        interpretation: inkInterpretation,
                        preservesOriginal: $preservesInkAfterConversion,
                        onApply: applyInkInterpretation,
                        onRetry: interpretSelectedInk,
                        onCancel: {
                            withAnimation(.snappy) { self.inkInterpretation = nil }
                        }
                    )
                    .frame(width: min(430, max(300, geometry.size.width - 32)))
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(30)
                }
                CanvasPencilInteractionBridge {
                    switch canvasPreferences.doubleTapAction {
                    case .toggleEraser:
                        withAnimation(.snappy) {
                            mode = mode == .eraser ? .pencil : .eraser
                        }
                    case .showToolPalette:
                        mode = .pencil
                        showsPencilPalette = true
                    case .createCard:
                        selectedNodeIDs = [store.addCard(at: canvasPoint(
                            CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        ), text: "新建卡片")]
                        mode = .select
                    }
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .overlay(alignment: .topLeading) { modeControls(size: geometry.size) }
            .overlay(alignment: .bottom) { selectionToolbar }
            .navigationTitle(store.selectedDocument?.name ?? "画布")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        withAnimation(.snappy) {
                            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                        }
                    } label: {
                        Label(
                            columnVisibility == .detailOnly ? "显示画布列表" : "隐藏画布列表",
                            systemImage: "rectangle.split.1x2"
                        )
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Menu {
                            Section("基础节点") {
                                Button("文本", systemImage: "textformat") {
                                    createNode { store.addNote(at: $0) }
                                }
                                Button("卡片", systemImage: "note.text") {
                                    createNode { store.addCard(at: $0) }
                                }
                                Button("形状", systemImage: "square.on.circle") {
                                    createNode { store.addShape(at: $0) }
                                }
                                Button("分组", systemImage: "square.3.layers.3d") {
                                    createNode { store.addGroup(at: $0) }
                                }
                            }
                            Section("媒体与文件") {
                                placeholderCreationButton("图片卡片", icon: "photo", kind: .image)
                                placeholderCreationButton("视频卡片", icon: "film", kind: .video)
                                placeholderCreationButton("音频卡片", icon: "waveform", kind: .audio)
                                placeholderCreationButton("文件卡片", icon: "doc", kind: .file)
                                Button("从素材库添加…", systemImage: "photo.on.rectangle.angled") {
                                    materialTargetNodeID = nil
                                    materialKindFilter = [.image, .video, .audio, .file]
                                    showsMaterials = true
                                }
                            }
                            Section("创作节点") {
                                placeholderCreationButton(
                                    "生成配置", icon: "wand.and.stars", kind: .generationTask
                                )
                                Button("3D 场景", systemImage: "cube.transparent") {
                                    let point = canvasPoint(CGPoint(x: 520, y: 380))
                                    let nodeID = store.addScene3D(at: point)
                                    selectedNodeIDs = [nodeID]
                                    directorPresentation = Canvas3DDirectorPresentation(nodeID: nodeID)
                                }
                            }
                        } label: {
                            Label("新建节点", systemImage: "plus")
                        }
                        .accessibilityIdentifier("canvas.node.create")
                        Button("撤销", systemImage: "arrow.uturn.backward") { store.undo() }
                            .disabled(!store.canUndo)
                        Button("重做", systemImage: "arrow.uturn.forward") { store.redo() }
                            .disabled(!store.canRedo)
                        Button {
                            withAnimation(.snappy) {
                                showsAgent = true
                                isAgentCollapsed = false
                            }
                        } label: {
                            Label("画布助手", systemImage: "sparkles")
                        }
                        Button {
                            materialTargetNodeID = nil
                            materialKindFilter = nil
                            showsMaterials = true
                        } label: {
                            Label("素材库", systemImage: "photo.on.rectangle.angled")
                        }
                        Button {
                            showsGeneration = true
                        } label: {
                            Label("生成", systemImage: "wand.and.stars")
                        }
                        Button {
                            showsMediaJobs = true
                        } label: {
                            Label("媒体任务", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                        }
                        .badge(canvasJobs.filter { !$0.state.isTerminal }.count)
                        Button {
                            let existing = store.selectedDocument?.nodes.first(where: {
                                selectedNodeIDs.contains($0.id) && $0.kind == .scene3D
                            })?.id
                            let nodeID = existing ?? store.addScene3D(
                                at: canvasPoint(CGPoint(x: 520, y: 380))
                            )
                            selectedNodeIDs = [nodeID]
                            directorPresentation = Canvas3DDirectorPresentation(nodeID: nodeID)
                        } label: {
                            Label("3D 导演台", systemImage: "cube.transparent")
                        }
                        Menu {
                            Toggle("同步此画布", isOn: Binding(
                                get: { store.project.sync.isEnabled },
                                set: { store.setSyncEnabled($0) }
                            ))
                            if !selectedNodeIDs.isEmpty {
                                Button("属性") { showsInspector = true }
                                Button("复制到剪贴板", action: copySelection)
                                Button("复制副本") { selectedNodeIDs = store.duplicateNodes(selectedNodeIDs) }
                                Button("分组") { store.group(selectedNodeIDs) }
                                Button("取消分组") { store.ungroup(selectedNodeIDs) }
                                Button("锁定") { store.setLocked(selectedNodeIDs, locked: true) }
                                Button("解锁") { store.setLocked(selectedNodeIDs, locked: false) }
                                Menu("对齐") {
                                    Button("左对齐") { store.align(selectedNodeIDs, to: .leading) }
                                    Button("水平居中") { store.align(selectedNodeIDs, to: .horizontalCenter) }
                                    Button("右对齐") { store.align(selectedNodeIDs, to: .trailing) }
                                    Button("顶部对齐") { store.align(selectedNodeIDs, to: .top) }
                                    Button("垂直居中") { store.align(selectedNodeIDs, to: .verticalCenter) }
                                    Button("底部对齐") { store.align(selectedNodeIDs, to: .bottom) }
                                }
                                Menu("分布") {
                                    Button("水平等距") { store.distribute(selectedNodeIDs, horizontally: true) }
                                    Button("垂直等距") { store.distribute(selectedNodeIDs, horizontally: false) }
                                }
                                Menu("层级") {
                                    Button("移到最前") { store.changeLayer(selectedNodeIDs, bringToFront: true) }
                                    Button("移到最后") { store.changeLayer(selectedNodeIDs, bringToFront: false) }
                                }
                                Button("删除所选节点", role: .destructive, action: deleteSelection)
                            }
                            if !selectedStrokeIDs.isEmpty {
                                Button("整理所选笔迹", systemImage: "wand.and.rays", action: interpretSelectedInk)
                                Button("删除所选笔迹", role: .destructive) {
                                    store.removeStrokes(selectedStrokeIDs)
                                    selectedStrokeIDs.removeAll()
                                }
                            }
                            Menu("导出") {
                                Button("可编辑 Floe 画布包") { prepareExport(.package) }
                                Button("PNG 图片") { prepareExport(.png) }
                                Button("PDF") { prepareExport(.pdf) }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
    }

    private func createNode(_ factory: (CGPoint) -> UUID) {
        selectedNodeIDs = [factory(canvasPoint(CGPoint(x: 520, y: 380)))]
        selectedStrokeIDs.removeAll()
        selectedConnectionID = nil
        mode = .select
    }

    private func placeholderCreationButton(
        _ title: String,
        icon: String,
        kind: CanvasNodeKind
    ) -> some View {
        Button(title, systemImage: icon) {
            createNode { store.addPlaceholder(kind: kind, at: $0) }
        }
    }

    private func grid(size: CGSize) -> some View {
        Canvas { context, _ in
            let spacing = max(18, 42 * scale)
            let xStart = pan.width.truncatingRemainder(dividingBy: spacing)
            let yStart = pan.height.truncatingRemainder(dividingBy: spacing)
            var path = Path()
            var x = xStart
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y = yStart
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(.secondary.opacity(0.12)), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }

    private func drawingLayer(_ document: FloeCanvasDocument) -> some View {
        Canvas { context, _ in
            for stroke in document.strokes where stroke.points.count > 1 {
                let points = stroke.points.map { screenPoint($0.cgPoint) }
                let path = Self.smoothedPath(points)
                if selectedStrokeIDs.contains(stroke.id) {
                    context.stroke(
                        path,
                        with: .color(FloeTheme.primary.opacity(0.28)),
                        style: StrokeStyle(
                            lineWidth: (stroke.width + 8) * scale,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
                context.stroke(
                    path,
                    with: .color(stroke.color == "blue" ? .blue : .primary),
                    style: StrokeStyle(
                        lineWidth: stroke.width * scale,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    private static func smoothedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return path
        }
        for index in 1..<points.count {
            let current = points[index]
            let previous = points[index - 1]
            let midpoint = CGPoint(
                x: (previous.x + current.x) / 2,
                y: (previous.y + current.y) / 2
            )
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }

    private func connectionLayer(_ document: FloeCanvasDocument) -> some View {
        let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
        return ZStack {
            Canvas { context, _ in
                for connection in document.connections {
                    guard let source = nodes[connection.sourceNodeID],
                          let destination = nodes[connection.destinationNodeID] else { continue }
                    let start = screenPoint(connectionAnchor(
                        node: source,
                        port: connection.sourcePort,
                        toward: CGPoint(x: destination.x, y: destination.y)
                    ))
                    let end = screenPoint(connectionAnchor(
                        node: destination,
                        port: connection.destinationPort,
                        toward: CGPoint(x: source.x, y: source.y)
                    ))
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: end)
                    let selected = selectedConnectionID == connection.id
                    context.stroke(
                        path,
                        with: .color(selected ? FloeTheme.primary : FloeTheme.primary.opacity(0.65)),
                        style: StrokeStyle(
                            lineWidth: selected ? 4 : 2,
                            dash: connection.kind == .source ? [7, 5] : []
                        )
                    )
                }
            }
            .allowsHitTesting(false)

            ForEach(document.connections) { connection in
                if let source = nodes[connection.sourceNodeID],
                   let destination = nodes[connection.destinationNodeID] {
                    let start = screenPoint(connectionAnchor(
                        node: source,
                        port: connection.sourcePort,
                        toward: CGPoint(x: destination.x, y: destination.y)
                    ))
                    let end = screenPoint(connectionAnchor(
                        node: destination,
                        port: connection.destinationPort,
                        toward: CGPoint(x: source.x, y: source.y)
                    ))
                    let dx = end.x - start.x
                    let dy = end.y - start.y
                    Capsule()
                        .fill(Color.black.opacity(0.001))
                        .frame(width: max(32, hypot(dx, dy)), height: 30)
                        .rotationEffect(.radians(atan2(dy, dx)))
                        .position(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedConnectionID = connection.id
                            selectedNodeIDs.removeAll()
                            selectedStrokeIDs.removeAll()
                            editingNodeID = nil
                        }
                        .accessibilityLabel("连接线")
                        .accessibilityHint("点按后可反向或删除")
                        .accessibilityIdentifier("canvas.connection.\(connection.id.uuidString)")
                }
            }
        }
    }

    private func nodeLayer(_ document: FloeCanvasDocument) -> some View {
        ForEach(document.nodes.sorted { $0.zIndex < $1.zIndex }) { node in
            CanvasNodeCard(
                node: node,
                text: Binding(
                    get: { node.text },
                    set: { store.updateNode(node.id, text: $0) }
                ),
                isSelected: selectedNodeIDs.contains(node.id),
                isEditing: editingNodeID == node.id,
                sourceURLs: node.sourceURLs.map(\.absoluteString),
                licenseStatus: node.licenseStatus,
                onOpen3D: node.kind == .scene3D ? {
                    directorPresentation = Canvas3DDirectorPresentation(nodeID: node.id)
                } : nil,
                onBeginEditing: {
                    selectedNodeIDs = [node.id]
                    selectedConnectionID = nil
                    editingNodeID = node.id
                },
                onDuplicate: {
                    selectedNodeIDs = store.duplicateNodes(contextSelection(for: node))
                    selectedConnectionID = nil
                    editingNodeID = nil
                },
                onConnect: {
                    selectedNodeIDs = contextSelection(for: node)
                    connectionStartID = node.id
                    selectedConnectionID = nil
                    editingNodeID = nil
                    mode = .connector
                },
                onToggleLock: {
                    store.setLocked(contextSelection(for: node), locked: !node.isLocked)
                },
                onBringToFront: {
                    store.changeLayer(contextSelection(for: node), bringToFront: true)
                },
                onSendToBack: {
                    store.changeLayer(contextSelection(for: node), bringToFront: false)
                },
                onGroup: {
                    store.group(contextSelection(for: node))
                },
                onUngroup: {
                    store.ungroup(contextSelection(for: node))
                    enteredGroupID = nil
                },
                onDelete: {
                    let ids = contextSelection(for: node)
                    store.deleteNodes(ids)
                    selectedNodeIDs.subtract(ids)
                }
            )
            .frame(width: node.width, height: node.height)
            .overlay {
                ZStack {
                    if selectedNodeIDs.contains(node.id), mode == .select, !node.isLocked {
                        CanvasNodeSelectionChrome(
                            node: node,
                            onBegin: store.beginInteractiveMutation,
                            onGeometryChanged: { width, height, rotation in
                                store.updateNodeGeometry(
                                    node.id,
                                    width: width,
                                    height: height,
                                    rotation: rotation,
                                    persistAfter: false
                                )
                            },
                            onEnd: store.finishNodeMutation
                        )
                    }
                    if selectedNodeIDs.contains(node.id) || mode == .connector {
                        CanvasConnectionPortsOverlay(
                            activePort: connectionStartID == node.id ? connectionStartPort : nil,
                            onTap: { handleConnectionPort(nodeID: node.id, port: $0) }
                        )
                    }
                    if selectedNodeIDs.count == 1,
                       selectedNodeIDs.contains(node.id),
                       mode == .select,
                       editingNodeID == nil {
                        CanvasNodeInlineAIComposer(nodeTitle: node.text) { request in
                            pendingAgentRequest = CanvasAgentRequest(
                                nodeID: node.id,
                                prompt: request
                            )
                            withAnimation(.snappy) {
                                showsAgent = true
                                isAgentCollapsed = false
                            }
                        }
                        .offset(y: node.height / 2 + 34)
                    }
                }
            }
            .scaleEffect(scale)
            .position(screenPoint(CGPoint(x: node.x, y: node.y)))
            .rotationEffect(.degrees(node.rotation))
            .onTapGesture(count: 2) {
                guard mode == .select else { return }
                selectedConnectionID = nil
                if let groupID = node.groupID, enteredGroupID != groupID {
                    enteredGroupID = groupID
                    selectedNodeIDs = [node.id]
                    editingNodeID = nil
                } else {
                    selectedNodeIDs = [node.id]
                    editingNodeID = node.id
                }
            }
            .onTapGesture {
                if mode == .connector {
                    if let source = connectionStartID {
                        store.connect(source, to: node.id, sourcePort: connectionStartPort)
                        connectionStartID = nil
                        connectionStartPort = nil
                    } else {
                        connectionStartID = node.id
                        connectionStartPort = nil
                    }
                } else {
                    // Selection is stable: a second click begins no hidden
                    // toggle. Editing is an explicit double-click/menu action.
                    selectedConnectionID = nil
                    selectedNodeIDs = selectionForNode(node)
                    editingNodeID = nil
                }
            }
            .simultaneousGesture(
                DragGesture()
                    .onChanged { value in
                        guard mode == .select, !node.isLocked else { return }
                        updateNodeDrag(node, translation: value.translation)
                    }
                    .onEnded { _ in
                        guard mode == .select else { return }
                        finishNodeDrag()
                    }
            )
        }
    }

    private func handleConnectionPort(nodeID: UUID, port: CanvasConnectionPort) {
        selectedConnectionID = nil
        editingNodeID = nil
        if let source = connectionStartID, source != nodeID {
            store.connect(
                source,
                to: nodeID,
                sourcePort: connectionStartPort,
                destinationPort: port
            )
            connectionStartID = nil
            connectionStartPort = nil
            selectedNodeIDs = [nodeID]
            mode = .select
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            connectionStartID = nodeID
            connectionStartPort = port
            selectedNodeIDs = [nodeID]
            mode = .connector
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    private func connectionAnchor(
        node: FloeCanvasNode,
        port: CanvasConnectionPort?,
        toward target: CGPoint
    ) -> CGPoint {
        let resolvedPort: CanvasConnectionPort
        if let port {
            resolvedPort = port
        } else {
            let dx = target.x - node.x
            let dy = target.y - node.y
            resolvedPort = abs(dx) >= abs(dy)
                ? (dx >= 0 ? .trailing : .leading)
                : (dy >= 0 ? .bottom : .top)
        }
        switch resolvedPort {
        case .top:
            return CGPoint(x: node.x, y: node.y - node.height / 2)
        case .trailing:
            return CGPoint(x: node.x + node.width / 2, y: node.y)
        case .bottom:
            return CGPoint(x: node.x, y: node.y + node.height / 2)
        case .leading:
            return CGPoint(x: node.x - node.width / 2, y: node.y)
        }
    }

    private var canvasAgentContext: String {
        guard let document = store.selectedDocument else { return "当前画布为空。" }
        let selected = document.nodes.filter { selectedNodeIDs.contains($0.id) }
        guard !selected.isEmpty else {
            return "当前画布：\(document.name)。节点数：\(document.nodes.count)，关系数：\(document.connections.count)。当前没有选中节点。"
        }
        let selectedIDs = Set(selected.map(\.id))
        let relations = document.connections.filter {
            selectedIDs.contains($0.sourceNodeID) || selectedIDs.contains($0.destinationNodeID)
        }
        let relatedIDs = Set(relations.flatMap { [$0.sourceNodeID, $0.destinationNodeID] })
            .subtracting(selectedIDs)
        let related = document.nodes.filter { relatedIDs.contains($0.id) }.prefix(8)
        let selectedSummary = selected.prefix(12).map {
            "- \($0.id.uuidString): \($0.kind.rawValue), \($0.text.prefix(240))"
        }.joined(separator: "\n")
        let relatedSummary = related.map {
            "- \($0.id.uuidString): \($0.kind.rawValue), \($0.text.prefix(160))"
        }.joined(separator: "\n")
        return """
        当前画布：\(document.name)
        当前选择：
        \(selectedSummary)
        相连节点：
        \(relatedSummary.isEmpty ? "无" : relatedSummary)
        相关连接数：\(relations.count)
        """
    }

    private func selectionForNode(_ node: FloeCanvasNode) -> Set<UUID> {
        guard let groupID = node.groupID, enteredGroupID != groupID else { return [node.id] }
        return Set(store.selectedDocument?.nodes.compactMap {
            $0.groupID == groupID ? $0.id : nil
        } ?? [node.id])
    }

    private func contextSelection(for node: FloeCanvasNode) -> Set<UUID> {
        selectedNodeIDs.contains(node.id) ? selectedNodeIDs : selectionForNode(node)
    }

    private func updateNodeDrag(_ node: FloeCanvasNode, translation: CGSize) {
        if !selectedNodeIDs.contains(node.id) {
            selectedNodeIDs = selectionForNode(node)
        }
        selectedConnectionID = nil
        if nodeDragOrigins.isEmpty {
            let nodes = store.selectedDocument?.nodes ?? []
            nodeDragOrigins = Dictionary(uniqueKeysWithValues: nodes.compactMap { candidate in
                guard selectedNodeIDs.contains(candidate.id), !candidate.isLocked else { return nil }
                return (candidate.id, CGPoint(x: candidate.x, y: candidate.y))
            })
            guard !nodeDragOrigins.isEmpty else { return }
            store.beginInteractiveMutation()
        }
        for (id, origin) in nodeDragOrigins {
            store.updateNode(
                id,
                position: CGPoint(
                    x: origin.x + translation.width / scale,
                    y: origin.y + translation.height / scale
                ),
                persistAfter: false
            )
        }
    }

    private func finishNodeDrag() {
        guard !nodeDragOrigins.isEmpty else { return }
        nodeDragOrigins.removeAll()
        store.finishNodeMutation()
    }

    private func interactionLayer(size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: mode == .pencil || mode == .eraser ? 0 : 4)
                    .onChanged { value in
                        switch mode {
                        case .hand:
                            pan = CGSize(
                                width: panStart.width + value.translation.width,
                                height: panStart.height + value.translation.height
                            )
                        case .pencil, .eraser:
                            let point = canvasPoint(value.location)
                            if mode == .eraser {
                                store.eraseStroke(near: point)
                            } else {
                                if let activeStrokeID {
                                    store.appendPoint(point, to: activeStrokeID)
                                } else {
                                    let newID = store.beginStroke(
                                        at: point,
                                        width: pencilWidth,
                                        color: pencilColor
                                    )
                                    activeStrokeID = newID
                                    selectedStrokeIDs.insert(newID)
                                }
                            }
                        case .select:
                            if marqueeStart == nil { marqueeStart = value.startLocation }
                            marqueeCurrent = value.location
                        case .card, .text, .shape, .connector: break
                        }
                    }
                    .onEnded { _ in
                        if mode == .hand {
                            panStart = pan
                        } else if mode == .pencil || mode == .eraser {
                            activeStrokeID = nil
                            store.finishStroke()
                        } else if mode == .select, let start = marqueeStart, let end = marqueeCurrent {
                            let a = canvasPoint(start), b = canvasPoint(end)
                            let rect = CGRect(
                                x: min(a.x, b.x), y: min(a.y, b.y),
                                width: abs(b.x - a.x), height: abs(b.y - a.y)
                            )
                            selectedNodeIDs = Set(store.selectedDocument?.nodes.filter {
                                rect.intersects(CGRect(
                                    x: $0.x - $0.width / 2, y: $0.y - $0.height / 2,
                                    width: $0.width, height: $0.height
                                ))
                            }.map(\.id) ?? [])
                            selectedStrokeIDs = Set(store.selectedDocument?.strokes.filter { stroke in
                                let points = stroke.points.map(\.cgPoint)
                                guard let first = points.first else { return false }
                                let bounds = points.dropFirst().reduce(
                                    CGRect(x: first.x, y: first.y, width: 1, height: 1)
                                ) { partial, point in
                                    partial.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
                                }
                                return rect.intersects(bounds)
                            }.map(\.id) ?? [])
                            selectedConnectionID = nil
                            marqueeStart = nil; marqueeCurrent = nil
                        }
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = min(3, max(0.3, scaleStart * value))
                    }
                    .onEnded { _ in
                        scaleStart = scale
                    }
            )
            .gesture(SpatialTapGesture().onEnded { value in
                switch mode {
                case .select:
                    selectedNodeIDs.removeAll()
                    selectedStrokeIDs.removeAll()
                    selectedConnectionID = nil
                    editingNodeID = nil
                case .text:
                    selectedNodeIDs = [store.addNote(at: canvasPoint(value.location))]
                    mode = .select
                case .card:
                    selectedNodeIDs = [store.addCard(at: canvasPoint(value.location))]
                    mode = .select
                case .shape:
                    selectedNodeIDs = [store.addShape(at: canvasPoint(value.location))]
                    mode = .select
                case .hand, .pencil, .eraser, .connector: break
                }
            })
    }

    private func modeControls(size: CGSize) -> some View {
        HStack(spacing: 4) {
            ForEach(CanvasMode.allCases) { value in
                Button {
                    if value == .pencil {
                        mode = .pencil
                        showsPencilPalette.toggle()
                    } else {
                        showsPencilPalette = false
                        mode = value
                    }
                } label: {
                    Image(systemName: value.icon)
                        .font(.body.weight(mode == value ? .semibold : .regular))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(mode == value ? Color.white : Color.primary)
                .background(
                    mode == value ? FloeTheme.primary : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .accessibilityLabel(value.title)
                .accessibilityAddTraits(mode == value ? .isSelected : [])
                .accessibilityIdentifier("canvas.tool.\(value.rawValue)")
            }

            Divider().frame(height: 24).padding(.horizontal, 2)

            Menu {
                Picker("整理方式", selection: $inkOutputPreference) {
                    ForEach(CanvasInkOutputPreference.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                if mode == .eraser {
                    Button("清除全部笔迹", systemImage: "trash", role: .destructive) {
                        store.clearDrawing()
                        selectedStrokeIDs.removeAll()
                    }
                }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel("笔迹整理方式：\(inkOutputPreference.title)")

            Button(action: interpretSelectedInk) {
                Image(systemName: "wand.and.rays")
                    .frame(width: 32, height: 32)
                    .overlay(alignment: .topTrailing) {
                        if !selectedStrokeIDs.isEmpty {
                            Text("\(selectedStrokeIDs.count)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(FloeTheme.primary, in: Circle())
                                .offset(x: 5, y: -5)
                        }
                    }
            }
            .accessibilityLabel(selectedStrokeIDs.isEmpty ? "整理笔迹" : "整理所选笔迹")
            .disabled((selectedStrokeIDs.isEmpty && !store.hasNativeInk) || isInterpretingInk)
        }
        .padding(5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .popover(isPresented: $showsPencilPalette, arrowEdge: .top) {
            CanvasPencilPalette(
                width: $pencilWidth,
                colorName: $pencilColor,
                fingerDrawingEnabled: $canvasPreferences.fingerDrawingEnabled,
                onCreateCard: {
                    selectedNodeIDs = [store.addCard(
                        at: canvasPoint(CGPoint(x: size.width / 2, y: size.height / 2)),
                        text: "新建卡片"
                    )]
                    showsPencilPalette = false
                    mode = .select
                },
                onCreateText: {
                    selectedNodeIDs = [store.addNote(
                        at: canvasPoint(CGPoint(x: size.width / 2, y: size.height / 2))
                    )]
                    showsPencilPalette = false
                    mode = .select
                },
                onCreateShape: {
                    selectedNodeIDs = [store.addShape(
                        at: canvasPoint(CGPoint(x: size.width / 2, y: size.height / 2))
                    )]
                    showsPencilPalette = false
                    mode = .select
                }
            )
            .presentationCompactAdaptation(.popover)
        }
        .padding(12)
    }

    @ViewBuilder
    private var selectionToolbar: some View {
        if let connectionID = selectedConnectionID, mode == .select {
            HStack(spacing: 4) {
                Button("反向", systemImage: "arrow.left.arrow.right") {
                    store.reverseConnection(connectionID)
                }
                Button("删除连接", systemImage: "trash", role: .destructive) {
                    store.deleteConnection(connectionID)
                    selectedConnectionID = nil
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 18)
            .accessibilityIdentifier("canvas.connection.toolbar")
        } else if !selectedNodeIDs.isEmpty, mode == .select {
            HStack(spacing: 4) {
                if selectedNodeIDs.count == 1, let nodeID = selectedNodeIDs.first {
                    Button("编辑", systemImage: "pencil") { editingNodeID = nodeID }
                }
                Button("复制", systemImage: "plus.square.on.square") {
                    selectedNodeIDs = store.duplicateNodes(selectedNodeIDs)
                    editingNodeID = nil
                }
                Button("连接", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                    connectionStartID = selectedNodeIDs.first
                    editingNodeID = nil
                    mode = .connector
                }
                if let selectedGroupID, enteredGroupID != selectedGroupID {
                    Button("进入分组", systemImage: "rectangle.inset.filled") {
                        enteredGroupID = selectedGroupID
                        if let first = selectedNodeIDs.first { selectedNodeIDs = [first] }
                        editingNodeID = nil
                    }
                } else if enteredGroupID != nil {
                    Button("退出分组", systemImage: "rectangle.portrait.and.arrow.right") {
                        enteredGroupID = nil
                        editingNodeID = nil
                    }
                } else {
                    Button("分组", systemImage: "square.3.layers.3d") {
                        store.group(selectedNodeIDs)
                        editingNodeID = nil
                    }
                }
                if let attachable = selectedAttachableNode {
                    Button(
                        attachable.asset == nil ? "选择素材" : "替换素材",
                        systemImage: "photo.badge.plus"
                    ) {
                        materialTargetNodeID = attachable.id
                        materialKindFilter = [attachable.kind]
                        showsMaterials = true
                    }
                }
                Button("属性", systemImage: "slider.horizontal.3") { showsInspector = true }
                Button("生成", systemImage: "wand.and.stars") { showsGeneration = true }
                Button("删除", systemImage: "trash", role: .destructive) { deleteSelection() }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .padding(8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("canvas.node.toolbar")
        }
    }

    private var selectedGroupID: UUID? {
        let selectedNodes = store.selectedDocument?.nodes.filter { selectedNodeIDs.contains($0.id) } ?? []
        let groups = Set(selectedNodes.compactMap(\.groupID))
        guard groups.count == 1, selectedNodes.allSatisfy({ $0.groupID == groups.first }) else { return nil }
        return groups.first
    }

    private var selectedAttachableNode: FloeCanvasNode? {
        guard selectedNodeIDs.count == 1,
              let id = selectedNodeIDs.first,
              let node = store.selectedDocument?.nodes.first(where: { $0.id == id }),
              [.image, .video, .audio, .file].contains(node.kind) else { return nil }
        return node
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                scale = max(0.3, scale - 0.2)
                scaleStart = scale
            } label: {
                Image(systemName: "minus")
            }
            Text("\(Int(scale * 100))%")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 48)
            Button {
                scale = min(3, scale + 0.2)
                scaleStart = scale
            } label: {
                Image(systemName: "plus")
            }
            Button {
                scale = 1
                scaleStart = 1
                pan = .zero
                panStart = .zero
            } label: {
                Image(systemName: "scope")
            }
            .accessibilityLabel("重置画布视图")
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(.regularMaterial, in: Capsule())
        .padding(12)
    }

    private var keyboardActions: CanvasKeyboardActions {
        CanvasKeyboardActions(
            canUndo: store.canUndo,
            canRedo: store.canRedo,
            hasNodeSelection: !selectedNodeIDs.isEmpty,
            hasInkSelection: !selectedStrokeIDs.isEmpty || store.hasNativeInk,
            undo: { store.undo() },
            redo: { store.redo() },
            copy: copySelection,
            paste: pasteFromClipboard,
            duplicate: {
                guard !selectedNodeIDs.isEmpty else { return }
                selectedNodeIDs = store.duplicateNodes(selectedNodeIDs)
            },
            delete: deleteSelection,
            selectAll: {
                selectedNodeIDs = Set(store.selectedDocument?.nodes.map(\.id) ?? [])
                selectedStrokeIDs = Set(store.selectedDocument?.strokes.map(\.id) ?? [])
            },
            group: { store.group(selectedNodeIDs) },
            ungroup: { store.ungroup(selectedNodeIDs) },
            interpretInk: interpretSelectedInk,
            chooseTool: { index in
                guard CanvasMode.allCases.indices.contains(index) else { return }
                mode = CanvasMode.allCases[index]
            },
            zoomIn: {
                scale = min(3, scale + 0.2)
                scaleStart = scale
            },
            zoomOut: {
                scale = max(0.3, scale - 0.2)
                scaleStart = scale
            },
            resetView: {
                scale = 1; scaleStart = 1; pan = .zero; panStart = .zero
            },
            nudge: { dx, dy in store.nudgeNodes(selectedNodeIDs, dx: dx, dy: dy) }
        )
    }

    private func copySelection() {
        guard !selectedNodeIDs.isEmpty else { return }
        do {
            let data = try store.clipboardData(for: selectedNodeIDs)
            let text = store.selectedDocument?.nodes
                .filter { selectedNodeIDs.contains($0.id) }
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            var item: [String: Any] = [Self.nodePasteboardType: data]
            if let text, !text.isEmpty {
                item[UTType.utf8PlainText.identifier] = text
            }
            UIPasteboard.general.setItems([item], options: [:])
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            store.saveError = error.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        do {
            if let data = UIPasteboard.general.data(forPasteboardType: Self.nodePasteboardType) {
                selectedNodeIDs = try store.pasteNodes(from: data)
            } else if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty {
                selectedNodeIDs = [store.addNote(
                    at: canvasPoint(CGPoint(x: 560, y: 380)),
                    text: text
                )]
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } catch {
            store.saveError = "无法粘贴：\(error.localizedDescription)"
        }
    }

    private func deleteSelection() {
        if let selectedConnectionID {
            store.deleteConnection(selectedConnectionID)
            self.selectedConnectionID = nil
            return
        }
        store.deleteNodes(selectedNodeIDs)
        store.removeStrokes(selectedStrokeIDs)
        editingNodeID = nil
        selectedNodeIDs.removeAll()
        selectedStrokeIDs.removeAll()
    }

    private func interpretSelectedInk() {
        guard (!selectedStrokeIDs.isEmpty || store.hasNativeInk), !isInterpretingInk else {
            if selectedStrokeIDs.isEmpty && !store.hasNativeInk {
                inkInterpretationError = "请用 Apple Pencil 画出内容，或切到“选择”后框选已有笔迹。"
            }
            return
        }
        let sourceIDs = selectedStrokeIDs
        isInterpretingInk = true
        inkInterpretation = nil
        inkInterpretationError = nil
        Task { @MainActor in
            defer { isInterpretingInk = false }
            do {
                let capture: CanvasInkCapture
                if sourceIDs.isEmpty {
                    capture = try store.nativeInkCapture()
                } else {
                    capture = try store.inkCapture(strokeIDs: sourceIDs)
                }
                let recognized = try? await Task.detached(priority: .userInitiated) {
                    try VisualTextRecognizer.recognize(
                        imageData: capture.imageData,
                        pixelWidth: capture.pixelWidth,
                        pixelHeight: capture.pixelHeight,
                        referencePrefix: "ink",
                        limit: 80
                    )
                }.value
                let ocrText = (recognized ?? []).map(\.text).joined(separator: "\n")
                let prompt = inkInterpretationPrompt(
                    preference: inkOutputPreference,
                    ocrText: ocrText,
                    pixelWidth: capture.pixelWidth,
                    pixelHeight: capture.pixelHeight
                )
                let result = await environment.conversationCenter.describeCanvasImageResult(
                    base64: capture.imageData.base64EncodedString(),
                    mimeType: "image/png",
                    prompt: prompt
                )
                var interpretation: CanvasInkInterpretation
                switch result {
                case .success(let response):
                    do {
                        interpretation = try Self.decodeInkInterpretation(response)
                        interpretation.routeDescription = environment.conversationCenter
                            .canvasVisionDestinationName() ?? "画面理解模型"
                    } catch {
                        guard !ocrText.isEmpty else { throw error }
                        interpretation = Self.ocrFallbackInterpretation(ocrText)
                    }
                case .failure(let failure):
                    guard !ocrText.isEmpty else {
                        throw FloeError.invalidConfiguration(failure.userMessage)
                    }
                    interpretation = Self.ocrFallbackInterpretation(ocrText)
                }
                interpretation.sourceBounds = capture.canvasBounds
                inkInterpretationSourceIDs = sourceIDs
                withAnimation(.snappy) { inkInterpretation = interpretation }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                inkInterpretationError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func applyInkInterpretation() {
        guard let inkInterpretation else { return }
        selectedNodeIDs = store.applyInkInterpretation(
            inkInterpretation,
            strokeIDs: inkInterpretationSourceIDs,
            preserveOriginal: preservesInkAfterConversion
        )
        if !preservesInkAfterConversion { selectedStrokeIDs.removeAll() }
        if !preservesInkAfterConversion && inkInterpretationSourceIDs.isEmpty {
            store.updatePencilDrawing(nil)
        }
        self.inkInterpretation = nil
        mode = .select
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func inkInterpretationPrompt(
        preference: CanvasInkOutputPreference,
        ocrText: String,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> String {
        """
        You are converting one Apple Pencil sketch into editable native canvas objects. Interpret the user's intent, not the drawing quality. Preserve the language and facts visible in the ink. Do not add unsupported content. \(preference.instruction)

        Image size: \(pixelWidth)x\(pixelHeight). On-device OCR evidence (may be incomplete or wrong):
        \(ocrText.isEmpty ? "none" : String(ocrText.prefix(4_000)))

        Return ONLY one JSON object with this exact shape:
        {"summary":"short explanation","layout":"text|cards|flowchart|mindmap|wireframe","confidence":0.0,"nodes":[{"id":"n1","kind":"text|stickyNote|shape","text":"visible label","x":0.5,"y":0.5,"width":0.3,"height":0.2,"shape":"rectangle|roundedRectangle|ellipse|diamond|triangle"}],"connections":[{"from":"n1","to":"n2","label":"optional"}]}

        Coordinates and sizes are normalized 0...1. Use 1-40 nodes. Keep text concise and editable. Use shape nodes for diagram or interface geometry, stickyNote for ideas, and text for headings or prose. Connections must reference existing node IDs. If the ink is ambiguous, make the smallest faithful interpretation and lower confidence. Never return Markdown or commentary outside JSON.
        """
    }

    private static func decodeInkInterpretation(_ response: String) throws -> CanvasInkInterpretation {
        guard let start = response.firstIndex(of: "{"),
              let end = response.lastIndex(of: "}"), start <= end else {
            throw FloeError.validationFailed("笔迹模型没有返回可用的结构。")
        }
        let data = Data(response[start...end].utf8)
        var value = try JSONDecoder().decode(CanvasInkInterpretation.self, from: data)
        value.confidence = min(1, max(0, value.confidence))
        value.nodes = Array(value.nodes.filter { node in
            !node.id.isEmpty && ["text", "stickyNote", "shape"].contains(node.kind)
                && node.x.isFinite && node.y.isFinite
                && node.width.isFinite && node.height.isFinite
        }.prefix(40))
        let ids = Set(value.nodes.map(\.id))
        value.connections = Array(value.connections.filter {
            ids.contains($0.from) && ids.contains($0.to) && $0.from != $0.to
        }.prefix(60))
        guard !value.nodes.isEmpty else {
            throw FloeError.validationFailed("笔迹模型没有生成可编辑节点。")
        }
        if value.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.summary = "已把所选笔迹整理成 \(value.nodes.count) 个可编辑节点。"
        }
        return value
    }

    private static func ocrFallbackInterpretation(_ text: String) -> CanvasInkInterpretation {
        CanvasInkInterpretation(
            summary: "辅助视觉不可用，已用本机文字识别整理可辨认内容。",
            layout: "text",
            confidence: 0.55,
            nodes: [CanvasInkPlanNode(
                id: "ocr-1",
                kind: "stickyNote",
                text: text,
                x: 0.5,
                y: 0.5,
                width: 0.82,
                height: 0.72
            )],
            connections: [],
            routeDescription: "Apple Vision 本机文字识别"
        )
    }

    private func screenPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * scale + pan.width, y: point.y * scale + pan.height)
    }

    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.width) / scale, y: (point.y - pan.height) / scale)
    }

    private func prepareExport(_ format: CanvasDocumentStore.ExportFormat) {
        do {
            let data = try store.exportData(format)
            let base = store.project.name.isEmpty ? "Floe 画布" : store.project.name
            switch format {
            case .package:
                exportContentType = .floeCanvasPackage
                exportFilename = base
            case .png:
                exportContentType = .png
                exportFilename = base
            case .pdf:
                exportContentType = .pdf
                exportFilename = base
            }
            exportDocument = CanvasBinaryDocument(data: data)
        } catch {
            store.saveError = error.localizedDescription
        }
    }

    @MainActor
    private func cancel(_ job: MediaGenerationJob) async -> String? {
        do {
            try await environment.mediaGenerationService.cancelVideo(jobID: job.id)
            canvasJobs = (try? await MediaGenerationJobStore(database: environment.database)
                .jobs(canvasID: job.canvasID)) ?? canvasJobs
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @MainActor
    private func retry(_ job: MediaGenerationJob) async -> String? {
        do {
            let replacement = try await environment.mediaGenerationService.retryVideo(jobID: job.id)
            store.setGenerationJob(replacement.id, for: job.resultNodeID)
            canvasJobs = (try? await MediaGenerationJobStore(database: environment.database)
                .jobs(canvasID: job.canvasID)) ?? canvasJobs
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct CanvasInkInterpretationPanel: View {
    let interpretation: CanvasInkInterpretation
    @Binding var preservesOriginal: Bool
    let onApply: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wand.and.rays")
                    .font(.title2)
                    .foregroundStyle(FloeTheme.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("笔迹整理预览").font(.headline)
                    Text("\(interpretation.layout) · 置信度 \(Int(interpretation.confidence * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("关闭笔迹整理预览")
            }

            Text(interpretation.summary)
                .font(.subheadline)
                .lineLimit(3)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(interpretation.nodes.prefix(5)) { node in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: node.kind == "shape" ? "square.on.circle" : "note.text")
                            .foregroundStyle(.secondary)
                        Text(node.text.isEmpty ? "未命名图形" : node.text)
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                if interpretation.nodes.count > 5 {
                    Text("另有 \(interpretation.nodes.count - 5) 个节点")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }

            Toggle("保留原始笔迹", isOn: $preservesOriginal)
                .font(.subheadline)
            Text(preservesOriginal
                 ? "格式化内容会放在原稿旁边，原笔迹保持可编辑。"
                 : "格式化内容会替换所选笔迹；应用后仍可撤销。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button("重新理解", action: onRetry)
                    .buttonStyle(.bordered)
                Spacer()
                Button("应用到画布", action: onApply)
                    .buttonStyle(.borderedProminent)
            }

            Label("识别路径：\(interpretation.routeDescription)", systemImage: "eye")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(.separator.opacity(0.45), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
    }
}

private enum CanvasPencilToolKind { case ink, eraser }

private struct CanvasPencilKitSurface: UIViewRepresentable {
    let drawingData: Data?
    let tool: CanvasPencilToolKind
    let width: Double
    let colorName: String
    let fingerDrawingEnabled: Bool
    let onDrawingChanged: @MainActor (Data?) -> Void
    let onClosedShape: @MainActor (CGRect) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged, onClosedShape: onClosedShape)
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView(frame: .zero)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = fingerDrawingEnabled ? .anyInput : .pencilOnly
        applyTool(to: canvas)
        if let drawingData, let drawing = try? PKDrawing(data: drawingData) {
            context.coordinator.isApplyingExternalDrawing = true
            canvas.drawing = drawing
            context.coordinator.isApplyingExternalDrawing = false
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.onDrawingChanged = onDrawingChanged
        context.coordinator.onClosedShape = onClosedShape
        canvas.drawingPolicy = fingerDrawingEnabled ? .anyInput : .pencilOnly
        applyTool(to: canvas)
        let current = canvas.drawing.dataRepresentation()
        let expected = drawingData ?? Data()
        guard current != expected else { return }
        context.coordinator.isApplyingExternalDrawing = true
        canvas.drawing = (try? PKDrawing(data: expected)) ?? PKDrawing()
        context.coordinator.isApplyingExternalDrawing = false
    }

    private func applyTool(to canvas: PKCanvasView) {
        switch tool {
        case .eraser:
            canvas.tool = PKEraserTool(.vector)
        case .ink:
            canvas.tool = PKInkingTool(
                .pen,
                color: uiColor,
                width: max(1, width)
            )
        }
    }

    private var uiColor: UIColor {
        switch colorName {
        case "blue": .systemBlue
        case "red": .systemRed
        case "green": .systemGreen
        case "black": .black
        default: .label
        }
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var onDrawingChanged: @MainActor (Data?) -> Void
        var onClosedShape: @MainActor (CGRect) -> Void
        var isApplyingExternalDrawing = false
        private var pendingSave: Task<Void, Never>?

        init(
            onDrawingChanged: @escaping @MainActor (Data?) -> Void,
            onClosedShape: @escaping @MainActor (CGRect) -> Void
        ) {
            self.onDrawingChanged = onDrawingChanged
            self.onClosedShape = onClosedShape
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing else { return }
            let data = canvasView.drawing.dataRepresentation()
            if let stroke = canvasView.drawing.strokes.last,
               stroke.path.count >= 6 {
                let first = stroke.path[0].location
                let last = stroke.path[stroke.path.count - 1].location
                let bounds = stroke.renderBounds
                if hypot(last.x - first.x, last.y - first.y) <= max(28, min(bounds.width, bounds.height) * 0.22),
                   bounds.width >= 70, bounds.height >= 48 {
                    onClosedShape(bounds)
                }
            }
            pendingSave?.cancel()
            pendingSave = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                onDrawingChanged(data.isEmpty ? nil : data)
            }
        }
    }
}

private struct CanvasPencilPalette: View {
    @Binding var width: Double
    @Binding var colorName: String
    @Binding var fingerDrawingEnabled: Bool
    let onCreateCard: () -> Void
    let onCreateText: () -> Void
    let onCreateShape: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("画笔").font(.headline)
            HStack(spacing: 14) {
                ForEach(["black", "blue", "red", "green"], id: \.self) { name in
                    Button { colorName = name } label: {
                        Circle()
                            .fill(color(for: name))
                            .frame(width: 30, height: 30)
                            .overlay {
                                if colorName == name {
                                    Circle().stroke(.primary, lineWidth: 3).padding(-4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(colorLabel(name))
                }
            }
            LabeledContent("粗细") {
                Slider(value: $width, in: 1...18, step: 0.5)
                    .frame(width: 190)
            }
            Toggle("允许手指绘画", isOn: $fingerDrawingEnabled)
            Divider()
            Text("快速创建").font(.subheadline.weight(.semibold))
            HStack {
                Button("卡片", systemImage: "note.text", action: onCreateCard)
                Button("文本", systemImage: "textformat", action: onCreateText)
                Button("形状", systemImage: "square.on.circle", action: onCreateShape)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .frame(width: 360)
    }

    private func color(for name: String) -> Color {
        switch name {
        case "blue": .blue
        case "red": .red
        case "green": .green
        default: .primary
        }
    }

    private func colorLabel(_ name: String) -> String {
        switch name {
        case "blue": "蓝色"
        case "red": "红色"
        case "green": "绿色"
        default: "黑色"
        }
    }
}

private struct CanvasPencilInteractionBridge: UIViewRepresentable {
    let onTap: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.addInteraction(UIPencilInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    @MainActor
    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var onTap: @MainActor () -> Void

        init(onTap: @escaping @MainActor () -> Void) {
            self.onTap = onTap
        }

        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveTap tap: UIPencilInteraction.Tap
        ) {
            onTap()
        }
    }
}

private struct CanvasMediaJobCenter: View {
    @Environment(\.dismiss) private var dismiss
    let jobs: [MediaGenerationJob]
    let onCancel: @MainActor (MediaGenerationJob) async -> String?
    let onRetry: @MainActor (MediaGenerationJob) async -> String?

    @State private var pendingCancellation: MediaGenerationJob?
    @State private var pendingRetry: MediaGenerationJob?
    @State private var workingJobID: UUID?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if jobs.isEmpty {
                    ContentUnavailableView("没有媒体任务", systemImage: "film.stack")
                } else {
                    ForEach(jobs) { job in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(job.mediaKind == .video ? "视频生成" : "媒体生成", systemImage: "film")
                                    .font(.headline)
                                Spacer()
                                Text(title(for: job.state))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: job.state))
                            }
                            Text(job.id.uuidString)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            if let estimate = job.estimatedCompletionAt, !job.state.isTerminal {
                                LabeledContent("预计完成", value: estimate.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                            }
                            if let expiry = job.resultURLExpiresAt ?? job.resultRetentionExpiresAt {
                                LabeledContent("结果保留至", value: expiry.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                            }
                            if let error = job.lastError, !error.isEmpty {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            if workingJobID == job.id {
                                ProgressView().controlSize(.small)
                            } else if !job.state.isTerminal {
                                Button("取消任务", role: .destructive) { pendingCancellation = job }
                            } else if [.failed, .expired, .cancelled].contains(job.state) {
                                Button("重新生成") { pendingRetry = job }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("媒体任务")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
        .confirmationDialog("取消这个供应商任务？", isPresented: Binding(
            get: { pendingCancellation != nil },
            set: { if !$0 { pendingCancellation = nil } }
        )) {
            Button("取消任务", role: .destructive) {
                guard let job = pendingCancellation else { return }
                pendingCancellation = nil
                run(job, action: onCancel)
            }
            Button("保留任务", role: .cancel) { pendingCancellation = nil }
        }
        .confirmationDialog("重新生成可能再次计费", isPresented: Binding(
            get: { pendingRetry != nil },
            set: { if !$0 { pendingRetry = nil } }
        )) {
            Button("确认重新生成") {
                guard let job = pendingRetry else { return }
                pendingRetry = nil
                run(job, action: onRetry)
            }
            Button("取消", role: .cancel) { pendingRetry = nil }
        } message: {
            Text("这会提交一个新的供应商任务。原任务记录和参数会保留用于审计。")
        }
        .alert("媒体任务无法更新", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "未知错误") }
    }

    private func run(
        _ job: MediaGenerationJob,
        action: @escaping @MainActor (MediaGenerationJob) async -> String?
    ) {
        workingJobID = job.id
        Task { @MainActor in
            errorMessage = await action(job)
            workingJobID = nil
        }
    }

    private func title(for state: MediaGenerationJobState) -> String {
        switch state {
        case .preparing: "准备中"
        case .submitted: "等待开始"
        case .running: "生成中"
        case .completed: "准备下载"
        case .downloading: "下载中"
        case .ready: "已保存"
        case .failed: "失败"
        case .cancelled: "已取消"
        case .expired: "可能已过期"
        }
    }

    private func color(for state: MediaGenerationJobState) -> Color {
        switch state {
        case .ready: .green
        case .failed, .expired: .red
        case .cancelled: .secondary
        default: FloeTheme.primary
        }
    }
}

private struct CanvasNodeInspector: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CanvasDocumentStore
    let node: FloeCanvasNode
    let selectedIDs: Set<UUID>

    @State private var width: Double
    @State private var height: Double
    @State private var rotation: Double

    init(store: CanvasDocumentStore, node: FloeCanvasNode, selectedIDs: Set<UUID>) {
        self.store = store
        self.node = node
        self.selectedIDs = selectedIDs
        _width = State(initialValue: node.width)
        _height = State(initialValue: node.height)
        _rotation = State(initialValue: node.rotation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("尺寸") {
                    LabeledContent("宽度") {
                        TextField("宽度", value: $width, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("高度") {
                        TextField("高度", value: $height, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("应用尺寸") {
                        store.resizeNode(node.id, width: width, height: height)
                    }
                    .disabled(node.isLocked)
                }

                Section("旋转") {
                    Slider(value: $rotation, in: -180...180, step: 1)
                    LabeledContent("角度", value: "\(Int(rotation))°")
                    Button(selectedIDs.count > 1 ? "应用到所选节点" : "应用旋转") {
                        store.rotateNodes(selectedIDs.isEmpty ? [node.id] : selectedIDs, degrees: rotation)
                    }
                }

                Section("排列") {
                    Toggle("锁定", isOn: Binding(
                        get: { node.isLocked },
                        set: { store.setLocked(selectedIDs.isEmpty ? [node.id] : selectedIDs, locked: $0) }
                    ))
                    Button("移到最前") {
                        store.changeLayer(selectedIDs.isEmpty ? [node.id] : selectedIDs, bringToFront: true)
                    }
                    Button("移到最后") {
                        store.changeLayer(selectedIDs.isEmpty ? [node.id] : selectedIDs, bringToFront: false)
                    }
                }
            }
            .navigationTitle("节点属性")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct CanvasNodeCard: View {
    let node: FloeCanvasNode
    @Binding var text: String
    let isSelected: Bool
    let isEditing: Bool
    let sourceURLs: [String]
    let licenseStatus: String?
    let onOpen3D: (() -> Void)?
    let onBeginEditing: () -> Void
    let onDuplicate: () -> Void
    let onConnect: () -> Void
    let onToggleLock: () -> Void
    let onBringToFront: () -> Void
    let onSendToBack: () -> Void
    let onGroup: () -> Void
    let onUngroup: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            nodeContent
            if !sourceURLs.isEmpty || licenseStatus != nil {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text("来源 \(sourceURLs.count)")
                    if let licenseStatus {
                        Text("· \(licenseStatus)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
        }
        .background(nodeBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? FloeTheme.primary : .secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .contextMenu {
            Button("编辑", systemImage: "pencil", action: onBeginEditing)
            Button("复制", systemImage: "plus.square.on.square", action: onDuplicate)
            Button("连接", systemImage: "point.topleft.down.to.point.bottomright.curvepath", action: onConnect)
            if let onOpen3D {
                Button("打开 3D 导演台", systemImage: "cube.transparent", action: onOpen3D)
            }
            Divider()
            Button(node.isLocked ? "解锁" : "锁定", systemImage: node.isLocked ? "lock.open" : "lock", action: onToggleLock)
            Button("移到最前", systemImage: "arrow.up.to.line", action: onBringToFront)
            Button("移到最后", systemImage: "arrow.down.to.line", action: onSendToBack)
            if node.groupID == nil {
                Button("分组", systemImage: "square.3.layers.3d", action: onGroup)
            } else {
                Button("解除分组", systemImage: "square.2.layers.3d", action: onUngroup)
            }
            Divider()
            Button("删除节点", role: .destructive, action: onDelete)
        }
        .accessibilityIdentifier("canvas.node.\(node.id.uuidString)")
    }

    private var nodeBackground: Color {
        node.kind == .stickyNote
            ? Color(uiColor: .systemYellow).opacity(0.24)
            : Color(uiColor: .secondarySystemBackground)
    }

    @ViewBuilder
    private var nodeContent: some View {
        switch node.kind {
        case .text, .stickyNote:
            if isEditing {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
            } else {
                Text(text.isEmpty ? (node.kind == .stickyNote ? "便签" : "文本") : text)
                    .font(.body)
                    .foregroundStyle(text.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(14)
                    .contentShape(Rectangle())
            }
        case .shape:
            ZStack {
                CanvasNodeShapeView(shape: node.shape ?? .roundedRectangle)
                if isEditing {
                    TextField("形状文字", text: $text, axis: .vertical)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    Text(text)
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
        case .image:
            CanvasAssetNodeContent(node: node, fallbackIcon: "photo", title: text.isEmpty ? "图片" : text)
        case .video:
            CanvasAssetNodeContent(node: node, fallbackIcon: "play.rectangle.fill", title: text.isEmpty ? "视频" : text)
        case .audio:
            CanvasAssetNodeContent(node: node, fallbackIcon: "waveform", title: text.isEmpty ? "音频" : text)
        case .file:
            CanvasAssetNodeContent(node: node, fallbackIcon: "doc", title: text.isEmpty ? "文件" : text)
        case .group:
            assetPlaceholder(icon: "square.3.layers.3d", title: text.isEmpty ? "分组" : text)
        case .generationTask:
            VStack(spacing: 10) {
                if node.generationJobID == nil {
                    Image(systemName: "wand.and.stars")
                        .font(.largeTitle)
                        .foregroundStyle(FloeTheme.primary)
                    Text(text.isEmpty ? "生成配置" : text).font(.headline)
                    Text("选中后点“生成”配置图片或视频任务")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                    Text(text.isEmpty ? "生成任务" : text).font(.headline)
                    Text("任务状态会在重新打开 App 后继续恢复")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .scene3D:
            ZStack(alignment: .bottomLeading) {
                Canvas3DScenePreview(scene: node.scene3D ?? .starter())
                VStack(alignment: .leading, spacing: 3) {
                    Label(text.isEmpty ? "3D 场景" : text, systemImage: "cube.transparent")
                        .font(.headline)
                    if let onOpen3D {
                        Button("打开导演台", systemImage: "arrow.up.left.and.arrow.down.right") {
                            onOpen3D()
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(10)
            }
        }
    }

    private func assetPlaceholder(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(FloeTheme.primary)
            Text(title).lineLimit(2)
            if let mimeType = node.asset?.mimeType {
                Text(mimeType).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct CanvasAssetNodeContent: View {
    let node: FloeCanvasNode
    let fallbackIcon: String
    let title: String

    private var fileURL: URL? {
        guard let relativePath = node.asset?.localRelativePath,
              !relativePath.contains(".."),
              let support = try? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
              ) else { return nil }
        return support.appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativePath)
    }

    var body: some View {
        Group {
            switch node.kind {
            case .image:
                if let fileURL, let image = UIImage(contentsOfFile: fileURL.path) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    placeholder
                }
            case .video:
                if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                    CanvasVideoNode(url: fileURL)
                } else {
                    placeholder
                }
            default:
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: fallbackIcon)
                .font(.largeTitle)
                .foregroundStyle(FloeTheme.primary)
            Text(title).lineLimit(2)
            if let mimeType = node.asset?.mimeType {
                Text(mimeType).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct CanvasVideoNode: View {
    @State private var player: AVPlayer

    init(url: URL) {
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        VideoPlayer(player: player)
            .onDisappear { player.pause() }
    }
}

private struct CanvasAgentRequest: Identifiable, Equatable {
    let id = UUID()
    let nodeID: UUID
    let prompt: String
}

private struct CanvasConnectionPortsOverlay: View {
    let activePort: CanvasConnectionPort?
    let onTap: (CanvasConnectionPort) -> Void

    var body: some View {
        ZStack {
            ForEach(CanvasConnectionPort.allCases, id: \.self) { port in
                Button {
                    onTap(port)
                } label: {
                    Image(systemName: activePort == port ? "circle.inset.filled" : "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(activePort == port ? .white : FloeTheme.primary)
                        .frame(width: 20, height: 20)
                        .background(activePort == port ? FloeTheme.primary : Color(uiColor: .systemBackground), in: Circle())
                        .overlay { Circle().stroke(FloeTheme.primary, lineWidth: 1.5) }
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: port.alignment)
                .offset(port.outwardOffset)
                .accessibilityLabel("从节点\(port.accessibilityName)连接")
                .accessibilityIdentifier("canvas.connection.port.\(port.rawValue)")
            }
        }
    }
}

private extension CanvasConnectionPort {
    var alignment: Alignment {
        switch self {
        case .top: .top
        case .trailing: .trailing
        case .bottom: .bottom
        case .leading: .leading
        }
    }

    var outwardOffset: CGSize {
        switch self {
        case .top: CGSize(width: 0, height: -12)
        case .trailing: CGSize(width: 12, height: 0)
        case .bottom: CGSize(width: 0, height: 12)
        case .leading: CGSize(width: -12, height: 0)
        }
    }

    var accessibilityName: String {
        switch self {
        case .top: "上方"
        case .trailing: "右侧"
        case .bottom: "下方"
        case .leading: "左侧"
        }
    }
}

private struct CanvasNodeInlineAIComposer: View {
    let nodeTitle: String
    let onSubmit: (String) -> Void
    @State private var prompt = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(FloeTheme.primary)
            TextField(
                nodeTitle.isEmpty ? "让 AI 处理这个节点" : "让 AI 处理“\(nodeTitle.prefix(18))”",
                text: $prompt
            )
            .textFieldStyle(.plain)
            .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 10)
        .frame(width: 260, height: 38)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(.separator.opacity(0.5), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityIdentifier("canvas.node.inlineAI")
    }

    private func submit() {
        let request = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { return }
        prompt = ""
        onSubmit(request)
    }
}

private struct CanvasNodeSelectionChrome: View {
    let node: FloeCanvasNode
    let onBegin: () -> Void
    let onGeometryChanged: (_ width: Double?, _ height: Double?, _ rotation: Double?) -> Void
    let onEnd: () -> Void

    @State private var resizeOrigin: CGSize?
    @State private var rotationOrigin: Double?

    private enum Handle: CaseIterable, Hashable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var alignment: Alignment {
            switch self {
            case .topLeading: .topLeading
            case .topTrailing: .topTrailing
            case .bottomLeading: .bottomLeading
            case .bottomTrailing: .bottomTrailing
            }
        }

        var horizontal: Double {
            switch self {
            case .topLeading, .bottomLeading: -1
            case .topTrailing, .bottomTrailing: 1
            }
        }

        var vertical: Double {
            switch self {
            case .topLeading, .topTrailing: -1
            case .bottomLeading, .bottomTrailing: 1
            }
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .stroke(FloeTheme.primary, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .allowsHitTesting(false)
            ForEach(Handle.allCases, id: \.self) { handle in
                Circle()
                    .fill(.background)
                    .overlay { Circle().stroke(FloeTheme.primary, lineWidth: 2) }
                    .frame(width: 13, height: 13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: handle.alignment)
                    .contentShape(Rectangle().inset(by: -10))
                    .gesture(resizeGesture(handle))
            }
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FloeTheme.primary)
                .padding(7)
                .background(.background, in: Circle())
                .overlay { Circle().stroke(FloeTheme.primary, lineWidth: 1.5) }
                .offset(y: -node.height / 2 - 30)
                .gesture(rotationGesture)
                .accessibilityLabel("旋转节点")
        }
    }

    private func resizeGesture(_ handle: Handle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if resizeOrigin == nil {
                    resizeOrigin = CGSize(width: node.width, height: node.height)
                    onBegin()
                }
                guard let origin = resizeOrigin else { return }
                let width = handle.horizontal == 0
                    ? nil
                    : origin.width + value.translation.width * handle.horizontal
                let height = handle.vertical == 0
                    ? nil
                    : origin.height + value.translation.height * handle.vertical
                onGeometryChanged(width, height, nil)
            }
            .onEnded { _ in
                resizeOrigin = nil
                onEnd()
            }
    }

    private var rotationGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if rotationOrigin == nil {
                    rotationOrigin = node.rotation
                    onBegin()
                }
                guard let origin = rotationOrigin else { return }
                onGeometryChanged(nil, nil, origin + value.translation.width * 0.6)
            }
            .onEnded { _ in
                rotationOrigin = nil
                onEnd()
            }
    }
}

private struct CanvasNodeShapeView: View {
    let shape: CanvasShapeKind

    @ViewBuilder
    var body: some View {
        switch shape {
        case .rectangle:
            Rectangle()
                .fill(FloeTheme.primary.opacity(0.14))
                .overlay { Rectangle().stroke(FloeTheme.primary.opacity(0.45), lineWidth: 1.5) }
        case .roundedRectangle:
            RoundedRectangle(cornerRadius: 18)
                .fill(FloeTheme.primary.opacity(0.14))
                .overlay { RoundedRectangle(cornerRadius: 18).stroke(FloeTheme.primary.opacity(0.45), lineWidth: 1.5) }
        case .ellipse:
            Ellipse()
                .fill(FloeTheme.primary.opacity(0.14))
                .overlay { Ellipse().stroke(FloeTheme.primary.opacity(0.45), lineWidth: 1.5) }
        case .diamond:
            CanvasDiamondShape()
                .fill(FloeTheme.primary.opacity(0.14))
                .overlay { CanvasDiamondShape().stroke(FloeTheme.primary.opacity(0.45), lineWidth: 1.5) }
        case .triangle:
            CanvasTriangleShape()
                .fill(FloeTheme.primary.opacity(0.14))
                .overlay { CanvasTriangleShape().stroke(FloeTheme.primary.opacity(0.45), lineWidth: 1.5) }
        }
    }
}

private struct CanvasDiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private struct CanvasTriangleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A focused creative assistant embedded in the native canvas. It receives
/// search, web reading, materials and media generation, without full browser
/// control or unrelated system administration tools.
private struct CanvasAgentFloatingPanel: View {
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: CanvasDocumentStore

    let workspace: WorkspaceRecord?
    let contextSnapshot: String
    @Binding var pendingRequest: CanvasAgentRequest?
    let availableSize: CGSize
    @Binding var offset: CGSize
    @Binding var isCollapsed: Bool
    let onClose: () -> Void

    @State private var prompt = ""
    @State private var selectedModelID: UUID?
    @State private var messages: [PersistedMessage] = []
    @State private var isRunning = false
    @State private var statusText: String?
    @State private var errorText: String?
    @State private var resultText: String?
    @State private var resultRunID: UUID?
    @State private var insertedRunIDs: Set<UUID> = []
    @State private var dragOrigin = CGSize.zero
    @State private var isDragging = false

    private var center: ConversationCenter { environment.conversationCenter }
    private var mcpCenter: MCPSettingsCenter { environment.mcpSettingsCenter }
    private var toolCapableModels: [ModelProfile] {
        center.canvasAssistantModels.filter {
            $0.remoteModelID != AppleFoundationModelIdentity.remoteModelID
        }
    }
    private var allowedToolNames: Set<String> { mcpCenter.canvasAllowedToolNames() }
    private var allowedMCPCount: Int {
        allowedToolNames.subtracting(CanvasAgentToolPolicy.nativeToolNames).count
    }

    var body: some View {
        VStack(spacing: 0) {
            floatingHeader
            if !isCollapsed {
                capabilityBanner
                Divider()
                transcript
                Divider()
                composer
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .padding(12)
        .task {
            await prepare()
            await consumePendingRequest()
        }
        .onChange(of: pendingRequest?.id) { _, _ in
            Task { await consumePendingRequest() }
        }
    }

    private var floatingHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(FloeTheme.primary)
            Text("画布助手")
                .font(.headline)
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
            Button {
                withAnimation(.snappy) { isCollapsed.toggle() }
            } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCollapsed ? "展开画布助手" : "收起画布助手")
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭画布助手")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    if !isDragging {
                        dragOrigin = offset
                        isDragging = true
                    }
                    offset = clampedOffset(CGSize(
                        width: dragOrigin.width + value.translation.width,
                        height: dragOrigin.height + value.translation.height
                    ))
                }
                .onEnded { _ in
                    offset = clampedOffset(offset)
                    isDragging = false
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.snappy) { offset = .zero }
        }
    }

    private func clampedOffset(_ proposed: CGSize) -> CGSize {
        let panelWidth = min(420, max(280, availableSize.width - 24))
        let panelHeight = isCollapsed ? 52 : min(680, max(300, availableSize.height - 96))
        let horizontalLimit = max(0, (availableSize.width - panelWidth) / 2)
        let verticalLimit = max(0, (availableSize.height - panelHeight) / 2)
        return CGSize(
            width: min(horizontalLimit, max(-horizontalLimit, proposed.width)),
            height: min(verticalLimit, max(-verticalLimit, proposed.height))
        )
    }

    private var capabilityBanner: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("查找资料与生成素材", systemImage: "sparkles")
                .font(.headline)
            Text("可搜索网页、读取链接，并使用素材库和已配置的图片或视频模型。结果会保留来源，确认后加入当前画布。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label("web.search", systemImage: "magnifyingglass")
                Label("web.fetch", systemImage: "doc.text.magnifyingglass")
                Label("素材与媒体", systemImage: "photo.stack")
            }
            .font(.caption2.monospaced())
            .foregroundStyle(FloeTheme.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial)
    }

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if messages.isEmpty, !isRunning {
                    ContentUnavailableView(
                        "开始创作",
                        systemImage: "sparkles",
                        description: Text("搜索资料、读取网址、整理画面，或生成可加入当前画布的素材。")
                    )
                }
                ForEach(messages.suffix(12)) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role == "user" ? "你" : "画布助手")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(displayContent(message))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        message.role == "user"
                            ? FloeTheme.primary.opacity(0.10)
                            : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                }
                if isRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(statusText ?? "正在处理…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding()
        }
    }

    private var composer: some View {
        VStack(spacing: 10) {
            if toolCapableModels.count > 1 {
                Picker("画布助手模型", selection: $selectedModelID) {
                    ForEach(toolCapableModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField("告诉画布助手要查找、整理或生成什么", text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            HStack {
                if let resultRunID, let resultText,
                   !insertedRunIDs.contains(resultRunID) {
                    Button {
                        insertResult(resultText, runID: resultRunID)
                    } label: {
                        Label("加入画布", systemImage: "rectangle.stack.badge.plus")
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button {
                    Task { await runResearch() }
                } label: {
                    Label("发送", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || selectedModelID == nil)
            }
        }
        .padding()
        .background(.regularMaterial)
    }

    @MainActor
    private func prepare() async {
        mcpCenter.activate()
        await center.reload()
        if selectedModelID == nil {
            let preferred = center.modelPreferences.canvasAgentModelID
                ?? center.modelPreferences.defaultAgentModelID
            selectedModelID = toolCapableModels.first(where: { $0.id == preferred })?.id
                ?? toolCapableModels.first?.id
        }
        if toolCapableModels.isEmpty {
            errorText = "请先启用一个支持工具调用的模型。"
        }
        await reloadMessages()
    }

    @MainActor
    private func runResearch() async {
        let userPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userPrompt.isEmpty,
              let pair = center.providerAndModel(modelID: selectedModelID),
              pair.1.capabilities.contains(.tools) else {
            errorText = "所选模型不支持工具调用。"
            return
        }
        isRunning = true
        statusText = "正在准备画布任务…"
        errorText = nil
        resultText = nil
        resultRunID = nil
        defer { isRunning = false }

        do {
            let conversationID = try await ensureConversationAndPolicy()
            statusText = "正在处理并核对结果…"
            let started = try await center.startRun(
                goal: researchGoal(userPrompt),
                in: conversationID,
                provider: pair.0,
                model: pair.1,
                workspaceID: workspace?.id,
                executionMode: .agent,
                runSurface: .canvas
            )
            switch await started.result.value {
            case .failure(let error):
                throw error
            case .success:
                break
            }
            await reloadMessages()
            guard let answer = messages.last(where: {
                $0.role == "assistant" && $0.runID == started.runID
            })?.content.trimmingCharacters(in: .whitespacesAndNewlines),
                  !answer.isEmpty else {
                throw FloeError.internalError("画布助手没有返回可用结果")
            }
            resultText = answer
            resultRunID = started.runID
            prompt = ""
            statusText = "已完成"
        } catch {
            errorText = error.localizedDescription
            statusText = nil
            await reloadMessages()
        }
    }

    @MainActor
    private func consumePendingRequest() async {
        guard !isRunning, let request = pendingRequest else { return }
        prompt = request.prompt
        pendingRequest = nil
        await runResearch()
    }

    @MainActor
    private func ensureConversationAndPolicy() async throws -> UUID {
        let workspaceStore = SQLiteWorkspaceStore(database: environment.database)
        let conversationID: UUID
        if let existing = store.project.agentConversationID,
           try await environment.conversationStore.conversation(id: existing) != nil {
            conversationID = existing
        } else {
            let id = UUID()
            let now = Date()
            do {
                try await environment.conversationStore.saveConversation(ConversationRecord(
                    id: id,
                    title: CanvasAgentIdentity.conversationTitlePrefix + store.project.name,
                    createdAt: now,
                    updatedAt: now,
                    titleOrigin: .manual
                ))
                try await environment.conversationStore.setArchived(id: id, archived: true)
                if let workspace {
                    try await workspaceStore.linkConversation(
                        workspaceID: workspace.id,
                        conversationID: id
                    )
                }
                store.setAgentConversationID(id)
                conversationID = id
            } catch {
                try? await environment.conversationStore.deleteConversation(id: id)
                throw error
            }
        }

        let names = mcpCenter.canvasAllowedToolNames()
        let hasMCP = !names.subtracting(CanvasAgentToolPolicy.nativeToolNames).isEmpty
        try await workspaceStore.saveTaskPolicy(TaskPolicy(
            conversationID: conversationID,
            approvalMode: TaskApprovalMode.automatic.rawValue,
            allowedToolNames: names,
            filePaths: [],
            networkAllowed: true,
            browserControlAllowed: false,
            uploadAllowed: false,
            credentialsAllowed: false,
            remoteExecutionAllowed: hasMCP,
            recoveryPolicy: .safePoint,
            notificationPolicy: .stages
        ))
        center.taskPolicyDidChange(conversationID: conversationID)
        return conversationID
    }

    @MainActor
    private func reloadMessages() async {
        guard let conversationID = store.project.agentConversationID else { return }
        messages = (try? await environment.conversationStore.messages(
            conversationID: conversationID
        ))?.filter { $0.role == "user" || $0.role == "assistant" } ?? []
    }

    private func researchGoal(_ request: String) -> String {
        """
        你是 Floe 原生画布里的创作助手。理解当前选中的节点、相邻关系和用户目标；需要资料时可以搜索网页或读取公开链接，需要素材时可以使用已提供的素材与媒体生成工具。只使用本次实际提供的工具，不要假装执行未提供的能力。保留来源节点，建议生成的结果应作为旁边的新节点，并清楚说明与原节点的关系。

        当前画布上下文：
        \(contextSnapshot)

        用户要求：
        \(request)
        """
    }

    private func displayContent(_ message: PersistedMessage) -> String {
        guard message.role == "user",
              let range = message.content.range(of: "User request:\n") else {
            return message.content
        }
        return String(message.content[range.upperBound...])
    }

    @MainActor
    private func insertResult(_ text: String, runID: UUID) {
        store.addResearchNote(
            text: text,
            sourceURLs: Self.extractURLs(from: text),
            runID: runID
        )
        insertedRunIDs.insert(runID)
    }

    private static func extractURLs(from text: String) -> [String] {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return detector.matches(in: text, options: [], range: range).compactMap { match in
            guard let value = match.url?.absoluteString,
                  let scheme = match.url?.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  seen.insert(value).inserted else { return nil }
            return value
        }
    }
}

private struct CanvasMediaGenerationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @ObservedObject var store: CanvasDocumentStore
    let sourceNodeIDs: Set<UUID>

    @State private var kind: MediaKind = .image
    @State private var prompt = ""
    @State private var selectedVideoModelID: UUID?
    @State private var aspectRatio = "1:1"
    @State private var duration = 5
    @State private var quality = ""
    @State private var isSubmitting = false
    @State private var error: String?

    private var videoModels: [ModelProfile] { environment.conversationCenter.videoModels }
    private var selectedVideoModel: ModelProfile? {
        videoModels.first(where: { $0.id == selectedVideoModelID })
    }
    private var descriptor: MediaModelDescriptor? {
        guard let selectedVideoModel else { return nil }
        return OfficialMediaModelCatalog.models.first { $0.remoteModelID == selectedVideoModel.remoteModelID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $kind) {
                    Text("图片").tag(MediaKind.image)
                    Text("视频").tag(MediaKind.video)
                }
                .pickerStyle(.segmented)

                Section("创作内容") {
                    TextField("描述希望生成的内容", text: $prompt, axis: .vertical)
                        .lineLimit(4...10)
                    Picker("画面比例", selection: $aspectRatio) {
                        ForEach(availableRatios, id: \.self) { Text($0).tag($0) }
                    }
                    if kind == .video {
                        Picker("视频模型", selection: $selectedVideoModelID) {
                            Text("请选择").tag(Optional<UUID>.none)
                            ForEach(videoModels) { model in
                                Text(model.displayName).tag(Optional(model.id))
                            }
                        }
                        if !availableDurations.isEmpty {
                            Picker("时长", selection: $duration) {
                                ForEach(availableDurations, id: \.self) { Text("\($0) 秒").tag($0) }
                            }
                        }
                        if !availableQualities.isEmpty {
                            Picker("质量", selection: $quality) {
                                ForEach(availableQualities, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting { ProgressView().frame(maxWidth: .infinity) }
                        else { Text(kind == .image ? "生成图片" : "开始生成视频").frame(maxWidth: .infinity) }
                    }
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting || (kind == .video && selectedVideoModelID == nil))
                } footer: {
                    Text(kind == .video
                         ? "视频任务会先保存供应商任务编号，再在后台尽力查询和取回；系统不保证准时唤醒。"
                         : "生成结果会保存到素材库，并在源提示旁创建新节点。")
                }
            }
            .navigationTitle("生成素材")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .task {
                let preferences = environment.conversationCenter.modelPreferences
                selectedVideoModelID = preferences.defaultVideoModelID ?? videoModels.first?.id
                normalizeOptions()
            }
            .onChange(of: selectedVideoModelID) { _, _ in normalizeOptions() }
            .onChange(of: kind) { _, _ in normalizeOptions() }
            .alert("无法生成", isPresented: Binding(
                get: { error != nil }, set: { if !$0 { error = nil } }
            )) { Button("完成", role: .cancel) {} } message: { Text(error ?? "") }
        }
    }

    private var availableRatios: [String] {
        if kind == .video, let values = descriptor?.supportedAspectRatios, !values.isEmpty { return values }
        return ["1:1", "4:3", "3:4", "16:9", "9:16"]
    }
    private var availableDurations: [Int] { descriptor?.supportedDurations ?? [5] }
    private var availableQualities: [String] { descriptor?.supportedQualities ?? [] }

    private func normalizeOptions() {
        if !availableRatios.contains(aspectRatio) { aspectRatio = availableRatios.first ?? "1:1" }
        if !availableDurations.isEmpty, !availableDurations.contains(duration) { duration = availableDurations[0] }
        if !availableQualities.isEmpty, !availableQualities.contains(quality) { quality = availableQualities[0] }
    }

    @MainActor
    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let sourcePoint = CGPoint(x: 360, y: 300)
            let resultPoint = CGPoint(x: 760, y: 300)
            let promptNodeID = store.addNote(at: sourcePoint, text: prompt)
            if kind == .image {
                let asset = try await environment.mediaGenerationService.generateImage(
                    prompt: prompt,
                    options: ImageGenerationOptions(aspectRatio: aspectRatio)
                )
                let resultID = store.addAsset(asset, kind: .image, at: resultPoint)
                store.connect(promptNodeID, to: resultID, kind: .generatedFrom)
            } else {
                let canvasID = store.project.id
                guard let documentID = store.selectedDocument?.id,
                      let model = selectedVideoModel else {
                    throw FloeError.invalidConfiguration("请选择视频模型。")
                }
                let resultNodeID = store.addGenerationTask(
                    kind: .video, prompt: "正在准备生成任务", at: resultPoint
                )
                store.connect(promptNodeID, to: resultNodeID, kind: .generatedFrom)
                let job = try await environment.mediaGenerationService.submitVideo(
                    modelID: model.id, canvasID: canvasID, documentID: documentID,
                    sourceNodeIDs: Array(sourceNodeIDs) + [promptNodeID],
                    resultNodeID: resultNodeID,
                    request: RemoteVideoRequest(
                        prompt: prompt, modelRemoteID: model.remoteModelID,
                        options: VideoGenerationOptions(
                            aspectRatio: aspectRatio,
                            resolution: quality.isEmpty ? nil : quality,
                            durationSeconds: duration
                        )
                    )
                )
                store.setGenerationJob(job.id, for: resultNodeID)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private final class CanvasMaterialLibraryStore: ObservableObject {
    struct Item: Identifiable, Hashable {
        let id: UUID
        let url: URL
        let name: String
        let kind: CanvasNodeKind
        let byteCount: Int64
        let updatedAt: Date
        let contentHash: String?
        let cloudRecordName: String?
        let referenceCount: Int
        let tags: [String]
        let sourceURL: URL?
        let license: String?

        var reference: CanvasAssetReference {
            CanvasAssetReference(
                id: id,
                contentHash: contentHash,
                localRelativePath: "Materials/\(url.lastPathComponent)",
                mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
                byteCount: byteCount, sourceURL: sourceURL, license: license
            )
        }
    }

    @Published private(set) var items: [Item] = []
    @Published var error: String?
    private var assetStore: CreativeAssetStore?

    func configure(assetStore: CreativeAssetStore) {
        self.assetStore = assetStore
    }

    private var directory: URL {
        get throws {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            let value = support.appendingPathComponent("FloeAgent/Materials", isDirectory: true)
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
    }

    func reload() async {
        do {
            let records = try await assetStore?.allAssets() ?? []
            let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            let urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            items = urls.compactMap { url in
                guard let kind = Self.kind(for: url) else { return nil }
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let stable = UUID(uuidString: String(url.lastPathComponent.prefix(36))) ?? UUID()
                let record = recordsByID[stable]
                return Item(
                    id: stable, url: url,
                    name: record?.displayName ?? url.deletingPathExtension().lastPathComponent,
                    kind: kind, byteCount: Int64(values?.fileSize ?? 0),
                    updatedAt: record?.updatedAt ?? values?.contentModificationDate ?? .distantPast,
                    contentHash: record?.contentHash,
                    cloudRecordName: record?.cloudRecordName,
                    referenceCount: record?.referenceCount ?? 0,
                    tags: record?.tags ?? [], sourceURL: record?.sourceURL,
                    license: record?.license
                )
            }.sorted { $0.updatedAt > $1.updatedAt }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func importFiles(_ urls: [URL]) async {
        do {
            let destination = try directory
            for source in urls {
                let accessed = source.startAccessingSecurityScopedResource()
                let id = UUID()
                let target = destination.appendingPathComponent("\(id.uuidString)-\(source.lastPathComponent)")
                try FileManager.default.copyItem(at: source, to: target)
                if accessed { source.stopAccessingSecurityScopedResource() }
                let data = try Data(contentsOf: target, options: .mappedIfSafe)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if let existing = try await assetStore?.asset(contentHash: hash),
                   existing.localRelativePath != nil {
                    try FileManager.default.removeItem(at: target)
                    continue
                }
                let mediaKind: MediaKind
                switch Self.kind(for: target) {
                case .video: mediaKind = .video
                case .audio: mediaKind = .audio
                case .file: mediaKind = .document
                default: mediaKind = .image
                }
                try await assetStore?.save(CreativeAssetRecord(
                    id: id, contentHash: hash, kind: mediaKind,
                    displayName: source.deletingPathExtension().lastPathComponent,
                    mimeType: UTType(filenameExtension: source.pathExtension)?.preferredMIMEType,
                    localRelativePath: "Materials/\(target.lastPathComponent)",
                    byteCount: Int64(data.count), tags: ["导入"], referenceCount: 0
                ))
            }
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ ids: Set<UUID>) async {
        do {
            guard let assetStore else {
                throw FloeError.invalidConfiguration("素材数据库尚未就绪。")
            }
            for item in items where ids.contains(item.id) {
                let path = try await assetStore.requestPermanentDeletion(assetID: item.id)
                if path != nil, FileManager.default.fileExists(atPath: item.url.path) {
                    try FileManager.default.removeItem(at: item.url)
                }
            }
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func update(_ item: Item, name: String, tags: [String], sourceURL: URL?, license: String?) async {
        do {
            try await assetStore?.updateMetadata(
                assetID: item.id, displayName: name, tags: tags,
                sourceURL: sourceURL, license: license
            )
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func deleteCloudCopy(_ item: Item) async {
        do {
            try await assetStore?.requestCloudCopyDeletion(assetID: item.id)
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    private static func kind(for url: URL) -> CanvasNodeKind? {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .data) || type.conforms(to: .content) { return .file }
        return nil
    }
}

private struct CanvasMaterialLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var store = CanvasMaterialLibraryStore()
    @State private var search = ""
    @State private var selection = Set<UUID>()
    @State private var importsFiles = false
    @State private var editingItem: CanvasMaterialLibraryStore.Item?

    var onChoose: ((CanvasAssetReference, CanvasNodeKind) -> Void)?
    let allowedKinds: Set<CanvasNodeKind>?

    init(
        allowedKinds: Set<CanvasNodeKind>? = nil,
        onChoose: ((CanvasAssetReference, CanvasNodeKind) -> Void)? = nil
    ) {
        self.allowedKinds = allowedKinds
        self.onChoose = onChoose
    }

    private var filtered: [CanvasMaterialLibraryStore.Item] {
        let byKind = allowedKinds.map { kinds in store.items.filter { kinds.contains($0.kind) } }
            ?? store.items
        return search.isEmpty ? byKind : byKind.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) })
                || ($0.sourceURL?.absoluteString.localizedCaseInsensitiveContains(search) ?? false)
                || ($0.license?.localizedCaseInsensitiveContains(search) ?? false)
        }
    }

    private var allowedContentTypes: [UTType] {
        guard let allowedKinds else { return [.image, .movie, .audio, .pdf, .data] }
        var types: [UTType] = []
        if allowedKinds.contains(.image) { types.append(.image) }
        if allowedKinds.contains(.video) { types.append(.movie) }
        if allowedKinds.contains(.audio) { types.append(.audio) }
        if allowedKinds.contains(.file) { types.append(contentsOf: [.pdf, .data]) }
        return types.isEmpty ? [.data] : types
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(filtered) { item in
                Button {
                    if let onChoose { onChoose(item.reference, item.kind) }
                    else if selection.contains(item.id) { selection.remove(item.id) }
                    else { selection.insert(item.id) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon(for: item.kind))
                            .font(.title2).foregroundStyle(FloeTheme.primary)
                            .frame(width: 42, height: 42)
                            .background(FloeTheme.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name).foregroundStyle(.primary).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))
                                .font(FloeTheme.Typography.metadata).foregroundStyle(.secondary)
                            if !item.tags.isEmpty {
                                Text(item.tags.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        if selection.contains(item.id) { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("编辑信息", systemImage: "info.circle") { editingItem = item }
                    if item.cloudRecordName != nil {
                        Button("删除云端副本，保留本机", systemImage: "icloud.slash", role: .destructive) {
                            Task { await store.deleteCloudCopy(item) }
                        }
                    }
                    if item.referenceCount > 0 {
                        Text("被 \(item.referenceCount) 个画布节点引用")
                    }
                }
            }
        }
        .overlay {
            if filtered.isEmpty {
                ContentUnavailableView("素材库为空", systemImage: "photo.on.rectangle.angled", description: Text("导入图片、视频、音频或文档；所有画布都可重复使用。"))
            }
        }
        .searchable(text: $search, prompt: "搜索素材")
        .navigationTitle("素材库")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !selection.isEmpty {
                    Button("删除", role: .destructive) {
                        let ids = selection
                        selection.removeAll()
                        Task { await store.delete(ids) }
                    }
                }
                Button("导入", systemImage: "plus") { importsFiles = true }
            }
        }
        .fileImporter(
            isPresented: $importsFiles,
            allowedContentTypes: allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): Task { await store.importFiles(urls) }
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .alert("素材操作失败", isPresented: Binding(
            get: { store.error != nil }, set: { if !$0 { store.error = nil } }
        )) { Button("完成", role: .cancel) {} } message: { Text(store.error ?? "") }
        .sheet(item: $editingItem) { item in
            CanvasMaterialMetadataEditor(item: item) { name, tags, sourceURL, license in
                Task { await store.update(item, name: name, tags: tags, sourceURL: sourceURL, license: license) }
            }
        }
        .task {
            store.configure(assetStore: environment.creativeAssetStore)
            await store.reload()
        }
    }

    private func icon(for kind: CanvasNodeKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .file: "doc"
        case .scene3D: "cube.transparent"
        default: "square.stack.3d.up"
        }
    }
}

private struct CanvasMaterialMetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    let item: CanvasMaterialLibraryStore.Item
    let onSave: (String, [String], URL?, String?) -> Void
    @State private var name: String
    @State private var tags: String
    @State private var source: String
    @State private var license: String

    init(
        item: CanvasMaterialLibraryStore.Item,
        onSave: @escaping (String, [String], URL?, String?) -> Void
    ) {
        self.item = item; self.onSave = onSave
        _name = State(initialValue: item.name)
        _tags = State(initialValue: item.tags.joined(separator: ", "))
        _source = State(initialValue: item.sourceURL?.absoluteString ?? "")
        _license = State(initialValue: item.license ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name)
                TextField("标签（逗号分隔）", text: $tags)
                TextField("来源网址", text: $source, axis: .vertical)
                    .textInputAutocapitalization(.never)
                TextField("授权信息", text: $license, axis: .vertical)
            }
            .navigationTitle("素材信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let values = tags.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        onSave(name, values, URL(string: source), license.isEmpty ? nil : license)
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
